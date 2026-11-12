import Foundation
import Darwin

private let kTIOCSWINSZ: UInt = 0x80087467

/// 疑似端末（PTY）でシェルを起動して読み書きする。
final class PTY {
    private(set) var fd: Int32 = -1
    private(set) var pid: pid_t = 0
    private var source: DispatchSourceRead?
    /// 送りきれなかったデータ（大きな貼り付けなど）。シェルが受け取れるようになったら続きを送る
    private var pending: [UInt8] = []
    private var pendingOffset = 0
    private var writeSource: DispatchSourceWrite?
    private var buf = [UInt8](repeating: 0, count: 65536)

    var onData: ((UnsafeBufferPointer<UInt8>) -> Void)?
    var onExit: (() -> Void)?

    @discardableResult
    func start(shell: String, cols: Int, rows: Int, env extra: [String: String]) -> Bool {
        stop()
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }

        // fork 前に C 文字列を全部用意しておく（子プロセスでは何も確保しない）
        let name = "-" + (shell as NSString).lastPathComponent   // ログインシェルとして起動
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(name), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(shell)
        let home = strdup(NSHomeDirectory())
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(path)
            free(home)
        }

        var master: Int32 = -1
        let p = forkpty(&master, nil, nil, &ws)
        if p < 0 { return false }
        if p == 0 {
            _ = chdir(home)
            _ = execve(path, argv, envp)
            _exit(127)
        }

        // 書き込みで待たないように（受け取れない分は後で送る）
        let flags = fcntl(master, F_GETFL)
        if flags >= 0 { _ = fcntl(master, F_SETFL, flags | O_NONBLOCK) }
        fd = master
        pid = p
        let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { close(master) }
        src.resume()
        source = src
        return true
    }

    private func readAvailable() {
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 {
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            finish()
            return
        }
        buf.withUnsafeBufferPointer { onData?(UnsafeBufferPointer(rebasing: $0[0..<n])) }
    }

    private func finish() {
        stop()
        onExit?()
    }

    private func stop() {
        stopWriting()
        guard let s = source else { return }
        source = nil
        s.cancel()
        fd = -1
        let p = pid
        pid = 0
        if p > 0 {
            DispatchQueue.global().async {
                var st: Int32 = 0
                _ = waitpid(p, &st, 0)
            }
        }
    }

    func write(_ s: String) { write(Array(s.utf8)) }

    /// シェルに送る。シェルがすぐ受け取れない分はためておき、受け取れるようになったら続きを送る。
    /// メインの処理はここで待たないので、大きな貼り付けでもアプリ全体が固まらない
    func write(_ bytes: [UInt8]) {
        guard fd >= 0, !bytes.isEmpty else { return }
        // Ctrl+C は、たまっている貼り付けの残りを捨ててすぐ送る（貼り付けを途中で止められるように）
        if bytes == [0x03] && hasPending {
            pending.removeAll()
            pendingOffset = 0
        }
        if hasPending {
            pending.append(contentsOf: bytes)
            return
        }
        let sent = writeSome(bytes, from: 0)
        if sent < bytes.count {
            pending = Array(bytes[sent...])
            pendingOffset = 0
            startWriteSource()
        }
    }

    private var hasPending: Bool { pendingOffset < pending.count }

    /// 書けるだけ書いて、書けたバイト数を返す（待たない）
    private func writeSome(_ bytes: [UInt8], from start: Int) -> Int {
        var off = start
        bytes.withUnsafeBufferPointer { p in
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                break   // EAGAIN（いまは受け取れない）やエラー：続きは後で
            }
        }
        return off - start
    }

    private func startWriteSource() {
        guard writeSource == nil, fd >= 0 else { return }
        let src = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.flushPending() }
        src.resume()
        writeSource = src
    }

    private func flushPending() {
        guard fd >= 0 else { stopWriting(); return }
        pendingOffset += writeSome(pending, from: pendingOffset)
        if !hasPending {
            stopWriting()
        } else if pendingOffset > 1 << 20 {
            // 送り終わった前半を捨てて、メモリを返す
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
    }

    private func stopWriting() {
        writeSource?.cancel()
        writeSource = nil
        pending.removeAll()
        pendingOffset = 0
    }

    func resize(cols: Int, rows: Int) {
        guard fd >= 0 else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, kTIOCSWINSZ, &ws)
    }

    func terminate() {
        if pid > 0 { kill(pid, SIGHUP) }
    }
}

// MARK: - パスワード入力中かどうか

extension PTY {
    /// パスワード入力中か：入力を1行ずつ受け取る状態（ICANON）なのに、打った文字を表示しない（ECHO なし）。
    /// sudo や ssh のパスワード入力がこの状態になる。vim などは ICANON も切っているので含まれない
    var isPasswordMode: Bool {
        guard fd >= 0 else { return false }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return false }
        return t.c_lflag & tcflag_t(ECHO) == 0 && t.c_lflag & tcflag_t(ICANON) != 0
    }
}

// MARK: - タブ名のための情報

extension PTY {
    /// いま前面で動いているコマンド名。シェル自身が前面にいるときは nil
    var foregroundCommand: String? {
        guard fd >= 0, pid > 0 else { return nil }
        let pg = tcgetpgrp(fd)
        guard pg > 0, pg != pid else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pg, &buf, UInt32(buf.count)) > 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }

    /// シェルのいるフォルダ（ホームは ~ で）
    var currentDirectory: String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return (path as NSString).lastPathComponent
    }
}

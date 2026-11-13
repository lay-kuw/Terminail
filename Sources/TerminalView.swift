import AppKit
import CoreText
import QuartzCore

/// ターミナルの描画・キー入力（日本語IME対応）・選択・スクロールを担当するビュー
final class TerminalView: NSView, NSTextInputClient {
    let term: Terminal
    let pty = PTY()
    private var config: Config

    private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italicFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var boldItalicFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private(set) var cellW: CGFloat = 8
    private(set) var cellH: CGFloat = 16
    private var baseline: CGFloat = 12
    private var padL: CGFloat = 16
    private var padR: CGFloat = 16
    private var padT: CGFloat = 16
    private var padB: CGFloat = 16
    private var topPad: CGFloat { padT + 28 + extraTop }   // 信号ボタンのぶん（＋タブバーのぶん）
    /// タブバーが使う上の余白（dots スタイルのタブ名の行など）
    var extraTop: CGFloat = 0 { didSet { if extraTop != oldValue { updateGrid(); needsDisplay = true } } }
    private var balance = false     // 余ったすき間を上下左右に均等に振り分ける（padding-balance）
    private var balX: CGFloat = 0
    private var balY: CGFloat = 0
    private var gx: CGFloat { padL + balX }     // 文字の格子の左上
    private var gy: CGFloat { topPad + balY }
    private var cellOpacity: CGFloat = 1        // 背景色つきのマスにも透明度をかける

    private var palette: [CGColor] = []
    private var fg = CGColor(gray: 0.93, alpha: 1)
    private var bgSolid = CGColor(gray: 0.1, alpha: 1)
    private var cursorColor = CGColor(gray: 0.8, alpha: 1)
    private var selColor = CGColor(gray: 0.5, alpha: 0.35)
    private var optionAsMeta = false
    private var boldIsBright = false
    private var thicken = false

    // カーソルの形（cursor-style）：block（マス全体）/ bar（左端の縦棒）/ underline（下線）
    private enum CursorStyle { case block, bar, underline }
    private var cursorStyle = CursorStyle.block

    /// マスの四角を、実際に塗るカーソルの形にする
    private func cursorShape(_ r: CGRect) -> CGRect {
        switch cursorStyle {
        case .block:
            return r
        case .bar:
            return CGRect(x: r.minX, y: r.minY, width: max(2, (cellW * 0.15).rounded()), height: r.height)
        case .underline:
            let h = max(2, (cellH * 0.12).rounded())
            return CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
        }
    }

    // カーソルのシュン（移動するとき、残像を引きながらすべるように動く）
    private var glide = true
    private var glideFrom: CGRect = .zero
    private var glideTo: CGRect = .zero
    private var glideStart: CFTimeInterval = 0
    private var glideTimer: Timer?
    private var lastCursor = (col: -1, row: -1)
    private static let glideHead = 0.09      // 先頭が着くまで
    private static let glideTail = 0.15      // しっぽが追いつくまで

    /// いま何行さかのぼっているか（0 = 一番下）
    private(set) var viewOffset = 0 {
        didSet {
            guard viewOffset != oldValue else { return }
            if !settingSmooth { syncSmooth(from: oldValue) }
            onViewOffsetChanged?()
        }
    }
    var onViewOffsetChanged: (() -> Void)?
    var onUserScroll: (() -> Void)?      // ホイールや検索で、自分でスクロールした
    /// いまの位置（0 = いちばん古い行、1 = 一番下）
    var scrollFraction: CGFloat {
        let sb = CGFloat(term.scrollback.count)
        return sb == 0 ? 1 : (sb - offF) / sb
    }

    // MARK: - スムーズスクロール
    //
    // さかのぼっている量を小数で持ち（offF）、行の途中のぶんは shiftUp（px）だけ全体を上にずらして描く。
    // トラックパッドは指の動きにそのままついてくる。マウスのホイールは目標まで、なめらかに追いかける。

    private var smoothScroll = true
    private var offF: CGFloat = 0           // さかのぼっている行数（小数あり）
    private var offTarget: CGFloat = 0      // ホイールで目指している位置
    private(set) var shiftUp: CGFloat = 0   // 行の途中まで動いているぶん（px）
    private var smoothTimer: Timer?
    private var settingSmooth = false

    /// ほかの所（キー入力・検索・つまみ）で viewOffset が変わったら、小数の位置も合わせる
    private func syncSmooth(from old: Int) {
        if viewOffset == 0 {
            offF = 0
            offTarget = 0
            shiftUp = 0
            stopSmooth()
            return
        }
        offF = max(0, CGFloat(viewOffset) - shiftUp / max(1, cellH))
        offTarget = max(0, offTarget + CGFloat(viewOffset - old))
    }

    private func setSmooth(_ v: CGFloat) {
        let sb = CGFloat(term.scrollback.count)
        offF = max(0, min(sb, v))
        var n = Int(ceil(offF - 0.001))
        var s = (CGFloat(n) - offF) * cellH
        if s < 0.5 { s = 0 }
        if s > cellH - 0.5 { s = 0; n -= 1 }   // ほぼ1行ぶん：ひとつ下の行にそろえる
        shiftUp = s
        settingSmooth = true
        viewOffset = max(0, n)
        settingSmooth = false
        needsDisplay = true
        followDragSelection()
    }

    // 目標に近づく速さ（秒）。小さいほどキビキビ、大きいほどゆったり。
    // 経過時間で計算するので、60Hz の画面でも 120Hz の画面でも同じ速さ・同じなめらかさになる
    private static let tauTrackpad: CGFloat = 0.035   // トラックパッド：指の動きをならしてついてくる
    private static let tauWheel: CGFloat = 0.085      // マウスのホイール
    private static let tauDrag: CGFloat = 0.03        // 右端の光の粒をつまんで動かす
    private static let tauJump: CGFloat = 0.11        // レールのクリック・一番下へ戻る：すーっと移動
    private var tau: CGFloat = 0.085
    private var lastTick: CFTimeInterval = 0
    private var displayLinkRef: AnyObject?

    /// 目標の位置まで、なめらかに移動する
    private func glide(to target: CGFloat, tau t: CGFloat) {
        offTarget = max(0, min(CGFloat(term.scrollback.count), target))
        tau = t
        startSmooth()
        onUserScroll?()
    }

    /// 画面の書き換え（垂直同期）に合わせて動かす。macOS 14 より前はタイマーで、画面の最大フレームレートで動かす
    private func startSmooth() {
        guard smoothTimer == nil && displayLinkRef == nil else { return }
        lastTick = CACurrentMediaTime()
        if #available(macOS 14.0, *) {
            let dl = displayLink(target: self, selector: #selector(displayTick))
            dl.add(to: .main, forMode: .common)
            displayLinkRef = dl
        } else {
            let fps = Double(window?.screen?.maximumFramesPerSecond ?? 60)
            let t = Timer(timeInterval: 1.0 / max(60, fps), repeats: true) { [weak self] _ in self?.smoothTick() }
            RunLoop.main.add(t, forMode: .common)
            smoothTimer = t
        }
    }

    @objc private func displayTick() { smoothTick() }

    private func smoothTick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0.001, now - lastTick))
        lastTick = now
        let d = offTarget - offF
        if abs(d) < 0.005 {
            setSmooth(offTarget)
            stopSmooth()
        } else {
            // 指数でなめらかに近づく（残りの距離のうち、経過時間に応じた割合だけ進む）
            let k = CGFloat(1 - Foundation.exp(-dt / Double(tau)))
            setSmooth(offF + d * k)
        }
        onUserScroll?()
    }

    private func stopSmooth() {
        smoothTimer?.invalidate()
        smoothTimer = nil
        if #available(macOS 14.0, *) { (displayLinkRef as? CADisplayLink)?.invalidate() }
        displayLinkRef = nil
    }

    /// 0 = いちばん古い行、1 = 一番下 の位置へ（右端の光の粒をマウスで動かしたとき）
    /// animated = true（レールをクリックして飛ぶ）ならすーっと移動、false（つまんで動かしている）なら手にほぼくっついてくる
    func scroll(toFraction f: CGFloat, animated: Bool = false) {
        guard !term.isAlt else { return }
        let sb = term.scrollback.count
        if smoothScroll {
            glide(to: CGFloat(sb) * (1 - max(0, min(1, f))), tau: animated ? Self.tauJump : Self.tauDrag)
            return
        }
        let top = Int((f * CGFloat(sb)).rounded())
        viewOffset = max(0, min(sb, sb - top))
        onUserScroll?()
        needsDisplay = true
    }

    /// ⌘K：画面と履歴を消す（うっかり表示した秘密の値を消したいときなど）。
    /// シェルに Ctrl+L を送って、プロンプトだけ描き直してもらう
    func clearScrollback() {
        guard !term.isAlt else { return }   // vim などの中では何もしない
        clearSearch()
        term.clearScreenAndHistory()        // 画面もアプリ側で確実に消す
        viewOffset = 0
        selA = nil
        selB = nil
        // シェルが前にいるときだけ Ctrl+L でプロンプトを描き直してもらう
        // （sleep などの実行中に送ると「^L」と表示されてしまうため）
        if pty.foregroundCommand == nil { pty.write("\u{0C}") }
        needsDisplay = true
    }

    func scrollToBottom() {
        guard viewOffset != 0 || offF > 0 else { return }
        if smoothScroll { glide(to: 0, tau: Self.tauJump); return }
        viewOffset = 0
        needsDisplay = true
    }
    private var marked = NSAttributedString()
    private var selA: (Int, Int)?
    private var selB: (Int, Int)?
    private var scrollAccum: CGFloat = 0

    private static let defBgAsFg: UInt32 = 0xF000_0001
    private static let defFgAsBg: UInt32 = 0xF000_0002

    var onBell: (() -> Void)?
    var onEnter: ((NSRect) -> Void)?
    var onType: ((NSRect) -> Void)?
    var onShellExit: (() -> Void)?
    var onDelete: ((NSRect) -> Void)?

    /// ⌘+ / ⌘- で変えた文字サイズの差（その場だけ。設定には保存しない）
    var fontDelta: CGFloat = 0 { didSet { if fontDelta != oldValue { apply(config) } } }

    // 検索のハイライト
    private var matches: [(row: Int, col: Int, len: Int)] = []
    private var matchByRow: [Int: [Int]] = [:]   // 行 → matches の番号
    private(set) var currentMatch = -1

    // ログ保存
    private var logHandle: FileHandle?
    private var logURL: URL?
    /// ログの書き込みに失敗して、記録を止めた（ディスクがいっぱいなど）
    var onLogError: ((URL, Error) -> Void)?
    private var logBuffer = Data()
    private var logFlushScheduled = false
    var isLogging: Bool { logHandle != nil }

    /// タブの色（tab-colors が cursor / edge のとき）。nil ならテーマのカーソル色
    var tabColor: NSColor? {
        didSet { cursorColor = tabColor?.cgColor ?? themeCursor; needsDisplay = true }
    }
    private var themeCursor = CGColor(gray: 0.8, alpha: 1)

    // 放置するとカーソルがふわーっと呼吸する
    private var idleEffect = true
    private var idleAfter: Double = 60
    private var lastActivity = CACurrentMediaTime()
    private var idleCheck: Timer?
    private var breathTimer: Timer?
    private var breathStart: CFTimeInterval = 0
    private var breathing: Bool { breathTimer != nil }

    /// キー入力・出力・クリックがあったら呼ぶ
    private func noteActivity() {
        lastActivity = CACurrentMediaTime()
        if breathing { stopBreath() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupIdle()
        if window == nil { stopSmooth() }
    }

    /// 放置チェックのタイマーは、前に出ているタブで、演出がオンのときだけ動かす
    private func setupIdle() {
        idleCheck?.invalidate()
        idleCheck = nil
        stopBreath()
        guard window != nil, idleEffect else { return }
        lastActivity = CACurrentMediaTime()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkIdle() }
        RunLoop.main.add(t, forMode: .common)
        idleCheck = t
    }

    private func checkIdle() {
        guard idleEffect, !breathing, let w = window, w.isVisible, w.isKeyWindow,
              CACurrentMediaTime() - lastActivity >= idleAfter else { return }
        breathStart = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.breathTick() }
        RunLoop.main.add(t, forMode: .common)
        breathTimer = t
    }

    private func breathTick() {
        guard let w = window, w.isKeyWindow else { stopBreath(); return }
        setNeedsDisplay(cellRect(term.cx, term.cy, w: 2).insetBy(dx: -18, dy: -18))
    }

    private func stopBreath() {
        guard let t = breathTimer else { return }
        t.invalidate()
        breathTimer = nil
        setNeedsDisplay(cellRect(term.cx, term.cy, w: 2).insetBy(dx: -18, dy: -18))
    }

    /// 呼吸の明るさ 0.3〜1（最初は 1 から始めて、なめらかに暗くなっていく）
    private var breathLevel: CGFloat {
        let t = CACurrentMediaTime() - breathStart
        return CGFloat(0.3 + 0.7 * (0.5 + 0.5 * cos(t * 1.7)))
    }

    init(frame: NSRect, config: Config) {
        self.config = config
        self.term = Terminal(cols: 80, rows: 24, scrollback: config.int("shell.scrollback", 0, 200_000))
        super.init(frame: frame)
        term.onBell = { [weak self] in self?.onBell?() }
        term.onResponse = { [weak self] s in self?.pty.write(s) }
        term.onScrollIntoHistory = { [weak self] in
            guard let self, self.viewOffset > 0 else { return }
            self.viewOffset = min(self.viewOffset + 1, self.term.scrollback.count)
        }
        term.onHistoryTrimmed = { [weak self] n in self?.shiftMatches(by: n) }
        term.onHistoryChanged = { [weak self] in
            guard let self else { return }
            self.refreshSearch()
            if self.term.isAlt { self.viewOffset = 0 }
            self.viewOffset = min(self.viewOffset, self.term.scrollback.count)
            self.selA = nil
            self.selB = nil
        }
        pty.onData = { [weak self] data in
            self?.noteActivity()
            self?.term.feed(data)
            self?.invalidateChanged()
            self?.scheduleSearchRefresh()
        }
        pty.onExit = { [weak self] in self?.stopLog(); self?.onShellExit?() }
        apply(config)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // MARK: - 設定

    func apply(_ c: Config) {
        config = c
        let size = max(6, min(72, CGFloat(c.double("font.size")) + fontDelta))
        let fam = c.string("font.family")
        font = NSFont(name: fam, size: size)
            ?? NSFontManager.shared.font(withFamily: fam, traits: [], weight: 5, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let fm = NSFontManager.shared
        // 日本語などメインのフォントにない文字は fallback のフォントで描く（2つ目の font-family）
        var names = c.strings("font.fallback")
        let one = c.string("font.fallback")
        if !one.isEmpty { names.append(one) }
        let fallbacks: [NSFontDescriptor] = names.compactMap { n in
            (NSFont(name: n, size: size)
                ?? NSFont(name: n.replacingOccurrences(of: " W", with: "-W").replacingOccurrences(of: " ", with: ""), size: size))?
                .fontDescriptor
        }
        func withFallback(_ f: NSFont) -> NSFont {
            guard !fallbacks.isEmpty else { return f }
            return NSFont(descriptor: f.fontDescriptor.addingAttributes([.cascadeList: fallbacks]), size: f.pointSize) ?? f
        }
        let regular = font
        font = withFallback(regular)
        boldFont = withFallback(fm.convert(regular, toHaveTrait: .boldFontMask))
        italicFont = withFallback(fm.convert(regular, toHaveTrait: .italicFontMask))
        boldItalicFont = withFallback(fm.convert(fm.convert(regular, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask))

        // ASCII をまとめて描いてもマス目とずれないよう、フォントの実際の文字幅をそのまま使う
        cellW = ("M" as NSString).size(withAttributes: [.font: font]).width
        let natural = font.ascender - font.descender + font.leading
        cellH = ceil(natural * CGFloat(max(0.7, min(3, c.double("font.line_height")))))
        baseline = floor((cellH - (font.ascender - font.descender)) / 2 + font.ascender)
        // padding が全体、padding_x / padding_y / padding_top などがあればそちらを優先
        func pad(_ keys: [String]) -> CGFloat {
            // 余白は 0〜200px に収める（とんでもない数が書かれていても落ちないように）
            for k in keys { let v = c.double(k); if v >= 0 { return CGFloat(min(200, v)) } }
            return CGFloat(max(0, min(200, c.double("window.padding"))))
        }
        padL = pad(["window.padding_left", "window.padding_x"])
        padR = pad(["window.padding_right", "window.padding_x"])
        padT = pad(["window.padding_top", "window.padding_y"])
        padB = pad(["window.padding_bottom", "window.padding_y"])

        let colors = Colors(c)
        fg = colors.foreground.cgColor
        bgSolid = colors.background.cgColor
        themeCursor = colors.cursor.cgColor
        cursorColor = tabColor?.cgColor ?? themeCursor
        let wasIdle = idleEffect
        idleEffect = c.string("fx.idle") == "breathe"
        idleAfter = max(1, c.double("fx.idle_after"))
        if wasIdle != idleEffect { setupIdle() }
        selColor = colors.selection.cgColor
        optionAsMeta = c.bool("shell.option_as_meta")
        boldIsBright = c.bool("colors.bold_is_bright")
        balance = c.bool("window.padding_balance")
        smoothScroll = c.bool("fx.smooth_scroll")
        if !smoothScroll && shiftUp > 0 { shiftUp = 0; needsDisplay = true }
        cellOpacity = c.bool("window.opacity_cells") ? CGFloat(max(0, min(1, c.double("window.opacity")))) : 1
        thicken = c.bool("font.thicken")
        glide = c.bool("fx.cursor_glide")
        switch c.string("cursor.style").lowercased() {
        case "bar": cursorStyle = .bar
        case "underline": cursorStyle = .underline
        default: cursorStyle = .block
        }
        term.maxScrollback = c.int("shell.scrollback", 0, 200_000)
        buildPalette(colors.palette)
        updateGrid()
        needsDisplay = true
    }


    private func buildPalette(_ base16: [NSColor]) {
        var p: [CGColor] = base16.map { $0.cgColor }
        let lv: [CGFloat] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 {
            p.append(CGColor(srgbRed: lv[r] / 255, green: lv[g] / 255, blue: lv[b] / 255, alpha: 1))
        } } }
        for i in 0..<24 {
            let v = CGFloat(8 + i * 10) / 255
            p.append(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
        }
        palette = p
    }

    // MARK: - シェル

    func startShell() {
        var shell = config.string("shell.program")
        if shell.isEmpty { shell = ProcessInfo.processInfo.environment["SHELL"] ?? "" }
        if shell.isEmpty, let pw = getpwuid(getuid()), let s = pw.pointee.pw_shell { shell = String(cString: s) }
        if shell.isEmpty { shell = "/bin/zsh" }
        // バージョンは Info.plist に書いたものをそのまま使う（2か所に書かない）
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var env = ["TERM": "xterm-256color", "COLORTERM": "truecolor",
                   "TERM_PROGRAM": "Terminail", "TERM_PROGRAM_VERSION": version]
        if ProcessInfo.processInfo.environment["LANG"] == nil {
            env["LANG"] = (Locale.preferredLanguages.first ?? "").hasPrefix("ja") ? "ja_JP.UTF-8" : "en_US.UTF-8"
        }
        if !pty.start(shell: shell, cols: term.cols, rows: term.rows, env: env) {
            term.feed("\u{1b}[31mTerminail: could not start the shell (\(shell))\u{1b}[0m\r\n")
            needsDisplay = true
        }
    }

    // MARK: - レイアウト

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    private func updateGrid() {
        guard cellW > 0, cellH > 0 else { return }
        let c = max(10, Int((bounds.width - padL - padR) / cellW))
        let r = max(3, Int((bounds.height - topPad - padB) / cellH))
        // ドラッグで大きさを変えている最中は、文字の格子を左上に固定する。
        // 余白を均等に振り分けると、1px 動かすたびに文字全体が少しずつずれて震えて見えるため（手を離したら振り分ける）
        let (bx, by): (CGFloat, CGFloat) = balance && !inLiveResize
            ? (max(0, floor((bounds.width - padL - padR - CGFloat(c) * cellW) / 2)),
               max(0, floor((bounds.height - topPad - padB - CGFloat(r) * cellH) / 2)))
            : (0, 0)
        if bx != balX || by != balY {
            balX = bx
            balY = by
            needsDisplay = true
        }
        guard c != term.cols || r != term.rows else { return }
        if inLiveResize {
            // ドラッグ中は、折り返し直しとシェルへの通知を 0.08 秒に1回までにまとめる（プロンプトの描き直しが連続しないように）
            guard resizeWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                self?.resizeWork = nil
                self?.updateGrid()
            }
            resizeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
            return
        }
        term.resize(cols: c, rows: r)
        pty.resize(cols: c, rows: r)
        needsDisplay = true
    }

    private var resizeWork: DispatchWorkItem?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        resizeWork?.cancel()
        resizeWork = nil
        updateGrid()          // 最後の大きさで折り返し直して、余白も振り分ける
        needsDisplay = true
    }

    /// cols × rows のマスがちょうど入るビューの大きさ
    func sizeFor(cols: Int, rows: Int) -> NSSize {
        NSSize(width: ceil(padL + padR + CGFloat(cols) * cellW), height: ceil(topPad + padB + CGFloat(rows) * cellH))
    }

    private func cellRect(_ col: Int, _ row: Int, w: Int = 1) -> NSRect {
        NSRect(x: gx + CGFloat(col) * cellW, y: gy + CGFloat(row) * cellH,
               width: cellW * CGFloat(w), height: cellH)
    }

    /// カーソルのマスの画面座標（演出やIME候補窓の位置に使う）
    func cursorScreenRect() -> NSRect {
        guard let win = window else { return .zero }
        return win.convertToScreen(convert(cellRect(term.cx, term.cy), to: nil))
    }

    // MARK: - 描画

    private func color(_ code: UInt32, bold: Bool) -> CGColor {
        if code == 0 || code == Self.defFgAsBg { return fg }
        if code == Self.defBgAsFg { return bgSolid }
        switch code >> 24 {
        case 1:
            var i = Int(code & 0xFF)
            if bold && boldIsBright && i < 8 { i += 8 }
            return i < palette.count ? palette[i] : fg
        case 2:
            return CGColor(srgbRed: CGFloat((code >> 16) & 0xFF) / 255,
                           green: CGFloat((code >> 8) & 0xFF) / 255,
                           blue: CGFloat(code & 0xFF) / 255, alpha: 1)
        default:
            return fg
        }
    }

    private func eff(_ c: Cell) -> (fg: UInt32, bg: UInt32) {
        if c.attr & A.inverse != 0 {
            return (c.bg == 0 ? Self.defBgAsFg : c.bg, c.fg == 0 ? Self.defFgAsBg : c.fg)
        }
        return (c.fg, c.bg)
    }

    // MARK: - 変わった行だけ描き直す

    /// 前回くらべた時点の、画面に出ている各行とカーソル
    private var shown: [[Cell]] = []
    private var shownCursor: (Int, Int, Bool) = (-1, -1, false)

    /// 出力が来たら、前回と中身が変わった行（とカーソルのあった行）だけ描き直しを頼む。
    /// 1行だけ変わったときに画面全体を描き直さずにすむ
    private func invalidateChanged() {
        let rows = term.rows
        if shown.count != rows {
            shown = Array(repeating: [], count: rows)
            needsDisplay = true
        }
        let top = term.scrollback.count - viewOffset
        for r in 0..<rows {
            let l = term.line(top + r) ?? []
            if l != shown[r] {
                shown[r] = l
                invalidateRow(r)
            }
        }
        let cur = (term.cx, term.cy, viewOffset == 0 && term.cursorVisible)
        if cur != shownCursor {
            if shownCursor.1 >= 0 && shownCursor.1 < rows { invalidateRow(shownCursor.1) }
            if cur.1 < rows { invalidateRow(cur.1) }
            shownCursor = cur
        }
    }

    private func invalidateRow(_ r: Int) {
        if shiftUp > 0 { needsDisplay = true; return }   // 行の途中までずれているときは全体を描き直す
        // 文字がマスから少しはみ出ることがあるので、上下に少し余裕をもたせる
        setNeedsDisplay(NSRect(x: 0, y: gy + CGFloat(r) * cellH - 2, width: bounds.width, height: cellH + 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)   // 描き直す範囲だけ、前の文字を消してから描く
        ctx.setShouldSmoothFonts(thicken)   // オフにすると細めの文字になる
        let topAbs = term.scrollback.count - viewOffset
        let sel = orderedSel()
        let focused = window?.isKeyWindow ?? false
        let showCursor = viewOffset == 0 && term.cursorVisible && marked.length == 0
        let gliding = showCursor && updateGlide() && focused
        if gliding { drawGlide(ctx) }
        // スムーズスクロールで行の途中にいるときは、全体を shiftUp だけ上にずらし、下に1行多く描く（はみ出しは切る）
        let shift = shiftUp
        if shift > 0 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: gy, width: bounds.width, height: CGFloat(term.rows) * cellH))
        }
        for r in 0..<(term.rows + (shift > 0 ? 1 : 0)) {
            let a = topAbs + r
            guard let line = term.line(a) else { continue }
            let y = gy + CGFloat(r) * cellH - shift
            if y > dirtyRect.maxY || y + cellH < dirtyRect.minY { continue }
            let cur: Int? = (showCursor && !gliding && r == term.cy) ? term.cx : nil
            drawRow(ctx, line, y: y, absRow: a, sel: sel, cursorCol: cur, focused: focused)
        }
        if shift > 0 { ctx.restoreGState() }
        if marked.length > 0 { drawMarked(ctx) }
        if isLogging {   // 記録中は右上に小さな赤い点
            let red = palette.count > 1 ? palette[1] : CGColor(srgbRed: 0.97, green: 0.46, blue: 0.56, alpha: 1)
            ctx.setFillColor(red)
            ctx.fillEllipse(in: CGRect(x: bounds.maxX - 18, y: 11, width: 7, height: 7))
        }
    }

    // MARK: - 検索

    /// 過去ログも含めて探す（大文字小文字は区別しない）。見つかった数を返す。いちばん新しいものから
    @discardableResult
    func search(_ query: String) -> Int {
        searchQuery = query
        findMatches(query)
        if matchCount > 0 { showMatch(matches.count - 1) }
        needsDisplay = true
        onMatchesChanged?()
        return matches.count
    }

    private var searchQuery = ""
    private var trimHandled = false
    private var trimmedTotal = 0      // これまでに履歴からあふれて消えた行の合計
    private var firstValid = 0        // matches のうち、まだ残っている最初の番号
    var onMatchesChanged: (() -> Void)?

    /// 履歴の古い行が消えた。
    /// 検索結果は「これまでに消えた行数も足した通し番号」で覚えているので、ずらす計算はいらない。
    /// 消えた行の結果がどこまでかを二分探索で調べるだけ（大量に流れても軽い）
    private func shiftMatches(by n: Int) {
        trimmedTotal += n
        trimHandled = true
        guard !matches.isEmpty else { return }
        var lo = firstValid, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid].row < trimmedTotal { lo = mid + 1 } else { hi = mid }
        }
        guard lo != firstValid else { return }
        firstValid = lo
        if currentMatch < firstValid { currentMatch = firstValid < matches.count ? firstValid : -1 }
        onMatchesChanged?()
    }

    /// 履歴が消された・画面の大きさが変わったなど：同じ言葉で探し直す（表示位置は動かさない）
    private func refreshSearch() {
        if trimHandled { trimHandled = false; return }
        refreshSearchKeepingPosition()
    }

    /// 同じ言葉で探し直す。いま選んでいる結果はそのまま（なければ近いもの）、表示位置は動かさない
    private func refreshSearchKeepingPosition() {
        searchRefreshWork?.cancel()
        searchRefreshWork = nil
        guard !searchQuery.isEmpty else { return }
        let cur: (row: Int, col: Int)? = currentMatch >= firstValid && currentMatch < matches.count
            ? (matches[currentMatch].row, matches[currentMatch].col) : nil
        findMatches(searchQuery)
        if matches.isEmpty {
            currentMatch = -1
        } else if let c = cur {
            // 同じ結果、なければそれより前で一番近いもの、それもなければ最初
            currentMatch = matches.lastIndex { $0.row < c.row || ($0.row == c.row && $0.col <= c.col) } ?? 0
        } else {
            currentMatch = matches.count - 1
        }
        needsDisplay = true
        onMatchesChanged?()
    }

    private var searchRefreshWork: DispatchWorkItem?

    /// 検索中に出力が流れてきたら、新しい行も探し直す。
    /// 流れている間は0.3秒に1回までにまとめる（毎回探すと重いので）
    private func scheduleSearchRefresh() {
        guard !searchQuery.isEmpty, searchRefreshWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            self?.searchRefreshWork = nil
            self?.refreshSearchKeepingPosition()
        }
        searchRefreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// 大文字小文字をそろえる（英字はその場で計算、それ以外は1文字のときだけ小文字に）
    private static func fold(_ ch: UInt32) -> UInt32 {
        if ch >= 65 && ch <= 90 { return ch + 32 }
        if ch < 128 { return ch }
        guard let u = Unicode.Scalar(ch) else { return ch }
        let l = String(u).lowercased().unicodeScalars
        return l.count == 1 ? l.first!.value : ch
    }

    /// 履歴と画面から探す。文字の比較は数値のまま行う（文字列を作らないので速い）
    private func findMatches(_ query: String) {
        matches = []
        matchByRow = [:]
        currentMatch = -1
        firstValid = 0
        let q = query.unicodeScalars.map { Self.fold($0.value) }
        guard !q.isEmpty else { return }
        let total = term.scrollback.count + term.rows
        var chars: [UInt32] = []
        var cols: [Int] = []
        chars.reserveCapacity(256)
        cols.reserveCapacity(256)
        for r in 0..<total {
            guard let line = term.line(r), line.count >= q.count else { continue }
            chars.removeAll(keepingCapacity: true)
            cols.removeAll(keepingCapacity: true)
            for (c, cell) in line.enumerated() where cell.attr & A.wideCont == 0 {
                chars.append(Self.fold(cell.ch == 0 ? 32 : cell.ch))
                cols.append(c)
            }
            guard chars.count >= q.count else { continue }
            var i = 0
            let last = chars.count - q.count
            while i <= last {
                var hit = true
                for k in 0..<q.count where chars[i + k] != q[k] { hit = false; break }
                if hit {
                    let endCell = cols[i + q.count - 1]
                    let w = line[endCell].attr & A.wide != 0 ? 2 : 1
                    // 行は「消えた行数を足した通し番号」で覚える（履歴があふれてもずれない）
                    matchByRow[r + trimmedTotal, default: []].append(matches.count)
                    matches.append((r + trimmedTotal, cols[i], endCell + w - cols[i]))
                    i += q.count
                } else { i += 1 }
            }
        }
    }

    /// older = true で古い方（上）へ
    func nextMatch(older: Bool) {
        // 結果が流れて消えていたら、その場で探し直してから進む
        if matchCount == 0 || searchRefreshWork != nil { refreshSearchKeepingPosition() }
        let n = matchCount
        guard n > 0 else { return }
        let idx = max(0, currentMatch - firstValid)
        showMatch(((idx + (older ? -1 : 1)) % n + n) % n + firstValid)
    }

    /// まだ履歴に残っている検索結果の数と、いま何番目か（表示用、1から）
    var matchCount: Int { matches.count - firstValid }
    var currentMatchNumber: Int { currentMatch - firstValid + 1 }

    private func showMatch(_ i: Int) {
        currentMatch = i
        let row = matches[i].row - trimmedTotal
        guard row >= 0 else { return }
        let sb = term.scrollback.count
        let top = sb - viewOffset
        if row < top || row >= top + term.rows {
            let want = max(0, min(sb, row - term.rows / 2))
            viewOffset = sb - want
            onUserScroll?()
        }
        needsDisplay = true
    }

    func clearSearch() {
        searchRefreshWork?.cancel()
        searchRefreshWork = nil
        searchQuery = ""
        matches = []
        matchByRow = [:]
        currentMatch = -1
        needsDisplay = true
    }

    // MARK: - ログ保存

    /// ここまでの履歴を書き出して、あとは行が確定するたびに書き足していく
    func startLog(to url: URL) -> Bool {
        stopLog()
        // ログには画面に出た秘密の値も残るので、自分だけが読み書きできるファイルにする
        let fm = FileManager.default
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              (try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil,
              let h = try? FileHandle(forWritingTo: url) else { return false }
        logHandle = h
        logURL = url
        logBuffer = Data()
        for l in term.scrollback { appendLog(l) }
        term.resetCommitSkip()
        term.onCommit = { [weak self] l in self?.appendLog(l) }
        flushLog()
        needsDisplay = true
        return true
    }

    /// 止めるときに、いま画面に出ている内容も書いて閉じる
    func stopLog() {
        guard logHandle != nil else { return }
        term.onCommit = nil
        for l in term.uncommittedScreenLines() { appendLog(l) }   // まだ書いていない所だけ
        flushLog()                      // 失敗したら flushLog の中で閉じて知らせる
        guard let h = logHandle else { return }
        try? h.close()
        logHandle = nil
        needsDisplay = true
    }

    private func appendLog(_ l: [Cell]) {
        // 画面の幅で折り返しただけの行は、改行せずに次の行とつなげる（長い行が1行のまま残る）
        let wrapped = Terminal.isWrapped(l)
        logBuffer.append(contentsOf: Array((Terminal.rowText(l, trim: !wrapped) + (wrapped ? "" : "\n")).utf8))
        if logBuffer.count > 64 * 1024 { flushLog(); return }
        if !logFlushScheduled {
            logFlushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.flushLog() }
        }
    }

    private func flushLog() {
        logFlushScheduled = false
        guard let h = logHandle, !logBuffer.isEmpty else { return }
        do {
            try h.write(contentsOf: logBuffer)
            logBuffer.removeAll(keepingCapacity: true)
        } catch {
            // 書けなかったら記録を止めて知らせる（記録中の赤い点も消える）
            term.onCommit = nil
            try? h.close()
            logHandle = nil
            logBuffer = Data()
            needsDisplay = true
            if let u = logURL { onLogError?(u, error) }
        }
    }

    // MARK: カーソルのシュン

    /// カーソルが動いていたらアニメを始める。アニメ中なら true
    private func updateGlide() -> Bool {
        let now = CACurrentMediaTime()
        let target = cellRect(term.cx, term.cy)
        if term.cx != lastCursor.col || term.cy != lastCursor.row {
            let first = lastCursor.col < 0
            lastCursor = (term.cx, term.cy)
            if glide && !first {
                glideFrom = isGliding(now) ? glideHeadRect(now) : glideTo
                glideStart = now
                startGlideTimer()
            }
            glideTo = target
        }
        glideTo = target
        return glide && isGliding(now)
    }

    private func isGliding(_ now: CFTimeInterval) -> Bool { now - glideStart < Self.glideTail }

    private func lerpRect(_ a: CGRect, _ b: CGRect, _ k: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k, width: a.width, height: a.height)
    }

    private func glideHeadRect(_ now: CFTimeInterval) -> CGRect {
        lerpRect(glideFrom, glideTo, CGFloat(easeOut(clamp01((now - glideStart) / Self.glideHead))))
    }

    private func drawGlide(_ ctx: CGContext) {
        let now = CACurrentMediaTime()
        let e = now - glideStart
        let head = cursorShape(glideHeadRect(now))
        let tailK = easeOut(clamp01((e - 0.025) / (Self.glideTail - 0.025)))
        let tail = cursorShape(lerpRect(glideFrom, glideTo, CGFloat(tailK)))
        // 先頭としっぽの四角をつなぐ形（凸包）を、うすいカーソル色で塗る
        let pts = [head, tail].flatMap { [CGPoint(x: $0.minX, y: $0.minY), CGPoint(x: $0.maxX, y: $0.minY),
                                          CGPoint(x: $0.maxX, y: $0.maxY), CGPoint(x: $0.minX, y: $0.maxY)] }
        let hull = convexHull(pts)
        if hull.count > 2 {
            ctx.setFillColor(cursorColor.copy(alpha: 0.35 * CGFloat(1 - tailK)) ?? cursorColor)
            ctx.addLines(between: hull)
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.setFillColor(cursorColor.copy(alpha: 0.85) ?? cursorColor)
        ctx.fill(head)
    }

    private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for pt in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], pt) <= 0 { lower.removeLast() }
            lower.append(pt)
        }
        for pt in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], pt) <= 0 { upper.removeLast() }
            upper.append(pt)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// アニメのあいだだけ画面を描き直す
    private func startGlideTimer() {
        guard glideTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.needsDisplay = true
            if !self.isGliding(CACurrentMediaTime()) {
                timer.invalidate()
                self.glideTimer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        glideTimer = t
    }

    /// 消える文字（カーソルの1つ左のマス）の画面座標
    private func deletedCharScreenRect() -> NSRect {
        guard let win = window else { return .zero }
        return win.convertToScreen(convert(cellRect(max(0, term.cx - 1), term.cy), to: nil))
    }

    private func drawRow(_ ctx: CGContext, _ line: [Cell], y: CGFloat, absRow: Int,
                         sel: ((Int, Int), (Int, Int))?, cursorCol: Int?, focused: Bool) {
        let n = min(line.count, term.cols)

        // 背景色
        var c = 0
        while c < n {
            let code = eff(line[c]).bg
            var e = c + 1
            while e < n && eff(line[e]).bg == code { e += 1 }
            if code != 0 {
                let bgc = color(code, bold: false)
                ctx.setFillColor(bgc.copy(alpha: bgc.alpha * cellOpacity) ?? bgc)
                ctx.fill(CGRect(x: gx + CGFloat(c) * cellW, y: y, width: CGFloat(e - c) * cellW, height: cellH))
            }
            c = e
        }

        // 選択範囲
        if let s = sel, absRow >= s.0.0, absRow <= s.1.0 {
            let c0 = absRow == s.0.0 ? s.0.1 : 0
            let c1 = min(absRow == s.1.0 ? s.1.1 : n - 1, n - 1)
            if c1 >= c0 {
                ctx.setFillColor(selColor)
                ctx.fill(CGRect(x: gx + CGFloat(c0) * cellW, y: y, width: CGFloat(c1 - c0 + 1) * cellW, height: cellH))
            }
        }

        // 検索で見つかった所
        if let ids = matchByRow[absRow + trimmedTotal] {
            for i in ids {
                let m = matches[i]
                let on = i == currentMatch
                let col = palette.count > 3 ? palette[3] : CGColor(srgbRed: 0.9, green: 0.7, blue: 0.3, alpha: 1)
                ctx.setFillColor(col.copy(alpha: on ? 0.75 : 0.28) ?? col)
                let r = CGRect(x: gx + CGFloat(m.col) * cellW, y: y, width: CGFloat(m.len) * cellW, height: cellH)
                ctx.fill(r)
                if on {
                    ctx.setStrokeColor(col)
                    ctx.setLineWidth(1)
                    ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
                }
            }
        }

        // カーソル
        if let cc = cursorCol, cc < n {
            let w: CGFloat = line[cc].attr & A.wide != 0 ? 2 : 1
            let r = cursorShape(CGRect(x: gx + CGFloat(cc) * cellW, y: y, width: cellW * w, height: cellH))
            if focused && breathing {
                let b = breathLevel
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 14 * b, color: cursorColor.copy(alpha: 0.9 * b))
                ctx.setFillColor(cursorColor.copy(alpha: b) ?? cursorColor)
                ctx.fill(r)
                ctx.restoreGState()
            } else if focused {
                ctx.setFillColor(cursorColor)
                ctx.fill(r)
            } else if cursorStyle == .block {
                ctx.setStrokeColor(cursorColor)
                ctx.setLineWidth(1)
                ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            } else {
                // 縦棒・下線は枠にできないので、ウィンドウが後ろにあるあいだは薄く塗る
                ctx.setFillColor(cursorColor.copy(alpha: 0.5) ?? cursorColor)
                ctx.fill(r)
            }
        }

        // 文字：ASCII は色・属性ごとにまとめて、それ以外（全角・記号・絵文字）は1文字ずつマスに置く
        var run = ""
        var runFg: UInt32 = 0
        var runAttr: UInt8 = 0
        var runStart = 0
        var runEnd = 0
        let by = y + baseline

        func attrs(_ fgCode: UInt32, _ at: UInt8) -> [NSAttributedString.Key: Any] {
            let f: NSFont
            switch (at & A.bold != 0, at & A.italic != 0) {
            case (true, true): f = boldItalicFont
            case (true, false): f = boldFont
            case (false, true): f = italicFont
            default: f = font
            }
            var col = color(fgCode, bold: at & A.bold != 0)
            if at & A.dim != 0 { col = col.copy(alpha: 0.55) ?? col }
            return [.font: f, .foregroundColor: NSColor(cgColor: col) ?? NSColor.white]
        }
        // オプションなしの draw(with:) は rect の原点がベースラインになる（反転ビューでもOK）
        func drawText(_ s: String, _ x: CGFloat, _ a: [NSAttributedString.Key: Any]) {
            NSAttributedString(string: s, attributes: a)
                .draw(with: NSRect(x: x, y: by, width: 100_000, height: cellH), options: [], context: nil)
        }
        func decorate(_ c0: Int, _ c1: Int, _ fgCode: UInt32, _ at: UInt8) {
            guard at & (A.underline | A.strike) != 0 else { return }
            ctx.setFillColor(color(fgCode, bold: at & A.bold != 0))
            let x0 = gx + CGFloat(c0) * cellW
            let w = CGFloat(c1 - c0) * cellW
            if at & A.underline != 0 { ctx.fill(CGRect(x: x0, y: by + 2, width: w, height: 1)) }
            if at & A.strike != 0 { ctx.fill(CGRect(x: x0, y: y + cellH / 2, width: w, height: 1)) }
        }
        func flush() {
            if run.isEmpty { return }
            drawText(run, gx + CGFloat(runStart) * cellW, attrs(runFg, runAttr))
            decorate(runStart, runEnd, runFg, runAttr)
            run = ""
        }

        for col in 0..<n {
            let cell = line[col]
            if cell.attr & A.wideCont != 0 { continue }
            var f = eff(cell).fg
            // ブロックのときだけ、カーソルの下の文字を背景色で抜く（縦棒・下線は文字に重ならない）
            if let cc = cursorCol, cc == col, focused, cursorStyle == .block { f = Self.defBgAsFg }
            let at = cell.attr & (A.bold | A.italic | A.underline | A.strike | A.dim)
            let ch = cell.ch == 0 ? 32 : cell.ch
            if ch == 32 && at & (A.underline | A.strike) == 0 { flush(); continue }
            let scalar = Unicode.Scalar(ch) ?? "\u{FFFD}"
            if ch < 0x80 {
                if !run.isEmpty && (f != runFg || at != runAttr) { flush() }
                if run.isEmpty { runFg = f; runAttr = at; runStart = col }
                run.unicodeScalars.append(scalar)
                runEnd = col + 1
            } else {
                flush()
                let wide = cell.attr & A.wide != 0
                let a = attrs(f, at)
                let s = String(Character(scalar))
                let w = (s as NSString).size(withAttributes: a).width
                let cw = cellW * (wide ? 2 : 1)
                drawText(s, gx + CGFloat(col) * cellW + max(0, (cw - w) / 2), a)
                decorate(col, col + (wide ? 2 : 1), f, at)
            }
        }
        flush()
    }

    /// 日本語入力の変換中の文字
    private func drawMarked(_ ctx: CGContext) {
        let s = marked.string
        let w = s.unicodeScalars.reduce(0) { $0 + Terminal.width($1.value) }
        let r = cellRect(term.cx, term.cy, w: max(1, w))
        ctx.setFillColor(bgSolid.copy(alpha: 0.92) ?? bgSolid)
        ctx.fill(r)
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: fg) ?? NSColor.white])
            .draw(with: NSRect(x: r.minX, y: r.minY + baseline, width: 100_000, height: cellH), options: [], context: nil)
        ctx.setFillColor(cursorColor)
        ctx.fill(CGRect(x: r.minX, y: r.minY + baseline + 2, width: r.width, height: 1.5))
    }

    // MARK: - キー入力

    private func send(_ s: String) {
        if viewOffset != 0 { viewOffset = 0; needsDisplay = true }
        pty.write(s)
    }

    override func keyDown(with e: NSEvent) {
        noteActivity()
        let m = e.modifierFlags
        if m.contains(.command) { return }
        if !hasMarkedText() {
            if let s = special(e) {
                if e.keyCode == 36 || e.keyCode == 76 { onEnter?(cursorScreenRect()) }
                if e.keyCode == 51 { onDelete?(deletedCharScreenRect()) }
                send(s)
                return
            }
            if m.contains(.control) {
                if let ign = e.charactersIgnoringModifiers, ign == " " || ign == "@" || ign == "2" {
                    send("\u{0}")
                    return
                }
                if let ch = e.characters, !ch.isEmpty { send(ch); return }
            }
            if m.contains(.option) && optionAsMeta, let ch = e.charactersIgnoringModifiers, !ch.isEmpty {
                send("\u{1b}" + ch)
                return
            }
        }
        // パスワード入力中は日本語入力を通さず、キーの文字（半角）をそのまま送る
        if pty.isPasswordMode, let ch = e.characters, !ch.isEmpty {
            if marked.length > 0 { marked = NSAttributedString(); needsDisplay = true }
            send(ch)
            return
        }
        interpretKeyEvents([e])
    }

    /// パスワード入力中は日本語入力（IME）をこのビューで使わせない。変換の学習にパスワードが残らないように
    override var inputContext: NSTextInputContext? {
        pty.isPasswordMode ? nil : super.inputContext
    }

    private func special(_ e: NSEvent) -> String? {
        let m = e.modifierFlags
        let alt = m.contains(.option)
        let ss = term.appCursor ? "\u{1b}O" : "\u{1b}["
        switch e.keyCode {
        case 36, 76: return "\r"
        case 51: return alt ? "\u{1b}\u{7f}" : "\u{7f}"
        case 117: return "\u{1b}[3~"
        case 48: return m.contains(.shift) ? "\u{1b}[Z" : "\t"
        case 53: return "\u{1b}"
        case 126: return ss + "A"
        case 125: return ss + "B"
        case 124: return alt ? "\u{1b}f" : ss + "C"
        case 123: return alt ? "\u{1b}b" : ss + "D"
        case 115: return "\u{1b}[H"
        case 119: return "\u{1b}[F"
        case 116: return "\u{1b}[5~"
        case 121: return "\u{1b}[6~"
        case 122: return "\u{1b}OP"
        case 120: return "\u{1b}OQ"
        case 99: return "\u{1b}OR"
        case 118: return "\u{1b}OS"
        case 96: return "\u{1b}[15~"
        case 97: return "\u{1b}[17~"
        case 98: return "\u{1b}[18~"
        case 100: return "\u{1b}[19~"
        case 101: return "\u{1b}[20~"
        case 109: return "\u{1b}[21~"
        case 103: return "\u{1b}[23~"
        case 111: return "\u{1b}[24~"
        default: return nil
        }
    }

    // MARK: - NSTextInputClient（日本語入力）

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSAttributedString()
        needsDisplay = true
        if s.isEmpty { return }
        onType?(cursorScreenRect())
        send(s)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onEnter?(cursorScreenRect())
            send("\r")
        case #selector(NSResponder.insertTab(_:)): send("\t")
        case #selector(NSResponder.deleteBackward(_:)):
            onDelete?(deletedCharScreenRect())
            send("\u{7f}")
        case #selector(NSResponder.cancelOperation(_:)): send("\u{1b}")
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString { marked = a }
        else if let s = string as? String { marked = NSAttributedString(string: s) }
        needsDisplay = true
    }

    func unmarkText() { marked = NSAttributedString(); needsDisplay = true }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange {
        marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { cursorScreenRect() }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: - マウス（選択・ドラッグ）

    private func cellAt(_ e: NSEvent) -> (Int, Int) {
        cellAt(point: convert(e.locationInWindow, from: nil))
    }

    private func cellAt(point p: NSPoint) -> (Int, Int) {
        let r = max(0, min(term.rows, Int((p.y - gy + shiftUp) / cellH)))
        let c = max(0, min(term.cols - 1, Int((p.x - gx) / cellW)))
        return (term.scrollback.count - viewOffset + r, c)
    }

    private func orderedSel() -> ((Int, Int), (Int, Int))? {
        guard let a = selA, let b = selB else { return nil }
        return (a.0 < b.0 || (a.0 == b.0 && a.1 <= b.1)) ? (a, b) : (b, a)
    }

    override func mouseDown(with e: NSEvent) {
        noteActivity()
        let p = convert(e.locationInWindow, from: nil)
        if p.y < topPad - 6 { window?.performDrag(with: e); return }   // 上の余白でウィンドウ移動
        window?.makeFirstResponder(self)
        let pos = cellAt(e)
        if e.clickCount == 2 { selectWord(at: pos) } else { selA = pos; selB = nil }
        dragPoint = p
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        guard selA != nil else { return }
        let p = convert(e.locationInWindow, from: nil)
        dragPoint = p
        selB = cellAt(point: p)
        updateDragScroll()
        needsDisplay = true
    }

    // MARK: - 選択しながらスクロール
    //
    // ・ドラッグ中にホイールやトラックパッドでスクロールしたら、選択の終わりをマウスの下のマスに合わせ直す
    // ・ドラッグしたまま上下の端からはみ出したら、はみ出したぶんだけ自動でスクロールする

    private var dragPoint: NSPoint?          // 選択のドラッグ中、マウスがいまいる場所（押していなければ nil）
    private var dragScrollTimer: Timer?
    private var dragScrollAccum: CGFloat = 0

    /// スクロールして画面が動いたら、選択の終わりをマウスの下のマスに合わせ直す
    private func followDragSelection() {
        guard let p = dragPoint, selA != nil else { return }
        selB = cellAt(point: p)
        needsDisplay = true
    }

    /// 文字の格子から上（＋）・下（−）にどれだけはみ出しているか（px）。中にいれば 0
    private func dragOvershoot(_ p: NSPoint) -> CGFloat {
        let bottom = min(bounds.maxY - 2, gy + CGFloat(term.rows) * cellH)
        if p.y < gy { return gy - p.y }
        if p.y > bottom { return bottom - p.y }
        return 0
    }

    private func updateDragScroll() {
        guard let p = dragPoint, selA != nil, !term.isAlt, dragOvershoot(p) != 0 else { stopDragScroll(); return }
        guard dragScrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.dragScrollTick() }
        RunLoop.main.add(t, forMode: .common)
        dragScrollTimer = t
    }

    private func stopDragScroll() {
        dragScrollTimer?.invalidate()
        dragScrollTimer = nil
        dragScrollAccum = 0
    }

    private func dragScrollTick() {
        guard let p = dragPoint, selA != nil, !term.isAlt else { stopDragScroll(); return }
        let over = dragOvershoot(p)
        guard over != 0 else { stopDragScroll(); return }
        // 大きくはみ出すほど速く（1秒あたり 6〜120 行）
        let speed: CGFloat = max(6, min(120, Swift.abs(over) / cellH * 12))
        let step: CGFloat = (over > 0 ? speed : -speed) / 60
        if smoothScroll {
            stopSmooth()
            setSmooth(offF + step)     // この中で選択も合わせ直す
            offTarget = offF
        } else {
            dragScrollAccum += step
            let lines = Int(dragScrollAccum)
            if lines != 0 {
                dragScrollAccum -= CGFloat(lines)
                viewOffset = max(0, min(term.scrollback.count, viewOffset + lines))
                followDragSelection()
            }
        }
        onUserScroll?()
    }

    override func mouseUp(with e: NSEvent) {
        dragPoint = nil
        stopDragScroll()
        if e.clickCount < 2 {
            if let a = selA, let b = selB, a == b { selA = nil; selB = nil }
            if selB == nil { selA = nil }
        }
        needsDisplay = true
    }

    private func selectWord(at p: (Int, Int)) {
        guard let line = term.line(p.0) else { return }
        func isWord(_ c: Int) -> Bool {
            guard c >= 0 && c < line.count else { return false }
            let cell = line[c]
            if cell.attr & A.wideCont != 0 { return true }
            return cell.ch != 32 && cell.ch != 0
        }
        guard isWord(p.1) else { return }
        var s = p.1, e = p.1
        while isWord(s - 1) { s -= 1 }
        while isWord(e + 1) { e += 1 }
        selA = (p.0, s)
        selB = (p.0, e)
    }

    override func scrollWheel(with e: NSEvent) {
        // スムーズスクロールは、1行未満の細かい動きもそのまま使う（整数の行にまとめる前に分ける）
        if smoothScroll && !term.isAlt {
            scrollAccum = 0
            let sb = CGFloat(term.scrollback.count)
            if e.hasPreciseScrollingDeltas {
                // トラックパッド：目標を指の動きどおりに動かし、画面の書き換えに合わせて素早く追いかける
                // （合図が届く間隔のばらつきをならして、カクつかないように）。慣性も macOS がそのまま送ってくる
                if e.phase == .began { offTarget = offF }
                glide(to: offTarget + e.scrollingDeltaY / cellH, tau: Self.tauTrackpad)
            } else {
                // マウスのホイール：目標の位置まで、なめらかに追いかける
                glide(to: min(sb, offTarget + e.scrollingDeltaY), tau: Self.tauWheel)
            }
            return
        }
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / cellH : e.scrollingDeltaY
        scrollAccum += dy
        let lines = Int(scrollAccum)
        if lines == 0 { return }
        scrollAccum -= CGFloat(lines)
        if term.isAlt {   // vim や less の中では矢印キーとして送る
            let seq = (term.appCursor ? "\u{1b}O" : "\u{1b}[") + (lines > 0 ? "A" : "B")
            pty.write(String(repeating: seq, count: min(Swift.abs(lines), 10)))
            return
        }
        viewOffset = max(0, min(term.scrollback.count, viewOffset + lines))
        onUserScroll?()
        needsDisplay = true
        followDragSelection()
    }

    // MARK: - メニューから呼ばれる操作

    @objc func doCopy(_ sender: Any?) {
        guard let s = orderedSel() else { return }
        let text = term.text(from: s.0, to: s.1)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func doPaste(_ sender: Any?) {
        guard var s = NSPasteboard.general.string(forType: .string) else { return }
        s = s.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        // 貼り付けた文字の中に「貼り付け終わり」の合図が仕込まれていると、そこから先がコマンドとして実行されてしまうので取り除く
        s = s.replacingOccurrences(of: "\u{1b}[201~", with: "").replacingOccurrences(of: "\u{1b}[200~", with: "")
        send(term.bracketedPaste ? "\u{1b}[200~" + s + "\u{1b}[201~" : s)
    }
}

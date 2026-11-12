import Foundation

/// 画面の1マス
struct Cell: Equatable {
    var ch: UInt32 = 32
    var fg: UInt32 = 0     // 0 = デフォルト / 0x01xxxxxx = パレット / 0x02RRGGBB = RGB
    var bg: UInt32 = 0
    var attr: UInt8 = 0
    var flags: UInt8 = 0   // F.*（すき間に入るのでメモリは増えない）
}

/// 行やマスの目印
enum F {
    /// 行の先頭のマスに付ける：この行は画面の幅で折り返して、次の行に続いている（本当の改行ではない）
    static let wrapped: UInt8 = 1
    /// 全角文字が行末に入りきらず、次の行へ送ったときに残る空きマス（コピーや折り返し直しでは無視する）
    static let filler: UInt8 = 2
}

enum A {
    static let bold: UInt8 = 1
    static let dim: UInt8 = 2
    static let italic: UInt8 = 4
    static let underline: UInt8 = 8
    static let inverse: UInt8 = 16
    static let strike: UInt8 = 32
    static let wide: UInt8 = 64        // 全角文字の左半分
    static let wideCont: UInt8 = 128   // 全角文字の右半分
}

enum Col {
    static func idx(_ i: Int) -> UInt32 { 0x0100_0000 | UInt32(max(0, min(255, i))) }
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        let c = { (v: Int) -> UInt32 in UInt32(max(0, min(255, v))) }
        return 0x0200_0000 | (c(r) << 16) | (c(g) << 8) | c(b)
    }
}

/// VT100 / xterm 互換のターミナル状態とエスケープシーケンス解析
final class Terminal {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var screen: [[Cell]]
    private(set) var scrollback: [[Cell]] = []
    var maxScrollback: Int
    private var savedMain: [[Cell]]?
    var isAlt: Bool { savedMain != nil }

    private(set) var cx = 0
    private(set) var cy = 0
    private var wrapPending = false
    private var pen = Cell()
    private var saved: (x: Int, y: Int, pen: Cell) = (0, 0, Cell())
    private var top = 0
    private var bottom: Int
    private(set) var cursorVisible = true
    private(set) var appCursor = false
    private(set) var bracketedPaste = false
    private var autowrap = true
    private var lastChar: UInt32 = 32

    var onBell: (() -> Void)?
    var onResponse: ((String) -> Void)?
    var onScrollIntoHistory: (() -> Void)?
    var onHistoryChanged: (() -> Void)?
    /// 履歴があふれて、古い行が n 行消えた（検索結果の行番号をずらすのに使う）
    var onHistoryTrimmed: ((Int) -> Void)?
    /// 行が確定したとき（画面の上から履歴へ流れた・画面ごと消された）。ログ保存に使う
    var onCommit: (([Cell]) -> Void)?
    /// 大きさを変えて履歴から画面に戻ってきた行の数（もう一度流れてきても二重に記録しない）
    private var commitSkip = 0
    /// その次の行のうち、先頭から何マスまでは書き終わっているか（折り返し直しで行の途中までになったとき）
    private var commitPartial = 0
    /// 細くしたときに画面の下からはみ出した行（カーソルを画面に残すために、下に押し出されたもの）。
    /// また広げたときに戻せるように取っておく。画面が上に流れたり消されたりしたら捨てる
    private var hiddenBelow: [[Cell]] = []

    private enum State { case ground, esc, escSkip, csi, str, strEsc }
    private var state = State.ground
    private var params: [Int] = []
    private var cur = -1
    private var priv: UInt8 = 0
    private var inter: UInt8 = 0
    private var u8need = 0
    private var u8acc: UInt32 = 0

    init(cols: Int, rows: Int, scrollback: Int) {
        self.cols = cols
        self.rows = rows
        self.maxScrollback = scrollback
        self.bottom = rows - 1
        self.screen = (0..<rows).map { _ in Array(repeating: Cell(), count: cols) }
    }

    // MARK: - 公開API

    func resetCommitSkip() { commitSkip = 0; commitPartial = 0 }

    /// 履歴に入れる行は、右側の何もないマスを切り落として小さくする（メモリ節約。履歴はふつう半分以上が空白）
    private static func compact(_ l: [Cell]) -> [Cell] {
        // 折り返している行は削らない（行末の空白も中身の一部なので）
        if isWrapped(l) { return l }
        let keep = A.inverse | A.underline | A.strike | A.wideCont
        var n = l.count
        while n > 0 {
            let c = l[n - 1]
            if (c.ch == 32 || c.ch == 0) && c.bg == 0 && c.attr & keep == 0 { n -= 1 } else { break }
        }
        return n == l.count ? l : Array(l[0..<n])
    }

    private func commit(_ l: [Cell]) {
        if commitSkip > 0 { commitSkip -= 1; return }
        if commitPartial > 0 {
            let r = Terminal.dropPrefix(l, commitPartial)
            commitPartial = 0
            if let r { onCommit?(r) }
            return
        }
        onCommit?(l)
    }

    /// 行の先頭 k マス（書き終わっている所）を落とす。折り返しの目印は残す。何も残らない折り返し行は nil
    private static func dropPrefix(_ l: [Cell], _ k: Int) -> [Cell]? {
        let wrapped = isWrapped(l)
        var r = Array(l[min(k, l.count)...])
        if wrapped {
            if r.isEmpty { return nil }
            r[0].flags |= F.wrapped
        }
        return r
    }

    /// ログを止めるとき用：画面に出ている内容のうち、まだログに書いていない所だけ
    func uncommittedScreenLines() -> [[Cell]] {
        var ls: [[Cell]]
        if hiddenBelow.isEmpty {
            ls = mainScreenLines()
        } else {
            // 細くしたときに画面の下へ押し出しておいた行も、画面の続きとして書く
            ls = (savedMain ?? screen) + hiddenBelow
            while let l = ls.last, !Terminal.isWrapped(l), Terminal.plain(l).isEmpty { ls.removeLast() }
        }
        let skip = min(commitSkip, ls.count)
        ls.removeFirst(skip)
        if skip == commitSkip && commitPartial > 0 && !ls.isEmpty {
            if let r = Terminal.dropPrefix(ls[0], commitPartial) { ls[0] = r } else { ls.removeFirst() }
        }
        return ls
    }

    /// この行は折り返して次の行に続いているか
    static func isWrapped(_ l: [Cell]) -> Bool { !l.isEmpty && l[0].flags & F.wrapped != 0 }

    /// 1行を文字列に（右端の空白は削る）
    static func plain(_ l: [Cell]) -> String { rowText(l, trim: true) }

    /// 1行を文字列に。全角の右半分と、送り残しの空きマスは飛ばす
    static func rowText(_ l: [Cell], from c0: Int = 0, to c1: Int = Int.max, trim: Bool) -> String {
        var s = ""
        let end = min(c1, l.count - 1)
        if c0 <= end {
            for c in c0...end {
                let cell = l[c]
                if cell.attr & A.wideCont != 0 || cell.flags & F.filler != 0 { continue }
                if let u = Unicode.Scalar(cell.ch == 0 ? 32 : cell.ch) { s.unicodeScalars.append(u) }
            }
        }
        if trim { while s.hasSuffix(" ") { s.removeLast() } }
        return s
    }

    /// いまの（通常の）画面の、最後に文字がある行までの文字列
    func mainScreenLines() -> [[Cell]] {
        let src = savedMain ?? screen
        guard let last = src.lastIndex(where: { !Terminal.plain($0).isEmpty }) else { return [] }
        return Array(src[0...last])
    }

    func line(_ a: Int) -> [Cell]? {
        if a < 0 { return nil }
        if a < scrollback.count { return scrollback[a] }
        let i = a - scrollback.count
        return i < rows ? screen[i] : nil
    }

    func feed(_ data: UnsafeBufferPointer<UInt8>) {
        for b in data { step(b) }
    }

    func feed(_ s: String) {
        let bytes = Array(s.utf8)
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    func fullReset() {
        reset()
        scrollback.removeAll()
        onHistoryChanged?()
    }

    func clearHistory() {
        scrollback.removeAll()
        hiddenBelow = []
        onHistoryChanged?()
    }

    /// ⌘K：履歴と、いま画面に出ている内容を消して、カーソルを左上へ（端末のモードはそのまま）
    func clearScreenAndHistory() {
        guard savedMain == nil else { return }
        scrollback.removeAll()
        for y in 0..<rows { screen[y] = blankRow() }
        cx = 0
        cy = 0
        wrapPending = false
        commitSkip = 0
        commitPartial = 0
        hiddenBelow = []
        onHistoryChanged?()
    }

    /// 選んだ範囲の文字列。画面の幅で折り返しただけの所には改行を入れない（長いコマンドや URL をそのままコピーできる）
    func text(from a: (Int, Int), to b: (Int, Int)) -> String {
        var out = ""
        for r in a.0...b.0 {
            guard let ln = line(r) else { continue }
            let wrapped = Terminal.isWrapped(ln) && r != b.0
            out += Terminal.rowText(ln, from: r == a.0 ? a.1 : 0, to: r == b.0 ? b.1 : Int.max, trim: !wrapped)
            if r != b.0 && !wrapped { out += "\n" }
        }
        return out
    }

    func resize(cols nc: Int, rows nr: Int) {
        guard nc > 0, nr > 0, nc != cols || nr != rows else { return }

        func fitWidth(_ lines: inout [[Cell]]) {
            for i in lines.indices {
                if lines[i].count < nc {
                    lines[i].append(contentsOf: Array(repeating: Cell(), count: nc - lines[i].count))
                } else if lines[i].count > nc {
                    lines[i].removeLast(lines[i].count - nc)
                }
            }
        }
        func fitHeight(_ lines: inout [[Cell]], cursorRow: inout Int, history: Bool) {
            if lines.count > nr {
                // カーソルより下の行から削り、それでも足りなければ上の行を履歴へ
                while lines.count > nr && lines.count - 1 > cursorRow { lines.removeLast() }
                while lines.count > nr {
                    let l = lines.removeFirst()
                    if history { scrollback.append(Terminal.compact(l)); commit(l) }
                    cursorRow -= 1
                }
            } else {
                while lines.count < nr {
                    if history, let l = scrollback.popLast() {
                        commitSkip += 1
                        lines.insert(l, at: 0)
                        cursorRow += 1
                    } else {
                        lines.append(Array(repeating: Cell(), count: nc))
                    }
                }
            }
        }

        if var m = savedMain {
            // vim などの全画面アプリ中：裏にある通常画面は折り返し直し、全画面アプリの画面はそのまま切り詰め
            var cur = (x: saved.x, y: saved.y)
            var wp = false
            reflow(&m, cursor: &cur, wrap: &wp, nc: nc, nr: nr)
            savedMain = m
            saved.x = cur.x
            saved.y = cur.y
            var c = cy
            fitHeight(&screen, cursorRow: &c, history: false)
            fitWidth(&screen)
            cy = max(0, min(c, nr - 1))
            cx = min(cx, nc - 1)
        } else {
            // 通常画面：本当の改行ごとの行に戻して、新しい幅で折り返し直す（はみ出した文字も消えない）
            var cur = (x: cx, y: cy)
            var wp = wrapPending
            reflow(&screen, cursor: &cur, wrap: &wp, nc: nc, nr: nr)
            cx = cur.x
            cy = cur.y
            wrapPending = wp
        }
        cols = nc
        rows = nr
        top = 0
        bottom = nr - 1
        if savedMain != nil { wrapPending = false }   // 通常画面では reflow が「次の文字で折り返す」状態を引き継ぐ
        onHistoryChanged?()
    }

    // MARK: - 折り返し直し

    private static func isBlankRow(_ l: [Cell]) -> Bool {
        let keep = A.inverse | A.underline | A.strike
        return l.allSatisfy { ($0.ch == 32 || $0.ch == 0) && $0.bg == 0 && $0.attr & keep == 0 }
    }

    /// 履歴＋画面（＋下に押し出しておいた行）を、本当の改行で区切られた行（論理行）に戻してから、新しい幅 nc で折り返し直す。
    /// カーソルの位置と「次の文字で折り返す」状態、ログに書き終わった位置（行の途中まで）も一緒に運ぶ
    private func reflow(_ main: inout [[Cell]], cursor: inout (x: Int, y: Int), wrap: inout Bool, nc: Int, nr: Int) {
        let oldCols = cols
        let sb = scrollback.count
        let committed = sb + commitSkip            // この行より前はログに書き終わっている（この行も commitPartial マスまで）

        // 画面は、最後に文字がある行かカーソルの行までを使う。下に押し出した行があるときは画面を全部使ってその後ろにつなげる
        var lastRow = min(cursor.y, main.count - 1)
        if let y = main.lastIndex(where: { !Terminal.isBlankRow($0) }) { lastRow = max(lastRow, y) }
        if !hiddenBelow.isEmpty { lastRow = main.count - 1 }
        let phys = scrollback + main[0...max(0, lastRow)] + hiddenBelow

        // 1. 論理行に戻す
        var logical: [[Cell]] = []
        var cur: [Cell] = []
        var curLL = 0, curOff = 0, curCell = -1     // curCell：「次の文字で折り返す」ときの、最後に書いた文字
        var bLL = -1, bOff = 0
        for (i, row) in phys.enumerated() {
            if i == committed { bLL = logical.count; bOff = cur.count + commitPartial }
            let wrapped = Terminal.isWrapped(row)
            var cells = row
            if wrapped && cells.count < oldCols { cells += Array(repeating: Cell(), count: oldCols - cells.count) }
            if i == sb + cursor.y {
                curLL = logical.count
                let x = min(cursor.x, max(0, cells.count - 1))
                if wrap {
                    curCell = cur.count + x
                    curOff = curCell + 1
                } else {
                    curOff = cur.count + min(cursor.x, cells.count)
                }
            }
            for c in cells where c.flags & F.filler == 0 {
                var c = c
                c.flags = 0
                cur.append(c)
            }
            if !wrapped {
                // 本当の改行：行末の空白は落とす（カーソルの所までは残す）
                var n = cur.count
                let keepTo = logical.count == curLL && i >= sb + cursor.y ? curOff : 0
                while n > keepTo, (cur[n - 1].ch == 32 || cur[n - 1].ch == 0), cur[n - 1].bg == 0,
                      cur[n - 1].attr & (A.inverse | A.underline | A.strike | A.wideCont) == 0 { n -= 1 }
                logical.append(Array(cur[0..<n]))
                cur = []
            }
        }
        if !cur.isEmpty { logical.append(cur) }
        if bLL < 0 { bLL = logical.count; bOff = 0 }

        // 2. 新しい幅で折り返す
        var out: [[Cell]] = []
        var newCur = (x: 0, row: 0)
        var endWrap = false                          // 縮めた結果、カーソルがちょうど行末に着いた
        var cellPos: (x: Int, row: Int)? = nil       // curCell の新しい場所
        var bRow = -1, bPartial = 0
        var filler = Cell()
        filler.flags = F.filler
        for (li, line) in logical.enumerated() {
            var row: [Cell] = []
            var j = 0
            while j < line.count {
                let isWide = line[j].attr & A.wide != 0 && j + 1 < line.count
                let w = isWide ? 2 : 1
                if row.count + w > nc {
                    if row.count < nc { row.append(filler) }   // 全角が入りきらない：空きマスを残して次の行へ
                    row[0].flags |= F.wrapped
                    out.append(row)
                    row = []
                }
                if li == curLL && j == curOff { newCur = (row.count, out.count) }
                if li == curLL && (j == curCell || (isWide && j + 1 == curCell)) {
                    cellPos = (row.count + (j == curCell ? 0 : 1), out.count)
                }
                if li == bLL && (j == bOff || (isWide && j + 1 == bOff)) { bRow = out.count; bPartial = row.count }
                row.append(line[j])
                if isWide { row.append(line[j + 1]) }
                j += w
            }
            if li == curLL && curOff >= line.count {
                let x = row.count + (curOff - line.count)
                if x >= nc {
                    // 行がちょうど埋まった：最後のマスに置いて「次の文字で折り返す」状態にする（上書きしないように）
                    newCur = (nc - 1, out.count)
                    endWrap = true
                } else {
                    newCur = (x, out.count)
                }
            }
            if li == bLL && bRow < 0 { bRow = out.count; bPartial = row.count }
            out.append(row)
        }
        if bRow < 0 { bRow = out.count; bPartial = 0 }
        if out.isEmpty { out = [[]] }

        // 「次の文字で折り返す」状態：最後に書いた文字のすぐ右にカーソルを置く。行末なら、また折り返し待ちにする
        var newWrap = endWrap && !wrap
        if wrap, let p = cellPos {
            let after = p.x + 1
            if after >= nc { newCur = (nc - 1, p.row); newWrap = true } else { newCur = (after, p.row) }
        }

        // 3. 履歴と画面に分ける（カーソルの行は必ず画面に入れる）。画面の下からはみ出した行は取っておく
        let start = max(0, min(out.count - nr, newCur.row))
        var newSB = out[0..<start].map { Terminal.compact($0) }
        var newMain: [[Cell]] = []
        for r in start..<min(out.count, start + nr) {
            var l = out[r]
            if l.count < nc { l += Array(repeating: Cell(), count: nc - l.count) }
            newMain.append(l)
        }
        while newMain.count < nr { newMain.append(Array(repeating: Cell(), count: nc)) }
        hiddenBelow = start + nr < out.count ? Array(out[(start + nr)...]) : []

        // 履歴の上限
        if newSB.count > maxScrollback {
            let k = newSB.count - maxScrollback
            newSB.removeFirst(k)
            bRow -= k
            if bRow < 0 { bRow = 0; bPartial = 0 }
        }

        // 4. ログ：書き終わった位置（行の途中まで）を新しい行に合わせる。
        //    まだ書いていない行が履歴に入ったら、いま書く。画面に戻った書き済みの所は、次に流れても書かない
        if onCommit != nil {
            if bRow < newSB.count {
                commitSkip = 0
                commitPartial = bPartial
                for r in bRow..<newSB.count { commit(newSB[r]) }
                commitSkip = 0
                commitPartial = 0
            } else {
                commitSkip = bRow - newSB.count
                commitPartial = bPartial
            }
        } else {
            commitSkip = 0
            commitPartial = 0
        }

        scrollback = newSB
        main = newMain
        wrap = newWrap
        cursor = (x: max(0, min(newCur.x, nc - 1)), y: max(0, min(newCur.row - start, nr - 1)))
    }

    // MARK: - パーサ

    private func step(_ b: UInt8) {
        switch state {
        case .ground: ground(b)
        case .esc: esc(b)
        case .escSkip: state = .ground
        case .csi: csi(b)
        case .str:
            if b == 0x1B { state = .strEsc } else if b == 0x07 { state = .ground }
        case .strEsc:
            if b == 0x5C { state = .ground } else { state = .esc; esc(b) }
        }
    }

    private func ground(_ b: UInt8) {
        if u8need > 0 {
            if b & 0xC0 == 0x80 {
                u8acc = (u8acc << 6) | UInt32(b & 0x3F)
                u8need -= 1
                if u8need == 0 { put(u8acc) }
                return
            }
            u8need = 0
            put(0xFFFD)
        }
        switch b {
        case 0x00..<0x20, 0x7F: control(b)
        case 0x20..<0x80: put(UInt32(b))
        case 0xC2...0xDF: u8acc = UInt32(b & 0x1F); u8need = 1
        case 0xE0...0xEF: u8acc = UInt32(b & 0x0F); u8need = 2
        case 0xF0...0xF4: u8acc = UInt32(b & 0x07); u8need = 3
        default: put(0xFFFD)
        }
    }

    private func control(_ b: UInt8) {
        switch b {
        case 0x07: onBell?()
        case 0x08: if cx > 0 { cx -= 1 }; wrapPending = false
        case 0x09: cx = min(cols - 1, (cx / 8 + 1) * 8); wrapPending = false
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cx = 0; wrapPending = false
        case 0x1B: state = .esc; inter = 0
        default: break
        }
    }

    private func esc(_ b: UInt8) {
        state = .ground
        switch b {
        case 0x5B: // [
            state = .csi
            params.removeAll(keepingCapacity: true)
            cur = -1; priv = 0; inter = 0
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .str   // OSC / DCS / SOS / PM / APC は読み飛ばす
        case 0x20...0x2F: state = .escSkip              // ESC ( B など
        case 0x37: saveCursor()                         // 7
        case 0x38: restoreCursor()                      // 8
        case 0x44: lineFeed()                           // D
        case 0x45: cx = 0; lineFeed()                   // E
        case 0x4D: reverseIndex()                       // M
        case 0x63: reset()                              // c
        default: break
        }
    }

    private func csi(_ b: UInt8) {
        switch b {
        case 0x30...0x39: cur = min(99999, (cur < 0 ? 0 : cur) * 10 + Int(b - 0x30))
        case 0x3A, 0x3B: params.append(cur); cur = -1
        case 0x3C...0x3F: priv = b
        case 0x20...0x2F: inter = b
        case 0x40...0x7E:
            params.append(cur)
            cur = -1
            state = .ground
            dispatch(b)
        case 0x18, 0x1A: state = .ground
        case 0x1B: state = .esc
        case 0x00..<0x20: control(b)
        default: break
        }
    }

    private func p(_ i: Int, _ d: Int = 1) -> Int { i < params.count && params[i] > 0 ? params[i] : d }
    private func p0(_ i: Int) -> Int { i < params.count && params[i] >= 0 ? params[i] : 0 }

    private func dispatch(_ f: UInt8) {
        if priv == 0x3F { // ?
            if f == 0x68 || f == 0x6C { for m in params where m >= 0 { privMode(m, f == 0x68) } }
            return
        }
        if priv != 0 {
            if priv == 0x3E && f == 0x63 { onResponse?("\u{1b}[>0;10;1c") }
            return
        }
        if inter != 0 {
            if inter == 0x21 && f == 0x70 { softReset() }
            return
        }
        if f != 0x6D && f != 0x62 { wrapPending = false }
        switch f {
        case 0x40: insertChars(p(0))                                        // @
        case 0x41: cy = max(cy >= top ? top : 0, cy - p(0))                 // A
        case 0x42, 0x65: cy = min(cy <= bottom ? bottom : rows - 1, cy + p(0)) // B e
        case 0x43, 0x61: cx = min(cols - 1, cx + p(0))                      // C a
        case 0x44: cx = max(0, cx - p(0))                                   // D
        case 0x45: cx = 0; cy = min(cy <= bottom ? bottom : rows - 1, cy + p(0)) // E
        case 0x46: cx = 0; cy = max(cy >= top ? top : 0, cy - p(0))         // F
        case 0x47, 0x60: cx = min(cols - 1, p(0) - 1)                       // G `
        case 0x48, 0x66: cy = min(rows - 1, p(0) - 1); cx = min(cols - 1, p(1) - 1) // H f
        case 0x64: cy = min(rows - 1, p(0) - 1)                             // d
        case 0x4A: eraseDisplay(p0(0))                                      // J
        case 0x4B: eraseLine(p0(0))                                         // K
        case 0x4C: insertLines(p(0))                                        // L
        case 0x4D: deleteLines(p(0))                                        // M
        case 0x50: deleteChars(p(0))                                        // P
        case 0x58: eraseChars(p(0))                                         // X
        case 0x53: scrollUp(p(0))                                           // S
        case 0x54: if params.count <= 1 { scrollDown(p(0)) }                // T
        case 0x62: for _ in 0..<min(p(0), 4096) { put(lastChar) }           // b
        case 0x6D: sgr()                                                    // m
        case 0x72:                                                          // r
            let t = p(0) - 1, bt = p(1, rows) - 1
            if t < bt && bt < rows { top = t; bottom = bt } else { top = 0; bottom = rows - 1 }
            cx = 0; cy = 0
        case 0x73: saveCursor()                                             // s
        case 0x75: restoreCursor()                                          // u
        case 0x6E:                                                          // n
            if p0(0) == 6 { onResponse?("\u{1b}[\(cy + 1);\(cx + 1)R") }
            else if p0(0) == 5 { onResponse?("\u{1b}[0n") }
        case 0x63: onResponse?("\u{1b}[?62;22c")                            // c
        default: break
        }
    }

    private func privMode(_ m: Int, _ on: Bool) {
        switch m {
        case 1: appCursor = on
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 47, 1047: if on { enterAlt() } else { exitAlt() }
        case 1049:
            if on { saveCursor(); enterAlt() } else { exitAlt(); restoreCursor() }
        case 2004: bracketedPaste = on
        default: break
        }
    }

    private func enterAlt() {
        guard savedMain == nil else { return }
        savedMain = screen
        screen = (0..<rows).map { _ in Array(repeating: Cell(), count: cols) }
        onHistoryChanged?()
    }

    private func exitAlt() {
        guard let m = savedMain else { return }
        screen = m
        savedMain = nil
        onHistoryChanged?()
    }


    private func sgr() {
        var i = 0
        while i < params.count {
            let v = max(0, params[i])
            switch v {
            case 0: pen = Cell()
            case 1: pen.attr |= A.bold
            case 2: pen.attr |= A.dim
            case 3: pen.attr |= A.italic
            case 4: pen.attr |= A.underline
            case 7: pen.attr |= A.inverse
            case 9: pen.attr |= A.strike
            case 21, 22: pen.attr &= ~(A.bold | A.dim)
            case 23: pen.attr &= ~A.italic
            case 24: pen.attr &= ~A.underline
            case 27: pen.attr &= ~A.inverse
            case 29: pen.attr &= ~A.strike
            case 30...37: pen.fg = Col.idx(v - 30)
            case 39: pen.fg = 0
            case 40...47: pen.bg = Col.idx(v - 40)
            case 49: pen.bg = 0
            case 90...97: pen.fg = Col.idx(v - 90 + 8)
            case 100...107: pen.bg = Col.idx(v - 100 + 8)
            case 38, 48:
                var color: UInt32?
                if i + 2 < params.count && params[i + 1] == 5 {
                    color = Col.idx(params[i + 2]); i += 2
                } else if i + 1 < params.count && params[i + 1] == 2 {
                    if i + 5 < params.count && params[i + 2] < 0 {
                        color = Col.rgb(params[i + 3], params[i + 4], params[i + 5]); i += 5
                    } else if i + 4 < params.count {
                        color = Col.rgb(params[i + 2], params[i + 3], params[i + 4]); i += 4
                    } else {
                        i = params.count
                    }
                }
                if let c = color { if v == 38 { pen.fg = c } else { pen.bg = c } }
            default: break
            }
            i += 1
        }
    }

    // MARK: - 画面操作

    private func blank() -> Cell { var c = Cell(); c.bg = pen.bg; return c }

    /// いまの行の x にマスを書く。行の先頭のマスなら「折り返している」目印は残す（文字を書き換えても行の性質は変わらない）
    private func setCell(_ x: Int, _ c: Cell) {
        var c = c
        if x == 0 { c.flags = (c.flags & ~F.wrapped) | (screen[cy][0].flags & F.wrapped) }
        screen[cy][x] = c
    }
    private func blankRow() -> [Cell] { Array(repeating: blank(), count: cols) }

    private func put(_ cp: UInt32) {
        let w = Terminal.width(cp)
        if w == 0 { combine(cp); return }
        if wrapPending {
            if autowrap { screen[cy][0].flags |= F.wrapped; cx = 0; lineFeed() }
            wrapPending = false
        }
        if w == 2 && cx >= cols - 1 {
            if !autowrap || cols < 2 { return }
            var f = blank()
            f.flags = F.filler
            setCell(cx, f)
            screen[cy][0].flags |= F.wrapped
            cx = 0
            lineFeed()
        }
        clearWide(cx)
        if w == 2 { clearWide(cx + 1) }
        var c = pen
        c.ch = cp
        c.flags = 0
        if w == 2 {
            c.attr |= A.wide
            setCell(cx, c)
            var c2 = pen
            c2.ch = 0
            c2.flags = 0
            c2.attr |= A.wideCont
            setCell(cx + 1, c2)
        } else {
            setCell(cx, c)
        }
        lastChar = cp
        if cx + w >= cols { cx = cols - 1; wrapPending = true } else { cx += w }
    }

    /// 全角文字の片割れを上書きする時は、もう片方も消す
    private func clearWide(_ x: Int) {
        guard x < cols else { return }
        let a = screen[cy][x].attr
        if a & A.wideCont != 0 && x > 0 { setCell(x - 1, blank()) }
        if a & A.wide != 0 && x + 1 < cols { setCell(x + 1, blank()) }
    }

    /// 濁点などの結合文字は直前の文字と合成する（か → が）
    private func combine(_ cp: UInt32) {
        var x = wrapPending ? cx : cx - 1
        guard x >= 0 else { return }
        if screen[cy][x].attr & A.wideCont != 0 && x > 0 { x -= 1 }
        guard let b = Unicode.Scalar(screen[cy][x].ch), let m = Unicode.Scalar(cp) else { return }
        var s = ""
        s.unicodeScalars.append(b)
        s.unicodeScalars.append(m)
        let comp = s.precomposedStringWithCanonicalMapping.unicodeScalars
        if comp.count == 1, let v = comp.first?.value { screen[cy][x].ch = v }
    }

    private func lineFeed() {
        if cy == bottom { scrollUp(1) } else if cy < rows - 1 { cy += 1 }
        wrapPending = false
    }

    private func reverseIndex() {
        if cy == top { scrollDown(1) } else if cy > 0 { cy -= 1 }
        wrapPending = false
    }

    private func scrollUp(_ n: Int) {
        for _ in 0..<min(n, rows) {
            let l = screen.remove(at: top)
            if top == 0 && savedMain == nil {
                hiddenBelow = []
                scrollback.append(Terminal.compact(l))
                commit(l)
                onScrollIntoHistory?()
                if scrollback.count > maxScrollback + 256 {
                    let n = scrollback.count - maxScrollback
                    scrollback.removeFirst(n)
                    onHistoryTrimmed?(n)
                    onHistoryChanged?()
                }
            }
            screen.insert(blankRow(), at: bottom)
        }
    }

    private func scrollDown(_ n: Int) {
        for _ in 0..<min(n, rows) {
            screen.remove(at: bottom)
            screen.insert(blankRow(), at: top)
        }
    }

    private func eraseLine(_ m: Int) {
        let a = m == 0 ? cx : 0
        let b = m == 1 ? cx + 1 : cols
        let bc = blank()
        if a < min(b, cols) { for x in a..<min(b, cols) { setCell(x, bc) } }
    }

    private func eraseDisplay(_ m: Int) {
        switch m {
        case 0:
            eraseLine(0)
            for y in (cy + 1)..<rows { screen[y] = blankRow() }
            if savedMain == nil { hiddenBelow = [] }
        case 1:
            eraseLine(1)
            for y in 0..<cy { screen[y] = blankRow() }
        case 2:
            if savedMain == nil, onCommit != nil {   // clear で消える内容もログには残す
                for l in mainScreenLines() { commit(l) }
            }
            for y in 0..<rows { screen[y] = blankRow() }
            if savedMain == nil { commitSkip = 0; commitPartial = 0; hiddenBelow = [] }
        case 3:
            clearHistory()
        default: break
        }
    }

    private func insertChars(_ n: Int) {
        let n = min(n, cols - cx)
        let w = screen[cy][0].flags & F.wrapped
        screen[cy].removeLast(n)
        screen[cy].insert(contentsOf: Array(repeating: blank(), count: n), at: cx)
        keepWrapFlag(w)
    }

    private func deleteChars(_ n: Int) {
        let n = min(n, cols - cx)
        let w = screen[cy][0].flags & F.wrapped
        screen[cy].removeSubrange(cx..<(cx + n))
        screen[cy].append(contentsOf: Array(repeating: blank(), count: n))
        keepWrapFlag(w)
    }

    /// 文字をずらしても、「折り返している」目印は行の先頭のマスに残す
    private func keepWrapFlag(_ w: UInt8) {
        for x in 1..<cols where screen[cy][x].flags & F.wrapped != 0 { screen[cy][x].flags &= ~F.wrapped }
        screen[cy][0].flags = (screen[cy][0].flags & ~F.wrapped) | w
    }

    private func eraseChars(_ n: Int) {
        let bc = blank()
        for x in cx..<min(cols, cx + n) { setCell(x, bc) }
    }

    private func insertLines(_ n: Int) {
        guard cy >= top && cy <= bottom else { return }
        for _ in 0..<min(n, bottom - cy + 1) {
            screen.remove(at: bottom)
            screen.insert(blankRow(), at: cy)
        }
        cx = 0
    }

    private func deleteLines(_ n: Int) {
        guard cy >= top && cy <= bottom else { return }
        for _ in 0..<min(n, bottom - cy + 1) {
            screen.remove(at: cy)
            screen.insert(blankRow(), at: bottom)
        }
        cx = 0
    }

    private func saveCursor() { saved = (cx, cy, pen) }

    private func restoreCursor() {
        cx = min(saved.x, cols - 1)
        cy = min(saved.y, rows - 1)
        pen = saved.pen
        wrapPending = false
    }

    private func softReset() {
        pen = Cell()
        top = 0
        bottom = rows - 1
        cursorVisible = true
        appCursor = false
        autowrap = true
        wrapPending = false
    }

    private func reset() {
        softReset()
        hiddenBelow = []
        screen = (0..<rows).map { _ in Array(repeating: Cell(), count: cols) }
        savedMain = nil
        cx = 0
        cy = 0
        bracketedPaste = false
        state = .ground
        u8need = 0
    }

    // MARK: - 文字幅

    static func width(_ c: UInt32) -> Int {
        if c < 0x300 { return 1 }
        switch c {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x200B...0x200F, 0x20D0...0x20FF,
             0x3099...0x309A, 0xFE00...0xFE0F, 0x1F3FB...0x1F3FF, 0xE0100...0xE01EF,
             0x1160...0x11FF:
            return 0
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x3098, 0x309B...0x33FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

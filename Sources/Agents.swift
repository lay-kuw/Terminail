import AppKit
import CoreText

// MARK: - AI エージェント
//
// タブの中で Claude Code・Codex・Antigravity CLI が動いていたら見分けて、
// 「考え中」「承認待ち」などの様子を、hooks と画面の文字から読み取る。

/// 対応している AI
enum AgentKind: String, CaseIterable {
    case claude, codex, antigravity

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    /// バッジの色（テーマに関係なく見分けやすいパステル）
    var badgeColor: NSColor {
        switch self {
        case .claude: return NSColor(srgbRed: 1.00, green: 0.77, blue: 0.64, alpha: 1)   // ピーチ
        case .codex: return NSColor(srgbRed: 0.83, green: 0.75, blue: 1.00, alpha: 1)    // ラベンダー
        case .antigravity: return NSColor(srgbRed: 0.66, green: 0.90, blue: 1.00, alpha: 1)   // 水色
        }
    }

    /// 前面のプロセスの名前と引数から見分ける。node で動くものは、引数のスクリプトの名前で見分ける
    static func detect(name: String, args: [String]) -> AgentKind? {
        let head = Array(args.prefix(3))
        let bases = ([name] + head).map { ($0 as NSString).lastPathComponent.lowercased() }
        let full = head.map { $0.lowercased() }
        func named(_ s: String) -> Bool { bases.contains(s) }
        func inPath(_ s: String) -> Bool { full.contains { $0.contains(s) } }
        if named("claude") || inPath("claude-code") { return .claude }
        if named("codex") || inPath("@openai/codex") { return .codex }
        if named("agy") || named("antigravity") || inPath("antigravity") { return .antigravity }
        return nil
    }
}

/// AI の様子
enum AgentStatus {
    case thinking, approval, waiting, done, error

    var label: String {
        switch self {
        case .thinking: return "Thinking"
        case .approval: return "Needs you"
        case .waiting: return "Your turn"
        case .done: return "Done"
        case .error: return "Error"
        }
    }

    var face: String {
        switch self {
        case .thinking: return "(•ᴗ•)…"
        case .approval: return "(・ω・)?"
        case .waiting: return "(•ᴗ•)ノ"
        case .done: return "(˶ᵔᵕᵔ˶)✧"
        case .error: return "(；ﾟдﾟ)"
        }
    }

    /// テーマの色から（青・黄・水色・緑・赤）
    func color(_ p: [NSColor]) -> NSColor {
        guard p.count >= 8 else { return .white }
        switch self {
        case .thinking: return p[4]
        case .approval: return p[5].blended(withFraction: 0.4, of: .white) ?? p[5]   // 薄い紫
        case .waiting: return p[6]
        case .done: return p[2]
        case .error: return p[1]
        }
    }

    /// 急ぐ順（大きいほど急ぐ）。タブにひとつだけ印を出すときに使う
    var urgency: Int {
        switch self {
        case .approval: return 5
        case .error: return 4
        case .thinking: return 3
        case .waiting: return 2
        case .done: return 1
        }
    }
}

/// 画面1つぶんの AI の様子
final class AgentState {
    let kind: AgentKind
    private(set) var status: AgentStatus = .waiting
    private(set) var since = CACurrentMediaTime()
    /// 今回の頼みごとで考えていた時間の合計（承認待ちなど、AI が止まっていた時間は数えない）
    private(set) var thought: Double = 0
    var doing = ""          // いまやっていること（「Edit login.ts」など）
    var request = ""        // 承認待ちのときの中身
    var prompt = ""         // 最後に頼んだこと
    var hookStatus = false  // hooks から「始まり・終わり・承認待ち」が届いている（届いていれば、そちらを正とする）
    var hookDoing = false   // hooks から「いまやっていること」が届いている
    var quiet = 0           // 画面から「考え中」が消えて何回目か（すぐに「完了」にしないため）
    /// 起動したばかりで、まだ何も頼んでいない（「Your turn」のかわりにごあいさつ）
    private(set) var fresh = true

    init(kind: AgentKind) { self.kind = kind }

    /// 状態を変える。変わったら true
    @discardableResult
    func set(_ s: AgentStatus) -> Bool {
        guard s != status else { return false }
        fresh = false
        // 終わったら「いまやっていること」は消す（最後の作業の名前が、薄い字で残ったままにならないように）
        if s == .done || s == .waiting || s == .error { doing = ""; hookDoing = false }
        let now = CACurrentMediaTime()
        if status == .thinking { thought += now - since }
        // 新しい頼みごとが始まったら数え直す（承認のあとに考えを続けるときは、そのまま足していく）
        if s == .thinking && status != .approval { thought = 0 }
        status = s
        since = now
        return true
    }

    /// 考えている時間（考え中のときだけ「2m 14s」。ほかのときは出さない）
    var timeText: String {
        guard status == .thinking else { return "" }
        let n = max(0, Int(thought + CACurrentMediaTime() - since))
        if n < 60 { return "\(n)s" }
        if n < 3600 { return "\(n / 60)m " + String(format: "%02ds", n % 60) }
        return "\(n / 3600)h " + String(format: "%02dm", (n % 3600) / 60)
    }

    /// カードに出す様子の名前
    var label: String { fresh ? "Hello World" : status.label }
    /// 様子の名前のあとに添える顔文字（起動したばかりのときと、添える一言がないとき）
    var labelFace: String { summary.isEmpty && status != .thinking ? "₍ᐢ. .ᐢ₎♡" : "" }

    /// カードに出す一言
    var summary: String {
        if fresh { return "" }
        if status == .approval { return request.isEmpty ? "Waiting for your OK" : request }
        if !doing.isEmpty { return doing }
        if !prompt.isEmpty { return "“" + prompt + "”" }
        return ""
    }
}

// MARK: - 画面の文字から推測する（hooks がないとき・承認の確認）

enum AgentScreen {
    struct Info {
        var busy = false        // 考え中・作業中（「esc to interrupt」が出ている）
        var approval = false    // 承認を待っている（「Do you want…」と「1. Yes」が出ている）
        var activity = ""       // 作業中の一言（「Pondering…」など）
        var question = ""       // 承認のたずね文
    }

    /// 作業中の行（「✻ Pondering… (12s · ↓ 1.2k tokens)」「Working (5s • esc to interrupt)」など）
    private static let spinner = try? NSRegularExpression(
        pattern: "^\\s*[^\\s\\w]?\\s*[A-Za-z][\\w-]*(…|\\.\\.\\.)?\\s*\\(\\s*(\\d+m\\s*)?\\d+s\\b", options: [])

    private static let yesOption = try? NSRegularExpression(
        pattern: "(^|[\\s❯>›])1[.)]\\s*(yes|allow|approve|proceed)", options: [.caseInsensitive])

    static func scan(_ lines: [String]) -> Info {
        var info = Info()
        var asked = false
        var yes = false
        for raw in lines {
            let l = raw.lowercased()
            let spin = spinner?.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
            if l.contains("esc to interrupt") || l.contains("esc to cancel") || spin {
                info.busy = true
                info.activity = activityText(raw)
            }
            if l.contains("do you want") || l.contains("allow this") || l.contains("would you like to run")
                || l.contains("requires approval") || l.contains("permission") {
                asked = true
                if info.question.isEmpty { info.question = raw.trimmingCharacters(in: .whitespaces) }
            }
            if l.contains("(y/n)") || l.contains("[y/n]") || l.contains("allow once") || l.contains("yes, proceed") { yes = true }
            if let re = yesOption, re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil { yes = true }
        }
        info.approval = asked && yes
        return info
    }

    /// 「✻ Pondering… (esc to interrupt)」→「Pondering…」
    private static func activityText(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "(") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: "esc to", options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        let start = t.firstIndex { $0.isLetter } ?? t.endIndex
        t = String(t[start...]).trimmingCharacters(in: .whitespaces)
        while let last = t.last, last == "·" || last == "•" || last == "-" {
            t.removeLast()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return String(t.prefix(60))
    }
}

// MARK: - hooks から届く知らせ

/// AI の hooks が `Terminail --hook <ai> <event>` を呼ぶと、その Terminail が動いているアプリにこれを送る
struct AgentHookEvent {
    static let name = Notification.Name("io.github.lay-kuw.terminail.hook")

    let pane: String
    let kind: AgentKind
    let event: String
    let tool: String
    let detail: String
    let prompt: String
    let message: String
    let type: String
    /// Antigravity の Stop：false なら、まだ続きがある
    let idle: String

    init?(_ info: [AnyHashable: Any]) {
        func s(_ k: String) -> String { info[k] as? String ?? "" }
        guard !s("pane").isEmpty, let k = AgentKind(rawValue: s("agent")) else { return nil }
        pane = s("pane")
        kind = k
        event = s("event")
        tool = s("tool")
        detail = s("detail")
        prompt = s("prompt")
        message = s("message")
        type = s("type")
        idle = s("idle")
    }
}

/// コマンドラインとして呼ばれたとき（hooks から）。ふつうに起動したときは nil を返す
enum HookCLI {
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        switch args[1] {
        case "--hook":
            if args.count >= 4, let kind = AgentKind(rawValue: args[2]) { forward(kind, args[3]) }
            return 0      // 何があっても AI の邪魔はしない（何も出力せず、成功で終わる）
        case "--uninstall-hooks":
            AgentHooks.uninstall()
            return 0
        default:
            return nil
        }
    }

    private static func forward(_ kind: AgentKind, _ event: String) {
        guard let pane = ProcessInfo.processInfo.environment["TERMINAIL_PANE"], !pane.isEmpty else { return }
        let json = (try? JSONSerialization.jsonObject(with: readInput())) as? [String: Any] ?? [:]
        func str(_ v: Any?) -> String { v as? String ?? "" }
        // Claude Code・Codex は tool_name / tool_input、Antigravity は toolCall の name / args
        let call = json["toolCall"] as? [String: Any] ?? [:]
        let input = json["tool_input"] as? [String: Any] ?? call["args"] as? [String: Any] ?? [:]
        var lower: [String: Any] = [:]
        for (k, v) in input { lower[k.lowercased()] = v }
        let keys = ["command", "commandline", "file_path", "absolutepath", "targetfile", "path", "pattern", "url", "query"]
        let detail = keys.map { str(lower[$0]) }.first { !$0.isEmpty } ?? ""
        let tool = [json["tool_name"], json["tool"], call["name"]].map(str).first { !$0.isEmpty } ?? ""
        let prompt = str(json["prompt"]).isEmpty ? str(json["lastUserInput"]) : str(json["prompt"])
        var idle = ""
        if let b = json["fullyIdle"] as? Bool { idle = b ? "true" : "false" }
        let info: [String: String] = [
            "pane": pane, "agent": kind.rawValue, "event": event,
            "tool": tool,
            "detail": String(detail.prefix(200)),
            "prompt": String(prompt.prefix(200)),
            "message": String(str(json["message"]).prefix(200)),
            "type": str(json["notification_type"]),
            "idle": idle
        ]
        DistributedNotificationCenter.default().postNotificationName(AgentHookEvent.name, object: nil,
                                                                    userInfo: info, deliverImmediately: true)
    }

    /// hooks が渡してくる情報（標準入力の JSON）。1秒待っても来なければあきらめる（AI を止めないように）
    private static func readInput() -> Data {
        guard isatty(0) == 0 else { return Data() }
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = FileHandle.standardInput.readDataToEndOfFile()
            done.signal()
        }
        return done.wait(timeout: .now() + 1) == .success ? data : Data()
    }
}

// MARK: - hooks を AI の設定に足す・外す

enum AgentHooks {
    private enum Style { case wrapped, named }   // wrapped：{"hooks": {イベント: […]}}、named：{"terminail": {イベント: […]}}
    private struct Target {
        let kind: AgentKind
        let dir: String
        let file: String
        let events: [(String, String?)]          // イベントと、道具の絞り込み（nil なら書かない）
        let style: Style
    }

    private static var targets: [Target] {
        let h = NSHomeDirectory()
        return [
            Target(kind: .claude, dir: h + "/.claude", file: h + "/.claude/settings.json",
                   events: [("UserPromptSubmit", nil), ("PreToolUse", "*"), ("PostToolUse", "*"), ("Notification", nil), ("Stop", nil)],
                   style: .wrapped),
            Target(kind: .codex, dir: h + "/.codex", file: h + "/.codex/hooks.json",
                   events: [("UserPromptSubmit", nil), ("PreToolUse", ".*"), ("PermissionRequest", ".*"), ("PostToolUse", ".*"), ("Stop", nil)],
                   style: .wrapped),
            // Antigravity CLI：道具のイベントは matcher つき、ほかのイベントはコマンドをそのまま並べる
            Target(kind: .antigravity, dir: h + "/.gemini", file: h + "/.gemini/config/hooks.json",
                   events: [("PreInvocation", nil), ("PreToolUse", "*"), ("PostToolUse", "*"), ("Stop", nil)],
                   style: .named),
        ]
    }

    /// 足すかどうかの答え（"on" / "off"）。まだ聞いていなければ nil
    static var consent: String? {
        get {
            let s = try? String(contentsOfFile: markerPath, encoding: .utf8)
            return s?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            try? FileManager.default.createDirectory(atPath: Config.dir, withIntermediateDirectories: true)
            try? (newValue ?? "").write(toFile: markerPath, atomically: true, encoding: .utf8)
        }
    }
    private static var markerPath: String { (Config.dir as NSString).appendingPathComponent("agent-hooks") }

    /// Terminail が足した hooks か（コマンドの形で見分ける）
    private static func isOurs(_ h: [String: Any]) -> Bool {
        (h["command"] as? String)?.contains("/Terminail' --hook ") ?? false
    }

    /// 入っている AI にだけ hooks を足す（前に足したものは、いまのアプリの場所で入れ直す）。足した AI の名前を返す
    @discardableResult
    static func install() -> [String] {
        guard let exe = Bundle.main.executablePath else { return [] }
        let quoted = "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var added: [String] = []
        for t in targets where FileManager.default.fileExists(atPath: t.dir) {
            guard var root = read(t.file) else { continue }   // JSON として読めないファイルには触らない
            backup(t.file)
            strip(&root, t)
            for (event, matcher) in t.events {
                let handler: [String: Any] = ["type": "command", "command": "\(quoted) --hook \(t.kind.rawValue) \(event)"]
                var group: [String: Any] = ["hooks": [handler]]
                if let m = matcher { group["matcher"] = m }
                if t.style == .named && matcher == nil { group = handler }
                let key = t.style == .wrapped ? "hooks" : "terminail"
                var events = root[key] as? [String: Any] ?? [:]
                var list = events[event] as? [[String: Any]] ?? []
                list.append(group)
                events[event] = list
                root[key] = events
            }
            if write(root, t.file) { added.append(t.kind.title) }
        }
        return added
    }

    /// Terminail が足した hooks だけを外す（ほかの設定はそのまま）
    static func uninstall() {
        for t in targets where FileManager.default.fileExists(atPath: t.file) {
            guard var root = read(t.file) else { continue }
            let before = NSDictionary(dictionary: root)
            strip(&root, t)
            if !before.isEqual(to: root) { _ = write(root, t.file) }
        }
    }

    private static func strip(_ root: inout [String: Any], _ t: Target) {
        if t.style == .named {
            root.removeValue(forKey: "terminail")
            return
        }
        guard var events = root["hooks"] as? [String: Any] else { return }
        for (event, value) in events {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { g in
                guard let hs = g["hooks"] as? [[String: Any]] else { return g }
                let left = hs.filter { !isOurs($0) }
                if left.isEmpty { return nil }
                var g2 = g
                g2["hooks"] = left
                return g2
            }
            if kept.isEmpty { events.removeValue(forKey: event) } else { events[event] = kept }
        }
        if events.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = events }
    }

    /// ない・空のファイルは空の設定として、JSON でないファイルは nil（触らない）
    private static func read(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func write(_ root: [String: Any], _ path: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return false }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    /// 初めて書き換えるときだけ、元のファイルを横に残す
    private static func backup(_ path: String) {
        let b = path + ".terminail-backup"
        let fm = FileManager.default
        if fm.fileExists(atPath: path) && !fm.fileExists(atPath: b) { try? fm.copyItem(atPath: path, toPath: b) }
    }
}

// MARK: - AI のバッジ・アイコン

enum AgentBadge {
    private static var cache: [String: NSImage] = [:]
    private static let font = NSFont.systemFont(ofSize: 9, weight: .semibold)

    /// 設定（agent-icon-claude など）で指定した画像。なければ nil（文字のバッジを出す）
    static func image(_ k: AgentKind, _ config: Config) -> NSImage? {
        let raw = config.string("agent.icon_" + k.rawValue).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        if let img = cache[path] { return img }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = img
        return img
    }

    /// バッジの幅（名前の長さで変わる）
    static func width(_ k: AgentKind, image: NSImage?) -> CGFloat {
        if image != nil { return 14 }
        return ceil(NSAttributedString(string: k.title, attributes: [.font: font]).size().width) + 10
    }

    /// バッジを置く欄の幅。どの AI でも同じ幅にして、その右の様子の位置をそろえる
    static let column: CGFloat = AgentKind.allCases.map { width($0, image: nil) }.max() ?? 40

    /// 上下が反転したビューの中に描いて、使った幅を返す
    static func draw(_ k: AgentKind, image: NSImage?, x: CGFloat, midY: CGFloat) -> CGFloat {
        if let img = image {
            let s: CGFloat = 14
            let r = NSRect(x: x, y: midY - s / 2, width: s, height: s)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).addClip()
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return s
        }
        let col = k.badgeColor
        let str = NSAttributedString(string: k.title, attributes: [.font: font, .foregroundColor: col])
        let tw = ceil(str.size().width)
        let r = NSRect(x: x, y: midY - 7, width: tw + 10, height: 14)
        col.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        let th = ceil(font.ascender - font.descender)
        str.draw(with: NSRect(x: r.minX + 5, y: midY - th / 2, width: tw + 1, height: th), options: [.usesLineFragmentOrigin])
        return r.width
    }
}

// MARK: - カードの並び（AI モードの左の一覧・⌘L ののぞき見）

final class AgentListView: NSView {
    enum Style { case sidebar, peek }
    enum Action { case select(Int), approve(Int, Int), deny(Int, Int) }

    /// カードの中の1行
    struct Row {
        var kind: AgentKind?
        var image: NSImage?
        var status: AgentStatus?
        var label: String
        var text: String
        var time: String
        var ask: Bool
        var pane: Int
        var labelFace = ""
    }

    /// タブ1つぶんのカード（いつも2行：タブの名前と、AI の様子かコマンド）
    struct Card {
        var icon: String
        var color: NSColor
        var name: String
        var active: Bool
        var split: TabBarView.Split
        var row: Row
    }

    let style: Style
    var cards: [Card] = [] {
        didSet {
            updateTimer()
            scrollTarget = clampScroll(scrollTarget)
            scrollY = clampScroll(scrollY)
            if let c = cursor, c >= cards.count { cursor = cards.isEmpty ? nil : cards.count - 1 }
            // 左の一覧：選んでいるタブが見えるところまで、するっとスクロール
            if style == .sidebar, let a = cards.firstIndex(where: { $0.active }), a != shownActive {
                shownActive = a
                reveal(a)
            }
            needsDisplay = true
        }
    }
    private var shownActive = -1
    /// のぞき見で、矢印キーで選んでいるカード
    var cursor: Int? { didSet { if let c = cursor { reveal(c) }; needsDisplay = true } }
    var palette: [NSColor] = []
    var fg: NSColor = .white
    /// 右端の仕切りの線の色（左の一覧だけ。画面分割の線と同じ）
    var divider: NSColor?
    var onAction: ((Action, NSRect) -> Void)?
    /// 上にあけておく高さ（左の一覧では、信号ボタンの行）
    var topInset: CGFloat = 0

    private var hits: [(NSRect, Action)] = []
    private var timer: Timer?

    static let rowH: CGFloat = 18
    static let pad: CGFloat = 4
    /// タブのアイコンの欄の幅（名前はいつもこの右から始まる）
    static let iconW: CGFloat = 18

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 配置

    private static func cardHeight(_ c: Card) -> CGFloat { pad * 2 + rowH * 2 }

    /// 横に並べる数。左の一覧は縦に1列、のぞき見は2列
    /// （のぞき見でもタブが1つなら1列。半分の幅のカードが左に寄らないように）
    var columns: Int { style == .peek ? min(2, max(1, cards.count)) : 1 }

    /// カードの場所（スクロールする前の位置）
    private func cardRects(width: CGFloat) -> [NSRect] {
        let cols = columns
        let gap: CGFloat = style == .peek ? 10 : 3
        let side: CGFloat = style == .peek ? 0 : 8
        let w = (width - side * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
        var out: [NSRect] = []
        var y = topInset
        var i = 0
        while i < cards.count {
            let chunk = Array(cards[i..<min(cards.count, i + cols)])
            let h = chunk.map(Self.cardHeight).max() ?? 0
            for (j, _) in chunk.enumerated() {
                out.append(NSRect(x: side + CGFloat(j) * (w + gap), y: y, width: w, height: h))
            }
            y += h + gap
            i += cols
        }
        return out
    }

    /// 全部のカードを並べたときの高さ
    func contentHeight(width: CGFloat) -> CGFloat {
        (cardRects(width: width).last?.maxY ?? topInset) - topInset
    }

    /// カードのいまの場所（スクロールし終わったときの位置。キラキラはそこから出す）
    func cardRect(_ i: Int) -> NSRect? {
        let rs = cardRects(width: bounds.width)
        return rs.indices.contains(i) ? rs[i].offsetBy(dx: 0, dy: -scrollTarget) : nil
    }

    // MARK: スクロール（カードが入りきらないとき。マウスのホイールでもトラックパッドでも、なめらかに）

    private var scrollY: CGFloat = 0          // いま描いている位置
    private var scrollTarget: CGFloat = 0     // 向かっている位置
    private var scrollTimer: Timer?

    private var maxScroll: CGFloat {
        max(0, contentHeight(width: bounds.width) + topInset + 8 - bounds.height)
    }

    private func clampScroll(_ v: CGFloat) -> CGFloat { min(max(0, v), maxScroll) }

    override func scrollWheel(with e: NSEvent) {
        guard maxScroll > 0 else { return }
        if e.hasPreciseScrollingDeltas {
            // トラックパッド・Magic Mouse：指の動きにそのままついていく（慣性もそのまま）
            scrollTimer?.invalidate()
            scrollTimer = nil
            scrollTarget = clampScroll(scrollTarget - e.scrollingDeltaY)
            scrollY = scrollTarget
            needsDisplay = true
        } else {
            // ホイールのマウス：1目盛りぶん先へ、するっと動かす
            scrollTarget = clampScroll(scrollTarget - e.scrollingDeltaY * 24)
            animateScroll()
        }
    }

    /// カード i が見えるところまでスクロールする
    func reveal(_ i: Int) {
        let rs = cardRects(width: bounds.width)
        guard rs.indices.contains(i), bounds.height > 0 else { return }
        let r = rs[i]
        var t = scrollTarget
        if r.minY - t < topInset { t = r.minY - topInset }
        if r.maxY - t > bounds.height - 8 { t = r.maxY - bounds.height + 8 }
        t = clampScroll(t)
        guard t != scrollTarget else { return }
        scrollTarget = t
        animateScroll()
    }

    private func animateScroll() {
        guard scrollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let d = self.scrollTarget - self.scrollY
            if abs(d) < 0.5 {
                self.scrollY = self.scrollTarget
                self.scrollTimer?.invalidate()
                self.scrollTimer = nil
            } else {
                self.scrollY += d * 0.22
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        scrollTimer = t
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scrollTarget = clampScroll(scrollTarget)
        scrollY = clampScroll(scrollY)
    }

    // MARK: のぞき見の矢印キー

    /// 矢印キーで選ぶカードを動かす（左右は端で反対側へ回る、上下は端で止まる）
    func moveCursor(_ d: Int) {
        let n = cards.count
        guard n > 0 else { return }
        let c = cursor ?? cards.firstIndex(where: { $0.active }) ?? 0
        var next = c + d
        if !(0..<n).contains(next) {
            guard abs(d) == 1 else { return }
            next = (next + n) % n
        }
        cursor = next
    }

    /// エンター：選んでいるカードのタブを表示
    func activateCursor() {
        guard let c = cursor, let r = cardRect(c) else { return }
        onAction?(.select(c), r)
    }

    // MARK: 動き（考え中の点・承認待ちの点滅）

    private func updateTimer() {
        let need = window != nil && !isHiddenOrHasHiddenAncestor
            && cards.contains { $0.row.status == .thinking || $0.row.status == .approval }
        if need && timer == nil {
            let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !need {
            timer?.invalidate()
            timer = nil
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateTimer() }
    override func viewDidHide() { super.viewDidHide(); updateTimer() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateTimer() }

    private var pulse: CGFloat { CGFloat(0.5 + 0.5 * sin(CACurrentMediaTime() * 4.5)) }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        hits.removeAll()
        let rects = cardRects(width: bounds.width)
        // スクロールしたカードは、上の余白（信号ボタンの行）や外にはみ出さないように切る
        let area = NSRect(x: 0, y: topInset, width: bounds.width, height: max(0, bounds.height - topInset))
        NSGraphicsContext.saveGraphicsState()
        area.clip()
        for (i, (c, r)) in zip(cards, rects).enumerated() {
            let sr = r.offsetBy(dx: 0, dy: -scrollY)
            if sr.maxY < area.minY || sr.minY > area.maxY { continue }
            drawCard(c, i, sr)
        }
        NSGraphicsContext.restoreGraphicsState()
        if style == .sidebar, let col = divider {
            PaneContainer.drawDivider(NSRect(x: bounds.maxX - 1, y: 10, width: 1, height: max(0, bounds.height - 20)),
                                      color: col, vertical: false)
        }
    }

    private func text(_ s: String, _ font: NSFont, _ color: NSColor, _ r: NSRect, center: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        if center { para.alignment = .center }
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let h = ceil(font.ascender - font.descender)
        str.draw(with: NSRect(x: r.minX, y: r.midY - h / 2, width: max(0, r.width), height: h),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func width(_ s: String, _ font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
    }

    private func drawCard(_ c: Card, _ i: Int, _ r: NSRect) {
        let shape = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
        if c.active {
            fg.withAlphaComponent(0.10).setFill()
            shape.fill()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5)
            ring.lineWidth = 1
            c.color.withAlphaComponent(0.4).setStroke()
            ring.stroke()
        } else if style == .peek {
            fg.withAlphaComponent(0.05).setFill()
            shape.fill()
        }
        if style == .peek && cursor == i {     // 矢印キーで選んでいるカード
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            ring.lineWidth = 2
            fg.withAlphaComponent(0.7).setStroke()
            ring.stroke()
        }
        hits.append((r, .select(i)))

        // 1行目：タブのアイコンと名前（分割していれば分割のしるし）
        let nameRow = NSRect(x: r.minX + 10, y: r.minY + Self.pad, width: r.width - 20, height: Self.rowH)
        // 承認待ちのタブは、アイコンと名前を薄い紫で点滅させる
        let asking = c.row.status == .approval
        let askCol = AgentStatus.approval.color(palette).withAlphaComponent(0.45 + 0.55 * pulse)
        let iconCol = asking ? askCol : c.color
        let nameFont = NSFont.systemFont(ofSize: 11, weight: c.active ? .semibold : .medium)   // 様子の行（Done など）と同じ大きさ
        if !c.icon.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
            // アイコンの記号は形も大きさもまちまちなので、見えている形のまん中を、名前の文字の高さのまん中に合わせる。
            // 文字の並びの基準線（ベースライン）を自分で決めて描く（フォントが替わっても、位置がずれないように）
            let key = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
            let str = NSAttributedString(string: c.icon, attributes: [.font: NSFont.systemFont(ofSize: 12), key: true])
            let line = CTLineCreateWithAttributedString(str)
            let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let textH = ceil(nameFont.ascender - nameFont.descender)
            let baseline = nameRow.midY - textH / 2 + nameFont.ascender        // 名前の文字のベースライン
            let center = NSPoint(x: nameRow.minX + Self.iconW / 2, y: baseline - nameFont.capHeight / 2)
            ctx.saveGState()
            if c.active || asking { ctx.setShadow(offset: .zero, blur: 6, color: iconCol.withAlphaComponent(0.9).cgColor) }
            ctx.setFillColor(iconCol.cgColor)
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // 上下が反転したビューの中なので、文字を正しい向きに
            ctx.textPosition = CGPoint(x: center.x - ink.midX, y: center.y + ink.midY)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        var nameRight = nameRow.maxX
        if c.split != .none, let img = Self.splitImage(c.split, color: fg.withAlphaComponent(0.55)) {
            let s = img.size
            let ir = NSRect(x: nameRow.maxX - s.width, y: nameRow.midY - s.height / 2, width: s.width, height: s.height)
            img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            nameRight = ir.minX - 6
        }
        // 考えている時間（考え中のときだけ）
        if !c.row.time.isEmpty {
            let tf = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            let w = width(c.row.time, tf)
            let col = c.row.status?.color(palette) ?? fg
            text(c.row.time, tf, col.withAlphaComponent(0.85), NSRect(x: nameRight - w, y: nameRow.minY, width: w + 1, height: Self.rowH))
            nameRight -= w + 8
        }
        text(c.name, nameFont, asking ? askCol : (c.active ? fg : fg.withAlphaComponent(0.75)),
             NSRect(x: nameRow.minX + Self.iconW + 6, y: nameRow.minY, width: nameRight - nameRow.minX - Self.iconW - 6, height: Self.rowH))

        // 2行目：AI の様子（AI がいなければ、動いているコマンドかフォルダ）
        drawRow(c.row, i, NSRect(x: nameRow.minX, y: nameRow.maxY, width: nameRow.width, height: Self.rowH))
    }

    private func drawRow(_ row: Row, _ card: Int, _ r: NSRect) {
        let font = NSFont.systemFont(ofSize: 11)
        let mid = r.midY
        var x = r.minX
        var right = r.maxX

        // 承認・拒否のボタン（右端）
        if row.ask {
            let deny = NSRect(x: right - 22, y: mid - 9, width: 22, height: 18)
            let ok = NSRect(x: deny.minX - 26, y: mid - 9, width: 22, height: 18)
            drawButton(ok, approve: true)
            drawButton(deny, approve: false)
            hits.append((ok, .approve(card, row.pane)))
            hits.append((deny, .deny(card, row.pane)))
            right = ok.minX - 6
        }
        // AI のバッジ（欄の幅はどの AI でも同じ。様子の位置がそろう）
        if let k = row.kind {
            _ = AgentBadge.draw(k, image: row.image, x: x, midY: mid)
            x += AgentBadge.column + 6
        }
        // 状態（考え中は弾む点、ほかは色の点）と名前。点の欄も同じ幅にする
        if let s = row.status {
            let col = s.color(palette)
            if s == .thinking {
                let t = CACurrentMediaTime()
                for k in 0..<3 {
                    let a = 0.3 + 0.7 * max(0, sin(t * 7 - Double(k) * 0.9))
                    col.withAlphaComponent(CGFloat(a)).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x + CGFloat(k) * 5, y: mid - 1.5, width: 3, height: 3)).fill()
                }
            } else {
                let a: CGFloat = s == .approval ? 0.45 + 0.55 * pulse : 1
                col.withAlphaComponent(a).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + 4.5, y: mid - 3, width: 6, height: 6)).fill()
            }
            x += 19
            if !row.label.isEmpty {
                let lf = NSFont.systemFont(ofSize: 11, weight: .semibold)
                let w = width(row.label, lf)
                text(row.label, lf, col, NSRect(x: x, y: r.minY, width: w + 1, height: r.height))
                x += w + 6
            }
            if !row.labelFace.isEmpty {     // 顔文字は少しあけて、ほんの少し上げる（記号のフォントは下がって見えるので）
                let ff = NSFont.systemFont(ofSize: 11)
                let w = width(row.labelFace, ff)
                x += 3
                text(row.labelFace, ff, col, NSRect(x: x, y: r.minY - 1.5, width: w + 1, height: r.height))
                x += w + 6
            }
        }
        // 一言（やっていること・承認の中身・コマンド）
        if x < right {
            let col = row.ask ? (AgentStatus.approval.color(palette)) : fg.withAlphaComponent(0.6)
            text(row.text, font, col, NSRect(x: x, y: r.minY, width: right - x, height: r.height))
        }
    }

    private func drawButton(_ r: NSRect, approve: Bool) {
        let shape = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        let mark = NSBezierPath()
        mark.lineWidth = 1.8
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        if approve {
            AgentStatus.approval.color(palette).setFill()
            shape.fill()
            mark.move(to: NSPoint(x: r.midX - 4, y: r.midY))
            mark.line(to: NSPoint(x: r.midX - 1, y: r.midY + 3))
            mark.line(to: NSPoint(x: r.midX + 4.5, y: r.midY - 3.5))
            NSColor(white: 0.1, alpha: 0.9).setStroke()
        } else {
            fg.withAlphaComponent(0.3).setStroke()
            shape.lineWidth = 1
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5).stroke()
            mark.move(to: NSPoint(x: r.midX - 3, y: r.midY - 3))
            mark.line(to: NSPoint(x: r.midX + 3, y: r.midY + 3))
            mark.move(to: NSPoint(x: r.midX + 3, y: r.midY - 3))
            mark.line(to: NSPoint(x: r.midX - 3, y: r.midY + 3))
            fg.withAlphaComponent(0.85).setStroke()
        }
        mark.stroke()
    }

    static func splitImage(_ kind: TabBarView.Split, color: NSColor) -> NSImage? {
        let name: String
        switch kind {
        case .none: return nil
        case .sideBySide: name = "rectangle.split.2x1"
        case .stacked: name = "rectangle.split.1x2"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: "split")?.withSymbolConfiguration(cfg)
    }

    // MARK: クリック

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if style == .sidebar && p.y < topInset - 2 {      // 信号ボタンの行はウィンドウ移動
            window?.performDrag(with: e)
            return
        }
        guard p.y >= topInset else { return }
        for (r, a) in hits.reversed() where r.contains(p) {
            onAction?(a, r)
            return
        }
    }
}

// MARK: - ⌘L ののぞき見

final class AgentPeekView: NSView {
    let list = AgentListView(style: .peek)
    var onClose: (() -> Void)?
    var bg: NSColor = .black
    var fg: NSColor = .white
    var header = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(list)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// まん中のパネル。カードが1列ならパネルも細くして、カードがまん中に来るように
    private var panel: NSRect {
        let w = max(200, min(list.columns == 1 ? 400 : 760, bounds.width - 48))
        let h = max(120, min(bounds.height - 48, list.contentHeight(width: w - 32) + 88))
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// カードの数や大きさが変わったら、並べ直す
    func place() {
        let p = panel
        list.frame = NSRect(x: p.minX + 16, y: p.minY + 50, width: p.width - 32, height: p.height - 88)
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let p = panel
        let shape = NSBezierPath(roundedRect: p, xRadius: 18, yRadius: 18)
        bg.withAlphaComponent(0.96).setFill()
        shape.fill()
        shape.lineWidth = 1
        fg.withAlphaComponent(0.14).setStroke()
        shape.stroke()
        let title = NSMutableAttributedString(string: "✦ Agents", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: fg])
        title.append(NSAttributedString(string: "   " + header, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: fg.withAlphaComponent(0.6)]))
        title.draw(with: NSRect(x: p.minX + 20, y: p.minY + 18, width: p.width - 40, height: 20), options: [.usesLineFragmentOrigin])
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        NSAttributedString(string: "Arrow keys to move · Return to jump · Esc to close", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: fg.withAlphaComponent(0.5), .paragraphStyle: para])
            .draw(with: NSRect(x: p.minX, y: p.maxY - 28, width: p.width, height: 16), options: [.usesLineFragmentOrigin])
    }

    override func mouseDown(with e: NSEvent) {
        if !panel.contains(convert(e.locationInWindow, from: nil)) { onClose?() }
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: onClose?()                                  // Esc
        case 123: list.moveCursor(-1)                        // ←
        case 124: list.moveCursor(1)                         // →
        case 125: list.moveCursor(list.columns)              // ↓
        case 126: list.moveCursor(-list.columns)             // ↑
        case 36, 76: list.activateCursor()                   // Return・テンキーの Enter
        default: super.keyDown(with: e)
        }
    }
}

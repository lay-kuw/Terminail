import AppKit
import QuartzCore

/// タブ1つぶん（ターミナル本体と、アイコンの番号・表示名）
final class Tab {
    let view: TerminalView
    var slot: Int          // アイコンの番号（開いた順。閉じたら空いた番号をまた使う。1つに戻ったら 0 に）
    var name = ""
    var running: String?              // いま前面で動いているコマンド
    var startedAt: CFTimeInterval = 0
    var alert = false                 // 裏で長いコマンドが終わった（タブのアイコンが光る）
    init(view: TerminalView, slot: Int) { self.view = view; self.slot = slot }
}

/// ターミナルのウィンドウ1枚ぶん（すりガラス・背景色・タブたちをまとめたもの）。
/// どのウィンドウも同じ扱い：ホットキーで出し入れ、赤ボタンで閉じる。
final class TermWindow: NSObject, NSWindowDelegate {
    let window: AppWindow
    let box: NSView
    let effect: GlassView
    let tint: NSView
    let tabBar: TabBarView
    private(set) var tabs: [Tab] = []
    private(set) var active = 0
    private var config: Config
    private var colors: Colors          // 設定から作った色（キー入力のたびに作り直さないよう、ここに持っておく）
    private var nameTimer: Timer?
    private var closing = false
    private var fontDelta: CGFloat = 0          // ⌘+ / ⌘- の差（このウィンドウのタブ全部に効く）
    private var searchBar: SearchBar?
    private var searchWork: DispatchWorkItem?
    let seq: Int                   // 開いた順番（Window メニューの番号付けに使う）
    private static var nextSeq = 0

    /// いま前に出ているタブのターミナル
    var termView: TerminalView { tabs[active].view }

    var onBell: ((TermWindow) -> Void)?
    var onEnter: ((TermWindow, NSRect) -> Void)?
    var onType: ((TermWindow, NSRect) -> Void)?
    var onDelete: ((TermWindow, NSRect) -> Void)?
    var onClosed: ((TermWindow) -> Void)?        // ウィンドウが閉じた（赤ボタン・最後のタブで exit）
    var onCommandFinished: ((TermWindow, Tab, String, Double) -> Void)?   // 長いコマンドが終わった

    /// ウィンドウのふち全体が光る枠（tab-colors = edge）
    private let edge = EdgeGlowView()
    /// スクロール位置の「すべる光」と、一番下へ戻るボタン
    private let scrollGlow = ScrollGlowView()
    private let jump = JumpButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))

    /// タブの色でキラキラを描くか（そのときは白を混ぜない）
    var sparklesTinted: Bool {
        let m = config.string("tabs.colors")
        return m == "cursor" || m == "edge"
    }

    /// 演出に使う色。tab-colors が cursor / edge ならいまのタブの色
    var accent: NSColor {
        let m = config.string("tabs.colors")
        return (m == "cursor" || m == "edge") ? tabColor(tabs[active]) : colors.cursor
    }

    /// ✦ 白 ☾ 紫 ♪ 水色 ♡ 赤 ✿ ピンク ☘ 緑 ❄ 青（テーマの色から）
    func tabColor(_ t: Tab) -> NSColor {
        let p = colors.palette
        switch t.slot % 7 {
        case 0: return p[15]                    // 白
        case 1: return p[5]                     // 紫
        case 2: return p[6]                     // 水色
        case 3: return p[1]                     // 赤
        case 4:                                 // ピンク（テーマにないので、赤と紫を混ぜて少し明るく）
            let pink = p[1].blended(withFraction: 0.45, of: p[5]) ?? p[1]
            return pink.blended(withFraction: 0.15, of: .white) ?? pink
        case 5: return p[2]                     // 緑
        default: return p[4]                    // 青
        }
    }

    init(config: Config) {
        self.config = config
        self.colors = Colors(config)
        TermWindow.nextSeq += 1
        self.seq = TermWindow.nextSeq
        let w = CGFloat(max(300, min(10000, config.double("window.width"))))
        let h = CGFloat(max(200, min(10000, config.double("window.height"))))
        window = AppWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        box = NSView(frame: root.bounds)
        effect = GlassView(frame: box.bounds)
        tint = NSView(frame: box.bounds)
        tabBar = TabBarView(frame: NSRect(x: 0, y: box.bounds.height - 28, width: box.bounds.width, height: 28))
        super.init()

        window.title = "Terminail"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 300, height: 160)
        window.delegate = self

        root.wantsLayer = true
        box.autoresizingMask = [.width, .height]
        box.wantsLayer = true
        box.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tabBar.autoresizingMask = [.width, .minYMargin]
        tabBar.isHidden = true
        tabBar.onSelect = { [weak self] i in self?.select(i) }
        box.addSubview(effect)
        box.addSubview(tint)
        box.addSubview(tabBar)
        scrollGlow.frame = NSRect(x: box.bounds.width - 24, y: 0, width: 24, height: box.bounds.height)
        scrollGlow.autoresizingMask = [.minXMargin, .height]
        scrollGlow.onDrag = { [weak self] f, jump in self?.termView.scroll(toFraction: f, animated: jump) }
        scrollGlow.canScroll = { [weak self] in
            guard let v = self?.termView else { return false }
            return !v.term.isAlt && v.term.scrollback.count > 0
        }
        box.addSubview(scrollGlow)
        jump.setFrameOrigin(NSPoint(x: box.bounds.width - 35, y: 4))
        jump.autoresizingMask = [.minXMargin, .maxYMargin]
        jump.onClick = { [weak self] in self?.termView.scrollToBottom() }
        box.addSubview(jump)
        edge.frame = box.bounds
        edge.autoresizingMask = [.width, .height]
        box.addSubview(edge)
        root.addSubview(box)
        window.contentView = root

        let first = makeTab()
        tabs.append(first)
        show(first.view)
        // 1秒ごとにタブ名の更新と、長いコマンドが終わったかの確認
        let tm = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(tm, forMode: .common)
        nameTimer = tm

        // マスの数でウィンドウの大きさを決められる
        let cols = config.int("window.columns", 0, 1000), rows = config.int("window.rows", 0, 500)
        if cols > 0 && rows > 0 { window.setContentSize(first.view.sizeFor(cols: cols, rows: rows)) }
        updateTabBar()
    }

    var blurRadius: Int { Int(max(0, min(100, config.number("window.blur", ifTrue: 20)))) }

    func startShell() { termView.startShell() }

    func apply(_ c: Config) {
        config = c
        colors = Colors(c)
        for t in tabs { t.view.apply(c) }
        let corner = CGFloat(max(0, min(40, c.double("window.corner_radius"))))
        window.cornerRadius = corner
        box.layer?.cornerRadius = corner
        effect.corner = corner
        let op = CGFloat(max(0, min(1, c.double("window.opacity"))))
        tint.layer?.backgroundColor = colors.background.withAlphaComponent(op).cgColor
        setBlur(blurRadius)
        switch c.string("window.appearance") {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "auto": window.appearance = nil
        default: window.appearance = NSAppearance(named: .darkAqua)
        }
        window.level = c.bool("window.always_on_top") ? .floating : .normal
        updateTabBar()
    }

    /// ぼかしの強さ。layer（標準のすりガラスを調整・角丸OK）か window（WindowServer に任せる）
    func setBlur(_ r: Int) {
        if config.string("window.blur_mode") == "window", WindowBlur.set(window, radius: r) {
            effect.isHidden = true
        } else {
            WindowBlur.set(window, radius: 0)
            effect.isHidden = r == 0
            effect.radius = r
        }
    }

    // MARK: - タブ

    private func makeTab() -> Tab {
        let used = Set(tabs.map(\.slot))
        var slot = 0
        while used.contains(slot) { slot += 1 }
        let v = TerminalView(frame: box.bounds, config: config)
        v.autoresizingMask = [.width, .height]
        v.fontDelta = fontDelta
        let tab = Tab(view: v, slot: slot)
        v.onBell = { [weak self, weak v] in if let s = self, v === s.termView { s.onBell?(s) } }
        v.onEnter = { [weak self, weak v] r in if let s = self, v === s.termView { s.onEnter?(s, r) } }
        v.onType = { [weak self, weak v] r in if let s = self, v === s.termView { s.onType?(s, r) } }
        v.onDelete = { [weak self, weak v] r in if let s = self, v === s.termView { s.onDelete?(s, r) } }
        v.onViewOffsetChanged = { [weak self, weak v] in if let s = self, v === s.termView { s.updateScrollUI(kick: false) } }
        v.onUserScroll = { [weak self, weak v] in if let s = self, v === s.termView { s.updateScrollUI(kick: true) } }
        v.onMatchesChanged = { [weak self, weak v] in if let s = self, v === s.termView { s.updateSearchCount() } }
        v.onLogError = { [weak self] url, err in self?.showLogError(url, err) }
        v.onShellExit = { [weak self, weak tab] in if let s = self, let t = tab { s.tabExited(t) } }
        return tab
    }

    /// ⌘T：いまのタブの右に新しいタブを開く
    func newTab() {
        let t = makeTab()
        t.view.apply(config)
        tabs.insert(t, at: active + 1)
        select(active + 1)
        t.view.startShell()
    }

    func select(tab t: Tab) {
        if let i = tabs.firstIndex(where: { $0 === t }) { select(i) }
    }

    func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        if i != active { closeSearch(); scrollGlow.hide() }
        let old = termView
        active = i
        if old !== termView { old.removeFromSuperview() }
        show(termView)
        if tabs[active].alert && window.isKeyWindow { tabs[active].alert = false }
        updateTabBar()
    }

    func selectNext() { if tabs.count > 1 { select((active + 1) % tabs.count) } }
    func selectPrevious() { if tabs.count > 1 { select((active - 1 + tabs.count) % tabs.count) } }

    /// 前に出すタブだけをウィンドウに入れる（ほかのタブはシェルを動かしたまま裏で待機）
    private func show(_ v: TerminalView) {
        if v.superview !== box {
            v.frame = box.bounds
            box.addSubview(v, positioned: .above, relativeTo: tint)
        }
        window.makeFirstResponder(v)
        v.needsDisplay = true
    }

    /// exit でタブのシェルが終わった：そのタブを閉じる。最後のタブならウィンドウごと閉じる
    private func tabExited(_ t: Tab) {
        guard !closing, let i = tabs.firstIndex(where: { $0 === t }) else { return }
        if tabs.count == 1 {
            window.close()
            return
        }
        let wasActive = i == active
        if wasActive { closeSearch() }
        tabs.remove(at: i)
        t.view.removeFromSuperview()
        if i < active || active >= tabs.count { active = max(0, active - 1) }
        // 1つに戻ったら、開いたばかりのウィンドウと同じ状態に（✦・白、光っていたのも消す）
        if tabs.count == 1 {
            tabs[0].slot = 0
            tabs[0].alert = false
        }
        if wasActive { show(termView) }
        updateTabBar()
    }

    /// タブを見たら光るのを止める
    private func clearAlert() {
        guard tabs.indices.contains(active), tabs[active].alert, window.isKeyWindow else { return }
        tabs[active].alert = false
        updateTabBar()
    }

    // MARK: - スクロール位置の表示

    private func updateScrollUI(kick: Bool) {
        let v = termView
        scrollGlow.color = accent
        scrollGlow.topInset = (barVisible ? tabBar.frame.height : 28) + 6
        scrollGlow.setTarget(v.scrollFraction)
        if kick { scrollGlow.kick() }
        jump.color = accent
        jump.setShown(v.viewOffset > 0)
    }

    // MARK: - 文字サイズ（その場だけ）

    func zoom(_ step: CGFloat) {
        fontDelta = step == 0 ? 0 : max(-8, min(40, fontDelta + step))
        for t in tabs { t.view.fontDelta = fontDelta }
    }

    // MARK: - 検索（⌘F）

    /// ⌘F：検索窓を出す。出ているときにもう一度押すと閉じる
    func showSearch() {
        if searchBar != nil {
            closeSearch()
            return
        }
        let bar = SearchBar(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        let c = colors
        bar.style(fg: c.foreground, bg: c.background)
        bar.onChange = { [weak self, weak bar] q in
            // 打つたびに全部探すと、出力が流れているときに重くなるので、打ち終わるのを少し待つ
            guard let self else { return }
            self.searchWork?.cancel()
            let w = DispatchWorkItem { [weak self, weak bar] in
                guard let self else { return }
                let n = self.termView.search(q)
                bar?.setCount(n == 0 ? (q.isEmpty ? "" : "0") : "\(self.termView.currentMatchNumber)/\(n)")
            }
            self.searchWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        }
        bar.onStep = { [weak self, weak bar] older in
            guard let self else { return }
            let v = self.termView
            v.nextMatch(older: older)
            if v.matchCount > 0 { bar?.setCount("\(v.currentMatchNumber)/\(v.matchCount)") }
        }
        bar.onClose = { [weak self] in self?.closeSearch() }
        bar.autoresizingMask = [.minXMargin, .minYMargin]
        searchBar = bar
        layoutSearch()
        box.addSubview(bar, positioned: .above, relativeTo: tabBar)
        window.makeFirstResponder(bar.field)
    }

    /// ⌘K：いまのタブの画面と履歴を消す
    func clearScrollback() {
        closeSearch()
        termView.clearScrollback()
    }

    private func updateSearchCount() {
        guard let bar = searchBar else { return }
        let v = termView
        bar.setCount(v.matchCount == 0 ? "" : "\(v.currentMatchNumber)/\(v.matchCount)")
    }

    private func showLogError(_ url: URL, _ err: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Logging stopped"
        a.informativeText = "Couldn't write to \(url.path)\n\(err.localizedDescription)\n\nOutput after this point was not saved."
        a.beginSheetModal(for: window)
    }

    func closeSearch() {
        searchWork?.cancel()
        guard let bar = searchBar else { return }
        bar.removeFromSuperview()
        searchBar = nil
        termView.clearSearch()
        window.makeFirstResponder(termView)
    }

    private func layoutSearch() {
        guard let bar = searchBar else { return }
        let top = barVisible ? tabBar.frame.height : 28
        bar.setFrameOrigin(NSPoint(x: box.bounds.width - bar.frame.width - 10, y: box.bounds.height - top - bar.frame.height - 4))
    }

    // MARK: - ログ

    var isLogging: Bool { termView.isLogging }
    func startLog(to url: URL) -> Bool { termView.startLog(to: url) }
    func stopLog() { termView.stopLog() }

    // MARK: - タブバー

    private var barVisible: Bool {
        tabs.count > 1 || config.string("tabs.bar") == "always"
    }

    private func updateTabBar() {
        let visible = barVisible
        let style: TabBarView.Style = config.string("tabs.style") == "pill" ? .pill : .dots
        let extra: CGFloat = visible && style == .dots ? TabBarView.nameLine : 0
        tabBar.isHidden = !visible
        let h = 28 + extra
        tabBar.frame = NSRect(x: 0, y: box.bounds.height - h, width: box.bounds.width, height: h)
        for t in tabs { t.view.extraTop = extra }
        if visible { refreshNames() }
        let c = colors
        let mode = config.string("tabs.colors")
        let colored = mode == "cursor" || mode == "edge" || mode == "icon"
        tabBar.style = style
        tabBar.items = tabs.map { TabBarView.Item(icon: icon(for: $0.slot, style: style), name: $0.name,
                                                  color: colored ? tabColor($0) : nil, alert: $0.alert) }
        // カーソル・キラキラの色
        for t in tabs { t.view.tabColor = (mode == "cursor" || mode == "edge") ? tabColor(t) : nil }
        // ふち全体が発光する枠。タブが2つ以上のときだけ、じわっと光って、じわっと消える
        edge.corner = CGFloat(max(0, min(40, config.double("window.corner_radius"))))
        edge.color = tabColor(tabs[active])
        edge.setLit(mode == "edge" && tabs.count > 1)
        tabBar.active = active
        tabBar.fg = c.foreground
        tabBar.accent = c.cursor
        tabBar.needsDisplay = true
        layoutSearch()
        updateScrollUI(kick: false)
    }

    /// 長いコマンドが終わったかを調べる（終わったら通知）。タブバーが出ていればタブ名も更新
    private func poll() {
        let now = CACurrentMediaTime()
        let after = max(1, config.double("notify.after"))
        let ignore = Set(config.strings("notify.ignore").map { $0.lowercased() })
        let styles = Set(config.strings("notify.style"))
        var alertChanged = false
        for (i, t) in tabs.enumerated() {
            let fg = t.view.pty.foregroundCommand
            if let cmd = fg {
                if t.running == nil { t.startedAt = now }
                t.running = cmd
            } else if let cmd = t.running {
                t.running = nil
                let took = now - t.startedAt
                // いままさにそのタブを見ているなら知らせない
                let looking = NSApp.isActive && window.isKeyWindow && window.isVisible && i == active
                if took >= after && !looking && !ignore.contains(cmd.lowercased()) && !styles.contains("off") {
                    if styles.contains("tab") && !(i == active && window.isKeyWindow) { t.alert = true; alertChanged = true }
                    onCommandFinished?(self, t, cmd, took)
                }
            }
        }
        if alertChanged { updateTabBar() }
        if barVisible { refreshNames() }
    }

    /// タブ名：シェルがいるフォルダ。何か動いていればそのコマンド名
    private func refreshNames() {
        var changed = false
        for t in tabs {
            // 前面のコマンドは poll() で調べたものを使う（同じ情報を2回取りにいかない）
            let n = t.running ?? t.view.pty.currentDirectory ?? "shell"
            if n != t.name { t.name = n; changed = true }
        }
        guard changed else { return }
        for (i, t) in tabs.enumerated() where i < tabBar.items.count { tabBar.items[i].name = t.name }
        tabBar.needsDisplay = true
    }

    static let symbolIcons = ["✦", "☾", "♪", "♡", "✿", "☘", "❄"]

    /// 通知に出すアイコン（記号のときだけ）
    func iconText(_ t: Tab) -> String {
        let s = icon(for: t.slot, style: .pill)
        return s.isEmpty || s == "●" ? "✦" : s
    }

    private func icon(for slot: Int, style: TabBarView.Style) -> String {
        let list: [String]
        switch config.string("tabs.icons") {
        case "none": list = []
        case "custom":
            let custom = config.strings("tabs.icon_list")
            list = custom.isEmpty ? Self.symbolIcons : custom
        default: list = Self.symbolIcons
        }
        if list.isEmpty { return style == .dots ? "●" : "" }
        let s = list[slot % list.count]
        // 記号が絵文字の見た目にならないように（テキスト表示を指定）
        return s.hasSuffix("\u{FE0E}") ? s : s + "\u{FE0E}"
    }

    // MARK: - 閉じる

    func terminateAll() {
        closing = true
        for t in tabs { t.view.stopLog(); t.view.pty.terminate() }
    }

    func windowWillClose(_ notification: Notification) {
        nameTimer?.invalidate()
        nameTimer = nil
        tabBar.stopPulse()
        scrollGlow.hide()
        terminateAll()
        onClosed?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) { termView.needsDisplay = true; clearAlert() }
    func windowDidResignKey(_ notification: Notification) { termView.needsDisplay = true }
}

/// 信号ボタンの行に描くタブバー。
/// dots：真ん中にアイコンが並び、その下に今のタブの名前。pill：信号ボタンの右に、名前入りの丸いタブ。
final class TabBarView: NSView {
    enum Style { case dots, pill }
    struct Item { var icon: String; var name: String; var color: NSColor? = nil; var alert = false }

    static let nameLine: CGFloat = 14     // dots のタブ名の行の高さ

    var style: Style = .dots
    var items: [Item] = [] { didSet { updatePulse() } }
    private var pulseTimer: Timer?

    /// 光っているタブがあるあいだだけ、ゆっくり明滅させる
    private func updatePulse() {
        let need = items.contains { $0.alert } && !isHidden
        if need && pulseTimer == nil {
            let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            RunLoop.main.add(t, forMode: .common)
            pulseTimer = t
        } else if !need {
            pulseTimer?.invalidate()
            pulseTimer = nil
        }
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    /// ウィンドウから外れたら、明滅のタイマーも止める
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopPulse() }
    }

    private var pulse: CGFloat { CGFloat(0.5 + 0.5 * sin(CACurrentMediaTime() * 4.5)) }
    var active = 0
    var fg: NSColor = .white
    var accent: NSColor = .white
    var onSelect: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    // MARK: 配置

    private func rects() -> [NSRect] {
        let n = items.count
        guard n > 0 else { return [] }
        switch style {
        case .dots:
            let step: CGFloat = 22
            let x0 = bounds.midX - step * CGFloat(n) / 2
            return (0..<n).map { NSRect(x: x0 + step * CGFloat($0), y: 4, width: step, height: 20) }
        case .pill:
            let left: CGFloat = 78, gap: CGFloat = 4
            let avail = max(40, bounds.width - left - 10)
            let w = min(170, (avail - gap * CGFloat(n - 1)) / CGFloat(n))
            return (0..<n).map { NSRect(x: left + (w + gap) * CGFloat($0), y: 4, width: w, height: 20) }
        }
    }

    /// タブの上だけクリックを受ける（ほかの所はターミナル側でウィンドウ移動になる）
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sv = superview else { return nil }
        let p = convert(point, from: sv)
        return rects().contains(where: { $0.contains(p) }) ? self : nil
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = rects().firstIndex(where: { $0.contains(p) }) { onSelect?(i) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        let rs = rects()
        switch style {
        case .dots: drawDots(rs)
        case .pill: drawPills(rs)
        }
    }

    private func centered(_ s: String, font: NSFont, color: NSColor, in r: NSRect, glow: NSColor? = nil) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        if let g = glow {
            let sh = NSShadow()
            sh.shadowColor = g
            sh.shadowBlurRadius = 6
            sh.shadowOffset = .zero
            attrs[.shadow] = sh
        }
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = ceil(font.ascender - font.descender)
        let box = NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
        str.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawDots(_ rs: [NSRect]) {
        for (i, r) in rs.enumerated() {
            let on = i == active
            let it = items[i]
            let size: CGFloat = it.icon == "●" ? 7 : 13
            let col = it.color ?? accent
            if it.alert && !on {
                let p = pulse
                centered(it.icon, font: .systemFont(ofSize: size), color: col.withAlphaComponent(0.35 + 0.65 * p), in: r,
                         glow: col.withAlphaComponent(p))
            } else {
                centered(it.icon, font: .systemFont(ofSize: size),
                         color: on ? col : fg.withAlphaComponent(0.32), in: r,
                         glow: on ? col.withAlphaComponent(0.9) : nil)
            }
        }
        guard items.indices.contains(active) else { return }
        let line = NSRect(x: 80, y: 26, width: max(0, bounds.width - 160), height: TabBarView.nameLine)
        centered(items[active].name, font: .systemFont(ofSize: 10.5), color: fg.withAlphaComponent(0.6), in: line)
    }

    private func drawPills(_ rs: [NSRect]) {
        for (i, r) in rs.enumerated() {
            let on = i == active
            if on {
                fg.withAlphaComponent(0.14).setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
            let it = items[i]
            let font = NSFont.systemFont(ofSize: 11, weight: on ? .medium : .regular)
            let textCol = on ? fg : fg.withAlphaComponent(0.45)
            // アイコンだけタブの色（光るときは明滅）
            let str = NSMutableAttributedString()
            if !it.icon.isEmpty {
                var ic = it.color.map { on ? $0 : $0.withAlphaComponent(0.6) } ?? textCol
                if it.alert && !on { ic = (it.color ?? accent).withAlphaComponent(0.35 + 0.65 * pulse) }
                str.append(NSAttributedString(string: it.icon + " ", attributes: [.font: font, .foregroundColor: ic]))
            }
            str.append(NSAttributedString(string: it.name, attributes: [.font: font, .foregroundColor: textCol]))
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            str.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: str.length))
            let inner = r.insetBy(dx: 10, dy: 0)
            let h = ceil(font.ascender - font.descender)
            str.draw(with: NSRect(x: inner.minX, y: inner.midY - h / 2, width: inner.width, height: h),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

/// ⌘F の検索バー（右上に出る小さな角丸の入力欄）。⏎ で古い方へ、⇧⏎ で新しい方へ、Esc で閉じる
final class SearchBar: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    var onChange: ((String) -> Void)?
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Find"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.frame = NSRect(x: 10, y: 6, width: frame.width - 128, height: 16)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right
        count.frame = NSRect(x: frame.width - 116, y: 7, width: 44, height: 14)   // 件数が増えたら setCount で広げる
        addSubview(field)
        addSubview(count)
        // ▲ 古い方へ・▼ 新しい方へ・× 閉じる
        for (i, (sym, act)) in [("chevron.up", #selector(older)), ("chevron.down", #selector(newer)),
                                ("xmark", #selector(close))].enumerated() {
            let b = NSButton(frame: NSRect(x: frame.width - 68 + CGFloat(i) * 21, y: 5, width: 18, height: 18))
            b.isBordered = false
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            b.imagePosition = .imageOnly
            b.target = self
            b.action = act
            b.refusesFirstResponder = true
            addSubview(b)
            buttons.append(b)
        }
    }

    private var buttons: [NSButton] = []
    @objc private func older() { onStep?(true) }
    @objc private func newer() { onStep?(false) }
    @objc private func close() { onClose?() }
    required init?(coder: NSCoder) { fatalError("not supported") }

    func style(fg: NSColor, bg: NSColor) {
        layer?.backgroundColor = bg.withAlphaComponent(0.92).cgColor
        layer?.borderColor = fg.withAlphaComponent(0.18).cgColor
        field.textColor = fg
        count.textColor = fg.withAlphaComponent(0.5)
        for b in buttons { b.contentTintColor = fg.withAlphaComponent(0.7) }
        field.placeholderAttributedString = NSAttributedString(string: "Find", attributes: [
            .foregroundColor: fg.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 12)])
    }

    /// 件数の表示。桁が増えたら件数の欄を広げて、そのぶん入力欄を縮める（ボタンと重ならないように）
    func setCount(_ s: String) {
        count.stringValue = s
        let w = max(44, ceil(count.attributedStringValue.size().width) + 6)
        let right = bounds.width - 72          // ▲ ▼ × のボタンの手前
        count.frame = NSRect(x: right - w, y: 7, width: w, height: 14)
        field.frame.size.width = max(60, right - w - 6 - field.frame.minX)
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            onStep?(!shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// ふちが発光しているように見せる枠。
/// 内側へ大きくにじむ光（halo）＋細い光の帯（glow）＋白っぽく光る芯（core）の3層を重ねる。
/// 外側は box の角丸で切り取られるので、光は内側にだけ広がる。
final class EdgeGlowView: NSView {
    private let halo = CAShapeLayer()
    private let glow = CAShapeLayer()
    private let core = CAShapeLayer()
    private var lit = false

    // 光り方の調整（サンプルで選んだ値）
    private static let strength: CGFloat = 1.8     // 全体の強さ（各層の濃さにかける）
    private static let haloRadius: CGFloat = 12    // にじむ幅
    private static let bandWidth: CGFloat = 5      // 光の帯の太さ
    private static let coreWhite: CGFloat = 0      // 芯の白さ（0 でタブの色そのまま）

    var corner: CGFloat = 8 { didSet { if corner != oldValue { updatePaths() } } }
    var color: NSColor = .white { didSet { if color != oldValue { updateColors() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        for l in [halo, glow, core] {
            l.fillColor = nil
            l.lineJoin = .round
            l.shadowOffset = .zero
            layer?.addSublayer(l)
        }
        halo.lineWidth = 10
        halo.shadowRadius = Self.haloRadius
        halo.shadowOpacity = 0.9
        glow.lineWidth = Self.bandWidth
        glow.shadowRadius = 7 * Self.bandWidth / 3
        glow.shadowOpacity = 1
        core.lineWidth = 1
        core.shadowRadius = 2.5
        core.shadowOpacity = 1
        updatePaths()
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaths()
    }

    /// 光る / 消える。どちらもゆっくりフェード
    func setLit(_ on: Bool) {
        guard on != lit else { return }
        lit = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.9 : 0.7
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = on ? 1 : 0
        }
    }

    private func updatePaths() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (l, inset) in [(halo, CGFloat(0)), (glow, CGFloat(1)), (core, CGFloat(0.5))] {
            l.frame = bounds
            let r = bounds.insetBy(dx: inset, dy: inset)
            let rad = max(0, corner - inset)
            l.path = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
        }
        CATransaction.commit()
    }

    /// タブを切り替えたときは、色がふわっと移り変わる
    private func updateColors() {
        let c = color
        let hot = Self.coreWhite > 0 ? (c.blended(withFraction: Self.coreWhite, of: .white) ?? c) : c
        let k = Self.strength
        func a(_ v: CGFloat) -> CGFloat { min(1, v * k) }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        halo.strokeColor = c.withAlphaComponent(a(0.10)).cgColor
        halo.shadowColor = c.cgColor
        glow.strokeColor = c.withAlphaComponent(a(0.55)).cgColor
        glow.shadowColor = c.cgColor
        core.strokeColor = hot.withAlphaComponent(a(0.95)).cgColor
        core.shadowColor = c.cgColor
        CATransaction.commit()
    }
}

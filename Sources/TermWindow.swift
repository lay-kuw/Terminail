import AppKit
import QuartzCore

/// 画面やタブを開け閉めしたときの演出（描くのは AppDelegate の FX。位置はどれも画面座標）
enum PaneTransition {
    case beam(from: CGPoint, to: CGPoint)    // 分割の線が光ってのびる
    case poof(CGImage, NSRect)               // 閉じた画面の最後の姿が消えていく
    case sparkle(NSRect, count: Int)         // タブバーのタブからキラキラ
}

/// 画面1つぶん（ターミナル本体と、いま前面で動いているコマンド）
final class Pane {
    let view: TerminalView
    var running: String?              // いま前面で動いているコマンド
    var startedAt: CFTimeInterval = 0
    init(view: TerminalView) { self.view = view }
}

/// タブ1つぶん。⌘W で画面を2つまで並べられる（タブごとに別々）
final class Tab {
    let container: PaneContainer
    private(set) var panes: [Pane] = []
    var focus = 0          // いま操作している画面の番号
    var slot: Int          // アイコンの番号（開いた順。閉じたら空いた番号をまた使う。1つに戻ったら 0 に）
    var name = ""
    var alert = false                 // 裏で長いコマンドが終わった（タブのアイコンが光る）
    var isSplit: Bool { panes.count > 1 }
    /// いま操作している画面のターミナル
    var view: TerminalView { panes[focus].view }

    init(first: Pane, slot: Int, frame: NSRect) {
        self.slot = slot
        container = PaneContainer(frame: frame)
        add(first)
    }

    func add(_ p: Pane) {
        panes.append(p)
        container.setPanes(panes.map(\.view))
    }

    func remove(_ p: Pane) {
        panes.removeAll { $0 === p }
        focus = max(0, min(focus, panes.count - 1))
        container.setPanes(panes.map(\.view))
    }
}

/// タブの中身：画面を1つ、または2つ並べる（left-right なら左右、top-bottom なら上下に半分ずつ）
final class PaneContainer: NSView {
    private(set) var panes: [TerminalView] = []
    /// true なら上下、false なら左右に並べる
    var vertical = false { didSet { if vertical != oldValue { layoutPanes() } } }
    var dividerColor = NSColor.white.withAlphaComponent(0.18) { didSet { needsDisplay = true } }
    /// 画面の並びや大きさが変わった（スクロール表示や検索窓を合わせ直す）
    var onLayout: (() -> Void)?
    private static let gap: CGFloat = 1     // 2つの画面のあいだの線

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func setPanes(_ views: [TerminalView]) {
        for v in panes where !views.contains(where: { $0 === v }) { v.removeFromSuperview() }
        panes = views
        for v in views where v.superview !== self { addSubview(v) }
        layoutPanes()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPanes()
    }

    private func layoutPanes() {
        let b = bounds
        let g = Self.gap
        if panes.count < 2 {
            panes.first?.chromeTop = true
            panes.first?.frame = b
        } else if vertical {
            let h = floor((b.height - g) / 2)
            panes[0].chromeTop = true
            panes[0].frame = NSRect(x: 0, y: 0, width: b.width, height: h)
            panes[1].chromeTop = false      // 下の画面には信号ボタンもタブバーもないので、上の余白はいらない
            panes[1].frame = NSRect(x: 0, y: h + g, width: b.width, height: b.height - h - g)
        } else {
            let w = floor((b.width - g) / 2)
            panes[0].chromeTop = true
            panes[0].frame = NSRect(x: 0, y: 0, width: w, height: b.height)
            panes[1].chromeTop = true
            panes[1].frame = NSRect(x: w + g, y: 0, width: b.width - w - g, height: b.height)
        }
        needsDisplay = true
        onLayout?()
    }

    /// 2つの画面のあいだの線の場所。タイトルバーにはかからないように始める
    var dividerRect: NSRect? {
        guard panes.count > 1 else { return nil }
        let f = panes[1].frame
        let g = Self.gap
        let line: NSRect
        if vertical {
            let inset: CGFloat = 12
            line = NSRect(x: inset, y: f.minY - g, width: max(0, bounds.width - inset * 2), height: g)
        } else {
            let top = panes[0].chromeHeight + 6       // 信号ボタンとタブバーの下から
            line = NSRect(x: f.minX - g, y: top, width: g, height: max(0, bounds.height - top - 10))
        }
        return line.width > 0 && line.height > 0 ? line : nil
    }

    /// 仕切りの線。両端はふわっと消える
    override func draw(_ dirtyRect: NSRect) {
        guard let line = dividerRect, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = dividerColor.usingColorSpace(.sRGB) ?? dividerColor
        let clear = c.withAlphaComponent(0)
        guard let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                    colors: [clear.cgColor, c.cgColor, c.cgColor, clear.cgColor] as CFArray,
                                    locations: [0, 0.15, 0.85, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: line)
        let start = vertical ? CGPoint(x: line.minX, y: line.midY) : CGPoint(x: line.midX, y: line.minY)
        let end = vertical ? CGPoint(x: line.maxX, y: line.midY) : CGPoint(x: line.midX, y: line.maxY)
        ctx.drawLinearGradient(grad, start: start, end: end, options: [])
        ctx.restoreGState()
    }
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
    private weak var searchTarget: TerminalView?      // 検索している画面
    private var searchWork: DispatchWorkItem?
    let seq: Int                   // 開いた順番（Window メニューの番号付けに使う）
    private static var nextSeq = 0

    /// いま操作している画面のターミナル（前に出ているタブの、選んでいる画面）
    var termView: TerminalView { tabs[active].view }

    var onBell: ((TermWindow) -> Void)?
    var onEnter: ((TermWindow, NSRect) -> Void)?
    var onType: ((TermWindow, NSRect) -> Void)?
    var onDelete: ((TermWindow, NSRect) -> Void)?
    var onClosed: ((TermWindow) -> Void)?        // ウィンドウが閉じた（赤ボタン・最後のタブで exit）
    var onCommandFinished: ((TermWindow, Tab, String, Double) -> Void)?   // 長いコマンドが終わった
    var onTransition: ((TermWindow, PaneTransition) -> Void)?             // 画面・タブの開け閉めの演出

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
        tabBar.onSelect = { [weak self] i in self?.switchTab(i) }
        box.addSubview(effect)
        box.addSubview(tint)
        box.addSubview(tabBar)
        // スクロール表示と一番下へ戻るボタンは、操作している画面の右端に合わせて置く（layoutPaneChrome）
        scrollGlow.frame = NSRect(x: box.bounds.width - 24, y: 0, width: 24, height: box.bounds.height)
        scrollGlow.onDrag = { [weak self] f, jump in self?.termView.scroll(toFraction: f, animated: jump) }
        scrollGlow.canScroll = { [weak self] in
            guard let v = self?.termView else { return false }
            return !v.term.isAlt && v.term.scrollback.count > 0
        }
        box.addSubview(scrollGlow)
        jump.setFrameOrigin(NSPoint(x: box.bounds.width - 35, y: 4))
        jump.onClick = { [weak self] in self?.termView.scrollToBottom() }
        box.addSubview(jump)
        edge.frame = box.bounds
        edge.autoresizingMask = [.width, .height]
        box.addSubview(edge)
        root.addSubview(box)
        window.contentView = root

        let first = makeTab()
        tabs.append(first)
        show(first)
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
        for t in tabs {
            for p in t.panes { p.view.apply(c) }
            t.container.dividerColor = colors.foreground.withAlphaComponent(0.18)
        }
        refreshCorners()
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

    /// 画面を1つ作る（シェルはまだ起動しない）。シェルはホームのフォルダから始まる
    private func makePane() -> Pane {
        let v = TerminalView(frame: box.bounds, config: config)
        v.autoresizingMask = []          // 大きさは PaneContainer が決める
        v.fontDelta = fontDelta
        let pane = Pane(view: v)
        v.onBell = { [weak self, weak v] in if let s = self, v === s.termView { s.onBell?(s) } }
        v.onEnter = { [weak self, weak v] r in if let s = self, v === s.termView { s.onEnter?(s, r) } }
        v.onType = { [weak self, weak v] r in if let s = self, v === s.termView { s.onType?(s, r) } }
        v.onDelete = { [weak self, weak v] r in if let s = self, v === s.termView { s.onDelete?(s, r) } }
        v.onViewOffsetChanged = { [weak self, weak v] in if let s = self, v === s.termView { s.updateScrollUI(kick: false) } }
        v.onUserScroll = { [weak self, weak v] in if let s = self, v === s.termView { s.updateScrollUI(kick: true) } }
        v.onMatchesChanged = { [weak self, weak v] in if let s = self, v === s.searchTarget { s.updateSearchCount() } }
        v.onLogError = { [weak self] url, err in self?.showLogError(url, err) }
        v.onShellExit = { [weak self, weak pane] in if let s = self, let p = pane { s.paneExited(p) } }
        v.onFocus = { [weak self, weak pane] in if let s = self, let p = pane { s.paneFocused(p) } }
        return pane
    }

    private func makeTab() -> Tab {
        let used = Set(tabs.map(\.slot))
        var slot = 0
        while used.contains(slot) { slot += 1 }
        let tab = Tab(first: makePane(), slot: slot, frame: box.bounds)
        tab.container.autoresizingMask = [.width, .height]
        tab.container.dividerColor = colors.foreground.withAlphaComponent(0.18)
        tab.container.onLayout = { [weak self, weak tab] in
            guard let s = self, let t = tab, s.tabs.indices.contains(s.active), s.tabs[s.active] === t else { return }
            s.layoutPaneChrome()
        }
        return tab
    }

    /// ⌘T：いまのタブの右に新しいタブを開く
    func newTab() {
        let t = makeTab()
        t.view.apply(config)
        tabs.insert(t, at: active + 1)
        select(active + 1)
        t.view.startShell()
        if animates {   // 中身はふわっと現れて、タブバーのタブはぽよんと弾む
            fadeIn(t.container, duration: 0.25)
            tabBar.pop(active)
            if let r = pillScreenRect(active) { onTransition?(self, .sparkle(r, count: 10)) }
        }
    }

    func select(tab t: Tab) {
        if let i = tabs.firstIndex(where: { $0 === t }) { switchTab(i) }
    }

    /// 別のタブに移る（⌘[ ⌘]・タブバーのクリック・通知から）。移った先のタブが小さく弾んで、キラキラ
    private func switchTab(_ i: Int, pane: Int? = nil) {
        let changed = i != active
        select(i, pane: pane)
        guard changed, animates else { return }
        tabBar.pop(i, strength: 0.18)
        if let r = pillScreenRect(i) { onTransition?(self, .sparkle(r, count: 5)) }
    }

    /// タブ i の画面 pane を選ぶ（pane が nil なら、そのタブで前に選んでいた画面）
    func select(_ i: Int, pane: Int? = nil) {
        guard tabs.indices.contains(i) else { return }
        let t = tabs[i]
        let f = pane.map { max(0, min(t.panes.count - 1, $0)) } ?? t.focus
        if i != active || f != t.focus { closeSearch(refocus: false); scrollGlow.hide() }
        if i != active, tabs.indices.contains(active) { tabs[active].container.removeFromSuperview() }
        active = i
        t.focus = f
        show(t)
        if t.alert && window.isKeyWindow { t.alert = false }
        updateTabBar()
    }

    /// ⌘]：タブ1の画面1 → タブ1の画面2 → タブ2の画面1 … の順に進む（最後まで行ったら最初に戻る）
    func selectNext() {
        let t = tabs[active]
        if t.focus < t.panes.count - 1 { select(active, pane: t.focus + 1); return }
        guard tabs.count > 1 || t.isSplit else { return }
        switchTab((active + 1) % tabs.count, pane: 0)
    }

    /// ⌘[：selectNext の逆向き
    func selectPrevious() {
        let t = tabs[active]
        if t.focus > 0 { select(active, pane: t.focus - 1); return }
        guard tabs.count > 1 || t.isSplit else { return }
        let j = (active - 1 + tabs.count) % tabs.count
        switchTab(j, pane: tabs[j].panes.count - 1)
    }

    /// 前に出すタブだけをウィンドウに入れる（ほかのタブはシェルを動かしたまま裏で待機）
    private func show(_ t: Tab) {
        let c = t.container
        if c.superview !== box {
            c.frame = box.bounds
            box.addSubview(c, positioned: .above, relativeTo: tint)
        }
        updatePaneFocus(t)
        window.makeFirstResponder(t.view)
    }

    /// 分割しているとき、操作していない画面を少し暗くする（カーソルも枠だけに）
    private func updatePaneFocus(_ t: Tab) {
        for (i, p) in t.panes.enumerated() { p.view.isActivePane = !t.isSplit || i == t.focus }
        layoutPaneChrome()
    }

    /// 画面をクリックして選んだ（キー入力がその画面に移った）
    private func paneFocused(_ p: Pane) {
        guard tabs.indices.contains(active) else { return }
        let t = tabs[active]
        guard let i = t.panes.firstIndex(where: { $0 === p }), i != t.focus else { return }
        closeSearch(refocus: false)
        scrollGlow.hide()
        t.focus = i
        updatePaneFocus(t)
        updateTabBar()
    }

    // MARK: - 画面分割

    /// ⌘W：分割していなければ2つに分ける（split-direction の向き）。分割していれば、左右と上下を入れ替える
    func splitOrFlip() {
        let t = tabs[active]
        closeSearch(refocus: false)
        if t.isSplit {
            t.container.vertical.toggle()
            updatePaneFocus(t)
            updateTabBar()
            window.makeFirstResponder(t.view)     // 検索窓を閉じたときも、キー入力を画面に戻す
            beam(t)
            return
        }
        t.container.vertical = config.string("split.direction").lowercased().hasPrefix("top")
        let p = makePane()
        t.add(p)                // 操作するのは元の画面のまま（新しい画面は ⌘] かクリックで）
        updateTabBar()          // 新しい画面にもタブの色や上の余白を合わせる
        show(t)
        p.view.startShell()     // 新しいコンソールと同じく、ホームのフォルダから始まる
        if animates { fadeIn(p.view, duration: 0.3) }
        beam(t)
    }

    /// exit で画面のシェルが終わった：分割中ならその画面だけ閉じる。1つしかなければタブを閉じる
    private func paneExited(_ p: Pane) {
        guard !closing, let ti = tabs.firstIndex(where: { $0.panes.contains { $0 === p } }) else { return }
        let t = tabs[ti]
        guard t.isSplit else { tabExited(t); return }
        if searchTarget === p.view { closeSearch(refocus: false) }
        if ti == active, animates, let snap = snapshot(p.view) { onTransition?(self, .poof(snap.image, snap.rect)) }
        t.remove(p)
        if ti == active {
            scrollGlow.hide()
            show(t)
        } else {
            updatePaneFocus(t)
        }
        updateTabBar()
    }

    /// タブの最後の画面で exit：そのタブを閉じる。最後のタブならウィンドウごと閉じる
    private func tabExited(_ t: Tab) {
        guard !closing, let i = tabs.firstIndex(where: { $0 === t }) else { return }
        if tabs.count == 1 {
            // 最後の画面：ウィンドウごと、カードになってキラキラと消えていく
            if animates, let snap = snapshot(t.container) { onTransition?(self, .poof(snap.image, snap.rect)) }
            window.close()
            return
        }
        let wasActive = i == active
        if wasActive { closeSearch(refocus: false) }
        if animates {   // 見ていたタブなら中身が消えていき、タブバーのタブがあった場所からキラキラ
            if wasActive, let snap = snapshot(t.container) { onTransition?(self, .poof(snap.image, snap.rect)) }
            if let r = pillScreenRect(i) { onTransition?(self, .sparkle(r, count: 10)) }
        }
        tabs.remove(at: i)
        t.container.removeFromSuperview()
        if i < active || active >= tabs.count { active = max(0, active - 1) }
        // 1つに戻ったら、開いたばかりのウィンドウと同じ状態に（✦・白、光っていたのも消す）
        if tabs.count == 1 {
            tabs[0].slot = 0
            tabs[0].alert = false
        }
        if wasActive { show(tabs[active]) }
        updateTabBar()
    }

    /// タブを見たら光るのを止める
    private func clearAlert() {
        guard tabs.indices.contains(active), tabs[active].alert, window.isKeyWindow else { return }
        tabs[active].alert = false
        updateTabBar()
    }

    // MARK: - スクロール位置の表示

    /// スクロール表示・一番下へ戻るボタン・検索窓を、いま操作している画面の右端に合わせる
    private func layoutPaneChrome() {
        guard tabs.indices.contains(active) else { return }
        let v = termView
        guard v.superview != nil else { return }
        let r = v.convert(v.bounds, to: box)
        scrollGlow.frame = NSRect(x: r.maxX - 24, y: r.minY, width: 24, height: r.height)
        jump.setFrameOrigin(NSPoint(x: r.maxX - 35, y: r.minY + 4))
        layoutSearch()
    }

    private func updateScrollUI(kick: Bool) {
        let v = termView
        scrollGlow.color = accent
        scrollGlow.topInset = v.chromeHeight + 6
        scrollGlow.setTarget(v.scrollFraction)
        if kick { scrollGlow.kick() }
        jump.color = accent
        jump.setShown(v.viewOffset > 0)
    }

    // MARK: - 文字サイズ（その場だけ）

    func zoom(_ step: CGFloat) {
        fontDelta = step == 0 ? 0 : max(-8, min(40, fontDelta + step))
        for t in tabs { for p in t.panes { p.view.fontDelta = fontDelta } }
    }

    // MARK: - 検索（⌘F）

    /// ⌘F：検索窓を出す。出ているときにもう一度押すと閉じる
    func showSearch() {
        if searchBar != nil {
            closeSearch()
            return
        }
        let bar = SearchBar(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        searchTarget = termView          // 検索するのは、いま操作している画面
        let c = colors
        bar.style(fg: c.foreground, bg: c.background)
        bar.onChange = { [weak self, weak bar] q in
            // 打つたびに全部探すと、出力が流れているときに重くなるので、打ち終わるのを少し待つ
            guard let self else { return }
            self.searchWork?.cancel()
            let w = DispatchWorkItem { [weak self, weak bar] in
                guard let self, let v = self.searchTarget else { return }
                let n = v.search(q)
                bar?.setCount(n == 0 ? (q.isEmpty ? "" : "0") : "\(v.currentMatchNumber)/\(n)")
            }
            self.searchWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        }
        bar.onStep = { [weak self, weak bar] older in
            guard let v = self?.searchTarget else { return }
            v.nextMatch(older: older)
            if v.matchCount > 0 { bar?.setCount("\(v.currentMatchNumber)/\(v.matchCount)") }
        }
        bar.onClose = { [weak self] in self?.closeSearch() }
        searchBar = bar
        layoutSearch()
        box.addSubview(bar, positioned: .above, relativeTo: tabBar)
        window.makeFirstResponder(bar.field)
    }

    /// ⌘K：いま操作している画面の、表示と履歴を消す
    func clearScrollback() {
        closeSearch()
        termView.clearScrollback()
    }

    private func updateSearchCount() {
        guard let bar = searchBar, let v = searchTarget else { return }
        bar.setCount(v.matchCount == 0 ? "" : "\(v.currentMatchNumber)/\(v.matchCount)")
    }

    private func showLogError(_ url: URL, _ err: Error) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Logging stopped"
        a.informativeText = "Couldn't write to \(url.path)\n\(err.localizedDescription)\n\nOutput after this point was not saved."
        a.beginSheetModal(for: window)
    }

    /// 検索窓を閉じる。refocus が true なら、キー入力をターミナルに戻す
    func closeSearch(refocus: Bool = true) {
        searchWork?.cancel()
        guard let bar = searchBar else { return }
        bar.removeFromSuperview()
        searchBar = nil
        searchTarget?.clearSearch()
        searchTarget = nil
        if refocus { window.makeFirstResponder(termView) }
    }

    /// 検索窓は、検索している画面の右上に置く
    private func layoutSearch() {
        guard let bar = searchBar else { return }
        let v = searchTarget ?? termView
        guard v.superview != nil else { return }
        let r = v.convert(v.bounds, to: box)
        bar.setFrameOrigin(NSPoint(x: r.maxX - bar.frame.width - 10, y: r.maxY - v.chromeHeight - bar.frame.height - 4))
    }

    // MARK: - ログ（いま操作している画面ごと）

    var isLogging: Bool { termView.isLogging }
    func startLog(to url: URL) -> Bool { termView.startLog(to: url) }
    func stopLog() { termView.stopLog() }

    // MARK: - 開け閉めの演出（tab-animations）

    private var animates: Bool { config.bool("fx.tab_anim") && window.isVisible }

    private func fadeIn(_ v: NSView, duration: Double) {
        v.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            v.animator().alphaValue = 1
        }
    }

    /// 分割の線が光ってのびる
    private func beam(_ t: Tab) {
        guard animates, let r = t.container.dividerRect else { return }
        let c = t.container
        func scr(_ p: NSPoint) -> NSPoint { window.convertPoint(toScreen: c.convert(p, to: nil)) }
        let (a, b) = t.container.vertical ? (NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY))
                                          : (NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.midX, y: r.maxY))
        onTransition?(self, .beam(from: scr(a), to: scr(b)))
    }

    /// タブバーの i 番目のタブの場所（画面座標）。タブバーが出ていなければ nil
    private func pillScreenRect(_ i: Int) -> NSRect? {
        guard !tabBar.isHidden, let r = tabBar.itemRect(i) else { return nil }
        return window.convertToScreen(tabBar.convert(r, to: nil))
    }

    /// ビューの見た目を、背景の色を敷いた角丸のカードとして写し取る（画面座標の位置つき）。
    /// 背景を敷くのは、消えていく写しの文字と、下に現れる画面の文字が二重に見えないように
    private func snapshot(_ v: NSView) -> (image: CGImage, rect: NSRect)? {
        guard v.window === window, v.bounds.width > 1, v.bounds.height > 1,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let img = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        let rad = min(window.cornerRadius * full.width / v.bounds.width, full.width / 2, full.height / 2)
        ctx.addPath(CGPath(roundedRect: full, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.clip()
        ctx.setFillColor(colors.background.withAlphaComponent(0.92).cgColor)
        ctx.fill(full)
        ctx.draw(img, in: full)
        guard let card = ctx.makeImage() else { return nil }
        return (card, window.convertToScreen(v.convert(v.bounds, to: nil)))
    }

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
        for t in tabs {
            for p in t.panes { p.view.extraTop = extra; p.view.tabBarShown = visible }
            t.container.needsDisplay = true
        }
        if visible { refreshNames() }
        let c = colors
        let mode = config.string("tabs.colors")
        let colored = mode == "cursor" || mode == "edge" || mode == "icon"
        tabBar.style = style
        tabBar.items = tabs.map { TabBarView.Item(icon: icon(for: $0.slot, style: style), name: $0.name, split: splitKind($0),
                                                  color: colored ? tabColor($0) : nil, alert: $0.alert) }
        // カーソル・キラキラの色
        for t in tabs {
            for p in t.panes { p.view.tabColor = (mode == "cursor" || mode == "edge") ? tabColor(t) : nil }
        }
        // ふち全体が発光する枠。タブが2つ以上のときだけ、じわっと光って、じわっと消える
        edge.corner = window.cornerRadius
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
            for p in t.panes {
                let fg = p.view.pty.foregroundCommand
                if let cmd = fg {
                    if p.running == nil { p.startedAt = now }
                    p.running = cmd
                } else if let cmd = p.running {
                    p.running = nil
                    let took = now - p.startedAt
                    // いままさにそのタブを見ているなら知らせない（分割中は、どちらの画面も見えているものとする）
                    let looking = NSApp.isActive && window.isKeyWindow && window.isVisible && i == active
                    if took >= after && !looking && !ignore.contains(cmd.lowercased()) && !styles.contains("off") {
                        if styles.contains("tab") && !(i == active && window.isKeyWindow) { t.alert = true; alertChanged = true }
                        onCommandFinished?(self, t, cmd, took)
                    }
                }
            }
        }
        if alertChanged { updateTabBar() }
        if barVisible { refreshNames() }
    }

    /// タブ名：操作している画面のシェルがいるフォルダ。何か動いていればそのコマンド名
    private func refreshNames() {
        var changed = false
        for t in tabs {
            // 前面のコマンドは poll() で調べたものを使う（同じ情報を2回取りにいかない）
            let p = t.panes[t.focus]
            let n = p.running ?? p.view.pty.currentDirectory ?? "shell"
            if n != t.name { t.name = n; changed = true }
        }
        guard changed else { return }
        for (i, t) in tabs.enumerated() where i < tabBar.items.count { tabBar.items[i].name = t.name }
        tabBar.needsDisplay = true
    }

    /// タブバーに出す分割アイコンの種類
    private func splitKind(_ t: Tab) -> TabBarView.Split {
        guard t.isSplit else { return .none }
        return t.container.vertical ? .stacked : .sideBySide
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
        for t in tabs { for p in t.panes { p.view.stopLog(); p.view.pty.terminate() } }
    }

    /// 角の丸さを、macOS が実際にウィンドウに使っている丸さに合わせる（すりガラス・光る枠・中身の切り抜き）
    private func refreshCorners() {
        let corner = window.cornerRadius
        box.layer?.cornerRadius = corner
        effect.corner = corner
        edge.corner = corner
    }

    func windowDidEnterFullScreen(_ notification: Notification) { refreshCorners() }
    func windowDidExitFullScreen(_ notification: Notification) { refreshCorners() }
    /// 画面に出たときに、もう一度確かめる（出る前は丸さが決まっていないことがあるため）
    func windowDidChangeScreen(_ notification: Notification) { refreshCorners() }
    func windowDidBecomeMain(_ notification: Notification) { refreshCorners() }

    func windowWillClose(_ notification: Notification) {
        nameTimer?.invalidate()
        nameTimer = nil
        tabBar.stopPulse()
        scrollGlow.hide()
        terminateAll()
        onClosed?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        for p in tabs[active].panes { p.view.needsDisplay = true }
        clearAlert()
    }
    func windowDidResignKey(_ notification: Notification) {
        for p in tabs[active].panes { p.view.needsDisplay = true }
    }
}

/// 信号ボタンの行に描くタブバー。
/// dots：真ん中にアイコンが並び、その下に今のタブの名前。pill：信号ボタンの右に、名前入りの丸いタブ。
final class TabBarView: NSView {
    enum Style { case dots, pill }
    /// 分割しているタブにつけるアイコン（SF Symbols）
    enum Split { case none, sideBySide, stacked }
    struct Item {
        var icon: String
        var name: String
        var split: Split = .none
        var color: NSColor? = nil
        var alert = false
    }

    /// 分割アイコン（左右なら縦に、上下なら横に仕切った角丸の四角）。文字の高さの真ん中にそろえる
    private func splitMark(_ kind: Split, color: NSColor, font: NSFont) -> NSAttributedString? {
        let name: String
        switch kind {
        case .none: return nil
        case .sideBySide: name = "rectangle.split.2x1"
        case .stacked: name = "rectangle.split.1x2"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.95, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: "split")?.withSymbolConfiguration(cfg) else { return nil }
        let att = NSTextAttachment()
        att.image = img
        att.bounds = NSRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
        let s = NSMutableAttributedString(attachment: att)
        s.append(NSAttributedString(string: " ", attributes: [.font: font]))
        return s
    }

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
        popTimer?.invalidate()
        popTimer = nil
        popIndex = -1
    }

    /// ウィンドウから外れたら、明滅のタイマーも止める
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopPulse() }
    }

    private var pulse: CGFloat { CGFloat(0.5 + 0.5 * sin(CACurrentMediaTime() * 4.5)) }

    // 新しいタブはぽよんと大きく、移った先のタブは小さく弾む
    private var popIndex = -1
    private var popStart: CFTimeInterval = 0
    private var popStrength: CGFloat = 0.5
    private var popTimer: Timer?
    private static let popDuration = 0.5

    /// strength：弾む大きさ（0.5 なら半分の大きさから、0.18 なら少しだけ縮んだところから）
    func pop(_ i: Int, strength: CGFloat = 0.5) {
        popIndex = i
        popStrength = strength
        popStart = CACurrentMediaTime()
        guard popTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.needsDisplay = true
            if CACurrentMediaTime() - self.popStart > Self.popDuration {
                self.popIndex = -1
                self.popTimer = nil
                timer.invalidate()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        popTimer = t
    }

    /// 弾んでいるタブの大きさ（縮んだところから、少し大きくなりすぎて、1 に落ち着くばね）
    private func popScale(_ i: Int) -> CGFloat {
        guard i == popIndex else { return 1 }
        let t = CACurrentMediaTime() - popStart
        return 1 - popStrength * CGFloat(exp(-7 * t) * cos(11 * t))
    }

    /// タブ i を、弾み具合に合わせて縮めたり広げたりして描く
    private func withPop(_ i: Int, _ r: NSRect, _ body: () -> Void) {
        let s = popScale(i)
        guard abs(s - 1) > 0.001, let ctx = NSGraphicsContext.current?.cgContext else { body(); return }
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -r.midX, y: -r.midY)
        body()
        ctx.restoreGState()
    }

    /// i 番目のタブの場所（このビューの座標）
    func itemRect(_ i: Int) -> NSRect? {
        let rs = rects()
        return rs.indices.contains(i) ? rs[i] : nil
    }
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
            withPop(i, r) {
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
        }
        guard items.indices.contains(active) else { return }
        let line = NSRect(x: 80, y: 26, width: max(0, bounds.width - 160), height: TabBarView.nameLine)
        let it = items[active]
        let font = NSFont.systemFont(ofSize: 10.5)
        let col = fg.withAlphaComponent(0.6)
        guard let mark = splitMark(it.split, color: col, font: font) else {
            centered(it.name, font: font, color: col, in: line)
            return
        }
        let str = NSMutableAttributedString(attributedString: mark)
        str.append(NSAttributedString(string: it.name, attributes: [.font: font, .foregroundColor: col]))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byTruncatingTail
        str.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: str.length))
        let h = ceil(font.ascender - font.descender)
        str.draw(with: NSRect(x: line.minX, y: line.midY - h / 2, width: line.width, height: h),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawPills(_ rs: [NSRect]) {
        for (i, r) in rs.enumerated() {
            withPop(i, r) { drawPill(i, r) }
        }
    }

    private func drawPill(_ i: Int, _ r: NSRect) {
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
        if let mark = splitMark(it.split, color: textCol.withAlphaComponent(on ? 0.75 : 0.45), font: font) {
            str.append(mark)
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

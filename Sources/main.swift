import AppKit
import Carbon
import UserNotifications

extension Notification.Name {
    static let terminailToggle = Notification.Name("TerminailToggle")
    static let terminailOpen = Notification.Name("io.github.lay-kuw.terminail.open")
}

/// WindowServer の背景ぼかし（非公開APIなので、見つからなければ何もしない）
enum WindowBlur {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias BlurFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let conn: ConnFn? = dlsym(rtldDefault, "CGSMainConnectionID").map { unsafeBitCast($0, to: ConnFn.self) }
    private static let blur: BlurFn? = dlsym(rtldDefault, "CGSSetWindowBackgroundBlurRadius").map { unsafeBitCast($0, to: BlurFn.self) }

    @discardableResult
    static func set(_ window: NSWindow, radius: Int) -> Bool {
        guard let c = conn, let b = blur, window.windowNumber > 0 else { return false }
        return b(c(), Int32(window.windowNumber), Int32(radius)) == 0
    }
}

/// macOS 標準のすりガラス（NSVisualEffectView）から、色味の層を取り除いてぼかしの強さだけ調整できるようにしたもの。
/// 角丸は maskImage で切り抜くので、ぼかしも角に沿う。
final class GlassView: NSVisualEffectView {
    var radius: Int = 20 { didSet { if radius != oldValue { tune() } } }
    var corner: CGFloat = 8 { didSet { if corner != oldValue { maskImage = GlassView.mask(corner) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        blendingMode = .behindWindow
        state = .active
        material = .hudWindow
        maskImage = GlassView.mask(corner)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() { super.layout(); tune() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); tune() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); tune() }

    static func mask(_ r: CGFloat) -> NSImage? {
        guard r > 0 else { return nil }
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    /// 中の層を調べて、ぼかし以外のフィルタと色の層を消し、ぼかしの半径を設定する
    func tune() {
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _ = walk(root)
        CATransaction.commit()
    }

    /// 戻り値：この層の下にぼかしの層があるか
    private func walk(_ l: CALayer) -> Bool {
        if NSStringFromClass(type(of: l)).contains("Backdrop") {
            if let fs = l.filters as? [NSObject] {
                let blurs = fs.filter { (($0.value(forKey: "name") as? String) ?? "").lowercased().contains("blur") }
                if !blurs.isEmpty && blurs.count != fs.count { l.filters = blurs }
                for f in blurs {
                    if let n = f.value(forKey: "name") as? String {
                        l.setValue(radius, forKeyPath: "filters.\(n).inputRadius")
                    }
                }
            }
            // 標準では背景を 1/8 に縮めてからぼかしているので半径がほぼ効かない。等倍にして半径をそのまま px で効かせる
            l.setValue(1.0, forKey: "scale")
            return true
        }
        var has = false
        for s in l.sublayers ?? [] where walk(s) { has = true }
        if !has && l !== layer {
            l.isHidden = true   // ぼかしと関係ない層（色味・ハイライトなど）は消す
        }
        return has
    }
}

/// タイトルバーなし・画面外にも動かせるウィンドウ
final class AppWindow: NSWindow {
    var cornerRadius: CGFloat = 16 {
        didSet { if cornerRadius != oldValue { invalidateShadow() } }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    private var config = Config.load()
    private var windows: [TermWindow] = []      // 開いているウィンドウ（どれも同じ扱い）
    private var hidden: [TermWindow] = []       // ホットキーで隠したウィンドウ（次に呼んだとき出す）
    private var windowsMenu: NSMenu?
    private var configWatch: DispatchSourceFileSystemObject?
    private var configFileWatch: DispatchSourceFileSystemObject?
    private var lastConfigText = ""
    private var reloadWork: DispatchWorkItem?
    private let fx = FX()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var lastKind: SummonKind = .fade
    private var launched = false
    private var hiding = false
    private var secureOn = false                // いま Secure Keyboard Entry が効いているか
    private let toaster = Toaster()
    private var badgeCount = 0
    private var askedNotify = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // すでに Terminail が動いていたら、そっちのウィンドウを出してもらって自分は終わる（ホットキーの取り合いを防ぐ）
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(.terminailOpen, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openTerminal), name: .terminailOpen, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toggle), name: .terminailToggle, object: nil)
        buildMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        registerHotKey()
        watchConfig()
        watchTabKeys()
        newWindow()
        launched = true
    }

    /// ⌘Tab などでアプリに切り替えたとき、ウィンドウが1枚も出ていなければ出す
    func applicationDidBecomeActive(_ notification: Notification) {
        updateSecureInput()
        badgeCount = 0
        NSApp.dockTile.badgeLabel = nil
        guard launched, !fx.isSummoning, !hiding else { return }
        if !windows.contains(where: { $0.window.isVisible }) { showAll() }
    }

    /// Finder や Dock から、すでに起動中の Terminail をもう一度開いたとき
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openTerminal()
        return false
    }

    func applicationWillResignActive(_ notification: Notification) {
        setSecureInput(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        setSecureInput(false)
        windows.forEach { $0.terminateAll() }
    }

    // MARK: - Secure Keyboard Entry（ほかのアプリからキー入力を盗み見られないようにする）

    /// アプリが前にいるあいだだけ有効にする（後ろにいるときまで効かせると、ほかのアプリの入力を邪魔するため）
    private func updateSecureInput() {
        setSecureInput(config.bool("security.secure_input") && NSApp.isActive)
    }

    private func setSecureInput(_ on: Bool) {
        guard on != secureOn else { return }
        if on { EnableSecureEventInput() } else { DisableSecureEventInput() }
        secureOn = on
    }

    // MARK: - 長いコマンドが終わったときの通知

    private static func duration(_ s: Double) -> String {
        let n = Int(s.rounded())
        if n < 60 { return "\(n)s" }
        if n < 3600 { return "\(n / 60)m \(n % 60)s" }
        return String(format: "%dh %02dm", n / 3600, (n % 3600) / 60)
    }

    /// notify の設定に合わせて知らせる：toast（既定）/ system / dock / tab（tab は TermWindow 側で光らせる）
    private func commandFinished(_ w: TermWindow, _ t: Tab, _ cmd: String, _ took: Double) {
        let styles = Set(config.strings("notify.style"))
        let time = Self.duration(took)
        if styles.contains("toast") {
            let c = Colors(config)
            toaster.show(icon: w.iconText(t), iconColor: w.tabColor(t), text: "\(cmd) finished · \(time)",
                         fg: c.foreground, bg: c.background, near: w.window) { [weak self, weak w, weak t] in
                guard let w, let t else { return }
                self?.focus(w, t)
            }
        }
        if styles.contains("system") { systemNotify(w, t, cmd, time) }
        if styles.contains("dock") && !NSApp.isActive {
            badgeCount += 1
            NSApp.dockTile.badgeLabel = "\(badgeCount)"
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func focus(_ w: TermWindow, _ t: Tab) {
        hidden.removeAll { $0 === w }
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
        w.select(tab: t)
    }

    private func systemNotify(_ w: TermWindow, _ t: Tab, _ cmd: String, _ time: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let send = {
            let content = UNMutableNotificationContent()
            content.title = "\(cmd) finished"
            content.body = "Took \(time) · \(w.iconText(t)) \(t.name)"
            content.sound = .default
            content.userInfo = ["seq": w.seq, "slot": t.slot]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if askedNotify { send(); return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.askedNotify = true
                if ok { send() }
            }
        }
    }

    /// アプリが前にあっても（別のタブを見ているときなど）バナーを出す
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    /// 通知をクリックしたら、そのタブを前に出す
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let seq = info["seq"] as? Int, let w = self.windows.first(where: { $0.seq == seq }) {
                if let slot = info["slot"] as? Int, let t = w.tabs.first(where: { $0.slot == slot }) {
                    self.focus(w, t)
                } else {
                    self.focus(w, w.tabs[0])
                }
            }
            done()
        }
    }

    // MARK: - 検索・ログ

    @objc func find() { keyTermWindow?.showSearch() }

    /// Edit → New Log…：保存先を選んだら、いまのタブの内容を全部テキストで記録しはじめる
    @objc func newLog() {
        guard let w = keyTermWindow else { return }
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Terminail \(f.string(from: Date())).log"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: w.window) { [weak w] res in
            guard res == .OK, let url = panel.url, let w else { return }
            if !w.startLog(to: url) {
                let a = NSAlert()
                a.messageText = "Couldn't start the log"
                a.informativeText = url.path
                a.runModal()
            }
        }
    }

    @objc func stopLog() { keyTermWindow?.stopLog() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(newLog): return keyTermWindow.map { !$0.isLogging } ?? false
        case #selector(stopLog): return keyTermWindow?.isLogging ?? false
        case #selector(find): return keyTermWindow != nil
        default: return true
        }
    }

    // MARK: - ウィンドウを作る

    private func makeWindow() -> TermWindow {
        let w = TermWindow(config: config)
        w.apply(config)
        w.onBell = { [weak self] w in self?.bell(w) }
        w.onEnter = { [weak self] w, r in self?.enterBurst(w, r) }
        w.onType = { [weak self] w, r in self?.typeTrail(w, r) }
        w.onDelete = { [weak self] w, r in self?.deleteSuck(w, r) }
        w.onClosed = { [weak self] w in self?.windowClosed(w) }
        w.onCommandFinished = { [weak self] w, t, cmd, took in self?.commandFinished(w, t, cmd, took) }
        return w
    }

    /// ⌘N：新しいウィンドウ。前にあるウィンドウから少しずらして置く（なければマウスのある画面の真ん中）
    @objc func newWindow() {
        let w = makeWindow()
        if let key = NSApp.keyWindow, key.isVisible, windows.contains(where: { $0.window === key }) {
            w.window.setFrameOrigin(NSPoint(x: key.frame.minX + 28, y: key.frame.minY - 28))
        } else {
            centerOnMouseScreen(w.window)
        }
        windows.append(w)
        w.startShell()
        appear(w)
    }

    /// ⌘T：いまのウィンドウに新しいタブ（ウィンドウがなければ新しいウィンドウ）
    @objc func newTab() {
        if let w = keyTermWindow { w.newTab() } else { newWindow() }
    }

    /// ⌘] / ⌘[ でタブ切り替え、⌘+ / ⌘- / ⌘0 で文字サイズ、⌘K で履歴を消す（メニューには出さない）
    private func watchTabKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self,
                  e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function, .shift]) == .command,
                  let w = self.keyTermWindow else { return e }
            switch e.charactersIgnoringModifiers {
            case "]": w.selectNext(); return nil
            case "[": w.selectPrevious(); return nil
            case "=", "+", ";": w.zoom(1); return nil
            case "-": w.zoom(-1); return nil
            case "0": w.zoom(0); return nil
            case "k": w.clearScrollback(); return nil
            default: return e
            }
        }
    }

    private var keyTermWindow: TermWindow? {
        let key = NSApp.keyWindow ?? NSApp.mainWindow
        return windows.first { $0.window === key }
    }

    /// 赤ボタン・最後のタブで exit：最後のウィンドウだったらアプリも終わる
    private func windowClosed(_ w: TermWindow) {
        windows.removeAll { $0 === w }
        hidden.removeAll { $0 === w }
        if windows.isEmpty { NSApp.terminate(nil) }
    }

    /// ⌘W：いまのウィンドウを閉じる
    @objc func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    private func applyConfig() {
        for w in windows { w.apply(config) }
    }

    /// キラキラに使う色：カーソル色＋テーマのピンク・青・水色
    private var sparkleColors: [CGColor] {
        let c = Colors(config)
        return [c.cursor.cgColor, c.palette[5].cgColor, c.palette[4].cgColor, c.palette[6].cgColor]
    }

    // MARK: - 設定ファイルの変更を見張って自動で再読み込み

    /// 設定ファイルを見張る。
    /// ・フォルダ：エディタが別ファイルに書いて置き換える保存方法（多くのエディタ）に気づける
    /// ・ファイル本体：その場で上書きする保存方法に気づける。置き換えられたら見張り直す
    private func watchConfig() {
        lastConfigText = (try? String(contentsOfFile: Config.path, encoding: .utf8)) ?? ""
        let fd = open(Config.dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            self?.scheduleConfigCheck()
            self?.watchConfigFile()      // 置き換えられたファイルを見張り直す
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatch = src
        watchConfigFile()
    }

    private func watchConfigFile() {
        configFileWatch?.cancel()
        configFileWatch = nil
        let fd = open(Config.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .extend, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self else { return }
            self.scheduleConfigCheck()
            if let e = src?.data, e.contains(.delete) || e.contains(.rename) {
                // ファイルが置き換えられた：少し待ってから新しいファイルを見張り直す
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.watchConfigFile() }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configFileWatch = src
    }

    /// 少し待ってから読み直す（保存は何回かに分かれて届くので、まとめて1回にする）。中身が変わったときだけ反映
    private func scheduleConfigCheck() {
        reloadWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let text = (try? String(contentsOfFile: Config.path, encoding: .utf8)) ?? ""
            if text != self.lastConfigText {
                self.lastConfigText = text
                self.reloadConfig()
            }
        }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    // MARK: - 出し入れ（ホットキー）

    /// Dock や Finder から開いたとき：隠れていれば出す、出ていれば前に持ってくる
    @objc func openTerminal() {
        if windows.contains(where: { $0.window.isVisible }) {
            NSApp.activate(ignoringOtherApps: true)
            (keyTermWindow ?? windows.last(where: { $0.window.isVisible }))?.window.makeKeyAndOrderFront(nil)
        } else {
            showAll()
        }
    }

    /// ホットキー：前に出ていれば全部しまう。しまってあれば全部出す
    @objc func toggle() {
        if fx.isSummoning || hiding { return }
        let shown = windows.filter { $0.window.isVisible && !$0.window.isMiniaturized }
        if NSApp.isActive && !shown.isEmpty && keyTermWindow != nil {
            hideAll()
        } else if !shown.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            (keyTermWindow ?? shown.last)?.window.makeKeyAndOrderFront(nil)
        } else {
            showAll()
        }
    }

    /// しまってあったウィンドウを全部出す（1枚もなければ新しく開く）
    private func showAll() {
        guard !fx.isSummoning, !hiding else { return }
        var list = hidden.filter { w in windows.contains { $0 === w } }
        hidden = []
        if list.isEmpty { list = windows.filter { !$0.window.isVisible && !$0.window.isMiniaturized } }
        if list.isEmpty, let mini = windows.last(where: { $0.window.isMiniaturized }) {
            NSApp.activate(ignoringOtherApps: true)
            mini.window.deminiaturize(nil)
            return
        }
        if list.isEmpty && windows.isEmpty { newWindow(); return }
        lastKind = pickKind()
        for w in list {
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.window.frame) }) {
                centerOnMouseScreen(w.window)
            }
            appear(w, kind: lastKind)
        }
    }

    /// 出現アニメつきで前に出す（最後に出したものがキーになる）
    private func appear(_ w: TermWindow, kind: SummonKind? = nil) {
        let k = kind ?? pickKind()
        lastKind = k
        let anim = SummonFX(kind: k, showing: true, window: w.window, box: w.box,
                            colors: sparkleColors, speed: max(0.1, min(10, config.double("summon.speed"))), blur: w.blurRadius,
                            setBlur: { [weak w] r in w?.setBlur(r) }) {}
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
        w.window.makeFirstResponder(w.termView)
        fx.add(anim, near: w.window)
    }

    /// 出ているウィンドウを全部しまって、前のアプリに戻る
    @objc func hideAll() {
        let shown = windows.filter { $0.window.isVisible && !$0.window.isMiniaturized }
        guard !shown.isEmpty, !fx.isSummoning, !hiding else { return }
        hiding = true
        hidden = shown
        var left = shown.count
        for w in shown {
            let anim = SummonFX(kind: lastKind, showing: false, window: w.window, box: w.box,
                                colors: sparkleColors, speed: max(0.1, min(10, config.double("summon.speed"))), blur: w.blurRadius,
                                setBlur: { [weak w] r in w?.setBlur(r) }) { [weak self, weak w] in
                w?.window.orderOut(nil)
                left -= 1
                if left == 0 {
                    self?.hiding = false
                    NSApp.hide(nil)
                }
            }
            fx.add(anim, near: w.window)
        }
    }

    /// マウスがある画面の真ん中（少し上）に置く
    private func centerOnMouseScreen(_ win: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { win.center(); return }
        let vf = scr.visibleFrame
        let s = win.frame.size
        win.setFrameOrigin(NSPoint(x: vf.midX - s.width / 2, y: vf.midY - s.height / 2 + vf.height * 0.06))
    }

    /// random のときは random_pool の中から（直前と同じのは避ける）
    private func pickKind() -> SummonKind {
        let name = config.string("summon.animation")
        if name != "random", let k = SummonKind(rawValue: name) { return k }
        var pool = config.strings("summon.random_pool").compactMap { SummonKind(rawValue: $0) }
        if pool.isEmpty { pool = SummonKind.allCases }
        if pool.count > 1 { pool.removeAll { $0 == lastKind } }
        return pool.randomElement() ?? .fade
    }

    // MARK: - 遊び心（どのウィンドウでも）

    private func bell(_ w: TermWindow) {
        if config.bool("fx.bell_sound") { NSSound.beep() }
        guard config.bool("fx.bell_shake"), w.window.isVisible, !fx.isSummoning, !fx.isShaking else { return }
        fx.add(ShakeFX(window: w.window), near: w.window)
    }

    /// エンター：カーソル位置からキラキラが多めにはじける
    private func enterBurst(_ w: TermWindow, _ r: NSRect) {
        guard config.bool("fx.enter_burst"), w.window.isVisible, !fx.isSummoning else { return }
        let n = max(0, min(80, config.int("fx.enter_sparkles", 0, 80)))
        let accent = w.accent.cgColor
        let white = w.sparklesTinted ? accent : CGColor(gray: 1, alpha: 1)
        let pt = CGPoint(x: r.midX, y: r.midY)
        for i in 0..<n {
            fx.add(SparkFX(at: pt, color: i % 3 == 0 ? white : accent, burst: true), near: w.window)
        }
    }

    /// 文字を消したとき：まわりのキラキラが、消えた文字に吸い込まれていく
    private func deleteSuck(_ w: TermWindow, _ r: NSRect) {
        guard config.bool("fx.delete_sparkles"), w.window.isVisible, !fx.isSummoning else { return }
        let c = w.accent.cgColor
        let center = CGPoint(x: r.midX, y: r.midY)
        let n = max(0, min(40, config.int("fx.delete_sparkle_count", 0, 40)))
        for i in 0..<n {
            fx.add(SuckFX(into: center, color: i % 3 == 0 && !w.sparklesTinted ? CGColor(gray: 1, alpha: 1) : c), near: w.window)
        }
    }

    private func typeTrail(_ w: TermWindow, _ r: NSRect) {
        guard config.bool("fx.cursor_trail"), w.window.isVisible, !fx.isSummoning else { return }
        let c = w.accent.cgColor
        let pt = CGPoint(x: r.midX, y: r.minY + r.height * 0.3)
        let n = max(0, min(20, config.int("fx.trail_sparkles", 0, 20)))
        for i in 0..<n {
            fx.add(SparkFX(at: pt, color: i % 2 == 0 || w.sparklesTinted ? c : CGColor(gray: 1, alpha: 1)), near: w.window)
        }
    }

    // MARK: - ホットキー（Carbon。アクセシビリティ権限いらず）

    private func registerHotKey() {
        if let r = hotKeyRef { _ = UnregisterEventHotKey(r); hotKeyRef = nil }
        guard let hk = parseHotKey(config.string("hotkey.key")) else {
            NSLog("Terminail: could not parse hotkey")
            return
        }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            _ = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                NotificationCenter.default.post(name: .terminailToggle, object: nil)
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x4C59_4C41), id: 1)   // 'LYLA'
        _ = RegisterEventHotKey(hk.code, hk.mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func parseHotKey(_ s: String) -> (code: UInt32, mods: UInt32)? {
        var mods: UInt32 = 0
        var code: UInt32?
        for part in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default: if let k = Self.keyCodes[part] { code = UInt32(k) }
            }
        }
        guard let c = code else { return nil }
        return (c, mods)
    }

    private static let keyCodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    // MARK: - メニュー

    private func menuItem(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private let fixedWindowItems = 3

    /// Window メニューを開くたびに、今のウィンドウの一覧で作り直す
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === windowsMenu else { return }
        // 先頭の固定の項目はそのまま（⌘N / ⌘T などが効くように）、その下の一覧だけ作り直す
        while menu.items.count > fixedWindowItems { menu.removeItem(at: fixedWindowItems) }
        // 出ているウィンドウを開いた順に並べて、Terminail 1, 2, … と詰めて番号を振る（途中を閉じたら振り直し）
        let open = windows.filter { $0.window.isVisible }.sorted { $0.seq < $1.seq }
        guard !open.isEmpty else { return }
        menu.addItem(.separator())
        let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Active")
        for (i, w) in open.enumerated() {
            w.window.title = "Terminail \(i + 1)"
            let item = NSMenuItem(title: w.window.title, action: #selector(focusWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = w
            item.onStateImage = sparkle
            item.state = w.window.isKeyWindow || (NSApp.keyWindow == nil && w.window.isMainWindow) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc func focusWindow(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? TermWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Terminail")
        appMenu.addItem(NSMenuItem(title: "About Terminail",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Settings…", #selector(openConfig), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Terminail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Window：新規・タブ・閉じる・開いているウィンドウの一覧（一覧は開くたびに作り直す）
        let windowItem = NSMenuItem()
        let wm = NSMenu(title: "Window")
        wm.addItem(menuItem("New Window", #selector(newWindow), "n"))
        wm.addItem(menuItem("New Tab", #selector(newTab), "t"))
        wm.addItem(menuItem("Close Window", #selector(closeWindow), "w"))
        wm.delegate = self
        windowItem.submenu = wm
        main.addItem(windowItem)
        windowsMenu = wm

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(TerminalView.doCopy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(TerminalView.doPaste(_:)), keyEquivalent: "v"))
        edit.addItem(.separator())
        edit.addItem(menuItem("Find…", #selector(find), "f"))
        edit.addItem(.separator())
        edit.addItem(menuItem("New Log…", #selector(newLog)))
        edit.addItem(menuItem("Stop Log", #selector(stopLog)))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc func openConfig() {
        let url = URL(fileURLWithPath: Config.path)
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func reloadConfig() {
        config = Config.load()
        applyConfig()
        registerHotKey()
        updateSecureInput()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

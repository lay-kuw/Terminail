import AppKit

/// トーストに付けるボタン（AI の承認・拒否など）
struct ToastAction {
    let title: String
    let primary: Bool       // 色つき（はい）か、枠だけ（いいえ）か
    let run: () -> Void
}

/// 長いコマンドが終わったときに、画面の右上に出る小さな丸いお知らせ。
/// すっと降りてきて、数秒で消える。クリックするとそのタブへ。重なったら下に並ぶ。
final class Toaster {
    private final class Toast {
        let panel: NSPanel
        let onClick: () -> Void
        let key: String?
        init(panel: NSPanel, key: String?, onClick: @escaping () -> Void) {
            self.panel = panel
            self.key = key
            self.onClick = onClick
        }
    }
    private var toasts: [Toast] = []
    private static let height: CGFloat = 32
    private static let gap: CGFloat = 8

    /// actions があるトースト（AI の承認待ちなど）は、答えるか dismiss(key:) されるまで出しっぱなし
    func show(icon: String, iconColor: NSColor, text: String, fg: NSColor, bg: NSColor,
              near win: NSWindow, actions: [ToastAction] = [], key: String? = nil, onClick: @escaping () -> Void) {
        if let key { dismiss(key: key) }      // 同じ画面の前の知らせは、新しいものに置きかえる
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let str = NSMutableAttributedString(string: icon + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: iconColor])
        str.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg]))
        let buttons = actions.map { ToastView.Button(title: $0.title, primary: $0.primary) }
        let textW = min(actions.isEmpty ? 390 : 300, ceil(str.size().width))
        let w = textW + 30 + ToastView.buttonsWidth(buttons)
        let h = Self.height

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let view = ToastView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.text = str
        view.buttons = buttons
        view.accent = iconColor
        view.fg = fg
        view.wantsLayer = true
        view.layer?.cornerRadius = h / 2
        view.layer?.masksToBounds = true
        let glass = GlassView(frame: view.bounds)
        glass.corner = h / 2
        glass.radius = 20
        glass.autoresizingMask = [.width, .height]
        let tint = NSView(frame: view.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = bg.withAlphaComponent(0.72).cgColor
        tint.layer?.cornerRadius = h / 2
        tint.layer?.borderWidth = 1
        tint.layer?.borderColor = iconColor.withAlphaComponent(0.55).cgColor
        tint.autoresizingMask = [.width, .height]
        let root = NSView(frame: view.bounds)
        root.addSubview(glass)
        root.addSubview(tint)
        root.addSubview(view)
        panel.contentView = root

        let toast = Toast(panel: panel, key: key, onClick: onClick)
        view.onClick = { [weak self, weak toast] in
            guard let toast else { return }
            toast.onClick()
            self?.dismiss(toast)
        }
        view.onButton = { [weak self, weak toast] i in
            guard let toast, actions.indices.contains(i) else { return }
            actions[i].run()
            self?.dismiss(toast)
        }
        toasts.append(toast)

        // ウィンドウがある画面の右上（ウィンドウがしまってあればマウスのある画面）
        let scr = (win.isVisible ? win.screen : nil)
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let vf = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let target = origin(for: toasts.count - 1, width: w, in: vf)
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y + 12))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(target)
        }
        guard actions.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self, weak toast] in
            if let toast { self?.dismiss(toast) }
        }
    }

    private func origin(for i: Int, width: CGFloat, in vf: NSRect) -> NSPoint {
        NSPoint(x: vf.maxX - width - 16, y: vf.maxY - 16 - Self.height - CGFloat(i) * (Self.height + Self.gap))
    }

    /// その画面の知らせを消す（AI の承認待ちが終わったときなど）
    func dismiss(key: String) {
        for t in toasts where t.key == key { dismiss(t) }
    }

    private func dismiss(_ t: Toast) {
        guard let i = toasts.firstIndex(where: { $0 === t }) else { return }
        toasts.remove(at: i)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            t.panel.animator().alphaValue = 0
        }, completionHandler: { t.panel.orderOut(nil) })
        // 下に並んでいたものを詰める
        for (j, other) in toasts.enumerated() {
            guard let vf = other.panel.screen?.visibleFrame else { continue }
            let target = origin(for: j, width: other.panel.frame.width, in: vf)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                other.panel.animator().setFrameOrigin(target)
            }
        }
    }
}

private final class ToastView: NSView {
    struct Button { let title: String; let primary: Bool }
    var text = NSAttributedString()
    var buttons: [Button] = []
    var accent: NSColor = .white
    var fg: NSColor = .white
    var onClick: (() -> Void)?
    var onButton: ((Int) -> Void)?

    private static let buttonFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static func buttonWidth(_ b: Button) -> CGFloat {
        ceil(NSAttributedString(string: b.title, attributes: [.font: buttonFont]).size().width) + 18
    }
    static func buttonsWidth(_ bs: [Button]) -> CGFloat {
        bs.isEmpty ? 0 : bs.reduce(0) { $0 + buttonWidth($1) + 6 } + 2
    }

    /// ボタンの場所（右から並べる）
    private var buttonRects: [NSRect] {
        var x = bounds.maxX - 6
        var out: [NSRect] = []
        for b in buttons.reversed() {
            let w = Self.buttonWidth(b)
            x -= w
            out.insert(NSRect(x: x, y: (bounds.height - 22) / 2, width: w, height: 22), at: 0)
            x -= 6
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = text.size()
        guard !buttons.isEmpty else {
            text.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
            return
        }
        let rects = buttonRects
        let textRight = (rects.first?.minX ?? bounds.maxX) - 8
        text.draw(with: NSRect(x: 14, y: (bounds.height - s.height) / 2, width: max(0, textRight - 14), height: s.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        for (b, r) in zip(buttons, rects) {
            let shape = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            if b.primary {
                accent.setFill()
                shape.fill()
            } else {
                fg.withAlphaComponent(0.3).setStroke()
                NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2 - 0.5, yRadius: r.height / 2 - 0.5).stroke()
            }
            let col = b.primary ? NSColor(white: 0.1, alpha: 0.95) : fg
            let t = NSAttributedString(string: b.title, attributes: [.font: Self.buttonFont, .foregroundColor: col])
            let ts = t.size()
            t.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = buttonRects.firstIndex(where: { $0.contains(p) }) { onButton?(i); return }
        onClick?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

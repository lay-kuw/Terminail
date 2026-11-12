import AppKit

/// 長いコマンドが終わったときに、画面の右上に出る小さな丸いお知らせ。
/// すっと降りてきて、数秒で消える。クリックするとそのタブへ。重なったら下に並ぶ。
final class Toaster {
    private final class Toast {
        let panel: NSPanel
        let onClick: () -> Void
        init(panel: NSPanel, onClick: @escaping () -> Void) { self.panel = panel; self.onClick = onClick }
    }
    private var toasts: [Toast] = []
    private static let height: CGFloat = 32
    private static let gap: CGFloat = 8

    func show(icon: String, iconColor: NSColor, text: String, fg: NSColor, bg: NSColor,
              near win: NSWindow, onClick: @escaping () -> Void) {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let str = NSMutableAttributedString(string: icon + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: iconColor])
        str.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg]))
        let w = min(420, ceil(str.size().width) + 30)
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

        let toast = Toast(panel: panel, onClick: onClick)
        view.onClick = { [weak self, weak toast] in
            guard let toast else { return }
            toast.onClick()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self, weak toast] in
            if let toast { self?.dismiss(toast) }
        }
    }

    private func origin(for i: Int, width: CGFloat, in vf: NSRect) -> NSPoint {
        NSPoint(x: vf.maxX - width - 16, y: vf.maxY - 16 - Self.height - CGFloat(i) * (Self.height + Self.gap))
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
    var text = NSAttributedString()
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let s = text.size()
        text.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

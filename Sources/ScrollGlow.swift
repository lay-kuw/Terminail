import AppKit
import QuartzCore

/// スクロールしたときに右端に出る「すべる光」。
/// 細いレールの上を光の粒がすべり、速く動かすと尾を引いてのびる。止まって1秒ほどで消える。
/// 右端にマウスを持っていくとレールが出て、光の粒をつかんで（レールをクリックして）動かせる。
final class ScrollGlowView: NSView {
    var color: NSColor = .white
    var topInset: CGFloat = 34
    /// マウスで動かしたとき（0 = いちばん古い、1 = 一番下）
    /// 2つ目は、クリックで飛んだとき true（すーっと移動）、つまんで動かしているとき false
    var onDrag: ((CGFloat, Bool) -> Void)?
    /// さかのぼれる履歴があるか（vim の中などでは出さない）
    var canScroll: () -> Bool = { false }

    private var hovering = false
    private var dragging = false
    private var tracking: NSTrackingArea?

    private var pos: CGFloat = 1        // いま描いている位置（0 = いちばん古い、1 = 一番下）
    private var target: CGFloat = 1     // 本当の位置。pos が少し遅れて追いかける
    private var vel: CGFloat = 0
    private var alpha: CGFloat = 0
    private var lastKick: CFTimeInterval = -100
    private var timer: Timer?

    override var isFlipped: Bool { true }

    /// 見えているときだけクリックを受ける（ふだんはターミナルの操作を邪魔しない）
    override func hitTest(_ point: NSPoint) -> NSView? {
        (hovering || dragging || alpha > 0.05) && canScroll() ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseMoved(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }

    private func hover(_ on: Bool) {
        hovering = on && canScroll()
        if hovering { kick() }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        drag(event, jump: true)
    }
    override func mouseDragged(with event: NSEvent) { drag(event, jump: false) }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        kick()
    }

    private func drag(_ e: NSEvent, jump: Bool) {
        let y = convert(e.locationInWindow, from: nil).y
        let bot = bounds.height - 46
        guard bot > topInset else { return }
        onDrag?(max(0, min(1, (y - topInset) / (bot - topInset))), jump)
        kick()
    }

    /// 位置を更新する。動いていないときは、そのまま飛ぶ（見えていないので）
    func setTarget(_ f: CGFloat) {
        target = max(0, min(1, f))
        if timer == nil { pos = target }
    }

    /// 自分でスクロールした：光を出す
    func kick() {
        lastKick = CACurrentMediaTime()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// タブを切り替えたときなど：すぐ消す
    func hide() {
        timer?.invalidate()
        timer = nil
        alpha = 0
        pos = target
        needsDisplay = true
    }

    private func tick() {
        let prev = pos
        // スクロール自体がなめらかに動くので、光の粒はそれにほぼそのままついていく（二重にゆっくりにならないように）
        pos += (target - pos) * (dragging ? 0.6 : 0.4)
        vel = vel * 0.7 + (pos - prev) * 0.3
        let want: CGFloat = hovering || dragging || CACurrentMediaTime() - lastKick < 1 ? 1 : 0
        alpha += (want - alpha) * (want > 0 ? 0.25 : 0.08)
        if alpha < 0.01 && abs(target - pos) < 0.0005 && !hovering && !dragging {
            timer?.invalidate()
            timer = nil
            alpha = 0
            pos = target
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard alpha > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let x = bounds.maxX - 8
        let top = topInset, bot = bounds.height - 46
        guard bot > top + 20 else { return }
        let py = top + pos * (bot - top)
        let c = color

        // レール
        ctx.setStrokeColor(c.withAlphaComponent(0.18 * alpha).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x, y: top))
        ctx.addLine(to: CGPoint(x: x, y: bot))
        ctx.strokePath()

        // 尾（動いている向きの反対側にのびる）
        let len = 6 + min(60, abs(vel) * (bot - top) * 9)
        let dir: CGFloat = vel < 0 ? 1 : -1
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 10, color: c.withAlphaComponent(alpha).cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(3)
        let steps = 12
        for i in 0..<steps {
            let a = CGFloat(i) / CGFloat(steps), b = CGFloat(i + 1) / CGFloat(steps)
            ctx.setStrokeColor(c.withAlphaComponent(alpha * (1 - a)).cgColor)
            ctx.move(to: CGPoint(x: x, y: py + dir * len * a))
            ctx.addLine(to: CGPoint(x: x, y: py + dir * len * b))
            ctx.strokePath()
        }
        // 光の粒（マウスが近くにあるときは、つかめるように少し大きく）
        let r: CGFloat = hovering || dragging ? 3.4 : 2.2
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9 * alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: x - r, y: py - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
    }
}

/// さかのぼっているあいだ右下に出る「一番下へ戻る」ボタン。光の玉から波紋が広がり続ける
final class JumpButton: NSView {
    var onClick: (() -> Void)?
    var color: NSColor = .white { didSet { if color != oldValue { updateColors() } } }

    private let orb = CALayer()
    private let ring = CAShapeLayer()
    private let chevron = CAShapeLayer()
    private(set) var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        let c = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let r: CGFloat = 7

        ring.frame = bounds
        ring.path = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = nil
        ring.lineWidth = 1
        ring.bounds = bounds
        ring.position = c

        orb.frame = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        orb.cornerRadius = r
        orb.shadowOffset = .zero
        orb.shadowRadius = 8
        orb.shadowOpacity = 1

        // 小さな下向きの山形
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x - 3, y: c.y + 1.2))
        p.addLine(to: CGPoint(x: c.x, y: c.y - 1.8))
        p.addLine(to: CGPoint(x: c.x + 3, y: c.y + 1.2))
        chevron.path = p
        chevron.fillColor = nil
        chevron.lineWidth = 1.5
        chevron.lineCap = .round
        chevron.lineJoin = .round
        chevron.strokeColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.15, alpha: 0.9).cgColor

        layer?.addSublayer(ring)
        layer?.addSublayer(orb)
        layer?.addSublayer(chevron)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func updateColors() {
        orb.backgroundColor = color.cgColor
        orb.shadowColor = color.cgColor
        ring.strokeColor = color.withAlphaComponent(0.75).cgColor
    }

    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        if on { startRipple() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = on ? 1 : 0
        }, completionHandler: { [weak self] in
            if let s = self, !s.shown { s.ring.removeAllAnimations() }
        })
    }

    private func startRipple() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.8
        scale.toValue = 2.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [scale, fade]
        g.duration = 1.8
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.repeatCount = .infinity
        ring.add(g, forKey: "ripple")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { shown ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

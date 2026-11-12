import AppKit
import CoreText
import QuartzCore

// MARK: - 演出エンジン
//
// 演出があるときだけ 60fps のタイマーが動き、終わったら止まる。
// 粒子などは、ウィンドウの周りに置いた透明なオーバーレイウィンドウに描く。

protocol FXItem: AnyObject {
    var drawsOverlay: Bool { get }
    /// false を返したら終了
    func step(_ now: CFTimeInterval) -> Bool
    /// 画面座標（左下原点）で描く
    func draw(_ ctx: CGContext)
}

final class OverlayWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class OverlayView: NSView {
    weak var fx: FX?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let fx, let win = window else { return }
        ctx.clear(bounds)
        ctx.translateBy(x: -win.frame.minX, y: -win.frame.minY)
        fx.drawItems(ctx)
    }
}

final class FX {
    private let overlay = OverlayWindow()
    private let canvas = OverlayView()
    private var items: [FXItem] = []
    private var timer: Timer?

    init() {
        canvas.fx = self
        overlay.contentView = canvas
    }

    var isSummoning: Bool { items.contains { $0 is SummonFX } }
    var isShaking: Bool { items.contains { $0 is ShakeFX } }

    func add(_ item: FXItem, near win: NSWindow) {
        items.append(item)
        if item.drawsOverlay {
            let scr = (win.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(win.frame) }) ?? NSScreen.main)?.frame ?? win.frame
            var f = win.frame.insetBy(dx: -360, dy: -360).intersection(scr)
            if f.isEmpty { f = scr }
            if overlay.isVisible { f = f.union(overlay.frame) }
            overlay.level = NSWindow.Level(rawValue: win.level.rawValue + 1)
            if overlay.frame != f { overlay.setFrame(f, display: false) }
            canvas.needsDisplay = true
            if !overlay.isVisible {
                canvas.displayIfNeeded()
                overlay.orderFrontRegardless()
            }
        }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let current = items
        var alive: [FXItem] = []
        for it in current where it.step(now) { alive.append(it) }
        let added = items.filter { n in !current.contains { $0 === n } }   // step 中に追加された分
        items = alive + added
        if items.contains(where: { $0.drawsOverlay }) {
            canvas.needsDisplay = true
        } else if overlay.isVisible {
            overlay.orderOut(nil)
        }
        if items.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    fileprivate func drawItems(_ ctx: CGContext) {
        for it in items where it.drawsOverlay {
            ctx.saveGState()
            it.draw(ctx)
            ctx.restoreGState()
        }
    }
}

// MARK: - 小物

func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

func sparkle(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: CGColor) {
    ctx.setStrokeColor(c)
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: x - r, y: y)); ctx.addLine(to: CGPoint(x: x + r, y: y))
    ctx.move(to: CGPoint(x: x, y: y - r)); ctx.addLine(to: CGPoint(x: x, y: y + r))
    ctx.strokePath()
    ctx.setFillColor(c)
    ctx.fill(CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
}

// MARK: - 出現 / 消える アニメーション

enum SummonKind: String, CaseIterable {
    case fade, particle, glitch
}

/// 出現・消える演出。
/// fade / glitch は p = 0（消えている）〜 1（表示）で、消えるときは逆再生。
/// particle は出るときと消えるときで別の動き（集まってウィンドウになる／ほどけて舞い上がる）。
final class SummonFX: FXItem {
    let kind: SummonKind
    let showing: Bool
    private unowned let win: AppWindow
    private let box: NSView
    private let colors: [CGColor]          // [0] はカーソル色。残りはキラキラに混ぜるテーマの色
    private var accent: CGColor { colors[0] }
    private let blurRadius: Int
    private let setBlur: (Int) -> Void
    private let duration: Double
    private var start: CFTimeInterval = 0
    private let done: () -> Void
    private var p: Double = 0              // 表示の度合い
    private var t: Double = 0              // 経過（0〜1）

    private struct Part {
        var sx, sy: CGFloat     // ウィンドウから遠い側の点
        var cx, cy: CGFloat     // 曲線の制御点（ふわっと回り込む）
        var tx, ty: CGFloat     // ウィンドウ上の点
        var delay: Double
        var phase, speed: Double
        var color: CGColor
        var size: CGFloat
        var star: Bool
    }
    private var parts: [Part] = []
    // glitch 用
    private struct GlitchState {
        var on = true
        var dx: CGFloat = 0
        var ghost: CGFloat = 0
        var slices: [(top: CGFloat, h: CGFloat, dx: CGFloat)] = []
        var blocks: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, white: Bool)] = []
    }
    private var g = GlitchState()
    private var gStep = -1
    private var snap: CGImage?        // ウィンドウの中身の写し

    var drawsOverlay: Bool { kind != .fade }

    init(kind: SummonKind, showing: Bool, window: AppWindow, box: NSView,
         colors: [CGColor], speed: Double, blur: Int, setBlur: @escaping (Int) -> Void, done: @escaping () -> Void) {
        self.kind = kind
        self.showing = showing
        self.win = window
        self.box = box
        self.colors = colors.isEmpty ? [CGColor(gray: 1, alpha: 1)] : colors
        self.blurRadius = blur
        self.setBlur = setBlur
        self.done = done
        let d: Double
        switch kind {
        case .fade: d = 0.2
        case .particle: d = 0.4
        case .glitch: d = 0.4
        }
        duration = d * max(0.1, speed)
        prepare()
        start = CACurrentMediaTime()
        apply(0)
    }

    // MARK: 準備

    private func prepare() {
        win.hasShadow = false
        if kind == .glitch { prepareGlitch() }
        guard kind == .particle else { return }
        let f = win.frame
        let rad = win.cornerRadius
        let white = CGColor(gray: 1, alpha: 1)
        let swirl: CGFloat = Bool.random() ? 1 : -1      // 全体で同じ向きに渦を巻く
        func pick() -> CGColor {
            let r = Double.random(in: 0..<1)
            if r < 0.42 { return white }
            if r < 0.62 { return accent }
            return colors.count > 1 ? colors[Int.random(in: 1..<colors.count)] : accent
        }
        /// 角丸の縁の上のランダムな点
        func onEdge() -> CGPoint {
            let w = f.width - 2 * rad, h = f.height - 2 * rad
            let arc = .pi / 2 * rad
            let total = 2 * w + 2 * h + 4 * arc
            var d = CGFloat.random(in: 0..<total)
            if d < w { return CGPoint(x: f.minX + rad + d, y: f.maxY) }; d -= w
            if d < h { return CGPoint(x: f.maxX, y: f.maxY - rad - d) }; d -= h
            if d < w { return CGPoint(x: f.maxX - rad - d, y: f.minY) }; d -= w
            if d < h { return CGPoint(x: f.minX, y: f.minY + rad + d) }; d -= h
            // 4つの角
            let corner = Int(d / arc), a = (d - CGFloat(corner) * arc) / rad
            let centers = [CGPoint(x: f.maxX - rad, y: f.maxY - rad), CGPoint(x: f.maxX - rad, y: f.minY + rad),
                           CGPoint(x: f.minX + rad, y: f.minY + rad), CGPoint(x: f.minX + rad, y: f.maxY - rad)]
            let base: [CGFloat] = [.pi / 2, 0, -.pi / 2, .pi]
            let c = centers[min(corner, 3)], ang = base[min(corner, 3)] - a
            return CGPoint(x: c.x + cos(ang) * rad, y: c.y + sin(ang) * rad)
        }
        let n = 760
        parts.reserveCapacity(n)
        for i in 0..<n {
            let star = i < 120
            let edge = Double.random(in: 0..<1) < (star ? 0.7 : 0.55)
            let target = edge ? onEdge() : CGPoint(x: f.minX + CGFloat.random(in: 0...f.width), y: f.minY + CGFloat.random(in: 0...f.height))
            // 遠い側の点：出るときは周りから、消えるときは少し上へ舞い上がる
            let ang = CGFloat.random(in: 0..<(2 * .pi))
            let dist = showing ? CGFloat.random(in: 140...380) : CGFloat.random(in: 60...220)
            var far = CGPoint(x: target.x + cos(ang) * dist, y: target.y + sin(ang) * dist)
            if !showing { far.y += CGFloat.random(in: 50...170) }
            let mid = CGPoint(x: (far.x + target.x) / 2, y: (far.y + target.y) / 2)
            let dx = target.x - far.x, dy = target.y - far.y
            let curl = swirl * CGFloat.random(in: 0.2...0.45)
            let ctrl = CGPoint(x: mid.x - dy * curl, y: mid.y + dx * curl)
            // 消えるときは上の方からほどけていく
            let delay = showing
                ? Double.random(in: 0..<0.32) * (edge ? 0.8 : 1)
                : Double.random(in: 0..<0.12) + 0.22 * Double((f.maxY - target.y) / max(1, f.height))
            parts.append(Part(sx: far.x, sy: far.y, cx: ctrl.x, cy: ctrl.y, tx: target.x, ty: target.y,
                              delay: delay, phase: Double.random(in: 0..<(2 * .pi)), speed: Double.random(in: 6...14),
                              color: pick(), size: star ? CGFloat.random(in: 1.6...3.0) : CGFloat.random(in: 1.0...2.1), star: star))
        }
    }

    // MARK: 進行

    func step(_ now: CFTimeInterval) -> Bool {
        let tt = clamp01((now - start) / duration)
        apply(tt)
        if tt >= 1 { finish(); return false }
        return true
    }

    private func apply(_ tt: Double) {
        t = tt
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch kind {
        case .fade:
            p = showing ? tt : 1 - tt
            let e = easeOut(p)
            win.alphaValue = CGFloat(p)
            transform(scale: 0.96 + 0.04 * e, ty: -8 * (1 - e))
        case .particle:
            // 出るとき：キラキラが集まりきる少し前から、ウィンドウがふわっと現れる
            // 消えるとき：ウィンドウが先にほどけて、キラキラだけが残って舞い上がる
            p = showing ? easeOut(clamp01((tt - 0.42) / 0.45)) : 1 - easeOut(clamp01(tt / 0.4))
            win.alphaValue = CGFloat(p)
            transform(scale: 0.985 + 0.015 * p)
        case .glitch:
            p = showing ? tt : 1 - tt
            // 0.04秒ごとにカクッと状態を切り替える（なめらかに動かさないのが「ヴヴッ」のコツ）
            let stepIndex = Int((CACurrentMediaTime() - start) / 0.04)
            if stepIndex != gStep { gStep = stepIndex; rollGlitch() }
            if p >= 0.97 {
                win.alphaValue = 1
                transform()
            } else {
                win.alphaValue = g.on ? CGFloat(0.6 + 0.4 * p) : 0
                transform(tx: g.dx)
            }
        }
        if blurRadius > 0 {
            setBlur(Int(Double(blurRadius) * (kind == .glitch ? p * p * p : p)))
        }
        win.standardWindowButton(.closeButton)?.superview?.alphaValue = kind == .glitch ? (p > 0.95 ? 1 : 0) : CGFloat(p)
    }

    /// box の中心を軸に拡大縮小・移動
    private func transform(scale: Double = 1, tx: CGFloat = 0, ty: Double = 0) {
        guard let layer = box.layer else { return }
        let b = layer.bounds
        let dx = b.width / 2 - layer.anchorPoint.x * b.width
        let dy = b.height / 2 - layer.anchorPoint.y * b.height
        var m = CATransform3DMakeTranslation(-dx, -dy, 0)
        m = CATransform3DConcat(m, CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1))
        m = CATransform3DConcat(m, CATransform3DMakeTranslation(dx + tx, dy + CGFloat(ty), 0))
        layer.transform = m
    }

    private func finish() {
        if showing { reset(); done() } else { done(); reset() }
    }

    private func reset() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
        win.standardWindowButton(.closeButton)?.superview?.alphaValue = 1
        if blurRadius > 0 { setBlur(blurRadius) }
        win.alphaValue = 1
        win.hasShadow = true
        win.invalidateShadow()
        parts = []
        snap = nil
    }

    // MARK: 描画

    func draw(_ ctx: CGContext) {
        switch kind {
        case .particle: drawParticles(ctx)
        case .glitch: drawGlitch(ctx)
        case .fade:
            break
        }
    }

    private func drawParticles(_ ctx: CGContext) {
        let now = CACurrentMediaTime()
        let travel = showing ? 0.58 : 0.7
        for pt in parts {
            let local = (t - pt.delay) / travel            // この粒の進み具合
            if showing && local <= 0 { continue }
            let k = showing ? smooth(clamp01(local)) : easeOut(clamp01(local))
            // 出るとき：遠く → ウィンドウ。消えるとき：ウィンドウ → 遠く
            let u = CGFloat(showing ? k : 1 - k)
            let a1 = 1 - u
            let x = a1 * a1 * pt.sx + 2 * a1 * u * pt.cx + u * u * pt.tx
            let y = a1 * a1 * pt.sy + 2 * a1 * u * pt.cy + u * u * pt.ty
            let tw = 0.55 + 0.45 * sin(pt.phase + now * pt.speed)
            var alpha: Double
            var grow: CGFloat = 1
            if showing {
                let fadeIn = clamp01(local / 0.18)
                let arrived = max(0, local - 1)                 // 着いてからの時間（粒の進み具合の単位）
                alpha = fadeIn * max(0, 1 - arrived / 0.35)
                if arrived > 0 { grow = 1 + CGFloat(max(0, 0.6 - arrived * 2)) }   // 着いた瞬間に少しだけ弾ける
            } else {
                let emerge = local < 0 ? 0.0 : clamp01(local / 0.1)
                alpha = emerge * pow(max(0, 1 - clamp01(local)), 1.3)
                if local < 0 { continue }
            }
            alpha *= tw
            if alpha <= 0.01 { continue }
            ctx.setAlpha(CGFloat(alpha))
            if pt.star {
                sparkle(ctx, x, y, pt.size * grow * CGFloat(0.8 + 0.4 * tw), pt.color)
            } else {
                ctx.setFillColor(pt.color)
                let r = pt.size * grow
                ctx.fillEllipse(in: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r))
            }
        }
        ctx.setAlpha(1)
        if showing { drawShimmer(ctx) }
    }

    // MARK: glitch（画面が乗っ取られるような白黒のデジタルノイズ）

    private func prepareGlitch() {
        guard let view = win.contentView, view.bounds.width > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        snap = rep.cgImage
    }

    private func rollGlitch() {
        let amp = CGFloat(1 - p)
        g.on = p > 0.8 || Double.random(in: 0..<1) < 0.35 + 0.6 * p
        g.dx = (Bool.random() ? -1 : 1) * CGFloat.random(in: 3...13) * amp
        g.ghost = Double.random(in: 0..<1) < 0.6 * Double(amp) ? (Bool.random() ? -1 : 1) * CGFloat.random(in: 4...12) * amp : 0
        let n = Int(((2 + CGFloat.random(in: 0...5)) * amp).rounded())
        g.slices = (0..<n).map { _ in
            (top: CGFloat.random(in: 0...0.92), h: CGFloat.random(in: 0.02...0.16), dx: (Bool.random() ? -1 : 1) * CGFloat.random(in: 10...80) * amp)
        }
        let m = Int(((4 + CGFloat.random(in: 0...10)) * amp).rounded())
        g.blocks = (0..<m).map { _ in
            (x: CGFloat.random(in: 0...1), y: CGFloat.random(in: 0...1), w: CGFloat.random(in: 6...96), h: CGFloat.random(in: 1...6), white: Double.random(in: 0..<1) < 0.55)
        }
    }

    private func drawGlitch(_ ctx: CGContext) {
        guard g.on, p < 0.97 else { return }
        let f = win.frame
        let x0 = f.minX + g.dx
        // 白い残像
        if g.ghost != 0 {
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.07))   // まぶしくならないよう、ごく薄く
            ctx.addPath(CGPath(roundedRect: CGRect(x: x0 + g.ghost, y: f.minY, width: f.width, height: f.height),
                               cornerWidth: win.cornerRadius, cornerHeight: win.cornerRadius, transform: nil))
            ctx.fillPath()
        }
        let img = snap
        // 中身を横に切り裂いて、左右にずらす
        if let src = img {
            let iw = CGFloat(src.width), ih = CGFloat(src.height)
            for s in g.slices {
                let crop = CGRect(x: 0, y: (s.top * ih).rounded(), width: iw, height: max(1, (s.h * ih).rounded()))
                guard let part = src.cropping(to: crop) else { continue }
                let y = f.maxY - (s.top + s.h) * f.height
                ctx.draw(part, in: CGRect(x: x0 + s.dx, y: y, width: f.width, height: s.h * f.height))
            }
        }
        // 白と黒のデジタルノイズ
        for b in g.blocks {
            ctx.setFillColor(CGColor(gray: b.white ? 1 : 0, alpha: 0.9))
            ctx.fill(CGRect(x: x0 + b.x * (f.width - b.w), y: f.minY + b.y * (f.height - b.h), width: b.w, height: b.h))
        }
    }

    /// 現れる瞬間に、ガラスの上を光がすっと横切る
    private func drawShimmer(_ ctx: CGContext) {
        let s = clamp01((t - 0.55) / 0.4)
        guard s > 0 && s < 1 else { return }
        let f = win.frame
        let band = f.width * 0.22
        let x = f.minX - band + (f.width + band * 2) * CGFloat(smooth(s))
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: f, cornerWidth: win.cornerRadius, cornerHeight: win.cornerRadius, transform: nil))
        ctx.clip()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x - band / 2 + 60, y: f.maxY))
        path.addLine(to: CGPoint(x: x + band / 2 + 60, y: f.maxY))
        path.addLine(to: CGPoint(x: x + band / 2 - 60, y: f.minY))
        path.addLine(to: CGPoint(x: x - band / 2 - 60, y: f.minY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: CGFloat(0.09 * sin(Double.pi * s))))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - ビープでぶるっ

final class ShakeFX: FXItem {
    private unowned let win: NSWindow
    private let base: NSPoint
    private let start = CACurrentMediaTime()
    private static let keys: [CGFloat] = [0, -7, 6, -5, 4, -3, 2, -1, 0]
    var drawsOverlay: Bool { false }

    init(window: NSWindow) {
        win = window
        base = window.frame.origin
    }

    func step(_ now: CFTimeInterval) -> Bool {
        let t = (now - start) / 0.38
        if t >= 1 { win.setFrameOrigin(base); return false }
        let f = t * Double(Self.keys.count - 1)
        let i = Int(f)
        let fr = CGFloat(f - Double(i))
        let dx = Self.keys[i] + (Self.keys[i + 1] - Self.keys[i]) * fr
        win.setFrameOrigin(NSPoint(x: base.x + dx, y: base.y))
        return true
    }

    func draw(_ ctx: CGContext) {}
}

// MARK: - キラキラ（タイプ中は少し、エンターでは多めにはじける）

final class SparkFX: FXItem {
    private var x, y, vx, vy: CGFloat
    private var life: Double = 0
    private let maxLife: Double
    private let size: CGFloat
    private let phase: Double
    private let color: CGColor
    private var last = CACurrentMediaTime()
    var drawsOverlay: Bool { true }

    init(at p: CGPoint, color: CGColor, burst: Bool = false) {
        x = p.x
        y = p.y
        if burst {
            let a = CGFloat.random(in: 0..<(2 * .pi))
            let v = CGFloat.random(in: 0.8...2.6)
            vx = cos(a) * v
            vy = sin(a) * v + 0.8
            maxLife = Double.random(in: 0.6...1.1)
            size = CGFloat.random(in: 2...4.5)
        } else {
            vx = CGFloat.random(in: -0.6...0.6)
            vy = CGFloat.random(in: 0.2...1.0)
            maxLife = Double.random(in: 0.45...0.8)
            size = CGFloat.random(in: 1.5...3.5)
        }
        phase = Double.random(in: 0..<(2 * .pi))
        self.color = color
    }

    func step(_ now: CFTimeInterval) -> Bool {
        let dt = min(0.05, now - last)
        last = now
        life += dt
        let fr = CGFloat(dt * 60)
        vy -= 0.05 * fr
        x += vx * fr
        y += vy * fr
        return life < maxLife
    }

    func draw(_ ctx: CGContext) {
        let k = life / maxLife
        let tw = 0.5 + 0.5 * abs(sin(phase + life * 18))
        ctx.setAlpha(CGFloat((1 - k) * tw))
        sparkle(ctx, x, y, size * CGFloat(1 - k * 0.5) + 1, color)
    }
}

// MARK: - 文字を消したとき、キラキラが吸い込まれていく

final class SuckFX: FXItem {
    private let cx, cy: CGFloat          // 吸い込まれる先（消えた文字）
    private let ox, oy: CGFloat          // 出てくる場所（中心からのずれ）
    private let delay: Double
    private let duration: Double
    private let size: CGFloat
    private let twist: CGFloat           // 吸い込まれながら少し回る
    private let phase: Double
    private let color: CGColor
    private let start = CACurrentMediaTime()
    var drawsOverlay: Bool { true }

    init(into center: CGPoint, color: CGColor) {
        cx = center.x
        cy = center.y
        let a = CGFloat.random(in: 0..<(2 * .pi))
        let r = CGFloat.random(in: 12...26)
        ox = cos(a) * r
        oy = sin(a) * r
        delay = Double.random(in: 0..<0.06)
        duration = Double.random(in: 0.2...0.3)
        size = CGFloat.random(in: 1.4...2.8)
        twist = CGFloat.random(in: -0.9...0.9)
        phase = Double.random(in: 0..<(2 * .pi))
        self.color = color
    }

    func step(_ now: CFTimeInterval) -> Bool { now - start < delay + duration }

    func draw(_ ctx: CGContext) {
        let now = CACurrentMediaTime()
        let k = clamp01((now - start - delay) / duration)
        guard k > 0 else { return }
        let e = CGFloat(k * k)                       // だんだん速く吸い込まれる
        let ang = twist * e
        let rx = ox * cos(ang) - oy * sin(ang), ry = ox * sin(ang) + oy * cos(ang)
        let x = cx + rx * (1 - e), y = cy + ry * (1 - e)
        let tw = 0.6 + 0.4 * sin(phase + now * 30)
        let appear = min(1, k / 0.2)
        ctx.setAlpha(CGFloat(appear * tw) * (1 - e * 0.5))
        sparkle(ctx, x, y, size * (1 - e * 0.7) + 0.6, color)
    }
}


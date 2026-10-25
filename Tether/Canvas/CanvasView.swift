import UIKit

private final class LatestGen {
    private var v = 0
    private let lock = NSLock()
    func set(_ n: Int) { lock.lock(); v = n; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return v }
}

extension CGAffineTransform {
    var scaleFactor: CGFloat { sqrt(abs(a * d - b * c)) }
    var isFlipped: Bool { (a * d - b * c) < 0 }
    /// Rotation angle, ignoring a horizontal flip.
    var angle: CGFloat { isFlipped ? atan2(-b, -a) : atan2(b, a) }
}

/// The drawing surface. Committed artwork is rendered off the main thread into three bitmaps
/// (layers below the current one, the current layer, layers above) that Core Animation composites.
/// While a stroke is in progress it is drawn as a vector shape layer, so drawing never waits on a re-render.
final class CanvasView: UIView, UIPencilInteractionDelegate {
    private unowned let model: AppModel
    private(set) var view: CGAffineTransform = .identity          // canvas units → screen points
    private var renderedView: CGAffineTransform = .identity       // view the bitmaps were rendered with
    private var fullDirty = true
    private var lastSize: CGSize = .zero

    // layers
    private let pageLayer = CALayer()
    private let contentLayer = CALayer()
    private let belowLayer = CALayer()
    private let activeLayer = CALayer()
    private let aboveLayer = CALayer()
    private let liveContainer = CALayer()
    private let liveClip = CAShapeLayer()
    private let liveLayer = CAShapeLayer()
    private let eraseMask = CALayer()
    private let eraseHole = CAShapeLayer()
    private let erasePartial = CAShapeLayer()
    private let overlay = CALayer()
    private let ropeLine = CAShapeLayer()
    private let tipDot = CAShapeLayer()
    private let penRing = CAShapeLayer()
    private let reach = CAShapeLayer()
    private let cursorRing = CAShapeLayer()
    private let cursorRingInner = CAShapeLayer()
    private let loupeTop = CAShapeLayer()
    private let loupeBottom = CAShapeLayer()

    // rendering
    private let renderQueue = DispatchQueue(label: "ink.tether.render", qos: .userInitiated)
    private let latest = LatestGen()
    private var renderGen = 0
    private var pending: [(layer: CAShapeLayer, gen: Int)] = []
    private var pendingErase: [(path: CGPath, opacity: Double, gen: Int)] = []
    private var settleWork: DispatchWorkItem?
    private var displayLink: CADisplayLink?
    private var anim: (from: (s: CGFloat, a: CGFloat, tx: CGFloat, ty: CGFloat), to: CGAffineTransform, start: CFTimeInterval, flip: Bool)?

    // input state
    private final class Stroke {
        let id: ObjectIdentifier?
        let brush: Brush
        let erase: Bool
        let whole: Bool
        var smoother: Smoother
        var emitter: CurveEmitter
        var raw: [V2] = []
        var tip: V2
        var pen: V2
        let startScreen: CGPoint
        let t0: CFTimeInterval
        let color: String
        let opacity: Double
        let isPencil: Bool
        let isFinger: Bool
        var preview: [Double]? = nil
        var snapped: SnappedShape? = nil
        var snapPts: [Double] = []
        var snapP = 0.5
        var removed: [(layer: Layer, item: Item, index: Int)] = []
        var holdAnchor: CGPoint
        var holdWork: DispatchWorkItem?
        init(id: ObjectIdentifier?, brush: Brush, erase: Bool, smoother: Smoother, emitter: CurveEmitter, at p: V2, screen: CGPoint, color: String, opacity: Double, isPencil: Bool, isFinger: Bool) {
            self.id = id; self.brush = brush; self.erase = erase; self.whole = erase && brush.mode == "whole"
            self.smoother = smoother; self.emitter = emitter; self.tip = p; self.pen = p; self.startScreen = screen
            self.t0 = CACurrentMediaTime(); self.color = color; self.opacity = opacity; self.isPencil = isPencil; self.isFinger = isFinger
            self.holdAnchor = screen
        }
    }
    private var stroke: Stroke?

    private struct Finger { var p: CGPoint; var start: CGPoint; var picker = false }
    private var fingers: [ObjectIdentifier: Finger] = [:]
    private var fingerOrder: [ObjectIdentifier] = []
    private final class Gesture {
        let t0 = CACurrentMediaTime()
        var maxCount: Int
        var moved = false
        let s0: CGFloat
        let vStart: CGAffineTransform
        var v0: CGAffineTransform
        var base: [CGPoint] = []
        var picking = false
        var longWork: DispatchWorkItem?
        init(count: Int, view: CGAffineTransform) { maxCount = count; s0 = view.scaleFactor; vStart = view; v0 = view }
    }
    private var gesture: Gesture?
    private var pick: (p: CGPoint, prev: String, color: String)?
    private var pickTouch: ObjectIdentifier?
    private var cursor: CGPoint?
    private var lastPencilAction: CFTimeInterval = 0

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.17, green: 0.17, blue: 0.19, alpha: 1) : UIColor(red: 0.83, green: 0.83, blue: 0.855, alpha: 1) }
        setupLayers()
        let pi = UIPencilInteraction()
        pi.delegate = self
        addInteraction(pi)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        addGestureRecognizer(scroll)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onTrackpadPinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pinch.cancelsTouchesInView = false
        addGestureRecognizer(pinch)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    private func setupLayers() {
        for l in [pageLayer, contentLayer, belowLayer, activeLayer, aboveLayer, liveContainer, overlay, eraseMask] {
            l.anchorPoint = .zero
            l.position = .zero
        }
        pageLayer.shadowColor = UIColor.black.cgColor
        pageLayer.shadowOpacity = 0.28
        pageLayer.shadowOffset = .zero
        layer.addSublayer(pageLayer)
        layer.addSublayer(contentLayer)
        contentLayer.addSublayer(belowLayer)
        contentLayer.addSublayer(activeLayer)
        contentLayer.addSublayer(aboveLayer)
        activeLayer.addSublayer(liveContainer)
        liveContainer.addSublayer(liveLayer)
        liveContainer.mask = liveClip
        liveLayer.fillRule = .nonZero
        for l in [belowLayer, activeLayer, aboveLayer] { l.contentsGravity = .resize; l.magnificationFilter = .linear }
        eraseHole.fillRule = .evenOdd
        eraseHole.fillColor = UIColor.black.cgColor
        erasePartial.fillColor = UIColor.black.cgColor
        eraseMask.addSublayer(eraseHole)
        eraseMask.addSublayer(erasePartial)
        layer.addSublayer(overlay)
        for l in [ropeLine, tipDot, penRing, reach, cursorRing, cursorRingInner, loupeTop, loupeBottom] {
            l.fillColor = UIColor.clear.cgColor
            overlay.addSublayer(l)
        }
        ropeLine.lineWidth = 1.5
        penRing.lineWidth = 1.5
        reach.lineWidth = 1
        cursorRing.lineWidth = 1
        cursorRingInner.lineWidth = 1
        loupeTop.lineWidth = 16
        loupeBottom.lineWidth = 16
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let s = window?.screen.scale ?? UIScreen.main.scale
        for l in [pageLayer, contentLayer, belowLayer, activeLayer, aboveLayer, liveContainer, liveLayer, overlay, eraseMask, eraseHole, erasePartial, liveClip,
                  ropeLine, tipDot, penRing, reach, cursorRing, cursorRingInner, loupeTop, loupeBottom] { l.contentsScale = s }
        becomeFirstResponder()
    }

    private var screenScale: CGFloat { window?.screen.scale ?? UIScreen.main.scale }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize, bounds.width > 1, bounds.height > 1 else { return }
        let first = lastSize == .zero
        let dw = bounds.width - lastSize.width, dh = bounds.height - lastSize.height
        lastSize = bounds.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [contentLayer, belowLayer, activeLayer, aboveLayer, liveContainer, overlay, eraseMask] { l.bounds = CGRect(origin: .zero, size: bounds.size) }
        liveLayer.frame = CGRect(origin: .zero, size: bounds.size)
        CATransaction.commit()
        if first || model.doc == nil { view = fitTransform() } else { view = view.concatenating(CGAffineTransform(translationX: dw / 2, y: dh / 2)) }
        fullDirty = true
        applyViewTransforms()
        updatePage()
        requestRender()
    }

    // MARK: - coordinates

    func toDoc(_ p: CGPoint) -> CGPoint { p.applying(view.inverted()) }
    func toScreen(_ v: V2) -> CGPoint { CGPoint(x: v.x, y: v.y).applying(view) }
    var zoom: CGFloat { view.scaleFactor }

    func fitTransform() -> CGAffineTransform {
        guard let d = model.doc, bounds.width > 1 else { return .identity }
        let topH: CGFloat = 60 + safeAreaInsets.top
        let side: CGFloat = 76
        let aw = max(50, bounds.width - side * 2), ah = max(50, bounds.height - topH - 40)
        let s = min(aw / CGFloat(d.w), ah / CGFloat(d.h))
        let cx = bounds.midX, cy = topH + (bounds.height - topH) / 2
        var v = CGAffineTransform(translationX: -CGFloat(d.w) / 2, y: -CGFloat(d.h) / 2)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        if view.isFlipped { v = v.concatenating(flipAbout(cx)) }
        return v
    }
    private func flipAbout(_ cx: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: -cx, y: 0).concatenating(CGAffineTransform(scaleX: -1, y: 1)).concatenating(CGAffineTransform(translationX: cx, y: 0))
    }
    func flipView() { setView(view.concatenating(flipAbout(bounds.midX))); model.toast(view.isFlipped ? "View flipped" : "View restored") }

    func setView(_ v: CGAffineTransform, live: Bool = false) {
        view = v
        fullDirty = true
        applyViewTransforms()
        refreshOverlay()
        if !live { scheduleSettle(0) }
    }

    private func applyViewTransforms() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageLayer.setAffineTransform(view)
        let s = max(view.scaleFactor, 0.0001)
        pageLayer.shadowRadius = 14 / s
        contentLayer.setAffineTransform(renderedView.inverted().concatenating(view))
        CATransaction.commit()
    }

    private func updatePage() {
        guard let d = model.doc else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageLayer.bounds = CGRect(x: 0, y: 0, width: d.w, height: d.h)
        pageLayer.shadowPath = CGPath(rect: pageLayer.bounds, transform: nil)
        if d.bgOn { pageLayer.backgroundColor = cgColor(hex: d.bg) }
        else { pageLayer.backgroundColor = CanvasView.checker.cgColor }
        activeLayer.opacity = Float(d.activeLayer.opacity)
        activeLayer.isHidden = !d.activeLayer.visible
        CATransaction.commit()
    }

    private static let checker: UIColor = {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            UIColor(white: 0.85, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); c.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        }
        return UIColor(patternImage: img)
    }()

    // MARK: - rendering

    func docOpened() {
        stroke = nil
        pending.forEach { $0.layer.removeFromSuperlayer() }
        pending = []; pendingErase = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        belowLayer.contents = nil; activeLayer.contents = nil; aboveLayer.contents = nil
        liveLayer.path = nil; activeLayer.mask = nil
        CATransaction.commit()
        view = fitTransform()
        renderedView = view
        fullDirty = true
        applyViewTransforms()
        updatePage()
        requestRender()
        GeometryCache.shared.trim(keep: Set(model.doc?.layers.flatMap { $0.items.map { $0.id } } ?? []))
    }

    func contentChanged(activeOnly: Bool) {
        if !activeOnly { fullDirty = true }
        updatePage()
        requestRender()
    }

    @discardableResult func requestRender() -> Int {
        guard let d = model.doc, bounds.width > 1, bounds.height > 1 else { return renderGen }
        renderGen += 1
        let gen = renderGen
        let scale = screenScale
        let job = DocRenderer.ScreenJob(layers: d.layers.map(LayerSnap.init), active: d.activeIndex, docW: d.w, docH: d.h, view: view,
                                        pxW: Int((bounds.width * scale).rounded()), pxH: Int((bounds.height * scale).rounded()), scale: scale,
                                        activeOnly: !fullDirty)
        latest.set(gen)
        let latest = self.latest
        renderQueue.async {
            if latest.get() != gen { return }
            let r = DocRenderer.renderScreen(job)
            DispatchQueue.main.async { [weak self] in self?.apply(r, gen: gen) }
        }
        return gen
    }

    private func apply(_ r: DocRenderer.ScreenResult, gen: Int) {
        guard gen == renderGen else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !r.activeOnly {
            belowLayer.contents = r.below
            aboveLayer.contents = r.above
            fullDirty = false
        }
        activeLayer.contents = r.active
        renderedView = r.view
        contentLayer.setAffineTransform(renderedView.inverted().concatenating(view))
        if let d = model.doc {
            liveClip.path = CGPath(rect: CGRect(x: 0, y: 0, width: d.w, height: d.h), transform: [renderedView])
        }
        pending.removeAll { if $0.gen <= gen { $0.layer.removeFromSuperlayer(); return true }; return false }
        pendingErase.removeAll { $0.gen <= gen }
        CATransaction.commit()
        updateEraseMask()
    }

    private func scheduleSettle(_ delay: Double) {
        settleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.requestRender() }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: - live stroke

    private func updateLive() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit(); updateEraseMask(); refreshOverlay() }
        guard let st = stroke, !st.whole else { liveLayer.path = nil; return }
        var shape = st.brush.shape
        shape.sim = !st.isPencil && st.snapped == nil
        if case .ellipse? = st.snapped { shape.ts = 0; shape.te = 0 }
        let pts = st.snapped != nil ? st.snapPts : (st.preview ?? st.emitter.live())
        let o = StrokeGeometry.outline(pts, shape, last: st.snapped != nil)
        let path = StrokeGeometry.path(o, transform: renderedView)
        if st.erase {
            liveLayer.path = nil
            liveErasePath = path
        } else {
            liveLayer.path = path
            liveLayer.fillColor = cgColor(hex: st.color, alpha: CGFloat(st.opacity))
        }
    }
    private var liveErasePath: CGPath?

    private func updateEraseMask() {
        let paths = pendingErase.map { $0.path } + (liveErasePath.map { [$0] } ?? [])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if paths.isEmpty {
            activeLayer.mask = nil
        } else {
            let hole = CGMutablePath()
            hole.addRect(CGRect(origin: .zero, size: bounds.size).insetBy(dx: -4000, dy: -4000))
            for p in paths { hole.addPath(p) }
            eraseHole.path = hole
            eraseMask.bounds = CGRect(origin: .zero, size: bounds.size)
            let op = stroke?.erase == true ? stroke!.opacity : (pendingErase.last?.opacity ?? 1)
            if op < 0.999 {
                let part = CGMutablePath(); for p in paths { part.addPath(p) }
                erasePartial.path = part
                erasePartial.fillColor = UIColor(white: 0, alpha: CGFloat(1 - op)).cgColor
            } else { erasePartial.path = nil }
            if activeLayer.mask !== eraseMask { activeLayer.mask = eraseMask }
        }
        CATransaction.commit()
    }

    // MARK: - strokes

    private func pressure(_ t: UITouch) -> Double {
        guard t.type == .pencil, t.maximumPossibleForce > 0 else { return 0.5 }
        return clampD(Double(t.force / t.maximumPossibleForce), 0.001, 1)
    }

    private func beginStroke(at p: CGPoint, raw: Double, time: Double, id: ObjectIdentifier?, isPencil: Bool, isFinger: Bool) {
        guard let d = model.doc else { return }
        if !d.activeLayer.visible { model.toast("This layer is hidden. Turn it on in Layers to draw on it."); return }
        let b = model.currentBrush
        let erase = model.tool == .eraser
        let dp = toDoc(p)
        let z = Double(zoom)
        let st = Stroke(id: id, brush: b, erase: erase, smoother: Smoother(model.smoothing(for: b)),
                        emitter: CurveEmitter(minDist: 0.3 / z, spacing: 2 / z), at: V2(Double(dp.x), Double(dp.y)), screen: p,
                        color: model.prefs.color, opacity: erase ? model.prefs.opacityEraser : model.prefs.opacityBrush,
                        isPencil: isPencil, isFinger: isFinger)
        stroke = st
        cursor = nil
        feed(st, p, raw: raw, time: time)
        armHold(st, p)
        updateLive()
    }

    private func feed(_ st: Stroke, _ p: CGPoint, raw: Double, time: Double) {
        let dp = toDoc(p)
        st.pen = V2(Double(dp.x), Double(dp.y))
        if let s = st.snapped {
            if case .line(let a, _) = s { snapLine(st, from: a, to: st.pen) }
            return
        }
        st.raw.append(st.pen)
        let pr = st.isPencil ? model.pressure(raw) : raw
        emit(st, st.smoother.push(Sample(x: Double(p.x), y: Double(p.y), p: pr, t: time)))
    }

    private func emit(_ st: Stroke, _ list: [Sample]) {
        for q in list {
            let dp = toDoc(CGPoint(x: q.x, y: q.y))
            st.emitter.add(Double(dp.x), Double(dp.y), q.p)
            st.tip = V2(Double(dp.x), Double(dp.y))
            if st.whole { eraseWholeAt(st, dp) }
        }
    }

    private func predict(_ st: Stroke, _ touches: [UITouch]) {
        guard st.snapped == nil, !touches.isEmpty else { st.preview = nil; return }
        var sm = st.smoother, em = st.emitter
        for t in touches {
            let p = t.location(in: self)
            let pr = st.isPencil ? model.pressure(pressure(t)) : 0.5
            for q in sm.push(Sample(x: Double(p.x), y: Double(p.y), p: pr, t: t.timestamp * 1000)) {
                let dp = toDoc(CGPoint(x: q.x, y: q.y))
                em.add(Double(dp.x), Double(dp.y), q.p)
            }
        }
        st.preview = em.live()
    }

    private func finishStroke(cancel: Bool) {
        guard let st = stroke else { return }
        stroke = nil
        st.holdWork?.cancel()
        liveErasePath = nil
        guard let d = model.doc else { return }
        if cancel {
            if st.whole && !st.removed.isEmpty { restore(st.removed); model.docChanged(activeOnly: true) }
            CATransaction.begin(); CATransaction.setDisableActions(true); liveLayer.path = nil; CATransaction.commit()
            updateEraseMask(); refreshOverlay()
            return
        }
        var pts: [Double]
        if st.snapped != nil { pts = st.snapPts }
        else { emit(st, st.smoother.flush()); pts = st.emitter.finish() }
        if st.whole {
            if !st.removed.isEmpty {
                let rem = st.removed
                model.push(HistoryEntry("Stroke eraser", undo: { [weak self] in self?.restore(rem) }, redo: {
                    for r in rem { if let i = r.layer.items.firstIndex(where: { $0.id == r.item.id }) { r.layer.items.remove(at: i) } }
                }))
                model.markDirty(); model.docVersion += 1
            }
            refreshOverlay()
            return
        }
        if pts.isEmpty { updateLive(); return }
        var shape = st.brush.shape
        shape.sim = !st.isPencil && st.snapped == nil
        if case .ellipse? = st.snapped { shape.ts = 0; shape.te = 0 }
        var rounded = pts
        for i in 0..<rounded.count { rounded[i] = i % 3 == 2 ? r3(rounded[i]) : r2(rounded[i]) }
        let item = Item.stroke(StrokeItem(id: newID(), m: st.erase ? "e" : "d", c: st.color, o: r3(st.opacity), b: shape, p: rounded))
        let L = d.activeLayer
        L.items.append(item)
        let label = st.erase ? "Erase" : (st.snapped != nil ? "Shape" : "Stroke")
        model.push(HistoryEntry(label, undo: { if let i = L.items.lastIndex(where: { $0.id == item.id }) { L.items.remove(at: i) } }, redo: { L.items.append(item) }))
        // keep showing the stroke as a vector shape until the bitmap that includes it arrives
        let gen = requestRender()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let o = StrokeGeometry.outline(pts, shape, last: true)
        let path = StrokeGeometry.path(o, transform: renderedView)
        if st.erase {
            pendingErase.append((path, st.opacity, gen))
        } else {
            let keep = CAShapeLayer()
            keep.contentsScale = screenScale
            keep.frame = liveLayer.frame
            keep.path = path
            keep.fillColor = cgColor(hex: st.color, alpha: CGFloat(st.opacity))
            liveContainer.insertSublayer(keep, below: liveLayer)
            pending.append((keep, gen))
        }
        liveLayer.path = nil
        CATransaction.commit()
        updateEraseMask()
        refreshOverlay()
        model.markDirty()
        model.docVersion += 1
        if !st.erase { model.rememberColor(st.color) }
    }

    private func restore(_ rem: [(layer: Layer, item: Item, index: Int)]) {
        for r in rem.reversed() { r.layer.items.insert(r.item, at: min(r.index, r.layer.items.count)) }
    }

    private func eraseWholeAt(_ st: Stroke, _ pt: CGPoint) {
        guard let d = model.doc else { return }
        let L = d.activeLayer
        let r = max(st.brush.size / 2, 4 / Double(zoom))
        var hit = false
        var i = L.items.count - 1
        while i >= 0 {
            if case .stroke(let s) = L.items[i], !s.isErase {
                let g = GeometryCache.shared.get(s)
                if g.bbox.insetBy(dx: -r, dy: -r).contains(pt) {
                    let near = g.path.contains(pt, using: .winding)
                        || g.path.copy(strokingWithWidth: CGFloat(r * 2), lineCap: .round, lineJoin: .round, miterLimit: 1).contains(pt)
                    if near {
                        st.removed.append((L, L.items[i], i))
                        L.items.remove(at: i)
                        hit = true
                    }
                }
            }
            i -= 1
        }
        if hit { requestRender() }
    }

    // MARK: hold to snap

    private func armHold(_ st: Stroke, _ p: CGPoint) {
        guard model.prefs.snap, !st.whole else { return }
        st.holdWork?.cancel()
        st.holdAnchor = p
        let w = DispatchWorkItem { [weak self, weak st] in if let st = st { self?.trySnap(st) } }
        st.holdWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + model.prefs.snapDelay, execute: w)
    }
    private func holdMoved(_ st: Stroke, _ p: CGPoint) {
        guard st.snapped == nil, model.prefs.snap else { return }
        if hypot(p.x - st.holdAnchor.x, p.y - st.holdAnchor.y) > 4 { armHold(st, p) }
    }
    private func trySnap(_ st: Stroke) {
        guard stroke === st, st.snapped == nil else { return }
        var len = 0.0
        for i in stride(from: 1, to: st.raw.count, by: 1) { len += st.raw[i].dist(st.raw[i - 1]) }
        if len * Double(zoom) < 40 { return }
        guard let shape = ShapeFit.fit(st.raw) else { return }
        var ps: [Double] = []
        var i = 2
        let out = st.emitter.out
        while i < out.count { ps.append(out[i]); i += 3 }
        ps.sort()
        st.snapP = ps.isEmpty ? 0.5 : ps[ps.count / 2]
        st.snapped = shape
        st.preview = nil
        switch shape {
        case .line(let a, _):
            snapLine(st, from: a, to: st.pen)
            model.toast("Straight line · keep holding to angle it")
        case .ellipse(let pts, let circle):
            st.snapPts = pts.flatMap { [$0.x, $0.y, st.snapP] }
            st.tip = pts.last ?? st.tip
            model.toast(circle ? "Circle" : "Ellipse")
        }
        updateLive()
    }
    private func snapLine(_ st: Stroke, from a: V2, to b: V2) {
        let n = max(2, Int((a.dist(b) * Double(zoom) / 6).rounded(.up)))
        var pts: [Double] = []
        for i in 0...n { let t = Double(i) / Double(n); pts += [a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, st.snapP] }
        st.snapPts = pts
        st.tip = b
    }

    // MARK: - touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if t.type == .pencil || t.type == .indirectPointer { penBegan(t, event) } else { fingerBegan(t) }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var anyFinger = false
        for t in touches {
            if t.type == .pencil || t.type == .indirectPointer { penMoved(t, event) } else { anyFinger = fingerMoved(t, event) || anyFinger }
        }
        if anyFinger, gesture != nil { gestureMove() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if t.type == .pencil || t.type == .indirectPointer { penEnded(t, cancelled: false) } else { fingerEnded(t, cancelled: false) }
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if t.type == .pencil || t.type == .indirectPointer { penEnded(t, cancelled: true) } else { fingerEnded(t, cancelled: true) }
        }
    }

    private func penBegan(_ t: UITouch, _ event: UIEvent?) {
        guard model.doc != nil else { return }
        model.panel = nil
        if let g = gesture {   // the pencil wins over a resting palm: undo what the palm did to the view
            g.longWork?.cancel()
            if CACurrentMediaTime() - g.t0 < 1 { setView(g.vStart) }
            gesture = nil; fingers.removeAll(); fingerOrder.removeAll()
        }
        if let st = stroke { if st.isFinger { finishStroke(cancel: true) } else { return } }
        let p = t.location(in: self)
        if model.pickOnce { startPick(p); pickTouch = ObjectIdentifier(t); return }
        beginStroke(at: p, raw: pressure(t), time: t.timestamp * 1000, id: ObjectIdentifier(t), isPencil: t.type == .pencil, isFinger: false)
    }
    private func penMoved(_ t: UITouch, _ event: UIEvent?) {
        if pickTouch == ObjectIdentifier(t) { movePick(t.location(in: self)); return }
        guard let st = stroke, st.id == ObjectIdentifier(t) else { return }
        let list = event?.coalescedTouches(for: t) ?? [t]
        for c in list { feed(st, c.location(in: self), raw: pressure(c), time: c.timestamp * 1000) }
        predict(st, event?.predictedTouches(for: t) ?? [])
        holdMoved(st, t.location(in: self))
        updateLive()
    }
    private func penEnded(_ t: UITouch, cancelled: Bool) {
        if pickTouch == ObjectIdentifier(t) { pickTouch = nil; endPick(); return }
        guard let st = stroke, st.id == ObjectIdentifier(t) else { return }
        if !cancelled { feed(st, t.location(in: self), raw: pressure(t), time: t.timestamp * 1000) }
        st.preview = nil
        finishStroke(cancel: cancelled && st.emitter.out.count < 18)
    }

    private func fingerBegan(_ t: UITouch) {
        guard model.doc != nil else { return }
        if let st = stroke, !st.isFinger { return }          // palm while the pencil is down
        model.panel = nil
        let id = ObjectIdentifier(t), p = t.location(in: self)
        fingers[id] = Finger(p: p, start: p)
        fingerOrder.append(id)
        if model.prefs.fingerDraw && fingers.count == 1 && gesture == nil && stroke == nil {
            if model.pickOnce { fingers[id]?.picker = true; startPick(p); return }
            beginStroke(at: p, raw: 0.5, time: t.timestamp * 1000, id: id, isPencil: false, isFinger: true)
            return
        }
        if let st = stroke, st.isFinger {                    // a second finger soon after the first: it was a gesture
            if CACurrentMediaTime() - st.t0 > 0.3 { return }
            finishStroke(cancel: true)
            for k in Array(fingers.keys) { if let f = fingers[k] { fingers[k]?.start = f.p } }
        }
        if pick != nil && gesture == nil { return }
        if let g = gesture { g.maxCount = max(g.maxCount, fingers.count); rebase() } else { gestureStart() }
    }
    private func fingerMoved(_ t: UITouch, _ event: UIEvent?) -> Bool {
        let id = ObjectIdentifier(t)
        guard var f = fingers[id] else { return false }
        f.p = t.location(in: self)
        fingers[id] = f
        if f.picker { movePick(f.p); return false }
        if let st = stroke, st.id == id {
            let list = event?.coalescedTouches(for: t) ?? [t]
            for c in list { feed(st, c.location(in: self), raw: 0.5, time: c.timestamp * 1000) }
            holdMoved(st, f.p)
            updateLive()
            return false
        }
        return true
    }
    private func fingerEnded(_ t: UITouch, cancelled: Bool) {
        let id = ObjectIdentifier(t)
        guard let f = fingers.removeValue(forKey: id) else { return }
        fingerOrder.removeAll { $0 == id }
        if f.picker { endPick(); return }
        if let st = stroke, st.id == id { finishStroke(cancel: cancelled); return }
        if gesture != nil { if fingers.isEmpty { gestureEnd() } else { rebase() } }
    }

    private func orderedFingers() -> [Finger] { fingerOrder.compactMap { fingers[$0] } }

    private func gestureStart() {
        let g = Gesture(count: fingers.count, view: view)
        gesture = g
        rebase()
        if fingers.count == 1, let f = orderedFingers().first {
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, let g = self.gesture, !g.moved, self.fingers.count == 1 else { return }
                g.picking = true
                self.startPick(f.p)
            }
            g.longWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: w)
        }
    }
    private func rebase() {
        guard let g = gesture else { return }
        g.v0 = view
        g.base = orderedFingers().prefix(2).map { $0.p }
    }
    private func gestureMove() {
        guard let g = gesture else { return }
        let fs = orderedFingers()
        for f in fs where hypot(f.p.x - f.start.x, f.p.y - f.start.y) > 10 { g.moved = true }
        if g.picking { if let f = fs.first { movePick(f.p) }; return }
        if g.moved { g.longWork?.cancel() }
        guard fs.count >= 2, g.base.count >= 2 else { return }   // one finger never moves the canvas (palm safety)
        let p0 = g.base[0], q0 = g.base[1], p = fs[0].p, q = fs[1].p
        let m0 = CGPoint(x: (p0.x + q0.x) / 2, y: (p0.y + q0.y) / 2), m = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        let d0 = max(1, hypot(q0.x - p0.x, q0.y - p0.y)), d1 = max(1, hypot(q.x - p.x, q.y - p.y))
        let cur = g.v0.scaleFactor
        let s = min(max(cur * d1 / d0, 0.01), 120) / cur
        var a = model.prefs.rotate ? atan2(q.y - p.y, q.x - p.x) - atan2(q0.y - p0.y, q0.x - p0.x) : 0
        func build(_ a: CGFloat) -> CGAffineTransform {
            g.v0.concatenating(CGAffineTransform(translationX: -m0.x, y: -m0.y))
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(rotationAngle: a))
                .concatenating(CGAffineTransform(translationX: m.x, y: m.y))
        }
        var v = build(a)
        if model.prefs.rotate {
            let t = v.angle
            if abs(t) < 0.05 { a -= t; v = build(a) }   // snap upright
        }
        setView(v, live: true)
    }
    private func gestureEnd() {
        guard let g = gesture else { return }
        gesture = nil
        g.longWork?.cancel()
        if g.picking { endPick(); return }
        let dur = CACurrentMediaTime() - g.t0
        if !g.moved && dur < 0.32 {
            switch g.maxCount {
            case 2: model.undo()
            case 3: model.redo()
            case 4...: model.uiHidden.toggle()
            default: break
            }
            scheduleSettle(0)
        } else if g.maxCount == 2 && dur < 0.3 && view.scaleFactor / g.s0 < 0.72 {
            animateFit()
        } else {
            scheduleSettle(0)
        }
    }

    // MARK: colour picking

    private func startPick(_ p: CGPoint) {
        guard let d = model.doc else { return }
        let c = DocRenderer.sampleColor(d, at: toDoc(p)) ?? model.prefs.color
        pick = (p, model.prefs.color, c)
        refreshOverlay()
    }
    private func movePick(_ p: CGPoint) {
        guard let d = model.doc, let pk = pick else { return }
        pick = (p, pk.prev, DocRenderer.sampleColor(d, at: toDoc(p)) ?? pk.color)
        refreshOverlay()
    }
    private func endPick() {
        guard let pk = pick else { return }
        pick = nil
        model.pickOnce = false
        model.setColor(pk.color, remember: true)
        refreshOverlay()
    }

    // MARK: - overlay

    func refreshOverlay() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let accent = UIColor.tintColor.cgColor
        for l in [ropeLine, tipDot, penRing, reach, cursorRing, cursorRingInner, loupeTop, loupeBottom] { l.path = nil }
        if let pk = pick {
            let r: CGFloat = 46
            loupeTop.path = UIBezierPath(arcCenter: pk.p, radius: r, startAngle: .pi, endAngle: 2 * .pi, clockwise: true).cgPath
            loupeTop.strokeColor = cgColor(hex: pk.color)
            loupeBottom.path = UIBezierPath(arcCenter: pk.p, radius: r, startAngle: 0, endAngle: .pi, clockwise: true).cgPath
            loupeBottom.strokeColor = cgColor(hex: pk.prev)
            return
        }
        if let st = stroke {
            let tp = toScreen(st.tip), pp = toScreen(st.pen)
            if st.erase {
                let rr = max(3, CGFloat(st.brush.size) * zoom / 2)
                cursorRing.path = UIBezierPath(arcCenter: tp, radius: rr, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                cursorRing.strokeColor = UIColor(white: 0.5, alpha: 0.9).cgColor
            }
            if model.prefs.ropeOn && model.prefs.showRope && st.snapped == nil {
                let L = CGFloat(model.prefs.ropeLength)
                let taut = hypot(pp.x - tp.x, pp.y - tp.y) >= L - 0.75
                let line = UIBezierPath(); line.move(to: tp); line.addLine(to: pp)
                ropeLine.path = line.cgPath
                ropeLine.strokeColor = UIColor.tintColor.withAlphaComponent(taut ? 0.95 : 0.55).cgColor
                ropeLine.lineDashPattern = taut ? nil : [3, 4]
                tipDot.path = UIBezierPath(arcCenter: tp, radius: 2.5, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                tipDot.fillColor = accent
                penRing.path = UIBezierPath(arcCenter: pp, radius: 5, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                penRing.strokeColor = accent
                reach.path = UIBezierPath(arcCenter: pp, radius: L, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                reach.strokeColor = UIColor.tintColor.withAlphaComponent(0.16).cgColor
            }
            return
        }
        if let c = cursor, gesture == nil {
            let rr = CGFloat(model.currentBrush.size) * zoom / 2
            if rr > 2.5 {
                cursorRing.path = UIBezierPath(arcCenter: c, radius: rr + 0.5, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                cursorRing.strokeColor = UIColor(white: 1, alpha: 0.9).cgColor
                cursorRingInner.path = UIBezierPath(arcCenter: c, radius: max(0.5, rr - 0.5), startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                cursorRingInner.strokeColor = UIColor(white: 0, alpha: 0.65).cgColor
            } else {
                cursorRing.path = UIBezierPath(arcCenter: c, radius: 3, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                cursorRing.strokeColor = UIColor(white: 1, alpha: 0.85).cgColor
                cursorRingInner.path = UIBezierPath(arcCenter: c, radius: 1.4, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                cursorRingInner.strokeColor = UIColor(white: 0, alpha: 0.6).cgColor
            }
        }
    }

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: if stroke == nil { cursor = g.location(in: self); refreshOverlay() }
        default: cursor = nil; refreshOverlay()
        }
    }

    // trackpad / mouse
    private var scrollStart: CGAffineTransform?
    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: scrollStart = view
        case .changed: if let v0 = scrollStart { let t = g.translation(in: self); setView(v0.concatenating(CGAffineTransform(translationX: t.x, y: t.y)), live: true) }
        default: scrollStart = nil; scheduleSettle(0)
        }
    }
    private var pinchStart: CGAffineTransform?
    @objc private func onTrackpadPinch(_ g: UIPinchGestureRecognizer) {
        let c = g.location(in: self)
        switch g.state {
        case .began: pinchStart = view
        case .changed:
            if let v0 = pinchStart {
                let s = min(max(v0.scaleFactor * g.scale, 0.01), 120) / v0.scaleFactor
                setView(v0.concatenating(CGAffineTransform(translationX: -c.x, y: -c.y)).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: c.x, y: c.y)), live: true)
            }
        default: pinchStart = nil; scheduleSettle(0)
        }
    }

    // MARK: - Apple Pencil double-tap and squeeze

    private func pencilAction(_ f: () -> Void) {
        let now = CACurrentMediaTime()
        if now - lastPencilAction < 0.08 { return }
        lastPencilAction = now
        f()
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { pencilAction { model.pencilTap() } }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) { pencilAction { model.pencilTap() } }
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        if squeeze.phase == .ended { pencilAction { model.pencilSqueeze() } }
    }

    // MARK: - keyboard

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Undo", action: #selector(kUndo), input: "z", modifierFlags: .command),
         UIKeyCommand(title: "Redo", action: #selector(kRedo), input: "z", modifierFlags: [.command, .shift]),
         UIKeyCommand(title: "Brush", action: #selector(kBrush), input: "b"),
         UIKeyCommand(title: "Eraser", action: #selector(kEraser), input: "e"),
         UIKeyCommand(title: "Smaller", action: #selector(kSmaller), input: "["),
         UIKeyCommand(title: "Bigger", action: #selector(kBigger), input: "]"),
         UIKeyCommand(title: "Fit", action: #selector(kFit), input: "0")]
    }
    @objc private func kUndo() { model.undo() }
    @objc private func kRedo() { model.redo() }
    @objc private func kBrush() { model.setTool(.brush) }
    @objc private func kEraser() { model.setTool(.eraser) }
    @objc private func kSmaller() { model.currentSize = vToSize(sizeToV(model.currentSize) - 0.03); model.toast(fmtSize(model.currentSize)) }
    @objc private func kBigger() { model.currentSize = vToSize(sizeToV(model.currentSize) + 0.03); model.toast(fmtSize(model.currentSize)) }
    @objc private func kFit() { animateFit() }

    // MARK: - fit animation

    func animateFit() {
        let target = fitTransform()
        let f = view
        anim = (from: (s: f.scaleFactor, a: f.angle, tx: f.tx, ty: f.ty), to: target, start: CACurrentMediaTime(), flip: f.isFlipped)
        if UIAccessibility.isReduceMotionEnabled || f.isFlipped != target.isFlipped { anim = nil; setView(target); return }
        displayLink?.invalidate()
        let dl = CADisplayLink(target: self, selector: #selector(stepAnim))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }
    @objc private func stepAnim() {
        guard let a = anim else { displayLink?.invalidate(); displayLink = nil; return }
        let k: Double = min(1, (CACurrentMediaTime() - a.start) / 0.22)
        let e: CGFloat = CGFloat(1 - pow(1 - k, 3))
        let to = a.to
        var dt: CGFloat = to.angle - a.from.a
        while dt > .pi { dt -= 2 * .pi }
        while dt < -.pi { dt += 2 * .pi }
        let ls0: Double = Foundation.log(Double(a.from.s))
        let ls1: Double = Foundation.log(Double(to.scaleFactor))
        let s: CGFloat = CGFloat(Foundation.exp(ls0 + (ls1 - ls0) * Double(e)))
        let ang: CGFloat = a.from.a + dt * e
        let ca: CGFloat = cos(ang) * s, sa: CGFloat = sin(ang) * s
        let tx: CGFloat = a.from.tx + (to.tx - a.from.tx) * e
        let ty: CGFloat = a.from.ty + (to.ty - a.from.ty) * e
        var v = CGAffineTransform(a: ca, b: sa, c: -sa, d: ca, tx: tx, ty: ty)
        if a.flip { v = CGAffineTransform(a: -v.a, b: -v.b, c: v.c, d: v.d, tx: v.tx, ty: v.ty) }
        if k >= 1 { anim = nil; displayLink?.invalidate(); displayLink = nil; setView(to) } else { setView(v, live: true) }
    }

    // MARK: - automated screenshot demo

    func demoStrokes() {
        let base = CGPoint(x: bounds.midX - 260, y: bounds.midY - 120)
        for row in 0..<3 {
            var t = CACurrentMediaTime() * 1000
            let y0 = base.y + CGFloat(row) * 110
            beginStroke(at: CGPoint(x: base.x, y: y0), raw: 0.2, time: t, id: nil, isPencil: true, isFinger: false)
            guard let st = stroke else { return }
            for i in 1...120 {
                t += 8
                let x = base.x + CGFloat(i) * 4.4
                let wobble: CGFloat = sin(CGFloat(i) / 14) * 40
                let y: CGFloat = y0 + wobble + CGFloat.random(in: -3...3)
                let pr: Double = 0.15 + 0.8 * sin(Double.pi * Double(i) / 120)
                feed(st, CGPoint(x: x, y: y), raw: pr, time: t)
            }
            finishStroke(cancel: false)
        }
    }
}

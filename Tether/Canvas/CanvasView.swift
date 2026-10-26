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
    // Eraser preview: shows what lies under the current layer (paper + layers below) through the eraser's shape.
    // Each eraser outline is its own mask shape, so going back over a spot can never "un-erase" it.
    private let revealLayer = CALayer()
    private let revealPaper = CALayer()
    private let revealBelow = CALayer()
    private let revealMask = CALayer()
    private let overlay = CALayer()
    private let cursorRing = CAShapeLayer()
    private let cursorRingInner = CAShapeLayer()
    private let loupeTop = CAShapeLayer()
    private let loupeBottom = CAShapeLayer()
    private let editGuide = CAShapeLayer()
    private let editHandles = CAShapeLayer()

    // rendering
    private let renderQueue = DispatchQueue(label: "ink.tether.render", qos: .userInitiated)
    private let latest = LatestGen()
    private var renderGen = 0
    private var pending: [(layer: CAShapeLayer, gen: Int)] = []
    private var pendingErase: [(path: CGPath, opacity: Double, gen: Int)] = []
    private var settleWork: DispatchWorkItem?
    private var displayLink: CADisplayLink?
    private var glideLink: CADisplayLink?
    // appending a stroke draws it onto the last bitmap instead of redrawing the whole layer
    private var baseActive: CGImage?
    private var baseKey: (view: CGAffineTransform, w: Int, h: Int, layer: String)?
    private var appended: [(item: Item, gen: Int)] = []
    private var hiddenItem: String?
    private var pendingFull = false

    // a snapped shape that can still be adjusted (until the next stroke)
    private final class ShapeEdit {
        let layer: Layer
        var item: StrokeItem
        var shape: SnappedShape
        let start: SnappedShape
        let original: StrokeItem
        var active = false
        var drag: Drag?
        enum Kind { case move, lineEnd(Int), axis(Int) }
        struct Drag { let kind: Kind; let touch: ObjectIdentifier; let isFinger: Bool; let startDoc: V2; let grab: V2; let startShape: SnappedShape; var screen: CGPoint }
        init(layer: Layer, item: StrokeItem, shape: SnappedShape) { self.layer = layer; self.item = item; self.shape = shape; start = shape; original = item }
    }
    private var shapeEdit: ShapeEdit?
    private let editButton = UIButton(type: .system)
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
        var snapBase: SnappedShape? = nil          // the fitted shape, before any adjusting while holding
        var snapPen = V2(0, 0)                     // where the pencil was when it snapped
        var holdFingers: Set<ObjectIdentifier> = []  // fingers put down while holding a snapped shape: constrain it
        var lastIn: (p: CGPoint, pr: Double, t: Double)? = nil
        var lastFeedWall: CFTimeInterval = 0
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
        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .capsule
        cfg.baseBackgroundColor = .tintColor
        cfg.baseForegroundColor = .white
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        editButton.configuration = cfg
        editButton.isHidden = true
        editButton.addTarget(self, action: #selector(editButtonTapped), for: .touchUpInside)
        addSubview(editButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    private func setupLayers() {
        for l in [pageLayer, contentLayer, belowLayer, activeLayer, aboveLayer, liveContainer, overlay, revealLayer, revealPaper, revealBelow, revealMask] {
            l.anchorPoint = .zero
            l.position = .zero
        }
        pageLayer.borderColor = UIColor(white: 0, alpha: 0.18).cgColor
        layer.addSublayer(pageLayer)
        layer.addSublayer(contentLayer)
        contentLayer.addSublayer(belowLayer)
        contentLayer.addSublayer(activeLayer)
        contentLayer.addSublayer(revealLayer)
        contentLayer.addSublayer(aboveLayer)
        revealLayer.addSublayer(revealPaper)
        revealLayer.addSublayer(revealBelow)
        revealLayer.mask = revealMask
        revealLayer.isHidden = true
        revealBelow.contentsGravity = .resize
        activeLayer.addSublayer(liveContainer)
        liveContainer.addSublayer(liveLayer)
        liveContainer.mask = liveClip
        liveLayer.fillRule = .nonZero
        for l in [belowLayer, activeLayer, aboveLayer] { l.contentsGravity = .resize; l.magnificationFilter = .linear }
        layer.addSublayer(overlay)
        for l in [cursorRing, cursorRingInner, loupeTop, loupeBottom, editGuide, editHandles] {
            l.fillColor = UIColor.clear.cgColor
            overlay.addSublayer(l)
        }
        editGuide.lineWidth = 1
        editGuide.lineDashPattern = [4, 4]
        editHandles.lineWidth = 1.5
        cursorRing.lineWidth = 1
        cursorRingInner.lineWidth = 1
        loupeTop.lineWidth = 16
        loupeBottom.lineWidth = 16
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let s = window?.screen.scale ?? UIScreen.main.scale
        for l in [pageLayer, contentLayer, belowLayer, activeLayer, aboveLayer, liveContainer, liveLayer, overlay, revealLayer, revealPaper, revealBelow, revealMask, liveClip,
                  cursorRing, cursorRingInner, loupeTop, loupeBottom, editGuide, editHandles] { l.contentsScale = s }
        becomeFirstResponder()
    }

    private var screenScale: CGFloat { window?.screen.scale ?? UIScreen.main.scale }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeEditButton()
        guard bounds.size != lastSize, bounds.width > 1, bounds.height > 1 else { return }
        let first = lastSize == .zero
        let dw = bounds.width - lastSize.width, dh = bounds.height - lastSize.height
        lastSize = bounds.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [contentLayer, belowLayer, activeLayer, aboveLayer, liveContainer, overlay, revealLayer, revealBelow, revealMask] { l.bounds = CGRect(origin: .zero, size: bounds.size) }
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
        pageLayer.borderWidth = 1 / s
        contentLayer.setAffineTransform(renderedView.inverted().concatenating(view))
        CATransaction.commit()
    }

    private func updatePage() {
        guard let d = model.doc else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pageLayer.bounds = CGRect(x: 0, y: 0, width: d.w, height: d.h)
        if d.bgOn { pageLayer.backgroundColor = cgColor(hex: d.bg) }
        else { pageLayer.backgroundColor = CanvasView.checker.cgColor }
        revealPaper.backgroundColor = pageLayer.backgroundColor
        revealPaper.bounds = pageLayer.bounds
        activeLayer.opacity = Float(d.activeLayer?.opacity ?? 1)
        activeLayer.isHidden = !(d.activeLayer?.visible ?? false)
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
        stopGlide()
        dropShapeEdit()
        baseActive = nil; baseKey = nil; appended = []
        pending.forEach { $0.layer.removeFromSuperlayer() }
        pending = []; pendingErase = []
        CATransaction.begin(); CATransaction.setDisableActions(true)
        belowLayer.contents = nil; activeLayer.contents = nil; aboveLayer.contents = nil
        liveLayer.path = nil; revealLayer.isHidden = true; revealMask.sublayers?.forEach { $0.removeFromSuperlayer() }
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
        endShapeEdit()
        if !activeOnly { fullDirty = true }
        updatePage()
        requestRender()
    }

    @discardableResult func requestRender() -> Int {
        guard let d = model.doc, bounds.width > 1, bounds.height > 1 else { return renderGen }
        renderGen += 1
        let gen = renderGen
        let scale = screenScale
        let hide = hiddenItem
        let job = DocRenderer.ScreenJob(layers: d.layers.map { LayerSnap($0, hiding: hide) }, active: d.activeIndex, docW: d.w, docH: d.h, view: view,
                                        pxW: Int((bounds.width * scale).rounded()), pxH: Int((bounds.height * scale).rounded()), scale: scale,
                                        activeOnly: !fullDirty, layerId: d.activeLayer?.id ?? "")
        latest.set(gen)
        pendingFull = true
        let latest = self.latest
        renderQueue.async {
            if latest.get() != gen { return }
            let r = DocRenderer.renderScreen(job)
            DispatchQueue.main.async { [weak self] in self?.apply(r, gen: gen, full: true) }
        }
        return gen
    }

    /// A stroke was added to the current layer: draw just it (and any others still on their way) onto the last bitmap.
    @discardableResult private func requestAppend(_ item: Item) -> Int {
        let scale = screenScale
        let pw = Int((bounds.width * scale).rounded()), ph = Int((bounds.height * scale).rounded())
        guard let d = model.doc, !fullDirty, !pendingFull, hiddenItem == nil, let base = baseActive, let key = baseKey,
              key.layer == (d.activeLayer?.id ?? ""), key.w == pw, key.h == ph, key.view == view else { return requestRender() }
        renderGen += 1
        let gen = renderGen
        appended.append((item, gen))
        let job = DocRenderer.AppendJob(base: base, items: appended.map { $0.item }, docW: d.w, docH: d.h, view: key.view,
                                        pxW: pw, pxH: ph, scale: scale, layerId: key.layer)
        latest.set(gen)
        let latest = self.latest
        renderQueue.async {
            if latest.get() != gen { return }
            let r = DocRenderer.renderAppend(job)
            DispatchQueue.main.async { [weak self] in self?.apply(r, gen: gen, full: false) }
        }
        return gen
    }

    private func apply(_ r: DocRenderer.ScreenResult, gen: Int, full: Bool) {
        guard gen == renderGen else { return }
        if full { pendingFull = false }
        if let a = r.active {
            baseActive = a
            baseKey = (r.view, a.width, a.height, r.layerId)
        }
        appended.removeAll { $0.gen <= gen }
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
        revealBelow.contents = belowLayer.contents
        revealPaper.setAffineTransform(renderedView)
        if shapeEdit?.active == true { showEditedShape() }
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
        var shapes: [(CGPath, Double)] = pendingErase.map { ($0.path, $0.opacity) }
        if let p = liveErasePath { shapes.append((p, stroke?.opacity ?? 1)) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var layers = (revealMask.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        if shapes.isEmpty {
            revealLayer.isHidden = true
            layers.forEach { $0.removeFromSuperlayer() }
            return
        }
        while layers.count < shapes.count {
            let l = CAShapeLayer()
            l.contentsScale = screenScale
            l.fillRule = .nonZero
            revealMask.addSublayer(l)
            layers.append(l)
        }
        while layers.count > shapes.count { layers.removeLast().removeFromSuperlayer() }
        for (i, sh) in shapes.enumerated() {
            layers[i].path = sh.0
            layers[i].fillColor = UIColor(white: 0, alpha: CGFloat(sh.1)).cgColor
        }
        revealLayer.isHidden = false
    }

    // MARK: - strokes

    private func pressure(_ t: UITouch) -> Double {
        guard t.type == .pencil, t.maximumPossibleForce > 0 else { return 0.5 }
        return clampD(Double(t.force / t.maximumPossibleForce), 0.001, 1)
    }

    private func beginStroke(at p: CGPoint, raw: Double, time: Double, id: ObjectIdentifier?, isPencil: Bool, isFinger: Bool) {
        guard let d = model.doc else { return }
        guard let L = d.activeLayer else { model.toast("No layers. Tap + in Layers to add one."); return }
        if L.locked { model.toast("This layer is locked. Unlock it in Layers to draw on it."); return }
        if !L.visible { model.toast("This layer is hidden. Turn it on in Layers to draw on it."); return }
        let b = model.currentBrush
        let erase = model.tool == .eraser
        let dp = toDoc(p)
        let z = Double(zoom)
        let st = Stroke(id: id, brush: b, erase: erase, smoother: Smoother(model.smoothing(for: b)),
                        emitter: CurveEmitter(minDist: 0.3 / z, spacing: 2 / z), at: V2(Double(dp.x), Double(dp.y)), screen: p,
                        color: model.prefs.color, opacity: erase ? model.prefs.opacityEraser : model.prefs.opacityBrush,
                        isPencil: isPencil, isFinger: isFinger)
        endShapeEdit()
        stroke = st
        cursor = nil
        feed(st, p, raw: raw, time: time)
        armHold(st, p)
        if st.smoother.o.lags && !st.whole { startGlide() }
        updateLive()
    }

    // While the pencil rests, keep feeding its position so lagging smoothing glides onto it instead of freezing.
    private func startGlide() {
        glideLink?.invalidate()
        let dl = CADisplayLink(target: self, selector: #selector(glide))
        dl.add(to: .main, forMode: .common)
        glideLink = dl
    }
    private func stopGlide() { glideLink?.invalidate(); glideLink = nil }
    @objc private func glide() {
        guard let st = stroke, let li = st.lastIn else { stopGlide(); return }
        if st.snapped != nil { return }
        let idle = CACurrentMediaTime() - st.lastFeedWall
        if idle < 0.035 { return }
        let out = st.smoother.push(Sample(x: Double(li.p.x), y: Double(li.p.y), p: li.pr, t: li.t + idle * 1000))
        if out.isEmpty { return }
        emit(st, out)
        st.preview = nil
        updateLive()
    }

    private func feed(_ st: Stroke, _ p: CGPoint, raw: Double, time: Double) {
        let dp = toDoc(p)
        st.pen = V2(Double(dp.x), Double(dp.y))
        if st.snapped != nil { adjustSnap(st); return }
        st.raw.append(st.pen)
        let pr = st.isPencil ? model.pressure(raw) : raw
        st.lastIn = (p, pr, time)
        st.lastFeedWall = CACurrentMediaTime()
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
        stopGlide()
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
        var freehand: [Double] = []
        if st.snapped != nil { pts = st.snapPts; freehand = st.emitter.finish() }
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
        guard let L = d.activeLayer, !L.locked else { updateLive(); return }
        let item = Item.stroke(StrokeItem(id: newID(), m: st.erase ? "e" : "d", c: st.color, o: r3(st.opacity), b: shape, p: roundPts(pts)))
        if let snapped = st.snapped, case .stroke(let si) = item {
            // two steps, so an accidental snap undoes back to the line you drew
            var fs = st.brush.shape
            fs.sim = !st.isPencil
            if freehand.count >= 6 {
                let free = Item.stroke(StrokeItem(id: newID(), m: st.erase ? "e" : "d", c: st.color, o: r3(st.opacity), b: fs, p: roundPts(freehand)))
                L.items.append(free)
                model.push(HistoryEntry("Stroke", undo: { if let i = L.items.lastIndex(where: { $0.id == free.id }) { L.items.remove(at: i) } }, redo: { L.items.append(free) }))
                if let i = L.items.lastIndex(where: { $0.id == free.id }) { L.items[i] = item }
                model.push(HistoryEntry("Snap to shape", undo: { if let i = L.items.lastIndex(where: { $0.id == item.id }) { L.items[i] = free } },
                                        redo: { if let i = L.items.lastIndex(where: { $0.id == free.id }) { L.items[i] = item } }))
            } else {
                L.items.append(item)
                model.push(HistoryEntry("Shape", undo: { if let i = L.items.lastIndex(where: { $0.id == item.id }) { L.items.remove(at: i) } }, redo: { L.items.append(item) }))
            }
            if !st.erase { offerShapeEdit(ShapeEdit(layer: L, item: si, shape: snapped)) }
        } else {
            L.items.append(item)
            let label = st.erase ? "Erase" : "Stroke"
            model.push(HistoryEntry(label, undo: { if let i = L.items.lastIndex(where: { $0.id == item.id }) { L.items.remove(at: i) } }, redo: { L.items.append(item) }))
        }
        // keep showing the stroke as a vector shape until the bitmap that includes it arrives
        let gen = requestAppend(item)
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
        guard let L = model.doc?.activeLayer, !L.locked else { return }
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
        // fit the line as drawn (after smoothing), so the shape lands where the line is
        let live = st.emitter.live()
        var drawn: [V2] = []
        drawn.reserveCapacity(live.count / 3)
        var i = 0
        while i + 1 < live.count { drawn.append(V2(live[i], live[i + 1])); i += 3 }
        var len = 0.0
        for k in stride(from: 1, to: drawn.count, by: 1) { len += drawn[k].dist(drawn[k - 1]) }
        if len * Double(zoom) < 40 { return }
        guard let shape = ShapeFit.fit(drawn) else { return }
        var ps: [Double] = []
        i = 2
        while i < live.count { ps.append(live[i]); i += 3 }
        ps.sort()
        st.snapP = ps.isEmpty ? 0.5 : ps[ps.count / 2]
        st.snapBase = shape
        st.snapPen = st.pen
        st.snapped = shape
        st.preview = nil
        adjustSnap(st)
        switch shape {
        case .line: model.toast("Line · keep holding to adjust it, add a finger for 15° steps")
        case .ellipse(let e): model.toast((e.circle ? "Circle" : "Ellipse") + " · keep holding to resize or turn it, add a finger for a circle")
        }
        updateLive()
    }

    /// While the pencil is still down after a snap: moving it adjusts the shape relative to where it snapped (no jump),
    /// a finger on the screen constrains it.
    private func adjustSnap(_ st: Stroke) {
        guard let base = st.snapBase else { return }
        let constrain = !st.holdFingers.isEmpty
        let d = st.pen - st.snapPen
        var shape: SnappedShape
        switch base {
        case .line(let a, let b):
            var e = b + d
            if constrain {
                let v = e - a, step = Double.pi / 12
                let ang = (atan2(v.y, v.x) / step).rounded() * step
                e = a + V2(cos(ang), sin(ang)) * v.length
            }
            shape = .line(a, e)
        case .ellipse(var el):
            let v0 = st.snapPen - el.c, v1 = st.pen - el.c
            if v0.length > 6 / Double(zoom) && v1.length > 1e-6 {
                let k = v1.length / v0.length
                el.r1 *= k; el.r2 *= k
                el.angle += atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
            }
            if constrain && !el.circle { let r = (el.r1 + el.r2) / 2; el.r1 = r; el.r2 = r }
            shape = .ellipse(el)
        }
        st.snapped = shape
        st.snapPts = shape.points(pressure: st.snapP, zoom: Double(zoom))
        if st.snapPts.count >= 3 { st.tip = V2(st.snapPts[st.snapPts.count - 3], st.snapPts[st.snapPts.count - 2]) }
    }

    private func roundPts(_ pts: [Double]) -> [Double] {
        var r = pts
        for i in 0..<r.count { r[i] = i % 3 == 2 ? r3(r[i]) : r2(r[i]) }
        return r
    }

    // MARK: - edit shape (after lifting)

    private func offerShapeEdit(_ se: ShapeEdit) {
        shapeEdit = se
        editButton.configuration?.title = "Edit shape"
        editButton.isHidden = false
        placeEditButton()
    }
    private func placeEditButton() {
        guard !editButton.isHidden else { return }
        let sz = editButton.sizeThatFits(CGSize(width: 240, height: 44))
        editButton.frame = CGRect(x: (bounds.width - sz.width) / 2, y: safeAreaInsets.top + 70, width: sz.width, height: sz.height)
    }
    @objc private func editButtonTapped() {
        guard let se = shapeEdit else { return }
        if se.active { endShapeEdit(); return }
        guard model.doc?.activeLayer === se.layer, se.layer.items.contains(where: { $0.id == se.item.id }) else { dropShapeEdit(); return }
        se.active = true
        editButton.configuration?.title = "Done"
        placeEditButton()
        hiddenItem = se.item.id
        requestRender()
        showEditedShape()
        model.toast("Drag the handles, or drag the shape to move it")
    }
    /// Before undo, redo, any other change and the next stroke: keep what was edited as one undo step and leave edit mode.
    func endShapeEdit() {
        guard let se = shapeEdit else { return }
        shapeEdit = nil
        editButton.isHidden = true
        guard se.active else { refreshOverlay(); return }
        se.drag = nil
        var committed: StrokeItem? = nil
        let L = se.layer
        if se.shape != se.start, let idx = L.items.firstIndex(where: { $0.id == se.item.id }) {
            let old = Item.stroke(se.original)
            var ni = se.item
            ni.id = newID()
            ni.p = roundPts(se.shape.points(pressure: pressureOf(se.item), zoom: Double(zoom)))
            let new = Item.stroke(ni)
            L.items[idx] = new
            committed = ni
            let origId = se.original.id
            model.push(HistoryEntry("Edit shape", undo: { if let i = L.items.firstIndex(where: { $0.id == ni.id }) { L.items[i] = old } },
                                    redo: { if let i = L.items.firstIndex(where: { $0.id == origId }) { L.items[i] = new } }))
            model.markDirty(); model.docVersion += 1
        }
        hiddenItem = nil
        let gen = requestRender()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let path = liveLayer.path {
            let it = committed ?? se.item
            let keep = CAShapeLayer()
            keep.contentsScale = screenScale
            keep.frame = liveLayer.frame
            keep.path = path
            keep.fillColor = cgColor(hex: it.c, alpha: CGFloat(it.o))
            liveContainer.insertSublayer(keep, below: liveLayer)
            pending.append((keep, gen))
        }
        liveLayer.path = nil
        CATransaction.commit()
        refreshOverlay()
    }
    private func pressureOf(_ s: StrokeItem) -> Double { s.p.count >= 3 ? s.p[2] : 0.5 }
    private func dropShapeEdit() {
        if shapeEdit?.active == true { CATransaction.begin(); CATransaction.setDisableActions(true); liveLayer.path = nil; CATransaction.commit() }
        shapeEdit = nil
        hiddenItem = nil
        editButton.isHidden = true
        refreshOverlay()
    }
    private func showEditedShape() {
        guard let se = shapeEdit else { return }
        let pts = se.shape.points(pressure: pressureOf(se.item), zoom: Double(zoom))
        let o = StrokeGeometry.outline(pts, se.item.b, last: true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        liveLayer.path = StrokeGeometry.path(o, transform: renderedView)
        liveLayer.fillColor = cgColor(hex: se.item.c, alpha: CGFloat(se.item.o))
        CATransaction.commit()
        refreshOverlay()
    }
    private func handlePoints(_ s: SnappedShape) -> [V2] {
        switch s {
        case .line(let a, let b): return [a, b]
        case .ellipse(let e): return e.handles
        }
    }
    private func editBegan(_ t: UITouch) -> Bool {
        guard let se = shapeEdit, se.active, se.drag == nil else { return false }
        let isFinger = !(t.type == .pencil || t.type == .indirectPointer)
        if isFinger && (!fingers.isEmpty || gesture != nil) { return false }
        let sp = t.location(in: self)
        let dp = toDoc(sp), d = V2(Double(dp.x), Double(dp.y))
        let hitR = 26.0 / Double(zoom)
        var kind: ShapeEdit.Kind? = nil
        var grab = V2(0, 0)
        for (i, h) in handlePoints(se.shape).enumerated() where h.dist(d) < hitR {
            if case .line = se.shape { kind = .lineEnd(i) } else { kind = .axis(i) }
            grab = h - d
            break
        }
        if kind == nil {
            switch se.shape {
            case .line(let a, let b):
                let ab = b - a, l2 = max(ab.length2, 1e-9)
                let u = clampD((d - a).dot(ab) / l2, 0, 1)
                if (a + ab * u).dist(d) < hitR { kind = .move }
            case .ellipse(let e):
                let ca = cos(e.angle), sa = sin(e.angle), dx = d.x - e.c.x, dy = d.y - e.c.y
                let lx = dx * ca + dy * sa, ly = -dx * sa + dy * ca
                let rx = e.r1 + hitR, ry = e.r2 + hitR
                if (lx * lx) / (rx * rx) + (ly * ly) / (ry * ry) <= 1 { kind = .move }
            }
        }
        guard let k = kind else {
            if isFinger { return false }
            endShapeEdit()          // pencil outside the shape: done
            return true
        }
        se.drag = ShapeEdit.Drag(kind: k, touch: ObjectIdentifier(t), isFinger: isFinger, startDoc: d, grab: grab, startShape: se.shape, screen: sp)
        return true
    }
    private func editMoved(_ t: UITouch) -> Bool {
        guard let se = shapeEdit, var dr = se.drag, dr.touch == ObjectIdentifier(t) else { return false }
        let sp = t.location(in: self)
        dr.screen = sp
        se.drag = dr
        let dp = toDoc(sp), d = V2(Double(dp.x), Double(dp.y))
        let target = d + dr.grab
        switch (dr.kind, dr.startShape) {
        case (.move, .line(let a, let b)):
            let m = d - dr.startDoc
            se.shape = .line(a + m, b + m)
        case (.move, .ellipse(var e)):
            e.c = e.c + (d - dr.startDoc)
            se.shape = .ellipse(e)
        case (.lineEnd(let i), .line(let a, let b)):
            se.shape = i == 0 ? .line(target, b) : .line(a, target)
        case (.axis(let i), .ellipse(var e)):
            let w = target - e.c
            let r = max(w.length, 1 / Double(zoom))
            let ang = atan2(w.y, w.x)
            if i % 2 == 0 { e.r1 = r; e.angle = ang + (i == 2 ? .pi : 0) } else { e.r2 = r; e.angle = ang + (i == 1 ? -.pi / 2 : .pi / 2) }
            if e.circle { e.r1 = r; e.r2 = r }
            se.shape = .ellipse(e)
        default: break
        }
        showEditedShape()
        return true
    }
    private func editEnded(_ t: UITouch, cancelled: Bool) -> Bool {
        guard let se = shapeEdit, let dr = se.drag, dr.touch == ObjectIdentifier(t) else { return false }
        if cancelled { se.shape = dr.startShape; showEditedShape() }
        se.drag = nil
        refreshOverlay()
        return true
    }
    /// A second finger during a one-finger shape drag: it's a pinch, so put the shape back and hand both fingers to the gesture.
    private func editYieldToGesture() {
        guard let se = shapeEdit, let dr = se.drag, dr.isFinger else { return }
        se.shape = dr.startShape
        se.drag = nil
        showEditedShape()
        fingers[dr.touch] = Finger(p: dr.screen, start: dr.screen)
        fingerOrder.append(dr.touch)
    }

    // MARK: - touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if editBegan(t) { continue }
            if t.type == .pencil || t.type == .indirectPointer { penBegan(t, event) } else { fingerBegan(t) }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var anyFinger = false
        for t in touches {
            if editMoved(t) { continue }
            if t.type == .pencil || t.type == .indirectPointer { penMoved(t, event) } else { anyFinger = fingerMoved(t, event) || anyFinger }
        }
        if anyFinger, gesture != nil { gestureMove() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if editEnded(t, cancelled: false) { continue }
            if t.type == .pencil || t.type == .indirectPointer { penEnded(t, cancelled: false) } else { fingerEnded(t, cancelled: false) }
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if editEnded(t, cancelled: true) { continue }
            if t.type == .pencil || t.type == .indirectPointer { penEnded(t, cancelled: true) } else { fingerEnded(t, cancelled: true) }
        }
    }

    private func penBegan(_ t: UITouch, _ event: UIEvent?) {
        guard model.doc != nil else { return }
        if model.panel != nil { model.panel = nil }
        if let g = gesture {   // the pencil wins over a resting palm: undo what the palm did to the view
            g.longWork?.cancel()
            if CACurrentMediaTime() - g.t0 < 0.4 { setView(g.vStart) }   // only a palm-length blip, never a real pinch
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
        if st.smoother.o.light { predict(st, event?.predictedTouches(for: t) ?? []) } else { st.preview = nil }
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
        if let st = stroke, !st.isFinger {                    // palm while the pencil is down…
            if st.snapped != nil { st.holdFingers.insert(ObjectIdentifier(t)); adjustSnap(st); updateLive() }   // …or a finger to constrain a shape
            return
        }
        if model.panel != nil { model.panel = nil }
        editYieldToGesture()
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
        if let st = stroke, st.holdFingers.remove(id) != nil { adjustSnap(st); updateLive(); return }
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
            let q = (t / (.pi / 2)).rounded() * (.pi / 2)
            if abs(t - q) < .pi / 90 { a -= t - q; v = build(a) }   // sticks to the nearest right angle within 2°
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
        }
        scheduleSettle(0)
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
        for l in [cursorRing, cursorRingInner, loupeTop, loupeBottom, editGuide, editHandles] { l.path = nil }
        if let se = shapeEdit, se.active {
            let hs = handlePoints(se.shape).map { toScreen($0) }
            let hp = UIBezierPath()
            for h in hs { hp.append(UIBezierPath(arcCenter: h, radius: 7, startAngle: 0, endAngle: 2 * .pi, clockwise: true)) }
            editHandles.path = hp.cgPath
            editHandles.fillColor = UIColor.white.cgColor
            editHandles.strokeColor = accent
            if case .ellipse(let e) = se.shape {
                let c = toScreen(e.c), gp = UIBezierPath()
                for h in hs { gp.move(to: c); gp.addLine(to: h) }
                editGuide.path = gp.cgPath
                editGuide.strokeColor = UIColor.tintColor.withAlphaComponent(0.6).cgColor
            }
        }
        if let pk = pick {
            let r: CGFloat = 46
            loupeTop.path = UIBezierPath(arcCenter: pk.p, radius: r, startAngle: .pi, endAngle: 2 * .pi, clockwise: true).cgPath
            loupeTop.strokeColor = cgColor(hex: pk.color)
            loupeBottom.path = UIBezierPath(arcCenter: pk.p, radius: r, startAngle: 0, endAngle: .pi, clockwise: true).cgPath
            loupeBottom.strokeColor = cgColor(hex: pk.prev)
            return
        }
        if let st = stroke {
            let tp = toScreen(st.tip)
            if st.erase {
                let rr = max(3, CGFloat(st.brush.size) * zoom / 2)
                cursorRing.path = UIBezierPath(arcCenter: tp, radius: rr, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
                cursorRing.strokeColor = UIColor(white: 0.5, alpha: 0.9).cgColor
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

    /// A wobbly loop, snapped to an ellipse, then opened for editing.
    func demoShape() {
        let c = CGPoint(x: bounds.midX, y: bounds.midY + 40)
        var t = CACurrentMediaTime() * 1000
        beginStroke(at: CGPoint(x: c.x + 220, y: c.y), raw: 0.5, time: t, id: nil, isPencil: true, isFinger: false)
        guard let st = stroke else { return }
        for i in 1...160 {
            t += 8
            let a: Double = Double(i) / 150 * 2 * Double.pi
            let r: Double = 1 + 0.04 * sin(a * 5)
            let x: CGFloat = c.x + CGFloat(cos(a) * 220 * r)
            let y: CGFloat = c.y + CGFloat(sin(a) * 130 * r)
            feed(st, CGPoint(x: x, y: y), raw: 0.5, time: t)
        }
        trySnap(st)
        finishStroke(cancel: false)
        editButtonTapped()
    }

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

import SwiftUI

/// A small drawing surface for trying a brush. Strokes go through the same smoothing as the canvas.
final class PadCanvas: UIView {
    var brush: Brush = Brush.builtIn[0] { didSet { setNeedsDisplay() } }
    weak var model: AppModel?
    var onPressure: ((Double?, Double?) -> Void)?

    private var items: [[Double]] = []       // x, y, pressure: re-drawn with the brush as it is edited
    private final class Live {
        let id: ObjectIdentifier
        var sm: Smoother
        var line: Centerline
        let pencil: Bool
        var preview: [Double] = []
        let settleT: Double, settleS: Double
        init(id: ObjectIdentifier, params: SmoothParams, pencil: Bool) {
            // as on the canvas: motion filtering and stabilisation settle the line behind the pen, streamline follows it
            var p = params
            settleT = 50 * p.mf; settleS = 14 * p.st
            p.mf = 0; p.st = 0
            self.id = id; self.sm = Smoother(p); self.pencil = pencil
            line = Centerline(spacing: 2, minDist: 0.3, startLen: 3, pressureDist: 1 + p.slp * 30)
        }
        var drawn: [Double] { line.settled(sigmaT: settleT, sigmaS: settleS) }
    }
    private var live: Live?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = .white
        layer.cornerRadius = 14
        layer.masksToBounds = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }

    func clear() { items = []; setNeedsDisplay() }
    func seedIfEmpty() {
        guard items.isEmpty, bounds.width > 40 else { return }
        var p: [Double] = []
        let w = Double(bounds.width), h = Double(bounds.height)
        for i in 0...80 {
            let t = Double(i) / 80
            let x: Double = w * 0.12 + t * w * 0.76
            let y: Double = h * 0.5 + sin(t * Double.pi * 2) * h * 0.16
            let pr: Double = 0.15 + 0.85 * pow(sin(Double.pi * t), 0.7)
            p.append(x); p.append(y); p.append(pr)
        }
        items.append(p)
        setNeedsDisplay()
    }
    override func layoutSubviews() { super.layoutSubviews(); seedIfEmpty() }

    private func ink() -> UIColor {
        guard let m = model else { return .black }
        if brush.isEraser { return UIColor(white: 0.55, alpha: 1) }
        let (r, g, b) = rgba(hex: m.prefs.color)
        return (r * 0.3 + g * 0.59 + b * 0.11) > 0.88 ? UIColor(white: 0.1, alpha: 1) : uiColor(hex: m.prefs.color)
    }
    private func pressure(_ t: UITouch) -> Double {
        guard t.type == .pencil, t.maximumPossibleForce > 0 else { return 0.5 }
        return clampD(Double(t.force / t.maximumPossibleForce), 0.001, 1)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard live == nil, let t = touches.first, let m = model else { return }
        let p = t.location(in: self)
        let lv = Live(id: ObjectIdentifier(t), params: m.smoothing(for: brush), pencil: t.type == .pencil)
        live = lv
        feed(lv, p, pressure(t), t.timestamp * 1000)
        setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let lv = live else { return }
        for t in touches where ObjectIdentifier(t) == lv.id {
            for c in event?.coalescedTouches(for: t) ?? [t] { feed(lv, c.location(in: self), pressure(c), c.timestamp * 1000) }
            var sm = lv.sm
            var extra: [Double] = []
            for pt in (lv.sm.o.light ? event?.predictedTouches(for: t) ?? [] : []) {
                let p = pt.location(in: self)
                for q in sm.push(Sample(x: Double(p.x), y: Double(p.y), p: lv.line.pressure, t: pt.timestamp * 1000)) {
                    extra.append(q.x); extra.append(q.y); extra.append(lv.line.pressure)
                }
            }
            lv.preview = extra
        }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }

    private func end(_ touches: Set<UITouch>) {
        guard let lv = live, touches.contains(where: { ObjectIdentifier($0) == lv.id }) else { return }
        for q in lv.sm.flush() { lv.line.add(q.x, q.y, q.p, q.t) }
        lv.line.finish()
        let pts = lv.drawn
        live = nil
        if !pts.isEmpty { items.append(pts) }
        onPressure?(nil, nil)
        setNeedsDisplay()
    }

    private func feed(_ lv: Live, _ p: CGPoint, _ raw: Double, _ t: Double) {
        let pr = lv.pencil ? (model?.pressure(raw) ?? raw) : raw
        if lv.pencil { onPressure?(raw, pr) }
        for q in lv.sm.push(Sample(x: Double(p.x), y: Double(p.y), p: pr, t: t)) { lv.line.add(q.x, q.y, q.p, q.t) }
        lv.preview = []
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(bounds)
        ink().setFill()
        let shape = brush.shape
        for it in items {
            ctx.addPath(StrokeGeometry.path(StrokeGeometry.outline(StrokeGeometry.bake(it, shape))))
            ctx.fillPath(using: .winding)
        }
        if let lv = live {
            let pts = lv.drawn + lv.line.provisional + lv.preview
            ctx.addPath(StrokeGeometry.path(StrokeGeometry.outline(StrokeGeometry.bake(pts, shape))))
            ctx.fillPath(using: .winding)
        }
    }
}

struct PadView: UIViewRepresentable {
    let model: AppModel
    let brush: Brush
    var clearToken: Int = 0
    var onPressure: ((Double?, Double?) -> Void)? = nil

    final class Coordinator { var token = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PadCanvas {
        let v = PadCanvas(frame: .zero)
        v.model = model
        v.brush = brush
        v.onPressure = onPressure
        return v
    }
    func updateUIView(_ v: PadCanvas, context: Context) {
        if v.brush != brush { v.brush = brush }
        v.onPressure = onPressure
        if context.coordinator.token != clearToken { context.coordinator.token = clearToken; v.clear() }
    }
}

/// Full-screen brush editor laid out like a studio: settings on the left, a drawing pad on the right.
struct BrushEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hSize
    let target: EditorTarget
    @State private var draft: Brush? = nil
    @State private var tab: EditorTab = .smoothing
    @State private var clearToken = 0
    @State private var confirmReset = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { model.editor = nil }.buttonStyle(.bordered)
                Spacer()
                VStack(spacing: 1) {
                    Text("BRUSH EDITOR").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                    Text(draft?.name ?? "").font(.headline).lineLimit(1)
                }
                Spacer()
                Button("Done") { if let d = draft { model.commitBrush(d) }; model.editor = nil }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let d = draft {
                if hSize == .compact {
                    ScrollView {
                        VStack(spacing: 0) {
                            tabsRow
                            settings(d).padding(16)
                            pad(d).frame(height: 380).padding(16)
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(EditorTab.allCases) { t in tabButton(t) }
                            Spacer()
                        }
                        .padding(10).frame(width: 176)
                        Divider()
                        ScrollView { settings(d).padding(16) }.frame(width: 360)
                        Divider()
                        pad(d).padding(14)
                    }
                }
            } else { Spacer() }
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear { if draft == nil { draft = model.brush(target.id); tab = target.tab } }
        .alert("Reset this brush?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetBrush(target.id); draft = model.brush(target.id) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It goes back to its original settings.") }
        .alert("Delete this brush?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteBrush(target.id); model.editor = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It will be removed from My brushes.") }
    }

    private var tabsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) { ForEach(EditorTab.allCases) { t in tabButton(t) } }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
    private func tabButton(_ t: EditorTab) -> some View {
        Button { tab = t } label: {
            Text(t.rawValue).font(.subheadline.weight(.semibold))
                .frame(maxWidth: hSize == .compact ? nil : .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                .background(tab == t ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func bind(_ key: String) -> Binding<Double> {
        Binding(get: { draft?[key] ?? 0 }, set: { v in draft?[key] = v })
    }

    @ViewBuilder private func settings(_ d: Brush) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch tab {
            case .smoothing:
                SectionLabel("Streamline")
                SettingSlider(label: "Amount", value: bind("streamline"), hint: "The line trails behind the pencil like it's on a string, for long gliding curves. At 0% it comes straight from the pen.")
                SettingSlider(label: "Pressure", value: bind("slPressure"), hint: "How far the pencil travels before pressure fully changes. Higher builds thickness gradually for even, calm lines.")
                SectionLabel("Stabilisation")
                SettingSlider(label: "Amount", value: bind("stab"), hint: "Smooths the shape of the line just behind the pen; the end of the line always stays on the pen. Higher straightens wobbles over a longer stretch.")
                SectionLabel("Motion filtering")
                SettingSlider(label: "Amount", value: bind("motion"), hint: "Removes hand jitter just behind the pen, with no lag. The same at every speed.")
                Text("Global smoothing (\(pct(model.prefs.gStab)) stabilisation, \(pct(model.prefs.gMotion)) motion filtering) adds on top of these.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Pressure and smoothing for all brushes") { model.showGlobal = true }.buttonStyle(.bordered)
            case .taper:
                SectionLabel("Taper")
                SettingSlider(label: "Start", value: bind("taperStart"), hint: "Length of the thin lead-in at the start of each stroke.")
                SettingSlider(label: "End", value: bind("taperEnd"), hint: "Length of the flick-out at the end of each stroke.")
            case .pressure:
                SectionLabel("Pressure")
                SettingSlider(label: "Pressure changes size", value: bind("thinning"), hint: "At 0% the line stays one width however hard you press.")
                SettingSlider(label: "Response", value: bind("gamma"), range: 0.4...2.5, step: 0.05,
                              format: { $0 < 0.95 ? "Softer" : ($0 > 1.05 ? "Firmer" : "Linear") },
                              hint: "Softer reaches full size with a light touch; firmer needs more pressure.")
                Text("This sits on top of the pressure curve for all brushes, which you can shape in Pressure and smoothing.").font(.footnote).foregroundStyle(.secondary)
            case .shape:
                SectionLabel("Shape")
                SettingSlider(label: "Default size", value: Binding(get: { sizeToV(draft?.size ?? 1) }, set: { v in draft?.size = (vToSize(v) * 100).rounded() / 100 }),
                              range: 0...1, step: 0.001, format: { fmtSize(vToSize($0)) }, hint: "The size this brush starts at. The side bar changes it while you draw.")
            case .about:
                SectionLabel("About this brush")
                if model.isCustom(target.id) {
                    TextField("Name", text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = String($0.prefix(40)) }))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text("\(d.name) is a built-in brush. Your changes are kept, and you can reset it at any time.").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Every stroke is stored as a vector shape, so it stays sharp at any zoom and exports cleanly to SVG.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    if !d.isEraser {
                        Button("Duplicate brush") {
                            model.commitBrush(d)
                            let id = model.duplicateBrush(target.id)
                            model.librarySet = "mine"
                            model.editor = EditorTarget(id: id, tab: .about)
                            model.toast("Duplicated into My brushes")
                        }
                    }
                    if model.isCustom(target.id) { Button("Delete brush", role: .destructive) { confirmDelete = true } }
                    else { Button("Reset to default") { confirmReset = true } }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func pad(_ d: Brush) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Drawing pad").font(.subheadline.weight(.semibold))
                Text("Try the brush here · 100% size").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { clearToken += 1 }.buttonStyle(.bordered)
            }
            PadView(model: model, brush: d, clearToken: clearToken)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.12)))
        }
    }
}

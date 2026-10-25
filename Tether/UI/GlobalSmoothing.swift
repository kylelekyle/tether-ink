import SwiftUI

/// Drag points to shape how pressure maps to line weight. Tap the graph to add a point; drag one off the graph to remove it.
struct PressureCurveEditor: View {
    @Environment(AppModel.self) private var model
    var live: (Double, Double)?
    @State private var dragIndex: Int? = nil
    @State private var dragOut = false

    private let m: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - m * 2, h = geo.size.height - m * 2
            let nodes = model.prefs.curve
            Canvas { ctx, size in
                let grid = Path { p in
                    for i in 0...4 {
                        let a = m + w * CGFloat(i) / 4, b = m + h * CGFloat(i) / 4
                        p.move(to: CGPoint(x: a, y: m)); p.addLine(to: CGPoint(x: a, y: m + h))
                        p.move(to: CGPoint(x: m, y: b)); p.addLine(to: CGPoint(x: m + w, y: b))
                    }
                }
                ctx.stroke(grid, with: .color(.primary.opacity(0.12)), lineWidth: 1)
                ctx.stroke(Path { p in p.move(to: CGPoint(x: m, y: m + h)); p.addLine(to: CGPoint(x: m + w, y: m)) },
                           with: .color(.primary.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                let curve = Path { p in
                    for i in 0...120 {
                        let t = Double(i) / 120
                        let pt = CGPoint(x: m + w * CGFloat(t), y: m + h * CGFloat(1 - PressureCurve.eval(nodes, t)))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                ctx.stroke(curve, with: .color(.primary), lineWidth: 2.5)
                for (i, n) in nodes.enumerated() {
                    let c = CGPoint(x: m + w * CGFloat(n[0]), y: m + h * CGFloat(1 - n[1]))
                    let r = CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)
                    ctx.fill(Path(ellipseIn: r), with: .color(i == dragIndex ? .accentColor : Color(uiColor: .systemBackground)))
                    ctx.stroke(Path(ellipseIn: r), with: .color(.accentColor), lineWidth: 2)
                }
                if let l = live {
                    let c = CGPoint(x: m + w * CGFloat(l.0), y: m + h * CGFloat(1 - l.1))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.accentColor))
                }
                _ = size
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var ns = model.prefs.curve
                func toNode(_ p: CGPoint) -> (Double, Double) { (Double((p.x - m) / w), Double(1 - (p.y - m) / h)) }
                if dragIndex == nil {
                    var best = 22.0, hit: Int? = nil
                    for (i, n) in ns.enumerated() {
                        let c = CGPoint(x: m + w * CGFloat(n[0]), y: m + h * CGFloat(1 - n[1]))
                        let d = Double(hypot(c.x - g.startLocation.x, c.y - g.startLocation.y))
                        if d < best { best = d; hit = i }
                    }
                    if hit == nil {
                        let (nx, ny) = toNode(g.startLocation)
                        guard nx > 0.03 && nx < 0.97 && ns.count < 8 else { return }
                        ns.append([nx, min(1, max(0, ny))])
                        ns.sort { $0[0] < $1[0] }
                        hit = ns.firstIndex { $0[0] == nx }
                    }
                    dragIndex = hit
                }
                guard let i = dragIndex, i < ns.count else { return }
                let (nx, ny) = toNode(g.location)
                let isEnd = i == 0 || i == ns.count - 1
                dragOut = !isEnd && (g.location.x < -20 || g.location.y < -20 || g.location.x > geo.size.width + 20 || g.location.y > geo.size.height + 20)
                if !isEnd { ns[i][0] = min(max(nx, ns[i - 1][0] + 0.02), ns[i + 1][0] - 0.02) }
                ns[i][1] = min(1, max(0, ny))
                model.setPref(\.curve, ns)
            }
            .onEnded { _ in
                if let i = dragIndex, dragOut {
                    var ns = model.prefs.curve
                    if i > 0 && i < ns.count - 1 { ns.remove(at: i); model.setPref(\.curve, ns) }
                }
                dragIndex = nil; dragOut = false
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300)
        .accessibilityLabel("Pressure curve")
    }
}

struct GlobalSmoothingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var live: (Double, Double)? = nil
    @State private var clearToken = 0

    var body: some View {
        NavigationStack {
            Group {
                if hSize == .compact {
                    ScrollView { VStack(spacing: 20) { controls; pad.frame(height: 360) }.padding(16) }
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        ScrollView { controls.padding(.vertical, 4) }.frame(width: 360)
                        pad
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Pressure and smoothing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showGlobal = false } } }
        }
        .presentationDetents([.large])
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Smoothing for every brush")
            SettingSlider(label: "Stabilisation", value: model.bind(\.gStab), hint: "Adds to each brush's own stabilisation.")
            SettingSlider(label: "Motion filtering", value: model.bind(\.gMotion), hint: "Adds to each brush's own motion filtering.")
            SettingSlider(label: "Motion filtering expression", value: model.bind(\.gMotionExpr))
            SectionLabel("Shapes")
            Toggle("Hold at the end of a stroke to snap it", isOn: model.bind(\.snap))
            SettingSlider(label: "Hold time", value: model.bind(\.snapDelay), range: 0.25...1.2, step: 0.01, format: { String(format: "%.2f s", $0) },
                          hint: "Lines become straight; closed loops become ellipses or circles. Keep holding a line to swing its angle.")
            SectionLabel("Pressure curve")
            PressureCurveEditor(live: live)
            Text("Drag the points. Tap the graph to add a point; drag one off the graph to remove it. Draw on the pad to see your pressure on the curve.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Reset") { model.setPref(\.curve, [[0, 0], [1, 1]]) }
                Button("Light touch") { model.setPref(\.curve, [[0, 0], [0.3, 0.55], [1, 1]]) }
                Button("Firm touch") { model.setPref(\.curve, [[0, 0], [0.55, 0.3], [1, 1]]) }
            }
            .buttonStyle(.bordered)
        }
    }

    private var pad: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Drawing pad").font(.subheadline.weight(.semibold))
                Text(model.currentBrush.name).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { clearToken += 1 }.buttonStyle(.bordered)
            }
            PadView(model: model, brush: model.currentBrush, clearToken: clearToken, onPressure: { raw, out in
                if let r = raw, let o = out { live = (r, o) } else { live = nil }
            })
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.12)))
        }
    }
}

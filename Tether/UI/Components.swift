import SwiftUI

extension Color {
    /// Solid panel colour (no blur): cheap to draw and stays static.
    static let chrome = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.086, green: 0.09, blue: 0.106, alpha: 1)
        : UIColor(red: 0.965, green: 0.965, blue: 0.973, alpha: 1) })
}

/// A labelled 0…1 (or custom range) slider with its value on the right and an optional hint underneath.
struct SettingSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0.01
    var format: (Double) -> String = pct
    var hint: String? = nil
    var onEditingEnded: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(format(value)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: { editing in if !editing { onEditingEnded?() } })
            if let h = hint { Text(h).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
}

/// Procreate-style vertical slider for the side bar: drag up and down; slide sideways for finer control.
/// A tap (no drag) calls onTap instead of changing the value.
struct VSlider: View {
    let value: Double
    let onChange: (Double) -> Void
    var onDrag: (Bool, Bool) -> Void = { _, _ in }
    var onTap: (() -> Void)? = nil

    @State private var dragValue: Double? = nil
    @State private var lastY: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let v = dragValue ?? value
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.28)).frame(height: max(0, h * v))
                Capsule().fill(Color.primary).frame(width: w + 6, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(y: -(h * v) + 7)
            }
            // GeometryReader pins its content to the top-left; the handle is wider than the track,
            // so give the stack the track's exact size to keep the handle centred on it.
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragValue == nil {
                            // still a tap until the finger or pencil really moves
                            if onTap != nil && hypot(g.translation.width, g.translation.height) < 5 { return }
                            dragValue = value; lastY = g.location.y
                        }
                        let cur = dragValue ?? value
                        let dx = abs(g.location.x - g.startLocation.x)
                        let precision = 1 / (1 + max(0, dx - 40) / 45)
                        let dy = g.location.y - lastY
                        lastY = g.location.y
                        let nv = min(1, max(0, cur - Double(dy / max(h, 1)) * Double(precision)))
                        dragValue = nv
                        if nv != cur { onChange(nv) }
                        onDrag(true, precision < 0.98)
                    }
                    .onEnded { _ in
                        if dragValue == nil { onTap?(); return }
                        dragValue = nil
                        onDrag(false, false)
                    }
            )
        }
        .frame(width: 30)
    }
}

/// Type an exact brush size. Opens from a tap on the side bar's size slider.
struct SizeEntry: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.tool == .eraser ? "Eraser size" : "Brush size").font(.headline)
            HStack(spacing: 8) {
                TextField(sizeText(model.currentSize), text: $text)
                    .keyboardType(.decimalPad)
                    .focused($focused)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .onSubmit { apply(); model.sizeEntry = false }
                Text("px").foregroundStyle(.secondary)
                Button("Set") { apply(); model.sizeEntry = false }
                    .buttonStyle(.borderedProminent)
            }
            Text("\(sizeText(sizeMin)) to \(sizeText(sizeMax)) px").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 260)
        .background(Color.chrome, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onDisappear(perform: apply)   // tapping outside keeps what was typed
    }

    private func apply() {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        text = ""
        guard let s = Double(t), s.isFinite, s > 0 else { return }
        let size = min(max(s, sizeMin), sizeMax)
        if abs(size - model.currentSize) > 1e-9 { model.currentSize = size }
    }
    private func sizeText(_ s: Double) -> String {
        s < 10 ? String(format: "%.1f", s) : "\(Int(s.rounded()))"
    }
}

/// A small preview of a brush's stroke shape.
struct BrushPreview: View {
    let brush: Brush
    var body: some View {
        Canvas { ctx, size in
            var p: [Double] = []
            let w = Double(size.width), h = Double(size.height)
            for i in 0...60 {
                let t = Double(i) / 60
                let x: Double = 10 + t * (w - 20)
                let y: Double = h / 2 + sin(t * Double.pi * 2) * h * 0.22
                let pr: Double = 0.15 + 0.85 * pow(sin(Double.pi * t), 0.7)
                p.append(x); p.append(y); p.append(pr)
            }
            var shape = brush.shape
            shape.size = min(max(brush.size, 1.2), 10)
            let o = StrokeGeometry.outline(p, shape, last: true)
            ctx.fill(Path(StrokeGeometry.path(o)), with: .foreground)
        }
        .frame(width: 120, height: 34)
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Color.chrome, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

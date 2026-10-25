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
struct VSlider: View {
    let value: Double
    let onChange: (Double) -> Void
    var onDrag: (Bool, Bool) -> Void = { _, _ in }

    @State private var dragValue: Double? = nil
    @State private var lastY: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let v = dragValue ?? value
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.1))
                RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.28)).frame(height: max(0, h * v))
                Capsule().fill(Color.primary).frame(width: 36, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(y: -(h * v) + 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragValue == nil { dragValue = value; lastY = g.location.y }
                        let dx = abs(g.location.x - g.startLocation.x)
                        let precision = 1 / (1 + max(0, dx - 40) / 45)
                        let dy = g.location.y - lastY
                        lastY = g.location.y
                        let nv = min(1, max(0, (dragValue ?? value) - Double(dy / max(h, 1)) * Double(precision)))
                        dragValue = nv
                        onChange(nv)
                        onDrag(true, precision < 0.98)
                    }
                    .onEnded { _ in dragValue = nil; onDrag(false, false) }
            )
        }
        .frame(width: 30)
    }
}

/// A small preview of a brush's stroke shape.
struct BrushPreview: View {
    let brush: Brush
    var body: some View {
        Canvas { ctx, size in
            var p: [Double] = []
            for i in 0...60 {
                let t = Double(i) / 60
                p += [10 + t * (size.width - 20), size.height / 2 + sin(t * .pi * 2) * size.height * 0.22, 0.15 + 0.85 * pow(sin(.pi * t), 0.7)]
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

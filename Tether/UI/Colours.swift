import SwiftUI

/// Hue, saturation, brightness (0…1). Kept as the panel's own state so the hue survives greys and black.
struct HSB: Equatable {
    var h: Double
    var s: Double
    var b: Double

    init(h: Double, s: Double, b: Double) { self.h = h; self.s = s; self.b = b }
    init(hex: String, keepHue: Double? = nil) {
        var hh: CGFloat = 0, ss: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        uiColor(hex: hex).getHue(&hh, saturation: &ss, brightness: &bb, alpha: &aa)
        h = Double(hh); s = Double(ss); b = Double(bb)
        if let k = keepHue, s < 0.002 || b < 0.002 { h = k }
    }
    var hex: String { hexString(UIColor(hue: CGFloat(h), saturation: CGFloat(s), brightness: CGFloat(b), alpha: 1)) }
    var color: Color { Color(hue: h, saturation: s, brightness: b) }
    var rgb: (Double, Double, Double) { let (r, g, bl) = rgba(hex: hex); return (Double(r), Double(g), Double(bl)) }
}

private let hueStops: [Color] = (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }

private struct Knob: View {
    var size: CGFloat = 22
    var body: some View {
        Circle().strokeBorder(Color.white, lineWidth: 3)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}

/// Saturation left to right, brightness top to bottom. Three static gradients, so it costs almost nothing to draw.
private struct SVSquare: View {
    @Binding var hsb: HSB
    var onChange: (Bool) -> Void
    var corner: CGFloat = 10
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Color(hue: hsb.h, saturation: 1, brightness: 1)
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Knob().position(x: CGFloat(hsb.s) * w, y: CGFloat(1 - hsb.b) * h)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hsb.s = clampD(Double(v.location.x / w), 0, 1)
                hsb.b = clampD(1 - Double(v.location.y / h), 0, 1)
                onChange(false)
            }.onEnded { _ in onChange(true) })
        }
    }
}

/// Hue ring with a saturation/brightness square inside it.
private struct ColourDisc: View {
    @Binding var hsb: HSB
    var onChange: (Bool) -> Void
    var body: some View {
        GeometryReader { g in
            let d = min(g.size.width, g.size.height)
            let ring: CGFloat = 28
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let mid = d / 2 - ring / 2
            let side = (d / 2 - ring - 8) * 1.414
            ZStack {
                Circle()
                    .strokeBorder(AngularGradient(colors: hueStops, center: .center), lineWidth: ring)
                    .frame(width: d, height: d)
                    .position(c)
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        var a = atan2(Double(v.location.y - c.y), Double(v.location.x - c.x)) / (2 * .pi)
                        if a < 0 { a += 1 }
                        hsb.h = a
                        onChange(false)
                    }.onEnded { _ in onChange(true) })
                Knob(size: ring - 2)
                    .position(x: c.x + CGFloat(cos(hsb.h * 2 * .pi)) * mid, y: c.y + CGFloat(sin(hsb.h * 2 * .pi)) * mid)
                SVSquare(hsb: $hsb, onChange: onChange, corner: 6)
                    .frame(width: side, height: side)
                    .position(c)
            }
        }
    }
}

/// A gradient track with a knob; value 0…1.
private struct GradientSlider: View {
    let label: String
    let colors: [Color]
    @Binding var value: Double
    let text: String
    var onChange: (Bool) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 14, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                    Knob(size: 24).position(x: 12 + CGFloat(value) * (w - 24), y: g.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    value = clampD(Double((v.location.x - 12) / max(1, w - 24)), 0, 1)
                    onChange(false)
                }.onEnded { _ in onChange(true) })
            }
            .frame(height: 26)
            Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
        }
    }
}

private struct Swatch: View {
    let hex: String
    var selected = false
    var body: some View {
        RoundedRectangle(cornerRadius: 7).fill(Color(uiColor: uiColor(hex: hex)))
            .aspectRatio(1, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.18), lineWidth: selected ? 2.5 : 1))
    }
}

struct ColourPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("colourTab") private var tab = "disc"
    @State private var hsb = HSB(h: 0, s: 0, b: 0)
    @State private var previous = "#111111"
    @State private var lastPush: CFTimeInterval = 0
    @State private var hexField = ""
    @State private var ready = false

    private static let palettes: [(String, [String])] = [
        ("Inks", ["#000000", "#111111", "#1b1d22", "#232a35", "#2e2a26", "#3b2f2f", "#4a4a4a", "#6b6b6b", "#8c8c8c", "#b3b3b3", "#d9d9d9", "#ffffff"]),
        ("Basics", ["#e53935", "#fb8c00", "#fdd835", "#7cb342", "#43a047", "#00acc1", "#1e88e5", "#3949ab", "#8e24aa", "#d81b60", "#6d4c41", "#546e7a"]),
        ("Skin", ["#fbe3d0", "#f3c9ab", "#e8b08f", "#d99a73", "#c68460", "#b06f4f", "#965a3e", "#7b4630", "#613524", "#4a271b"]),
        ("Soft", ["#ffd1dc", "#ffe4c4", "#fff3b0", "#d5f5e3", "#c9f0ff", "#d6dcff", "#ecd9ff", "#ffe0f0"]),
    ]

    var body: some View {
        VStack(spacing: 12) {
            header
            Group {
                switch tab {
                case "classic": classic
                case "value": valueTab
                case "palettes": palettesTab
                default: ColourDisc(hsb: $hsb, onChange: push).frame(height: 300)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if tab != "palettes" { history }
            tabs
        }
        .padding(14)
        .frame(width: 360, height: 560)
        .onAppear {
            previous = model.prefs.color
            hsb = HSB(hex: model.prefs.color)
            hexField = String(model.prefs.color.dropFirst())
            ready = true
        }
        .onChange(of: model.prefs.color) { _, new in
            if new != hsb.hex.lowercased() { hsb = HSB(hex: new, keepHue: hsb.h); hexField = String(new.dropFirst()) }
        }
    }

    /// Live while dragging (at most 30 times a second, so the rest of the interface isn't redrawn every frame), exact on release.
    private func push(_ final: Bool) {
        let now = CACurrentMediaTime()
        if !final && now - lastPush < 1.0 / 30 { return }
        lastPush = now
        let hex = hsb.hex.lowercased()
        hexField = String(hex.dropFirst())
        if hex != model.prefs.color { model.setColor(hex) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Colours").font(.headline)
            Spacer()
            Button { model.panel = nil; model.pickOnce = true; model.toast("Touch the canvas to pick a colour") } label: {
                Image(systemName: "eyedropper").frame(width: 34, height: 30)
            }
            .accessibilityLabel("Pick a colour from the canvas")
            HStack(spacing: 0) {
                Button { model.setColor(previous); hsb = HSB(hex: previous, keepHue: hsb.h) } label: {
                    Rectangle().fill(Color(uiColor: uiColor(hex: previous))).frame(width: 30, height: 30)
                }
                .accessibilityLabel("Previous colour")
                Rectangle().fill(ready ? hsb.color : Color(uiColor: uiColor(hex: model.prefs.color))).frame(width: 30, height: 30)
                    .accessibilityLabel("Current colour")
            }
            .buttonStyle(.plain)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.18)))
        }
    }

    private var classic: some View {
        VStack(spacing: 14) {
            SVSquare(hsb: $hsb, onChange: push).frame(height: 220)
            sliders
        }
    }

    private var sliders: some View {
        VStack(spacing: 10) {
            GradientSlider(label: "H", colors: hueStops, value: $hsb.h, text: "\(Int((hsb.h * 360).rounded()))°", onChange: push)
            GradientSlider(label: "S", colors: [Color(hue: hsb.h, saturation: 0, brightness: hsb.b), Color(hue: hsb.h, saturation: 1, brightness: hsb.b)],
                           value: $hsb.s, text: "\(Int((hsb.s * 100).rounded()))%", onChange: push)
            GradientSlider(label: "B", colors: [.black, Color(hue: hsb.h, saturation: hsb.s, brightness: 1)],
                           value: $hsb.b, text: "\(Int((hsb.b * 100).rounded()))%", onChange: push)
        }
    }

    private var valueTab: some View {
        let (r, g, b) = hsb.rgb
        return VStack(spacing: 10) {
            sliders
            Divider().padding(.vertical, 2)
            rgbSlider("R", r, 0) { [Color(red: 0, green: g, blue: b), Color(red: 1, green: g, blue: b)] }
            rgbSlider("G", g, 1) { [Color(red: r, green: 0, blue: b), Color(red: r, green: 1, blue: b)] }
            rgbSlider("B", b, 2) { [Color(red: r, green: g, blue: 0), Color(red: r, green: g, blue: 1)] }
            HStack {
                Text("Hex").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text("#").foregroundStyle(.secondary)
                TextField("000000", text: $hexField)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(width: 90)
                    .onSubmit {
                        let h = "#" + hexField.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
                        if isHexColor(h) { hsb = HSB(hex: h, keepHue: hsb.h); push(true) } else { hexField = String(model.prefs.color.dropFirst()) }
                    }
            }
            .padding(.top, 4)
        }
    }

    private func rgbSlider(_ label: String, _ v: Double, _ ch: Int, colors: () -> [Color]) -> some View {
        let bind = Binding<Double>(get: { v }, set: { nv in
            var (r, g, b) = hsb.rgb
            if ch == 0 { r = nv } else if ch == 1 { g = nv } else { b = nv }
            hsb = HSB(hex: hexString(UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)), keepHue: hsb.h)
        })
        return GradientSlider(label: label, colors: colors(), value: bind, text: "\(Int((v * 255).rounded()))", onChange: push)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("History")
                Spacer()
                if !model.prefs.colorHistory.isEmpty {
                    Button("Clear") { model.setPref(\.colorHistory, []) }.font(.caption.weight(.semibold))
                }
            }
            if model.prefs.colorHistory.isEmpty {
                Text("Colours you draw with show up here.").font(.caption).foregroundStyle(.secondary).frame(height: 30, alignment: .leading)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
                    ForEach(model.prefs.colorHistory.prefix(10), id: \.self) { c in
                        Button { pick(c) } label: { Swatch(hex: c, selected: c == model.prefs.color) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var palettesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SectionLabel("My palette")
                        Spacer()
                        Button { addToPalette() } label: { Label("Add current", systemImage: "plus").font(.caption.weight(.semibold)) }
                    }
                    if model.prefs.palette.isEmpty {
                        Text("Tap Add current to keep the colour you have now. Touch and hold a swatch to remove it.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        grid(model.prefs.palette, removable: true)
                    }
                }
                ForEach(Self.palettes, id: \.0) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(p.0)
                        grid(p.1, removable: false)
                    }
                }
            }
        }
    }

    private func grid(_ colors: [String], removable: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                Button { pick(c) } label: { Swatch(hex: c, selected: c == model.prefs.color) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if removable { Button("Remove", systemImage: "trash", role: .destructive) { model.setPref(\.palette, model.prefs.palette.filter { $0 != c }) } }
                    }
            }
        }
    }

    private func addToPalette() {
        let c = model.prefs.color.lowercased()
        if model.prefs.palette.contains(c) { model.toast("Already in your palette"); return }
        model.setPref(\.palette, model.prefs.palette + [c])
    }

    private func pick(_ c: String) {
        hsb = HSB(hex: c, keepHue: hsb.h)
        hexField = String(c.dropFirst())
        model.setColor(c)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton("disc", "Disc", "circle.circle")
            tabButton("classic", "Classic", "square.fill")
            tabButton("value", "Value", "slider.horizontal.3")
            tabButton("palettes", "Palettes", "square.grid.3x3.fill")
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private func tabButton(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { tab = id } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(tab == id ? Color.accentColor : Color.secondary)
            .background(tab == id ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == id ? .isSelected : [])
    }
}

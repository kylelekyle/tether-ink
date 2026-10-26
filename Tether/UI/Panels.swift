import SwiftUI

// MARK: - brush library

struct BrushLibraryPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.prefs.brushId
        let set = model.librarySet ?? model.brush(current).set
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Brush library").font(.headline)
                Spacer()
                Button { let id = model.duplicateBrush(current); model.librarySet = "mine"; model.panel = nil; model.editor = EditorTarget(id: id, tab: .about) } label: {
                    Label("New", systemImage: "plus").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<Brush.sets.count, id: \.self) { i in
                        let s = Brush.sets[i]
                        Button { model.librarySet = s.id } label: {
                            HStack {
                                Text(s.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(model.brushes(inSet: s.id).count)").font(.caption).monospacedDigit()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .foregroundStyle(s.id == set ? Color.primary : Color.secondary)
                            .background(s.id == set ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 128)
                ScrollView {
                    VStack(spacing: 4) {
                        let list = model.brushes(inSet: set)
                        if list.isEmpty {
                            Text("Brushes you duplicate or create appear here. Tap New to copy the current brush.")
                                .font(.footnote).foregroundStyle(.secondary).padding(8)
                        }
                        ForEach(list) { b in
                            let on = b.id == current
                            Button {
                                if on { model.panel = nil; model.editor = EditorTarget(id: b.id, tab: .smoothing) }
                                else { model.setPref(\.brushId, b.id) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(b.name).font(.subheadline.weight(.semibold))
                                        Text(fmtSize(b.size) + (on ? " · tap again to edit" : "")).font(.caption).monospacedDigit().opacity(0.75)
                                    }
                                    Spacer(minLength: 4)
                                    BrushPreview(brush: b)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 480, height: 470)
    }
}

// MARK: - eraser

struct EraserPanel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Eraser").font(.headline)
            ForEach(Brush.erasers) { b in
                let on = b.id == model.prefs.eraserId
                Button {
                    if on { model.panel = nil; model.editor = EditorTarget(id: b.id, tab: .smoothing) } else { model.setPref(\.eraserId, b.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name).font(.subheadline.weight(.semibold))
                        Text((b.note ?? "") + (on ? " · tap again to edit" : "")).font(.caption).opacity(0.75)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
            Text("Size and opacity come from the side bar, just like the brush.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - smoothing quick panel

struct SmoothingPanel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let b = model.currentBrush
        VStack(alignment: .leading, spacing: 12) {
            Text("Smoothing").font(.headline)
            SectionLabel("When I lift the pencil")
            Toggle("Catch up to the pencil", isOn: model.bind(\.catchUp))
            Text(model.prefs.catchUp ? "The line finishes where the pencil lifted." : "The line stays exactly as drawn: smoothing never adds a tail when you lift.")
                .font(.footnote).foregroundStyle(.secondary)
            SectionLabel(b.name)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Streamline").foregroundStyle(.secondary); Text(pct(b.streamline)).monospacedDigit() }
                GridRow { Text("Stabilisation").foregroundStyle(.secondary); Text(pct(b.stab) + (model.prefs.gStab > 0 ? " + \(pct(model.prefs.gStab)) global" : "")).monospacedDigit() }
                GridRow { Text("Motion filtering").foregroundStyle(.secondary); Text(pct(b.motion) + (model.prefs.gMotion > 0 ? " + \(pct(model.prefs.gMotion)) global" : "")).monospacedDigit() }
            }
            .font(.subheadline)
            rowButton("Edit \(b.name) smoothing", "Streamline, stabilisation and motion filtering for this brush") {
                model.panel = nil; model.editor = EditorTarget(id: model.currentBrushId, tab: .smoothing)
            }
            rowButton("Pressure and smoothing", "Pressure curve and smoothing for every brush") { model.panel = nil; model.showGlobal = true }
        }
        .padding(14)
        .frame(width: 350)
    }
}

func rowButton(_ title: String, _ sub: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(sub).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
    }
    .buttonStyle(.plain)
}

// MARK: - layers

struct LayersPanel: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var bgOpen = false
    @State private var renaming: Layer? = nil
    @State private var newName = ""
    @State private var opacityStart: Double? = nil

    var body: some View {
        let _ = model.docVersion
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Button { model.addLayer() } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold)).frame(width: 30, height: 24)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("New layer")
            }
            if let d = model.doc {
                List {
                    Section {
                        ForEach(Array(d.layers.reversed())) { L in
                            layerRow(d, L)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    // declared right to left, so they read Lock · Duplicate · Delete
                                    Button(role: .destructive) { model.deleteLayer(L) } label: { Label("Delete", systemImage: "trash") }
                                    Button { model.duplicateLayer(L) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                        .tint(Color(white: 0.55))
                                    Button { model.toggleLock(L) } label: { Label(L.locked ? "Unlock" : "Lock", systemImage: L.locked ? "lock.open" : "lock") }
                                        .tint(Color(white: 0.35))
                                }
                                .modifier(PanelRow())
                        }
                        // press and hold a layer to lift it; the others slide apart while it's dragged
                        .onMove { from, to in
                            var shown = Array(d.layers.reversed())
                            shown.move(fromOffsets: from, toOffset: to)
                            model.reorderLayers(Array(shown.reversed()))
                        }
                    }
                    Section {
                        if d.layers.isEmpty {
                            Text("No layers. Tap + to add one.").font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                .modifier(PanelRow())
                        }
                        bgRow(d).modifier(PanelRow())
                        if bgOpen { bgOptions(d).modifier(PanelRow()) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
            }
        }
        .padding(14)
        .frame(width: 350, height: 540)
        .alert("Rename layer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let L = renaming { model.renameLayer(L, newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func layerRow(_ d: Doc, _ L: Layer) -> some View {
        let on = L.id == d.active
        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                LayerThumb(doc: d, layer: L, version: model.docVersion)
                Button {
                    if on { expanded.toggle() } else { model.selectLayer(L.id); expanded = false }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(L.items.count) \(L.items.count == 1 ? "item" : "items")" + (L.opacity < 1 ? " · \(pct(L.opacity))" : "")).font(.caption).monospacedDigit().opacity(0.75)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if L.locked {
                    Button { model.toggleLock(L) } label: {
                        Image(systemName: "lock.fill").font(.system(size: 14, weight: .medium)).frame(width: 26, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unlock \(L.name)")
                }
                Button { model.toggleVisible(L) } label: {
                    Image(systemName: L.visible ? "eye" : "eye.slash").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L.visible ? "Hide \(L.name)" : "Show \(L.name)")
                MoveArrows(up: { model.moveLayer(L, up: true) }, down: { model.moveLayer(L, up: false) })
            }
            .padding(6)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
            if on && expanded { layerOptions(L) }
        }
    }

    private func layerOptions(_ L: Layer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingSlider(label: "Layer opacity", value: Binding(get: { L.opacity }, set: { v in
                if opacityStart == nil { opacityStart = L.opacity }
                model.setLayerOpacity(L, v, commitFrom: nil)
            }), onEditingEnded: { model.setLayerOpacity(L, L.opacity, commitFrom: opacityStart); opacityStart = nil })
            HStack {
                Button("Rename") { newName = L.name; renaming = L }
                Button("Clear") { model.clearLayer() }
            }
            .buttonStyle(.bordered)
            Text("Swipe a layer left to lock, duplicate or delete it.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The paper: always there, always locked. The eye hides it (exports go transparent).
    private func bgRow(_ d: Doc) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: uiColor(hex: d.bg))).frame(width: 44, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                .opacity(d.bgOn ? 1 : 0.35)
            Button { bgOpen.toggle() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background").font(.subheadline.weight(.semibold))
                    Text(d.bgOn ? d.bg : "Hidden · exports transparent").font(.caption).opacity(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Image(systemName: "lock.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 26, height: 44)
                .accessibilityLabel("Background is locked")
            Button { model.setBackground(nil, on: !d.bgOn) } label: {
                Image(systemName: d.bgOn ? "eye" : "eye.slash").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(d.bgOn ? "Hide background" : "Show background")
            Color.clear.frame(width: 30, height: 1)   // lines the eye up with the layer rows
        }
        .padding(6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
    }

    private func bgOptions(_ d: Doc) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(["#ffffff", "#f6f1e7", "#ecebe6", "#d9dce3", "#9aa0ab", "#3a3b40", "#1c1c1f", "#000000"], id: \.self) { c in
                    Button { model.setBackground(c) } label: {
                        RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: uiColor(hex: c))).frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(c == d.bg ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: c == d.bg ? 2.5 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Use current colour") { model.setBackground(model.prefs.color) }.buttonStyle(.bordered)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Up and down chevrons with a grip between them, on the right edge of a layer row.
struct MoveArrows: View {
    let up: () -> Void
    let down: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Button(action: up) { Image(systemName: "chevron.up").frame(width: 30, height: 18).contentShape(Rectangle()) }
                .accessibilityLabel("Move layer up")
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .semibold)).opacity(0.45).frame(height: 10)
                .accessibilityHidden(true)
            Button(action: down) { Image(systemName: "chevron.down").frame(width: 30, height: 18).contentShape(Rectangle()) }
                .accessibilityLabel("Move layer down")
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.plain)
    }
}

/// List rows that look like the rest of the panels: no separators, no row background.
private struct PanelRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct LayerThumb: View {
    let doc: Doc
    let layer: Layer
    let version: Int
    var body: some View {
        let k = min(88 / doc.w, 88 / doc.h)
        let img = DocRenderer.renderDoc(layers: [LayerSnap(layer)], w: doc.w, h: doc.h, bg: nil, scale: k)
        ZStack {
            Checkerboard()
            if let img = img { Image(decorative: img, scale: 2).resizable().scaledToFit() }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.1)))
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let s: CGFloat = 5
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : s
                while x < size.width { ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.86))); x += 2 * s }
                y += s; row += 1
            }
        }
    }
}

// MARK: - colour

// MARK: - actions

struct ActionsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var tab = "Share"
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions").font(.headline)
            Picker("Section", selection: $tab) { ForEach(["Add", "Canvas", "Share", "Prefs", "Help"], id: \.self) { Text($0).tag($0) } }
                .pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case "Add": addTab
                    case "Canvas": canvasTab
                    case "Prefs": prefsTab
                    case "Help": helpTab
                    default: shareTab
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380, height: 520)
        .alert("Rename drawing", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { if let d = model.doc { model.renameDoc(id: d.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var addTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bring in a sketch or photo to ink over. It goes on its own layer, so you can lower its opacity or hide it.").font(.footnote).foregroundStyle(.secondary)
            rowButton("Insert a photo", "From your photo library") { model.panel = nil; model.importingPhoto = true }
            rowButton("Open a drawing file", "A .tether.json file, including ones saved from the web version") { model.panel = nil; model.importingBackup = true }
        }
    }

    private var canvasTab: some View {
        let d = model.doc
        var strokes = 0, points = 0
        for L in d?.layers ?? [] { for it in L.items { if case .stroke(let s) = it { strokes += 1; points += s.p.count / 3 } } }
        return VStack(alignment: .leading, spacing: 8) {
            rowButton("Fit canvas to screen", "Centre the whole canvas") { model.panel = nil; model.canvas?.animateFit() }
            rowButton("Flip view horizontally", "Check proportions with fresh eyes") { model.canvas?.flipView() }
            rowButton("Rename drawing", d?.name ?? "") { newName = d?.name ?? ""; renaming = true }
            SectionLabel("Canvas information")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Size").foregroundStyle(.secondary); Text("\(Int(d?.w ?? 0)) × \(Int(d?.h ?? 0)) px") }
                GridRow { Text("Layers").foregroundStyle(.secondary); Text("\(d?.layers.count ?? 0)") }
                GridRow { Text("Strokes").foregroundStyle(.secondary); Text("\(strokes)") }
                GridRow { Text("Points").foregroundStyle(.secondary); Text("\(points)") }
            }
            .font(.subheadline).monospacedDigit()
        }
    }

    private var shareTab: some View {
        let d = model.doc
        let maxS = d.map { Exporter.maxPNGScale($0) } ?? 1
        var scales: [Double] = [1, 2, 4].filter { $0 <= maxS }
        if maxS > 1.1 && maxS < 8 && !scales.contains(where: { abs($0 - maxS) < 0.15 }) { scales.append((maxS * 100).rounded(.down) / 100) }
        return VStack(alignment: .leading, spacing: 8) {
            rowButton("SVG", "Pure vector · opens in Illustrator, Affinity, Inkscape, Figma") { model.panel = nil; model.exportSVG() }
            ForEach(scales, id: \.self) { s in
                let w = Int(((d?.w ?? 0) * s).rounded()), h = Int(((d?.h ?? 0) * s).rounded())
                rowButton("PNG \(String(format: "%g", s))×", "\(w) × \(h) px") { model.panel = nil; model.exportPNG(scale: s) }
            }
            rowButton("Drawing file", "Everything, editable · opens in the web version too") { model.panel = nil; model.exportBackup() }
            Text((d?.bgOn ?? true) ? "Exports include the background colour. Hide it in Layers for a transparent PNG or SVG." : "Background is hidden, so exports are transparent.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var prefsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowButton("Pressure and smoothing", "Pressure curve, global stabilisation and motion filtering, hold-to-snap shapes") { model.panel = nil; model.showGlobal = true }
            SectionLabel("Apple Pencil")
            Picker("Double-tap", selection: model.bind(\.pencilTap)) {
                Text("Swap brush and eraser").tag("swap")
                Text("Follow iPad setting").tag("system")
                Text("Do nothing").tag("off")
            }
            Picker("Squeeze (Pencil Pro)", selection: model.bind(\.pencilSqueeze)) {
                Text("Open colours").tag("colour")
                Text("Open brushes").tag("brushes")
                Text("Swap brush and eraser").tag("swap")
                Text("Do nothing").tag("off")
            }
            SectionLabel("Interface")
            Toggle("Right-hand interface", isOn: model.bind(\.rightHand))
            Toggle("Draw with finger", isOn: model.bind(\.fingerDraw))
            Toggle("Rotate with two fingers", isOn: model.bind(\.rotate))
            Text("With finger drawing off, a single finger only picks colours (touch and hold), so a resting palm can't move the canvas.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    static let help: [[String]] = [["Apple Pencil", "Draws or erases"], ["Pencil double-tap", "Swaps brush and eraser (change in Prefs)"],
        ["Pencil squeeze", "Opens colours on Apple Pencil Pro"], ["Two-finger pinch", "Zoom and rotate"],
        ["Quick pinch in", "Fit canvas to screen"], ["Two-finger tap", "Undo"], ["Three-finger tap", "Redo"],
        ["Four-finger tap", "Hide or show the interface"], ["Touch and hold", "Pick a colour"],
        ["Hold at the end", "Snaps the stroke to a straight line or ellipse"],
        ["Side bar sliders", "Slide sideways while dragging for fine control"],
        ["Brush, again", "Tap the selected brush to edit it"]]

    private var helpTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<ActionsPanel.help.count, id: \.self) { i in
                HStack(alignment: .top) {
                    Text(ActionsPanel.help[i][0]).font(.subheadline.weight(.semibold)).frame(width: 140, alignment: .leading)
                    Text(ActionsPanel.help[i][1]).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

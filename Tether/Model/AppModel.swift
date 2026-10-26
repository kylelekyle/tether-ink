import SwiftUI
import UIKit
import Observation
import UniformTypeIdentifiers

enum Tool { case brush, eraser }

enum Panel: String, Identifiable { case brushes, eraser, layers, colour, actions, smoothing; var id: String { rawValue } }

struct EditorTarget: Identifiable, Equatable { let id: String; var tab: EditorTab }
enum EditorTab: String, CaseIterable, Identifiable {
    case smoothing = "Smoothing", taper = "Taper", pressure = "Pressure", shape = "Shape", about = "About"
    var id: String { rawValue }
}

final class HistoryEntry {
    let label: String
    let undo: () -> Void
    let redo: () -> Void
    init(_ label: String, undo: @escaping () -> Void, redo: @escaping () -> Void) { self.label = label; self.undo = undo; self.redo = redo }
}

final class History {
    private(set) var stack: [HistoryEntry] = []
    private(set) var idx = 0
    var canUndo: Bool { idx > 0 }
    var canRedo: Bool { idx < stack.count }
    var top: HistoryEntry? { idx > 0 ? stack[idx - 1] : nil }
    func push(_ e: HistoryEntry) {
        if idx < stack.count { stack.removeSubrange(idx..<stack.count) }
        stack.append(e)
        if stack.count > 500 { stack.removeFirst() }
        idx = stack.count
    }
    func undo() -> HistoryEntry? { guard idx > 0 else { return nil }; idx -= 1; let e = stack[idx]; e.undo(); return e }
    func redo() -> HistoryEntry? { guard idx < stack.count else { return nil }; let e = stack[idx]; idx += 1; e.redo(); return e }
    func reset() { stack = []; idx = 0 }
}

@Observable
final class AppModel {
    var prefs: Prefs = Prefs.load()
    var doc: Doc? = nil
    var docVersion = 0
    var tool: Tool = .brush
    var panel: Panel? = nil
    var showGallery = false
    var editor: EditorTarget? = nil
    var showGlobal = false
    var showNewCanvas = false
    var importingBackup = false
    var importingPhoto = false
    var toastText: String? = nil
    var status = ""
    var pickOnce = false
    var uiHidden = false
    var canUndo = false
    var canRedo = false
    var gallery: [DocMeta] = []
    var librarySet: String? = nil
    var libraryKind = "vector"          // brush library: "vector" or "pixel"
    var pixelBrushes: [PixelBrush] = []
    var importing: String? = nil      // what's being imported right now (shown while it works)
    var sizeBubble: String? = nil     // "size" | "opacity" while a side bar slider is dragged
    var sizeEntry = false             // the type-a-size box beside the side bar
    var dropPoint: CGPoint? = nil     // where the colour being dragged out of the dock is (screen points)
    var fillOffer = false             // after a colour drop: offer "Continue filling"
    var fillMode = false              // taps fill areas instead of drawing

    @ObservationIgnored let history = History()
    @ObservationIgnored let store = Store()
    @ObservationIgnored weak var canvas: CanvasView?
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var prefsWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored var demo: String? = nil

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demo"), i + 1 < args.count { demo = args[i + 1] }
        gallery = store.list()
        if demo == nil, let last = UserDefaults.standard.string(forKey: "lastDoc"), let d = store.load(id: last) { open(d) }
        else if demo == nil, let first = gallery.first, let d = store.load(id: first.id) { open(d) }
        else { let d = AppModel.makeSampler(); open(d); if demo == nil { markDirty() } }
        if let d = demo { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.runDemo(d) } }
    }

    // MARK: prefs

    func setPref<T>(_ kp: WritableKeyPath<Prefs, T>, _ v: T) {
        prefs[keyPath: kp] = v
        schedulePrefsSave()
    }
    func bind<T>(_ kp: WritableKeyPath<Prefs, T>) -> Binding<T> {
        Binding(get: { self.prefs[keyPath: kp] }, set: { self.setPref(kp, $0) })
    }
    private func schedulePrefsSave() {
        prefsWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.prefs.save() }
        prefsWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    // MARK: brushes

    func brush(_ id: String) -> Brush {
        var b = Brush.builtIn.first { $0.id == id } ?? prefs.customBrushes.first { $0.id == id } ?? Brush.erasers.first { $0.id == id } ?? Brush.builtIn[0]
        if let o = prefs.brushOverrides[id] {
            if let s = o["scatter"] { b["scatter"] = s }   // first, so the scatter settings have something to set
            for (k, v) in o where k != "scatter" { b[k] = v }
        }
        return b
    }
    func baseBrush(_ id: String) -> Brush? { Brush.builtIn.first { $0.id == id } ?? Brush.erasers.first { $0.id == id } }
    func isCustom(_ id: String) -> Bool { prefs.customBrushes.contains { $0.id == id } }
    func brushes(inSet set: String) -> [Brush] {
        if set == "mine" || set.hasPrefix("imp:") { return prefs.customBrushes.filter { $0.set == set }.map { brush($0.id) } }
        return Brush.builtIn.filter { $0.set == set }.map { brush($0.id) }
    }
    /// The vector library's sets: built in, then each imported set, then the brushes you made.
    var vectorSets: [(id: String, name: String)] {
        var out = Brush.sets.filter { $0.id != "mine" }
        var seen = Set<String>()
        for b in prefs.customBrushes where b.set.hasPrefix("imp:") && !seen.contains(b.set) {
            seen.insert(b.set)
            out.append((b.set, String(b.set.dropFirst(4))))
        }
        out.append(("mine", "My brushes"))
        return out
    }
    func refreshPixelBrushes() {
        let list = PixelBrushStore.list()
        if list != pixelBrushes { pixelBrushes = list }
    }

    // MARK: importing

    /// Any file handed to the app: drawings, Procreate artwork, Procreate or Photoshop brushes.
    func importFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if url.lastPathComponent.lowercased().hasSuffix(".tether.json") || ext == "json" { importBackup(url); return }
        guard ["procreate", "brushset", "brush", "abr"].contains(ext) else { toast("Tether Ink can't open .\(ext) files"); return }
        let ok = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)
        if ok { url.stopAccessingSecurityScopedResource() }
        guard let data = data else { toast("Couldn't read that file"); return }
        let name = url.lastPathComponent
        importing = ext == "procreate" ? "Tracing \(name)…" : "Importing \(name)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if ext == "procreate" {
                let doc = ProcreateImport.document(data, fileName: name)
                DispatchQueue.main.async { self?.finishImport(doc) }
            } else {
                let r = ext == "abr" ? BrushImport.abr(data, fileName: name) : BrushImport.procreate(data, fileName: name)
                if let r = r { for (b, files) in r.pixel { PixelBrushStore.save(b, files: files) } }
                DispatchQueue.main.async { self?.finishImport(r) }
            }
        }
    }
    private func finishImport(_ doc: Doc?) {
        importing = nil
        guard let d = doc else { toast("That .procreate file couldn't be read"); return }
        saveNow()
        open(d); saveNow(); refreshGallery(); showGallery = false
        toast("Imported \(d.name) · \(d.layers.count) layers traced to vector")
    }
    private func finishImport(_ r: BrushImport.Result?) {
        importing = nil
        guard let r = r else { toast("No brushes found in that file"); return }
        prefs.customBrushes.append(contentsOf: r.vector)
        prefs.stampShapes.append(contentsOf: r.shapes)
        schedulePrefsSave()
        refreshPixelBrushes()
        libraryKind = "vector"
        librarySet = "imp:" + r.setName
        toast("Imported \(r.vector.count) brushes into \(r.setName): vector copies, originals in Pixel brushes")
    }
    var currentBrushId: String { tool == .eraser ? prefs.eraserId : prefs.brushId }
    var currentBrush: Brush { brush(currentBrushId) }

    func setBrushValue(_ id: String, _ key: String, _ v: Double) {
        var o = prefs.brushOverrides[id] ?? [:]
        o[key] = v
        prefs.brushOverrides[id] = o
        schedulePrefsSave()
    }
    var currentSize: Double {
        get { currentBrush.size }
        set { setBrushValue(currentBrushId, "size", (newValue * 100).rounded() / 100) }
    }
    var currentOpacity: Double {
        get { tool == .eraser ? prefs.opacityEraser : prefs.opacityBrush }
        set { if tool == .eraser { setPref(\.opacityEraser, max(0.02, newValue)) } else { setPref(\.opacityBrush, max(0.02, newValue)) } }
    }

    /// Saves an edited copy of a brush: built-in brushes keep only the differences, custom brushes are rewritten.
    func commitBrush(_ b: Brush) {
        if let i = prefs.customBrushes.firstIndex(where: { $0.id == b.id }) {
            prefs.customBrushes[i] = b
            prefs.brushOverrides[b.id] = nil
        } else if let base = baseBrush(b.id) {
            var o: [String: Double] = [:]
            for k in Brush.keys + Brush.stampKeys where abs(b[k] - base[k]) > 1e-9 { o[k] = b[k] }
            prefs.brushOverrides[b.id] = o.isEmpty ? nil : o
        }
        schedulePrefsSave()
    }
    func resetBrush(_ id: String) { prefs.brushOverrides[id] = nil; schedulePrefsSave() }
    @discardableResult func duplicateBrush(_ id: String) -> String {
        var b = brush(id)
        b.id = "u" + newID()
        b.set = "mine"
        b.mode = nil
        b.note = nil
        b.name = b.name.hasSuffix(" copy") ? b.name : b.name + " copy"
        prefs.customBrushes.append(b)
        prefs.brushId = b.id
        tool = .brush
        schedulePrefsSave()
        return b.id
    }
    func deleteBrush(_ id: String) {
        prefs.customBrushes.removeAll { $0.id == id }
        prefs.brushOverrides[id] = nil
        if prefs.brushId == id { prefs.brushId = "studio" }
        schedulePrefsSave()
    }

    func smoothing(for b: Brush) -> SmoothParams {
        func comb(_ a: Double, _ c: Double) -> Double { 1 - (1 - a) * (1 - c) }
        var s = SmoothParams()
        s.mf = comb(b.motion, prefs.gMotion)
        s.mfx = b.motion >= prefs.gMotion ? b.motionExpr : prefs.gMotionExpr
        s.st = comb(b.stab, prefs.gStab)
        s.sts = b.stabSpeed
        s.sl = b.streamline
        s.slp = b.slPressure
        s.catchUp = prefs.catchUp
        return s
    }
    func pressure(_ raw: Double) -> Double { PressureCurve.eval(prefs.curve, raw) }

    // MARK: tools and colour

    func setTool(_ t: Tool) {
        tool = t
        endFilling()
        canvas?.refreshOverlay()
    }
    func endFilling() {
        if fillMode { fillMode = false }
        if fillOffer { fillOffer = false }
    }
    func toggleTool() {
        setTool(tool == .eraser ? .brush : .eraser)
        toast(tool == .eraser ? "Eraser" : "Brush")
    }
    func setColor(_ hex: String, remember: Bool = false) {
        setPref(\.color, hex.lowercased())
        if remember { rememberColor(hex) }
    }
    func rememberColor(_ hex: String) {
        if prefs.colorHistory.first == hex.lowercased() { return }
        var h = prefs.colorHistory.filter { $0 != hex.lowercased() }
        h.insert(hex.lowercased(), at: 0)
        setPref(\.colorHistory, Array(h.prefix(18)))
    }

    // MARK: Apple Pencil buttons

    func pencilTap() {
        switch prefs.pencilTap {
        case "off": return
        case "system":
            switch UIPencilInteraction.preferredTapAction {
            case .ignore: return
            case .showColorPalette: panel = panel == .colour ? nil : .colour
            default: toggleTool()
            }
        default: toggleTool()
        }
    }
    func pencilSqueeze() {
        switch prefs.pencilSqueeze {
        case "off": return
        case "swap": toggleTool()
        case "brushes": panel = panel == .brushes ? nil : .brushes
        default: panel = panel == .colour ? nil : .colour
        }
    }

    // MARK: toast and status

    func toast(_ s: String) {
        toastText = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toastText = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: w)
    }

    // MARK: history

    func push(_ e: HistoryEntry) { canvas?.endShapeEdit(); history.push(e); refreshUndo() }
    func refreshUndo() {
        if canUndo != history.canUndo { canUndo = history.canUndo }
        if canRedo != history.canRedo { canRedo = history.canRedo }
    }
    func undo() { canvas?.endShapeEdit(); if let e = history.undo() { docChanged(); toast("Undo · \(e.label)") }; refreshUndo() }
    func redo() { canvas?.endShapeEdit(); if let e = history.redo() { docChanged(); toast("Redo · \(e.label)") }; refreshUndo() }

    // MARK: documents

    func open(_ d: Doc) {
        doc = d
        history.reset(); refreshUndo()
        UserDefaults.standard.set(d.id, forKey: "lastDoc")
        docVersion += 1
        status = "Saved"
        canvas?.docOpened()
    }

    /// Something in the drawing changed: redraw, refresh panels, save soon.
    func docChanged(activeOnly: Bool = false) {
        docVersion += 1
        canvas?.contentChanged(activeOnly: activeOnly)
        markDirty()
    }

    func markDirty() {
        guard let d = doc else { return }
        d.updated = nowMs()
        if status != "Edited" { status = "Edited" }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
    }

    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        guard let d = doc else { return }
        store.save(d)
        if status != "Saved" { status = "Saved" }
        prefs.save()
    }

    func refreshGallery() { store.waitForWrites(); gallery = store.list() }

    func openDoc(id: String) {
        saveNow()
        store.waitForWrites()
        guard let d = store.load(id: id) else { toast("Couldn't open that drawing"); return }
        open(d)
        showGallery = false
    }

    func newDoc(w: Double, h: Double) {
        saveNow()
        let d = Doc(w: clampD(w, 64, 16000), h: clampD(h, 64, 16000), name: "Sketch \(gallery.count + 1)")
        open(d)
        saveNow()
        refreshGallery()
        showGallery = false
    }

    func duplicateDoc(id: String) {
        saveNow(); store.waitForWrites()
        guard let d = store.load(id: id) else { return }
        d.id = newID(); d.name += " copy"; d.created = nowMs(); d.updated = nowMs()
        store.save(d)
        refreshGallery()
    }

    func deleteDoc(id: String) {
        store.delete(id: id)
        store.waitForWrites()
        gallery = store.list()
        if doc?.id == id {
            if let first = gallery.first, let d = store.load(id: first.id) { open(d) }
            else { let d = Doc(w: 2048, h: 1536, name: "Sketch 1"); open(d); saveNow(); refreshGallery() }
        }
    }

    func renameDoc(id: String, to name: String) {
        let n = String(name.trimmingCharacters(in: .whitespaces).prefix(80))
        guard !n.isEmpty else { return }
        if doc?.id == id { doc?.name = n; docVersion += 1; saveNow() }
        else if let d = store.load(id: id) { d.name = n; d.updated = nowMs(); store.save(d) }
        refreshGallery()
    }

    func importBackup(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let d = try? JSONDecoder().decode(Doc.self, from: data) else { toast("That file isn't a Tether Ink drawing"); return }
        saveNow()
        d.id = newID(); d.updated = nowMs()
        open(d); saveNow(); refreshGallery(); showGallery = false
        toast("Opened \(d.name)")
    }

    func insertPhoto(_ image: UIImage) {
        guard let d = doc else { return }
        let maxSide: CGFloat = 2560
        let k = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpg = scaled.jpegData(compressionQuality: 0.9) else { return }
        let src = "data:image/jpeg;base64," + jpg.base64EncodedString()
        let fit = min(d.w / Double(size.width), d.h / Double(size.height))
        let w = Double(size.width) * fit, h = Double(size.height) * fit
        let item = ImageItem(id: newID(), src: src, x: (d.w - w) / 2, y: (d.h - h) / 2, w: w, h: h, o: 1)
        let L = Layer(name: "Photo"); L.items = [.image(item)]; L.opacity = 0.6
        let i = max(0, d.activeIndex), prev = d.active
        d.layers.insert(L, at: i)
        push(HistoryEntry("Insert photo", undo: { d.layers.removeAll { $0 === L }; d.active = prev }, redo: { d.layers.insert(L, at: min(i, d.layers.count)) }))
        docChanged()
        toast("Photo added under your layer at 60% opacity")
    }

    // MARK: fill

    /// Drop the current colour into the area around p (canvas units). The fill goes to the bottom of the current
    /// layer, under its lines. Dropping onto an existing fill on this layer recolours it.
    func fill(at p: V2) {
        guard let d = doc, p.x >= 0, p.y >= 0, p.x <= d.w, p.y <= d.h else { return }
        guard let L = d.activeLayer else { toast("No layers. Tap + in Layers to add one."); return }
        if L.locked { toast("This layer is locked"); return }
        if !L.visible { toast("This layer is hidden"); return }
        let colour = prefs.color
        let opacity = r3(prefs.opacityBrush)
        canvas?.endShapeEdit()
        let pt = CGPoint(x: p.x, y: p.y)
        let hit = L.items.lastIndex { item in
            if case .fill(let f) = item { return GeometryCache.shared.get(f).path.contains(pt, using: .evenOdd) }
            return false
        }
        if let i = hit, case .fill(let old) = L.items[i] {
            var nf = old
            nf.c = colour; nf.o = opacity
            if nf != old {
                L.items[i] = .fill(nf)
                push(HistoryEntry("Fill colour", undo: { if let j = L.items.firstIndex(where: { $0.id == old.id }) { L.items[j] = .fill(old) } },
                                  redo: { if let j = L.items.firstIndex(where: { $0.id == old.id }) { L.items[j] = .fill(nf) } }))
                docChanged(activeOnly: true)
                rememberColor(colour)
            }
            if !fillOffer && !fillMode { fillOffer = true }
            return
        }
        let layers = d.layers.filter { $0.visible }.map { $0.items }
        let w = d.w, h = d.h
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let polys = FloodFill.region(layers, w: w, h: h, seed: p)
            DispatchQueue.main.async {
                guard let self = self, self.doc === d else { return }
                guard let polys = polys else { self.toast("Drop the colour inside an area, not on a line"); return }
                let item = Item.fill(FillItem(id: newID(), c: colour, o: opacity, p: polys))
                L.items.insert(item, at: 0)
                self.push(HistoryEntry("Fill", undo: { L.items.removeAll { $0.id == item.id } }, redo: { L.items.insert(item, at: 0) }))
                self.docChanged(activeOnly: true)
                self.rememberColor(colour)
                if !self.fillOffer && !self.fillMode { self.fillOffer = true }
            }
        }
    }

    // MARK: layers

    func selectLayer(_ id: String) { guard let d = doc, d.active != id else { return }; d.active = id; docVersion += 1; canvas?.contentChanged(activeOnly: false); markDirty() }

    func addLayer() {
        guard let d = doc else { return }
        let L = Layer(name: "Layer \(d.layers.count + 1)"), i = d.activeIndex, prev = d.active
        d.layers.insert(L, at: i + 1); d.active = L.id
        push(HistoryEntry("New layer", undo: { d.layers.removeAll { $0 === L }; d.active = prev }, redo: { d.layers.insert(L, at: min(i + 1, d.layers.count)); d.active = L.id }))
        docChanged()
    }
    /// Copies a layer once, just above it (the copy starts unlocked).
    func duplicateLayer(_ src: Layer) {
        guard let d = doc, let i = d.layers.firstIndex(where: { $0 === src }) else { return }
        let L = Layer(copy: src, name: src.name + " copy"), prev = d.active
        d.layers.insert(L, at: i + 1); d.active = L.id
        push(HistoryEntry("Duplicate layer", undo: { d.layers.removeAll { $0 === L }; d.active = prev }, redo: { d.layers.insert(L, at: min(i + 1, d.layers.count)); d.active = L.id }))
        docChanged()
    }
    func clearLayer() {
        guard let d = doc, let L = d.activeLayer else { return }
        if L.locked { toast("This layer is locked"); return }
        let old = L.items
        if old.isEmpty { return }
        L.items = []
        push(HistoryEntry("Clear layer", undo: { L.items = old }, redo: { L.items = [] }))
        docChanged()
    }
    /// Any layer can go, even the last one: the canvas and background stay.
    func deleteLayer(_ L: Layer) {
        guard let d = doc, let i = d.layers.firstIndex(where: { $0 === L }) else { return }
        let prev = d.active
        d.layers.remove(at: i)
        if prev == L.id { d.active = d.layers.isEmpty ? "" : d.layers[max(0, i - 1)].id }
        let na = d.active
        push(HistoryEntry("Delete layer", undo: { d.layers.insert(L, at: min(i, d.layers.count)); d.active = prev }, redo: { d.layers.removeAll { $0 === L }; d.active = na }))
        docChanged()
    }
    /// One step up (towards the top of the stack) or down.
    func moveLayer(_ L: Layer, up: Bool) {
        guard let d = doc, let i = d.layers.firstIndex(where: { $0 === L }) else { return }
        let j = up ? i + 1 : i - 1
        guard j >= 0 && j < d.layers.count else { return }
        let sw = { d.layers.swapAt(i, j) }
        sw()
        push(HistoryEntry("Move layer", undo: sw, redo: sw))
        docChanged()
    }
    /// A new stacking order from dragging a layer in the panel (bottom layer first).
    func reorderLayers(_ order: [Layer]) {
        guard let d = doc, order.count == d.layers.count, !zip(order, d.layers).allSatisfy({ $0 === $1 }) else { return }
        let old = d.layers
        d.layers = order
        push(HistoryEntry("Move layer", undo: { d.layers = old }, redo: { d.layers = order }))
        docChanged()
    }
    func toggleLock(_ L: Layer) {
        let was = L.locked
        L.locked.toggle()
        push(HistoryEntry(was ? "Unlock layer" : "Lock layer", undo: { L.locked = was }, redo: { L.locked = !was }))
        docVersion += 1; markDirty()
    }
    func renameLayer(_ L: Layer, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != L.name else { return }
        let was = L.name; L.name = n
        push(HistoryEntry("Rename layer", undo: { L.name = was }, redo: { L.name = n }))
        docVersion += 1; markDirty()
    }
    func toggleVisible(_ L: Layer) {
        let was = L.visible; L.visible.toggle()
        push(HistoryEntry(was ? "Hide layer" : "Show layer", undo: { L.visible = was }, redo: { L.visible = !was }))
        docChanged()
    }
    func setLayerOpacity(_ L: Layer, _ v: Double, commitFrom start: Double?) {
        L.opacity = v
        canvas?.contentChanged(activeOnly: false)
        if let a = start, a != v {
            push(HistoryEntry("Layer opacity", undo: { L.opacity = a }, redo: { L.opacity = v }))
            docChanged()
        } else { docVersion += 1 }
    }
    func setBackground(_ hex: String?, on: Bool? = nil) {
        guard let d = doc else { return }
        let was = (d.bg, d.bgOn)
        if let h = hex { d.bg = h; d.bgOn = true }
        if let o = on { d.bgOn = o }
        let now = (d.bg, d.bgOn)
        push(HistoryEntry("Background", undo: { d.bg = was.0; d.bgOn = was.1 }, redo: { d.bg = now.0; d.bgOn = now.1 }))
        docChanged()
    }

    // MARK: export

    func exportSVG() {
        guard let d = doc, let url = Exporter.tempFile(Exporter.fileBase(d) + ".svg", Data(Exporter.svg(d).utf8)) else { return }
        Share.present([url])
    }
    func exportPNG(scale: Double) {
        guard let d = doc else { return }
        toast("Rendering PNG…")
        DispatchQueue.main.async {
            guard let data = Exporter.png(d, scale: scale),
                  let url = Exporter.tempFile(Exporter.fileBase(d) + (scale == 1 ? "" : "@\(String(format: "%g", scale))x") + ".png", data) else { self.toast("That size is too large to render"); return }
            Share.present([url])
        }
    }
    func exportBackup() {
        guard let d = doc, let data = Exporter.backup(d), let url = Exporter.tempFile(Exporter.fileBase(d) + ".tether.json", data) else { return }
        Share.present([url])
    }

    // MARK: first run sample

    static func makeSampler() -> Doc {
        let d = Doc(w: 1800, h: 1200, name: "Brush sampler")
        let ink = d.layers[0]; ink.name = "Line"
        let col = Layer(name: "Colour")
        d.layers.insert(col, at: 0); d.active = ink.id
        let rows = Brush.builtIn.filter { $0.id != "round" }
        let top = 140.0, gap = (d.h - 250) / Double(rows.count - 1)
        for (ri, b) in rows.enumerated() {
            for (ci, m) in [0.4, 0.7, 1.0, 1.6, 2.4].enumerated() {
                let x0 = 150 + Double(ci) * 315, y0 = top + Double(ri) * gap
                var p: [Double] = []
                for i in 0...70 {
                    let t = Double(i) / 70
                    let x: Double = x0 + t * 250
                    let y: Double = y0 + sin(t * Double.pi * 2) * 30
                    let pr: Double = 0.12 + 0.88 * pow(sin(Double.pi * t), 0.7)
                    p.append(r2(x)); p.append(r2(y)); p.append(r3(pr))
                }
                var shape = b.shape; shape.size = r2(b.size * m)
                let baked: [Double] = StrokeGeometry.bake(p, shape).enumerated().map { $0.offset % 3 == 2 ? r3($0.element) : r2($0.element) }
                let s = StrokeItem(id: newID(), m: "d", c: b.id == "marker" ? "#a9c2f5" : "#111111", o: 1, b: shape, p: baked)
                (b.id == "marker" ? col : ink).items.append(.stroke(s))
            }
        }
        return d
    }

    // MARK: screenshots for automated checks

    private func runDemo(_ d: String) {
        switch d {
        case "library": panel = .brushes
        case "layers": doc?.layers.first?.locked = true; panel = .layers
        case "smoothing": panel = .smoothing
        case "actions": panel = .actions
        case "colour": UserDefaults.standard.set("disc", forKey: "colourTab"); panel = .colour
        case "colourclassic": UserDefaults.standard.set("classic", forKey: "colourTab"); panel = .colour
        case "shape": canvas?.demoShape()
        case "editor": editor = EditorTarget(id: "studio", tab: .smoothing)
        case "global": showGlobal = true
        case "gallery": refreshGallery(); showGallery = true
        case "draw": canvas?.demoStrokes()
        case "scatter": prefs.brushId = "stipple"; canvas?.demoStrokes()
        case "fast": canvas?.demoFast()
        case "midstroke": canvas?.demoMidstroke()
        case "arch": canvas?.demoArch()
        case "fill": canvas?.demoFill()
        case "size": sizeEntry = true
        case "nolayers": doc?.layers = []; doc?.active = ""; docVersion += 1; canvas?.contentChanged(activeOnly: false); panel = .layers
        default: break
        }
    }
}

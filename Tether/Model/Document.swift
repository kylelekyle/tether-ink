import Foundation

// The document format matches the web version's backup files (.tether.json), so drawings move freely between them.

struct BrushShape: Codable, Equatable {
    var size: Double
    var thin: Double = 0
    var ts: Double = 0
    var te: Double = 0
    var sm: Double = 0.5
    var sl: Double = 0
    var g: Double = 1
    var sim: Bool = false

    init(size: Double, thin: Double, ts: Double, te: Double, sm: Double, sl: Double, g: Double, sim: Bool) {
        self.size = size; self.thin = thin; self.ts = ts; self.te = te; self.sm = sm; self.sl = sl; self.g = g; self.sim = sim
    }

    enum CodingKeys: String, CodingKey { case size, thin, ts, te, sm, sl, g, sim }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 3
        thin = try c.decodeIfPresent(Double.self, forKey: .thin) ?? 0
        ts = try c.decodeIfPresent(Double.self, forKey: .ts) ?? 0
        te = try c.decodeIfPresent(Double.self, forKey: .te) ?? 0
        sm = try c.decodeIfPresent(Double.self, forKey: .sm) ?? 0.5
        sl = try c.decodeIfPresent(Double.self, forKey: .sl) ?? 0.2
        g = try c.decodeIfPresent(Double.self, forKey: .g) ?? 1
        if let n = try? c.decodeIfPresent(Double.self, forKey: .sim) { sim = n != 0 }
        else if let b = try? c.decodeIfPresent(Bool.self, forKey: .sim) { sim = b }
        else { sim = false }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(size, forKey: .size); try c.encode(thin, forKey: .thin); try c.encode(ts, forKey: .ts); try c.encode(te, forKey: .te)
        try c.encode(sm, forKey: .sm); try c.encode(sl, forKey: .sl); try c.encode(g, forKey: .g); try c.encode(sim ? 1 : 0, forKey: .sim)
    }
}

struct StrokeItem: Codable, Equatable {
    var id: String
    var m: String          // "d" draw, "e" erase
    var c: String          // hex colour
    var o: Double          // opacity
    var b: BrushShape
    var p: [Double]        // x, y, pressure triples in canvas units
    var isErase: Bool { m == "e" }
}

struct ImageItem: Codable, Equatable {
    var id: String
    var src: String        // data URL
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var o: Double?
    var opacity: Double { o ?? 1 }
}

enum Item: Codable, Equatable {
    case stroke(StrokeItem)
    case image(ImageItem)

    var id: String {
        switch self { case .stroke(let s): return s.id; case .image(let i): return i.id }
    }
    var isErase: Bool { if case .stroke(let s) = self { return s.isErase }; return false }

    private enum K: String, CodingKey { case t }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        let t = try c.decodeIfPresent(String.self, forKey: .t) ?? "s"
        if t == "i" { self = .image(try ImageItem(from: d)) } else { self = .stroke(try StrokeItem(from: d)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case .stroke(let s): try c.encode("s", forKey: .t); try s.encode(to: e)
        case .image(let i): try c.encode("i", forKey: .t); try i.encode(to: e)
        }
    }
}

final class Layer: Codable, Identifiable {
    var id: String
    var name: String
    var visible: Bool
    var opacity: Double
    var items: [Item]
    var locked = false   // locked layers can't be drawn on, erased or cleared

    init(name: String) { id = newID(); self.name = name; visible = true; opacity = 1; items = [] }
    init(copy l: Layer, name: String) { id = newID(); self.name = name; visible = l.visible; opacity = l.opacity; items = l.items }

    enum CodingKeys: String, CodingKey { case id, name, visible, opacity, items, locked }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? newID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Layer"
        visible = (try? c.decode(Bool.self, forKey: .visible)) ?? true
        opacity = clampD((try? c.decode(Double.self, forKey: .opacity)) ?? 1, 0, 1)
        // skip any item that fails to decode rather than losing the whole drawing
        var list: [Item] = []
        if var arr = try? c.nestedUnkeyedContainer(forKey: .items) {
            while !arr.isAtEnd {
                if let it = try? arr.decode(Item.self) { list.append(it) } else { _ = try? arr.decode(Skip.self) }
            }
        }
        items = list
        locked = (try? c.decode(Bool.self, forKey: .locked)) ?? false
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(visible, forKey: .visible)
        try c.encode(opacity, forKey: .opacity); try c.encode(items, forKey: .items)
        if locked { try c.encode(true, forKey: .locked) }   // only written when set, so files stay as they were
    }
    var hasErase: Bool { items.contains { $0.isErase } }
}

private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

final class Doc: Codable, Identifiable {
    var v = 1
    var id: String
    var name: String
    var w: Double
    var h: Double
    var bg: String
    var bgOn: Bool
    var created: Double
    var updated: Double
    var active: String
    var layers: [Layer]
    var kind = "drawing"

    init(w: Double, h: Double, name: String) {
        let l = Layer(name: "Layer 1")
        id = newID(); self.name = name; self.w = w.rounded(); self.h = h.rounded()
        bg = "#ffffff"; bgOn = true; created = nowMs(); updated = nowMs(); active = l.id; layers = [l]
    }

    enum CodingKeys: String, CodingKey { case v, id, name, w, h, bg, bgOn, created, updated, active, layers, kind }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = ((try? c.decode(String.self, forKey: .id)) ?? newID()).filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        if id.isEmpty { id = newID() }
        name = String(((try? c.decode(String.self, forKey: .name)) ?? "Untitled").prefix(80))
        w = clampD(((try? c.decode(Double.self, forKey: .w)) ?? 2048).rounded(), 16, 20000)
        h = clampD(((try? c.decode(Double.self, forKey: .h)) ?? 1536).rounded(), 16, 20000)
        bg = (try? c.decode(String.self, forKey: .bg)) ?? "#ffffff"
        if !isHexColor(bg) { bg = "#ffffff" }
        bgOn = (try? c.decode(Bool.self, forKey: .bgOn)) ?? true
        created = (try? c.decode(Double.self, forKey: .created)) ?? nowMs()
        updated = (try? c.decode(Double.self, forKey: .updated)) ?? nowMs()
        layers = (try? c.decode([Layer].self, forKey: .layers)) ?? []   // a drawing may have no layers at all
        active = (try? c.decode(String.self, forKey: .active)) ?? ""
        if !layers.contains(where: { $0.id == active }) { active = layers.last?.id ?? "" }
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(w, forKey: .w); try c.encode(h, forKey: .h); try c.encode(bg, forKey: .bg); try c.encode(bgOn, forKey: .bgOn)
        try c.encode(created, forKey: .created); try c.encode(updated, forKey: .updated); try c.encode(active, forKey: .active)
        try c.encode(layers, forKey: .layers); try c.encode(kind, forKey: .kind)
    }

    /// nil only when the drawing has no layers.
    var activeLayer: Layer? { layers.first { $0.id == active } ?? layers.last }
    /// -1 when the drawing has no layers.
    var activeIndex: Int { layers.firstIndex { $0.id == active } ?? (layers.count - 1) }
}

struct DocMeta: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var w: Double
    var h: Double
    var created: Double
    var updated: Double
}

func newID() -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<12).map { _ in chars[Int.random(in: 0..<chars.count)] })
}
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
func isHexColor(_ s: String) -> Bool {
    let t = s.hasPrefix("#") ? String(s.dropFirst()) : s
    return (t.count == 6 || t.count == 3) && t.allSatisfy { $0.isHexDigit }
}
func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

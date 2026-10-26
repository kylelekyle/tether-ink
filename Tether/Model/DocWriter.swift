import Foundation
import CoreGraphics

/// Fast JSON writer for drawings (the same format as `Doc`'s Codable output).
/// Saving works from a snapshot, so it runs off the main thread while you keep drawing.
enum DocWriter {
    struct LayerShot {
        let id: String, name: String, visible: Bool, opacity: Double, items: [Item], locked: Bool
        var tiles: [Int: CGImage]? = nil
    }
    struct Snapshot {
        let v: Int, id: String, name: String, w: Double, h: Double, bg: String, bgOn: Bool
        let created: Double, updated: Double, active: String, kind: String
        let stamps: [StampShape]
        let layers: [LayerShot]
        init(_ d: Doc) {
            v = d.v; id = d.id; name = d.name; w = d.w; h = d.h; bg = d.bg; bgOn = d.bgOn
            created = d.created; updated = d.updated; active = d.active; kind = d.kind; stamps = d.stamps
            layers = d.layers.map { LayerShot(id: $0.id, name: $0.name, visible: $0.visible, opacity: $0.opacity, items: $0.items, locked: $0.locked, tiles: $0.tiles) }
        }
        var renderLayers: [LayerSnap] { layers.map { LayerSnap(items: $0.items, visible: $0.visible, opacity: $0.opacity, tiles: $0.tiles) } }
    }

    static func json(_ d: Snapshot) -> Data {
        var w = Writer()
        var n = 4096
        for l in d.layers {
            for it in l.items {
                switch it {
                case .stroke(let s): n += 160 + s.p.count * 7
                case .image(let i): n += 200 + i.src.utf8.count
                case .fill(let f): n += 80 + f.p.reduce(0) { $0 + $1.count * 7 + 2 }
                }
            }
        }
        w.o.reserveCapacity(n)
        w.raw("{")
        w.key("v"); w.num(Double(d.v)); w.comma()
        w.key("id"); w.str(d.id); w.comma()
        w.key("name"); w.str(d.name); w.comma()
        w.key("w"); w.num(d.w); w.comma()
        w.key("h"); w.num(d.h); w.comma()
        w.key("bg"); w.str(d.bg); w.comma()
        w.key("bgOn"); w.bool(d.bgOn); w.comma()
        w.key("created"); w.num(d.created); w.comma()
        w.key("updated"); w.num(d.updated); w.comma()
        w.key("active"); w.str(d.active); w.comma()
        w.key("layers"); w.raw("[")
        for (li, l) in d.layers.enumerated() {
            if li > 0 { w.comma() }
            w.raw("{")
            w.key("id"); w.str(l.id); w.comma()
            w.key("name"); w.str(l.name); w.comma()
            w.key("visible"); w.bool(l.visible); w.comma()
            w.key("opacity"); w.num(l.opacity); w.comma()
            if l.locked { w.key("locked"); w.bool(true); w.comma() }
            if let t = l.tiles {
                w.key("px"); w.raw("{")
                var first = true
                for (k, img) in t.sorted(by: { $0.key < $1.key }) {
                    guard let png = Tiles.png(img) else { continue }
                    if !first { w.comma() }
                    first = false
                    w.str(Tiles.name(k)); w.o.append(58)
                    w.o.append(34); w.o.append(contentsOf: png.base64EncodedData()); w.o.append(34)
                }
                w.raw("}"); w.comma()
            }
            w.key("items"); w.raw("[")
            for (ii, it) in l.items.enumerated() {
                if ii > 0 { w.comma() }
                switch it {
                case .stroke(let s):
                    w.raw("{")
                    w.key("t"); w.str("s"); w.comma()
                    w.key("id"); w.str(s.id); w.comma()
                    w.key("m"); w.str(s.m); w.comma()
                    w.key("c"); w.str(s.c); w.comma()
                    w.key("o"); w.num(s.o); w.comma()
                    w.key("b"); w.raw("{")
                    w.key("size"); w.num(s.b.size); w.comma()
                    w.key("thin"); w.num(s.b.thin); w.comma()
                    w.key("ts"); w.num(s.b.ts); w.comma()
                    w.key("te"); w.num(s.b.te); w.comma()
                    w.key("sm"); w.num(s.b.sm); w.comma()
                    w.key("sl"); w.num(s.b.sl); w.comma()
                    w.key("g"); w.num(s.b.g); w.comma()
                    w.key("sim"); w.num(s.b.sim ? 1 : 0)
                    if let k = s.b.k, let j = try? JSONEncoder().encode(k) { w.comma(); w.key("k"); w.o.append(contentsOf: j) }
                    w.raw("}"); w.comma()
                    w.key("r"); w.raw("[")
                    for (k, v) in s.p.enumerated() { if k > 0 { w.comma() }; w.num(v) }
                    w.raw("]}")
                case .image(let im):
                    w.raw("{")
                    w.key("t"); w.str("i"); w.comma()
                    w.key("id"); w.str(im.id); w.comma()
                    w.key("src"); w.str(im.src); w.comma()
                    w.key("x"); w.num(im.x); w.comma()
                    w.key("y"); w.num(im.y); w.comma()
                    w.key("w"); w.num(im.w); w.comma()
                    w.key("h"); w.num(im.h)
                    if let o = im.o { w.comma(); w.key("o"); w.num(o) }
                    w.raw("}")
                case .fill(let f):
                    w.raw("{")
                    w.key("t"); w.str("f"); w.comma()
                    w.key("id"); w.str(f.id); w.comma()
                    w.key("c"); w.str(f.c); w.comma()
                    w.key("o"); w.num(f.o); w.comma()
                    w.key("p"); w.raw("[")
                    for (pi, poly) in f.p.enumerated() {
                        if pi > 0 { w.comma() }
                        w.raw("[")
                        for (k, v) in poly.enumerated() { if k > 0 { w.comma() }; w.num(v) }
                        w.raw("]")
                    }
                    w.raw("]}")
                }
            }
            w.raw("]}")
        }
        w.raw("]"); w.comma()
        w.key("kind"); w.str(d.kind)
        if !d.stamps.isEmpty, let j = try? JSONEncoder().encode(d.stamps) { w.comma(); w.key("stamps"); w.o.append(contentsOf: j) }
        w.raw("}")
        return Data(w.o)
    }

    struct Writer {
        var o: [UInt8] = []
        @inline(__always) mutating func raw(_ s: StaticString) {
            s.withUTF8Buffer { o.append(contentsOf: $0) }
        }
        @inline(__always) mutating func comma() { o.append(44) }
        mutating func key(_ k: StaticString) { o.append(34); raw(k); o.append(34); o.append(58) }
        mutating func bool(_ b: Bool) { if b { raw("true") } else { raw("false") } }
        mutating func str(_ s: String) {
            o.append(34)
            for b in s.utf8 {
                switch b {
                case 34: o.append(92); o.append(34)
                case 92: o.append(92); o.append(92)
                case 10: o.append(92); o.append(110)
                case 13: o.append(92); o.append(114)
                case 9: o.append(92); o.append(116)
                case 0..<32:
                    let hex: [UInt8] = Array("0123456789abcdef".utf8)
                    o.append(contentsOf: [92, 117, 48, 48, hex[Int(b >> 4)], hex[Int(b & 15)]])
                default: o.append(b)
                }
            }
            o.append(34)
        }
        mutating func int(_ v: Int64) {
            var n = v
            if n == 0 { o.append(48); return }
            let start = o.count
            while n > 0 { o.append(48 + UInt8(n % 10)); n /= 10 }
            o[start..<o.count].reverse()
        }
        /// Up to three decimals, trailing zeros dropped (everything in a drawing is stored at that precision).
        mutating func num(_ v: Double) {
            guard v.isFinite else { o.append(48); return }
            let scaled = (v * 1000).rounded()
            if abs(scaled) >= 9e15 { o.append(contentsOf: Array(String(v).utf8)); return }
            var k = Int64(scaled)
            if k < 0 { o.append(45); k = -k }
            int(k / 1000)
            let f = k % 1000
            if f != 0 {
                o.append(46)
                o.append(48 + UInt8(f / 100))
                let d2 = (f / 10) % 10, d3 = f % 10
                if d2 != 0 || d3 != 0 { o.append(48 + UInt8(d2)) }
                if d3 != 0 { o.append(48 + UInt8(d3)) }
            }
        }
    }
}

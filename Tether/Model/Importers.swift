import Foundation
import UIKit
import Compression

// MARK: - Zip (read only)

/// Just enough of the zip format for .procreate, .brushset and .brush files: stored and deflated entries.
struct ZipReader {
    struct Entry { let name: String; let method: UInt16; let csize: Int; let size: Int; let offset: Int }
    let data: Data
    private(set) var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    init?(_ data: Data) {
        self.data = data
        let n = data.count
        guard n >= 22 else { return nil }
        // the end-of-central-directory record sits in the last 64 KB
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65_536)
        while i >= stop { if u32(i) == 0x0605_4b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { return nil }
        let count = Int(u16(eocd + 10))
        var p = Int(u32(eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4b50 else { return nil }
            let method = u16(p + 10)
            let csize = Int(u32(p + 20)), size = Int(u32(p + 24))
            let nl = Int(u16(p + 28)), xl = Int(u16(p + 30)), cl = Int(u16(p + 32))
            let off = Int(u32(p + 42))
            guard p + 46 + nl <= n else { return nil }
            let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nl)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, csize: csize, size: size, offset: off)
            names.append(name)
            p += 46 + nl + xl + cl
        }
    }

    private func u16(_ i: Int) -> UInt16 { UInt16(data[data.startIndex + i]) | UInt16(data[data.startIndex + i + 1]) << 8 }
    private func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }

    func read(_ name: String) -> Data? {
        guard let e = entries[name] else { return nil }
        let h = e.offset
        guard h + 30 <= data.count, u32(h) == 0x0403_4b50 else { return nil }
        let start = h + 30 + Int(u16(h + 26)) + Int(u16(h + 28))
        guard start + e.csize <= data.count else { return nil }
        let raw = data[(data.startIndex + start)..<(data.startIndex + start + e.csize)]
        switch e.method {
        case 0: return Data(raw)
        case 8: return Inflate.decode(Data(raw), size: e.size, algorithm: COMPRESSION_ZLIB)   // raw deflate
        default: return nil
        }
    }
}

enum Inflate {
    /// One-shot decode with Apple's Compression framework (ZLIB = raw deflate, LZ4 = Apple's "bv41" blocks).
    static func decode(_ src: Data, size: Int, algorithm: compression_algorithm) -> Data? {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let sp = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, size, sp, src.count, nil, algorithm)
            }
        }
        return n == size ? out : nil
    }
}

// MARK: - Procreate archives (NSKeyedArchiver)

/// Reads the bits of a Procreate brush we can use; everything else in the archive is skipped.
final class PBrush: NSObject, NSCoding {
    static let keys = ["minSize", "maxSize", "paintSize", "dynamicsPressureSize", "plotSmoothing", "plotMovingAverageStabilization",
                       "plotFFTSmoothingAmount", "pencilTaperStartLength", "pencilTaperEndLength", "taperStartLength", "taperEndLength",
                       "plotSpacing", "plotJitter", "plotJitterLinear", "dynamicsJitterSize", "shapeScatter", "shapeRotation"]
    static let flags = ["oriented", "shapeRandomise", "shapeInverted"]
    var name = "Brush"
    var nums: [String: Double] = [:]
    var bools: [String: Bool] = [:]
    var sizeCurve: [CGPoint] = []

    init(name: String, nums: [String: Double]) { self.name = name; self.nums = nums }
    required init?(coder c: NSCoder) {
        name = (c.decodeObject(forKey: "name") as? String) ?? "Brush"
        for k in PBrush.keys where c.containsValue(forKey: k) { nums[k] = c.decodeDouble(forKey: k) }
        for k in PBrush.flags where c.containsValue(forKey: k) { bools[k] = c.decodeBool(forKey: k) }
        sizeCurve = (c.decodeObject(forKey: "dynamicsPressureSizeCurve") as? PCurve)?.points ?? []
    }
    func encode(with c: NSCoder) {
        c.encode(name, forKey: "name")
        for (k, v) in nums { c.encode(v, forKey: k) }
        for (k, v) in bools { c.encode(v, forKey: k) }
    }
}
final class PCurve: NSObject, NSCoding {
    var points: [CGPoint] = []
    required init?(coder c: NSCoder) {
        points = ((c.decodeObject(forKey: "points") as? [Any]) ?? []).compactMap { ($0 as? String).map { NSCoder.cgPoint(for: $0) } }
    }
    func encode(with coder: NSCoder) {}
}
final class PDoc: NSObject, NSCoding {
    var size = CGSize(width: 2048, height: 2048)
    var tile = 256
    var name: String?
    var background: Data?
    var backgroundHidden = false
    var layers: [PLayer] = []
    required init?(coder c: NSCoder) {
        if let s = c.decodeObject(forKey: "size") as? String { size = NSCoder.cgSize(for: s) }
        if c.containsValue(forKey: "tileSize") { tile = c.decodeInteger(forKey: "tileSize") }
        name = c.decodeObject(forKey: "name") as? String
        background = c.decodeObject(forKey: "backgroundColor") as? Data
        backgroundHidden = c.decodeBool(forKey: "backgroundHidden")
        layers = ((c.decodeObject(forKey: "layers") as? [Any]) ?? []).compactMap { $0 as? PLayer }
    }
    func encode(with coder: NSCoder) {}
}
final class PLayer: NSObject, NSCoding {
    var uuid = "", name = "Layer", hidden = false, locked = false, opacity = 1.0
    required init?(coder c: NSCoder) {
        uuid = (c.decodeObject(forKey: "UUID") as? String) ?? ""
        name = (c.decodeObject(forKey: "name") as? String) ?? "Layer"
        hidden = c.decodeBool(forKey: "hidden")
        locked = c.decodeBool(forKey: "locked")
        if c.containsValue(forKey: "opacity") { opacity = c.decodeDouble(forKey: "opacity") }
    }
    func encode(with coder: NSCoder) {}
}
/// Stands in for any archived class we don't need (colour profiles, animation settings, video info).
final class PIgnore: NSObject, NSCoding {
    required init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) {}
}

enum KeyedArchive {
    static func root(_ data: Data, classes: [String: AnyClass]) -> Any? {
        guard let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        u.requiresSecureCoding = false
        for (name, cls) in classes { u.setClass(cls, forClassName: name) }
        defer { u.finishDecoding() }
        return try? u.decodeTopLevelObject(forKey: NSKeyedArchiveRootObjectKey)
    }
}

// MARK: - Brushes: a vector copy now, the original kept for pixel layers

struct PixelBrush: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var set: String
    var source: String       // "procreate" or "abr"
}

/// Imported originals, kept as they came (Documents/Brushes/Pixel/<id>/) until the pixel engine can paint with them.
enum PixelBrushStore {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Brushes/Pixel", isDirectory: true)
    }
    static func list() -> [PixelBrush] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("info.json")) else { return nil }
            return try? JSONDecoder().decode(PixelBrush.self, from: data)
        }.sorted { ($0.set, $0.name) < ($1.set, $1.name) }
    }
    static func save(_ b: PixelBrush, files: [String: Data]) {
        let dir = root.appendingPathComponent(b.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files { try? data.write(to: dir.appendingPathComponent(name)) }
        if let info = try? JSONEncoder().encode(b) { try? info.write(to: dir.appendingPathComponent("info.json")) }
    }
    static func thumbnail(_ b: PixelBrush) -> UIImage? { UIImage(contentsOfFile: root.appendingPathComponent(b.id).appendingPathComponent("Thumbnail.png").path) }
    static func delete(_ b: PixelBrush) { try? FileManager.default.removeItem(at: root.appendingPathComponent(b.id)) }
}

enum BrushImport {
    struct Result { var vector: [Brush] = []; var pixel: [(PixelBrush, [String: Data])] = []; var shapes: [StampShape] = []; var setName = "Imported" }

    /// .brushset (many brushes in folders) or .brush (one brush at the top level).
    static func procreate(_ data: Data, fileName: String) -> Result? {
        guard let zip = ZipReader(data) else { return nil }
        var r = Result()
        var setName = (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        var folders: [String] = []
        if let pl = zip.read("brushset.plist"), let info = try? PropertyListSerialization.propertyList(from: pl, format: nil) as? [String: Any] {
            if let n = info["name"] as? String { setName = n }
            folders = (info["brushes"] as? [String]) ?? []
        }
        if folders.isEmpty {
            folders = Array(Set(zip.names.filter { $0.hasSuffix("Brush.archive") }.map { ($0 as NSString).deletingLastPathComponent })).sorted()
        }
        r.setName = setName
        for folder in folders {
            let prefix = folder.isEmpty ? "" : folder + "/"
            guard let archive = zip.read(prefix + "Brush.archive"),
                  let pb = KeyedArchive.root(archive, classes: ["SilicaBrush": PBrush.self, "ValkyrieMagnitudinalCurve": PCurve.self]) as? PBrush else { continue }
            var files: [String: Data] = ["Brush.archive": archive]
            for f in ["Shape.png", "Grain.png", "Shape.jpg", "Grain.jpg"] { if let d = zip.read(prefix + f) { files[f] = d } }
            var vb = vectorBrush(pb, set: setName)
            if vb.stamp != nil, let img = files["Shape.png"] ?? files["Shape.jpg"],
               let sh = traceShape(img, inverted: pb.bools["shapeInverted"] ?? false) {
                StampRegistry.shared.register(sh)
                r.shapes.append(sh)
                vb.stamp?.shape = sh.id
            }
            r.vector.append(vb)
            if let t = zip.read(prefix + "QuickLook/Thumbnail.png") { files["Thumbnail.png"] = t }
            r.pixel.append((PixelBrush(id: "p" + newID(), name: pb.name, set: setName, source: "procreate"), files))
        }
        return r.vector.isEmpty ? nil : r
    }

    /// Procreate's size, pressure, taper and smoothing on a vector brush. Grain, texture and wet mixing don't carry over.
    static func vectorBrush(_ pb: PBrush, set: String) -> Brush {
        func n(_ k: String, _ d: Double) -> Double { pb.nums[k] ?? d }
        let lo = n("minSize", 0), hi = n("maxSize", 1)
        let size = clampD(((lo + (hi - lo) * n("paintSize", 0.3)) * 120 * 100).rounded() / 100, 0.5, sizeMax)
        // a curve that bends below the diagonal needs firmer pressure: read it as a gamma
        var gamma = 1.0
        if let mid = pb.sizeCurve.first(where: { $0.x > 0.2 && $0.x < 0.8 }), mid.y > 0.01, mid.y < 0.99 {
            gamma = clampD(log(Double(mid.y)) / log(Double(mid.x)), 0.4, 2.5)
        }
        let ts = n("pencilTaperStartLength", n("taperStartLength", 0)), te = n("pencilTaperEndLength", n("taperEndLength", 0))
        return Brush(id: "u" + newID(), name: pb.name, set: "imp:" + set, size: size,
                     thinning: clampD(n("dynamicsPressureSize", 0.5) * 0.9, 0, 0.9),
                     taperStart: clampD(ts, 0, 1), taperEnd: clampD(te, 0, 1), smoothing: 0.5, gamma: (gamma * 100).rounded() / 100,
                     streamline: clampD(n("plotSmoothing", 0), 0, 1), slPressure: 0.15,
                     stab: clampD(n("plotMovingAverageStabilization", 0), 0, 1), stabSpeed: 0.5,
                     motion: clampD(n("plotFFTSmoothingAmount", 0), 0, 1), motionExpr: 0, mode: nil, note: "Imported",
                     stamp: stampParams(pb))
    }

    /// Scatter settings, when the brush scatters, spaces out or jitters its dabs enough to show in vector.
    static func stampParams(_ pb: PBrush) -> StampParams? {
        func n(_ k: String) -> Double { pb.nums[k] ?? 0 }
        let spacing = n("plotSpacing"), jitter = n("plotJitter"), linear = n("plotJitterLinear")
        guard jitter >= 0.05 || linear >= 0.05 || spacing >= 0.1 else { return nil }
        var k = StampParams()
        k.spacing = clampD(spacing, 0.02, 3)
        k.jitter = clampD(jitter * 2, 0, 4)
        k.jitterLinear = clampD(linear * 2, 0, 4)
        k.sizeJitter = clampD(n("dynamicsJitterSize"), 0, 1)
        k.rotation = (pb.bools["shapeRandomise"] ?? false) ? 1 : clampD(n("shapeScatter") / 2, 0, 1)
        k.oriented = (pb.bools["oriented"] ?? false) || n("shapeRotation") != 0
        return k
    }

    /// A brush's shape image as dab polygons: traced at 96 px, centred in a unit square, the 60 biggest pieces.
    /// White paints (black, if the brush says its shape is inverted). A plain round shape gives nil: a round dot.
    static func traceShape(_ data: Data, inverted: Bool) -> StampShape? {
        guard let img = UIImage(data: data)?.cgImage else { return nil }
        let S = 96
        var px = [UInt8](repeating: 0, count: S * S * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: S, height: S))
            return true
        }
        guard ok else { return nil }
        // shapes drawn on transparency use their alpha; opaque ones use brightness
        var clear = 0
        for i in 0..<(S * S) where px[i * 4 + 3] < 128 { clear += 1 }
        let useAlpha = clear > S * S / 10
        var mask = [UInt8](repeating: 0, count: S * S)
        for i in 0..<(S * S) {
            let lum = (Int(px[i * 4]) * 3 + Int(px[i * 4 + 1]) * 6 + Int(px[i * 4 + 2])) / 10
            var on = useAlpha ? px[i * 4 + 3] >= 128 : lum >= 128
            if inverted && !useAlpha { on = !on }
            mask[i] = on ? 1 : 0
        }
        var loops = PixelTrace.loops(mask, W: S, H: S, x0: 0, y0: 0, x1: S - 1, y1: S - 1, eps: 0.6, minArea: 1.5)
        guard !loops.isEmpty else { return nil }
        loops.sort { abs(PixelTrace.area($0)) > abs(PixelTrace.area($1)) }
        loops = Array(loops.prefix(60))
        if loops.count == 1 {
            // a single round blob is just a dot
            let l = loops[0]
            let a = abs(PixelTrace.area(l))
            var per = 0.0
            for i in 0..<l.count { per += l[i].dist(l[(i + 1) % l.count]) }
            if per > 0 && 4 * Double.pi * a / (per * per) > 0.8 { return nil }
        }
        // outlines wind one way and holes the other, so they fill right with the non-zero rule
        func inside(_ p: V2, _ poly: [V2]) -> Bool {
            var c = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let a = poly[i], b = poly[j]
                if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
                j = i
            }
            return c
        }
        var polys: [[Double]] = []
        for (i, l) in loops.enumerated() {
            let depth = loops.indices.filter { $0 != i && inside(l[0], loops[$0]) }.count
            let ccw = PixelTrace.area(l) > 0
            let q = (ccw == (depth % 2 == 0)) ? l : Array(l.reversed())
            polys.append(q.flatMap { [r3($0.x / Double(S) - 0.5), r3($0.y / Double(S) - 0.5)] })
        }
        return StampShape(id: "k" + newID(), p: polys)
    }

    /// Photoshop brushes: names and diameters, from the old (v1/2) and the current (v6+) layouts.
    static func abr(_ data: Data, fileName: String) -> Result? {
        let setName = (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        let b = [UInt8](data)
        guard b.count > 4 else { return nil }
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }
        func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }
        let version = u16(0)
        var found: [(String, Double)] = []
        if version == 1 || version == 2 {
            let count = u16(2)
            var p = 4
            for k in 0..<count {
                guard p + 6 <= b.count else { break }
                let type = u16(p), len = u32(p + 2)
                let body = p + 6
                if type == 2 && body + 14 <= b.count {
                    var q = body + 6                        // misc, spacing
                    var name = "Brush \(k + 1)"
                    if version == 2 {
                        let chars = u32(q); q += 4
                        var units: [UInt16] = []
                        for c in 0..<max(0, chars) where q + c * 2 + 1 < b.count { units.append(UInt16(u16(q + c * 2))) }
                        q += chars * 2
                        let s = String(decoding: units.filter { $0 != 0 }, as: UTF16.self)
                        if !s.isEmpty { name = s }
                    }
                    q += 1                                   // antialias
                    let top = u16(q), left = u16(q + 2), bottom = u16(q + 4), right = u16(q + 6)
                    found.append((name, Double(max(bottom - top, right - left))))
                } else if type == 1 && body + 14 <= b.count {
                    found.append(("Brush \(k + 1)", Double(max(1, u16(body + 6)))))
                }
                p = body + len
            }
        } else {
            // v6+: 8BIM sections; the 'desc' section lists each brush's name ("Nm  " TEXT) and diameter ("Dmtr" UntF)
            var names: [String] = [], sizes: [Double] = []
            var i = 0
            while i + 8 < b.count {
                if b[i] == 0x4E, b[i + 1] == 0x6D, b[i + 2] == 0x20, b[i + 3] == 0x20, b[i + 4] == 0x54, b[i + 5] == 0x45, b[i + 6] == 0x58, b[i + 7] == 0x54 {
                    let chars = u32(i + 8)
                    var units: [UInt16] = []
                    if chars > 0 && chars < 512 {
                        for c in 0..<chars where i + 12 + c * 2 + 1 < b.count { units.append(UInt16(u16(i + 12 + c * 2))) }
                    }
                    let s = String(decoding: units.filter { $0 != 0 }, as: UTF16.self)
                    if !s.isEmpty { names.append(s) }
                    i += 12 + max(0, min(chars, 512)) * 2
                    continue
                }
                if b[i] == 0x44, b[i + 1] == 0x6D, b[i + 2] == 0x74, b[i + 3] == 0x72, i + 20 <= b.count {   // "Dmtr" UntF #Pxl <double>
                    var bits: UInt64 = 0
                    for k in 0..<8 { bits = bits << 8 | UInt64(b[i + 12 + k]) }
                    let v = Double(bitPattern: bits)
                    if v.isFinite && v > 0 && v < 5000 { sizes.append(v) }
                    i += 20
                    continue
                }
                i += 1
            }
            for (k, name) in names.enumerated() { found.append((name, k < sizes.count ? sizes[k] : 20)) }
        }
        guard !found.isEmpty else { return nil }
        var r = Result()
        r.setName = setName
        for (name, d) in found {
            r.vector.append(Brush(id: "u" + newID(), name: name, set: "imp:" + setName, size: clampD(d, 0.5, sizeMax), thinning: 0.5,
                                  taperStart: 0, taperEnd: 0, smoothing: 0.5, gamma: 1, streamline: 0.1, motion: 0.3, note: "Imported"))
            r.pixel.append((PixelBrush(id: "p" + newID(), name: name, set: setName, source: "abr"), [:]))
        }
        // the original file is kept once, beside the first brush
        if !r.pixel.isEmpty { r.pixel[0].1["brushes.abr"] = data }
        return r
    }
}

// MARK: - .procreate artwork, traced to vector

enum ProcreateImport {
    /// Reads the document and traces each layer into vector fills: one fill per colour the layer uses,
    /// so linework and flat colour come out as clean shapes. Soft shading comes out in flat steps.
    static func document(_ data: Data, fileName: String, progress: (Double) -> Void = { _ in }) -> Doc? {
        guard let zip = ZipReader(data), let arc = zip.read("Document.archive"),
              let pd = KeyedArchive.root(arc, classes: ["SilicaDocument": PDoc.self, "SilicaLayer": PLayer.self,
                                                        "ValkyrieColorProfile": PIgnore.self, "ValkyrieDocumentAnimation": PIgnore.self,
                                                        "VideoSegmentInfo": PIgnore.self, "ValkyrieMagnitudinalCurve": PIgnore.self]) as? PDoc
        else { return nil }
        let W = Int(pd.size.width), H = Int(pd.size.height), T = max(16, pd.tile)
        guard W > 0, H > 0, W <= 16_384, H <= 16_384 else { return nil }
        let name = pd.name ?? (fileName as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        let doc = Doc(w: Double(W), h: Double(H), name: String(name.prefix(80)))
        if let bg = pd.background, bg.count >= 12 {
            let f = bg.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
            func c(_ v: Float32) -> String { String(format: "%02x", Int((max(0, min(1, v)) * 255).rounded())) }
            doc.bg = "#" + c(f[0]) + c(f[1]) + c(f[2])
        }
        doc.bgOn = !pd.backgroundHidden
        var layers: [Layer] = []
        for (li, pl) in pd.layers.reversed().enumerated() {       // Procreate lists the top layer first
            progress(Double(li) / Double(max(1, pd.layers.count)))
            let L = Layer(name: pl.name)
            L.visible = !pl.hidden
            L.opacity = clampD(pl.opacity, 0, 1)
            L.locked = pl.locked
            if let rgba = pixels(zip, uuid: pl.uuid, W: W, H: H, T: T) { L.items = trace(rgba, W: W, H: H) }
            layers.append(L)
        }
        doc.layers = layers
        doc.active = layers.last?.id ?? ""
        progress(1)
        return doc
    }

    /// The layer's pixels, premultiplied RGBA, top row first (Procreate stores them bottom-up).
    static func pixels(_ zip: ZipReader, uuid: String, W: Int, H: Int, T: Int) -> [UInt8]? {
        guard !uuid.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: W * H * 4)
        var any = false
        for name in zip.names where name.hasPrefix(uuid + "/") && name.hasSuffix(".lz4") {
            let file = (name as NSString).lastPathComponent.dropLast(4)
            let parts = file.split(separator: "~")
            guard parts.count == 2, let cx = Int(parts[0]), let cy = Int(parts[1]) else { continue }
            let tw = min(T, W - cx * T), th = min(T, H - cy * T)
            guard tw > 0, th > 0, let comp = zip.read(name), let raw = Inflate.decode(comp, size: tw * th * 4, algorithm: COMPRESSION_LZ4) else { continue }
            any = true
            raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<th {
                        let Y = H - 1 - (cy * T + y)
                        let s = y * tw * 4, d = (Y * W + cx * T) * 4
                        for k in 0..<(tw * 4) { dst[d + k] = src[s + k] }
                    }
                }
            }
        }
        return any ? out : nil
    }

    /// One even-odd fill per colour (up to 24; alpha in four steps for soft layers), largest first.
    static func trace(_ rgba: [UInt8], W: Int, H: Int) -> [Item] {
        let n = W * H
        // soft layers (mostly half-transparent pixels) keep their transparency in steps; others are cut at half
        var mid = 0, solid = 0
        for i in stride(from: 0, to: n, by: 7) {
            let a = rgba[i * 4 + 3]
            if a >= 224 { solid += 1 } else if a >= 32 { mid += 1 }
        }
        let soft = mid > solid
        func level(_ a: UInt8) -> Int { soft ? (a >= 224 ? 3 : a >= 160 ? 2 : a >= 96 ? 1 : a >= 32 ? 0 : -1) : (a >= 128 ? 3 : -1) }
        func key(_ i: Int) -> Int {
            let a = Int(rgba[i * 4 + 3])
            let lv = level(UInt8(a))
            if lv < 0 { return -1 }
            let r = min(255, Int(rgba[i * 4]) * 255 / max(a, 1)), g = min(255, Int(rgba[i * 4 + 1]) * 255 / max(a, 1)), b = min(255, Int(rgba[i * 4 + 2]) * 255 / max(a, 1))
            return lv << 15 | (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
        }
        // 1. histogram of colours
        var hist = [Int](repeating: 0, count: 1 << 17)
        var keys = [Int32](repeating: -1, count: n)
        for i in 0..<n {
            let k = key(i)
            if k >= 0 { hist[k] += 1; keys[i] = Int32(k) }
        }
        // 2. palette: the most common colours that differ enough from each other
        func rgb(_ k: Int) -> (Int, Int, Int, Int) { ((k >> 10 & 31) * 8 + 4, (k >> 5 & 31) * 8 + 4, (k & 31) * 8 + 4, k >> 15) }
        let used = hist.indices.filter { hist[$0] > 0 }.sorted { hist[$0] > hist[$1] }
        var palette: [(Int, Int, Int, Int)] = []
        func dist(_ a: (Int, Int, Int, Int), _ b: (Int, Int, Int, Int)) -> Int {
            let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2, da = (a.3 - b.3) * 64
            return dr * dr + dg * dg + db * db + da * da
        }
        for k in used where palette.count < 24 && hist[k] >= 30 {
            let c = rgb(k)
            if palette.allSatisfy({ dist($0, c) > 28 * 28 }) { palette.append(c) }
        }
        guard !palette.isEmpty else { return [] }
        var nearest = [UInt8](repeating: 255, count: 1 << 17)
        for k in used {
            let c = rgb(k)
            var best = 0, bd = Int.max
            for (j, p) in palette.enumerated() { let d = dist(p, c); if d < bd { bd = d; best = j } }
            nearest[k] = UInt8(best)
        }
        // 3. a mask per palette colour, traced (grown a pixel on solid layers so neighbouring colours overlap, never gap)
        var counts = [Int](repeating: 0, count: palette.count)
        for i in 0..<n where keys[i] >= 0 { counts[Int(nearest[Int(keys[i])])] += 1 }
        var items: [Item] = []
        for j in palette.indices.sorted(by: { counts[$0] > counts[$1] }) {
            var mask = [UInt8](repeating: 0, count: n)
            var x0 = W, y0 = H, x1 = -1, y1 = -1
            for i in 0..<n where keys[i] >= 0 && nearest[Int(keys[i])] == UInt8(j) {
                mask[i] = 1
                let x = i % W, y = i / W
                if x < x0 { x0 = x }; if x > x1 { x1 = x }; if y < y0 { y0 = y }; if y > y1 { y1 = y }
            }
            guard x1 >= x0 else { continue }
            if !soft {
                var grown = mask
                for y in y0...y1 {
                    for x in x0...x1 where mask[y * W + x] != 0 {
                        if x > 0 { grown[y * W + x - 1] = 1 }
                        if x < W - 1 { grown[y * W + x + 1] = 1 }
                        if y > 0 { grown[(y - 1) * W + x] = 1 }
                        if y < H - 1 { grown[(y + 1) * W + x] = 1 }
                    }
                }
                mask = grown
                x0 = max(0, x0 - 1); y0 = max(0, y0 - 1); x1 = min(W - 1, x1 + 1); y1 = min(H - 1, y1 + 1)
            }
            let loops = PixelTrace.loops(mask, W: W, H: H, x0: x0, y0: y0, x1: x1, y1: y1, eps: 0.5, minArea: 2)
            guard !loops.isEmpty else { continue }
            let c = palette[j]
            let hex = String(format: "#%02x%02x%02x", min(255, c.0), min(255, c.1), min(255, c.2))
            let o = soft ? [0.25, 0.5, 0.75, 1.0][c.3] : 1.0
            items.append(.fill(FillItem(id: newID(), c: hex, o: o, p: loops.map { $0.flatMap { [r2($0.x), r2($0.y)] } })))
        }
        return items
    }
}

import UIKit

/// What a pixel brush paints with, on top of the dab placement in `StampParams`.
struct PixelParams: Codable, Equatable {
    var src: String? = nil            // folder in PixelBrushStore holding the brush's Shape and Grain images
    var hardness: Double = 0.9        // the built-in round tip's edge: 1 crisp … 0 soft (used when there's no shape image)
    var flow: Double = 1              // each dab's opacity; dabs in one stroke never build past it
    var pressureOpacity: Double = 0   // light pressure paints fainter
    var opacityJitter: Double = 0     // random fade per dab
    var grain: String? = nil          // "file" (the brush's Grain image), "noise" (built in), nil for none
    var grainScale: Double = 0.5      // 0…1, small to large
    var grainDepth: Double = 1        // how strongly the grain shows
    var shapeInverted = false
    var grainInverted = false

    init() {}
    static func make(hardness: Double = 0.9, flow: Double = 1, pressureOpacity: Double = 0, grain: String? = nil,
                     grainScale: Double = 0.5, grainDepth: Double = 1) -> PixelParams {
        var p = PixelParams()
        p.hardness = hardness; p.flow = flow; p.pressureOpacity = pressureOpacity; p.grain = grain; p.grainScale = grainScale; p.grainDepth = grainDepth
        return p
    }
    enum CodingKeys: String, CodingKey { case src, hardness, flow, pressureOpacity, opacityJitter, grain, grainScale, grainDepth, shapeInverted, grainInverted }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let b = PixelParams()
        src = try? c.decodeIfPresent(String.self, forKey: .src)
        hardness = (try? c.decodeIfPresent(Double.self, forKey: .hardness)) ?? b.hardness
        flow = (try? c.decodeIfPresent(Double.self, forKey: .flow)) ?? b.flow
        pressureOpacity = (try? c.decodeIfPresent(Double.self, forKey: .pressureOpacity)) ?? b.pressureOpacity
        opacityJitter = (try? c.decodeIfPresent(Double.self, forKey: .opacityJitter)) ?? b.opacityJitter
        grain = try? c.decodeIfPresent(String.self, forKey: .grain)
        grainScale = (try? c.decodeIfPresent(Double.self, forKey: .grainScale)) ?? b.grainScale
        grainDepth = (try? c.decodeIfPresent(Double.self, forKey: .grainDepth)) ?? b.grainDepth
        shapeInverted = (try? c.decodeIfPresent(Bool.self, forKey: .shapeInverted)) ?? false
        grainInverted = (try? c.decodeIfPresent(Bool.self, forKey: .grainInverted)) ?? false
    }

    var tipKey: String { src.map { "f:\($0):\(shapeInverted)" } ?? "r:\((hardness * 100).rounded())" }
    var grainKey: String? {
        switch grain {
        case "file": return src.map { "f:\($0):\(grainInverted)" }
        case "noise": return "noise"
        default: return nil
        }
    }
}

/// A brush tip at several sizes (grey: white paints), so each dab is drawn from one close to its size.
final class PixelTip {
    let levels: [(size: Int, image: CGImage)]   // largest first
    init(levels: [(Int, CGImage)]) { self.levels = levels.map { (size: $0.0, image: $0.1) } }
    func image(forDiameter d: Double) -> CGImage {
        var best = levels[0].image
        for l in levels where Double(l.size) >= d * 0.9 { best = l.image }
        return best
    }
}

/// Tips and grain textures, made once and shared (painting reads them on the main thread only).
enum PixelAssets {
    private static var tips: [String: PixelTip] = [:]
    private static var grains: [String: [UInt8]] = [:]
    static let grainSize = 256

    static func tip(_ p: PixelParams) -> PixelTip {
        if let t = tips[p.tipKey] { return t }
        var base: [UInt8]? = nil
        if let src = p.src, let data = PixelBrushStore.file(src, ["Shape.png", "Shape.jpg"]) { base = grey(data, size: 256, inverted: p.shapeInverted) }
        let t = PixelTip(levels: mips(base ?? round(256, hardness: p.hardness), 256))
        tips[p.tipKey] = t
        return t
    }

    /// The grain as a 256 × 256 grey texture (white paints), or nil for none.
    static func grain(_ p: PixelParams) -> [UInt8]? {
        guard let key = p.grainKey else { return nil }
        if let g = grains[key] { return g }
        var g: [UInt8]? = nil
        if key == "noise" { g = noise(grainSize) }
        else if let src = p.src, let data = PixelBrushStore.file(src, ["Grain.png", "Grain.jpg"]) { g = grey(data, size: grainSize, inverted: p.grainInverted) }
        if let g { grains[key] = g }
        return g
    }

    // MARK: making them

    /// An image as grey levels at size × size: brightness, or alpha for shapes drawn on transparency.
    static func grey(_ data: Data, size S: Int, inverted: Bool) -> [UInt8]? {
        guard let img = UIImage(data: data)?.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: S * S * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: S, height: S))
            return true
        }
        guard ok else { return nil }
        var clear = 0
        for i in 0..<(S * S) where px[i * 4 + 3] < 128 { clear += 1 }
        let useAlpha = clear > S * S / 10
        var out = [UInt8](repeating: 0, count: S * S)
        for i in 0..<(S * S) {
            var v = useAlpha ? Int(px[i * 4 + 3]) : (Int(px[i * 4]) * 3 + Int(px[i * 4 + 1]) * 6 + Int(px[i * 4 + 2])) / 10
            if inverted && !useAlpha { v = 255 - v }
            out[i] = UInt8(clamping: v)
        }
        return out
    }

    /// A round tip: solid to `hardness` of the radius, then easing out to the edge.
    static func round(_ S: Int, hardness: Double) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: S * S)
        let R = Double(S) / 2
        let inner = clampD(hardness, 0, 1) * (R - 1.5)
        for y in 0..<S {
            for x in 0..<S {
                let d = ((Double(x) + 0.5 - R) * (Double(x) + 0.5 - R) + (Double(y) + 0.5 - R) * (Double(y) + 0.5 - R)).squareRoot()
                var v: Double
                if d <= inner { v = 1 } else if d >= R { v = 0 } else {
                    let t = (d - inner) / (R - inner)
                    v = 1 - t * t * (3 - 2 * t)
                }
                out[y * S + x] = UInt8((v * 255).rounded())
            }
        }
        return out
    }

    /// Soft paper-like noise that tiles seamlessly.
    static func noise(_ S: Int) -> [UInt8] {
        var rng = SplitMix(x: 0x5EED)
        func layer(_ cells: Int) -> [Double] {
            var lattice = [Double](repeating: 0, count: cells * cells)
            for i in 0..<lattice.count { lattice[i] = rng.unit() }
            var out = [Double](repeating: 0, count: S * S)
            for y in 0..<S {
                for x in 0..<S {
                    let fx = Double(x) / Double(S) * Double(cells), fy = Double(y) / Double(S) * Double(cells)
                    let x0 = Int(fx) % cells, y0 = Int(fy) % cells, x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells
                    var u = fx - floor(fx), v = fy - floor(fy)
                    u = u * u * (3 - 2 * u); v = v * v * (3 - 2 * v)
                    let a = lattice[y0 * cells + x0] + (lattice[y0 * cells + x1] - lattice[y0 * cells + x0]) * u
                    let b = lattice[y1 * cells + x0] + (lattice[y1 * cells + x1] - lattice[y1 * cells + x0]) * u
                    out[y * S + x] = a + (b - a) * v
                }
            }
            return out
        }
        let a = layer(64), b = layer(128), c = layer(32)
        return (0..<(S * S)).map { i in
            let v = 0.5 * a[i] + 0.35 * b[i] + 0.15 * c[i]
            return UInt8(clamping: Int((clampD((v - 0.25) * 2, 0, 1) * 255).rounded()))
        }
    }

    /// Grey images at size, size/2, … down to 4 px.
    private static func mips(_ base: [UInt8], _ S: Int) -> [(Int, CGImage)] {
        var out: [(Int, CGImage)] = []
        var cur = base, n = S
        while n >= 4 {
            if let img = greyImage(cur, n) { out.append((n, img)) }
            let m = n / 2
            guard m >= 4 else { break }
            var next = [UInt8](repeating: 0, count: m * m)
            for y in 0..<m {
                for x in 0..<m {
                    let s = Int(cur[(2 * y) * n + 2 * x]) + Int(cur[(2 * y) * n + 2 * x + 1]) + Int(cur[(2 * y + 1) * n + 2 * x]) + Int(cur[(2 * y + 1) * n + 2 * x + 1])
                    next[y * m + x] = UInt8((s + 2) / 4)
                }
            }
            cur = next; n = m
        }
        return out
    }

    static func greyImage(_ bytes: [UInt8], _ n: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension PixelBrushStore {
    /// The first of these files the brush folder has.
    static func file(_ id: String, _ names: [String]) -> Data? {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        for n in names { if let d = try? Data(contentsOf: dir.appendingPathComponent(n)) { return d } }
        return nil
    }
}

extension BrushImport {
    /// A Procreate brush as a pixel brush: the vector copy's size, pressure, taper and smoothing,
    /// plus its shape, grain, spacing, jitter and opacity.
    static func pixelBrush(_ pb: PBrush, folder: String, set: String, hasShape: Bool, hasGrain: Bool) -> Brush {
        func n(_ k: String, _ d: Double) -> Double { pb.nums[k] ?? d }
        var b = vectorBrush(pb, set: set)
        b.id = folder
        b.set = "pix:" + set
        b.note = "Imported"
        var k = StampParams()
        k.spacing = clampD(n("plotSpacing", 0), 0.02, 3)
        k.scale = 1
        k.jitter = clampD(n("plotJitter", 0) * 2, 0, 4)
        k.jitterLinear = clampD(n("plotJitterLinear", 0) * 2, 0, 4)
        k.sizeJitter = clampD(n("dynamicsJitterSize", 0), 0, 1)
        k.rotation = (pb.bools["shapeRandomise"] ?? false) ? 1 : clampD(n("shapeScatter", 0) / 2, 0, 1)
        k.oriented = (pb.bools["oriented"] ?? false) || n("shapeRotation", 0) != 0
        b.stamp = k
        var p = PixelParams()
        p.src = folder
        // a bundled Procreate shape isn't in the file: a soft-edged round stands in for it
        if !hasShape { p.hardness = 0.55 }
        p.flow = clampD(n("dynamicsGlazedFlow", 1) * n("paintOpacity", 1) * n("maxOpacity", 1), 0.02, 1)
        p.pressureOpacity = clampD(n("dynamicsPressureOpacity", 0), 0, 1)
        p.opacityJitter = clampD(n("dynamicsJitterOpacity", 0), 0, 1)
        p.shapeInverted = pb.bools["shapeInverted"] ?? false
        p.grainInverted = pb.bools["textureInverted"] ?? false
        p.grainScale = clampD(n("textureScale", 0.5), 0, 1)
        p.grainDepth = clampD(n("grainDepth", 1), 0, 1)
        if hasGrain { p.grain = "file" } else if pb.texts["bundledGrainPath"].map({ !$0.lowercased().contains("blank") }) ?? false { p.grain = "noise" }
        b.pixel = p
        return b
    }

    /// A Photoshop brush as a pixel brush: its size on a round tip.
    static func pixelBrush(abrName name: String, size: Double, folder: String, set: String) -> Brush {
        var b = Brush(id: folder, name: name, set: "pix:" + set, size: clampD(size, 0.5, sizeMax), thinning: 0.5, taperStart: 0, taperEnd: 0,
                      smoothing: 0.5, gamma: 1, streamline: 0.1, motion: 0.3, note: "Imported")
        b.stamp = StampParams(spacing: 0.1)
        var p = PixelParams()
        p.hardness = 0.8
        b.pixel = p
        return b
    }
}

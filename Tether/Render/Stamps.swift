import Foundation

/// How a scatter brush lays dabs along the line instead of drawing a ribbon.
struct StampParams: Codable, Equatable {
    var shape: String? = nil      // a traced dab shape (see StampRegistry); nil = a round dot
    var spacing: Double = 0.1     // between dabs, as a fraction of the brush size
    var scale: Double = 1         // dab size relative to the line's width
    var jitter: Double = 0        // sideways scatter, up to half a brush width each way at 1
    var jitterLinear: Double = 0  // scatter along the line, same scale
    var sizeJitter: Double = 0    // random shrink, 0…1
    var rotation: Double = 0      // random turn, 0…1 of a full turn
    var oriented: Bool = false    // dabs turn with the line
}

/// A dab shape: polygons (flat x, y lists) in a unit square centred on 0, traced from a brush's shape image.
struct StampShape: Codable, Equatable {
    var id: String
    var p: [[Double]]
}

/// Dab shapes by id, for drawing on any thread. Filled from the brushes you've imported and from each opened drawing.
final class StampRegistry {
    static let shared = StampRegistry()
    private var shapes: [String: StampShape] = [:]
    private let lock = NSLock()
    func register(_ s: StampShape) { lock.lock(); shapes[s.id] = s; lock.unlock() }
    func get(_ id: String) -> StampShape? { lock.lock(); defer { lock.unlock() }; return shapes[id] }
}

/// Small, fast, repeatable random numbers (SplitMix64).
struct SplitMix {
    var x: UInt64
    mutating func next() -> UInt64 {
        x &+= 0x9E37_79B9_7F4A_7C15
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
}

extension StrokeGeometry {
    /// A stroke's seed for its dabs (FNV-1a of its id), so it scatters the same way every time it's drawn.
    static func seed(_ id: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    /// The stroke's shape: a ribbon, or dabs for a scatter brush.
    static func shapes(_ baked: [Double], _ b: BrushShape, seed: UInt64, s0: Double = 0, end: Double? = nil) -> [[V2]] {
        guard let k = b.k else { return outline(baked) }
        return stamps(baked, k, size: b.size, seed: seed, s0: s0, end: end)
    }
    /// Arc length of an (x, y, radius) line.
    static func arcLength(_ pts: [Double]) -> Double {
        var s = 0.0
        var i = 3
        while i + 1 < pts.count { s += V2(pts[i] - pts[i - 3], pts[i + 1] - pts[i - 2]).length; i += 3 }
        return s
    }

    /// One dab: where it lands, its radius and turn, the line's own radius there, and a spare random number.
    struct Dab { var x: Double; var y: Double; var r: Double; var angle: Double; var lineR: Double; var rnd: Double }

    /// Dabs along the (x, y, radius) line. Dab j sits at arc length j × step and draws its randomness from (seed, j),
    /// so any stretch of the line (s0 up to, not including, `end`) produces exactly the dabs the whole line would there.
    static func dabs(_ pts: [Double], _ k: StampParams, step: Double, seed: UInt64, s0: Double = 0, end: Double? = nil, limit: Int = 20_000) -> [Dab] {
        let n = pts.count / 3
        guard n > 0, step > 0 else { return [] }
        func P(_ i: Int) -> V2 { V2(pts[i * 3], pts[i * 3 + 1]) }
        var s = [Double](repeating: s0, count: n)
        for i in 1..<max(1, n) { s[i] = s[i - 1] + P(i).dist(P(i - 1)) }
        let stop = end ?? (s[n - 1] + 1e-9)
        var out: [Dab] = []
        var j = Int((s0 / step).rounded(.up))
        var i = 0
        while out.count < limit {
            let sj = Double(j) * step
            if sj >= stop { break }
            while i < n - 1 && s[i + 1] < sj { i += 1 }
            let i1 = min(n - 1, i + 1)
            let seg = s[i1] - s[i]
            let u = seg > 1e-9 ? clampD((sj - s[i]) / seg, 0, 1) : 0
            let p = P(i) + (P(i1) - P(i)) * u
            let r = pts[i * 3 + 2] + (pts[i1 * 3 + 2] - pts[i * 3 + 2]) * u
            let d = P(i1) - P(i)
            let t = d.length > 1e-9 ? d / d.length : V2(1, 0)
            let nrm = V2(-t.y, t.x)
            var rng = SplitMix(x: seed ^ (UInt64(truncatingIfNeeded: j) &* 0x9E37_79B9_7F4A_7C15))
            let a = rng.unit(), b = rng.unit(), c = rng.unit(), e = rng.unit(), f = rng.unit()
            let width = 2 * r
            let centre = p + nrm * (k.jitter * width * (a - 0.5)) + t * (k.jitterLinear * width * (b - 0.5))
            var ang = k.oriented ? atan2(t.y, t.x) : 0
            ang += k.rotation * 2 * Double.pi * (e - 0.5)
            out.append(Dab(x: centre.x, y: centre.y, r: r * k.scale * (1 - k.sizeJitter * c), angle: ang, lineR: r, rnd: f))
            j += 1
        }
        return out
    }

    /// A scatter stroke's dabs as polygons.
    static func stamps(_ pts: [Double], _ k: StampParams, size: Double, seed: UInt64, s0: Double = 0, end: Double? = nil) -> [[V2]] {
        // traced shapes are many polygons each, so they space out a little more to keep long strokes light
        let step = max(0.5, (k.shape == nil ? k.spacing : max(k.spacing, 0.12)) * size)
        let shape = k.shape.flatMap { StampRegistry.shared.get($0) }
        var out: [[V2]] = []
        for dab in dabs(pts, k, step: step, seed: seed, s0: s0, end: end) {
            let centre = V2(dab.x, dab.y), rr = dab.r
            let ca = cos(dab.angle), sa = sin(dab.angle)
            if let sh = shape {
                let w2 = 2 * rr
                for poly in sh.p where poly.count >= 6 {
                    var q: [V2] = []
                    q.reserveCapacity(poly.count / 2)
                    var m = 0
                    while m + 1 < poly.count {
                        let x = poly[m] * w2, y = poly[m + 1] * w2
                        q.append(V2(centre.x + x * ca - y * sa, centre.y + x * sa + y * ca))
                        m += 2
                    }
                    out.append(q)
                }
            } else {
                let sides = max(8, min(20, Int(rr * 3)))
                out.append((0..<sides).map { v in
                    let an = 2 * Double.pi * Double(v) / Double(sides)
                    return V2(centre.x + rr * cos(an), centre.y + rr * sin(an))
                })
            }
        }
        return out
    }
}

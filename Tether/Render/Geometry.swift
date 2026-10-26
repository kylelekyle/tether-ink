import Foundation
import CoreGraphics

/// Stroke geometry. A stroke is stored as its centerline: [x, y, radius] triples in canvas units,
/// with pressure and tapers already turned into the radius, so drawing it needs no brush maths.
enum StrokeGeometry {
    static let minRadius = 0.02

    /// Radius for a pressure: half the brush size at full pressure; thinning narrows lighter pressure.
    static func radius(_ p: Double, _ b: BrushShape) -> Double {
        let pg = pow(clampD(p, 0, 1), b.g)
        let w: Double = (1 - b.thin + 2 * b.thin * pg) / (1 + b.thin)
        return max(minRadius, b.size / 2 * w)
    }
    /// Lengths (canvas units) of the start and end tapers.
    static func taperLengths(_ b: BrushShape) -> (start: Double, end: Double) {
        let tl = max(b.size * 20, 40)
        return (b.ts > 0 ? b.ts * tl : 0, b.te > 0 ? b.te * tl : 0)
    }
    private static func easeStart(_ t: Double) -> Double { t * (2 - t) }
    private static func easeEnd(_ t: Double) -> Double { let u = t - 1; return u * u * u + 1 }

    /// (x, y, pressure) triples → (x, y, radius) triples, tapered by arc length.
    /// `s0` is the arc length at the first point; the end taper is measured from the last point (or `total`).
    static func bake(_ pts: [Double], _ b: BrushShape, s0: Double = 0, total: Double? = nil, endTaper: Bool = true) -> [Double] {
        let n = pts.count / 3
        guard n > 0 else { return [] }
        var s = [Double](repeating: s0, count: n)
        for i in 1..<max(1, n) {
            let dx = pts[i * 3] - pts[i * 3 - 3], dy = pts[i * 3 + 1] - pts[i * 3 - 2]
            s[i] = s[i - 1] + (dx * dx + dy * dy).squareRoot()
        }
        let S = total ?? s[n - 1]
        let (ts, te) = taperLengths(b)
        var out = [Double](repeating: 0, count: n * 3)
        for i in 0..<n {
            var k = 1.0
            if ts > 0 && s[i] < ts { k = min(k, easeStart(s[i] / ts)) }
            if endTaper && te > 0 && S - s[i] < te { k = min(k, easeEnd(max(0, S - s[i]) / te)) }
            out[i * 3] = pts[i * 3]
            out[i * 3 + 1] = pts[i * 3 + 1]
            out[i * 3 + 2] = max(minRadius, radius(pts[i * 3 + 2], b) * k)
        }
        return out
    }

    /// The pressure a radius came from (for re-editing a snapped shape, whose pressure is uniform).
    static func pressure(fromRadius r: Double, _ b: BrushShape) -> Double {
        guard b.thin > 0, b.size > 0 else { return 0.5 }
        let w = r / (b.size / 2) * (1 + b.thin)
        let pg = clampD((w - 1 + b.thin) / (2 * b.thin), 0, 1)
        return b.g > 0 ? pow(pg, 1 / b.g) : pg
    }

    /// Drawings saved before the new engine stored pressure; this gives the widths they were drawn with.
    static func migrateV1(_ pts: [Double], _ b: BrushShape) -> [Double] {
        guard b.sim && b.thin > 0 else { return bake(pts, b) }
        // finger strokes simulated pressure from speed: slow is thick, fast is thin
        var q = pts
        let size = b.size / (1 + b.thin)
        var prev = 0.5
        var i = 3
        while i + 2 < q.count {
            let d = V2(q[i] - q[i - 3], q[i + 1] - q[i - 2]).length
            let sp = min(1, d / max(size, 1e-6)), rp = min(1, 1 - sp)
            prev = min(1, prev + (rp - prev) * (sp * 0.275))
            q[i + 2] = prev
            i += 3
        }
        if q.count >= 6 { q[2] = q[5] }
        return bake(q, b)
    }

    // MARK: outline

    /// Closed polygons: the stroke's outline first, then round disks at turns tighter than the brush,
    /// all wound the same way so they fill as one shape (non-zero rule).
    static func outline(_ pts: [Double]) -> [[V2]] {
        let n = pts.count / 3
        guard n > 0 else { return [] }
        func P(_ i: Int) -> V2 { V2(pts[i * 3], pts[i * 3 + 1]) }
        func R(_ i: Int) -> Double { pts[i * 3 + 2] }
        var span = 0.0
        for i in 1..<max(1, n) { span = max(span, P(i).dist(P(0))) }
        if n == 1 || span < 1e-9 { return [circle(P(0), R(0), ccw: true)] }

        var s = [Double](repeating: 0, count: n)
        var rmax = R(0)
        for i in 1..<n { s[i] = s[i - 1] + P(i).dist(P(i - 1)); rmax = max(rmax, R(i)) }
        var tg = [V2](repeating: V2(1, 0), count: n)
        for i in 0..<n {
            let d = P(min(n - 1, i + 1)) - P(max(0, i - 1))
            let l = d.length
            tg[i] = l > 1e-12 ? d / l : (i > 0 ? tg[i - 1] : V2(1, 0))
        }
        let seg = max(1e-6, s[n - 1] / Double(max(1, n - 1)))
        let window = Int(min(64, 4 + 3 * rmax / seg))
        var left: [V2] = [], right: [V2] = [], disks: [(V2, Double)] = []
        left.reserveCapacity(n); right.reserveCapacity(n)
        var lastDisk: V2? = nil
        for i in 0..<n {
            let p = P(i), r = R(i), t = tg[i]
            let i0 = max(0, i - 1), i1 = min(n - 1, i + 1)
            let ds = s[i1] - s[i0]
            // envelope of a moving circle: tilt the offset by the rate the radius changes, so quick swells don't bulge
            let dr = clampD(ds > 1e-9 ? (R(i1) - R(i0)) / ds : 0, -0.95, 0.95)
            let c = (1 - dr * dr).squareRoot()
            let nrm = V2(-t.y, t.x)
            let back = t * (-dr)
            addSide(&left, p + (back + nrm * c) * r, window)
            addSide(&right, p + (back - nrm * c) * r, window)
            if i > 0 && i < n - 1 {
                let a = p - P(i - 1), b = P(i + 1) - p
                let la = a.length, lb = b.length
                if la > 1e-9 && lb > 1e-9 {
                    let turn = acos(clampD(a.dot(b) / (la * lb), -1, 1))
                    if turn > 0.15 && r * turn > 0.6 * min(la, lb) {
                        if lastDisk == nil || p.dist(lastDisk!) > r * 0.5 { disks.append((p, r)); lastDisk = p }
                    }
                }
            }
        }
        guard let lEnd = left.last, let rEnd = right.last, let lStart = left.first, let rStart = right.first else { return [] }
        let endCap = cap(P(n - 1), R(n - 1), toward: tg[n - 1], from: lEnd, to: rEnd)
        let startCap = cap(P(0), R(0), toward: -tg[0], from: rStart, to: lStart)
        var poly = left
        poly.append(contentsOf: endCap)
        poly.append(contentsOf: right.reversed())
        poly.append(contentsOf: startCap)
        var area = 0.0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            area += a.x * b.y - b.x * a.y
        }
        var out = [poly]
        for d in disks { out.append(circle(d.0, d.1, ccw: area > 0)) }
        return out
    }

    /// Append q to one side; if the new edge crosses one of the last few edges (the inside of a tight turn),
    /// cut the little loop out so no notch or hole is left.
    private static func addSide(_ side: inout [V2], _ q: V2, _ window: Int) {
        if let a = side.last, side.count >= 3 {
            let lo = max(0, side.count - 1 - window)
            var j = side.count - 3
            while j >= lo {
                if let x = crossing(side[j], side[j + 1], a, q) {
                    side.removeSubrange((j + 1)...)
                    side.append(x)
                    break
                }
                j -= 1
            }
        }
        side.append(q)
    }
    private static func crossing(_ a: V2, _ b: V2, _ c: V2, _ d: V2) -> V2? {
        let r = b - a, s = d - c
        let den = r.x * s.y - r.y * s.x
        if abs(den) < 1e-12 { return nil }
        let q = c - a
        let t = (q.x * s.y - q.y * s.x) / den
        let u = (q.x * r.y - q.y * r.x) / den
        return (t > 0 && t < 1 && u > 0 && u < 1) ? a + r * t : nil
    }
    /// Round cap around c from one side point to the other, bulging toward `toward`.
    private static func cap(_ c: V2, _ r: Double, toward f: V2, from a: V2, to b: V2) -> [V2] {
        let steps = max(4, min(16, Int(r * 2)))
        let a0 = atan2(a.y - c.y, a.x - c.x), a1 = atan2(b.y - c.y, b.x - c.x), af = atan2(f.y, f.x)
        func norm(_ v: Double) -> Double { var x = v.truncatingRemainder(dividingBy: 2 * .pi); if x < 0 { x += 2 * .pi }; return x }
        let ccwSpan = norm(a1 - a0)
        let span: Double = norm(af - a0) <= ccwSpan ? ccwSpan : -(2 * .pi - ccwSpan)
        var out: [V2] = []
        out.reserveCapacity(steps)
        for k in 1..<steps {
            let ang = a0 + span * Double(k) / Double(steps)
            out.append(V2(c.x + r * cos(ang), c.y + r * sin(ang)))
        }
        return out
    }
    private static func circle(_ c: V2, _ r: Double, ccw: Bool) -> [V2] {
        let n = max(12, min(32, Int(r * 2.5)))
        let dir: Double = ccw ? 1 : -1
        return (0..<n).map { i in
            let a = 2 * Double.pi * Double(i) / Double(n) * dir
            return V2(c.x + r * cos(a), c.y + r * sin(a))
        }
    }

    /// Closed, smooth outlines: quadratic curves through the midpoints of each polygon.
    static func path(_ o: [[V2]], transform: CGAffineTransform? = nil) -> CGPath {
        let path = CGMutablePath()
        let t = transform ?? .identity
        for poly in o {
            let n = poly.count
            guard n >= 3 else { continue }
            let a0 = poly[n - 1], b0 = poly[0]
            path.move(to: CGPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2), transform: t)
            for i in 0..<n {
                let a = poly[i], b = poly[(i + 1) % n]
                path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: CGPoint(x: a.x, y: a.y), transform: t)
            }
            path.closeSubpath()
        }
        return path
    }

    static func bbox(_ o: [[V2]]) -> CGRect {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for poly in o { for q in poly { x0 = min(x0, q.x); y0 = min(y0, q.y); x1 = max(x1, q.x); y1 = max(y1, q.y) } }
        guard x0.isFinite else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func svgPath(_ o: [[V2]]) -> String {
        func f(_ v: Double) -> String { let r = (v * 100).rounded() / 100; return r == r.rounded() ? String(Int(r)) : String(r) }
        var d = ""
        for poly in o {
            let n = poly.count
            guard n >= 3 else { continue }
            let a0 = poly[n - 1], b0 = poly[0]
            d += "M\(f((a0.x + b0.x) / 2)) \(f((a0.y + b0.y) / 2))Q"
            for i in 0..<n {
                let a = poly[i], b = poly[(i + 1) % n]
                d += "\(f(a.x)) \(f(a.y)) \(f((a.x + b.x) / 2)) \(f((a.y + b.y) / 2)) "
            }
            d = d.trimmingCharacters(in: .whitespaces) + "Z"
        }
        return d
    }
}

/// Outline paths for committed strokes, cached by stroke id. Safe to use from the render queue.
final class GeometryCache {
    static let shared = GeometryCache()
    private var cache: [String: (CGPath, CGRect)] = [:]
    private let lock = NSLock()

    func get(_ s: StrokeItem) -> (path: CGPath, bbox: CGRect) {
        lock.lock()
        if let c = cache[s.id] { lock.unlock(); return c }
        lock.unlock()
        let o = StrokeGeometry.outline(s.p)
        let entry = (StrokeGeometry.path(o), StrokeGeometry.bbox(o))
        lock.lock(); cache[s.id] = entry; lock.unlock()
        return entry
    }

    func trim(keep ids: Set<String>) {
        lock.lock(); cache = cache.filter { ids.contains($0.key) }; lock.unlock()
    }
}

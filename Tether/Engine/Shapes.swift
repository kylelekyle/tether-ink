import Foundation

// MARK: - Hold to snap: the shapes a held stroke can become

/// An ellipse in canvas units. `start` is the parameter angle where the outline begins (where the stroke began),
/// `dir` is +1 or -1 so the outline runs the same way the stroke was drawn.
struct Ellipse: Equatable {
    var c: V2
    var r1: Double
    var r2: Double
    var angle: Double
    var start: Double = 0
    var dir: Double = 1
    var circle: Bool = false

    func point(_ t: Double) -> V2 {
        let ex = cos(t) * r1, ey = sin(t) * r2, ca = cos(angle), sa = sin(angle)
        return V2(c.x + ex * ca - ey * sa, c.y + ex * sa + ey * ca)
    }
    /// The four axis ends: +r1, +r2, -r1, -r2.
    var handles: [V2] { [point(0), point(.pi / 2), point(.pi), point(.pi * 1.5)] }
    /// Closed outline with two extra steps of overlap so the round ends meet seamlessly.
    func outline(steps n: Int) -> [V2] {
        var pts: [V2] = []
        pts.reserveCapacity(n + 3)
        for i in 0...(n + 2) { pts.append(point(start + dir * Double(i) / Double(n) * .pi * 2)) }
        return pts
    }
    /// Parameter angle of a point (as if it were on the outline).
    func param(of p: V2) -> Double {
        let ca = cos(angle), sa = sin(angle), dx = p.x - c.x, dy = p.y - c.y
        let lx = dx * ca + dy * sa, ly = -dx * sa + dy * ca
        return atan2(ly / max(r2, 1e-9), lx / max(r1, 1e-9))
    }
}

/// A smooth open curve made of cubic Bézier segments: [p0, c1, c2, p1, c1, c2, p2, …].
/// `arc` marks a perfect circular arc, which stays circular when edited.
struct Curve: Equatable {
    var pts: [V2]
    var arc = false

    var segments: Int { max(1, (pts.count - 1) / 3) }
    var start: V2 { pts[0] }
    var end: V2 { pts[pts.count - 1] }

    func point(_ seg: Int, _ u: Double) -> V2 {
        let i = seg * 3
        let m = 1 - u
        let b0 = m * m * m, b1 = 3 * m * m * u, b2 = 3 * m * u * u, b3 = u * u * u
        let a = pts[i] * b0 + pts[i + 1] * b1
        let b = pts[i + 2] * b2 + pts[i + 3] * b3
        return a + b
    }
    /// The point halfway along the curve's parameter: the "bend" handle.
    var mid: V2 {
        let g = 0.5 * Double(segments)
        let seg = min(segments - 1, Int(g))
        return point(seg, g - Double(seg))
    }
    func sampled(perSegment k: Int = 32) -> [V2] {
        var out: [V2] = [pts[0]]
        out.reserveCapacity(segments * k + 1)
        for s in 0..<segments { for i in 1...k { out.append(point(s, Double(i) / Double(k))) } }
        return out
    }
    func moved(by d: V2) -> Curve { Curve(pts: pts.map { $0 + d }, arc: arc) }
    /// Rotate and scale about one end so the chord a→b becomes a→b2 (the bend keeps its shape).
    func mapped(fix a: V2, from b: V2, to b2: V2) -> Curve {
        let u = b - a, w = b2 - a
        let den = max(u.length2, 1e-12)
        let re: Double = (w.x * u.x + w.y * u.y) / den
        let im: Double = (w.y * u.x - w.x * u.y) / den
        return Curve(pts: pts.map { p in
            let v = p - a
            return a + V2(v.x * re - v.y * im, v.x * im + v.y * re)
        }, arc: arc)
    }
    /// Drag the bend handle: the curve passes through the new point and keeps its ends.
    func bent(to target: V2) -> Curve {
        if arc, let a = Curve.arc(start, target, end) { return a }
        var c = self
        let d = target - mid
        if segments == 1 {
            c.pts[1] = c.pts[1] + d / 0.75
            c.pts[2] = c.pts[2] + d / 0.75
        } else {
            let j = (segments / 2) * 3
            for k in (j - 1)...(j + 1) { c.pts[k] = c.pts[k] + d }
        }
        return c
    }

    /// A perfect circular arc from a through m to b, as up to four cubic segments.
    static func arc(_ a: V2, _ m: V2, _ b: V2) -> Curve? {
        let d: Double = 2 * (a.x * (m.y - b.y) + m.x * (b.y - a.y) + b.x * (a.y - m.y))
        if abs(d) < 1e-9 { return nil }
        let a2 = a.length2, m2 = m.length2, b2 = b.length2
        let cx: Double = (a2 * (m.y - b.y) + m2 * (b.y - a.y) + b2 * (a.y - m.y)) / d
        let cy: Double = (a2 * (b.x - m.x) + m2 * (a.x - b.x) + b2 * (m.x - a.x)) / d
        let c = V2(cx, cy)
        let r = a.dist(c)
        if !r.isFinite || r <= 0 { return nil }
        let t0 = atan2(a.y - c.y, a.x - c.x)
        var tm = atan2(m.y - c.y, m.x - c.x) - t0
        var t1 = atan2(b.y - c.y, b.x - c.x) - t0
        while tm < 0 { tm += 2 * .pi }
        while t1 < 0 { t1 += 2 * .pi }
        let sweep: Double = tm <= t1 ? t1 : t1 - 2 * .pi          // go the way that passes through m
        let n = max(1, min(4, Int((abs(sweep) / (.pi / 2)).rounded(.up))))
        let step = sweep / Double(n)
        let k: Double = 4.0 / 3.0 * tan(step / 4) * r
        var pts: [V2] = [a]
        for i in 0..<n {
            let s0 = t0 + step * Double(i), s1 = s0 + step
            let p0 = V2(cx + r * cos(s0), cy + r * sin(s0)), p1 = V2(cx + r * cos(s1), cy + r * sin(s1))
            pts.append(p0 + V2(-sin(s0), cos(s0)) * k)
            pts.append(p1 - V2(-sin(s1), cos(s1)) * k)
            pts.append(i == n - 1 ? b : p1)
        }
        return Curve(pts: pts, arc: true)
    }
}

enum SnappedShape: Equatable {
    case line(V2, V2)
    case ellipse(Ellipse)
    case curve(Curve)

    /// Flat [x, y, p, …] points for the stroke, spaced for the given zoom.
    func points(pressure: Double, zoom: Double) -> [Double] {
        switch self {
        case .line(let a, let b):
            let n = max(2, Int((a.dist(b) * zoom / 6).rounded(.up)))
            var pts: [Double] = []
            pts.reserveCapacity((n + 1) * 3)
            for i in 0...n { let t = Double(i) / Double(n); pts += [a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, pressure] }
            return pts
        case .ellipse(let e):
            let circ = Double.pi * (3 * (e.r1 + e.r2) - ((3 * e.r1 + e.r2) * (e.r1 + 3 * e.r2)).squareRoot())
            let n = max(48, min(360, Int(circ * zoom / 7)))
            return e.outline(steps: n).flatMap { [$0.x, $0.y, pressure] }
        case .curve(let c):
            let dense = c.sampled()
            var len = 0.0
            for i in 1..<dense.count { len += dense[i].dist(dense[i - 1]) }
            let n = max(8, min(600, Int(len * zoom / 3)))
            return ShapeFit.resample(dense, count: n).flatMap { [$0.x, $0.y, pressure] }
        }
    }
    var end: V2 {
        switch self {
        case .line(_, let b): return b
        case .ellipse(let e): return e.point(e.start + e.dir * (2 * .pi + 4 * .pi / 96))
        case .curve(let c): return c.end
        }
    }
}

enum ShapeFit {
    /// pts: the drawn line in canvas units. A closed loop becomes an ellipse (or a circle when nearly round),
    /// a nearly straight stroke a line, a stroke with one bend a smooth arch through its own end points.
    /// Anything else (S-curves, corners, scribbles) doesn't snap.
    static func fit(_ raw: [V2], zoom: Double = 1) -> SnappedShape? {
        let n = raw.count
        if n < 4 { return nil }
        var len = 0.0
        for i in 1..<n { len += raw[i].dist(raw[i - 1]) }
        let a = raw[0], b = raw[n - 1], gap = a.dist(b)
        guard len > 0 else { return nil }
        if gap >= len * 0.2 { return openStroke(raw, zoom: zoom) }
        let pts = resample(raw, count: 160)
        guard var e = fitEllipse(pts) ?? momentEllipse(pts) else { return .line(a, b) }
        if e.r2 / e.r1 > 0.88 { let r = (e.r1 + e.r2) / 2; e.r1 = r; e.r2 = r; e.circle = true }
        e.start = e.param(of: a)
        // drawn clockwise or anticlockwise (shoelace sign, relative to the ellipse's own frame)
        var area = 0.0
        for i in 0..<(pts.count - 1) { area += (pts[i].x - e.c.x) * (pts[i + 1].y - e.c.y) - (pts[i + 1].x - e.c.x) * (pts[i].y - e.c.y) }
        e.dir = area >= 0 ? 1 : -1
        return .ellipse(e)
    }

    /// Signed turn at each interior point of a polyline.
    private static func turning(_ q: [V2]) -> [Double] {
        guard q.count >= 3 else { return [] }
        var t: [Double] = []
        t.reserveCapacity(q.count - 2)
        for i in 1..<(q.count - 1) {
            let v1 = q[i] - q[i - 1], v2 = q[i + 1] - q[i]
            t.append(atan2(v1.x * v2.y - v1.y * v2.x, v1.dot(v2)))
        }
        return t
    }
    private static func smoothed(_ p: [V2], _ w: Int) -> [V2] {
        var out = p
        if p.count <= 2 * w { return out }
        for i in w..<(p.count - w) {
            var acc = V2(0, 0)
            for j in (i - w)...(i + w) { acc = acc + p[j] }
            out[i] = acc / Double(2 * w + 1)
        }
        return out
    }

    /// An open stroke: a line, an arch, or nothing.
    private static func openStroke(_ raw: [V2], zoom: Double) -> SnappedShape? {
        let a = raw[0], b = raw[raw.count - 1]
        let chord = a.dist(b)
        guard chord > 1e-9 else { return nil }
        let pts = resample(raw, count: 64)
        let u = (b - a) / chord
        var dev = 0.0, pos = 0.0, neg = 0.0
        for p in pts {
            let sd = (p.x - a.x) * u.y - (p.y - a.y) * u.x
            dev = max(dev, abs(sd)); pos = max(pos, sd); neg = max(neg, -sd)
        }
        if dev <= max(0.045 * chord, 2.5 / zoom) { return .line(a, b) }
        let total = abs(turning(smoothed(pts, 2)).reduce(0, +))
        // a corner: more than ~63° of turn within an eighth of the stroke
        let mid = turning(smoothed(resample(pts, count: 32), 1))
        if mid.count >= 4 {
            for i in 0...(mid.count - 4) where abs(mid[i] + mid[i + 1] + mid[i + 2] + mid[i + 3]) > 1.1 { return nil }
        }
        // bend direction on a coarse copy, so hand jitter can't look like wiggles; a real S also crosses its chord
        let coarse = Array(turning(resample(pts, count: 17)).dropFirst().dropLast())
        var P = 0.0, N = 0.0
        for t in coarse { if t > 0 { P += t } else { N -= t } }
        let crosses = min(pos, neg) > 0.25 * max(pos, neg)
        if crosses && min(P, N) > 0.15 && min(P, N) > 0.3 * max(P, N) { return nil }
        if total > 5.2 { return nil }
        guard let one = fitCubic(pts) else { return nil }
        if one.err <= 0.03 * chord && total <= 3.5 { return .curve(Curve(pts: one.c)) }
        // two segments joined smoothly in the middle
        let k = pts.count / 2
        guard var l = fitCubic(Array(pts[0...k]))?.c, var r = fitCubic(Array(pts[k...]))?.c else { return .curve(Curve(pts: one.c)) }
        let j = pts[k]
        let dl = j - l[2], dr = r[1] - j
        let ll = dl.length, lr = dr.length
        let dir = (dl.unit + dr.unit).unit
        if ll > 1e-9, lr > 1e-9, dir.length > 0.5 {
            l[2] = j - dir * ll
            r[1] = j + dir * lr
        }
        return .curve(Curve(pts: [l[0], l[1], l[2], j, r[1], r[2], r[3]]))
    }

    /// Least-squares cubic Bézier with both end points kept and both control points free,
    /// refined with a few Newton passes on the parameters. Returns the controls and the largest miss.
    static func fitCubic(_ pts: [V2]) -> (c: [V2], err: Double)? {
        let n = pts.count
        guard n >= 3 else { return nil }
        let P0 = pts[0], P3 = pts[n - 1]
        var u = [Double](repeating: 0, count: n)
        for i in 1..<n { u[i] = u[i - 1] + pts[i].dist(pts[i - 1]) }
        guard let total = u.last, total > 0 else { return nil }
        for i in 0..<n { u[i] /= total }
        var c: [V2] = [P0, P0, P3, P3]
        for _ in 0..<6 {
            var s11 = 0.0, s12 = 0.0, s22 = 0.0
            var r1 = V2(0, 0), r2 = V2(0, 0)
            for i in 0..<n {
                let t = u[i], m = 1 - t
                let b0 = m * m * m, b1 = 3 * m * m * t, b2 = 3 * m * t * t, b3 = t * t * t
                let rest = pts[i] - P0 * b0 - P3 * b3
                s11 += b1 * b1; s12 += b1 * b2; s22 += b2 * b2
                r1 = r1 + rest * b1; r2 = r2 + rest * b2
            }
            let det = s11 * s22 - s12 * s12
            if abs(det) < 1e-12 { return nil }
            let c1 = (r1 * s22 - r2 * s12) / det
            let c2 = (r2 * s11 - r1 * s12) / det
            c = [P0, c1, c2, P3]
            let cv = Curve(pts: c)
            for i in 1..<(n - 1) {
                let t = u[i], m = 1 - t
                let q = cv.point(0, t)
                let d1a = (c[1] - c[0]) * (3 * m * m)
                let d1b = (c[2] - c[1]) * (6 * m * t)
                let d1c = (c[3] - c[2]) * (3 * t * t)
                let d1 = d1a + d1b + d1c
                let d2a = (c[2] - c[1] * 2 + c[0]) * (6 * m)
                let d2b = (c[3] - c[2] * 2 + c[1]) * (6 * t)
                let d2 = d2a + d2b
                let e = q - pts[i]
                let num = e.dot(d1)
                let den = d1.dot(d1) + e.dot(d2)
                if abs(den) > 1e-12 { u[i] = clampD(t - num / den, 0, 1) }
            }
        }
        let cv = Curve(pts: c)
        var err = 0.0
        for i in 0..<n { err = max(err, cv.point(0, u[i]).dist(pts[i])) }
        return (c, err)
    }

    /// Evenly spaced along the path, so slow and fast parts of the stroke count equally.
    static func resample(_ p: [V2], count: Int) -> [V2] {
        guard p.count >= 2, count >= 2 else { return p }
        var len = 0.0
        for i in 1..<p.count { len += p[i].dist(p[i - 1]) }
        let step = len / Double(count - 1)
        guard step > 0 else { return p }
        var out: [V2] = [p[0]]
        var prev = p[0], acc = 0.0, i = 1
        while i < p.count && out.count < count {
            let d = prev.dist(p[i])
            if acc + d >= step {
                let t = (step - acc) / d
                prev = V2.lerp(prev, p[i], t)
                out.append(prev)
                acc = 0
            } else {
                acc += d; prev = p[i]; i += 1
            }
        }
        if out.count < count { out.append(p[p.count - 1]) }
        return out
    }

    /// Direct least-squares ellipse fit (Fitzgibbon, in the numerically stable form of Halír and Flusser).
    static func fitEllipse(_ pts: [V2]) -> Ellipse? {
        let n = Double(pts.count)
        var mx = 0.0, my = 0.0
        for p in pts { mx += p.x; my += p.y }
        mx /= n; my /= n
        var sc = 0.0
        for p in pts { sc += (p.x - mx) * (p.x - mx) + (p.y - my) * (p.y - my) }
        sc = (sc / n).squareRoot()
        if sc < 1e-9 { return nil }
        var S1 = [[Double]](repeating: [0, 0, 0], count: 3), S2 = S1, S3 = S1
        for p in pts {
            let x = (p.x - mx) / sc, y = (p.y - my) / sc
            let d1 = [x * x, x * y, y * y], d2 = [x, y, 1.0]
            for i in 0..<3 { for j in 0..<3 { S1[i][j] += d1[i] * d1[j]; S2[i][j] += d1[i] * d2[j]; S3[i][j] += d2[i] * d2[j] } }
        }
        guard let S3i = inv3(S3) else { return nil }
        var T = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { var v = 0.0; for k in 0..<3 { v += S3i[i][k] * S2[j][k] }; T[i][j] = -v } }
        var M = S1
        for i in 0..<3 { for j in 0..<3 { var v = 0.0; for k in 0..<3 { v += S2[i][k] * T[k][j] }; M[i][j] += v } }
        let Mp: [[Double]] = [M[2].map { $0 / 2 }, M[1].map { -$0 }, M[0].map { $0 / 2 }]
        var best: [Double]? = nil, bestCond = 0.0
        for l in realEigen3(Mp) {
            guard let v = nullVector(Mp, l) else { continue }
            let cond = 4 * v[0] * v[2] - v[1] * v[1]
            if cond > bestCond { bestCond = cond; best = v }
        }
        guard let a1 = best else { return nil }
        var a2 = [0.0, 0.0, 0.0]
        for i in 0..<3 { for k in 0..<3 { a2[i] += T[i][k] * a1[k] } }
        let A = a1[0], B = a1[1], C = a1[2], D = a2[0], E = a2[1], F = a2[2]
        let den = 4 * A * C - B * B
        if abs(den) < 1e-12 { return nil }
        let x0 = (B * E - 2 * C * D) / den, y0 = (B * D - 2 * A * E) / den
        let F0 = F + (D * x0 + E * y0) / 2
        let t = (A + C) / 2, dd = (((A - C) / 2) * ((A - C) / 2) + (B / 2) * (B / 2)).squareRoot()
        let m1 = t - dd, m2 = t + dd
        guard m1 != 0, m2 != 0, -F0 / m1 > 0, -F0 / m2 > 0 else { return nil }
        let r1 = (-F0 / m1).squareRoot() * sc, r2 = (-F0 / m2).squareRoot() * sc
        let ang: Double = abs(B) > 1e-12 ? atan2(m1 - A, B / 2) : (A <= C ? 0 : .pi / 2)
        // reject wild fits to partial loops: the ellipse must be about the size of what was drawn
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let span = max(maxX - minX, maxY - minY)
        guard r1.isFinite, r2.isFinite, r1 < span * 1.2, r2 > span * 0.02 else { return nil }
        return Ellipse(c: V2(x0 * sc + mx, y0 * sc + my), r1: r1, r2: r2, angle: ang)
    }

    /// Fallback: ellipse from the second moments of the points.
    static func momentEllipse(_ pts: [V2]) -> Ellipse? {
        let n = Double(pts.count)
        var cx = 0.0, cy = 0.0
        for p in pts { cx += p.x; cy += p.y }
        cx /= n; cy /= n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts { let dx = p.x - cx, dy = p.y - cy; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
        sxx /= n; syy /= n; sxy /= n
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let disc = max(0, tr * tr / 4 - det).squareRoot()
        let l1 = tr / 2 + disc, l2 = max(0, tr / 2 - disc)
        let r1 = (2 * l1).squareRoot(), r2 = (2 * l2).squareRoot()
        guard r1 > 0 else { return nil }
        return Ellipse(c: V2(cx, cy), r1: r1, r2: max(r2, r1 * 0.02), angle: atan2(l1 - sxx, sxy == 0 ? 1e-9 : sxy))
    }

    private static func inv3(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        if abs(det) < 1e-18 { return nil }
        let D = -(b * i - c * h), E = a * i - c * g, F = -(a * h - b * g), G = b * f - c * e, H = -(a * f - c * d), I = a * e - b * d
        return [[A / det, D / det, G / det], [B / det, E / det, H / det], [C / det, F / det, I / det]]
    }

    /// Real eigenvalues of a 3×3 matrix (roots of its characteristic cubic).
    private static func realEigen3(_ M: [[Double]]) -> [Double] {
        let tr = M[0][0] + M[1][1] + M[2][2]
        let c1 = (M[0][0] * M[1][1] - M[0][1] * M[1][0]) + (M[0][0] * M[2][2] - M[0][2] * M[2][0]) + (M[1][1] * M[2][2] - M[1][2] * M[2][1])
        let a = M[0][0], b = M[0][1], c = M[0][2], d = M[1][0], e = M[1][1], f = M[1][2], g = M[2][0], h = M[2][1], i = M[2][2]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        let A = -tr, B = c1, C = -det
        let p = B - A * A / 3
        let q = 2 * A * A * A / 27 - A * B / 3 + C
        let disc = (q / 2) * (q / 2) + (p / 3) * (p / 3) * (p / 3)
        var roots: [Double] = []
        if disc > 1e-30 {
            let s = disc.squareRoot()
            roots = [cbrt(-q / 2 + s) + cbrt(-q / 2 - s)]
        } else {
            let r = max(0, -p / 3).squareRoot()
            if r < 1e-30 { roots = [0] } else {
                let phi = acos(clampD((-q / 2) / (r * r * r), -1, 1))
                roots = (0..<3).map { 2 * r * cos((phi + 2 * .pi * Double($0)) / 3) }
            }
        }
        return roots.map { $0 - A / 3 }
    }

    private static func nullVector(_ M: [[Double]], _ l: Double) -> [Double]? {
        var R = M
        for k in 0..<3 { R[k][k] -= l }
        var best: [Double]? = nil, bn = 0.0
        for (u, v) in [(0, 1), (0, 2), (1, 2)] {
            let a = R[u], b = R[v]
            let cr = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
            let nrm = (cr[0] * cr[0] + cr[1] * cr[1] + cr[2] * cr[2]).squareRoot()
            if nrm > bn { bn = nrm; best = cr }
        }
        guard let v = best, bn > 1e-30 else { return nil }
        return v.map { $0 / bn }
    }
}

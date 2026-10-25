import Foundation

/// One raw or processed input sample. x/y in screen points, p = pressure 0…1, t = milliseconds.
struct Sample {
    var x: Double
    var y: Double
    var p: Double
    var t: Double
}

/// Effective smoothing for one stroke (brush settings combined with the global ones).
struct SmoothParams {
    var mf: Double = 0       // motion filtering amount
    var mfx: Double = 0.5    // motion filtering expression
    var st: Double = 0       // stabilisation amount
    var sts: Double = 0.5    // stabilisation speed influence
    var sl: Double = 0       // streamline amount
    var slp: Double = 0      // streamline pressure
    var rope: Double = 0     // rope length in screen points, 0 = off
    var catchUp: Bool = false
}

private func median(_ a: [Double]) -> Double {
    let s = a.sorted(), n = s.count
    if n == 0 { return 0 }
    return n % 2 == 1 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Raw pencil samples pass through, in order:
/// 1. Motion filtering – sliding median over a short time window: removes the extremes of wobble rather than averaging them.
/// 2. Stabilisation    – moving average over a stretch of path that grows with drawing speed.
/// 3. Streamline       – the line eases toward the pencil with a time lag; a separate lag for pressure.
/// 4. Rope             – the line only moves when the pencil pulls a string of fixed length taut.
/// A value type, so a copy can be pushed ahead with predicted touches without disturbing the real stroke.
struct Smoother {
    let o: SmoothParams
    private var mfBuf: [Sample] = []
    private var stBuf: [Sample] = []
    private var stLen = 0.0
    private var speed = 0.0
    private var prev: Sample? = nil
    private var sl: Sample? = nil
    private var slTarget: Sample? = nil
    private(set) var tip: Sample? = nil
    private(set) var pen: Sample? = nil
    private(set) var last: Sample? = nil

    init(_ o: SmoothParams) { self.o = o }

    // MARK: motion filtering
    private mutating func mfPush(_ q: Sample, _ out: inout [Sample]) {
        if o.mf < 0.01 { out.append(q); return }
        let window = 12 + o.mf * 110
        mfBuf.append(q)
        while mfBuf.count > 2 && q.t - mfBuf[0].t > window { mfBuf.removeFirst() }
        out.append(mfOut())
    }
    private func mfOut() -> Sample {
        let n = mfBuf.count
        if n == 1 { return mfBuf[0] }
        let mx = median(mfBuf.map { $0.x }), my = median(mfBuf.map { $0.y })
        let c = mfBuf[(n - 1) / 2]
        let e = o.mfx * (1 - 0.6 * o.mf)
        return Sample(x: mx + e * (c.x - mx), y: my + e * (c.y - my), p: c.p, t: c.t)
    }
    private mutating func mfFlush(_ out: inout [Sample]) {
        if o.mf < 0.01 { return }
        while mfBuf.count > 1 { mfBuf.removeFirst(); out.append(mfOut()) }
    }

    // MARK: stabilisation
    private mutating func stPush(_ q: Sample, _ out: inout [Sample]) {
        if let pv = prev {
            let dt = max(1, q.t - pv.t)
            let vi = ((q.x - pv.x) * (q.x - pv.x) + (q.y - pv.y) * (q.y - pv.y)).squareRoot() / dt
            speed += (vi - speed) * 0.25
        }
        prev = q
        if o.st < 0.01 { out.append(q); return }
        let k = clampD(speed / 0.6, 0.25, 3)
        let reach = o.st * 70 * (1 + o.sts * (k - 1))
        if let l = stBuf.last { stLen += ((q.x - l.x) * (q.x - l.x) + (q.y - l.y) * (q.y - l.y)).squareRoot() }
        stBuf.append(q)
        while stBuf.count > 1 && stLen > reach {
            let a = stBuf.removeFirst()
            stLen -= ((stBuf[0].x - a.x) * (stBuf[0].x - a.x) + (stBuf[0].y - a.y) * (stBuf[0].y - a.y)).squareRoot()
        }
        out.append(stOut())
    }
    private func stOut() -> Sample {
        var x = 0.0, y = 0.0
        for s in stBuf { x += s.x; y += s.y }
        let l = stBuf[stBuf.count - 1], n = Double(stBuf.count)
        return Sample(x: x / n, y: y / n, p: l.p, t: l.t)
    }
    private mutating func stFlush(_ out: inout [Sample]) {
        if o.st < 0.01 { return }
        while stBuf.count > 1 {
            let a = stBuf.removeFirst()
            stLen -= ((stBuf[0].x - a.x) * (stBuf[0].x - a.x) + (stBuf[0].y - a.y) * (stBuf[0].y - a.y)).squareRoot()
            out.append(stOut())
        }
    }

    // MARK: streamline
    private mutating func slPush(_ q: Sample, _ out: inout [Sample]) {
        guard var s = sl else { sl = q; out.append(q); return }
        let dt = max(1, q.t - s.t)
        let tp = pow(o.sl, 1.5) * 230, tpr = o.slp * 260
        let kp = tp < 1 ? 1 : 1 - exp(-dt / tp)
        let kr = tpr < 1 ? 1 : 1 - exp(-dt / tpr)
        s.x += (q.x - s.x) * kp
        s.y += (q.y - s.y) * kp
        s.p += (q.p - s.p) * kr
        s.t = q.t
        sl = s
        slTarget = q
        out.append(s)
    }
    private mutating func slFlush(_ out: inout [Sample]) {
        guard let s = sl, let q = slTarget, o.sl >= 0.01 else { return }
        let d = ((q.x - s.x) * (q.x - s.x) + (q.y - s.y) * (q.y - s.y)).squareRoot()
        let n = min(24, Int((d / 3).rounded(.up)))
        if n < 1 { return }
        for i in 1...n {
            let t = Double(i) / Double(n), e = 1 - (1 - t) * (1 - t)
            out.append(Sample(x: s.x + (q.x - s.x) * e, y: s.y + (q.y - s.y) * e, p: s.p + (q.p - s.p) * t, t: q.t))
        }
    }

    // MARK: rope
    private mutating func ropePush(_ q: Sample, _ out: inout [Sample]) {
        guard let tp = tip else { tip = q; out.append(q); return }
        pen = q
        let L = o.rope
        if L < 0.5 { tip = q; out.append(q); return }
        let dx = q.x - tp.x, dy = q.y - tp.y, d = (dx * dx + dy * dy).squareRoot()
        if d > L {
            let k = (d - L) / d
            let nt = Sample(x: tp.x + dx * k, y: tp.y + dy * k, p: q.p, t: q.t)
            tip = nt
            out.append(nt)
        }
    }
    private mutating func ropeFlush(_ out: inout [Sample]) {
        guard o.catchUp, o.rope >= 0.5, let t0 = tip, let q = pen else { return }
        let d = ((q.x - t0.x) * (q.x - t0.x) + (q.y - t0.y) * (q.y - t0.y)).squareRoot()
        let n = min(40, Int((d / 3).rounded(.up)))
        if n < 1 { return }
        for i in 1...n {
            let t = Double(i) / Double(n)
            out.append(Sample(x: t0.x + (q.x - t0.x) * t, y: t0.y + (q.y - t0.y) * t, p: t0.p * (1 - t * 0.5), t: q.t))
        }
    }

    // MARK: chain
    mutating func push(_ s: Sample) -> [Sample] {
        var a: [Sample] = [], b: [Sample] = [], c: [Sample] = [], d: [Sample] = []
        mfPush(s, &a)
        for q in a { stPush(q, &b) }
        for q in b { slPush(q, &c) }
        for q in c { ropePush(q, &d) }
        if let l = d.last { last = l }
        return d
    }

    mutating func flush() -> [Sample] {
        var m: [Sample] = []
        mfFlush(&m)
        var s: [Sample] = []
        for q in m { stPush(q, &s) }
        stFlush(&s)
        var l: [Sample] = []
        for q in s { slPush(q, &l) }
        slFlush(&l)
        var r: [Sample] = []
        for q in l { ropePush(q, &r) }
        ropeFlush(&r)
        if let x = r.last { last = x }
        return r
    }

    /// Where the drawn line currently ends.
    var head: Sample? { tip ?? last }
}

/// Centripetal Catmull–Rom through the smoothed points so fast strokes stay curved rather than faceted.
/// Output is a flat [x, y, p, …] array in canvas units.
struct CurveEmitter {
    private var q: [(Double, Double, Double)] = []
    private(set) var out: [Double] = []
    let minDist: Double
    let spacing: Double

    init(minDist: Double, spacing: Double) { self.minDist = minDist; self.spacing = spacing }

    mutating func add(_ x: Double, _ y: Double, _ p: Double) {
        if let l = q.last {
            let dx = x - l.0, dy = y - l.1
            if (dx * dx + dy * dy).squareRoot() < minDist {
                q[q.count - 1].2 = max(l.2, p)
                return
            }
        }
        q.append((x, y, p))
        if q.count == 1 { out.append(contentsOf: [x, y, p]); return }
        let n = q.count
        if n >= 3 { seg(n >= 4 ? q[n - 4] : q[n - 3], q[n - 3], q[n - 2], q[n - 1]) }
        if q.count > 4 { q.removeFirst() }
    }

    private mutating func seg(_ p0: (Double, Double, Double), _ p1: (Double, Double, Double), _ p2: (Double, Double, Double), _ p3: (Double, Double, Double)) {
        func dist(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot() }
        let d = dist(p1, p2)
        let k = max(1, min(40, Int((d / spacing).rounded(.up))))
        func kn(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { max(1e-4, dist(a, b).squareRoot()) }
        let t0 = 0.0, t1 = t0 + kn(p0, p1), t2 = t1 + kn(p1, p2), t3 = t2 + kn(p2, p3)
        func L(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ ta: Double, _ tb: Double, _ u: Double) -> (Double, Double) {
            let w = (tb - u) / (tb - ta), v = (u - ta) / (tb - ta)
            return (ax * w + bx * v, ay * w + by * v)
        }
        for i in 1...k {
            let t = Double(i) / Double(k), u = t1 + (t2 - t1) * t
            let a1 = L(p0.0, p0.1, p1.0, p1.1, t0, t1, u)
            let a2 = L(p1.0, p1.1, p2.0, p2.1, t1, t2, u)
            let a3 = L(p2.0, p2.1, p3.0, p3.1, t2, t3, u)
            let b1 = L(a1.0, a1.1, a2.0, a2.1, t0, t2, u)
            let b2 = L(a2.0, a2.1, a3.0, a3.1, t1, t3, u)
            let c = L(b1.0, b1.1, b2.0, b2.1, t1, t2, u)
            out.append(contentsOf: [c.0, c.1, p1.2 + (p2.2 - p1.2) * t])
        }
    }

    mutating func finish() -> [Double] {
        let n = q.count
        if n >= 2 { seg(n >= 3 ? q[n - 3] : q[n - 2], q[n - 2], q[n - 1], q[n - 1]) }
        q = []
        return out
    }

    /// Committed points plus a straight run to the newest control point (for drawing while the pencil is down).
    func live() -> [Double] {
        let n = q.count
        guard n >= 2 else { return out }
        return out + [q[n - 1].0, q[n - 1].1, q[n - 1].2]
    }
}

// MARK: - Pressure curve (monotone cubic through nodes)

enum PressureCurve {
    static func eval(_ nodes: [[Double]], _ xIn: Double) -> Double {
        let n = nodes.count
        let x = clampD(xIn, 0, 1)
        if n < 2 { return x }
        if x <= nodes[0][0] { return nodes[0][1] }
        if x >= nodes[n - 1][0] { return nodes[n - 1][1] }
        var dx = [Double](repeating: 0, count: n - 1), d = [Double](repeating: 0, count: n - 1), m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            dx[i] = nodes[i + 1][0] - nodes[i][0]
            if dx[i] == 0 { dx[i] = 1e-6 }
            d[i] = (nodes[i + 1][1] - nodes[i][1]) / dx[i]
        }
        m[0] = d[0]; m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], h = a * a + b * b
            if h > 9 { let t = 3 / h.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var i = 0
        while i < n - 2 && x > nodes[i + 1][0] { i += 1 }
        let h = dx[i], t = (x - nodes[i][0]) / h, t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * nodes[i][1] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * nodes[i + 1][1] + (t3 - t2) * h * m[i + 1]
        return clampD(y, 0, 1)
    }
}

// MARK: - Hold to snap

enum SnappedShape {
    case line(V2, V2)
    case ellipse([V2], circle: Bool)
}

enum ShapeFit {
    /// raw: points in canvas units.
    static func fit(_ raw: [V2]) -> SnappedShape? {
        let n = raw.count
        if n < 4 { return nil }
        var len = 0.0
        for i in 1..<n { len += raw[i].dist(raw[i - 1]) }
        let a = raw[0], b = raw[n - 1], gap = a.dist(b)
        if len > 0 && gap < len * 0.2 {
            var cx = 0.0, cy = 0.0
            for p in raw { cx += p.x; cy += p.y }
            cx /= Double(n); cy /= Double(n)
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in raw { let dx = p.x - cx, dy = p.y - cy; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
            sxx /= Double(n); syy /= Double(n); sxy /= Double(n)
            let tr = sxx + syy, det = sxx * syy - sxy * sxy
            let disc = max(0, tr * tr / 4 - det).squareRoot()
            let l1 = tr / 2 + disc, l2 = max(0, tr / 2 - disc)
            let ang = atan2(l1 - sxx, sxy == 0 ? 1e-9 : sxy)
            var r1 = (2 * l1).squareRoot(), r2 = (2 * l2).squareRoot()
            let circle = r1 > 0 && r2 / r1 > 0.88
            if circle { r1 = (r1 + r2) / 2; r2 = r1 }
            let ca = cos(ang), sa = sin(ang)
            let start = atan2(-(a.x - cx) * sa + (a.y - cy) * ca, (a.x - cx) * ca + (a.y - cy) * sa)
            var pts: [V2] = []
            let N = 96
            for i in 0...(N + 2) {
                let t = start + Double(i) / Double(N) * Double.pi * 2
                let ex = cos(t) * r1, ey = sin(t) * r2
                pts.append(V2(cx + ex * ca - ey * sa, cy + ex * sa + ey * ca))
            }
            return .ellipse(pts, circle: circle)
        }
        return .line(a, b)
    }
}

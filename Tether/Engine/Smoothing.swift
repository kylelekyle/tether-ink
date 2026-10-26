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
    var mfx: Double = 0.5    // motion filtering expression (keeps fast flicks crisp; never adds wobble back)
    var st: Double = 0       // stabilisation amount
    var sts: Double = 0.5    // stabilisation speed influence (more smoothing when drawing fast)
    var sl: Double = 0       // streamline amount
    var slp: Double = 0      // streamline pressure
    var rope: Double = 0     // rope length in screen points, 0 = off
    var catchUp: Bool = false  // on lift, run every stage on to the pencil

    /// Light enough that predicted touches help rather than make the line's head flicker.
    var light: Bool { mf < 0.05 && st < 0.05 && sl < 0.05 && rope < 0.5 }
    /// Something lags behind the pencil, so the line should keep gliding while the pencil rests.
    var lags: Bool { mf >= 0.01 || st >= 0.01 || sl >= 0.01 || slp >= 0.01 }
}

/// Raw pencil samples pass through, in order:
/// 1. Motion filtering – Gaussian-weighted average over a short time window: removes hand tremor (8–12 Hz) cleanly.
/// 2. Stabilisation    – triangle-weighted average over a stretch of path (arc length), wider when drawing fast.
/// 3. Streamline       – the line eases toward the pencil through two cascaded lags (critically damped, no overshoot);
///                       a separate lag for pressure.
/// 4. Rope             – the line only moves when the pencil pulls a string of fixed length taut.
/// With catch-up on, every stage runs on smoothly to the pencil when it lifts; otherwise the line stays as drawn.
/// A value type, so a copy can be pushed ahead with predicted touches without disturbing the real stroke.
struct Smoother {
    let o: SmoothParams
    // motion filtering
    private let mfW: Double
    private var mfCur: Double
    private var mfBuf: [Sample] = []
    private var mfPrev: Sample? = nil
    private var mfSpeed = 0.0
    // stabilisation
    static let stStep = 1.5
    private var stPts: [Sample] = []
    private var stLast: Sample? = nil
    private var stHead: Sample? = nil
    private var stOutLast: Sample? = nil
    private var stN = 1.0
    private var stMoveT = 0.0
    private var stPrevT = 0.0
    private var speed = 0.0
    private var prev: Sample? = nil
    // streamline
    private var slA: Sample? = nil
    private var slB: Sample? = nil
    private var slTarget: Sample? = nil
    // rope
    private(set) var tip: Sample? = nil
    private(set) var pen: Sample? = nil
    private(set) var last: Sample? = nil
    private var lastT = -Double.greatestFiniteMagnitude

    init(_ o: SmoothParams) {
        self.o = o
        let w: Double = 16 + pow(o.mf, 1.2) * 150
        mfW = w
        mfCur = w
    }

    // MARK: motion filtering
    private func mfEval(_ tc: Double, _ sig: Double) -> Sample {
        var sw = 0.0, sx = 0.0, sy = 0.0, sp = 0.0
        let inv = 1 / (2 * sig * sig)
        for q in mfBuf {
            let d = q.t - tc
            let w = exp(-d * d * inv)
            sw += w; sx += w * q.x; sy += w * q.y; sp += w * q.p
        }
        if sw < 1e-12 { return tc < mfBuf[0].t ? mfBuf[0] : mfBuf[mfBuf.count - 1] }
        return Sample(x: sx / sw, y: sy / sw, p: sp / sw, t: 0)
    }
    private mutating func mfPush(_ q: Sample, _ out: inout [Sample]) {
        if o.mf < 0.01 { out.append(q); return }
        if let pv = mfPrev {
            let dt = max(1, q.t - pv.t)
            let vi = ((q.x - pv.x) * (q.x - pv.x) + (q.y - pv.y) * (q.y - pv.y)).squareRoot() / dt
            mfSpeed += (vi - mfSpeed) * min(1, dt / 80)
        }
        mfPrev = q
        mfBuf.append(q)
        while mfBuf.count > 2 && q.t - mfBuf[0].t > mfW { mfBuf.removeFirst() }
        let fast: Double = min(1, mfSpeed / 1.2)
        mfCur = mfW * (1 - o.mfx * 0.75 * fast)
        var r = mfEval(q.t - mfCur / 2, mfCur / 5)
        r.t = q.t
        out.append(r)
    }
    private mutating func mfFlush(_ out: inout [Sample]) {
        guard o.mf >= 0.01, let end = mfBuf.last else { return }
        let tc0 = end.t - mfCur / 2, s0 = mfCur / 5
        let sEnd: Double = 6 * max(0, 1 - mfSpeed / 0.5) + 0.5   // slow lift: end on the steadied point, fast flick: on the pencil
        for i in 1...10 {
            let f = Double(i) / 10
            var r = mfEval(tc0 + (end.t - tc0) * f, s0 + (sEnd - s0) * f)
            r.t = end.t
            out.append(r)
        }
    }

    // MARK: stabilisation
    private func stOut(_ n: Double, t: Double) -> Sample {
        let m = stPts.count
        let nn = max(1, min(Double(m), n))
        let c = (nn - 1) / 2, half = nn / 2 + 0.5
        var sw = 0.0, sx = 0.0, sy = 0.0, sp = 0.0
        let top = min(m - 1, Int(nn.rounded(.up)))
        for j in 0...top {
            let w = half - abs(Double(j) - c)
            if w <= 0 { continue }
            let q = stPts[m - 1 - j]
            sw += w; sx += w * q.x; sy += w * q.y; sp += w * q.p
        }
        return Sample(x: sx / sw, y: sy / sw, p: sp / sw, t: t)
    }
    private mutating func stPush(_ q: Sample, _ out: inout [Sample]) {
        if let pv = prev {
            let dt = max(1, q.t - pv.t)
            let vi = ((q.x - pv.x) * (q.x - pv.x) + (q.y - pv.y) * (q.y - pv.y)).squareRoot() / dt
            speed += (vi - speed) * min(1, dt / 60)
        }
        prev = q
        if o.st < 0.01 { out.append(q); return }
        stHead = q
        guard var a = stLast else {
            stLast = q; stPts = [q]; stN = 1; stOutLast = q; stMoveT = q.t; stPrevT = q.t
            out.append(q)
            return
        }
        let h = Smoother.stStep
        let k = clampD(speed / 0.5, 1, 3)
        let reach: Double = pow(o.st, 1.2) * 90 * (1 + o.sts * (k - 1))
        let target = max(1, reach / h)
        var d = ((q.x - a.x) * (q.x - a.x) + (q.y - a.y) * (q.y - a.y)).squareRoot()
        var moved = false
        while d >= h {
            let f = h / d
            a = Sample(x: a.x + (q.x - a.x) * f, y: a.y + (q.y - a.y) * f, p: a.p + (q.p - a.p) * f, t: a.t + (q.t - a.t) * f)
            stPts.append(a)
            d -= h
            stN += (target - stN) * 0.08
            moved = true
        }
        stLast = a
        if moved {
            stMoveT = q.t
        } else if q.t - stMoveT > 40 && stN > 1.001 {
            // the pencil is resting: let the line glide onto it rather than stopping short
            stN = max(1, stN * exp(-max(0, q.t - stPrevT) / 120))
            stOutLast = stOut(stN, t: q.t)
        }
        stPrevT = q.t
        if moved {
            stN = min(stN, Double(stPts.count))
            let keep = Int(stN) + 2
            if stPts.count > keep + 32 { stPts.removeFirst(stPts.count - keep) }
            stOutLast = stOut(stN, t: q.t)
        }
        if var r = stOutLast { r.t = q.t; out.append(r) }
    }
    private mutating func stFlush(_ out: inout [Sample]) {
        guard o.st >= 0.01, let a = stLast, let q = stHead else { return }
        if (q.x - a.x) * (q.x - a.x) + (q.y - a.y) * (q.y - a.y) > 1e-12 { stPts.append(q); stLast = q }
        let n0 = min(stN, Double(stPts.count))
        let steps = max(1, min(16, Int(n0)))
        for i in 1...steps {
            let n: Double = i == steps ? 1 : max(1, n0 * (1 - Double(i) / Double(steps)))
            out.append(stOut(n, t: q.t))
        }
    }

    // MARK: streamline
    /// Lag per stage (two stages ≈ 300 ms total at 100%) and the pressure lag, in ms.
    private var slTaus: (Double, Double) { (pow(o.sl, 1.5) * 150, o.slp * 260) }
    private mutating func slStep(_ q: Sample, _ dt: Double) {
        guard var a = slA, var b = slB else { return }
        let (tp, tpr) = slTaus
        let k: Double = tp < 0.5 ? 1 : 1 - exp(-dt / tp)
        let kr: Double = tpr < 1 ? 1 : 1 - exp(-dt / tpr)
        a.x += (q.x - a.x) * k; a.y += (q.y - a.y) * k
        b.x += (a.x - b.x) * k; b.y += (a.y - b.y) * k
        b.p += (q.p - b.p) * kr
        b.t = q.t
        slA = a; slB = b
    }
    private mutating func slPush(_ q: Sample, _ out: inout [Sample]) {
        guard let b = slB else { slA = q; slB = q; slTarget = q; out.append(q); return }
        slTarget = q
        slStep(q, max(0.5, q.t - b.t))
        if let r = slB { out.append(r) }
    }
    private mutating func slFlush(_ out: inout [Sample]) {
        guard o.sl >= 0.01, let q = slTarget, let a = slA, let b = slB else { return }
        let d = ((q.x - b.x) * (q.x - b.x) + (q.y - b.y) * (q.y - b.y)).squareRoot() + ((q.x - a.x) * (q.x - a.x) + (q.y - a.y) * (q.y - a.y)).squareRoot()
        if d < 0.05 { return }
        let n = max(4, min(40, Int(d / 2) + 1))
        let dt = slTaus.0 * 7 / Double(n)
        var t = b.t
        for _ in 0..<n {
            t += dt
            slStep(Sample(x: q.x, y: q.y, p: q.p, t: t), dt)
            if var r = slB { r.t = q.t; out.append(r) }
        }
        out.append(q)
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
        guard o.rope >= 0.5, let t0 = tip, let q = pen else { return }
        let d = ((q.x - t0.x) * (q.x - t0.x) + (q.y - t0.y) * (q.y - t0.y)).squareRoot()
        let n = min(40, Int((d / 3).rounded(.up)))
        if n < 1 { return }
        for i in 1...n {
            let t = Double(i) / Double(n)
            out.append(Sample(x: t0.x + (q.x - t0.x) * t, y: t0.y + (q.y - t0.y) * t, p: t0.p * (1 - t * 0.5), t: q.t))
        }
    }

    // MARK: chain
    mutating func push(_ s0: Sample) -> [Sample] {
        var s = s0
        if s.t < lastT { s.t = lastT }
        lastT = s.t
        var a: [Sample] = [], b: [Sample] = [], c: [Sample] = [], d: [Sample] = []
        mfPush(s, &a)
        for q in a { stPush(q, &b) }
        for q in b { slPush(q, &c) }
        for q in c { ropePush(q, &d) }
        if let l = d.last { last = l }
        return d
    }

    /// End of stroke. Without catch-up nothing is added: the line stays exactly as it was drawn.
    mutating func flush() -> [Sample] {
        guard o.catchUp else { return [] }
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

enum SnappedShape: Equatable {
    case line(V2, V2)
    case ellipse(Ellipse)

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
        }
    }
    var end: V2 {
        switch self {
        case .line(_, let b): return b
        case .ellipse(let e): return e.point(e.start + e.dir * (2 * .pi + 4 * .pi / 96))
        }
    }
}

enum ShapeFit {
    /// pts: the drawn line in canvas units. A closed loop becomes an ellipse (or a circle when nearly round), anything else a line.
    static func fit(_ raw: [V2]) -> SnappedShape? {
        let n = raw.count
        if n < 4 { return nil }
        var len = 0.0
        for i in 1..<n { len += raw[i].dist(raw[i - 1]) }
        let a = raw[0], b = raw[n - 1], gap = a.dist(b)
        guard len > 0 else { return nil }
        if gap >= len * 0.2 { return .line(a, b) }
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

    /// Evenly spaced along the path, so slow and fast parts of the stroke count equally.
    static func resample(_ p: [V2], count: Int) -> [V2] {
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

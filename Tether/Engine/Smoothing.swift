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
    var mfx: Double = 0      // motion filtering expression: lets the filtering ease off as the pencil speeds up (0 = same at every speed)
    var st: Double = 0       // stabilisation amount
    var sts: Double = 0.5    // stabilisation speed: faster strokes get a longer stretch
    var sl: Double = 0       // streamline amount
    var slp: Double = 0      // streamline pressure: how far the pencil travels before pressure fully changes
    var catchUp: Bool = false  // on lift, run every stage on to the pencil

    /// Predicted touches can be drawn without the line's head flickering (stabilisation's glide can make it jump).
    var light: Bool { st < 0.05 }
    /// Something lags behind the pencil, so the line should keep gliding while the pencil rests.
    var lags: Bool { mf >= 0.01 || st >= 0.01 || sl >= 0.01 }
}

/// Raw pencil samples pass through, in order:
/// 1. Motion filtering – two-stage low-pass in time: removes tremor the same way at every speed
///                       (Expression can let it ease off for quick strokes, One Euro style).
/// 2. Stabilisation    – triangle-weighted average over a stretch of path (arc length); faster strokes get a longer stretch.
/// 3. Streamline       – the line eases toward the pencil through two cascaded lags (critically damped, no overshoot),
///                       with the same time constant at every speed.
/// With catch-up on, every stage runs on smoothly to the pencil when it lifts; otherwise the line stays as drawn.
/// Every stage keeps a small, fixed amount of state, so a copy can be pushed ahead with predicted touches cheaply.
struct Smoother {
    let o: SmoothParams
    // motion filtering
    private let mfMin: Double        // cutoff (Hz): 12 Hz at 0%, 2 Hz at 100%
    private var mfPrev: Sample? = nil
    private var mfA = V2(0, 0)
    private var mfB = V2(0, 0)
    private var mfV = V2(0, 0)       // smoothed velocity, pt/ms
    // stabilisation
    static let stStep = 1.5
    private var stPts: [V2] = []
    private var stLast: V2? = nil
    private var stHead: Sample? = nil
    private var stOutLast: V2? = nil
    private var stN = 1.0
    private var stMoveT = 0.0
    private var stPrevT = 0.0
    private var speed = 0.0          // pt/ms, smoothed
    private var prev: Sample? = nil
    // streamline
    private var slA: V2? = nil
    private var slB: V2? = nil
    private var slT = 0.0
    private var slTarget: Sample? = nil
    private var lastT = -Double.greatestFiniteMagnitude

    init(_ o: SmoothParams) {
        self.o = o
        mfMin = 12 * pow(2.0 / 12.0, o.mf)
    }

    /// Low-pass blend factor for a cutoff (Hz) over a time step (ms).
    private static func alpha(_ hz: Double, _ dt: Double) -> Double {
        let tau: Double = 1000 / (2 * Double.pi * hz)
        return 1 / (1 + tau / dt)
    }

    // MARK: motion filtering
    private mutating func mfPush(_ q: Sample) -> Sample {
        if o.mf < 0.01 { return q }
        guard let pv = mfPrev else {
            mfPrev = q; mfA = V2(q.x, q.y); mfB = mfA
            return q
        }
        let dt = max(0.5, q.t - pv.t)
        let raw = V2((q.x - pv.x) / dt, (q.y - pv.y) / dt)
        mfV = mfV + (raw - mfV) * Smoother.alpha(5, dt)
        let r: Double = o.mfx * mfV.length * 1000 / 120     // with Expression at 0 the cutoff never moves
        let a = Smoother.alpha(mfMin * (1 + r * r), dt)
        let target = V2(q.x, q.y)
        mfA = mfA + (target - mfA) * a
        mfB = mfB + (mfA - mfB) * a
        mfPrev = q
        return Sample(x: mfB.x, y: mfB.y, p: q.p, t: q.t)
    }
    private mutating func mfFlush(_ out: inout [Sample]) {
        guard o.mf >= 0.01, let end = mfPrev else { return }
        let from = mfB
        for i in 1...10 {
            let f = Double(i) / 10
            let e: Double = 1 - (1 - f) * (1 - f)
            out.append(Sample(x: from.x + (end.x - from.x) * e, y: from.y + (end.y - from.y) * e, p: end.p, t: end.t))
        }
    }

    // MARK: stabilisation
    private func stOut(_ n: Double) -> V2 {
        let m = stPts.count
        let nn = max(1, min(Double(m), n))
        let c = (nn - 1) / 2, half = nn / 2 + 0.5
        var sw = 0.0, sx = 0.0, sy = 0.0
        let top = min(m - 1, Int(nn.rounded(.up)))
        for j in 0...top {
            let w = half - abs(Double(j) - c)
            if w <= 0 { continue }
            let q = stPts[m - 1 - j]
            sw += w; sx += w * q.x; sy += w * q.y
        }
        return V2(sx / sw, sy / sw)
    }
    private mutating func stPush(_ q: Sample, _ out: inout [Sample]) {
        if let pv = prev {
            let dt = max(1, q.t - pv.t)
            let vi = V2(q.x - pv.x, q.y - pv.y).length / dt
            speed += (vi - speed) * min(1, dt / 40)
        }
        prev = q
        if o.st < 0.01 { out.append(q); return }
        stHead = q
        guard var a = stLast else {
            let p0 = V2(q.x, q.y)
            stLast = p0; stPts = [p0]; stN = 1; stOutLast = p0; stMoveT = q.t; stPrevT = q.t
            out.append(q)
            return
        }
        let h = Smoother.stStep
        let k = clampD(speed / 0.5, 1, 3)                        // faster strokes get a longer stretch
        let reach: Double = pow(o.st, 1.2) * 40 * (1 + o.sts * (k - 1))
        let target = max(1, reach / h)
        let qv = V2(q.x, q.y)
        var d = a.dist(qv)
        var moved = false
        while d >= h {
            a = a + (qv - a) * (h / d)
            stPts.append(a)
            d -= h
            stN += (target - stN) * 0.25
            moved = true
        }
        stLast = a
        if moved {
            stMoveT = q.t
        } else if q.t - stMoveT > 30 && stN > 1.001 {
            // the pencil is resting: let the line glide onto it rather than stopping short
            stN = max(1, stN * exp(-max(0, q.t - stPrevT) / 80))
            stOutLast = stOut(stN)
        }
        stPrevT = q.t
        if moved {
            stN = min(stN, Double(stPts.count))
            let keep = Int(stN) + 2
            if stPts.count > keep + 32 { stPts.removeFirst(stPts.count - keep) }
            stOutLast = stOut(stN)
        }
        if let r = stOutLast { out.append(Sample(x: r.x, y: r.y, p: q.p, t: q.t)) }
    }
    private mutating func stFlush(_ out: inout [Sample]) {
        guard o.st >= 0.01, let a = stLast, let q = stHead else { return }
        let qv = V2(q.x, q.y)
        if a.dist2(qv) > 1e-12 { stPts.append(qv); stLast = qv }
        let n0 = min(stN, Double(stPts.count))
        let steps = max(1, min(16, Int(n0)))
        for i in 1...steps {
            let n: Double = i == steps ? 1 : max(1, n0 * (1 - Double(i) / Double(steps)))
            let r = stOut(n)
            out.append(Sample(x: r.x, y: r.y, p: q.p, t: q.t))
        }
    }

    // MARK: streamline
    /// Lag per stage in ms, the same at every speed: 90 ms at 100%.
    private var slTau: Double { pow(o.sl, 1.5) * 90 }
    private mutating func slStep(_ x: Double, _ y: Double, _ dt: Double) {
        guard var a = slA, var b = slB else { return }
        let tau = slTau
        let k: Double = tau < 0.5 ? 1 : 1 - exp(-dt / tau)
        let target = V2(x, y)
        a = a + (target - a) * k
        b = b + (a - b) * k
        slA = a; slB = b
    }
    private mutating func slPush(_ q: Sample, _ out: inout [Sample]) {
        if o.sl < 0.01 { out.append(q); return }
        guard slB != nil else {
            slA = V2(q.x, q.y); slB = slA; slT = q.t; slTarget = q
            out.append(q)
            return
        }
        slTarget = q
        let dt = max(0.5, q.t - slT)
        slT = q.t
        slStep(q.x, q.y, dt)
        if let b = slB { out.append(Sample(x: b.x, y: b.y, p: q.p, t: q.t)) }
    }
    private mutating func slFlush(_ out: inout [Sample]) {
        guard o.sl >= 0.01, let q = slTarget, let a = slA, let b = slB else { return }
        let qv = V2(q.x, q.y)
        let d = b.dist(qv) + a.dist(qv)
        if d < 0.05 { return }
        let n = max(4, min(40, Int(d / 2) + 1))
        let dt = max(1, pow(o.sl, 1.5) * 90) * 7 / Double(n)
        for _ in 0..<n {
            slStep(q.x, q.y, dt)
            if let r = slB { out.append(Sample(x: r.x, y: r.y, p: q.p, t: q.t)) }
        }
        out.append(q)
    }

    // MARK: chain
    mutating func push(_ s0: Sample) -> [Sample] {
        var s = s0
        if s.t < lastT { s.t = lastT }
        lastT = s.t
        let a = mfPush(s)
        var b: [Sample] = [], c: [Sample] = []
        stPush(a, &b)
        for q in b { slPush(q, &c) }
        return c
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
        return l
    }
}

/// The drawn line: smoothed samples become evenly spaced points along a centripetal Catmull–Rom curve (canvas units).
/// Pressure only changes as the pencil travels, so pressing harder at touch-down or while paused never swells the line,
/// and the start takes the pressure the pencil settles into rather than the landing spike.
struct Centerline {
    let spacing: Double
    let minDist: Double
    let startLen: Double       // the start's pressure is settled once the line is this long
    let pressureDist: Double   // travel over which pressure moves about 63% of the way to a new value
    private(set) var x: [Double] = []
    private(set) var y: [Double] = []
    private(set) var p: [Double] = []
    private(set) var s: [Double] = []           // arc length at each point
    private(set) var t: [Double] = []           // time (ms) at each point
    private(set) var settled = false
    private var q: [(Double, Double, Double, Double)] = []
    private var pf = 0.0

    init(spacing: Double, minDist: Double, startLen: Double, pressureDist: Double) {
        self.spacing = spacing; self.minDist = minDist; self.startLen = startLen; self.pressureDist = max(1e-6, pressureDist)
    }

    var count: Int { x.count }
    var length: Double { s.last ?? 0 }
    var head: V2? { q.last.map { V2($0.0, $0.1) } ?? (x.isEmpty ? nil : V2(x[x.count - 1], y[y.count - 1])) }

    private mutating func emit(_ px: Double, _ py: Double, _ praw: Double, _ pt: Double) {
        guard let lx = x.last, let ly = y.last, let ls = s.last else {
            x.append(px); y.append(py); p.append(praw); s.append(0); t.append(pt)
            pf = praw
            if startLen <= 0 { settled = true }
            return
        }
        let ds = V2(px - lx, py - ly).length
        let sNow = ls + ds
        if !settled {
            pf = praw
            for i in 0..<p.count { p[i] = praw }
            if sNow >= startLen { settled = true }
        } else {
            pf += (praw - pf) * (1 - exp(-ds / pressureDist))
        }
        x.append(px); y.append(py); p.append(pf); s.append(sNow); t.append(pt)
    }

    private mutating func seg(_ p0: (Double, Double, Double, Double), _ p1: (Double, Double, Double, Double), _ p2: (Double, Double, Double, Double), _ p3: (Double, Double, Double, Double)) {
        func dist(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double)) -> Double { ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot() }
        let d = dist(p1, p2)
        let k = max(1, min(40, Int((d / spacing).rounded(.up))))
        func kn(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double)) -> Double { max(1e-4, dist(a, b).squareRoot()) }
        let t0 = 0.0
        let t1 = t0 + kn(p0, p1)
        let t2 = t1 + kn(p1, p2)
        let t3 = t2 + kn(p2, p3)
        func L(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ ta: Double, _ tb: Double, _ u: Double) -> (Double, Double) {
            let w = (tb - u) / (tb - ta), v = (u - ta) / (tb - ta)
            return (ax * w + bx * v, ay * w + by * v)
        }
        for i in 1...k {
            let t = Double(i) / Double(k)
            let u = t1 + (t2 - t1) * t
            let a1 = L(p0.0, p0.1, p1.0, p1.1, t0, t1, u)
            let a2 = L(p1.0, p1.1, p2.0, p2.1, t1, t2, u)
            let a3 = L(p2.0, p2.1, p3.0, p3.1, t2, t3, u)
            let b1 = L(a1.0, a1.1, a2.0, a2.1, t0, t2, u)
            let b2 = L(a2.0, a2.1, a3.0, a3.1, t1, t3, u)
            let c = L(b1.0, b1.1, b2.0, b2.1, t1, t2, u)
            emit(c.0, c.1, p1.2 + (p2.2 - p1.2) * t, p1.3 + (p2.3 - p1.3) * t)
        }
    }

    mutating func add(_ px: Double, _ py: Double, _ pr: Double, _ pt: Double = 0) {
        if let l = q.last {
            let dx = px - l.0, dy = py - l.1
            if (dx * dx + dy * dy).squareRoot() < minDist {
                q[q.count - 1].2 = pr      // the latest pressure, never the highest: a pause can't grow a blob
                return
            }
        }
        q.append((px, py, pr, pt))
        let n = q.count
        if n == 1 { emit(px, py, pr, pt); return }
        if n >= 3 { seg(n >= 4 ? q[n - 4] : q[n - 3], q[n - 3], q[n - 2], q[n - 1]) }
        if q.count > 4 { q.removeFirst() }
    }

    mutating func finish() {
        let n = q.count
        if n >= 2 { seg(n >= 3 ? q[n - 3] : q[n - 2], q[n - 2], q[n - 1], q[n - 1]) }
        q = []
    }

    /// Points `from`…`to` (inclusive) as flat [x, y, p, …].
    func flat(from: Int = 0, to: Int? = nil) -> [Double] {
        let end = min(to ?? (count - 1), count - 1)
        guard from <= end, from >= 0 else { return [] }
        var out: [Double] = []
        out.reserveCapacity((end - from + 2) * 3)
        for i in from...end { out.append(x[i]); out.append(y[i]); out.append(p[i]) }
        return out
    }

    /// The line as it is drawn: each point smoothed by a Gaussian centred on it (so nothing lags), first over time
    /// (`sigmaT` ms: motion filtering) then over arc length (`sigmaS` canvas units: stabilisation).
    /// The window shrinks evenly toward either end, so the line starts and ends exactly on the pen,
    /// and the last few points keep settling as the pencil moves on.
    func settled(from: Int = 0, to: Int? = nil, sigmaT: Double, sigmaS: Double) -> [Double] {
        let n = count
        let end = min(to ?? (n - 1), n - 1)
        guard from <= end, from >= 0 else { return [] }
        if sigmaT <= 0 && sigmaS <= 0 { return flat(from: from, to: end) }
        // the first pass must cover everything the second pass looks at
        var a = from, b = end
        if sigmaS > 0 {
            while a > 0 && s[from] - s[a - 1] <= 3 * sigmaS { a -= 1 }
            while b < n - 1 && s[b + 1] - s[end] <= 3 * sigmaS { b += 1 }
        }
        var first: [V2] = []
        first.reserveCapacity(b - a + 1)
        for i in a...b {
            first.append(sigmaT > 0
                ? Centerline.centred(i, lo: 0, hi: n - 1, key: t, k0: t[0], k1: t[n - 1], sigma: sigmaT) { V2(x[$0], y[$0]) }
                : V2(x[i], y[i]))
        }
        var out: [Double] = []
        out.reserveCapacity((end - from + 1) * 3)
        for i in from...end {
            let q = sigmaS > 0
                ? Centerline.centred(i, lo: a, hi: b, key: s, k0: s[0], k1: s[n - 1], sigma: sigmaS) { first[$0 - a] }
                : first[i - a]
            out.append(q.x); out.append(q.y); out.append(p[i])
        }
        return out
    }
    private static func centred(_ i: Int, lo: Int, hi: Int, key: [Double], k0: Double, k1: Double, sigma: Double, at: (Int) -> V2) -> V2 {
        let half = min(3 * sigma, key[i] - k0, k1 - key[i])
        if half <= 0 { return at(i) }
        var sw = 0.0
        var acc = V2(0, 0)
        var j = i
        while j >= lo && key[i] - key[j] <= half {
            let d = (key[i] - key[j]) / sigma
            let w = exp(-0.5 * d * d)
            sw += w; acc = acc + at(j) * w
            j -= 1
        }
        j = i + 1
        while j <= hi && key[j] - key[i] <= half {
            let d = (key[j] - key[i]) / sigma
            let w = exp(-0.5 * d * d)
            sw += w; acc = acc + at(j) * w
            j += 1
        }
        return acc / sw
    }

    /// While drawing: a straight run from the last committed point to the newest sample (its curve isn't known yet).
    var provisional: [Double] {
        guard q.count >= 2, let l = q.last else { return [] }
        return [l.0, l.1, pf]
    }
    /// The pressure new points are drawn with right now.
    var pressure: Double { pf }
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

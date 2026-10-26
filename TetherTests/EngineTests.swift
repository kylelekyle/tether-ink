import XCTest
import UIKit
@testable import TetherInk

final class EngineTests: XCTestCase {

    // MARK: helpers

    /// A path with a steady hand wobble on top (deterministic, so the tests always see the same stroke).
    private func wrinkle(_ f: (Double) -> V2, n: Int = 300) -> [V2] {
        (0...n).map { i in
            let u = Double(i) / Double(n)
            let p = f(u)
            let wx: Double = 1.0 * sin(u * 37) + 0.6 * sin(u * 91 + 1)
            let wy: Double = 1.0 * cos(u * 29) + 0.6 * sin(u * 77 + 2)
            return V2(p.x + wx, p.y + wy)
        }
    }
    private let pen = BrushShape(size: 3, thin: 0.55, ts: 0, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)

    // MARK: outline

    func testOutlineForALine() {
        var p: [Double] = []
        for i in 0...50 { p += [Double(i) * 4, 100, 0.5] }
        let shape = BrushShape(size: 6, thin: 0.5, ts: 0, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)
        let o = StrokeGeometry.outline(StrokeGeometry.bake(p, shape))
        XCTAssertEqual(o.count, 1)
        XCTAssertGreaterThan(o[0].count, 20)
        let bb = StrokeGeometry.bbox(o)
        // radius at half pressure with 50% thinning: 3 × (1 − 0.5 + 0.5) / 1.5 = 2
        XCTAssertEqual(bb.minX, -2, accuracy: 0.05)
        XCTAssertEqual(bb.maxX, 202, accuracy: 0.05)
        XCTAssertEqual(bb.height, 4, accuracy: 0.05)
    }

    func testSinglePointMakesADot() {
        let o = StrokeGeometry.outline([10, 10, 4])
        XCTAssertEqual(o.count, 1)
        XCTAssertGreaterThanOrEqual(o[0].count, 12)
    }

    /// Every outline point sits on the brush's edge or inside it: no spikes, notches or NaNs at tight turns.
    private func assertClean(_ baked: [Double], file: StaticString = #filePath, line: UInt = #line) {
        for poly in StrokeGeometry.outline(baked) {
            for q in poly {
                XCTAssertFalse(q.x.isNaN || q.y.isNaN, file: file, line: line)
                var best = Double.infinity
                var i = 0
                while i + 2 < baked.count { best = min(best, V2(baked[i], baked[i + 1]).dist(q) - baked[i + 2]); i += 3 }
                XCTAssertLessThan(best, 0.05, file: file, line: line)
            }
        }
    }

    func testTightTurnsGiveACleanOutline() {
        let thick = BrushShape(size: 12, thin: 0, ts: 0, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)
        // a U-turn tighter than the brush
        var u = Centerline(spacing: 1, minDist: 0.1, startLen: 0, pressureDist: 1)
        for i in 0...200 {
            let t = Double(i) / 200
            let p: V2
            if t < 0.4 { p = V2(10 + 100 * t / 0.4, 20) }
            else if t < 0.6 { let a = (t - 0.4) / 0.2 * .pi; p = V2(110 + 3 * sin(a), 23 - 3 * cos(a)) }
            else { p = V2(110 - 100 * (t - 0.6) / 0.4, 26) }
            u.add(p.x, p.y, 0.7)
        }
        u.finish()
        assertClean(StrokeGeometry.bake(u.flat(), thick))
        // a sharp V
        var v = Centerline(spacing: 1, minDist: 0.1, startLen: 0, pressureDist: 1)
        for i in 0...200 {
            let t = Double(i) / 200
            v.add(20 + 60 * t, 140 + (t < 0.5 ? 54 * t : 54 * (1 - t)), 0.7)
        }
        v.finish()
        assertClean(StrokeGeometry.bake(v.flat(), BrushShape(size: 10, thin: 0, ts: 0, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)))
    }

    // MARK: smoothing

    func testSmootherFinishesAtThePencilWithCatchUp() {
        var sm = Smoother(SmoothParams(mf: 0.5, mfx: 0.5, st: 0.5, sts: 0.5, sl: 0.5, slp: 0.3, catchUp: true))
        var last: Sample? = nil
        for i in 0...100 {
            let out = sm.push(Sample(x: Double(i) * 3, y: 50 + sin(Double(i) / 10) * 20, p: 0.5, t: Double(i) * 4))
            if let l = out.last { last = l }
        }
        if let l = sm.flush().last { last = l }
        XCTAssertNotNil(last)
        XCTAssertEqual(last!.x, 300, accuracy: 0.5)
    }

    func testWithoutCatchUpLiftingAddsNothing() {
        var sm = Smoother(SmoothParams(mf: 1, mfx: 0, st: 1, sts: 1, sl: 1, slp: 1, catchUp: false))
        for i in 0...100 { _ = sm.push(Sample(x: Double(i) * 3, y: 0, p: 0.5, t: Double(i) * 4)) }
        XCTAssertTrue(sm.flush().isEmpty)
    }

    func testFullSmoothingRemovesTremor() {
        // 9 Hz tremor of ±2 pt on a slow horizontal line, 240 Hz samples
        var sm = Smoother(SmoothParams(mf: 1, mfx: 1, st: 1, sts: 1, sl: 1, slp: 1, catchUp: true))
        var out: [Sample] = []
        for i in 0..<900 {
            let t = Double(i) * 1000 / 240
            out += sm.push(Sample(x: t * 0.15, y: 100 + 2 * sin(2 * .pi * 9 * t / 1000), p: 0.5, t: t))
        }
        let mid = out.filter { $0.x > 60 && $0.x < 400 }
        XCTAssertFalse(mid.isEmpty)
        XCTAssertLessThan(mid.map { abs($0.y - 100) }.max() ?? 99, 0.25)
    }

    /// Mean lag (ms) of the smoothed line behind a pencil going round a circle at `speed` pt/s.
    private func lag(_ p: SmoothParams, speed: Double) -> Double {
        var sm = Smoother(p)
        let R = 150.0, w = speed / R / 1000, dt = 1000.0 / 240
        var total = 0.0, n = 0
        var t = 0.0
        while t < 2400 {
            let a = w * t
            let x = 300 + R * cos(a), y = 300 + R * sin(a)
            if let q = sm.push(Sample(x: x, y: y, p: 0.5, t: t)).last, t > 800 {
                total += V2(q.x - x, q.y - y).length / speed * 1000
                n += 1
            }
            t += dt
        }
        return total / Double(max(n, 1))
    }

    /// Tremor left on a line drawn at `speed` pt/s with a 9 Hz ±2 pt hand tremor.
    private func tremorLeft(_ p: SmoothParams, speed: Double) -> Double {
        var sm = Smoother(p)
        var worst = 0.0
        for i in 0..<1200 {
            let t = Double(i) * 1000 / 240
            for q in sm.push(Sample(x: t * speed / 1000, y: 100 + 2 * sin(2 * .pi * 9 * t / 1000), p: 0.5, t: t)) where i >= 300 {
                worst = max(worst, abs(q.y - 100))
            }
        }
        return worst
    }

    func testSmoothingIsTheSameAtEverySpeed() {
        // fast strokes get the same smoothing as slow ones
        for p in [SmoothParams(sl: 0.35), SmoothParams(sl: 1), SmoothParams(mf: 1), SmoothParams(mf: 0.5)] {
            XCTAssertEqual(tremorLeft(p, speed: 150), tremorLeft(p, speed: 1000), accuracy: 0.03)
        }
        // and the line trails the pencil by the same time at any speed (the Studio Pen's default streamline)
        let slow = lag(SmoothParams(sl: 0.35), speed: 400), fast = lag(SmoothParams(sl: 0.35), speed: 1200)
        XCTAssertEqual(slow, fast, accuracy: 8)
        XCTAssertLessThan(fast, 90)
    }

    // MARK: centerline and pressure

    func testCenterlinePassesThroughPoints() {
        var line = Centerline(spacing: 2, minDist: 0.1, startLen: 0, pressureDist: 1)
        for i in 0...10 { line.add(Double(i) * 10, Double(i % 2) * 10, 0.5) }
        line.finish()
        XCTAssertEqual(line.x[0], 0, accuracy: 1e-9)
        XCTAssertEqual(line.x[line.count - 1], 100, accuracy: 1e-6)
        XCTAssertGreaterThan(line.count, 30)
    }

    func testSettledLineStaysOnThePenAndLosesTheJitter() {
        // a line at 300 pt/s with a 9 Hz ±2 pt hand tremor, motion filtering and stabilisation at 100%
        var line = Centerline(spacing: 2, minDist: 0.3, startLen: 0, pressureDist: 1)
        var t = 0.0
        while t < 3000 { line.add(t * 0.3, 100 + 2 * sin(2 * .pi * 9 * t / 1000), 0.5, t); t += 1000 / 240 }
        let out = line.settled(sigmaT: 50, sigmaS: 14)
        let n = out.count / 3
        XCTAssertEqual(n, line.count)
        XCTAssertEqual(out[(n - 1) * 3], line.x[n - 1], accuracy: 1e-9, "the line ends on the pen")
        XCTAssertEqual(out[(n - 1) * 3 + 1], line.y[n - 1], accuracy: 1e-9)
        var worst = 0.0
        for i in 0..<n where out[i * 3] > 100 && out[i * 3] < line.x[n - 1] - 100 { worst = max(worst, abs(out[i * 3 + 1] - 100)) }
        XCTAssertLessThan(worst, 0.1, "the jitter is gone behind the pen")
    }

    func testLiveStartMatchesWhatLands() {
        // a light landing that ramps up: the start drawn while the pencil is down must be the start that's kept
        let b = BrushShape(size: 3, thin: 0.55, ts: 0.12, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)
        var line = Centerline(spacing: 2, minDist: 0.3, startLen: 3, pressureDist: 5)
        var live: [Double] = []
        for i in 0...96 {
            let t = Double(i) * 1000 / 240
            line.add(100 + Double(i) * 4, 100, min(0.6, 0.05 + t / 50))
            if i == 60 { live = StrokeGeometry.bake(line.flat() + line.provisional, b) }
        }
        line.finish()
        let kept = StrokeGeometry.bake(line.flat(), b)
        for k in 0..<6 { XCTAssertEqual(live[k * 3 + 2], kept[k * 3 + 2], accuracy: 1e-9) }
    }

    func testPressingWhilePausedDoesNotSwell() {
        var line = Centerline(spacing: 2, minDist: 0.3, startLen: 3, pressureDist: 5)
        for i in 0..<60 { line.add(100 + Double(i) * 2, 100, 0.4) }
        for i in 0..<60 { line.add(220, 100, 0.4 + Double(i) * 0.01) }     // the pencil rests and presses harder
        let r = StrokeGeometry.bake(line.flat(), pen)
        let before = StrokeGeometry.radius(0.4, pen)
        var i = 2
        while i < r.count { XCTAssertLessThanOrEqual(r[i], before + 1e-9); i += 3 }
    }

    func testPressureCurve() {
        XCTAssertEqual(PressureCurve.eval([[0, 0], [1, 1]], 0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(PressureCurve.eval([[0, 0], [0.5, 0.2], [1, 1]], 0.5), 0.2, accuracy: 1e-9)
    }

    func testRadiusRoundTripsToPressure() {
        for p in [0.1, 0.5, 0.9] {
            XCTAssertEqual(StrokeGeometry.pressure(fromRadius: StrokeGeometry.radius(p, pen), pen), p, accuracy: 1e-9)
        }
    }

    // MARK: hold to snap

    func testShapeFit() {
        var line: [V2] = []
        for i in 0...30 { line.append(V2(Double(i) * 5, Double(i) * 2)) }
        if case .line = ShapeFit.fit(line) {} else { XCTFail("expected a line") }
        var loop: [V2] = []
        for i in 0...64 { let t = Double(i) / 64 * .pi * 2; loop.append(V2(100 + cos(t) * 80, 50 + sin(t) * 30)) }
        if case .ellipse = ShapeFit.fit(loop) {} else { XCTFail("expected an ellipse") }
    }

    func testEllipseFitLandsOnTheDrawnLoop() {
        // drawn unevenly (fast and slow parts), a little short of a full turn, rotated
        var pts: [V2] = []
        for i in 0..<150 {
            let u = Double(i) / 149
            let t = 0.93 * 2 * .pi * (u + 0.12 * sin(2 * .pi * u))
            let ex = cos(t) * 150, ey = sin(t) * 80, a = 0.4
            pts.append(V2(300 + ex * cos(a) - ey * sin(a), 200 + ex * sin(a) + ey * cos(a)))
        }
        guard case .ellipse(let e) = ShapeFit.fit(pts) else { return XCTFail("expected an ellipse") }
        XCTAssertEqual(e.c.x, 300, accuracy: 1.5)
        XCTAssertEqual(e.c.y, 200, accuracy: 1.5)
        XCTAssertEqual(max(e.r1, e.r2), 150, accuracy: 1.5)
        XCTAssertEqual(min(e.r1, e.r2), 80, accuracy: 1.5)
        XCTAssertFalse(e.circle)
        // the outline starts where the stroke started
        let first = e.point(e.start)
        XCTAssertLessThan(first.dist(pts[0]), 2)
    }

    func testArchesSnapToSmoothCurvesThroughTheirEnds() {
        let arch: (Double) -> V2 = { u in V2(50 + 300 * u, 200 - 120 * sin(.pi * u)) }
        let raw = wrinkle(arch)
        guard case .curve(let c) = ShapeFit.fit(raw) else { return XCTFail("expected a curve") }
        XCTAssertLessThan(c.start.dist(raw[0]), 1e-6)
        XCTAssertLessThan(c.end.dist(raw[raw.count - 1]), 1e-6)
        let clean = (0...400).map { arch(Double($0) / 400) }
        var worst = 0.0
        for q in c.sampled() { worst = max(worst, clean.map { $0.dist(q) }.min() ?? 0) }
        XCTAssertLessThan(worst, 0.015 * raw[0].dist(raw[raw.count - 1]), "the wrinkles are gone, the arch is the one drawn")
        // a lopsided arch keeps its early peak
        let lop: (Double) -> V2 = { u in V2(50 + 300 * u, 200 - 120 * sin(.pi * pow(u, 0.6))) }
        guard case .curve(let lc) = ShapeFit.fit(wrinkle(lop)) else { return XCTFail("expected a curve") }
        let peak = lc.sampled().min { $0.y < $1.y }!
        XCTAssertEqual((peak.x - 50) / 300, 0.3, accuracy: 0.05)
    }

    func testOnlyLinesAndArchesSnap() {
        if case .line = ShapeFit.fit(wrinkle { u in V2(50 + 300 * u, 240 + 20 * u) }) {} else { XCTFail("a wobbly straight stroke is a line") }
        XCTAssertNil(ShapeFit.fit(wrinkle { u in V2(50 + 300 * u, 200 - 60 * sin(2 * .pi * u)) }), "an S-curve doesn't snap")
        XCTAssertNil(ShapeFit.fit(wrinkle { u in V2(50 + 300 * u, 200 - (u < 0.5 ? 240 * u : 240 * (1 - u))) }), "a sharp corner doesn't snap")
    }

    func testPerfectArcIsCircular() {
        guard let arc = Curve.arc(V2(0, 0), V2(100, 60), V2(200, 0)) else { return XCTFail("expected an arc") }
        XCTAssertTrue(arc.arc)
        let c = V2(100, (3600.0 - 10000.0) / 120), r = c.dist(V2(0, 0))      // the circle through the three points
        for q in arc.sampled() { XCTAssertEqual(q.dist(c), r, accuracy: r * 0.002) }
        XCTAssertLessThan(arc.end.dist(V2(200, 0)), 1e-9)
        XCTAssertLessThan(arc.mid.dist(V2(100, 60)), r * 0.01)
    }

    // MARK: colour drop fill

    private func ring(_ cx: Double, _ cy: Double, _ r: Double) -> Item {
        var p: [Double] = []
        for i in 0...240 { let a = Double(i) / 240 * 2 * .pi; p += [cx + r * cos(a), cy + r * sin(a), 0.6] }
        let b = BrushShape(size: 3, thin: 0, ts: 0, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)
        return .stroke(StrokeItem(id: newID(), m: "d", c: "#111111", o: 1, b: b, p: StrokeGeometry.bake(p, b)))
    }
    /// Area covered with the even-odd rule, for one outer loop with holes inside it.
    private func filledArea(_ polys: [[Double]]) -> Double {
        let areas = polys.map { p -> Double in
            var s = 0.0
            var i = 0
            while i + 1 < p.count { let j = (i + 2) % p.count; s += p[i] * p[j + 1] - p[j] * p[i + 1]; i += 2 }
            return abs(s / 2)
        }
        guard let outer = areas.max() else { return 0 }
        return outer - (areas.reduce(0, +) - outer)
    }

    func testColourDropFillsTheAreaInsideALoop() {
        let full = Double.pi * 60 * 60
        guard let polys = FloodFill.region([[ring(150, 100, 60)]], w: 300, h: 200, seed: V2(150, 100)) else { return XCTFail("expected a fill") }
        XCTAssertEqual(polys.count, 1)
        XCTAssertEqual(filledArea(polys), full, accuracy: full * 0.08, "fills up to the line, tucked under it")
        // a shape inside the area stays a hole
        guard let holed = FloodFill.region([[ring(150, 100, 60), ring(150, 100, 20)]], w: 300, h: 200, seed: V2(150, 55)) else { return XCTFail("expected a fill") }
        XCTAssertEqual(holed.count, 2)
        XCTAssertEqual(filledArea(holed), Double.pi * (60 * 60 - 20 * 20), accuracy: full * 0.08)
        // dropped on a line: nothing
        XCTAssertNil(FloodFill.region([[ring(150, 100, 60)]], w: 300, h: 200, seed: V2(210, 100)))
    }

    func testFillsSaveAndLoad() throws {
        let d = AppModel.makeSampler()
        let f = FillItem(id: "f1", c: "#e8a33d", o: 1, p: [[0, 0, 10, 0, 10, 10, 0, 10]])
        d.layers[0].items.insert(.fill(f), at: 0)
        let back = try JSONDecoder().decode(Doc.self, from: DocWriter.json(DocWriter.Snapshot(d)))
        XCTAssertEqual(back.layers[0].items.first, .fill(f))
        XCTAssertTrue(Exporter.svg(d).contains("evenodd"))
    }

    // MARK: importing

    /// A zip with one stored (uncompressed) entry, built by hand.
    private func storedZip(_ name: String, _ content: Data) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8 & 0xff)) }
        func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16 & 0xffff) }
        let nb = Array(name.utf8)
        u32(0x0403_4b50); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0); u32(content.count); u32(content.count); u16(nb.count); u16(0)
        d.append(contentsOf: nb); d.append(content)
        let cd = d.count
        u32(0x0201_4b50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0); u32(0); u32(content.count); u32(content.count)
        u16(nb.count); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        d.append(contentsOf: nb)
        let size = d.count - cd
        u32(0x0605_4b50); u16(0); u16(0); u16(1); u16(1); u32(size); u32(cd); u16(0)
        return d
    }

    func testZipReaderReadsAnEntry() {
        let zip = storedZip("folder/hello.txt", Data("hello".utf8))
        guard let z = ZipReader(zip) else { return XCTFail("expected a zip") }
        XCTAssertEqual(z.names, ["folder/hello.txt"])
        XCTAssertEqual(z.read("folder/hello.txt"), Data("hello".utf8))
        XCTAssertNil(z.read("missing"))
    }

    func testProcreateBrushSettingsBecomeAVectorBrush() {
        let pb = PBrush(name: "Liner", nums: ["minSize": 0.01, "maxSize": 0.2, "paintSize": 0.25, "dynamicsPressureSize": 0.8,
                                              "plotSmoothing": 0.4, "pencilTaperStartLength": 0.2])
        let arch = NSKeyedArchiver(requiringSecureCoding: false)
        arch.setClassName("SilicaBrush", for: PBrush.self)
        arch.encode(pb, forKey: NSKeyedArchiveRootObjectKey)
        arch.finishEncoding()
        guard let r = BrushImport.procreate(storedZip("Brush.archive", arch.encodedData), fileName: "Liner.brush") else { return XCTFail("expected a brush") }
        XCTAssertEqual(r.vector.count, 1)
        XCTAssertEqual(r.pixel.count, 1, "the original is kept for pixel layers")
        let b = r.vector[0]
        XCTAssertEqual(b.name, "Liner")
        XCTAssertTrue(b.set.hasPrefix("imp:"))
        XCTAssertEqual(b.streamline, 0.4, accuracy: 1e-9)
        XCTAssertEqual(b.thinning, 0.72, accuracy: 1e-9)
        XCTAssertEqual(b.taperStart, 0.2, accuracy: 1e-9)
        XCTAssertEqual(b.size, ((0.01 + 0.19 * 0.25) * 120 * 100).rounded() / 100, accuracy: 1e-9)
    }

    func testTracingSplitsALayerIntoColourFills() {
        // a red disc inside a black ring, premultiplied RGBA like a Procreate layer
        let W = 80, H = 60
        var px = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let d = V2(Double(x) - 40, Double(y) - 30).length
                let i = (y * W + x) * 4
                if d < 20 { px[i] = 220; px[i + 1] = 40; px[i + 2] = 40; px[i + 3] = 255 }
                if d >= 20 && d < 24 { px[i + 3] = 255 }
            }
        }
        let items = ProcreateImport.trace(px, W: W, H: H)
        let colours = items.compactMap { item -> String? in
            if case .fill(let f) = item { return f.c }
            return nil
        }
        XCTAssertEqual(colours.count, 2)
        XCTAssertTrue(colours.contains("#dc2c2c"), "the red disc")
        XCTAssertTrue(colours.contains("#040404"), "the black ring")
    }

    // MARK: saving

    func testFastWriterMatchesTheDecoder() throws {
        let d = AppModel.makeSampler()
        let data = DocWriter.json(DocWriter.Snapshot(d))
        let back = try JSONDecoder().decode(Doc.self, from: data)
        XCTAssertEqual(back.layers.count, d.layers.count)
        for (a, b) in zip(back.layers, d.layers) {
            XCTAssertEqual(a.items.count, b.items.count)
            for (x, y) in zip(a.items, b.items) {
                if case .stroke(let s1) = x, case .stroke(let s2) = y {
                    XCTAssertEqual(s1.id, s2.id); XCTAssertEqual(s1.c, s2.c); XCTAssertEqual(s1.b, s2.b)
                    XCTAssertEqual(s1.p.count, s2.p.count)
                    for (u, v) in zip(s1.p, s2.p) { XCTAssertEqual(u, v, accuracy: 0.0006) }
                }
            }
        }
        XCTAssertEqual(back.name, d.name)
        XCTAssertEqual(back.active, d.active)
    }

    func testLockedLayersAndEmptyDrawingsSurviveSaving() throws {
        let d = AppModel.makeSampler()
        let plain = DocWriter.json(DocWriter.Snapshot(d))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("\"locked\""), "unlocked layers keep the old format")
        d.layers[1].locked = true
        var back = try JSONDecoder().decode(Doc.self, from: DocWriter.json(DocWriter.Snapshot(d)))
        XCTAssertEqual(back.layers.map { $0.locked }, [false, true])
        d.layers = []
        d.active = ""
        back = try JSONDecoder().decode(Doc.self, from: DocWriter.json(DocWriter.Snapshot(d)))
        XCTAssertTrue(back.layers.isEmpty, "a drawing with no layers stays that way")
        XCTAssertNil(back.activeLayer)
        XCTAssertEqual(back.activeIndex, -1)
    }

    func testOpensVersion1Drawings() throws {
        let json = """
        {"v":1,"id":"abc123","name":"Old sketch","w":1800,"h":1200,"bg":"#ffffff","bgOn":true,"created":1,"updated":2,"active":"L1",
         "layers":[{"id":"L1","name":"Line","visible":true,"opacity":1,"items":[
           {"t":"s","id":"s1","m":"d","c":"#111111","o":1,"b":{"size":3,"thin":0.55,"ts":0,"te":0,"sm":0.5,"sl":0,"g":1,"sim":0},"p":[0,0,0.5,10,10,1]},
           {"t":"i","id":"i1","src":"data:image/png;base64,AAAA","x":0,"y":0,"w":10,"h":10,"o":1},
           {"t":"zzz","id":"bad"}]}],"kind":"drawing"}
        """
        let d = try JSONDecoder().decode(Doc.self, from: Data(json.utf8))
        XCTAssertEqual(d.name, "Old sketch")
        XCTAssertEqual(d.layers[0].items.count, 2, "unknown items are skipped")
        guard case .stroke(let s) = d.layers[0].items[0] else { return XCTFail("expected a stroke") }
        XCTAssertEqual(s.p[2], 1.5 / 1.55, accuracy: 1e-6)     // half pressure, size 3, thinning 55%
        XCTAssertEqual(s.p[5], 1.5, accuracy: 1e-6)            // full pressure is half the size
        let out = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        XCTAssertTrue(out.contains("\"r\":"), "saved again as version 2")
        XCTAssertFalse(out.contains("\"p\":"))
    }

    // MARK: scatter brushes

    private func straight(_ len: Double, r: Double = 10) -> [Double] {
        stride(from: 0.0, through: len, by: 2).flatMap { [$0, 0, r] }
    }

    func testScatterChunksLineUpWithTheWholeStroke() {
        let k = StampParams(shape: nil, spacing: 0.1, scale: 0.3, jitter: 1, jitterLinear: 1, sizeJitter: 0.5, rotation: 0, oriented: false)
        let pts = straight(300)
        let whole = StrokeGeometry.stamps(pts, k, size: 20, seed: 42)
        let m = 51                                     // split at a shared point, as the live chunks do
        let first = Array(pts[0..<((m + 1) * 3)]), rest = Array(pts[(m * 3)...])
        let s1 = StrokeGeometry.arcLength(first)
        let a = StrokeGeometry.stamps(first, k, size: 20, seed: 42, s0: 0, end: s1)
        let b = StrokeGeometry.stamps(rest, k, size: 20, seed: 42, s0: s1)
        XCTAssertEqual(whole.count, a.count + b.count)
        for (x, y) in zip(whole, a + b) {
            XCTAssertEqual(x[0].x, y[0].x, accuracy: 1e-6)
            XCTAssertEqual(x[0].y, y[0].y, accuracy: 1e-6)
        }
    }

    func testScatterIsRepeatableAndJitters() {
        var k = StampParams(spacing: 0.25, scale: 0.2)
        let pts = straight(200)
        let still = StrokeGeometry.stamps(pts, k, size: 20, seed: 1)
        XCTAssertEqual(still.count, 41)                // one dab every 5 units, ends included
        for d in still { XCTAssertEqual(d.map { $0.y }.reduce(0, +) / Double(d.count), 0, accuracy: 1e-6, "no jitter stays on the line") }
        k.jitter = 1
        let a = StrokeGeometry.stamps(pts, k, size: 20, seed: 1), again = StrokeGeometry.stamps(pts, k, size: 20, seed: 1)
        let other = StrokeGeometry.stamps(pts, k, size: 20, seed: 2)
        XCTAssertEqual(a.map { $0[0].y }, again.map { $0[0].y }, "the same stroke scatters the same way every time")
        XCTAssertNotEqual(a.map { $0[0].y }, other.map { $0[0].y })
        let spread = a.map { abs($0.map { $0.y }.reduce(0, +) / Double($0.count)) }.max() ?? 0
        XCTAssertGreaterThan(spread, 3)
        XCTAssertLessThanOrEqual(spread, 10.01, "at 100% dabs stay within the brush width")
    }

    func testScatterStrokesSurviveSaving() throws {
        let shape = StampShape(id: "kTest", p: [[-0.5, -0.5, 0.5, -0.5, 0, 0.5]])
        StampRegistry.shared.register(shape)
        let d = Doc(w: 400, h: 300, name: "Scatter")
        var b = BrushShape(size: 20, thin: 0, ts: 0, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)
        b.k = StampParams(shape: "kTest", spacing: 0.3, scale: 0.5, jitter: 0.7, jitterLinear: 0.2, sizeJitter: 0.1, rotation: 1, oriented: true)
        d.layers[0].items = [.stroke(StrokeItem(id: "st1", m: "d", c: "#111111", o: 1, b: b, p: straight(100)))]
        d.stamps = [shape]
        let back = try JSONDecoder().decode(Doc.self, from: DocWriter.json(DocWriter.Snapshot(d)))
        guard case .stroke(let s) = back.layers[0].items[0] else { return XCTFail("expected a stroke") }
        XCTAssertEqual(s.b.k, b.k)
        XCTAssertEqual(back.stamps, [shape])
        XCTAssertFalse(GeometryCache.shared.get(s).path.isEmpty)
    }

    func testTracesABrushShape() {
        func png(_ draw: (CGContext) -> Void) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f }())
                .pngData { c in
                    UIColor.black.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                    UIColor.white.setFill(); draw(c.cgContext)
                }
        }
        let dots = png { $0.fillEllipse(in: CGRect(x: 6, y: 6, width: 16, height: 16)); $0.fillEllipse(in: CGRect(x: 36, y: 30, width: 20, height: 20)) }
        let sh = BrushImport.traceShape(dots, inverted: false)
        XCTAssertEqual(sh?.p.count, 2)
        for poly in sh?.p ?? [] { for v in poly { XCTAssertLessThanOrEqual(abs(v), 0.5) } }
        let round = png { $0.fillEllipse(in: CGRect(x: 2, y: 2, width: 60, height: 60)) }
        XCTAssertNil(BrushImport.traceShape(round, inverted: false), "a plain round shape is just a dot")
    }

    func testSVGExportIsWellFormed() {
        let d = AppModel.makeSampler()
        let svg = Exporter.svg(d)
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("<path d=\"M"))
        XCTAssertTrue(svg.hasSuffix("</svg>"))
    }
}

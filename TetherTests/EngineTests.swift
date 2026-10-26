import XCTest
@testable import TetherInk

final class EngineTests: XCTestCase {

    func testOutlineForALine() {
        var p: [Double] = []
        for i in 0...50 { p += [Double(i) * 4, 100, 0.5] }
        let shape = BrushShape(size: 6, thin: 0.5, ts: 0, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)
        let o = StrokeGeometry.outline(p, shape, last: true)
        XCTAssertGreaterThan(o.count, 20)
        let bb = StrokeGeometry.bbox(o)
        XCTAssertEqual(bb.minX, -3, accuracy: 2)
        XCTAssertEqual(bb.maxX, 203, accuracy: 2)
        XCTAssertLessThan(bb.height, 8)
    }

    func testSinglePointMakesADot() {
        let shape = BrushShape(size: 8, thin: 0, ts: 0, te: 0, sm: 0.5, sl: 0, g: 1, sim: false)
        let o = StrokeGeometry.outline([10, 10, 0.5], shape, last: true)
        XCTAssertGreaterThan(o.count, 8)
    }

    func testSmootherFinishesAtThePencilWithoutRope() {
        var sm = Smoother(SmoothParams(mf: 0.5, mfx: 0.5, st: 0.5, sts: 0.5, sl: 0.5, slp: 0.3, rope: 0, catchUp: true))
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
        var sm = Smoother(SmoothParams(mf: 1, mfx: 0, st: 1, sts: 1, sl: 1, slp: 1, rope: 0, catchUp: false))
        for i in 0...100 { _ = sm.push(Sample(x: Double(i) * 3, y: 0, p: 0.5, t: Double(i) * 4)) }
        XCTAssertTrue(sm.flush().isEmpty)
    }

    func testFullSmoothingRemovesTremor() {
        // 9 Hz tremor of ±2 pt on a slow horizontal line, 240 Hz samples
        var sm = Smoother(SmoothParams(mf: 1, mfx: 1, st: 1, sts: 1, sl: 1, slp: 1, rope: 0, catchUp: true))
        var out: [Sample] = []
        for i in 0..<900 {
            let t = Double(i) * 1000 / 240
            out += sm.push(Sample(x: t * 0.15, y: 100 + 2 * sin(2 * .pi * 9 * t / 1000), p: 0.5, t: t))
        }
        let mid = out.filter { $0.x > 60 && $0.x < 400 }
        XCTAssertFalse(mid.isEmpty)
        XCTAssertLessThan(mid.map { abs($0.y - 100) }.max() ?? 99, 0.25)
    }

    func testRopeHoldsTheLineBackByTheStringLength() {
        var sm = Smoother(SmoothParams(rope: 30))
        var last: Sample? = nil
        for i in 0...100 { if let l = sm.push(Sample(x: Double(i) * 3, y: 0, p: 0.5, t: Double(i) * 4)).last { last = l } }
        XCTAssertEqual(last!.x, 270, accuracy: 0.5)
    }

    func testCurveEmitterPassesThroughPoints() {
        var em = CurveEmitter(minDist: 0.1, spacing: 2)
        for i in 0...10 { em.add(Double(i) * 10, Double(i % 2) * 10, 0.5) }
        let out = em.finish()
        XCTAssertEqual(out[0], 0, accuracy: 1e-9)
        XCTAssertEqual(out[out.count - 3], 100, accuracy: 1e-6)
        XCTAssertGreaterThan(out.count / 3, 30)
    }

    func testPressureCurve() {
        XCTAssertEqual(PressureCurve.eval([[0, 0], [1, 1]], 0.3), 0.3, accuracy: 1e-9)
        XCTAssertEqual(PressureCurve.eval([[0, 0], [0.5, 0.2], [1, 1]], 0.5), 0.2, accuracy: 1e-9)
    }

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

    func testReadsWebBackupFormat() throws {
        let json = """
        {"v":1,"id":"abc123","name":"Web sketch","w":1800,"h":1200,"bg":"#ffffff","bgOn":true,"created":1,"updated":2,"active":"L1",
         "layers":[{"id":"L1","name":"Line","visible":true,"opacity":1,"items":[
           {"t":"s","id":"s1","m":"d","c":"#111111","o":1,"b":{"size":3,"thin":0.55,"ts":0.12,"te":0.28,"sm":0.5,"sl":0,"g":1,"sim":0},"p":[0,0,0.5,10,10,0.6]},
           {"t":"i","id":"i1","src":"data:image/png;base64,AAAA","x":0,"y":0,"w":10,"h":10,"o":1},
           {"t":"zzz","id":"bad"}]}],"kind":"drawing"}
        """
        let d = try JSONDecoder().decode(Doc.self, from: Data(json.utf8))
        XCTAssertEqual(d.name, "Web sketch")
        XCTAssertEqual(d.layers.count, 1)
        XCTAssertGreaterThanOrEqual(d.layers[0].items.count, 2)
        let again = try JSONDecoder().decode(Doc.self, from: try JSONEncoder().encode(d))
        XCTAssertEqual(again.layers[0].items.first, d.layers[0].items.first)
    }

    func testSVGExportIsWellFormed() {
        let d = AppModel.makeSampler()
        let svg = Exporter.svg(d)
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("<path d=\"M"))
        XCTAssertTrue(svg.hasSuffix("</svg>"))
    }
}

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
        var sm = Smoother(SmoothParams(mf: 0.5, mfx: 0.5, st: 0.5, sts: 0.5, sl: 0.5, slp: 0.3, rope: 0, catchUp: false))
        var last: Sample? = nil
        for i in 0...100 {
            let out = sm.push(Sample(x: Double(i) * 3, y: 50 + sin(Double(i) / 10) * 20, p: 0.5, t: Double(i) * 4))
            if let l = out.last { last = l }
        }
        if let l = sm.flush().last { last = l }
        XCTAssertNotNil(last)
        XCTAssertEqual(last!.x, 300, accuracy: 0.5)
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

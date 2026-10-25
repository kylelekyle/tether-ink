import Foundation
import CoreGraphics

enum StrokeGeometry {
    /// Same mapping as the web version so strokes look identical in both.
    static func options(_ b: BrushShape, last: Bool) -> FreehandOptions {
        var o = FreehandOptions()
        let thin = b.thin
        o.size = b.size / (1 + thin)
        o.thinning = thin
        o.smoothing = b.sm
        o.streamline = b.sl
        o.simulatePressure = b.sim && thin > 0
        let tl = max(b.size * 20, 40)
        o.taperStart = b.ts > 0 ? b.ts * tl : 0
        o.taperEnd = b.te > 0 ? b.te * tl : 0
        o.capStart = true
        o.capEnd = true
        o.last = last
        return o
    }

    static func outline(_ p: [Double], _ b: BrushShape, last: Bool) -> [V2] {
        var inp = p
        if b.g != 1 {
            var i = 2
            while i < inp.count { inp[i] = pow(clampD(inp[i], 0, 1), b.g); i += 3 }
        }
        return Freehand.stroke(inp, options(b, last: last))
    }

    /// Closed, smooth outline: quadratic curves through midpoints.
    static func path(_ o: [V2], transform: CGAffineTransform? = nil) -> CGPath {
        let path = CGMutablePath()
        let n = o.count
        guard n >= 3 else { return path }
        let t = transform ?? .identity
        let a0 = o[n - 1], b0 = o[0]
        path.move(to: CGPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2), transform: t)
        for i in 0..<n {
            let a = o[i], b = o[(i + 1) % n]
            path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: CGPoint(x: a.x, y: a.y), transform: t)
        }
        path.closeSubpath()
        return path
    }

    static func bbox(_ o: [V2]) -> CGRect {
        guard let f = o.first else { return .null }
        var x0 = f.x, y0 = f.y, x1 = f.x, y1 = f.y
        for q in o { x0 = min(x0, q.x); y0 = min(y0, q.y); x1 = max(x1, q.x); y1 = max(y1, q.y) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func svgPath(_ o: [V2]) -> String {
        let n = o.count
        guard n >= 3 else { return "" }
        func f(_ v: Double) -> String { let r = (v * 100).rounded() / 100; return r == r.rounded() ? String(Int(r)) : String(r) }
        let a0 = o[n - 1], b0 = o[0]
        var d = "M\(f((a0.x + b0.x) / 2)) \(f((a0.y + b0.y) / 2))Q"
        for i in 0..<n {
            let a = o[i], b = o[(i + 1) % n]
            d += "\(f(a.x)) \(f(a.y)) \(f((a.x + b.x) / 2)) \(f((a.y + b.y) / 2)) "
        }
        return d.trimmingCharacters(in: .whitespaces) + "Z"
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
        let o = StrokeGeometry.outline(s.p, s.b, last: true)
        let entry = (StrokeGeometry.path(o), StrokeGeometry.bbox(o))
        lock.lock(); cache[s.id] = entry; lock.unlock()
        return entry
    }

    func trim(keep ids: Set<String>) {
        lock.lock(); cache = cache.filter { ids.contains($0.key) }; lock.unlock()
    }
}

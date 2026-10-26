import Foundation

/// Small 2D vector used by the stroke engine (kept free of UIKit so it can be unit tested).
struct V2: Equatable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    static let zero = V2(0, 0)

    static func + (a: V2, b: V2) -> V2 { V2(a.x + b.x, a.y + b.y) }
    static func - (a: V2, b: V2) -> V2 { V2(a.x - b.x, a.y - b.y) }
    static func * (a: V2, s: Double) -> V2 { V2(a.x * s, a.y * s) }
    static func / (a: V2, s: Double) -> V2 { V2(a.x / s, a.y / s) }
    static prefix func - (a: V2) -> V2 { V2(-a.x, -a.y) }

    var length: Double { (x * x + y * y).squareRoot() }
    var length2: Double { x * x + y * y }
    /// Perpendicular: [y, -x]
    var per: V2 { V2(y, -x) }
    var unit: V2 { let l = length; return l > 0 ? self / l : V2(0, 0) }

    func dot(_ b: V2) -> Double { x * b.x + y * b.y }
    func dist(_ b: V2) -> Double { (self - b).length }
    func dist2(_ b: V2) -> Double { (self - b).length2 }

    func rotated(around c: V2, by r: Double) -> V2 {
        let s = sin(r), co = cos(r)
        let px = x - c.x, py = y - c.y
        return V2(px * co - py * s + c.x, px * s + py * co + c.y)
    }

    static func lerp(_ a: V2, _ b: V2, _ t: Double) -> V2 { a + (b - a) * t }
}

@inline(__always) func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }

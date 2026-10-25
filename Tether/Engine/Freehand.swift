import Foundation

// Swift port of perfect-freehand 1.2.3 (MIT License, Copyright (c) 2021 Stephen Ruiz Ltd.)
// https://github.com/steveruizok/perfect-freehand
// Turns pressure-sensitive input points into the outline polygon of a stroke.

struct FreehandOptions {
    var size: Double = 16
    var thinning: Double = 0.5
    var smoothing: Double = 0.5
    var streamline: Double = 0.5
    var simulatePressure: Bool = true
    /// Taper distances in canvas units; 0 means no taper.
    var taperStart: Double = 0
    var taperEnd: Double = 0
    var capStart: Bool = true
    var capEnd: Bool = true
    var last: Bool = false
}

enum Freehand {
    static let rateOfPressureChange = 0.275
    static let fixedPI = Double.pi + 0.0001
    static let startCapSegments = 13.0
    static let endCapSegments = 29.0
    static let cornerCapSegments = 13.0
    static let endNoiseThreshold = 3.0
    static let minStreamlineT = 0.15
    static let streamlineTRange = 0.85
    static let minRadius = 0.01
    static let defaultFirstPressure = 0.25
    static let defaultPressure = 0.5

    struct StrokePoint {
        var point: V2
        var pressure: Double
        var vector: V2
        var distance: Double
        var runningLength: Double
    }

    /// `flat` holds x, y, pressure triples.
    static func stroke(_ flat: [Double], _ o: FreehandOptions) -> [V2] {
        outline(strokePoints(flat, o), o)
    }

    static func radius(_ size: Double, _ thinning: Double, _ pressure: Double) -> Double {
        size * (0.5 - thinning * (0.5 - pressure))
    }

    static func simulate(_ prev: Double, _ distance: Double, _ size: Double) -> Double {
        let sp = min(1, distance / size)
        let rp = min(1, 1 - sp)
        return min(1, prev + (rp - prev) * (sp * rateOfPressureChange))
    }

    private static func valid(_ p: Double) -> Bool { !p.isNaN && p >= 0 }

    static func strokePoints(_ flat: [Double], _ o: FreehandOptions) -> [StrokePoint] {
        let n = flat.count / 3
        if n == 0 { return [] }
        let t = minStreamlineT + (1 - o.streamline) * streamlineTRange
        var pts: [(Double, Double, Double)] = []
        pts.reserveCapacity(n + 4)
        for i in 0..<n { pts.append((flat[i * 3], flat[i * 3 + 1], flat[i * 3 + 2])) }

        if pts.count == 2 {
            let first = pts[0], last = pts[1]
            pts = [first]
            for i in 1..<5 {
                let k = Double(i) / 4
                // interpolated points carry no pressure (the default is used), as in the original
                pts.append((first.0 + (last.0 - first.0) * k, first.1 + (last.1 - first.1) * k, -1))
            }
        }
        if pts.count == 1 {
            let p = pts[0]
            pts.append((p.0 + 1, p.1 + 1, p.2))
        }

        var out: [StrokePoint] = [StrokePoint(point: V2(pts[0].0, pts[0].1),
                                              pressure: valid(pts[0].2) ? pts[0].2 : defaultFirstPressure,
                                              vector: V2(1, 1), distance: 0, runningLength: 0)]
        var reached = false
        var running = 0.0
        var prev = out[0]
        let maxI = pts.count - 1
        for i in 1..<pts.count {
            let target = V2(pts[i].0, pts[i].1)
            let point = (o.last && i == maxI) ? target : V2.lerp(prev.point, target, t)
            if point == prev.point { continue }
            let d = point.dist(prev.point)
            running += d
            if i < maxI && !reached {
                if running < o.size { continue }
                reached = true
            }
            prev = StrokePoint(point: point,
                               pressure: valid(pts[i].2) ? pts[i].2 : defaultPressure,
                               vector: (prev.point - point).unit,
                               distance: d, runningLength: running)
            out.append(prev)
        }
        out[0].vector = out.count > 1 ? out[1].vector : V2(0, 0)
        return out
    }

    private static func easeStart(_ t: Double) -> Double { t * (2 - t) }
    private static func easeEnd(_ t: Double) -> Double { let u = t - 1; return u * u * u + 1 }

    static func outline(_ points: [StrokePoint], _ o: FreehandOptions) -> [V2] {
        let size = o.size
        if points.isEmpty || size <= 0 { return [] }
        let totalLength = points[points.count - 1].runningLength
        let taperStart = max(0, o.taperStart)
        let taperEnd = max(0, o.taperEnd)
        let minDistance = pow(size * o.smoothing, 2)
        var left: [V2] = []
        var right: [V2] = []
        left.reserveCapacity(points.count + 16)
        right.reserveCapacity(points.count + 16)

        var prevPressure: Double = {
            var acc = points[0].pressure
            for p in points.prefix(10) {
                var pr = p.pressure
                if o.simulatePressure { pr = simulate(acc, p.distance, size) }
                acc = (acc + pr) / 2
            }
            return acc
        }()
        var r = radius(size, o.thinning, points[points.count - 1].pressure)
        var firstRadius: Double? = nil
        var prevVector = points[0].vector
        var prevLeft = points[0].point
        var prevRight = prevLeft
        var tempLeft = prevLeft
        var tempRight = prevRight
        var prevSharp = false

        for i in 0..<points.count {
            var pressure = points[i].pressure
            let point = points[i].point
            let vector = points[i].vector
            let distance = points[i].distance
            let running = points[i].runningLength
            let isLast = i == points.count - 1

            if !isLast && totalLength - running < endNoiseThreshold { continue }

            if o.thinning != 0 {
                if o.simulatePressure { pressure = simulate(prevPressure, distance, size) }
                r = radius(size, o.thinning, pressure)
            } else {
                r = size / 2
            }
            if firstRadius == nil { firstRadius = r }

            let ts = running < taperStart ? easeStart(running / taperStart) : 1
            let te = totalLength - running < taperEnd ? easeEnd((totalLength - running) / taperEnd) : 1
            r = max(minRadius, r * min(ts, te))

            let nextVector = (!isLast ? points[i + 1] : points[i]).vector
            let nextDpr = !isLast ? vector.dot(nextVector) : 1.0
            let prevDpr = vector.dot(prevVector)
            let isPointSharp = prevDpr < 0 && !prevSharp
            let isNextSharp = nextDpr < 0

            if isPointSharp || isNextSharp {
                let offset = prevVector.per * r
                let step = 1 / cornerCapSegments
                var t = 0.0
                while t <= 1 {
                    tempLeft = (point - offset).rotated(around: point, by: fixedPI * t)
                    left.append(tempLeft)
                    tempRight = (point + offset).rotated(around: point, by: fixedPI * -t)
                    right.append(tempRight)
                    t += step
                }
                prevLeft = tempLeft
                prevRight = tempRight
                if isNextSharp { prevSharp = true }
                continue
            }
            prevSharp = false

            if isLast {
                let offset = vector.per * r
                left.append(point - offset)
                right.append(point + offset)
                continue
            }

            let offset = V2.lerp(nextVector, vector, nextDpr).per * r
            tempLeft = point - offset
            if i <= 1 || prevLeft.dist2(tempLeft) > minDistance {
                left.append(tempLeft)
                prevLeft = tempLeft
            }
            tempRight = point + offset
            if i <= 1 || prevRight.dist2(tempRight) > minDistance {
                right.append(tempRight)
                prevRight = tempRight
            }
            prevPressure = pressure
            prevVector = vector
        }

        let firstPoint = points[0].point
        let lastPoint = points.count > 1 ? points[points.count - 1].point : points[0].point + V2(1, 1)
        var startCap: [V2] = []
        var endCap: [V2] = []

        if points.count == 1 {
            if !(taperStart > 0 || taperEnd > 0) || o.last {
                return dot(firstPoint, firstRadius ?? r)
            }
        } else {
            if taperStart > 0 {
                // tapered start: no cap
            } else if o.capStart {
                startCap = roundStartCap(firstPoint, right.first ?? firstPoint)
            } else {
                startCap = flatStartCap(firstPoint, left.first ?? firstPoint, right.first ?? firstPoint)
            }
            let direction = (-points[points.count - 1].vector).per
            if taperEnd > 0 {
                endCap = [lastPoint]
            } else if o.capEnd {
                endCap = roundEndCap(lastPoint, direction, r)
            } else {
                endCap = flatEndCap(lastPoint, direction, r)
            }
        }
        return left + endCap + right.reversed() + startCap
    }

    private static func dot(_ c: V2, _ r: Double) -> [V2] {
        let offsetPoint = c + V2(1, 1)
        let start = c + (c - offsetPoint).per.unit * (-r)
        var pts: [V2] = []
        let step = 1 / startCapSegments
        var t = step
        while t <= 1 { pts.append(start.rotated(around: c, by: fixedPI * 2 * t)); t += step }
        return pts
    }

    private static func roundStartCap(_ center: V2, _ rightPoint: V2) -> [V2] {
        var cap: [V2] = []
        let step = 1 / startCapSegments
        var t = step
        while t <= 1 { cap.append(rightPoint.rotated(around: center, by: fixedPI * t)); t += step }
        return cap
    }

    private static func flatStartCap(_ center: V2, _ leftPoint: V2, _ rightPoint: V2) -> [V2] {
        let cv = leftPoint - rightPoint
        let a = cv * 0.5, b = cv * 0.51
        return [center - a, center - b, center + b, center + a]
    }

    private static func roundEndCap(_ center: V2, _ direction: V2, _ radius: Double) -> [V2] {
        var cap: [V2] = []
        let start = center + direction * radius
        let step = 1 / endCapSegments
        var t = step
        while t < 1 { cap.append(start.rotated(around: center, by: fixedPI * 3 * t)); t += step }
        return cap
    }

    private static func flatEndCap(_ center: V2, _ direction: V2, _ radius: Double) -> [V2] {
        [center + direction * radius, center + direction * (radius * 0.99),
         center - direction * (radius * 0.99), center - direction * radius]
    }
}

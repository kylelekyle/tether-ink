import Foundation

/// A brush preset. `size` is the diameter at full pressure, in canvas pixels. Smoothing values run 0…1.
struct Brush: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var set: String
    var size: Double
    var thinning: Double
    var taperStart: Double
    var taperEnd: Double
    var smoothing: Double
    var gamma: Double
    var streamline: Double = 0.1
    var slPressure: Double = 0.15
    var stab: Double = 0
    var stabSpeed: Double = 0.5
    var motion: Double = 0.3
    var motionExpr: Double = 0
    var mode: String? = nil     // erasers: "cut" or "whole"
    var note: String? = nil

    static let keys = ["size", "thinning", "taperStart", "taperEnd", "smoothing", "gamma", "streamline", "slPressure", "stab", "stabSpeed", "motion", "motionExpr"]

    subscript(key: String) -> Double {
        get {
            switch key {
            case "size": return size
            case "thinning": return thinning
            case "taperStart": return taperStart
            case "taperEnd": return taperEnd
            case "smoothing": return smoothing
            case "gamma": return gamma
            case "streamline": return streamline
            case "slPressure": return slPressure
            case "stab": return stab
            case "stabSpeed": return stabSpeed
            case "motion": return motion
            case "motionExpr": return motionExpr
            default: return 0
            }
        }
        set {
            switch key {
            case "size": size = newValue
            case "thinning": thinning = newValue
            case "taperStart": taperStart = newValue
            case "taperEnd": taperEnd = newValue
            case "smoothing": smoothing = newValue
            case "gamma": gamma = newValue
            case "streamline": streamline = newValue
            case "slPressure": slPressure = newValue
            case "stab": stab = newValue
            case "stabSpeed": stabSpeed = newValue
            case "motion": motion = newValue
            case "motionExpr": motionExpr = newValue
            default: break
            }
        }
    }

    var isEraser: Bool { mode != nil }

    /// The shape stored with every stroke (input smoothing is already baked into the points).
    var shape: BrushShape { BrushShape(size: size, thin: thinning, ts: taperStart, te: taperEnd, sm: smoothing, sl: 0, g: gamma, sim: false) }

    static let sets: [(id: String, name: String)] = [("inking", "Inking"), ("paint", "Painting"), ("mine", "My brushes")]

    static let builtIn: [Brush] = [
        Brush(id: "studio", name: "Studio Pen", set: "inking", size: 3, thinning: 0.55, taperStart: 0.12, taperEnd: 0.28, smoothing: 0.5, gamma: 1),
        Brush(id: "tech", name: "Technical Pen", set: "inking", size: 2, thinning: 0, taperStart: 0, taperEnd: 0, smoothing: 0.5, gamma: 1, streamline: 0.1),
        Brush(id: "fine", name: "Fine Liner", set: "inking", size: 1.4, thinning: 0.25, taperStart: 0.06, taperEnd: 0.1, smoothing: 0.5, gamma: 1),
        Brush(id: "hair", name: "Hairline Taper", set: "inking", size: 2.4, thinning: 0.7, taperStart: 0.55, taperEnd: 0.8, smoothing: 0.55, gamma: 1.1, streamline: 0.1, stab: 0.1),
        Brush(id: "gel", name: "Gel Pen", set: "inking", size: 2.6, thinning: 0.3, taperStart: 0.04, taperEnd: 0.08, smoothing: 0.5, gamma: 0.9, streamline: 0.1),
        Brush(id: "brushpen", name: "Brush Pen", set: "inking", size: 6, thinning: 0.9, taperStart: 0.45, taperEnd: 0.7, smoothing: 0.6, gamma: 1.35, streamline: 0.1, slPressure: 0.3),
        Brush(id: "ink", name: "Ink Brush", set: "paint", size: 9, thinning: 0.82, taperStart: 0.3, taperEnd: 0.55, smoothing: 0.6, gamma: 1.25, streamline: 0.1),
        Brush(id: "round", name: "Round Fill", set: "paint", size: 40, thinning: 0.35, taperStart: 0.05, taperEnd: 0.1, smoothing: 0.5, gamma: 1, streamline: 0.1),
        Brush(id: "marker", name: "Flat Marker", set: "paint", size: 26, thinning: 0, taperStart: 0, taperEnd: 0, smoothing: 0.5, gamma: 1, streamline: 0.1)
    ]

    static let erasers: [Brush] = [
        Brush(id: "cut", name: "Vector Eraser", set: "eraser", size: 14, thinning: 0, taperStart: 0, taperEnd: 0, smoothing: 0.5, gamma: 1, streamline: 0.15, mode: "cut", note: "Cuts through lines like a real eraser"),
        Brush(id: "whole", name: "Stroke Eraser", set: "eraser", size: 10, thinning: 0, taperStart: 0, taperEnd: 0, smoothing: 0.5, gamma: 1, streamline: 0, mode: "whole", note: "Removes any whole stroke it touches")
    ]
}

let sizeMin = 0.3, sizeMax = 400.0
func sizeToV(_ s: Double) -> Double { log(max(s, sizeMin) / sizeMin) / log(sizeMax / sizeMin) }
func vToSize(_ v: Double) -> Double { sizeMin * pow(sizeMax / sizeMin, clampD(v, 0, 1)) }
func fmtSize(_ s: Double) -> String { s < 10 ? String(format: "%.1f px", s) : "\(Int(s.rounded())) px" }
func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

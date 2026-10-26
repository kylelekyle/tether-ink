import Foundation

/// Everything the person sets up once and expects to stay put. Saved to UserDefaults as JSON.
struct Prefs: Codable, Equatable {
    var brushId = "studio"
    var eraserId = "cut"
    var brushOverrides: [String: [String: Double]] = [:]
    var customBrushes: [Brush] = []
    var color = "#111111"
    var opacityBrush = 1.0
    var opacityEraser = 1.0
    var colorHistory: [String] = []
    var palette: [String] = []
    // lifting the pencil
    var catchUp = false
    // smoothing for every brush
    var gStab = 0.0
    var gMotion = 0.0
    var gMotionExpr = 0.5
    var curve: [[Double]] = [[0, 0], [1, 1]]
    var snap = true
    var snapDelay = 0.55
    // interface
    var rightHand = false
    var fingerDraw = false
    var rotate = true
    var pencilTap = "swap"       // swap | system | off
    var pencilSqueeze = "colour" // colour | brushes | swap | off

    init() {}

    enum CodingKeys: String, CodingKey {
        case brushId, eraserId, brushOverrides, customBrushes, color, opacityBrush, opacityEraser, colorHistory, palette
        case catchUp, gStab, gMotion, gMotionExpr, curve, snap, snapDelay
        case rightHand, fingerDraw, rotate, pencilTap, pencilSqueeze
    }

    // Every key is optional so that adding settings later never wipes saved ones.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        let base = Prefs()
        brushId = v(.brushId, base.brushId)
        eraserId = v(.eraserId, base.eraserId)
        brushOverrides = v(.brushOverrides, base.brushOverrides)
        customBrushes = v(.customBrushes, base.customBrushes)
        color = v(.color, base.color)
        opacityBrush = v(.opacityBrush, base.opacityBrush)
        opacityEraser = v(.opacityEraser, base.opacityEraser)
        colorHistory = v(.colorHistory, base.colorHistory)
        palette = v(.palette, base.palette).filter(isHexColor)
        catchUp = v(.catchUp, base.catchUp)
        gStab = v(.gStab, base.gStab)
        gMotion = v(.gMotion, base.gMotion)
        gMotionExpr = v(.gMotionExpr, base.gMotionExpr)
        curve = v(.curve, base.curve)
        if curve.count < 2 || curve.contains(where: { $0.count != 2 }) { curve = base.curve }
        snap = v(.snap, base.snap)
        snapDelay = v(.snapDelay, base.snapDelay)
        rightHand = v(.rightHand, base.rightHand)
        fingerDraw = v(.fingerDraw, base.fingerDraw)
        rotate = v(.rotate, base.rotate)
        pencilTap = v(.pencilTap, base.pencilTap)
        pencilSqueeze = v(.pencilSqueeze, base.pencilSqueeze)
    }

    static func load() -> Prefs {
        guard let data = UserDefaults.standard.data(forKey: "prefs"), let p = try? JSONDecoder().decode(Prefs.self, from: data) else { return Prefs() }
        return p
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "prefs") }
    }
}

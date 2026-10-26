import UIKit

/// One pixel stroke being painted. Dabs go into a "wet" coverage buffer (grey, tiled like the layer); the part of the
/// line that can still move (the tail) is painted into a second buffer that's cleared every frame. On lift the wet
/// buffer, with grain, is laid onto the layer's tiles in the stroke's colour and opacity.
/// Within a stroke dabs never build past their own opacity (like Procreate's glazed paint).
final class PixelStroke {
    let params: PixelParams
    let stamp: StampParams
    let size: Double
    let seed: UInt64
    let erase: Bool
    let docW: Double, docH: Double
    let step: Double
    private let tip: PixelTip
    private let grain: [UInt8]?
    private let grainPeriod: Double
    private var wet: [Int: CGContext] = [:]
    private var tail: [Int: CGContext] = [:]
    private var tailUsed = Set<Int>()
    private var grainTiles: [Int: [UInt8]] = [:]
    private(set) var dirty = Set<Int>()
    private var stampS = 0.0
    private var stampLast: V2?
    private var shown: [Int: CALayer] = [:]
    static let T = Tiles.size

    init(brush: Brush, seed: UInt64, erase: Bool, docW: Double, docH: Double) {
        var p = brush.pixel ?? PixelParams.make(hardness: 0.85)
        var k = brush.stamp ?? StampParams(spacing: 0.06)
        if erase && !brush.isPixel { p = PixelParams.make(hardness: 0.85); k = StampParams(spacing: 0.06) }
        params = p; stamp = k
        size = max(0.3, brush.size)
        self.seed = seed; self.erase = erase; self.docW = docW; self.docH = docH
        step = max(0.35, max(k.spacing, 0.02) * size)
        tip = PixelAssets.tip(p)
        grain = PixelAssets.grain(p)
        grainPeriod = 64 + clampD(p.grainScale, 0, 1) * 960
    }

    var isEmpty: Bool { wet.isEmpty }

    // MARK: painting

    /// Paints a final stretch of the line into the wet buffer, numbering dabs on from the stretches before it.
    func advance(_ pts: [Double]) {
        guard pts.count >= 3 else { return }
        var s0 = stampS
        if let l = stampLast { s0 += l.dist(V2(pts[0], pts[1])) }
        let len = StrokeGeometry.arcLength(pts)
        for d in StrokeGeometry.dabs(pts, stamp, step: step, seed: seed, s0: s0, end: s0 + len, limit: 400_000) { dab(d, wet: true) }
        stampS = s0 + len
        stampLast = V2(pts[pts.count - 3], pts[pts.count - 2])
    }

    /// Repaints the moving tail (from where the wet paint ends).
    func paintTail(_ pts: [Double]) {
        clearTail()
        guard pts.count >= 3 else { return }
        var s0 = stampS
        if let l = stampLast { s0 += l.dist(V2(pts[0], pts[1])) }
        for d in StrokeGeometry.dabs(pts, stamp, step: step, seed: seed, s0: s0, end: nil, limit: 100_000) { dab(d, wet: false) }
    }

    func clearTail() {
        for k in tailUsed { if let c = tail[k] { blank(c) }; dirty.insert(k) }
        tailUsed.removeAll()
    }

    /// Starts over (a snapped shape replaces the line).
    func reset() {
        for (k, c) in wet { blank(c); dirty.insert(k) }
        clearTail()
        stampS = 0; stampLast = nil
    }

    private func blank(_ c: CGContext) {
        c.saveGState()
        c.setBlendMode(.copy)
        c.setFillColor(gray: 0, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: Self.T, height: Self.T))
        c.restoreGState()
    }

    private func buffer(_ k: Int, wet w: Bool) -> CGContext? {
        if let c = w ? wet[k] : tail[k] { return c }
        guard let c = CGContext(data: nil, width: Self.T, height: Self.T, bitsPerComponent: 8, bytesPerRow: Self.T,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        blank(c)
        c.setBlendMode(.lighten)
        c.interpolationQuality = .medium
        if w { wet[k] = c } else { tail[k] = c }
        return c
    }

    private func dab(_ d: StrokeGeometry.Dab, wet w: Bool) {
        var D = 2 * d.r
        guard D > 0.05 else { return }
        let q = clampD(d.lineR / (size / 2), 0, 1)
        var a = params.flow * (1 - params.pressureOpacity * (1 - q)) * (1 - params.opacityJitter * d.rnd)
        if D < 1 { a *= D; D = 1 }       // dabs under a pixel fade instead of vanishing
        guard a > 0.002 else { return }
        let R = D * 0.71 + 1
        let img = tip.image(forDiameter: D)
        let rect = CGRect(x: -D / 2, y: -D / 2, width: D, height: D)
        for k in Tiles.keys(in: CGRect(x: d.x - R, y: d.y - R, width: 2 * R, height: 2 * R), w: docW, h: docH) {
            guard let c = buffer(k, wet: w) else { continue }
            let o = Tiles.origin(k)
            c.saveGState()
            // tile buffers have a bottom-left origin: flip canvas y into them
            c.translateBy(x: d.x - Double(o.x), y: Double(Self.T) - (d.y - Double(o.y)))
            if d.angle != 0 { c.rotate(by: -d.angle) }
            c.clip(to: rect, mask: img)
            c.setFillColor(gray: a, alpha: 1)
            c.fill(rect)
            c.restoreGState()
            dirty.insert(k)
            if !w { tailUsed.insert(k) }
        }
    }

    // MARK: coverage

    private func bytes(_ c: CGContext) -> UnsafeMutablePointer<UInt8>? { c.data?.assumingMemoryBound(to: UInt8.self) }

    /// How strongly the grain lets paint through on a tile (255 = fully), in canvas space so it stays put.
    private func grainTile(_ k: Int) -> [UInt8]? {
        guard let g = grain else { return nil }
        if let t = grainTiles[k] { return t }
        let o = Tiles.origin(k), T = Self.T, G = PixelAssets.grainSize
        let depth = clampD(params.grainDepth, 0, 1)
        var out = [UInt8](repeating: 255, count: T * T)
        let per = Double(G) / grainPeriod
        for y in 0..<T {
            let gy = Int(Double(o.y + y) * per) & (G - 1)
            for x in 0..<T {
                let gx = Int(Double(o.x + x) * per) & (G - 1)
                let v = Double(g[gy * G + gx])
                out[y * T + x] = UInt8((255 - depth * (255 - v)).rounded())
            }
        }
        grainTiles[k] = out
        return out
    }

    /// Coverage of a tile (0…255, top row first): wet paint, plus the tail if asked, through the grain.
    func coverage(_ k: Int, withTail: Bool) -> [UInt8] {
        let n = Self.T * Self.T
        var out = [UInt8](repeating: 0, count: n)
        if let c = wet[k], let p = bytes(c) { for i in 0..<n { out[i] = p[i] } }
        if withTail, tailUsed.contains(k), let c = tail[k], let p = bytes(c) { for i in 0..<n where p[i] > out[i] { out[i] = p[i] } }
        if let g = grainTile(k) { for i in 0..<n where out[i] != 0 { out[i] = UInt8((Int(out[i]) * Int(g[i]) + 127) / 255) } }
        return out
    }

    // MARK: live display

    /// Brings the on-screen tiles up to date. The container is in canvas units.
    func show(in container: CALayer, color: String) {
        guard !dirty.isEmpty else { return }
        let (r, g, b) = rgba(hex: color)
        let cr = Int(r * 255), cg = Int(g * 255), cb = Int(b * 255)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for k in dirty {
            let cov = coverage(k, withTail: true)
            var px = [UInt8](repeating: 0, count: cov.count * 4)
            for i in 0..<cov.count where cov[i] != 0 {
                let a = Int(cov[i])
                px[i * 4] = UInt8((cr * a + 127) / 255); px[i * 4 + 1] = UInt8((cg * a + 127) / 255)
                px[i * 4 + 2] = UInt8((cb * a + 127) / 255); px[i * 4 + 3] = UInt8(a)
            }
            let l: CALayer
            if let s = shown[k] { l = s } else {
                l = CALayer()
                l.frame = Tiles.rect(k)
                l.contentsGravity = .resize
                l.magnificationFilter = .linear
                container.addSublayer(l)
                shown[k] = l
            }
            l.contents = PixelPaint.rgbaImage(px, Self.T)
        }
        CATransaction.commit()
        dirty.removeAll()
    }

    // MARK: committing

    /// The layer's tiles with the stroke laid on: the new image for each tile it touched.
    func commit(onto tiles: [Int: CGImage], color: String, opacity: Double) -> [Int: CGImage] {
        var out: [Int: CGImage] = [:]
        let full = CGRect(x: 0, y: 0, width: Self.T, height: Self.T)
        for k in wet.keys {
            let cov = coverage(k, withTail: false)
            if !cov.contains(where: { $0 != 0 }) { continue }
            if erase && tiles[k] == nil { continue }
            guard let mask = PixelAssets.greyImage(cov, Self.T), let c = Tiles.context() else { continue }
            if let old = tiles[k] { c.draw(old, in: full) }
            c.clip(to: full, mask: mask)
            if erase {
                c.setBlendMode(.destinationOut)
                c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: CGFloat(opacity)))
            } else {
                c.setFillColor(cgColor(hex: color, alpha: CGFloat(opacity)))
            }
            c.fill(full)
            if let img = c.makeImage() { out[k] = img }
        }
        return out
    }
}

enum PixelPaint {
    /// An image from premultiplied sRGB RGBA bytes.
    static func rgbaImage(_ px: [UInt8], _ n: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: Tiles.space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A colour fill laid under a pixel layer's paint: the new image for each tile it touched.
    static func fill(_ tiles: [Int: CGImage], polygons: [[Double]], color: String, opacity: Double, w: Double, h: Double) -> [Int: CGImage] {
        let path = StrokeGeometry.polygonsPath(polygons)
        guard !path.isEmpty else { return [:] }
        var out: [Int: CGImage] = [:]
        let T = Tiles.size
        let full = CGRect(x: 0, y: 0, width: T, height: T)
        for k in Tiles.keys(in: path.boundingBoxOfPath.insetBy(dx: -1, dy: -1), w: w, h: h) {
            guard let c = Tiles.context() else { continue }
            let o = Tiles.origin(k)
            c.saveGState()
            c.translateBy(x: 0, y: CGFloat(T))
            c.scaleBy(x: 1, y: -1)
            c.translateBy(x: CGFloat(-o.x), y: CGFloat(-o.y))
            c.addPath(path)
            c.setFillColor(cgColor(hex: color, alpha: CGFloat(opacity)))
            c.fillPath(using: .evenOdd)
            c.restoreGState()
            if let old = tiles[k] { c.draw(old, in: full) }
            if let img = c.makeImage() { out[k] = img }
        }
        return out
    }

    /// A brush's stroke on a small transparent image (library rows, the brush editor).
    static func preview(_ brush: Brush, width: Int, height: Int, color: String = "#111111", lines: [[Double]]) -> CGImage? {
        let s = PixelStroke(brush: brush, seed: 7, erase: false, docW: Double(width), docH: Double(height))
        for p in lines { s.advance(StrokeGeometry.bake(p, brush.shape)) }
        let tiles = s.commit(onto: [:], color: color, opacity: 1)
        guard let ctx = DocRenderer.makeContext(width, height) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        Tiles.draw(tiles, in: ctx, visible: nil)
        return ctx.makeImage()
    }
}

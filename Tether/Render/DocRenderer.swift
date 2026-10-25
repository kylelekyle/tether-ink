import UIKit

/// An immutable copy of a layer, safe to hand to the render queue.
struct LayerSnap {
    let items: [Item]
    let visible: Bool
    let opacity: Double
    let hasErase: Bool
    init(_ l: Layer) { items = l.items; visible = l.visible; opacity = l.opacity; hasErase = l.hasErase }
}

func rgba(hex: String) -> (CGFloat, CGFloat, CGFloat) {
    var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    let n = UInt32(s, radix: 16) ?? 0
    return (CGFloat((n >> 16) & 255) / 255, CGFloat((n >> 8) & 255) / 255, CGFloat(n & 255) / 255)
}
func cgColor(hex: String, alpha: CGFloat = 1) -> CGColor {
    let (r, g, b) = rgba(hex: hex)
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}
func uiColor(hex: String) -> UIColor { let (r, g, b) = rgba(hex: hex); return UIColor(red: r, green: g, blue: b, alpha: 1) }
func hexString(_ c: UIColor) -> String {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    let conv = c.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil).map { UIColor(cgColor: $0) } ?? c
    conv.getRed(&r, green: &g, blue: &b, alpha: &a)
    func h(_ v: CGFloat) -> String { String(format: "%02x", Int((clampD(Double(v), 0, 1) * 255).rounded())) }
    return "#" + h(r) + h(g) + h(b)
}

/// Decoded embedded photos, cached by item id.
final class ImageCache {
    static let shared = ImageCache()
    private var cache: [String: CGImage] = [:]
    private let lock = NSLock()
    func get(_ it: ImageItem) -> CGImage? {
        lock.lock()
        if let c = cache[it.id] { lock.unlock(); return c }
        lock.unlock()
        guard let comma = it.src.firstIndex(of: ","), let data = Data(base64Encoded: String(it.src[it.src.index(after: comma)...])),
              let img = UIImage(data: data)?.cgImage else { return nil }
        lock.lock(); cache[it.id] = img; lock.unlock()
        return img
    }
}

enum DocRenderer {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func makeContext(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Flip to a top-left origin and apply `scale` (pixels per point) and `view` (canvas → points).
    static func applyView(_ ctx: CGContext, height: Int, scale: CGFloat, view: CGAffineTransform) {
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(view)
    }

    static func drawItems(_ ctx: CGContext, _ items: [Item], visible: CGRect?) {
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        for it in items {
            switch it {
            case .stroke(let s):
                let g = GeometryCache.shared.get(s)
                if g.bbox.isNull { continue }
                if let v = visible, !g.bbox.insetBy(dx: -1, dy: -1).intersects(v) { continue }
                ctx.setBlendMode(s.isErase ? .destinationOut : .normal)
                ctx.setAlpha(CGFloat(s.o))
                ctx.setFillColor(s.isErase ? black : cgColor(hex: s.c))
                ctx.addPath(g.path)
                ctx.fillPath(using: .winding)
            case .image(let im):
                guard let cg = ImageCache.shared.get(im) else { continue }
                ctx.setBlendMode(.normal)
                ctx.setAlpha(CGFloat(im.opacity))
                ctx.saveGState()
                ctx.translateBy(x: im.x, y: im.y + im.h)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: im.w, height: im.h))
                ctx.restoreGState()
            }
        }
        ctx.setBlendMode(.normal)
        ctx.setAlpha(1)
    }

    // MARK: screen caches

    struct ScreenJob {
        let layers: [LayerSnap]
        let active: Int
        let docW: Double
        let docH: Double
        let view: CGAffineTransform   // canvas → points
        let pxW: Int
        let pxH: Int
        let scale: CGFloat
        let activeOnly: Bool
    }
    struct ScreenResult {
        let below: CGImage?
        let active: CGImage?
        let above: CGImage?
        let view: CGAffineTransform
        let activeOnly: Bool
    }

    static func renderScreen(_ j: ScreenJob) -> ScreenResult {
        let ptsW = CGFloat(j.pxW) / j.scale, ptsH = CGFloat(j.pxH) / j.scale
        let vis = CGRect(x: 0, y: 0, width: ptsW, height: ptsH).applying(j.view.inverted())
        let page = CGRect(x: 0, y: 0, width: j.docW, height: j.docH)

        func drawLayer(_ ctx: CGContext, _ L: LayerSnap) {
            ctx.saveGState()
            applyView(ctx, height: j.pxH, scale: j.scale, view: j.view)
            ctx.clip(to: page)
            drawItems(ctx, L.items, visible: vis)
            ctx.restoreGState()
        }
        func layerImage(_ L: LayerSnap) -> CGImage? {
            guard let ctx = makeContext(j.pxW, j.pxH) else { return nil }
            if L.visible { drawLayer(ctx, L) }
            return ctx.makeImage()
        }
        func composite(_ range: Range<Int>) -> CGImage? {
            guard let ctx = makeContext(j.pxW, j.pxH) else { return nil }
            for i in range {
                let L = j.layers[i]
                if !L.visible || L.opacity <= 0 { continue }
                if L.opacity >= 1 && !L.hasErase {
                    drawLayer(ctx, L)
                } else if let img = layerImage(L) {
                    ctx.setAlpha(CGFloat(L.opacity))
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: j.pxW, height: j.pxH))
                    ctx.setAlpha(1)
                }
            }
            return ctx.makeImage()
        }
        let a = max(0, min(j.active, j.layers.count - 1))
        let active = j.layers.isEmpty ? nil : layerImage(j.layers[a])
        if j.activeOnly { return ScreenResult(below: nil, active: active, above: nil, view: j.view, activeOnly: true) }
        let below = composite(0..<a)
        let above = composite((a + 1)..<max(a + 1, j.layers.count))
        return ScreenResult(below: below, active: active, above: above, view: j.view, activeOnly: false)
    }

    // MARK: whole document (export, thumbnails, colour picking)

    static func renderDoc(layers: [LayerSnap], w: Double, h: Double, bg: String?, scale: Double,
                          origin: CGPoint = .zero, pixelSize: (Int, Int)? = nil) -> CGImage? {
        let pw = pixelSize?.0 ?? max(1, Int((w * scale).rounded()))
        let ph = pixelSize?.1 ?? max(1, Int((h * scale).rounded()))
        guard let ctx = makeContext(pw, ph) else { return nil }
        let view = CGAffineTransform(translationX: -origin.x, y: -origin.y)
        if let bg = bg {
            ctx.saveGState()
            applyView(ctx, height: ph, scale: CGFloat(scale), view: view)
            ctx.setFillColor(cgColor(hex: bg))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.restoreGState()
        }
        for L in layers where L.visible && L.opacity > 0 {
            if L.opacity >= 1 && !L.hasErase {
                ctx.saveGState()
                applyView(ctx, height: ph, scale: CGFloat(scale), view: view)
                ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
                drawItems(ctx, L.items, visible: nil)
                ctx.restoreGState()
            } else {
                guard let lc = makeContext(pw, ph) else { continue }
                applyView(lc, height: ph, scale: CGFloat(scale), view: view)
                lc.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
                drawItems(lc, L.items, visible: nil)
                if let img = lc.makeImage() {
                    ctx.setAlpha(CGFloat(L.opacity))
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: pw, height: ph))
                    ctx.setAlpha(1)
                }
            }
        }
        return ctx.makeImage()
    }

    static func renderDoc(_ doc: Doc, scale: Double, background: Bool = true) -> CGImage? {
        renderDoc(layers: doc.layers.map(LayerSnap.init), w: doc.w, h: doc.h, bg: (background && doc.bgOn) ? doc.bg : nil, scale: scale)
    }

    static func thumbnail(_ doc: Doc, maxSide: Double = 360) -> UIImage? {
        let k = min(1, maxSide / max(doc.w, doc.h))
        guard let img = renderDoc(layers: doc.layers.map(LayerSnap.init), w: doc.w, h: doc.h, bg: doc.bgOn ? doc.bg : "#ffffff", scale: k) else { return nil }
        return UIImage(cgImage: img)
    }

    /// The colour of the drawing at a canvas point (what you see, background included).
    static func sampleColor(_ doc: Doc, at p: CGPoint) -> String? {
        guard let img = renderDoc(layers: doc.layers.map(LayerSnap.init), w: doc.w, h: doc.h, bg: doc.bgOn ? doc.bg : nil, scale: 1,
                                  origin: CGPoint(x: p.x - 0.5, y: p.y - 0.5), pixelSize: (1, 1)),
              let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let a = CGFloat(ptr[3]) / 255
        if a < 0.02 { return doc.bgOn ? doc.bg : nil }
        func c(_ v: UInt8) -> CGFloat { min(1, CGFloat(v) / 255 / a) }
        return hexString(UIColor(red: c(ptr[0]), green: c(ptr[1]), blue: c(ptr[2]), alpha: 1))
    }
}

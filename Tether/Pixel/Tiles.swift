import UIKit
import ImageIO

/// Pixel layers are stored as 256 px tiles at the drawing's resolution (one pixel per canvas unit), only where painted.
/// Tiles are immutable images: painting makes new ones, so the render queue and saving can read them at any time.
enum Tiles {
    static let size = 256
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func key(_ c: Int, _ r: Int) -> Int { r << 16 | c }
    static func col(_ k: Int) -> Int { k & 0xFFFF }
    static func row(_ k: Int) -> Int { k >> 16 }
    static func origin(_ k: Int) -> (x: Int, y: Int) { (col(k) * size, row(k) * size) }
    static func rect(_ k: Int) -> CGRect { let o = origin(k); return CGRect(x: o.x, y: o.y, width: size, height: size) }
    static func name(_ k: Int) -> String { "\(col(k)),\(row(k))" }
    static func key(name: String) -> Int? {
        let p = name.split(separator: ",")
        guard p.count == 2, let c = Int(p[0]), let r = Int(p[1]), c >= 0, r >= 0, c < 0x8000, r < 0x8000 else { return nil }
        return key(c, r)
    }

    /// The tiles a canvas rectangle touches, inside a w × h drawing.
    static func keys(in r: CGRect, w: Double, h: Double) -> [Int] {
        let page = CGRect(x: 0, y: 0, width: w, height: h)
        let q = r.intersection(page)
        guard !q.isNull, q.width > 0, q.height > 0 else { return [] }
        let c0 = Int(q.minX) / size, c1 = Int(ceil(q.maxX) - 1) / size
        let r0 = Int(q.minY) / size, r1 = Int(ceil(q.maxY) - 1) / size
        var out: [Int] = []
        for rr in r0...max(r0, r1) { for cc in c0...max(c0, c1) { out.append(key(cc, rr)) } }
        return out
    }

    /// A fresh colour tile (sRGB, premultiplied alpha), drawn with its top row first like every bitmap context.
    static func context() -> CGContext? {
        CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws tiles into a context already set up for canvas units with a top-left origin.
    static func draw(_ tiles: [Int: CGImage], in ctx: CGContext, visible: CGRect?) {
        for (k, img) in tiles {
            let r = rect(k)
            if let v = visible, !r.intersects(v) { continue }
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
            ctx.restoreGState()
        }
    }

    /// The alpha of a tile (top row first).
    static func alpha(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return (0..<(size * size)).map { px[$0 * 4 + 3] }
    }

    // MARK: PNG, cached per tile image so saving only encodes what changed

    private static let pngCache = NSMapTable<AnyObject, NSData>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static let lock = NSLock()

    static func png(_ img: CGImage) -> Data? {
        lock.lock()
        if let d = pngCache.object(forKey: img) { lock.unlock(); return d as Data }
        lock.unlock()
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        lock.lock(); pngCache.setObject(out, forKey: img); lock.unlock()
        return out as Data
    }

    static func image(png data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        // redraw into our own format so painting onto it later is exact
        guard let ctx = context() else { return nil }
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let img = ctx.makeImage() else { return nil }
        lock.lock(); pngCache.setObject(data as NSData, forKey: img); lock.unlock()
        return img
    }

    /// Layer JSON: {"c,r": base64 PNG}.
    static func encode(_ tiles: [Int: CGImage]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, img) in tiles { if let d = png(img) { out[name(k)] = d.base64EncodedString() } }
        return out
    }
    static func decode(_ m: [String: String]) -> [Int: CGImage] {
        var out: [Int: CGImage] = [:]
        for (n, b64) in m {
            guard let k = key(name: n), let d = Data(base64Encoded: b64), let img = image(png: d) else { continue }
            out[k] = img
        }
        return out
    }
}

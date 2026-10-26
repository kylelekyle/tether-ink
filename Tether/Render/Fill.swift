import Foundation
import CoreGraphics

/// Colour drop: the area around a point, bounded by everything drawn, as vector polygons.
/// 1. Draw every visible stroke and fill into a coverage mask (erasers take ink away, photos are ignored).
/// 2. Flood fill from the point. A pixel within 1 px of ink counts as blocked, which closes gaps up to about 2 px.
/// 3. Tuck the fill under the lines: climb toward each line's darkest point but never down its far side,
///    so the edge hides under the line without crossing even a hairline.
/// 4. Trace the pixel edges into loops (enclosed shapes come out as holes) and simplify them.
enum FloodFill {
    private static let wall: UInt8 = 26       // coverage that counts as ink

    /// Polygons (flat x, y lists, canvas units) to fill with the even-odd rule, or nil if the point is on a line.
    static func region(_ layers: [[Item]], w: Double, h: Double, seed: V2) -> [[Double]]? {
        let k = min(1.0, 4096 / max(w, h, 1))
        let W = max(1, Int((w * k).rounded(.up))), H = max(1, Int((h * k).rounded(.up)))
        guard seed.x >= 0, seed.y >= 0 else { return nil }
        let sx = Int(seed.x * k), sy = Int(seed.y * k)
        guard sx < W, sy < H, let cov = coverage(layers, W: W, H: H, k: k) else { return nil }

        func blocked(_ x: Int, _ y: Int) -> Bool {
            for yy in max(0, y - 1)...min(H - 1, y + 1) {
                let row = yy * W
                for xx in max(0, x - 1)...min(W - 1, x + 1) where cov[row + xx] >= wall { return true }
            }
            return false
        }
        if blocked(sx, sy) { return nil }

        // 2. scanline flood fill
        var reg = [UInt8](repeating: 0, count: W * H)
        var bx0 = sx, bx1 = sx, by0 = sy, by1 = sy
        var stack: [(Int, Int)] = [(sx, sy)]
        while let p = stack.popLast() {
            var x = p.0
            let y = p.1
            if reg[y * W + x] != 0 || blocked(x, y) { continue }
            while x > 0 && reg[y * W + x - 1] == 0 && !blocked(x - 1, y) { x -= 1 }
            var up = false, down = false
            while x < W && reg[y * W + x] == 0 && !blocked(x, y) {
                reg[y * W + x] = 1
                bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y)
                if y > 0 {
                    let ok = reg[(y - 1) * W + x] == 0 && !blocked(x, y - 1)
                    if ok && !up { stack.append((x, y - 1)); up = true } else if !ok { up = false }
                }
                if y < H - 1 {
                    let ok = reg[(y + 1) * W + x] == 0 && !blocked(x, y + 1)
                    if ok && !down { stack.append((x, y + 1)); down = true } else if !ok { down = false }
                }
                x += 1
            }
        }

        // 3. tuck under the lines, a step at a time from the region's edge
        var frontier: [Int] = []
        for y in by0...by1 {
            for x in bx0...bx1 {
                let i = y * W + x
                if reg[i] == 0 { continue }
                if (x > 0 && reg[i - 1] == 0) || (x < W - 1 && reg[i + 1] == 0) || (y > 0 && reg[i - W] == 0) || (y < H - 1 && reg[i + W] == 0) {
                    frontier.append(i)
                }
            }
        }
        for step in 0..<4 {
            var next: [Int] = []
            for j in frontier {
                let x = j % W, y = j / W
                let cj = cov[j]
                var around: [Int] = []
                if x > 0 { around.append(j - 1) }
                if x < W - 1 { around.append(j + 1) }
                if y > 0 { around.append(j - W) }
                if y < H - 1 { around.append(j + W) }
                for i in around where reg[i] == 0 {
                    let c = cov[i]
                    // uphill toward the line's core; level only across the 1 px gap band on the first step
                    if c > cj || (c == cj && (c > 0 || step == 0)) {
                        reg[i] = 1
                        next.append(i)
                        let ix = i % W, iy = i / W
                        bx0 = min(bx0, ix); bx1 = max(bx1, ix); by0 = min(by0, iy); by1 = max(by1, iy)
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }

        // 4. trace pixel edges, clockwise around the region (y down)
        let V = W + 1
        var nxt: [Int: [Int]] = [:]
        var starts: [Int] = []
        func edge(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) {
            let a = ay * V + ax
            nxt[a, default: []].append(by * V + bx)
            starts.append(a)
        }
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < W && y < H && reg[y * W + x] != 0 }
        for y in by0...by1 {
            for x in bx0...bx1 where reg[y * W + x] != 0 {
                if !inside(x, y - 1) { edge(x, y, x + 1, y) }
                if !inside(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                if !inside(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !inside(x - 1, y) { edge(x, y + 1, x, y) }
            }
        }
        var out: [[Double]] = []
        for s0 in starts {
            while nxt[s0] != nil {
                var loop: [V2] = []
                var v = s0
                repeat {
                    guard var outs = nxt[v], !outs.isEmpty else { break }
                    let w = outs.removeLast()
                    nxt[v] = outs.isEmpty ? nil : outs
                    loop.append(V2(Double(v % V), Double(v / V)))
                    v = w
                } while v != s0
                let poly = simplify(loop, 0.35)
                if poly.count >= 3 && abs(area(poly)) >= 3 {
                    out.append(poly.flatMap { [$0.x / k, $0.y / k] })
                }
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Ink coverage (0…255) of all the layers, at k pixels per canvas unit, top row first.
    private static func coverage(_ layers: [[Item]], W: Int, H: Int, k: Double) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: W * H)
        for items in layers {
            if items.contains(where: { $0.isErase }) {
                // an eraser only takes away its own layer's ink: draw the layer alone, then merge
                var tmp = [UInt8](repeating: 0, count: W * H)
                guard draw(items, into: &tmp, W: W, H: H, k: k) else { return nil }
                for i in 0..<out.count where tmp[i] > out[i] { out[i] = tmp[i] }
            } else {
                guard draw(items, into: &out, W: W, H: H, k: k) else { return nil }
            }
        }
        return out
    }

    private static func draw(_ items: [Item], into buf: inout [UInt8], W: Int, H: Int, k: Double) -> Bool {
        buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(H))
            ctx.scaleBy(x: CGFloat(k), y: -CGFloat(k))
            for it in items {
                switch it {
                case .stroke(let s):
                    // any ink is a wall whatever its opacity; an eraser takes ink away
                    ctx.setFillColor(gray: s.isErase ? 0 : 1, alpha: s.isErase ? CGFloat(s.o) : 1)
                    ctx.addPath(GeometryCache.shared.get(s).path)
                    ctx.fillPath(using: .winding)
                case .fill(let f):
                    ctx.setFillColor(gray: 1, alpha: 1)
                    ctx.addPath(GeometryCache.shared.get(f).path)
                    ctx.fillPath(using: .evenOdd)
                case .image:
                    continue
                }
            }
            return true
        }
    }

    /// Drop the corners that sit on a straight run, then Douglas–Peucker the closed loop.
    private static func simplify(_ loop: [V2], _ eps: Double) -> [V2] {
        let n = loop.count
        guard n >= 3 else { return loop }
        var pts: [V2] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            let a = loop[(i + n - 1) % n], b = loop[i], c = loop[(i + 1) % n]
            if (b.x - a.x) * (c.y - b.y) != (b.y - a.y) * (c.x - b.x) { pts.append(b) }
        }
        guard pts.count >= 3 else { return pts }
        pts.append(pts[0])
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let seg = stack.popLast() {
            let a = pts[seg.0], b = pts[seg.1]
            let d = b - a
            let len = d.length
            var best = -1.0, bi = -1
            if seg.1 - seg.0 >= 2 {
                for i in (seg.0 + 1)..<seg.1 {
                    let q = pts[i] - a
                    let dist: Double = len > 1e-9 ? abs(q.x * d.y - q.y * d.x) / len : q.length
                    if dist > best { best = dist; bi = i }
                }
            }
            if bi >= 0 && best > eps {
                keep[bi] = true
                stack.append((seg.0, bi))
                stack.append((bi, seg.1))
            }
        }
        var out: [V2] = []
        for i in 0..<(pts.count - 1) where keep[i] { out.append(pts[i]) }
        return out
    }

    private static func area(_ p: [V2]) -> Double {
        var s = 0.0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }
}

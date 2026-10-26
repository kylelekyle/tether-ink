import UIKit

enum Exporter {
    static func fileBase(_ doc: Doc) -> String {
        let allowed = doc.name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_" }
        let s = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        return s.isEmpty ? "drawing" : s
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private static func num(_ v: Double) -> String { let r = (v * 100).rounded() / 100; return r == r.rounded() ? String(Int(r)) : String(r) }

    /// Pure vector SVG. Layers become groups; erasers become masks over the strokes beneath them.
    static func svg(_ doc: Doc) -> String {
        var defs: [String] = [], body: [String] = [], mk = 0
        let W = num(doc.w), H = num(doc.h)
        if doc.bgOn { body.append("<rect id=\"background\" width=\"\(W)\" height=\"\(H)\" fill=\"\(doc.bg)\"/>") }
        for L in doc.layers where L.visible {
            var content = "", erasers: [String] = []
            func flushErase() {
                if erasers.isEmpty { return }
                mk += 1
                let id = "erase\(mk)"
                defs.append("<mask id=\"\(id)\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"\(W)\" height=\"\(H)\"><rect width=\"\(W)\" height=\"\(H)\" fill=\"#fff\"/>\(erasers.joined())</mask>")
                content = "<g mask=\"url(#\(id))\">\(content)</g>"
                erasers = []
            }
            for it in L.items {
                switch it {
                case .stroke(let s):
                    let d = StrokeGeometry.svgPath(StrokeGeometry.shapes(s.p, s.b, seed: StrokeGeometry.seed(s.id)))
                    if d.isEmpty { continue }
                    let op = s.o < 1 ? " fill-opacity=\"\(num(s.o))\"" : ""
                    if s.isErase { erasers.append("<path d=\"\(d)\" fill=\"#000\"\(op)/>") }
                    else { flushErase(); content += "<path d=\"\(d)\" fill=\"\(s.c)\"\(op)/>" }
                case .image(let im):
                    flushErase()
                    let op = im.opacity < 1 ? " opacity=\"\(num(im.opacity))\"" : ""
                    content += "<image href=\"\(im.src)\" x=\"\(num(im.x))\" y=\"\(num(im.y))\" width=\"\(num(im.w))\" height=\"\(num(im.h))\" preserveAspectRatio=\"none\"\(op)/>"
                case .fill(let f):
                    let d = StrokeGeometry.svgPolygons(f.p)
                    if d.isEmpty { continue }
                    flushErase()
                    let op = f.o < 1 ? " fill-opacity=\"\(num(f.o))\"" : ""
                    content += "<path d=\"\(d)\" fill=\"\(f.c)\" fill-rule=\"evenodd\"\(op)/>"
                }
            }
            flushErase()
            let op = L.opacity < 1 ? " opacity=\"\(num(L.opacity))\"" : ""
            body.append("<g id=\"\(esc(L.name.replacingOccurrences(of: " ", with: "_")))\" inkscape:groupmode=\"layer\" inkscape:label=\"\(esc(L.name))\"\(op)>\(content)</g>")
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:inkscape=\"http://www.inkscape.org/namespaces/inkscape\" width=\"\(W)\" height=\"\(H)\" viewBox=\"0 0 \(W) \(H)\">"
            + (defs.isEmpty ? "" : "<defs>\(defs.joined())</defs>") + body.joined() + "</svg>"
    }

    static func png(_ doc: Doc, scale: Double) -> Data? {
        guard let img = DocRenderer.renderDoc(doc, scale: scale, background: true) else { return nil }
        return UIImage(cgImage: img).pngData()
    }

    static func backup(_ doc: Doc) -> Data? { try? JSONEncoder().encode(doc) }

    /// Writes to a temporary file with a friendly name, ready for the share sheet.
    static func tempFile(_ name: String, _ data: Data) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// Largest PNG scale that stays within a sensible memory budget on iPad.
    static func maxPNGScale(_ doc: Doc) -> Double {
        let limit = 64_000_000.0
        return min(8, (limit / (doc.w * doc.h)).squareRoot(), 16384 / max(doc.w, doc.h))
    }
}

enum Share {
    static func present(_ items: [Any], from rect: CGRect? = nil) {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = rect ?? CGRect(x: top.view.bounds.midX, y: 60, width: 1, height: 1)
            pop.permittedArrowDirections = [.up, .down]
        }
        top.present(vc, animated: true)
    }
}

import Foundation
import UIKit

/// Drawings live as .tether.json files in the app's Documents/Drawings folder, which also shows up in the Files app.
final class Store {
    let root: URL
    private let metaDir: URL
    private let thumbDir: URL
    private let io = DispatchQueue(label: "ink.tether.store", qos: .utility)

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Drawings", isDirectory: true)
        metaDir = root.appendingPathComponent(".meta", isDirectory: true)
        thumbDir = root.appendingPathComponent(".thumbs", isDirectory: true)
        for d in [root, metaDir, thumbDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    func docURL(_ id: String) -> URL { root.appendingPathComponent("\(id).tether.json") }
    func metaURL(_ id: String) -> URL { metaDir.appendingPathComponent("\(id).json") }
    func thumbURL(_ id: String) -> URL { thumbDir.appendingPathComponent("\(id).jpg") }

    /// All drawings, newest first. Files dropped into the folder from the Files app are picked up too.
    func list() -> [DocMeta] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [DocMeta] = []
        for f in files where f.lastPathComponent.hasSuffix(".tether.json") {
            let id = String(f.lastPathComponent.dropLast(".tether.json".count))
            if let d = try? Data(contentsOf: metaURL(id)), let m = try? JSONDecoder().decode(DocMeta.self, from: d) {
                out.append(m)
            } else if let doc = load(id: id) {
                if doc.id != id { doc.id = id }
                let m = DocMeta(id: id, name: doc.name, w: doc.w, h: doc.h, created: doc.created, updated: doc.updated)
                if let md = try? JSONEncoder().encode(m) { try? md.write(to: metaURL(id), options: .atomic) }
                out.append(m)
            }
        }
        return out.sorted { $0.updated > $1.updated }
    }

    func load(id: String) -> Doc? {
        guard let data = try? Data(contentsOf: docURL(id)) else { return nil }
        return try? JSONDecoder().decode(Doc.self, from: data)
    }

    /// Takes a snapshot on the calling thread (cheap: the stroke arrays are shared, not copied),
    /// then writes the file and renders the thumbnail in the background.
    func save(_ doc: Doc) {
        let snap = DocWriter.Snapshot(doc)
        let meta = DocMeta(id: doc.id, name: doc.name, w: doc.w, h: doc.h, created: doc.created, updated: doc.updated)
        let id = doc.id
        thumbCache.removeObject(forKey: id as NSString)
        io.async { [self] in
            let data = DocWriter.json(snap)
            try? data.write(to: docURL(id), options: .atomic)
            if let m = try? JSONEncoder().encode(meta) { try? m.write(to: metaURL(id), options: .atomic) }
            let k = min(1, 360 / max(snap.w, snap.h))
            if let img = DocRenderer.renderDoc(layers: snap.renderLayers, w: snap.w, h: snap.h, bg: snap.bgOn ? snap.bg : "#ffffff", scale: k),
               let t = UIImage(cgImage: img).jpegData(compressionQuality: 0.82) {
                try? t.write(to: thumbURL(id), options: .atomic)
            }
            thumbCache.removeObject(forKey: id as NSString)
        }
    }

    func delete(id: String) {
        io.async { [self] in
            for u in [docURL(id), metaURL(id), thumbURL(id)] { try? FileManager.default.removeItem(at: u) }
            thumbCache.removeObject(forKey: id as NSString)
        }
    }

    func waitForWrites() { io.sync {} }

    private let thumbCache = NSCache<NSString, UIImage>()
    func thumbnail(id: String) -> UIImage? {
        if let c = thumbCache.object(forKey: id as NSString) { return c }
        guard let img = UIImage(contentsOfFile: thumbURL(id).path) else { return nil }
        thumbCache.setObject(img, forKey: id as NSString)
        return img
    }
}

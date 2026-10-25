import SwiftUI
import UniformTypeIdentifiers

func timeAgo(_ ms: Double) -> String {
    let s = Date().timeIntervalSince1970 - ms / 1000
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86400 { return "\(Int(s / 3600)) h ago" }
    if s < 86400 * 7 { return "\(Int(s / 86400)) d ago" }
    let f = DateFormatter(); f.dateStyle = .medium
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @State private var renameId: String? = nil
    @State private var newName = ""
    @State private var deleteId: String? = nil
    @State private var importing = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                if model.gallery.isEmpty {
                    Text("No drawings yet. Tap New to start one.").foregroundStyle(.secondary).padding(.top, 60)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 18)], spacing: 24) {
                    ForEach(model.gallery) { m in card(m) }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Tether Ink")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(model.gallery.count) \(model.gallery.count == 1 ? "drawing" : "drawings") · saved on this iPad").font(.footnote).foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import") { importing = true }
                    Button { model.showNewCanvas = true } label: { Label("New", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    Button("Done") { model.showGallery = false }
                }
            }
        }
        .sheet(isPresented: $model.showNewCanvas) { NewCanvasSheet().environment(model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { r in if case .success(let url) = r { model.importBackup(url) } }
        .alert("Rename drawing", isPresented: Binding(get: { renameId != nil }, set: { if !$0 { renameId = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let id = renameId { model.renameDoc(id: id, to: newName) }; renameId = nil }
            Button("Cancel", role: .cancel) { renameId = nil }
        }
        .alert("Delete this drawing?", isPresented: Binding(get: { deleteId != nil }, set: { if !$0 { deleteId = nil } })) {
            Button("Delete", role: .destructive) { if let id = deleteId { model.deleteDoc(id: id) }; deleteId = nil }
            Button("Cancel", role: .cancel) { deleteId = nil }
        } message: { Text("It will be removed from this iPad. This can't be undone.") }
    }

    private func card(_ m: DocMeta) -> some View {
        let current = model.doc?.id == m.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if current { model.showGallery = false } else { model.openDoc(id: m.id) }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08))
                    if let img = model.store.thumbnail(id: m.id) {
                        Image(uiImage: img).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                            .padding(12)
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(current ? Color.accentColor : .clear, lineWidth: 2.5))
            }
            .buttonStyle(.plain)
            .contextMenu { menu(m) }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(Int(m.w)) × \(Int(m.h)) · \(timeAgo(m.updated))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Menu { menu(m) } label: { Image(systemName: "ellipsis").frame(width: 32, height: 28) }
                    .accessibilityLabel("Options for \(m.name)")
            }
        }
    }

    @ViewBuilder private func menu(_ m: DocMeta) -> some View {
        Button { newName = m.name; renameId = m.id } label: { Label("Rename", systemImage: "pencil") }
        Button { model.duplicateDoc(id: m.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button(role: .destructive) { deleteId = m.id } label: { Label("Delete", systemImage: "trash") }
    }
}

struct NewCanvasSheet: View {
    @Environment(AppModel.self) private var model
    @State private var w = "2048"
    @State private var h = "2048"

    private var presets: [(String, Double, Double)] {
        let s = UIScreen.main.nativeBounds.size
        let long = max(s.width, s.height), short = min(s.width, s.height)
        return [("Screen size", long, short), ("A4 portrait", 2480, 3508), ("A4 landscape", 3508, 2480), ("Square", 3000, 3000), ("Comic page", 2475, 3825), ("16:9 4K", 3840, 2160)]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(0..<presets.count, id: \.self) { i in
                        let p = presets[i]
                        Button { model.showNewCanvas = false; model.newDoc(w: p.1, h: p.2) } label: {
                            HStack {
                                Text(p.0).foregroundStyle(.primary)
                                Spacer()
                                Text("\(Int(p.1)) × \(Int(p.2))").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                } footer: { Text("Lines stay vector at any size. The canvas size sets the page shape and the pixel size of PNG exports.") }
                Section("Custom") {
                    HStack {
                        TextField("Width", text: $w).keyboardType(.numberPad)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", text: $h).keyboardType(.numberPad)
                        Text("px").foregroundStyle(.secondary)
                    }
                    Button("Create custom canvas") { model.showNewCanvas = false; model.newDoc(w: Double(w) ?? 2048, h: Double(h) ?? 2048) }
                }
            }
            .navigationTitle("New canvas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.showNewCanvas = false } } }
        }
    }
}

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct CanvasRepresentable: UIViewRepresentable {
    let model: AppModel
    func makeUIView(context: Context) -> CanvasView {
        let v = CanvasView(model: model)
        model.canvas = v
        return v
    }
    func updateUIView(_ uiView: CanvasView, context: Context) {}
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var photoItem: PhotosPickerItem? = nil

    var body: some View {
        @Bindable var model = model
        ZStack {
            CanvasRepresentable(model: model).ignoresSafeArea()
            if !model.uiHidden {
                VStack(spacing: 0) {
                    TopBar()
                    Spacer(minLength: 0)
                }
                if model.sizeEntry {
                    // tap anywhere else to close the size box (without drawing)
                    Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                        .onTapGesture { model.sizeEntry = false }
                }
                HStack(spacing: 0) {
                    if model.prefs.rightHand { Spacer(minLength: 0) }
                    SideBar()
                    if !model.prefs.rightHand { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 8)
                if model.fillOffer || model.fillMode {
                    VStack {
                        Button(model.fillMode ? "Done filling" : "Continue filling") {
                            if model.fillMode { model.endFilling() } else { model.fillMode = true; model.toast("Tap areas to fill them") }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.accentColor, in: Capsule())
                        .padding(.top, 66)
                        Spacer()
                    }
                }
            }
            if let p = model.dropPoint {
                // the colour being dragged out of the dock
                Color.clear.ignoresSafeArea().overlay {
                    Circle().fill(Color(uiColor: uiColor(hex: model.prefs.color)))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        .position(p)
                }
                .allowsHitTesting(false)
            }
            if let w = model.importing {
                VStack {
                    Spacer()
                    HStack(spacing: 10) { ProgressView(); Text(w).font(.footnote.weight(.medium)) }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.chrome, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                        .padding(.bottom, 70)
                }
                .allowsHitTesting(false)
            }
            if let t = model.toastText {
                VStack { Spacer(); ToastView(text: t).padding(.bottom, 24) }
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.keyboard)   // the keyboard never pushes the bars around
        .animation(.easeOut(duration: 0.15), value: model.toastText)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .fullScreenCover(isPresented: $model.showGallery) { GalleryView().environment(model).statusBarHidden(true) }
        .fullScreenCover(item: $model.editor) { t in BrushEditorView(target: t).environment(model).statusBarHidden(true) }
        .sheet(isPresented: $model.showGlobal) { GlobalSmoothingView().environment(model) }
        .fileImporter(isPresented: $model.importingBackup, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { model.importFile(url) }
        }
        .confirmationDialog("Import \(model.procreateChoice?.name ?? "artwork")",
                            isPresented: Binding(get: { model.procreateChoice != nil }, set: { if !$0 { model.procreateChoice = nil } }),
                            titleVisibility: .visible) {
            Button("Pixel layers (exactly as painted)") { model.importProcreate(traced: false) }
            Button("Trace to vector shapes") { model.importProcreate(traced: true) }
            Button("Cancel", role: .cancel) { model.procreateChoice = nil }
        } message: {
            Text("Pixel layers keep every brush mark. Tracing turns each layer into flat colour shapes that stay sharp at any zoom.")
        }
        .photosPicker(isPresented: $model.importingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await MainActor.run { model.insertPhoto(img) }
                }
                await MainActor.run { photoItem = nil }
            }
        }
    }
}

// MARK: - top bar

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // two small floating docks instead of a full-width bar; the space between them is canvas
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 2) {
                Button { model.saveNow(); model.refreshGallery(); model.showGallery = true } label: {
                    Image(systemName: "square.grid.2x2").font(.system(size: 18, weight: .medium))
                }
                .buttonStyle(BarButton())
                .accessibilityLabel("Gallery")
                barIcon("wrench.adjustable", panel: .actions, label: "Actions") { ActionsPanel() }
                barIcon("scribble.variable", panel: .smoothing, label: "Smoothing") { SmoothingPanel() }
            }
            .modifier(Dock())

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Button { if model.tool != .brush { model.setTool(.brush); model.panel = nil } else { toggle(.brushes) } } label: {
                    Image(systemName: "paintbrush.pointed").font(.system(size: 19, weight: .medium))
                }
                .buttonStyle(BarButton(on: model.tool == .brush))
                .accessibilityLabel("Brushes")
                .popover(isPresented: binding(.brushes), arrowEdge: .top) { BrushLibraryPanel().environment(model).presentationCompactAdaptation(.popover) }

                Button { if model.tool != .eraser { model.setTool(.eraser); model.panel = nil } else { toggle(.eraser) } } label: {
                    Image(systemName: "eraser").font(.system(size: 19, weight: .medium))
                }
                .buttonStyle(BarButton(on: model.tool == .eraser))
                .accessibilityLabel("Eraser")
                .popover(isPresented: binding(.eraser), arrowEdge: .top) { EraserPanel().environment(model).presentationCompactAdaptation(.popover) }

                barIcon("square.2.layers.3d", panel: .layers, label: "Layers") { LayersPanel() }

                Button { toggle(.colour) } label: {
                    Circle().fill(Color(uiColor: uiColor(hex: model.prefs.color)))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: 1.5).padding(-3.5))
                        .frame(width: 40, height: 38)
                }
                .accessibilityLabel("Colour")
                // drag the colour out onto the canvas to fill an area (dropping it back near the dock cancels)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .global)
                        .onChanged { g in
                            if model.panel != nil { model.panel = nil }
                            model.dropPoint = g.location
                        }
                        .onEnded { g in
                            model.dropPoint = nil
                            let moved = (g.translation.width * g.translation.width + g.translation.height * g.translation.height).squareRoot()
                            if moved > 40 { model.canvas?.fill(atWindow: g.location) }
                        }
                )
                .popover(isPresented: binding(.colour), arrowEdge: .top) { ColourPanel().environment(model).presentationCompactAdaptation(.popover) }
            }
            .modifier(Dock())
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func toggle(_ p: Panel) { model.panel = model.panel == p ? nil : p }
    private func binding(_ p: Panel) -> Binding<Bool> {
        Binding(get: { model.panel == p }, set: { if !$0 && model.panel == p { model.panel = nil } })
    }
    @ViewBuilder private func barIcon<C: View>(_ symbol: String, panel p: Panel, label: String, @ViewBuilder content: @escaping () -> C) -> some View {
        Button { toggle(p) } label: { Image(systemName: symbol).font(.system(size: 18, weight: .medium)) }
            .buttonStyle(BarButton(on: model.panel == p))
            .accessibilityLabel(label)
            .popover(isPresented: binding(p), arrowEdge: .top) { content().environment(model).presentationCompactAdaptation(.popover) }
    }
}

/// A small floating dock, styled like the side bar: solid panel colour, hairline edge, no blur.
struct Dock: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 4)
            .frame(height: 46)
            .background(Color.chrome, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct BarButton: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .frame(minWidth: 40, minHeight: 38)
            .padding(.horizontal, 4)
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
    }
}

// MARK: - side bar

struct SideBar: View {
    @Environment(AppModel.self) private var model
    @State private var bubble: (kind: String, fine: Bool)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if model.prefs.rightHand, let b = bubble { SizeBubble(kind: b.kind, fine: b.fine) }
            VStack(spacing: 10) {
                VSlider(value: sizeToV(model.currentSize), onChange: { model.currentSize = vToSize($0) },
                        onDrag: { on, fine in bubble = on ? ("size", fine) : nil },
                        onTap: { model.sizeEntry.toggle() })
                    .frame(height: 190)
                    .accessibilityLabel("Brush size")
                    .accessibilityAction(named: "Type a size") { model.sizeEntry = true }
                    // pinned beside the slider, outside the side bar (48 wide, slider inset 9, 10 gap)
                    .overlay(alignment: model.prefs.rightHand ? .trailing : .leading) {
                        if model.sizeEntry {
                            SizeEntry().fixedSize().offset(x: model.prefs.rightHand ? -49 : 49)
                        }
                    }
                Button { model.pickOnce.toggle(); if model.pickOnce { model.toast("Touch the canvas to pick a colour") } } label: {
                    Image(systemName: "eyedropper").font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(model.pickOnce ? Color.accentColor : .secondary)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(model.pickOnce ? Color.accentColor : Color.secondary, lineWidth: 1.5))
                }
                .accessibilityLabel("Pick a colour from the canvas")
                VSlider(value: model.currentOpacity, onChange: { model.currentOpacity = (($0 * 100).rounded() / 100) },
                        onDrag: { on, fine in bubble = on ? ("opacity", fine) : nil })
                    .frame(height: 140)
                    .accessibilityLabel("Opacity")
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 17, weight: .medium)).frame(width: 36, height: 32) }
                    .disabled(!model.canUndo).accessibilityLabel("Undo")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").font(.system(size: 17, weight: .medium)).frame(width: 36, height: 32) }
                    .disabled(!model.canRedo).accessibilityLabel("Redo")
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 12)
            .frame(width: 48)
            .background(Color.chrome, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
            if !model.prefs.rightHand, let b = bubble { SizeBubble(kind: b.kind, fine: b.fine) }
        }
    }
}

struct SizeBubble: View {
    @Environment(AppModel.self) private var model
    let kind: String
    let fine: Bool
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if kind == "size" {
                    let onScreen = model.currentSize * Double(model.canvas?.zoom ?? 1)
                    Circle().fill(Color.primary).frame(width: min(max(onScreen, 1), 68), height: min(max(onScreen, 1), 68))
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: uiColor(hex: model.prefs.color)).opacity(model.currentOpacity))
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                }
            }
            .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 2) {
                if kind == "size" {
                    Text(fmtSize(model.currentSize)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(fine ? "Fine control · Size" : "Size").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(pct(model.currentOpacity)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(fine ? "Fine control · Opacity" : "Opacity").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.chrome, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
        .allowsHitTesting(false)
    }
}

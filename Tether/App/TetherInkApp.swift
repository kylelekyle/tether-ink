import SwiftUI

@main
struct TetherInkApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: phase) { _, p in if p != .active { model.saveNow() } }
                .onOpenURL { model.importFile($0) }       // "Open in Tether Ink" from Files or the share sheet
        }
    }
}

import SwiftUI

@main
struct MagicDockApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Label("MagicDock", systemImage: model.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

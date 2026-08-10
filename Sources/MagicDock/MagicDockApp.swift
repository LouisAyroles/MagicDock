import SwiftUI

@main
struct MagicDockApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self)
    private var lifecycleDelegate
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

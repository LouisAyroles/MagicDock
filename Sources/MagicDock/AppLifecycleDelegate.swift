import AppKit

@MainActor
final class AppLifecycleController {
    static let shared = AppLifecycleController()

    var releaseBeforeTermination: (() async -> Void)?

    private init() {}
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private var isPreparingToTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToTerminate else { return .terminateLater }
        guard let release = AppLifecycleController.shared.releaseBeforeTermination else {
            return .terminateNow
        }

        isPreparingToTerminate = true
        Task {
            await release()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

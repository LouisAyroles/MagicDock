import AppKit
import CoreGraphics
import IOKit.ps
import MagicDockCore

@MainActor
final class DockPresenceMonitor {
    typealias StateHandler = (_ isDocked: Bool, _ isInitialReading: Bool) -> Void

    private(set) var isDocked = false

    private var pollingTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var stateHandler: StateHandler?

    func start(stateHandler: @escaping StateHandler) {
        stop()
        self.stateHandler = stateHandler

        evaluate(isInitialReading: true)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.evaluate(isInitialReading: false)
            }
        }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.evaluate(isInitialReading: false)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        stateHandler = nil
    }

    private func evaluate(isInitialReading: Bool) {
        let resolvedState = DockPresenceResolver.resolve(
            previousState: isDocked,
            hasExternalDisplay: Self.hasExternalDisplay,
            hasExternalPower: Self.hasExternalPower
        )

        guard isInitialReading || resolvedState != isDocked else { return }
        isDocked = resolvedState
        stateHandler?(resolvedState, isInitialReading)
    }

    private static var hasExternalDisplay: Bool {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return false
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard
            CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success
        else {
            return false
        }

        return displays.prefix(Int(displayCount)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    private static var hasExternalPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return false
        }

        return IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
            == kIOPMACPowerKey
    }
}

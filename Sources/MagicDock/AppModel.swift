import AppKit
import Combine
import Foundation
import MagicDockCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairedDevices: [BluetoothDeviceSnapshot] = []
    @Published private(set) var deviceStates: [String: BluetoothDeviceSnapshot] = [:]
    @Published private(set) var peers: [DiscoveredPeer] = []
    @Published private(set) var progress = SwitchProgress(phase: .idle, message: "Ready")
    @Published private(set) var isBusy = false
    @Published private(set) var launchAtLogin = LoginItemController.isEnabled
    @Published private(set) var isDockConnected = false

    let settings: SettingsStore

    private let bluetooth: NativeBluetoothManager
    private let switchEngine: SwitchEngine
    private let peerService: PeerService
    private let dockMonitor = DockPresenceMonitor()
    private var refreshTask: Task<Void, Never>?
    private var releaseRecoveryTask: Task<Void, Never>?
    private var offlineClaimTask: Task<Void, Never>?
    private var dockClaimTask: Task<Void, Never>?

    init() {
        let settings = SettingsStore()
        let bluetooth = NativeBluetoothManager()

        self.settings = settings
        self.bluetooth = bluetooth
        self.switchEngine = SwitchEngine(bluetooth: bluetooth)
        self.peerService = PeerService(
            nodeID: settings.nodeID,
            displayName: Host.current().localizedName ?? "Mac",
            pairingKey: settings.pairingKey
        )

        configurePeerService()
        AppLifecycleController.shared.releaseBeforeTermination = { [weak self] in
            await self?.releaseBeforeTermination()
        }
        peerService.start()
        startRefreshingDevices()
        dockMonitor.start { [weak self] isDocked, isInitialReading in
            self?.handleDockStateChange(isDocked, isInitialReading: isInitialReading)
        }
        scheduleAutomaticOfflineClaim()
    }

    deinit {
        refreshTask?.cancel()
        releaseRecoveryTask?.cancel()
        offlineClaimTask?.cancel()
        dockClaimTask?.cancel()
        Task { @MainActor [dockMonitor] in
            dockMonitor.stop()
        }
        peerService.stop()
    }

    var configuredDevices: [ConfiguredPeripheral] {
        settings.configuredDevices
    }

    var pairingKeyDisplay: String {
        settings.pairingKey.displayValue
    }

    var automaticallyClaimOffline: Bool {
        settings.automaticallyClaimOffline
    }

    var automaticallySwitchWithDock: Bool {
        settings.automaticallySwitchWithDock
    }

    var selectedPeer: DiscoveredPeer? {
        guard let selectedPeerID = settings.selectedPeerID else { return peers.first }
        return peers.first { $0.id == selectedPeerID } ?? peers.first
    }

    var hasControl: Bool {
        !configuredDevices.isEmpty
            && configuredDevices.allSatisfy {
                deviceStates[$0.address]?.isConnected == true
            }
    }

    var menuBarIcon: String {
        if isBusy { return "arrow.triangle.2.circlepath" }
        if hasControl { return "keyboard.fill" }
        return "keyboard"
    }

    var canTakeControl: Bool {
        !isBusy && (selectedPeer != nil || !configuredDevices.isEmpty)
    }

    var takeControlTitle: String {
        if hasControl { return "Already in control" }
        return selectedPeer == nil ? "Take Offline Control" : "Take Control"
    }

    func selectPeer(id: String?) {
        settings.selectedPeerID = id
    }

    func isConfigured(_ snapshot: BluetoothDeviceSnapshot) -> Bool {
        configuredDevices.contains { $0.address == snapshot.address }
    }

    func toggleDevice(_ snapshot: BluetoothDeviceSnapshot) {
        settings.toggle(snapshot)
        Task { await refreshDevices() }
    }

    func importPairingKey(_ value: String) {
        do {
            try settings.replacePairingKey(with: value)
            progress = .init(phase: .idle, message: "Pairing key updated.")
            Task { await peerService.updatePairingKey(settings.pairingKey) }
        } catch {
            progress = .init(phase: .failed, message: error.localizedDescription)
        }
    }

    func copyPairingKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingKeyDisplay, forType: .string)
        progress = .init(phase: .idle, message: "Pairing key copied.")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItemController.setEnabled(enabled)
            launchAtLogin = LoginItemController.isEnabled
        } catch {
            launchAtLogin = LoginItemController.isEnabled
            progress = .init(phase: .failed, message: error.localizedDescription)
        }
    }

    func setAutomaticallyClaimOffline(_ enabled: Bool) {
        settings.automaticallyClaimOffline = enabled
        if enabled {
            scheduleAutomaticOfflineClaim()
        } else {
            offlineClaimTask?.cancel()
            offlineClaimTask = nil
        }
    }

    func setAutomaticallySwitchWithDock(_ enabled: Bool) {
        settings.automaticallySwitchWithDock = enabled

        if enabled {
            if isDockConnected {
                scheduleDockClaim(after: .seconds(2))
            } else {
                offlineClaimTask?.cancel()
                offlineClaimTask = nil
            }
        } else {
            dockClaimTask?.cancel()
            dockClaimTask = nil
            scheduleAutomaticOfflineClaim()
        }
    }

    func syncConfigurationFromPeer() {
        guard !isBusy else { return }
        isBusy = true

        Task {
            defer { isBusy = false }
            do {
                try await syncConfigurationFromPeerNow()
                progress = .init(phase: .idle, message: "Device configuration synchronized.")
                await refreshDevices()
            } catch {
                progress = .init(phase: .failed, message: error.localizedDescription)
            }
        }
    }

    func takeControl() {
        guard !isBusy else { return }
        let peer = selectedPeer
        cancelPendingReleaseRecovery()
        offlineClaimTask?.cancel()
        isBusy = true

        Task {
            defer { isBusy = false }
            do {
                if configuredDevices.isEmpty, peer != nil {
                    try await syncConfigurationFromPeerNow()
                }

                let devices = configuredDevices
                if let peer {
                    try await switchEngine.takeControl(
                        of: devices,
                        remote: { [peerService] command in
                            try await peerService.send(command, to: peer)
                        },
                        progress: progressHandler()
                    )
                } else {
                    try await switchEngine.claim(devices, progress: progressHandler())
                }
                await refreshDevices()
            } catch {
                progress = .init(phase: .failed, message: error.localizedDescription)
                await refreshDevices()
            }
        }
    }

    private func configurePeerService() {
        peerService.setPeersChangedHandler { [weak self] peers in
            Task { @MainActor in
                guard let self else { return }
                self.peers = peers

                if peers.isEmpty {
                    self.scheduleAutomaticOfflineClaim()
                } else {
                    self.offlineClaimTask?.cancel()
                    self.offlineClaimTask = nil
                }

                if let selectedID = self.settings.selectedPeerID,
                    peers.contains(where: { $0.id == selectedID })
                {
                    return
                }
                self.settings.selectedPeerID = peers.first?.id
            }
        }

        peerService.setErrorHandler { [weak self] message in
            Task { @MainActor in
                self?.progress = .init(phase: .failed, message: message)
            }
        }

        peerService.setRequestHandler { [weak self] command in
            guard let self else {
                return PeerResponse(
                    requestID: command.requestID,
                    success: false,
                    message: "MagicDock is shutting down."
                )
            }
            return await self.handleRemote(command)
        }
    }

    private func startRefreshingDevices() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func scheduleAutomaticOfflineClaim() {
        offlineClaimTask?.cancel()
        guard settings.automaticallyClaimOffline,
            !settings.automaticallySwitchWithDock || isDockConnected
        else { return }

        offlineClaimTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            await self.claimOfflineIfAppropriate()
        }
    }

    private func claimOfflineIfAppropriate() async {
        guard settings.automaticallyClaimOffline,
            !settings.automaticallySwitchWithDock || isDockConnected,
            peers.isEmpty,
            !configuredDevices.isEmpty,
            !hasControl,
            !isBusy
        else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            progress = .init(phase: .checkingPeer, message: "The other Mac is offline; reclaiming devices…")
            try await switchEngine.claim(configuredDevices, progress: progressHandler())
            await refreshDevices()
        } catch {
            progress = .init(phase: .failed, message: error.localizedDescription)
            await refreshDevices()
        }
    }

    private func handleDockStateChange(_ isDocked: Bool, isInitialReading: Bool) {
        isDockConnected = isDocked
        guard settings.automaticallySwitchWithDock else { return }

        if isDocked {
            let delay: Duration = isInitialReading ? .seconds(8) : .seconds(4)
            scheduleDockClaim(after: delay)
        } else {
            dockClaimTask?.cancel()
            dockClaimTask = nil
            offlineClaimTask?.cancel()
            offlineClaimTask = nil
        }
    }

    private func scheduleDockClaim(after delay: Duration) {
        dockClaimTask?.cancel()
        offlineClaimTask?.cancel()
        offlineClaimTask = nil

        dockClaimTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                self.settings.automaticallySwitchWithDock,
                self.isDockConnected,
                !self.configuredDevices.isEmpty || self.selectedPeer != nil,
                !self.hasControl,
                !self.isBusy
            else { return }

            self.takeControl()
        }
    }

    private func refreshDevices() async {
        let paired = await bluetooth.pairedDevices()
        pairedDevices =
            paired
            .filter { $0.kind != .other }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

        if configuredDevices.isEmpty, !settings.didAutoselectDevices {
            let magicDevices = pairedDevices.filter {
                $0.name.localizedCaseInsensitiveContains("Magic")
            }
            if !magicDevices.isEmpty {
                settings.setConfiguredDevices(magicDevices.map(ConfiguredPeripheral.init))
                settings.didAutoselectDevices = true
            }
        }

        var states = Dictionary(uniqueKeysWithValues: paired.map { ($0.address, $0) })
        for peripheral in configuredDevices where states[peripheral.address] == nil {
            if let snapshot = await bluetooth.snapshot(for: peripheral.address) {
                states[peripheral.address] = snapshot
            }
        }
        deviceStates = states
    }

    private func syncConfigurationFromPeerNow() async throws {
        guard let peer = selectedPeer else {
            throw AppModelError.noPeer
        }

        let command = PeerCommand(kind: .status)
        let response = try await peerService.send(command, to: peer)
        let remoteConfiguration: [ConfiguredPeripheral]

        if !response.configuredDevices.isEmpty {
            remoteConfiguration = response.configuredDevices
        } else {
            remoteConfiguration = response.devices
                .filter { $0.kind != .other }
                .map(ConfiguredPeripheral.init)
        }

        guard !remoteConfiguration.isEmpty else {
            throw AppModelError.peerHasNoDevices
        }
        settings.setConfiguredDevices(remoteConfiguration)
        settings.didAutoselectDevices = true
    }

    private func handleRemote(_ command: PeerCommand) async -> PeerResponse {
        do {
            switch command.kind {
            case .ping:
                return .success(for: command, message: "pong")
            case .status:
                let devices = await bluetooth.pairedDevices()
                return .success(
                    for: command,
                    devices: devices,
                    configuredDevices: configuredDevices
                )
            case .release:
                try await switchEngine.release(command.devices, progress: progressHandler())
                scheduleReleaseRecovery(for: command.devices)
                await refreshDevices()
                return .success(for: command)
            case .claim:
                cancelPendingReleaseRecovery()
                try await switchEngine.claim(command.devices, progress: progressHandler())
                await refreshDevices()
                return .success(for: command)
            case .complete:
                cancelPendingReleaseRecovery()
                return .success(for: command)
            }
        } catch {
            progress = .init(phase: .failed, message: error.localizedDescription)
            await refreshDevices()
            return .failure(for: command, error: error)
        }
    }

    private func progressHandler() -> SwitchEngine.ProgressHandler {
        { [weak self] progress in
            Task { @MainActor in
                self?.progress = progress
            }
        }
    }

    private func scheduleReleaseRecovery(for devices: [ConfiguredPeripheral]) {
        releaseRecoveryTask?.cancel()
        releaseRecoveryTask = Task { [weak self, devices] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self else { return }

            do {
                try await self.switchEngine.claim(devices, progress: self.progressHandler())
                await self.refreshDevices()
            } catch {
                self.progress = .init(
                    phase: .failed,
                    message: "Timed recovery failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func cancelPendingReleaseRecovery() {
        releaseRecoveryTask?.cancel()
        releaseRecoveryTask = nil
    }

    private func releaseBeforeTermination() async {
        offlineClaimTask?.cancel()
        dockClaimTask?.cancel()
        cancelPendingReleaseRecovery()
        peerService.stop()
        await switchEngine.releaseBeforeTermination(
            configuredDevices,
            progress: progressHandler()
        )
    }
}

enum AppModelError: LocalizedError {
    case noPeer
    case peerHasNoDevices

    var errorDescription: String? {
        switch self {
        case .noPeer:
            "No other Mac is available on the local network."
        case .peerHasNoDevices:
            "The other Mac has no keyboard or mouse configured."
        }
    }
}

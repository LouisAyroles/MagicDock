import Foundation

public enum SwitchPhase: String, Equatable, Sendable {
    case idle
    case checkingPeer
    case preparingDestination
    case releasingSource
    case pairing
    case connecting
    case verifying
    case rollingBack
    case complete
    case failed
}

public struct SwitchProgress: Equatable, Sendable {
    public let phase: SwitchPhase
    public let message: String

    public init(phase: SwitchPhase, message: String) {
        self.phase = phase
        self.message = message
    }
}

public struct RetryPolicy: Equatable, Sendable {
    public let pairingAttempts: Int
    public let connectionAttempts: Int
    public let delays: [Duration]
    public let handoffSettleDelay: Duration

    public init(
        pairingAttempts: Int = 3,
        connectionAttempts: Int = 3,
        delays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)],
        handoffSettleDelay: Duration = .seconds(1)
    ) {
        self.pairingAttempts = max(1, pairingAttempts)
        self.connectionAttempts = max(1, connectionAttempts)
        self.delays = delays.isEmpty ? [.zero] : delays
        self.handoffSettleDelay = max(.zero, handoffSettleDelay)
    }

    public static let `default` = RetryPolicy()
}

public actor SwitchEngine {
    public typealias RemoteCommand = @Sendable (PeerCommand) async throws -> PeerResponse
    public typealias ProgressHandler = @Sendable (SwitchProgress) -> Void

    private let bluetooth: any BluetoothManaging
    private let retryPolicy: RetryPolicy
    private var isBusy = false

    public init(
        bluetooth: any BluetoothManaging,
        retryPolicy: RetryPolicy = .default
    ) {
        self.bluetooth = bluetooth
        self.retryPolicy = retryPolicy
    }

    public func takeControl(
        of devices: [ConfiguredPeripheral],
        remote: @escaping RemoteCommand,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws {
        try beginTransaction()
        defer { endTransaction() }

        let devices = Self.unique(devices)
        guard !devices.isEmpty else { throw SwitchEngineError.noDevicesConfigured }

        do {
            progress(.init(phase: .checkingPeer, message: "Checking the other Mac…"))
            try await requireSuccess(remote(PeerCommand(kind: .ping)))

            var devicesToTransfer: [ConfiguredPeripheral] = []
            for peripheral in devices {
                let snapshot = await bluetooth.snapshot(for: peripheral.address)
                if snapshot?.isConnected != true {
                    devicesToTransfer.append(peripheral)
                }
            }

            guard !devicesToTransfer.isEmpty else {
                progress(.init(phase: .complete, message: "This Mac already has control."))
                return
            }

            progress(
                .init(
                    phase: .preparingDestination,
                    message: "Removing stale pairing records…"
                ))
            for peripheral in devicesToTransfer {
                let snapshot = await bluetooth.snapshot(for: peripheral.address)
                if snapshot?.isPaired == true, snapshot?.isConnected == false {
                    try await bluetooth.unpair(address: peripheral.address)
                }
            }

            progress(
                .init(
                    phase: .releasingSource,
                    message: "Releasing the devices from the other Mac…"
                ))
            try await requireSuccess(remote(PeerCommand(kind: .release, devices: devicesToTransfer)))

            // Magic accessories need a short interval after the source removes its bond before
            // they reliably accept a baseband connection from the destination Mac.
            try await Task.sleep(for: retryPolicy.handoffSettleDelay)

            do {
                for peripheral in devicesToTransfer {
                    try await ensureClaimed(peripheral, progress: progress)
                }
                try await verify(devices, progress: progress)
                try await requireSuccess(
                    remote(PeerCommand(kind: .complete, devices: devicesToTransfer)))
                progress(.init(phase: .complete, message: "Keyboard and mouse are ready."))
            } catch {
                progress(
                    .init(
                        phase: .rollingBack,
                        message: "Transfer failed; returning the devices to the other Mac…"
                    ))

                let destinationReleased = await releaseLocallyBestEffort(devicesToTransfer)

                let sourceReclaimed: Bool
                do {
                    try await requireSuccess(remote(PeerCommand(kind: .claim, devices: devicesToTransfer)))
                    sourceReclaimed = true
                } catch {
                    sourceReclaimed = false
                }

                throw SwitchEngineError.transferFailed(
                    reason: error.localizedDescription,
                    rollbackSucceeded: destinationReleased && sourceReclaimed
                )
            }
        } catch {
            progress(.init(phase: .failed, message: error.localizedDescription))
            throw error
        }
    }

    public func release(
        _ devices: [ConfiguredPeripheral],
        progress: @escaping ProgressHandler = { _ in }
    ) async throws {
        try beginTransaction()
        defer { endTransaction() }

        let devices = Self.unique(devices)
        guard !devices.isEmpty else { throw SwitchEngineError.noDevicesConfigured }

        progress(.init(phase: .releasingSource, message: "Releasing devices…"))
        var touchedDevices: [ConfiguredPeripheral] = []

        do {
            for peripheral in devices {
                guard await bluetooth.snapshot(for: peripheral.address) != nil else { continue }
                touchedDevices.append(peripheral)
                try await releaseOne(peripheral)
            }
            progress(.init(phase: .complete, message: "Devices released."))
        } catch {
            progress(.init(phase: .rollingBack, message: "Release failed; restoring local control…"))
            let restored = await claimBestEffort(touchedDevices, progress: progress)
            throw SwitchEngineError.releaseFailed(
                reason: error.localizedDescription,
                rollbackSucceeded: restored
            )
        }
    }

    public func claim(
        _ devices: [ConfiguredPeripheral],
        progress: @escaping ProgressHandler = { _ in }
    ) async throws {
        try beginTransaction()
        defer { endTransaction() }

        let devices = Self.unique(devices)
        guard !devices.isEmpty else { throw SwitchEngineError.noDevicesConfigured }

        for peripheral in devices {
            try await ensureClaimed(peripheral, progress: progress)
        }
        try await verify(devices, progress: progress)
        progress(.init(phase: .complete, message: "Devices reclaimed."))
    }

    private func ensureClaimed(
        _ peripheral: ConfiguredPeripheral,
        progress: @escaping ProgressHandler
    ) async throws {
        var snapshot = await bluetooth.snapshot(for: peripheral.address)

        if snapshot?.isPaired != true {
            progress(.init(phase: .pairing, message: "Pairing \(peripheral.name)…"))
            try await retry(attempts: retryPolicy.pairingAttempts) {
                let current = await self.bluetooth.snapshot(for: peripheral.address)
                guard current?.isPaired != true else { return }

                try await self.bluetooth.pair(address: peripheral.address) { event in
                    switch event {
                    case let .typePasskey(code):
                        progress(
                            .init(
                                phase: .pairing,
                                message:
                                    "Type \(String(format: "%06u", code)) on the keyboard, then press Return."
                            ))
                    case .pinRequired:
                        progress(
                            .init(
                                phase: .pairing,
                                message: "macOS is requesting a Bluetooth PIN."
                            ))
                    case .started, .confirmation:
                        break
                    }
                }
            }
            snapshot = await bluetooth.snapshot(for: peripheral.address)
        }

        guard snapshot?.isPaired == true else {
            throw SwitchEngineError.deviceNotPaired(peripheral.name)
        }

        if snapshot?.isConnected != true {
            progress(.init(phase: .connecting, message: "Connecting \(peripheral.name)…"))
            try await retry(attempts: retryPolicy.connectionAttempts) {
                let current = await self.bluetooth.snapshot(for: peripheral.address)
                guard current?.isConnected != true else { return }
                try await self.bluetooth.connect(address: peripheral.address)
            }
        }
    }

    private func releaseOne(_ peripheral: ConfiguredPeripheral) async throws {
        guard let snapshot = await bluetooth.snapshot(for: peripheral.address) else { return }
        if snapshot.isPaired {
            try await bluetooth.unpair(address: peripheral.address)
        } else if snapshot.isConnected {
            try await bluetooth.disconnect(address: peripheral.address)
        }
    }

    private func releaseLocallyBestEffort(_ devices: [ConfiguredPeripheral]) async -> Bool {
        var succeeded = true
        for peripheral in devices {
            do {
                try await releaseOne(peripheral)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private func claimBestEffort(
        _ devices: [ConfiguredPeripheral],
        progress: @escaping ProgressHandler
    ) async -> Bool {
        var succeeded = true
        for peripheral in devices {
            do {
                try await ensureClaimed(peripheral, progress: progress)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private func verify(
        _ devices: [ConfiguredPeripheral],
        progress: @escaping ProgressHandler
    ) async throws {
        progress(.init(phase: .verifying, message: "Verifying connections…"))
        for peripheral in devices {
            let snapshot = await bluetooth.snapshot(for: peripheral.address)
            guard snapshot?.isConnected == true else {
                throw SwitchEngineError.verificationFailed(peripheral.name)
            }
        }
    }

    private func retry(
        attempts: Int,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        var lastError: Error?

        for attempt in 0..<attempts {
            do {
                try await operation()
                return
            } catch {
                lastError = error
                guard attempt + 1 < attempts else { break }
                let delay = retryPolicy.delays[min(attempt, retryPolicy.delays.count - 1)]
                try await Task.sleep(for: delay)
            }
        }

        throw lastError ?? SwitchEngineError.unknownFailure
    }

    private func requireSuccess(_ response: PeerResponse) throws {
        guard response.success else {
            throw PeerTransportError.peerRejected(response.message ?? "Unknown error")
        }
    }

    private func beginTransaction() throws {
        guard !isBusy else { throw SwitchEngineError.busy }
        isBusy = true
    }

    private func endTransaction() {
        isBusy = false
    }

    private static func unique(_ devices: [ConfiguredPeripheral]) -> [ConfiguredPeripheral] {
        var addresses = Set<String>()
        return devices.filter { addresses.insert($0.address).inserted }
    }
}

public enum SwitchEngineError: LocalizedError, Equatable, Sendable {
    case busy
    case noDevicesConfigured
    case deviceNotPaired(String)
    case verificationFailed(String)
    case releaseFailed(reason: String, rollbackSucceeded: Bool)
    case transferFailed(reason: String, rollbackSucceeded: Bool)
    case unknownFailure

    public var errorDescription: String? {
        switch self {
        case .busy:
            "Another device transfer is already in progress."
        case .noDevicesConfigured:
            "Select at least one Bluetooth device first."
        case let .deviceNotPaired(name):
            "\(name) did not finish pairing."
        case let .verificationFailed(name):
            "\(name) is not connected after the transfer."
        case let .releaseFailed(reason, rollbackSucceeded):
            rollbackSucceeded
                ? "Release failed (\(reason)). Local control was restored."
                : "Release failed (\(reason)), and local recovery also failed."
        case let .transferFailed(reason, rollbackSucceeded):
            rollbackSucceeded
                ? "Transfer failed (\(reason)). The devices were returned to the other Mac."
                : "Transfer failed (\(reason)), and automatic rollback also failed."
        case .unknownFailure:
            "The Bluetooth operation failed for an unknown reason."
        }
    }
}

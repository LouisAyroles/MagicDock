import Foundation
import Testing

@testable import MagicDockCore

@Suite("Device switch workflow")
struct SwitchEngineTests {
    @Test("Clears stale records and claims both devices")
    func takesControl() async throws {
        let bluetooth = MockBluetoothManager(devices: destinationStaleDevices)
        let remote = RemoteRecorder()
        let engine = SwitchEngine(
            bluetooth: bluetooth,
            retryPolicy: RetryPolicy(pairingAttempts: 1, connectionAttempts: 1, delays: [])
        )

        try await engine.takeControl(of: configuredDevices) { command in
            await remote.record(command)
            return .success(for: command)
        }

        let operations = await bluetooth.operations
        let remoteKinds = await remote.kinds
        #expect(
            operations == [
                "unpair:AA:BB:CC:DD:EE:01",
                "unpair:AA:BB:CC:DD:EE:02",
                "pair:AA:BB:CC:DD:EE:01",
                "connect:AA:BB:CC:DD:EE:01",
                "pair:AA:BB:CC:DD:EE:02",
                "connect:AA:BB:CC:DD:EE:02",
            ])
        #expect(remoteKinds == [.ping, .release, .complete])
    }

    @Test("Rolls back to the source when claiming fails")
    func rollsBackOnFailure() async {
        let bluetooth = MockBluetoothManager(
            devices: destinationStaleDevices,
            failingConnectionAddress: "AA:BB:CC:DD:EE:02"
        )
        let remote = RemoteRecorder()
        let engine = SwitchEngine(
            bluetooth: bluetooth,
            retryPolicy: RetryPolicy(pairingAttempts: 1, connectionAttempts: 1, delays: [])
        )

        do {
            try await engine.takeControl(of: configuredDevices) { command in
                await remote.record(command)
                return .success(for: command)
            }
            Issue.record("Expected the transfer to fail")
        } catch {
            #expect(
                error as? SwitchEngineError
                    == .transferFailed(
                        reason: MockBluetoothError.forcedFailure.localizedDescription,
                        rollbackSucceeded: true
                    ))
        }

        let remoteKinds = await remote.kinds
        #expect(remoteKinds == [.ping, .release, .claim])
        let operations = await bluetooth.operations
        #expect(
            operations.suffix(3) == [
                "disconnect:AA:BB:CC:DD:EE:01",
                "unpair:AA:BB:CC:DD:EE:01",
                "unpair:AA:BB:CC:DD:EE:02",
            ])
    }

    @Test("Releases connected devices in order")
    func releasesDevices() async throws {
        let sourceDevices = configuredDevices.map {
            BluetoothDeviceSnapshot(
                address: $0.address,
                name: $0.name,
                kind: $0.kind,
                isPaired: true,
                isConnected: true
            )
        }
        let bluetooth = MockBluetoothManager(devices: sourceDevices)
        let engine = SwitchEngine(bluetooth: bluetooth)

        try await engine.release(configuredDevices)

        let operations = await bluetooth.operations
        #expect(
            operations == [
                "disconnect:AA:BB:CC:DD:EE:01",
                "unpair:AA:BB:CC:DD:EE:01",
                "disconnect:AA:BB:CC:DD:EE:02",
                "unpair:AA:BB:CC:DD:EE:02",
            ])
    }

    @Test("Restores local control when a release fails halfway")
    func restoresAfterPartialRelease() async {
        let sourceDevices = configuredDevices.map {
            BluetoothDeviceSnapshot(
                address: $0.address,
                name: $0.name,
                kind: $0.kind,
                isPaired: true,
                isConnected: true
            )
        }
        let bluetooth = MockBluetoothManager(
            devices: sourceDevices,
            failingUnpairAddress: "AA:BB:CC:DD:EE:02"
        )
        let engine = SwitchEngine(
            bluetooth: bluetooth,
            retryPolicy: RetryPolicy(pairingAttempts: 1, connectionAttempts: 1, delays: [])
        )

        do {
            try await engine.release(configuredDevices)
            Issue.record("Expected the release to fail")
        } catch {
            #expect(
                error as? SwitchEngineError
                    == .releaseFailed(
                        reason: MockBluetoothError.forcedFailure.localizedDescription,
                        rollbackSucceeded: true
                    ))
        }

        for peripheral in configuredDevices {
            let snapshot = await bluetooth.snapshot(for: peripheral.address)
            #expect(snapshot?.isConnected == true)
        }
    }

    private var configuredDevices: [ConfiguredPeripheral] {
        [
            ConfiguredPeripheral(
                address: "AA:BB:CC:DD:EE:01",
                name: "Magic Keyboard",
                kind: .keyboard
            ),
            ConfiguredPeripheral(
                address: "AA:BB:CC:DD:EE:02",
                name: "Magic Mouse",
                kind: .mouse
            ),
        ]
    }

    private var destinationStaleDevices: [BluetoothDeviceSnapshot] {
        configuredDevices.map {
            BluetoothDeviceSnapshot(
                address: $0.address,
                name: $0.name,
                kind: $0.kind,
                isPaired: true,
                isConnected: false
            )
        }
    }
}

private actor RemoteRecorder {
    private(set) var kinds: [PeerCommandKind] = []

    func record(_ command: PeerCommand) {
        kinds.append(command.kind)
    }
}

private actor MockBluetoothManager: BluetoothManaging {
    private var devices: [String: BluetoothDeviceSnapshot]
    private let failingConnectionAddress: String?
    private let failingUnpairAddress: String?
    private(set) var operations: [String] = []

    init(
        devices: [BluetoothDeviceSnapshot],
        failingConnectionAddress: String? = nil,
        failingUnpairAddress: String? = nil
    ) {
        self.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.address, $0) })
        self.failingConnectionAddress = failingConnectionAddress
        self.failingUnpairAddress = failingUnpairAddress
    }

    func pairedDevices() -> [BluetoothDeviceSnapshot] {
        devices.values.filter(\.isPaired)
    }

    func snapshot(for address: String) -> BluetoothDeviceSnapshot? {
        devices[address]
    }

    func connect(address: String) throws {
        operations.append("connect:\(address)")
        if address == failingConnectionAddress { throw MockBluetoothError.forcedFailure }
        update(address: address, paired: true, connected: true)
    }

    func disconnect(address: String) throws {
        operations.append("disconnect:\(address)")
        update(address: address, paired: true, connected: false)
    }

    func pair(
        address: String,
        eventHandler: @escaping @Sendable (PairingEvent) -> Void
    ) throws {
        operations.append("pair:\(address)")
        update(address: address, paired: true, connected: false)
    }

    func unpair(address: String) throws {
        operations.append("unpair:\(address)")
        if address == failingUnpairAddress { throw MockBluetoothError.forcedFailure }
        update(address: address, paired: false, connected: false)
    }

    private func update(address: String, paired: Bool, connected: Bool) {
        guard let current = devices[address] else { return }
        devices[address] = BluetoothDeviceSnapshot(
            address: current.address,
            name: current.name,
            kind: current.kind,
            isPaired: paired,
            isConnected: connected
        )
    }
}

private enum MockBluetoothError: LocalizedError {
    case forcedFailure

    var errorDescription: String? { "Forced Bluetooth failure." }
}

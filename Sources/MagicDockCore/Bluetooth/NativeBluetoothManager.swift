import Foundation
@preconcurrency import IOBluetooth
import os

public final class NativeBluetoothManager: BluetoothManaging, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.LouisAyroles.MagicDock.bluetooth")
    private let logger = Logger(subsystem: "io.github.LouisAyroles.MagicDock", category: "Bluetooth")
    private let pairingTimeout: TimeInterval

    public init(pairingTimeout: TimeInterval = 45) {
        self.pairingTimeout = pairingTimeout
    }

    public func pairedDevices() async -> [BluetoothDeviceSnapshot] {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.pairedDeviceObjects().map(Self.snapshot))
            }
        }
    }

    public func snapshot(for address: String) async -> BluetoothDeviceSnapshot? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let device = Self.device(for: address) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: Self.snapshot(device))
            }
        }
    }

    public func connect(address: String) async throws {
        try await submit {
            let device = try Self.requiredDevice(for: address)
            guard !device.isConnected() else { return }

            let result = device.openConnection()
            guard result == kIOReturnSuccess || device.isConnected() else {
                throw BluetoothOperationError.operationFailed(operation: "connect", code: result)
            }
        }
    }

    public func disconnect(address: String) async throws {
        try await submit {
            let device = try Self.requiredDevice(for: address)
            guard device.isConnected() else { return }

            let result = device.closeConnection()
            guard result == kIOReturnSuccess || !device.isConnected() else {
                throw BluetoothOperationError.operationFailed(operation: "disconnect", code: result)
            }
        }
    }

    public func pair(
        address: String,
        eventHandler: @escaping @Sendable (PairingEvent) -> Void = { _ in }
    ) async throws {
        let timeout = pairingTimeout

        try await submit {
            let device = try Self.requiredDevice(for: address)
            guard !device.isPaired() else { return }
            guard let pairer = IOBluetoothDevicePair(device: device) else {
                throw BluetoothOperationError.deviceNotFound(address)
            }

            let delegate = PairingDelegate(
                deviceName: device.name ?? address,
                eventHandler: eventHandler
            )
            pairer.delegate = delegate

            let startResult = pairer.start()
            guard startResult == kIOReturnSuccess else {
                pairer.delegate = nil
                throw BluetoothOperationError.operationFailed(operation: "pair", code: startResult)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while !delegate.isFinished && Date() < deadline {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: min(deadline, Date().addingTimeInterval(0.2))
                )
            }

            pairer.delegate = nil
            pairer.stop()

            guard delegate.isFinished else {
                throw BluetoothOperationError.pairingTimedOut(address)
            }
            guard delegate.result == kIOReturnSuccess, device.isPaired() else {
                throw BluetoothOperationError.pairingFailed(address: address, code: delegate.result)
            }
        }
    }

    public func unpair(address: String) async throws {
        try await submit {
            let device = try Self.requiredDevice(for: address)
            guard device.isPaired() else { return }

            if device.isConnected() {
                let closeResult = device.closeConnection()
                guard closeResult == kIOReturnSuccess || !device.isConnected() else {
                    throw BluetoothOperationError.operationFailed(
                        operation: "disconnect before unpair",
                        code: closeResult
                    )
                }
            }

            // IOBluetooth has no public unpair API. macOS implements `remove` on
            // IOBluetoothDevice; keeping this selector isolated makes the private
            // dependency explicit and replaceable.
            let removeSelector = NSSelectorFromString("remove")
            guard device.responds(to: removeSelector) else {
                throw BluetoothOperationError.unpairUnavailable
            }

            _ = device.perform(removeSelector)

            let deadline = Date().addingTimeInterval(4)
            while device.isPaired(), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }

            guard !device.isPaired() else {
                throw BluetoothOperationError.unpairFailed(address)
            }
        }
    }

    private func submit<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [logger] in
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    logger.error(
                        "Bluetooth operation failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func pairedDeviceObjects() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    private static func device(for address: String) -> IOBluetoothDevice? {
        guard let normalizedAddress = BluetoothAddress.normalize(address) else { return nil }
        return IOBluetoothDevice(addressString: normalizedAddress)
    }

    private static func requiredDevice(for address: String) throws -> IOBluetoothDevice {
        guard BluetoothAddress.normalize(address) != nil else {
            throw BluetoothOperationError.invalidAddress(address)
        }
        guard let device = device(for: address) else {
            throw BluetoothOperationError.deviceNotFound(address)
        }
        return device
    }

    private static func snapshot(_ device: IOBluetoothDevice) -> BluetoothDeviceSnapshot {
        let address = device.addressString ?? "Unknown"
        return BluetoothDeviceSnapshot(
            address: address,
            name: device.name ?? address,
            isPaired: device.isPaired(),
            isConnected: device.isConnected()
        )
    }
}

private final class PairingDelegate: NSObject, IOBluetoothDevicePairDelegate {
    private let deviceName: String
    private let eventHandler: @Sendable (PairingEvent) -> Void

    private(set) var isFinished = false
    private(set) var result: IOReturn = kIOReturnError

    init(deviceName: String, eventHandler: @escaping @Sendable (PairingEvent) -> Void) {
        self.deviceName = deviceName
        self.eventHandler = eventHandler
    }

    func devicePairingStarted(_ sender: Any!) {
        eventHandler(.started(deviceName: deviceName))
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        result = error
        isFinished = true
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    func devicePairingUserConfirmationRequest(
        _ sender: Any!,
        numericValue: BluetoothNumericValue
    ) {
        eventHandler(.confirmation(code: numericValue))
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        eventHandler(.typePasskey(code: passkey))
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        eventHandler(.pinRequired)
    }
}

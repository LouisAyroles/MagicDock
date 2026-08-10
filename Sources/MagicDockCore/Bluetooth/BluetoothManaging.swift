import Foundation

public enum PairingEvent: Equatable, Sendable {
    case started(deviceName: String)
    case confirmation(code: UInt32)
    case typePasskey(code: UInt32)
    case pinRequired
}

public protocol BluetoothManaging: Sendable {
    func pairedDevices() async -> [BluetoothDeviceSnapshot]
    func snapshot(for address: String) async -> BluetoothDeviceSnapshot?
    func connect(address: String) async throws
    func disconnect(address: String) async throws
    func pair(
        address: String,
        eventHandler: @escaping @Sendable (PairingEvent) -> Void
    ) async throws
    func unpair(address: String) async throws
}

public enum BluetoothOperationError: LocalizedError, Equatable, Sendable {
    case invalidAddress(String)
    case deviceNotFound(String)
    case operationFailed(operation: String, code: Int32)
    case pairingTimedOut(String)
    case pairingFailed(address: String, code: Int32)
    case unpairUnavailable
    case unpairFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidAddress(address):
            "Invalid Bluetooth address: \(address)."
        case let .deviceNotFound(address):
            "No Bluetooth device was found at \(address)."
        case let .operationFailed(operation, code):
            "Bluetooth \(operation) failed with IOKit code \(code)."
        case let .pairingTimedOut(address):
            "Pairing timed out for \(address)."
        case let .pairingFailed(address, code):
            "Pairing failed for \(address) with Bluetooth code \(code)."
        case .unpairUnavailable:
            "This macOS version does not expose the Bluetooth removal operation."
        case let .unpairFailed(address):
            "macOS did not remove the pairing record for \(address)."
        }
    }
}

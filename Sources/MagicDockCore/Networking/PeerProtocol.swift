import Foundation
@preconcurrency import Network

public enum PeerCommandKind: String, Codable, Sendable {
    case ping
    case status
    case release
    case claim
    case complete
}

public struct PeerCommand: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let kind: PeerCommandKind
    public let devices: [ConfiguredPeripheral]

    public init(
        requestID: UUID = UUID(),
        kind: PeerCommandKind,
        devices: [ConfiguredPeripheral] = []
    ) {
        self.requestID = requestID
        self.kind = kind
        self.devices = devices
    }
}

public struct PeerResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let success: Bool
    public let message: String?
    public let devices: [BluetoothDeviceSnapshot]
    public let configuredDevices: [ConfiguredPeripheral]

    public init(
        requestID: UUID,
        success: Bool,
        message: String? = nil,
        devices: [BluetoothDeviceSnapshot] = [],
        configuredDevices: [ConfiguredPeripheral] = []
    ) {
        self.requestID = requestID
        self.success = success
        self.message = message
        self.devices = devices
        self.configuredDevices = configuredDevices
    }

    public static func success(
        for command: PeerCommand,
        message: String? = nil,
        devices: [BluetoothDeviceSnapshot] = [],
        configuredDevices: [ConfiguredPeripheral] = []
    ) -> PeerResponse {
        PeerResponse(
            requestID: command.requestID,
            success: true,
            message: message,
            devices: devices,
            configuredDevices: configuredDevices
        )
    }

    public static func failure(for command: PeerCommand, error: Error) -> PeerResponse {
        PeerResponse(
            requestID: command.requestID,
            success: false,
            message: error.localizedDescription
        )
    }
}

public struct DiscoveredPeer: Identifiable, Hashable, @unchecked Sendable {
    public let id: String
    public let displayName: String
    let endpoint: NWEndpoint

    init(id: String, displayName: String, endpoint: NWEndpoint) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
    }

    public static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool {
        lhs.id == rhs.id && lhs.endpoint == rhs.endpoint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(endpoint)
    }
}

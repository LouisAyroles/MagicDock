import Foundation

public enum PeripheralKind: String, Codable, CaseIterable, Sendable {
    case keyboard
    case mouse
    case other

    public init(deviceName: String) {
        let normalizedName = deviceName.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        if normalizedName.contains("keyboard") || normalizedName.contains("clavier") {
            self = .keyboard
        } else if normalizedName.contains("mouse") || normalizedName.contains("souris") {
            self = .mouse
        } else {
            self = .other
        }
    }

    public var symbolName: String {
        switch self {
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}

public struct BluetoothDeviceSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let address: String
    public let name: String
    public let kind: PeripheralKind
    public let isPaired: Bool
    public let isConnected: Bool

    public var id: String { address }

    public init(
        address: String,
        name: String,
        kind: PeripheralKind? = nil,
        isPaired: Bool,
        isConnected: Bool
    ) {
        self.address = BluetoothAddress.normalize(address) ?? address.uppercased()
        self.name = name
        self.kind = kind ?? PeripheralKind(deviceName: name)
        self.isPaired = isPaired
        self.isConnected = isConnected
    }
}

public struct ConfiguredPeripheral: Codable, Hashable, Identifiable, Sendable {
    public let address: String
    public var name: String
    public var kind: PeripheralKind

    public var id: String { address }

    public init(address: String, name: String, kind: PeripheralKind) {
        self.address = BluetoothAddress.normalize(address) ?? address.uppercased()
        self.name = name
        self.kind = kind
    }

    public init(snapshot: BluetoothDeviceSnapshot) {
        self.init(address: snapshot.address, name: snapshot.name, kind: snapshot.kind)
    }
}

public enum BluetoothAddress {
    public static func normalize(_ candidate: String) -> String? {
        let hexadecimalCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let separators = CharacterSet(charactersIn: ":-.").union(.whitespacesAndNewlines)
        guard
            candidate.unicodeScalars.allSatisfy({
                hexadecimalCharacters.contains($0) || separators.contains($0)
            })
        else {
            return nil
        }

        let hexadecimal = candidate.unicodeScalars.filter(hexadecimalCharacters.contains)

        guard hexadecimal.count == 12 else { return nil }

        let compact = String(String.UnicodeScalarView(hexadecimal)).uppercased()
        var octets: [String] = []
        var index = compact.startIndex

        for _ in 0..<6 {
            let endIndex = compact.index(index, offsetBy: 2)
            octets.append(String(compact[index..<endIndex]))
            index = endIndex
        }

        return octets.joined(separator: ":")
    }
}

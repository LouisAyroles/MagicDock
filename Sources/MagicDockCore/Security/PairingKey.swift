import CryptoKit
import Foundation

public struct PairingKey: Equatable, Sendable {
    public static let byteCount = 32

    public let rawData: Data

    private init(validatedRawData: Data) {
        self.rawData = validatedRawData
    }

    public init(rawData: Data) throws {
        guard rawData.count == Self.byteCount else {
            throw PairingKeyError.invalidLength
        }
        self.rawData = rawData
    }

    public init(displayValue: String) throws {
        let hexadecimalCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        let separators = CharacterSet(charactersIn: "-").union(.whitespacesAndNewlines)
        guard
            displayValue.unicodeScalars.allSatisfy({
                hexadecimalCharacters.contains($0) || separators.contains($0)
            })
        else {
            throw PairingKeyError.invalidCharacters
        }

        let hexadecimal = displayValue.unicodeScalars.filter(hexadecimalCharacters.contains)

        guard hexadecimal.count == Self.byteCount * 2 else {
            throw PairingKeyError.invalidLength
        }

        let compact = String(String.UnicodeScalarView(hexadecimal))
        var bytes = [UInt8]()
        bytes.reserveCapacity(Self.byteCount)
        var index = compact.startIndex

        while index < compact.endIndex {
            let endIndex = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<endIndex], radix: 16) else {
                throw PairingKeyError.invalidCharacters
            }
            bytes.append(byte)
            index = endIndex
        }

        try self.init(rawData: Data(bytes))
    }

    public static func generate() -> PairingKey {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return PairingKey(validatedRawData: data)
    }

    public var displayValue: String {
        let compact = rawData.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: compact.count, by: 8).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(8, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: "-")
    }
}

public enum PairingKeyError: LocalizedError, Equatable, Sendable {
    case invalidLength
    case invalidCharacters

    public var errorDescription: String? {
        switch self {
        case .invalidLength:
            "The pairing key must contain exactly 64 hexadecimal characters."
        case .invalidCharacters:
            "The pairing key contains an invalid character."
        }
    }
}

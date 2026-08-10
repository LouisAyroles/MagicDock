import CryptoKit
import Foundation

struct SignedEnvelope: Codable, Equatable, Sendable {
    let protocolVersion: UInt16
    let senderID: String
    let sentAtMilliseconds: Int64
    let nonce: String
    let payload: Data
    let signature: Data
}

private struct SigningInput: Codable {
    let protocolVersion: UInt16
    let senderID: String
    let sentAtMilliseconds: Int64
    let nonce: String
    let payload: Data
}

public struct OpenedMessage<Payload: Sendable>: Sendable {
    public let senderID: String
    public let nonce: String
    public let payload: Payload
}

public struct MessageAuthenticator: Sendable {
    public static let currentProtocolVersion: UInt16 = 1
    public static let defaultClockTolerance: TimeInterval = 120

    private let key: SymmetricKey
    private let clockTolerance: TimeInterval

    public init(key: PairingKey, clockTolerance: TimeInterval = defaultClockTolerance) {
        self.key = SymmetricKey(data: key.rawData)
        self.clockTolerance = clockTolerance
    }

    public func seal<Payload: Encodable & Sendable>(
        _ payload: Payload,
        senderID: String,
        now: Date = Date(),
        nonce: String = UUID().uuidString
    ) throws -> Data {
        let payloadData = try Self.encoder().encode(payload)
        let input = SigningInput(
            protocolVersion: Self.currentProtocolVersion,
            senderID: senderID,
            sentAtMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
            nonce: nonce,
            payload: payloadData
        )
        let signature = Data(
            HMAC<SHA256>.authenticationCode(
                for: try Self.encoder().encode(input),
                using: key
            ))
        let envelope = SignedEnvelope(
            protocolVersion: input.protocolVersion,
            senderID: input.senderID,
            sentAtMilliseconds: input.sentAtMilliseconds,
            nonce: input.nonce,
            payload: input.payload,
            signature: signature
        )
        return try Self.encoder().encode(envelope)
    }

    public func open<Payload: Decodable & Sendable>(
        _ data: Data,
        as payloadType: Payload.Type,
        now: Date = Date()
    ) throws -> OpenedMessage<Payload> {
        let envelope: SignedEnvelope
        do {
            envelope = try Self.decoder().decode(SignedEnvelope.self, from: data)
        } catch {
            throw PeerSecurityError.malformedEnvelope
        }

        guard envelope.protocolVersion == Self.currentProtocolVersion else {
            throw PeerSecurityError.unsupportedProtocol(envelope.protocolVersion)
        }

        let sentAt = Date(timeIntervalSince1970: TimeInterval(envelope.sentAtMilliseconds) / 1_000)
        guard abs(now.timeIntervalSince(sentAt)) <= clockTolerance else {
            throw PeerSecurityError.expiredMessage
        }

        let input = SigningInput(
            protocolVersion: envelope.protocolVersion,
            senderID: envelope.senderID,
            sentAtMilliseconds: envelope.sentAtMilliseconds,
            nonce: envelope.nonce,
            payload: envelope.payload
        )
        let signingData = try Self.encoder().encode(input)

        guard
            HMAC<SHA256>.isValidAuthenticationCode(
                envelope.signature,
                authenticating: signingData,
                using: key
            )
        else {
            throw PeerSecurityError.invalidSignature
        }

        do {
            let payload = try Self.decoder().decode(Payload.self, from: envelope.payload)
            return OpenedMessage(senderID: envelope.senderID, nonce: envelope.nonce, payload: payload)
        } catch {
            throw PeerSecurityError.malformedPayload
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

public actor PeerSecurityContext {
    private let nodeID: String
    private var authenticator: MessageAuthenticator?
    private var acceptedNonces = Set<String>()
    private var nonceOrder = [String]()
    private let maximumRememberedNonces: Int

    public init(nodeID: String, key: PairingKey?, maximumRememberedNonces: Int = 512) {
        self.nodeID = nodeID
        self.authenticator = key.map { MessageAuthenticator(key: $0) }
        self.maximumRememberedNonces = maximumRememberedNonces
    }

    public func updateKey(_ key: PairingKey?) {
        authenticator = key.map { MessageAuthenticator(key: $0) }
        acceptedNonces.removeAll(keepingCapacity: true)
        nonceOrder.removeAll(keepingCapacity: true)
    }

    public func seal<Payload: Encodable & Sendable>(_ payload: Payload) throws -> Data {
        guard let authenticator else { throw PeerSecurityError.missingPairingKey }
        return try authenticator.seal(payload, senderID: nodeID)
    }

    public func open<Payload: Decodable & Sendable>(
        _ data: Data,
        as payloadType: Payload.Type
    ) throws -> OpenedMessage<Payload> {
        guard let authenticator else { throw PeerSecurityError.missingPairingKey }
        let opened = try authenticator.open(data, as: payloadType)

        guard acceptedNonces.insert(opened.nonce).inserted else {
            throw PeerSecurityError.replayedMessage
        }
        nonceOrder.append(opened.nonce)

        if nonceOrder.count > maximumRememberedNonces {
            let expiredCount = nonceOrder.count - maximumRememberedNonces
            let expired = nonceOrder.prefix(expiredCount)
            acceptedNonces.subtract(expired)
            nonceOrder.removeFirst(expiredCount)
        }

        return opened
    }
}

public enum PeerSecurityError: LocalizedError, Equatable, Sendable {
    case missingPairingKey
    case malformedEnvelope
    case malformedPayload
    case unsupportedProtocol(UInt16)
    case expiredMessage
    case invalidSignature
    case replayedMessage

    public var errorDescription: String? {
        switch self {
        case .missingPairingKey:
            "No pairing key is configured."
        case .malformedEnvelope:
            "The peer sent a malformed message."
        case .malformedPayload:
            "The peer sent an unreadable command."
        case let .unsupportedProtocol(version):
            "The peer uses unsupported protocol version \(version)."
        case .expiredMessage:
            "The peer message is outside the allowed clock window."
        case .invalidSignature:
            "The peer message signature is invalid."
        case .replayedMessage:
            "A replayed peer message was rejected."
        }
    }
}

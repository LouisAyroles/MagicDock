import Foundation
import Testing

@testable import MagicDockCore

@Suite("Authenticated peer messages")
struct MessageAuthenticatorTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Round trips an authenticated command")
    func roundTrip() throws {
        let key = try fixtureKey()
        let authenticator = MessageAuthenticator(key: key)
        let command = PeerCommand(kind: .release, devices: [sampleDevice])
        let data = try authenticator.seal(
            command,
            senderID: "mac-a",
            now: date,
            nonce: "nonce-1"
        )
        let opened = try authenticator.open(data, as: PeerCommand.self, now: date)

        #expect(opened.senderID == "mac-a")
        #expect(opened.nonce == "nonce-1")
        #expect(opened.payload == command)
    }

    @Test("Rejects a message signed with another key")
    func rejectsWrongKey() throws {
        let key = try fixtureKey()
        let sender = MessageAuthenticator(key: key)
        let otherKey = try PairingKey(rawData: Data(repeating: 0x24, count: 32))
        let receiver = MessageAuthenticator(key: otherKey)
        let data = try sender.seal(PeerCommand(kind: .ping), senderID: "mac-a", now: date)

        #expect(throws: PeerSecurityError.invalidSignature) {
            try receiver.open(data, as: PeerCommand.self, now: date)
        }
    }

    @Test("Rejects expired messages")
    func rejectsExpiredMessage() throws {
        let key = try fixtureKey()
        let authenticator = MessageAuthenticator(key: key, clockTolerance: 30)
        let data = try authenticator.seal(PeerCommand(kind: .ping), senderID: "mac-a", now: date)

        #expect(throws: PeerSecurityError.expiredMessage) {
            try authenticator.open(data, as: PeerCommand.self, now: date.addingTimeInterval(31))
        }
    }

    @Test("Rejects a replayed nonce")
    func rejectsReplay() async throws {
        let key = try fixtureKey()
        let context = PeerSecurityContext(nodeID: "mac-a", key: key)
        let data = try await context.seal(PeerCommand(kind: .ping))
        let _: OpenedMessage<PeerCommand> = try await context.open(data, as: PeerCommand.self)

        do {
            let _: OpenedMessage<PeerCommand> = try await context.open(data, as: PeerCommand.self)
            Issue.record("Expected replay protection to reject the second message")
        } catch {
            #expect(error as? PeerSecurityError == .replayedMessage)
        }
    }

    @Test("Formats and parses pairing keys")
    func pairingKeyRoundTrip() throws {
        let key = try fixtureKey()
        let formatted = key.displayValue
        #expect(formatted.split(separator: "-").count == 8)
        #expect(try PairingKey(displayValue: formatted) == key)
        #expect(throws: PairingKeyError.invalidCharacters) {
            try PairingKey(displayValue: formatted + "!")
        }
    }

    private var sampleDevice: ConfiguredPeripheral {
        ConfiguredPeripheral(
            address: "AA:BB:CC:DD:EE:FF",
            name: "Magic Keyboard",
            kind: .keyboard
        )
    }

    private func fixtureKey() throws -> PairingKey {
        try PairingKey(rawData: Data(repeating: 0x42, count: 32))
    }
}

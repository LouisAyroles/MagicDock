import Testing

@testable import MagicDockCore

@Suite("Bluetooth address parsing")
struct BluetoothAddressTests {
    @Test("Normalizes accepted address formats")
    func normalizesAcceptedFormats() {
        let candidates = [
            "AA:BB:CC:DD:EE:FF",
            "aa-bb-cc-dd-ee-ff",
            "aabbccddeeff",
            "AA.BB.CC.DD.EE.FF",
        ]

        for candidate in candidates {
            #expect(BluetoothAddress.normalize(candidate) == "AA:BB:CC:DD:EE:FF")
        }
    }

    @Test("Rejects malformed addresses")
    func rejectsMalformedAddresses() {
        let candidates = [
            "AA:BB:CC:DD:EE",
            "AA:BB:CC:DD:EE:GG",
            "AA/BB/CC/DD/EE/FF",
            "prefix-AABBCCDDEEFF",
        ]

        for candidate in candidates {
            #expect(BluetoothAddress.normalize(candidate) == nil)
        }
    }
}

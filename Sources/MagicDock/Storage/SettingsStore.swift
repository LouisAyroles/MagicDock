import Combine
import Foundation
import MagicDockCore
import os

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var configuredDevices: [ConfiguredPeripheral]
    @Published private(set) var pairingKey: PairingKey
    @Published var selectedPeerID: String? {
        didSet { defaults.set(selectedPeerID, forKey: Keys.selectedPeerID) }
    }

    let nodeID: String

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let logger = Logger(subsystem: "io.github.LouisAyroles.MagicDock", category: "Settings")

    private enum Keys {
        static let configuredDevices = "configuredDevices"
        static let nodeID = "nodeID"
        static let selectedPeerID = "selectedPeerID"
        static let didAutoselectDevices = "didAutoselectDevices"
        static let pairingKeyAccount = "peer-pairing-key"
    }

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(service: "io.github.LouisAyroles.MagicDock")
    ) {
        self.defaults = defaults
        self.keychain = keychain

        if let savedNodeID = defaults.string(forKey: Keys.nodeID) {
            nodeID = savedNodeID
        } else {
            let generatedNodeID = UUID().uuidString
            nodeID = generatedNodeID
            defaults.set(generatedNodeID, forKey: Keys.nodeID)
        }

        selectedPeerID = defaults.string(forKey: Keys.selectedPeerID)

        if let data = defaults.data(forKey: Keys.configuredDevices),
            let devices = try? JSONDecoder().decode([ConfiguredPeripheral].self, from: data)
        {
            configuredDevices = devices
        } else {
            configuredDevices = []
        }

        if let data = try? keychain.data(for: Keys.pairingKeyAccount),
            let savedKey = try? PairingKey(rawData: data)
        {
            pairingKey = savedKey
        } else {
            let generatedKey = PairingKey.generate()
            pairingKey = generatedKey
            do {
                try keychain.set(generatedKey.rawData, for: Keys.pairingKeyAccount)
            } catch {
                logger.error("Could not persist pairing key: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var didAutoselectDevices: Bool {
        get { defaults.bool(forKey: Keys.didAutoselectDevices) }
        set { defaults.set(newValue, forKey: Keys.didAutoselectDevices) }
    }

    func replacePairingKey(with displayValue: String) throws {
        let newKey = try PairingKey(displayValue: displayValue)
        try keychain.set(newKey.rawData, for: Keys.pairingKeyAccount)
        pairingKey = newKey
    }

    func setConfiguredDevices(_ devices: [ConfiguredPeripheral]) {
        var addresses = Set<String>()
        configuredDevices = devices.filter { addresses.insert($0.address).inserted }
        persistDevices()
    }

    func toggle(_ snapshot: BluetoothDeviceSnapshot) {
        if configuredDevices.contains(where: { $0.address == snapshot.address }) {
            configuredDevices.removeAll { $0.address == snapshot.address }
        } else {
            configuredDevices.append(ConfiguredPeripheral(snapshot: snapshot))
        }
        didAutoselectDevices = true
        persistDevices()
    }

    private func persistDevices() {
        do {
            defaults.set(try JSONEncoder().encode(configuredDevices), forKey: Keys.configuredDevices)
        } catch {
            logger.error("Could not encode device settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}

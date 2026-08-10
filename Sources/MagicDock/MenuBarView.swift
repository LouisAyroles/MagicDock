import AppKit
import MagicDockCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @State private var pairingKeyDraft = ""
    @State private var showsPairingKey = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            peerSection
            deviceSection
            actionSection
            Divider()
            configurationSection
            footer
        }
        .padding(16)
        .frame(width: 390)
        .onAppear {
            pairingKeyDraft = model.pairingKeyDisplay
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.hasControl ? "keyboard.fill" : "keyboard")
                .font(.title2)
                .foregroundStyle(model.hasControl ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("MagicDock")
                    .font(.headline)
                Text(model.hasControl ? "This Mac has control" : "Waiting for devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var peerSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("OTHER MAC")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if model.peers.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Other Mac offline", systemImage: "power")
                        .font(.callout)
                    Text("Offline control is available for previously configured devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker(
                    "Destination",
                    selection: Binding(
                        get: { model.selectedPeer?.id },
                        set: { model.selectPeer(id: $0) }
                    )
                ) {
                    ForEach(model.peers) { peer in
                        Text(peer.displayName).tag(Optional(peer.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("DEVICES")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.configuredDevices.isEmpty, model.selectedPeer != nil {
                    Button("Sync from peer") {
                        model.syncConfigurationFromPeer()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if model.pairedDevices.isEmpty && model.configuredDevices.isEmpty {
                Text("Connect the Magic Keyboard and Magic Mouse to one Mac, then select them here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(displayedDevices) { device in
                deviceRow(device)
            }
        }
    }

    private var displayedDevices: [BluetoothDeviceSnapshot] {
        var devices = model.pairedDevices
        for configured in model.configuredDevices
        where !devices.contains(where: { $0.address == configured.address }) {
            devices.append(
                model.deviceStates[configured.address]
                    ?? BluetoothDeviceSnapshot(
                        address: configured.address,
                        name: configured.name,
                        kind: configured.kind,
                        isPaired: false,
                        isConnected: false
                    ))
        }
        return devices
    }

    private func deviceRow(_ device: BluetoothDeviceSnapshot) -> some View {
        HStack(spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { model.isConfigured(device) },
                    set: { _ in model.toggleDevice(device) }
                )
            ) {
                EmptyView()
            }
            .labelsHidden()

            Image(systemName: device.kind.symbolName)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .lineLimit(1)
                Text(device.address)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(device.isConnected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .help(device.isConnected ? "Connected" : "Disconnected")
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.takeControl()
            } label: {
                HStack {
                    Spacer()
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.takeControlTitle)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canTakeControl || model.hasControl)

            Text(model.progress.message)
                .font(.caption)
                .foregroundStyle(model.progress.phase == .failed ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Secure pairing") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use the same key on both Macs. The key never leaves your devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if showsPairingKey {
                        Text(model.pairingKeyDisplay)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button(showsPairingKey ? "Hide key" : "Show key") {
                            showsPairingKey.toggle()
                        }
                        Button("Copy") {
                            model.copyPairingKey()
                        }
                    }

                    SecureField("Paste the key from the other Mac", text: $pairingKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Use this key") {
                        model.importPairingKey(pairingKeyDraft)
                        pairingKeyDraft = model.pairingKeyDisplay
                    }
                    .disabled(pairingKeyDraft == model.pairingKeyDisplay)
                }
                .padding(.top, 6)
            }

            Toggle(
                "Launch MagicDock at login",
                isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                )
            )

            Toggle(
                "Auto-connect when the other Mac is off",
                isOn: Binding(
                    get: { model.automaticallyClaimOffline },
                    set: { model.setAutomaticallyClaimOffline($0) }
                )
            )
            Text(
                "After startup, MagicDock waits briefly for the other Mac, then reconnects released devices automatically."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("Local network only")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Release & Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

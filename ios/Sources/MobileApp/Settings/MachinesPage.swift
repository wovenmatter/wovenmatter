import SwiftUI

/// The person's machines, as this device's core reaches them. With none
/// remembered it is the connect screen.
struct MachinesPage: View {
    @Bindable var model: MobileModel
    @Bindable var connector: MachineConnector
    @State private var confirmsDisconnect = false
    @State private var disconnecting = false

    private var machines: MachinesStore { model.app.machines }

    var body: some View {
        List {
            if machines.isConnected {
                Section {
                    ForEach(machines.connectedMachines) { machine in
                        MachineRow(machine: machine)
                    }
                } header: {
                    SettingsHeader(title: "Your machines")
                }
                Section {
                    SettingsLinkRow(title: "Connect with a new code", page: .connect)
                        .accessibilityIdentifier("machines-new-code")
                    SettingsActionRow(title: "Disconnect", destructive: true) { confirmsDisconnect = true }
                        .disabled(disconnecting)
                        .accessibilityIdentifier("machines-disconnect")
                }
            } else {
                ConnectSection(model: model, connector: connector)
            }
        }
        .settingsPage("Machines")
        .confirmationDialog("Disconnect this \(ThisDevice.kind)?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This \(ThisDevice.kind) forgets your machines and stops syncing. Its chats and artifacts stay on it.")
        }
    }

    private func disconnect() {
        disconnecting = true
        connector.cancel()
        Task {
            await model.device.disconnect()
            model.app.machineConnections?.removeRemotes()
            await machines.reload()
            disconnecting = false
        }
    }
}

/// Connecting again with a new code, after moving tailnets, say.
struct ConnectPage: View {
    @Bindable var model: MobileModel
    @Bindable var connector: MachineConnector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ConnectSection(model: model, connector: connector) { dismiss() }
        }
        .settingsPage("Connect")
    }
}

private struct MachineRow: View {
    let machine: Machine
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20

    private var otherRelease: String? {
        guard let version = machine.appVersion, version != ThisDevice.appVersion else { return nil }
        return version
    }

    var body: some View {
        HStack(spacing: 12) {
            LucideIcon(glyph: machine.platform == .linux ? .container : .monitor, size: iconSize)
                .frame(width: iconSize + 4)
            SettingsRowLayout(title: machine.name, detail: otherRelease.map {
                "\(machine.name) runs Woven Matter \($0) — update it or this \(ThisDevice.kind) so they match."
            } ?? machine.platform.displayName) {
                if otherRelease != nil {
                    SettingsStatusLabel(text: "Update needed", tone: .warning)
                } else if machine.isOnline {
                    SettingsStatusLabel(text: "Connected", tone: .good)
                } else {
                    SettingsStatusLabel(text: "Offline")
                }
            }
        }
        .frame(minHeight: 44)
        .settingsRow()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("machine-\(machine.id)")
    }
}

extension MachinesStore {
    /// The machines this device is connected to, online or offline: those its
    /// core remembers an address for. After Disconnect the library may still
    /// hold their rows, but they are no longer the device's machines.
    var connectedMachines: [Machine] {
        machines.filter { serverStatus(on: $0.id)?.hostName != nil }
    }

    /// The device remembers where at least one machine is.
    var isConnected: Bool { !connectedMachines.isEmpty }

    /// A machine runs another release, so the two do not sync.
    var releaseMismatch: Bool {
        machines.contains { $0.appVersion.map { $0 != ThisDevice.appVersion } ?? false }
    }
}

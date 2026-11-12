import SwiftUI
import WovenMatterShared
import WovenMatterDashboardStore

struct MacTailnetDiscoveryView: View {
    @Bindable var devices: MacDeviceSetupModel
    @Bindable var pairing: MacPairingController
    @Bindable var host: LibraryHostController
    var canPairWithCentral: Bool
    @State private var confirmation: DeviceSetupConfirmation?
    private var busy: Bool { devices.searching || pairing.isDiscovering || host.isDiscovering || devices.rows.contains(where: \.busy) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(devices.searching || pairing.isDiscovering || host.isDiscovering ? "Searching…" : "Find devices") {
                Task {
                    async let inventory: Void = devices.discover()
                    await pairing.refreshDiscovery()
                    await host.refreshDiscovery()
                    await inventory
                }
            }.buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                .accessibilityIdentifier("devices.find-macs")
            if let error = devices.error {
                Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
            } else if devices.searched && devices.rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Macs found").font(.system(size: 13, weight: .medium))
                    Text("No other macOS devices are visible on your Tailscale network. Connect another Mac to this tailnet, then try again.")
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                }.accessibilityIdentifier("devices.no-macs")
            }
            ForEach(devices.rows) { row in
                MacTailnetDeviceRow(row: row, release: devices.release, peer: peer(for: row), paired: isPaired(row),
                    canPairWithCentral: canPairWithCentral,
                    onAction: { action in
                        let item = DeviceSetupConfirmation(row: row, action: action)
                        if action == .open { Task { await perform(item) } } else { confirmation = item }
                    },
                    onInspect: { Task { await devices.inspect(row) } })
            }
            if let error = devices.releaseError {
                Text("Updates could not be checked. " + error).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                Button("Check for updates") { Task { await devices.checkRelease() } }.buttonStyle(SettingsQuietButtonStyle())
            }
        }
        .confirmationDialog(confirmation?.title ?? "Pair Mac?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { item in
            Button(item.buttonTitle) { Task { await perform(item) } }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { item in
            Text(item.message(version: devices.release?.version, snapshot: DevelopmentLaunch.isSnapshot))
        }
    }
    private func rowError(_ row: MacDeviceRow) { row.error = "Update both Macs to a version that supports paired Mac synchronization." }
    private func peer(for row: MacDeviceRow) -> DiscoveredPeer? {
        (pairing.peers + host.discoveredPeers).first { $0.endpoint.host == row.mac.dnsName }
    }
    private func isPaired(_ row: MacDeviceRow) -> Bool {
        guard let id = row.installation?.deviceID ?? peer(for: row)?.advertisement.identity.deviceID else { return false }
        return host.pairedDevices.contains { $0.id == id }
    }
    private func perform(_ item: DeviceSetupConfirmation) async {
        confirmation = nil
        if item.action == .pair, let peer = peer(for: item.row) {
            if peer.advertisement.capabilities?.contains(PairedMacSyncController.capability) == true { await host.pairWithPeer(peer); return }
            rowError(item.row); return
        }
        guard [.update, .download, .open].contains(item.action) || host.endpoint != nil else { item.row.error = "Wait for this Mac’s library to become available before pairing."; return }
        await devices.perform(item.action, row: item.row, central: host.endpoint)
    }
}

@MainActor struct DeviceSetupConfirmation {
    let row: MacDeviceRow
    let action: MacDeviceSetupModel.Action
    var title: String {
        switch action {
        case .update: "Update Woven Matter on \(row.mac.name)?"
        case .download: "Download Woven Matter on \(row.mac.name)?"
        case .open: "Open Woven Matter on \(row.mac.name)?"
        default: "Pair with \(row.mac.name)?"
        }
    }
    var buttonTitle: String {
        switch action { case .pair: "Pair"; case .installAndPair: row.installation?.installed == true ? "Update and pair" : "Download and pair"; case .update: "Update"; case .download: "Download"; case .open: "Open" }
    }
    func message(version: String?, snapshot: Bool = false) -> String {
        if action == .update || action == .download {
            return "Install Woven Matter \(version ?? "the latest version") on this Mac. Running work must finish before the app can restart. Its library stays on that Mac."
        }
        let destination = snapshot ? "this isolated snapshot database" : "this Mac’s library"
        let download = action == .installAndPair ? "Download and verify Woven Matter \(version ?? "the latest version"), then " : ""
        return download + "open Woven Matter on this Mac, request pairing with \(destination). Both Macs keep their libraries and synchronize shared data. Approve the pairing request here to finish."
    }
}

private struct MacTailnetDeviceRow: View {
    @Bindable var row: MacDeviceRow
    var release: MacRelease?
    var peer: DiscoveredPeer?
    var paired: Bool
    var canPairWithCentral: Bool
    var onAction: (MacDeviceSetupModel.Action) -> Void
    var onInspect: () -> Void
    @State private var showConnection = false
    private var installedVersion: String? { row.installation?.version ?? peer?.advertisement.identity.metadata.appVersion }
    private var canUseService: Bool { peer?.advertisement.capabilities?.contains(PairedMacSyncController.capability) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                DeviceConnectionIcon(kind: .mac)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.mac.name).font(.system(size: 13, weight: .medium))
                    Text(summary).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    Text(row.mac.dnsName.isEmpty ? row.mac.address : row.mac.dnsName).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if row.busy || row.checking { ProgressView().controlSize(.small).accessibilityLabel(row.busy ? "Setting up Mac" : "Checking installation") }
            }
            if row.mac.online && !row.checking { actions.disabled(row.busy).padding(.leading, 36) }
            if let message = row.message { Text(message).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground) }
            if let error = row.error { Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
            if row.installation?.installed == true, row.installation?.supportsSetup == false,
               !canUseService, release?.supportsRemoteSetup != true {
                Text("Pair in Apple Devices on that Mac. Setup from here will be available when a release with remote pairing support is published.")
                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            if row.mac.online {
                DisclosureGroup("Connection settings", isExpanded: $showConnection) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Checking, downloading, and opening apps uses this Mac’s existing SSH access over Tailscale. Configure SSH on the other Mac first if access is unavailable.")
                            .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        TextField("SSH host alias", text: $row.connection.alias).dashboardInput()
                        TextField("SSH user (optional)", text: $row.connection.user).dashboardInput()
                        Button("Check installation", action: onInspect).buttonStyle(SettingsQuietButtonStyle())
                    }.disabled(row.busy || row.checking)
                }.font(.system(size: 12))
            }
        }.padding(.vertical, 8)
            .accessibilityIdentifier("devices.mac.\(row.mac.id)")
    }
    private var summary: String {
        if !row.mac.online { return "Offline · Connect this Mac to Tailscale to continue" }
        if row.checking { return "Online · Checking Woven Matter…" }
        if let version = installedVersion {
            let versionText = "Woven Matter \(version)" + (row.installation?.build.map { " (\($0))" } ?? "")
            return versionText + (paired ? " · Paired" : row.installation?.running == true ? " · Running" : " · Installed")
        }
        if row.installation?.installed == false { return "Online · Woven Matter is not installed" }
        return "Online · Installation status unavailable"
    }
    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if !paired {
                if canUseService || row.installation?.supportsSetup == true || (canPairWithCentral && row.installation?.installed == true) {
                    Button("Pair") { onAction(.pair) }.buttonStyle(SettingsQuietButtonStyle())
                } else if let installation = row.installation, let release,
                          (canPairWithCentral || release.supportsRemoteSetup), !installation.installed || release.isNewer(than: installation) {
                    Button(installation.installed ? "Update & pair" : "Download & pair") { onAction(.installAndPair) }
                        .buttonStyle(SettingsQuietButtonStyle())
                } else if row.installation?.installed == true {
                    Button("Open Woven Matter") { onAction(.open) }.buttonStyle(SettingsQuietButtonStyle())
                } else if row.installation?.installed == false, release != nil {
                    Button("Download") { onAction(.download) }.buttonStyle(SettingsQuietButtonStyle())
                } else {
                    Button("Retry", action: onInspect).buttonStyle(SettingsQuietButtonStyle())
                }
            }
            if let installation = row.installation, installation.installed, let release, release.isNewer(than: installation) {
                Button("Update to \(release.version)") { onAction(.update) }.buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }
}

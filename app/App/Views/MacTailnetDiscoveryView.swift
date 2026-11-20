import SwiftUI

/// Find Devices for Macs: tailnet Macs without a Woven server. Installing opens Woven
/// Matter there over SSH; the Mac then joins on its own.
struct MacTailnetDiscoveryView: View {
    @Bindable var model: MachinesStore
    @State private var confirmation: TailnetDevice?

    private var macs: [TailnetDevice] { model.tailnetDevices.filter { $0.platform == .mac } }
    private var busy: Bool {
        model.isFindingDevices || macs.contains { model.installingHosts.contains($0.hostName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(model.isFindingDevices ? "Searching…" : "Find devices") { model.findDevices() }
                .buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                .accessibilityIdentifier("devices.find-macs")
            if let error = model.findDevicesError {
                Text(error).font(.system(size: 12)).foregroundStyle(WovenPalette.danger)
            } else if model.hasSearchedDevices && macs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Macs found").font(.system(size: 13, weight: .medium))
                    Text("No other macOS devices are visible on your Tailscale network. Connect another Mac to this tailnet, then try again.")
                        .font(.system(size: 12)).foregroundStyle(WovenPalette.mutedForeground)
                }.accessibilityIdentifier("devices.no-macs")
            }
            ForEach(macs) { device in
                MacTailnetDeviceRow(model: model, device: device, onInstall: { confirmation = device })
            }
        }
        .confirmationDialog(confirmation.map(confirmationTitle) ?? "Download Woven Matter?",
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            presenting: confirmation) { device in
            Button(isInstalled(device) ? "Open" : "Download") {
                confirmation = nil
                model.installServer(hostName: device.hostName, userName: nil, accessMode: nil)
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { device in
            Text(isInstalled(device)
                ? "Open Woven Matter on this Mac. It joins your machines on its own."
                : "Install the latest Woven Matter on this Mac and open it. It joins your machines on its own.")
        }
    }

    private func isInstalled(_ device: TailnetDevice) -> Bool {
        if case .installed = device.installation { return true }
        return false
    }

    private func confirmationTitle(_ device: TailnetDevice) -> String {
        isInstalled(device) ? "Open Woven Matter on \(device.name)?" : "Download Woven Matter on \(device.name)?"
    }
}

private struct MacTailnetDeviceRow: View {
    @Bindable var model: MachinesStore
    let device: TailnetDevice
    var onInstall: () -> Void
    @State private var showConnection = false
    @State private var sshAlias = ""
    @State private var sshUser = ""

    private var host: String {
        let alias = sshAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        return alias.isEmpty ? device.hostName : alias
    }
    private var busy: Bool { model.installingHosts.contains(host) }
    private var checking: Bool { model.inspectingHosts.contains(host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                DeviceConnectionIcon(platform: .mac)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.system(size: 13, weight: .medium))
                    Text(summary).font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground)
                    Text(device.hostName.isEmpty ? device.address : device.hostName).font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if busy || checking { ProgressView().controlSize(.small).accessibilityLabel(busy ? "Setting up Mac" : "Checking installation") }
            }
            if device.isOnline && !checking { actions.disabled(busy).padding(.leading, 36) }
            if let message = model.hostMessages[host] { Text(message).font(.system(size: 12)).foregroundStyle(WovenPalette.mutedForeground) }
            if let error = model.hostErrors[host] { Text(error).font(.system(size: 12)).foregroundStyle(WovenPalette.danger).textSelection(.enabled) }
            if device.isOnline {
                DisclosureGroup("Connection settings", isExpanded: $showConnection) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Checking, downloading, and opening apps uses this Mac’s existing SSH access over Tailscale. Configure SSH on the other Mac first if access is unavailable.")
                            .font(.system(size: 11)).foregroundStyle(WovenPalette.mutedForeground)
                        TextField("SSH host alias", text: $sshAlias).wovenInput()
                        TextField("SSH user (optional)", text: $sshUser).wovenInput()
                        Button("Check installation", action: inspect).buttonStyle(SettingsQuietButtonStyle())
                    }.disabled(busy || checking)
                }.font(.system(size: 12))
            }
        }.padding(.vertical, 8)
            .accessibilityIdentifier("devices.mac.\(device.id)")
    }

    private func inspect() {
        let user = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
        model.inspectHost(hostName: host, userName: user.isEmpty ? nil : user, accessMode: nil)
    }

    private var summary: String {
        if !device.isOnline { return "Offline · Connect this Mac to Tailscale to continue" }
        if checking { return "Online · Checking Woven Matter…" }
        switch device.installation {
        case .installed(let version): return (version.map { "Woven Matter \($0)" } ?? "Woven Matter") + " · Installed"
        case .notInstalled: return "Online · Woven Matter is not installed"
        case .unknown: return "Online · Installation status unavailable"
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            switch device.installation {
            case .installed:
                Button("Open Woven Matter", action: onInstall).buttonStyle(SettingsQuietButtonStyle())
            case .notInstalled:
                Button("Download", action: onInstall).buttonStyle(SettingsQuietButtonStyle())
            case .unknown:
                Button("Retry", action: inspect).buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }
}

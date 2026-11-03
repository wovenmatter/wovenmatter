import AppKit
import CompanionClient
import SwiftUI
import WovenMatterCompanion

struct SettingsCompanionView: View {
    @Bindable var model: ApplicationModel
    @Bindable var host: CompanionHostController
    @State private var pairingLink = ""
    @State private var pairingLinkBusy = false
    @State private var recoveryError: String?
    var reservesRailControlSpace = false
    var onBack: () -> Void
    private var client: CentralLibraryClientModel { model.libraryClient }

    var body: some View {
        SettingsPage(title: "Apple Devices", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if DevelopmentLaunch.isClient {
                SettingsCard(title: "This Mac") {
                    HStack(spacing: 12) {
                        DeviceConnectionIcon(kind: .mac)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.backendReplica.endpoint?.host ?? "Live library")
                            Text(model.backendReplica.status).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                    }
                }
                SettingsCard(title: "This Mac") {
                    Text("This development instance keeps a local database synchronized with the live library. Its own background server runs its agents and scheduled work.")
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                }
            } else {
                SettingsCard(title: "This Mac") {
                    HStack(spacing: 12) {
                        DeviceConnectionIcon(kind: .mac)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(DevelopmentLaunch.deviceName()).font(.system(size: 13, weight: .medium))
                            Text("Keeps a complete local library and synchronizes with paired Macs when connected.")
                                .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Spacer()
                    }
                }
                if !host.pendingPairingRequests.isEmpty { pairingRequests }
                if host.pairedDevices.contains(where: { $0.id != host.peerIdentity?.deviceID }) { pairedDevices }
                if !host.pendingDeviceRevocations.isEmpty { pendingRevocations }
            }
            SettingsDeviceWorkspaceInventory(workspaces: model.isLibraryClient ? client.executionWorkspaces : host.executionWorkspaces)
            if !DevelopmentLaunch.isClient {
                DevicePairingDiscoveryCard(pairing: client.devicePairing, host: host, isCentral: true, canPairWithCentral: true)
                DevicePairingCodeCard(host: host)
                SettingsCard(title: "Use a pairing link", detail: "Copy a pairing link from the other Mac’s Apple Devices settings.") {
                    HStack {
                        SecureField("Pairing link", text: $pairingLink).accessibilityIdentifier("companion.peer-link")
                        Button("Pair Mac") {
                            let link = pairingLink; pairingLink = ""; pairingLinkBusy = true
                            Task { await host.pairUsingLink(link); pairingLinkBusy = false }
                        }.buttonStyle(SettingsQuietButtonStyle())
                            .disabled(pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairingLinkBusy)
                    }
                }
                if !host.peerPairingStatus.isEmpty {
                    HStack {
                        Text(host.peerPairingStatus).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                        Spacer()
                        Button("Cancel pairing") { Task { await host.cancelPeerPairing() } }.buttonStyle(SettingsQuietButtonStyle())
                    }
                }
                if let message = host.peerPairingError ?? host.errorMessage {
                    Text(message).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
                        .textSelection(.enabled).accessibilityIdentifier("companion.error")
                }
                if !host.peerSyncErrors.isEmpty {
                    SettingsCard(title: "Synchronization needs attention", detail: "Local writing is saved while synchronization retries.") {
                        ForEach(Array(Set(host.peerSyncErrors.values)).sorted(), id: \.self) { message in
                            Text(message).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
                        }
                    }
                }
                if !model.companionRecoveredNoteDrafts.isEmpty { recoveredDrafts }
                SettingsCard(title: "Paired Macs", detail: "Each Mac saves shared notes, chats, library files, settings and connections locally. You can add workspaces or Apple devices from any Mac. Offline changes synchronize automatically when the Macs reconnect.") {
                    Text("Agents and scheduled work keep running on the workspace that owns them.")
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
        }
        .task {
            guard !DevelopmentLaunch.isClient else { return }
            while !Task.isCancelled {
                if !model.isLibraryClient { await host.refreshStatus() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }

    }
    private var clientDeviceRoster: some View {
        SettingsCard(title: "Paired devices") {
            ForEach(client.connectedDevices) { device in
                HStack(spacing: 12) {
                    DeviceConnectionIcon(kind: device.metadata.kind)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.system(size: 13, weight: .medium))
                        Text(DeviceConnectionIcon.label(device.metadata.kind)).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        if let seen = device.lastSeenAt {
                            Text("Last seen \(seen.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                    }
                }
            }
        }
    }
    private var pairingRequests: some View {
        SettingsCard(title: "Pairing requests") {
            ForEach(host.pendingPairingRequests) { request in
                HStack(spacing: 12) {
                    DeviceConnectionIcon(kind: request.identity.metadata.kind)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.identity.deviceName).font(.system(size: 13, weight: .medium))
                        Text(DeviceConnectionIcon.label(request.identity.metadata.kind)).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer()
                    Button("Decline") { Task { await host.denyPairing(id: request.id) } }.buttonStyle(SettingsQuietButtonStyle())
                    Button("Pair") { Task { await host.approvePairing(id: request.id) } }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
        }
    }
    private var pairedDevices: some View {
        SettingsCard(title: "Paired devices") {
            ForEach(host.pairedDevices.filter { $0.id != host.peerIdentity?.deviceID }) { device in
                HStack(spacing: 12) {
                    DeviceConnectionIcon(kind: device.kind)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.displayName).font(.system(size: 13, weight: .medium))
                        Text(DeviceConnectionIcon.label(device.kind)).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        if let seen = device.lastSeenAt {
                            Text("Last seen \(seen.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        } else {
                            Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                    }
                    Spacer()
                    Button("Unpair device", role: .destructive) { Task { await host.revoke(device.id) } }
                        .buttonStyle(SettingsQuietButtonStyle()).accessibilityIdentifier("companion.revoke")
                }
            }
        }
    }
    private var pendingRevocations: some View {
        SettingsCard(title: "Pending revocations") {
            ForEach(host.pendingDeviceRevocations.keys.sorted(), id: \.self) { id in
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.pairedDevices.first { $0.id == id }?.displayName ?? "Disconnected device")
                        .font(.system(size: 13, weight: .medium))
                    let names = (host.pendingDeviceRevocations[id] ?? []).map { workspaceID in
                        host.executionWorkspaces.first { $0.id == workspaceID }?.name ?? "Unavailable workspace"
                    }
                    Text("Waiting for " + names.joined(separator: ", "))
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
        }
    }
    private var recoveredDrafts: some View {
        SettingsCard(title: "Recovered writing") {
            ForEach(model.companionRecoveredNoteDrafts) { draft in
                HStack(alignment: .top, spacing: 12) {
                    Text(draft.title.isEmpty ? "Untitled note" : draft.title).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Save a copy") {
                        Task {
                            do { _ = try await model.preserveRecoveredNoteAsCopy(id: draft.id); recoveryError = nil }
                            catch { recoveryError = error.localizedDescription }
                        }
                    }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
            if let recoveryError { Text(recoveryError).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger) }
        }
    }
}

/// The shared inventory belongs to the library, independently of its paired devices.
struct SettingsDeviceWorkspaceInventory: View {
    let workspaces: [CompanionExecutionWorkspace]
    private var active: [CompanionExecutionWorkspace] {
        workspaces.filter(\.isVisibleInConnections).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    var body: some View {
        SettingsCard(title: "Workspaces", detail: "Paired devices automatically have access to all available workspaces.") {
            if active.isEmpty {
                Text("No workspaces connected.")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            ForEach(active) { workspace in
                HStack(spacing: 12) {
                    DeviceConnectionIcon(kind: workspace.kind == .mac ? .mac : workspace.kind == .ios ? .iPhone : .unknown)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(workspace.name).font(.system(size: 13, weight: .medium))
                        Text(workspaceLabel(workspace.kind))
                            .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer()
                }
            }
        }.accessibilityIdentifier("companion.workspaces")
    }
    private func workspaceLabel(_ kind: CompanionExecutionWorkspace.Kind) -> String {
        switch kind {
        case .mac: "Mac workspace"
        case .linux: "Linux workspace"
        case .ios: "iPhone or iPad workspace"
        }
    }
}

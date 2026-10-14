import AppKit
import CompanionClient
import SwiftUI
import WovenMatterCompanion

struct SettingsCompanionView: View {
    @Bindable var model: ApplicationModel
    @Bindable var host: CompanionHostController
    @State private var recoveryError: String?
    @State private var switching = false
    @State private var confirmRoleChange = false
    @State private var updatingAccess: Set<String> = []
    var reservesRailControlSpace = false
    var onBack: () -> Void
    private var client: CentralLibraryClientModel { model.libraryClient }

    var body: some View {
        SettingsPage(title: "Device Connections", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if model.isLibraryClient {
                CentralLibraryPairingCard(client: client, application: model)
                SettingsCard(title: "This Mac") {
                    HStack {
                        DeviceConnectionIcon(kind: .mac)
                        Text(Host.current().localizedName ?? "This Mac").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Toggle("Available to paired devices", isOn: Binding(get: { client.sharingLocalExecution }, set: { enabled in
                            Task { if enabled { await client.startLocalSharing() } else { await client.stopLocalSharing() } }
                        })).toggleStyle(DashboardSwitchToggleStyle()).disabled(client.localSharingBusy || client.localExecution == nil)
                    }
                    if let error = client.deviceConnectionsError { Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger) }
                }
                if !client.connectedDevices.isEmpty { clientDeviceRoster }
            } else {
                SettingsCard(title: "Central database") {
                    HStack(spacing: 12) {
                        DeviceConnectionIcon(kind: .mac)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Host.current().localizedName ?? "This Mac").font(.system(size: 13, weight: .medium))
                            Text(host.endpoint == nil ? "Sharing is off" : "Available to paired devices")
                                .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Spacer()
                        Button(host.endpoint == nil ? "Start sharing" : "Stop sharing") {
                            if host.endpoint == nil { Task { await host.start() } } else { host.stopSharing() }
                        }.buttonStyle(SettingsQuietButtonStyle()).disabled(host.isStarting).accessibilityIdentifier("companion.sharing")
                    }
                }
                if !host.pendingPairingRequests.isEmpty { pairingRequests }
                if !host.pairedDevices.isEmpty { pairedDevices }
                if !host.pendingDeviceRevocations.isEmpty { pendingRevocations }
            }
            if !model.isLibraryClient || client.credential == nil {
                DevicePairingDiscoveryCard(pairing: client.devicePairing, host: host, isCentral: !model.isLibraryClient, canPairWithCentral: model.isLibraryClient)
            }
            if !model.isLibraryClient, host.endpoint != nil { DevicePairingCodeCard(host: host) }
            if !model.isLibraryClient, let message = host.errorMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
                    .textSelection(.enabled).accessibilityIdentifier("companion.error")
            }
            if let error = client.deviceConnectionsError, !model.isLibraryClient {
                Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
            }
            if !model.companionRecoveredNoteDrafts.isEmpty { recoveredDrafts }
            SettingsCard(title: "Database role", detail: model.isLibraryClient
                ? "This Mac is a node. Pair it with a central database to share its data and workspaces."
                : "This Mac hosts the central database. Paired devices use this database and its connected workspaces.") {
                HStack {
                    Text(model.isLibraryClient ? "Node" : "Central database").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button(model.isLibraryClient ? "Use as central database…" : "Change to node…") { confirmRoleChange = true }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(switching)
                }
                Text("Changing roles restarts Woven Matter. This Mac’s existing data stays on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
        .task {
            await client.initialize()
            if model.isLibraryClient { await client.devicePairing.restorePendingRequest() }
            while !Task.isCancelled {
                if !model.isLibraryClient { await host.refreshStatus() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onDisappear { client.devicePairing.stopPairingMode() }
        .confirmationDialog(model.isLibraryClient ? "Use this Mac as a central database?" : "Change this Mac to a node?", isPresented: $confirmRoleChange) {
            Button("Change role and restart") {
                switching = true
                Task {
                    defer { switching = false }
                    do {
                        if model.isLibraryClient { try await model.returnToCentralLibraryMode() }
                        else { try await model.activateLibraryClientMode() }
                    } catch { client.deviceConnectionsError = error.localizedDescription }
                }
            }
        } message: {
            Text(model.isLibraryClient
                ? "This reopens this Mac’s own database. Its paired database and pending changes stay saved separately."
                : "After restarting, pair this node with a central database. This Mac’s existing database stays saved separately.")
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
            ForEach(host.pairedDevices) { device in
                DisclosureGroup {
                    ForEach(host.executionWorkspaces.filter { !$0.deleted && $0.kind != .ios && $0.executionDeviceID != device.id }) { workspace in
                        let key = device.id + ":" + workspace.id
                        Toggle(isOn: Binding(get: {
                            host.workspaceAccessPolicies.first { $0.deviceID == device.id && $0.workspaceID == workspace.id }?.enabled ?? true
                        }, set: { enabled in
                            updatingAccess.insert(key)
                            Task {
                                await host.setExecutionAccess(deviceID: device.id, workspaceID: workspace.id, enabled: enabled)
                                updatingAccess.remove(key)
                            }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.name).font(.system(size: 12))
                                if host.pendingDeviceRevocations[device.id]?.contains(workspace.id) == true {
                                    Text("Revocation waiting for this workspace").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                }
                            }
                        }.toggleStyle(DashboardSwitchToggleStyle()).disabled(updatingAccess.contains(key))
                    }
                    Text("Workspace access controls agent execution. The central database remains available.")
                        .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    Button("Unpair device", role: .destructive) { Task { await host.revoke(device.id) } }
                        .buttonStyle(SettingsQuietButtonStyle()).accessibilityIdentifier("companion.revoke")
                } label: {
                    HStack(spacing: 12) {
                        DeviceConnectionIcon(kind: device.kind)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(.system(size: 13, weight: .medium))
                            Text(DeviceConnectionIcon.label(device.kind)).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            if let seen = device.lastSeenAt {
                                Text("Last seen \(seen.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            } else {
                                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                        }
                    }
                }.disclosureGroupStyle(SettingsDisclosureGroupStyle())
            }
        }
    }
    private var pendingRevocations: some View {
        SettingsCard(title: "Pending revocations") {
            ForEach(host.pendingDeviceRevocations.keys.sorted(), id: \.self) { id in
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.pairedDevices.first { $0.id == id }?.name ?? "Disconnected device")
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

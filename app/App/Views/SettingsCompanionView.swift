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
    var onOpenBots: () -> Void = {}
    private var client: CentralLibraryClientModel { model.libraryClient }

    var body: some View {
        SettingsPage(title: "Apple Devices", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if DevelopmentLaunch.isClient {
                SettingsSection {
                    deviceRow(icon: .mac, title: model.backendReplica.endpoint?.host ?? "Live library", detail: model.backendReplica.status)
                    SettingsNote("This development instance keeps a local database synchronized with the live library. Its own background server runs its agents and scheduled work.")
                }
            } else {
                SettingsSection {
                    deviceRow(icon: .mac, title: DevelopmentLaunch.deviceName(), detail: "This Mac")
                }
                BotsVersionStatusLink(bots: model.bots, onOpen: onOpenBots)
                if !host.pendingPairingRequests.isEmpty { pairingRequests }
                if host.pairedDevices.contains(where: { $0.id != host.peerIdentity?.deviceID }) { pairedDevices }
                if !host.pendingDeviceRevocations.isEmpty { pendingRevocations }
                pairSection
                if !host.peerSyncErrors.isEmpty {
                    SettingsSection(title: "Synchronization needs attention", detail: "Local writing is saved while synchronization retries.") {
                        ForEach(Array(Set(host.peerSyncErrors.values)).sorted(), id: \.self) { message in
                            SettingsError(message)
                        }
                    }
                }
                if !model.companionRecoveredNoteDrafts.isEmpty { recoveredDrafts }
            }
            SettingsHelp {
                SettingsNote("Each Mac keeps a complete local library with shared notes, chats, library files, settings, and connections. You can add workspaces or Apple devices from any Mac. Offline changes synchronize automatically when the Macs reconnect.")
                SettingsNote("Paired devices can use all available workspaces, listed in Settings → Workspaces. Agents and scheduled work keep running on the workspace that owns them.")
            }
        }
        .task {
            guard !DevelopmentLaunch.isClient else { return }
            while !Task.isCancelled {
                await host.refreshStatus()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func deviceRow(icon: CompanionDeviceKind, title: String, detail: String?) -> some View {
        HStack(spacing: 12) {
            DeviceConnectionIcon(kind: icon, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.settingsRow)
                if let detail {
                    Text(detail).font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: SettingsMetrics.rowHeight)
    }

    /// Three ways to pair, closed until needed.
    private var pairSection: some View {
        SettingsSection(title: "Pair a device") {
            DevicePairingDiscoveryCard(pairing: client.devicePairing, host: host, canPairWithCentral: true)
            DevicePairingCodeCard(host: host)
            SettingsSummaryRow("Paste a pairing link") {
                SettingsNote("Copy a pairing link from the other Mac’s Apple Devices settings.")
                HStack {
                    SecureField("Pairing link", text: $pairingLink)
                        .dashboardInput()
                        .accessibilityIdentifier("companion.peer-link")
                    Button("Pair Mac") {
                        let link = pairingLink; pairingLink = ""; pairingLinkBusy = true
                        Task { await host.pairUsingLink(link); pairingLinkBusy = false }
                    }.buttonStyle(SettingsQuietButtonStyle())
                        .disabled(pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairingLinkBusy)
                }
            }
            if !host.peerPairingStatus.isEmpty {
                SettingsRow(title: host.peerPairingStatus) {
                    Button("Cancel pairing") { Task { await host.cancelPeerPairing() } }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
            if let message = host.peerPairingError ?? host.errorMessage {
                SettingsError(message).accessibilityIdentifier("companion.error")
            }
        }
    }

    private var pairingRequests: some View {
        SettingsSection(title: "Pairing requests") {
            ForEach(host.pendingPairingRequests) { request in
                HStack(spacing: 12) {
                    DeviceConnectionIcon(kind: request.identity.metadata.kind, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.identity.deviceName).font(.settingsRow)
                        Text(DeviceConnectionIcon.label(request.identity.metadata.kind)).font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer()
                    Button("Decline") { Task { await host.denyPairing(id: request.id) } }.buttonStyle(SettingsQuietButtonStyle())
                    Button("Pair") { Task { await host.approvePairing(id: request.id) } }.buttonStyle(SettingsQuietButtonStyle())
                }
                .frame(minHeight: SettingsMetrics.rowHeight)
            }
        }
    }

    private var pairedDevices: some View {
        SettingsSection(title: "Paired devices") {
            ForEach(host.pairedDevices.filter { $0.id != host.peerIdentity?.deviceID }) { device in
                HStack(spacing: 12) {
                    DeviceConnectionIcon(kind: device.kind, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName).font(.settingsRow)
                        Group {
                            if let seen = device.lastSeenAt {
                                Text("\(DeviceConnectionIcon.label(device.kind)) · Last seen \(seen.formatted(date: .abbreviated, time: .shortened))")
                            } else {
                                Text("\(DeviceConnectionIcon.label(device.kind)) · Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                        .font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer()
                    Button("Unpair device", role: .destructive) { Task { await host.revoke(device.id) } }
                        .buttonStyle(SettingsQuietButtonStyle()).accessibilityIdentifier("companion.revoke")
                }
                .frame(minHeight: SettingsMetrics.rowHeight)
            }
        }
    }

    private var pendingRevocations: some View {
        SettingsSection(title: "Pending revocations") {
            ForEach(host.pendingDeviceRevocations.keys.sorted(), id: \.self) { id in
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.pairedDevices.first { $0.id == id }?.displayName ?? "Disconnected device")
                        .font(.settingsRow)
                    let names = (host.pendingDeviceRevocations[id] ?? []).map { workspaceID in
                        host.executionWorkspaces.first { $0.id == workspaceID }?.name ?? "Unavailable workspace"
                    }
                    Text("Waiting for " + names.joined(separator: ", "))
                        .font(.settingsSecondary).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
        }
    }

    private var recoveredDrafts: some View {
        SettingsSection(title: "Recovered writing") {
            ForEach(model.companionRecoveredNoteDrafts) { draft in
                SettingsRow(title: draft.title.isEmpty ? "Untitled note" : draft.title) {
                    Button("Save a copy") {
                        Task {
                            do { _ = try await model.preserveRecoveredNoteAsCopy(id: draft.id); recoveryError = nil }
                            catch { recoveryError = error.localizedDescription }
                        }
                    }.buttonStyle(SettingsQuietButtonStyle())
                }
            }
            if let recoveryError { SettingsError(recoveryError) }
        }
    }
}

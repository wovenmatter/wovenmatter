import AppKit
import SwiftUI
import WovenMatterCore

struct LibraryTransferSettings: View {
    @Bindable var model: ApplicationModel
    @Bindable var host: CompanionHostController
    private var state: LibraryTransferPresentation { model.isBackendFrontend ? host.libraryTransfer : model.libraryTransfer.presentation }
    @State private var restarting = false
    @State private var restartError: String?
    var body: some View {
        if !state.invitations.isEmpty {
            SettingsCard(title: "Central database requests") {
                ForEach(state.invitations) { peer in
                    HStack {
                        Text("\(peer.advertisement.identity.deviceName) wants to host your central database.")
                        Spacer()
                        Button("Review transfer…") { Task { await host.beginLibraryTransfer(peer) } }.buttonStyle(SettingsQuietButtonStyle())
                    }
                }
            }
        }
        ForEach(state.incoming.filter { [.awaitingApproval, .receiving, .verified].contains($0.status.phase) }, id: \.request.id) { session in
            SettingsCard(title: "Move central database to this Mac") {
                Text("Merge the library from \(session.request.source.deviceName) with this Mac’s database and retain all data from both. Each Mac keeps a backup. Workspaces and agent credentials stay on their owning devices.")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                if session.status.phase == .awaitingApproval {
                    HStack {
                        Button("Decline") { Task { await host.declineLibraryTransfer(session.request.id) } }.buttonStyle(SettingsQuietButtonStyle())
                        Button("Back up and accept transfer") { Task { await host.approveLibraryTransfer(session.request.id) } }.buttonStyle(DashboardPrimaryButtonStyle())
                    }
                } else {
                    ProgressView(session.status.phase == .verified ? "Merged library verified. Waiting for the other Mac to complete the handoff…" : "Backing up, receiving, and merging the databases…")
                        .controlSize(.small)
                }
            }
        }
        if let outgoing = state.outgoing, outgoing.phase != .cancelled {
            SettingsCard(title: "Database transfer") {
                Text(state.message ?? "Your transfer is saved. Keep both Macs connected until verification finishes.")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                if let backup = outgoing.backupPath {
                    Button("Show this Mac’s backup in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backup) }.buttonStyle(SettingsQuietButtonStyle())
                }
                if outgoing.phase != .committed {
                    HStack {
                        Button("Retry transfer") { Task { await host.retryLibraryTransfer() } }.buttonStyle(SettingsQuietButtonStyle())
                        if outgoing.phase != .verified {
                            Button("Cancel transfer") { Task { await host.cancelLibraryTransfer() } }.buttonStyle(SettingsQuietButtonStyle())
                        }
                    }
                }
            }
        }
        if state.restartRequired {
            SettingsCard(title: "Your merged library is ready") {
                Text("Restart Woven Matter to continue with the new database role. Both original backups are retained.")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                Button("Continue and restart") {
                    restarting = true
                    Task { defer { restarting = false }; do { try await model.restartAfterLibraryTransfer() } catch { restartError = error.localizedDescription } }
                }.buttonStyle(DashboardPrimaryButtonStyle()).disabled(restarting)
                if let restartError { Text(restartError).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger) }
            }
        } else if let message = state.message, state.outgoing == nil {
            Text(message).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
        }
        ForEach(state.incoming.filter { $0.status.backupPath != nil }, id: \.request.id) { session in
            SettingsCard(title: "Retained database backup") {
                if let backup = session.status.backupPath {
                    Button("Show this Mac’s backup in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: backup) }.buttonStyle(SettingsQuietButtonStyle())
                }
                if let count = session.status.recoveredItemCount, count > 0 { Text("\(count) conflicting items were kept as recovery copies.").font(.system(size: 12)) }
                if let count = session.status.retainedConflictCount, count > 0 { Text("\(count) additional conflicting records are retained in the merged database and both original backups.").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground) }
            }
        }
    }
}

struct LibraryTransferChooser: View {
    @Bindable var model: ApplicationModel
    @Bindable var host: CompanionHostController
    @Environment(\.dismiss) private var dismiss
    @State private var selected: CompanionDiscoveredPeer?
    private var peers: [CompanionDiscoveredPeer] { host.discoveredPeers.filter { $0.advertisement.capabilities?.contains("library.transfer.v1") == true } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose the next central Mac").font(.title2.weight(.semibold))
            Text("Both Macs keep a backup. Their libraries are merged, including a database preserved before the destination became a node. Conflicting writing is retained, and paired devices follow the new central database.")
                .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(peers) { peer in
                        Button { selected = peer } label: {
                            HStack(spacing: 10) {
                                DeviceConnectionIcon(kind: .mac)
                                Text(peer.advertisement.identity.deviceName)
                                Spacer()
                                Image(systemName: selected?.id == peer.id ? "checkmark.circle.fill" : "circle")
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.buttonStyle(SettingsQuietButtonStyle())
                    }
                    if peers.isEmpty { Text("Open Woven Matter on the destination Mac and connect both Macs to Tailscale. Both need a version that supports database transfer.").font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground) }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(SettingsQuietButtonStyle())
                Button("Refresh Macs") { Task { await host.refreshDiscovery() } }.buttonStyle(SettingsQuietButtonStyle()).disabled(host.isDiscovering)
                Spacer()
                Button("Transfer and become a node") {
                    guard let selected else { return }
                    Task { await host.beginLibraryTransfer(selected); dismiss() }
                }.buttonStyle(DashboardPrimaryButtonStyle()).disabled(selected == nil)
            }
        }.padding(24).frame(width: 600, height: 420)
            .task { await host.refreshDiscovery() }
    }
}

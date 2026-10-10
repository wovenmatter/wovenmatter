import AppKit
import CompanionClient
import SwiftUI

struct CentralLibraryClientSettings: View {
    @Bindable var model: CentralLibraryClientModel
    let application: ApplicationModel
    @AppStorage(DashboardTheme.storageKey) private var theme = DashboardTheme.green.rawValue
    @State private var switching = false
    @State private var executionSettings = false
    var body: some View {
        SettingsPage(title: "Settings", detail: "This Mac is a client of your central Woven Matter library.") {
            CentralLibraryPairingCard(client: model, application: application)
            SettingsCard(title: "Synchronization", detail: model.status) {
                HStack {
                    Text(model.state.outbox.isEmpty ? "No saved changes waiting to sync." : "\(model.state.outbox.count) saved changes waiting to sync.")
                    Spacer()
                    Button("Sync now") { Task { await model.refresh() } }.buttonStyle(SettingsQuietButtonStyle()).disabled(model.refreshing)
                }
                Text("Notes and drafts stay on this Mac while disconnected. Execution remains in the workspace that owns each conversation.")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            SettingsCard(title: "Execution on this Mac", detail: "Run agents here using a separate workspace. Shared app data still synchronizes with the central library.") {
                if model.localExecution == nil {
                    Button(model.localExecutionBusy ? "Starting…" : "Enable execution on this Mac") { Task { await model.enableLocalExecution() } }
                        .buttonStyle(SettingsQuietButtonStyle()).disabled(model.localExecutionBusy || model.credential == nil)
                } else {
                    Text("This Mac is available in the execution workspace selector.").font(.system(size: 13))
                    Button("Configure this Mac’s agents and connections") { executionSettings = true }
                        .buttonStyle(SettingsQuietButtonStyle())
                    Button(model.sharingLocalExecution ? "Stop sharing execution" : "Share execution with other devices") {
                        Task { if model.sharingLocalExecution { await model.stopLocalSharing() } else { await model.startLocalSharing() } }
                    }.buttonStyle(SettingsQuietButtonStyle()).disabled(model.localSharingBusy || model.preparingTransition)
                    Text("Sharing uses Tailscale and grants access only to devices authorized by your central library. Keep this app running while its agents work.")
                        .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
            SettingsCard(title: "Execution workspaces", detail: "Authorize direct access while the central Mac is available. These workspaces then remain usable when it is offline.") {
                ForEach(model.executionWorkspaces) { workspace in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.name).font(.system(size: 13, weight: .medium))
                            Text(model.directOnline.contains(workspace.id) ? "Connected directly" : workspace.kind.rawValue.capitalized)
                                .font(.caption).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Spacer()
                        Button("Enable direct access") { Task { await model.enableDirectAccess(workspace.id) } }
                            .buttonStyle(SettingsQuietButtonStyle()).disabled(!model.online || workspace.endpoint == nil)
                    }
                }
                if model.executionWorkspaces.isEmpty { Text("Registered execution workspaces appear after synchronization.").font(.caption) }
            }
            SettingsCard(title: "Appearance") {
                DashboardSegmentedSelector(options: DashboardTheme.allCases.map(\.rawValue), selection: $theme) { DashboardTheme(rawValue: $0)?.title ?? $0 }
            }
            SettingsCard(title: "This Mac’s library", detail: "The previous central library remains stored separately. Returning to it restarts Woven Matter and keeps this client’s saved data.") {
                Button("Return to this Mac’s library…") {
                    switching = true
                    Task {
                        defer { switching = false }
                        do { try await application.returnToCentralLibraryMode() }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(switching)
            }
        }.task { await model.initialize() }
        .sheet(isPresented: $executionSettings) {
            if let execution = model.localExecution {
                VStack(spacing: 0) {
                    HStack { Spacer(); Button("Done") { executionSettings = false }.keyboardShortcut(.cancelAction) }.padding()
                    SettingsView(model: execution.model, executionOnly: true)
                }.frame(width: 740, height: 700)
            }
        }
    }
}

struct CentralLibraryPairingCard: View {
    @Bindable var client: CentralLibraryClientModel
    let application: ApplicationModel
    @State private var pairing = false
    @State private var switching = false
    @State private var message: String?
    var body: some View {
        SettingsCard(title: application.isLibraryClient ? "Central library" : "Use another Mac’s central library",
            detail: "Keep both Macs on the same Tailscale network. Copy a pairing link from Devices in Woven Matter on your central Mac.") {
            if let credential = client.credential {
                Text(credential.endpoint.absoluteString).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                if !application.isLibraryClient {
                    Text("Pairing is ready. Switching restarts this app as a client and preserves this Mac’s existing library.")
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                    Button("Use as client and restart") {
                        switching = true
                        Task {
                            defer { switching = false }
                            do { try await application.activateLibraryClientMode() }
                            catch { message = error.localizedDescription }
                        }
                    }.buttonStyle(SettingsQuietButtonStyle()).disabled(switching)
                }
            }
            HStack {
                SecureField("Paste pairing link", text: $client.pairingText).textFieldStyle(.roundedBorder)
                Button(pairing ? "Pairing…" : "Pair") {
                    pairing = true
                    Task {
                        defer { pairing = false }
                        if await client.pair(client.pairingText) { message = "Paired with central library." }
                        else { message = client.errorMessage }
                    }
                }.buttonStyle(SettingsQuietButtonStyle()).disabled(pairing || client.pairingText.isEmpty)
            }
            if let message { Text(message).font(.system(size: 12)).textSelection(.enabled) }
        }.task { await client.initialize() }
    }
}

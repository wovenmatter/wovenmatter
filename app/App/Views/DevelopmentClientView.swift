import AppKit
import SwiftUI

/// The production desktop surface backed by this instance's execution model and
/// synchronized replica. Enrollment remains in the existing connection UI.
struct DevelopmentClientView: View {
    @Bindable var application: ApplicationModel
    private var client: CentralLibraryClientModel { application.libraryClient }
    @State private var showsConnection = false
    @State private var showsConflicts = false

    var body: some View {
        Group {
            if let execution = client.localExecution {
                RootView(model: execution.model)
                    .toolbar {
                        ToolbarItem {
                            Button(DevelopmentLaunch.displayName) { showsConnection = true }
                                .help("Live library · " + client.status)
                        }
                        if !client.state.conflicts.isEmpty {
                            ToolbarItem {
                                Button("Saved conflicts") { showsConflicts = true }
                            }
                        }
                    }
            } else {
                connectionSetup
            }
        }
        .sheet(isPresented: $showsConnection) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { showsConnection = false }
                        .buttonStyle(SettingsQuietButtonStyle())
                }.padding(16)
                CentralLibraryClientSettings(model: client, application: application,
                    onBackFromSetup: { showsConnection = false })
            }
            .frame(minWidth: 560, minHeight: 480)
        }
        .task { await client.run() }
        .alert("Woven Matter", isPresented: Binding(
            get: { client.errorMessage != nil }, set: { if !$0 { client.errorMessage = nil } }
        )) {
            Button("OK") { client.errorMessage = nil }
        } message: { Text(client.errorMessage ?? "") }
        .sheet(isPresented: $showsConflicts) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Saved conflicts").font(.headline)
                ForEach(client.state.conflicts.keys.sorted(), id: \.self) { id in
                    if let conflict = client.state.conflicts[id] {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(conflict.local.title)
                                Text(conflict.reason).font(.caption)
                            }
                            Spacer()
                            Button("Keep as copy") { Task { await client.preserveConflict(id) } }
                        }
                    }
                }
                Button("Done") { showsConflicts = false }
            }
            .padding(24).frame(minWidth: 480)
        }
    }

    private var connectionSetup: some View {
        SettingsPage(title: "Connect your Dev client") {
            SettingsCard(title: "Production library") {
                Text("This client needs a running library host before it can open your workspace.")
                Text("Open Woven Matter with background execution enabled, then retry. The host must support Dev client connections and have its central library available through Tailscale.")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                if let error = client.deviceConnectionsError ?? client.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
                        .textSelection(.enabled)
                }
                HStack {
                    Button(client.developmentConnectionBusy ? "Connecting…" : "Retry connection") {
                        Task {
                            if client.credential == nil { await client.connectDevelopmentLibrary() }
                            else { await client.initializeClientWorkspace() }
                        }
                    }
                    .disabled(!client.initialized || client.developmentConnectionBusy || client.localExecutionBusy)
                    Button("Devices…") { showsConnection = true }
                    Button("Quit Dev client") { NSApplication.shared.terminate(nil) }
                }.buttonStyle(SettingsQuietButtonStyle())
            }
            SettingsCard(title: "Testing without a running host") {
                Text("For an independent copy of your library, launch this branch in snapshot mode from the terminal:")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                Text("scripts/build_and_run.sh --mode snapshot --instance " + (DevelopmentLaunch.instance ?? "review"))
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

}

import AppKit
import CompanionClient
import SwiftUI

/// Both library roles use the same desktop settings navigation. Provider and
/// harness controls belong to this Mac's execution workspace.
struct CentralLibraryClientSettings: View {
    @Bindable var model: CentralLibraryClientModel
    let application: ApplicationModel
    var body: some View {
        Group {
            if showingDevices || model.credential == nil {
                SettingsCompanionView(model: application, host: application.companionHost, onBack: { showingDevices = false })
            } else if let execution = model.localExecution {
                SettingsView(model: execution.model, clientContext: model, applicationContext: application)
            } else {
                SettingsPage(title: "Settings") {
                    if model.localExecutionBusy { ProgressView("Opening this Mac’s workspace…") }
                    SettingsDestinationRow(title: "Device Connections", icon: { DashboardLucideIcon(glyph: .monitor, size: 15) }) {
                        showingDevices = true
                    }
                    MobileAnalyticsSettingsCard(analytics: model.analytics)
                    if let error = model.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
                        Button("Retry opening workspace") { Task { await model.initializeClientWorkspace() } }
                            .buttonStyle(SettingsQuietButtonStyle())
                    }
                }
            }
        }
        .task { await model.initializeClientWorkspace() }
    }
    @State private var showingDevices = false
}

struct CentralLibraryPairingCard: View {
    @Bindable var client: CentralLibraryClientModel
    let application: ApplicationModel
    @State private var pairing = false
    @State private var message: String?
    var body: some View {
        SettingsCard(title: "Central database") {
            if let credential = client.credential {
                HStack(spacing: 12) {
                    DashboardLucideIcon(glyph: .monitor, size: 20)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credential.endpoint.host ?? "Central database").font(.system(size: 13, weight: .medium))
                        if application.isLibraryClient {
                            Text(client.status).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                    }
                    Spacer()
                    Button("Unpair") { Task { await client.disconnectCentralLibrary() } }
                        .buttonStyle(SettingsQuietButtonStyle())
                }

            } else {
                HStack {
                    SecureField("Paste pairing link", text: $client.pairingText).dashboardInput().privacySensitive()
                    Button(pairing ? "Pairing…" : "Pair") {
                        pairing = true; message = nil
                        Task {
                            defer { pairing = false }
                            if !(await client.pair(client.pairingText)) { message = client.deviceConnectionsError }
                        }
                    }.buttonStyle(SettingsQuietButtonStyle()).disabled(pairing || client.pairingText.isEmpty)
                }
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
        }
    }
}

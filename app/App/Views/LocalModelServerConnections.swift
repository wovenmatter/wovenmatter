import SwiftUI
import WovenProtocol

struct LocalModelServerConnections: View {
    @Bindable var agent: AgentSettingsStore
    /// The machine whose servers these are.
    let machineID: String?
    /// At most this many servers per machine.
    static let maximumServers = 12
    private var servers: [LocalModelServer] { agent.connections(on: machineID).localServers }
    @State private var error: String?
    @State private var adding = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsNote("OpenAI Responses-compatible servers on this Mac or your Tailscale network.")
            ForEach(servers) { server in
                SettingsSummaryRow(server.name, value: server.models.count == 1 ? "1 model" : "\(server.models.count) models") {
                    LocalModelServerConnectionRow(agent: agent, machineID: machineID, server: server, changed: reload)
                }
            }
            if adding {
                LocalModelServerConnectionRow(agent: agent, machineID: machineID, server: nil) { adding = false; reload() }
            } else if servers.count < Self.maximumServers {
                Button("Add model server") { adding = true }.buttonStyle(SettingsQuietButtonStyle())
            }
            if let error { SettingsError(error) }
        }
        .task { reload() }
    }
    private func reload() {
        Task { do { try await agent.reloadLocalServers(on: machineID); error = nil } catch { self.error = error.localizedDescription } }
    }
}

private struct LocalModelServerConnectionRow: View {
    @Bindable var agent: AgentSettingsStore
    let machineID: String?
    let server: LocalModelServer?
    let changed: () -> Void
    @State private var url = ""
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?
    @State private var verified = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Server URL", text: $url).wovenInput()
                .accessibilityLabel("Local model server URL")
                .disabled(server != nil)
            if server != nil {
                Text("Add a new connection to use a different server URL.").font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
            }
            SecureField(server == nil ? "API key" : "API key · leave empty to keep saved key", text: $key)
                .wovenInput().accessibilityLabel("Local model server API key")
            HStack {
                Button(busy ? "Connecting…" : "Connect") { connect() }
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(busy || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (server == nil && key.isEmpty))
                if let server {
                    Text(verified ? "Connected · \(server.models.count) models" : "Saved · \(server.models.count) models · checked \(server.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                    Spacer()
                    Button("Remove") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do { try await agent.removeLocalServer(server, on: machineID); changed() }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                }
            }
            if let error { SettingsError(error) }
        }
        .task { url = server?.url ?? "" }
    }
    private func connect() {
        busy = true; error = nil; verified = false
        let enteredURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            do {
                try await agent.connectLocalServer(url: enteredURL, key: enteredKey, replacing: server, on: machineID)
                key = ""; verified = true; changed()
            } catch { self.error = error.localizedDescription }
        }
    }
}

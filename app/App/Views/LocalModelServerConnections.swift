import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct LocalModelServerConnections: View {
    @Bindable var agent: DefaultAgentSettingsModel
    private var servers: [LocalModelServer] { agent.localServers }
    @State private var error: String?
    @State private var adding = false
    var body: some View {
        SettingsCard(title: "Local models", detail: "Connect OpenAI Responses-compatible servers on this Mac or your Tailscale network.") {
            ForEach(servers) { server in
                LocalModelServerConnectionRow(agent: agent, server: server, changed: reload)
                Divider()
            }
            if adding || servers.isEmpty {
                LocalModelServerConnectionRow(agent: agent, server: nil) { adding = false; reload() }
            } else if servers.count < LocalModelServerStore.maximumServers {
                Button("Add model server") { adding = true }.buttonStyle(SettingsQuietButtonStyle())
            }
            if let error { SettingsError(error) }
        }
        .task { reload() }
    }
    private func reload() {
        Task { do { try await agent.reloadLocalServers(); error = nil } catch { self.error = error.localizedDescription } }
    }
}

private struct LocalModelServerConnectionRow: View {
    @Bindable var agent: DefaultAgentSettingsModel
    let server: LocalModelServer?
    let changed: () -> Void
    @State private var url = ""
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?
    @State private var verified = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Server URL", text: $url).settingsInput()
                .accessibilityLabel("Local model server URL")
                .disabled(server != nil)
            if server != nil {
                Text("Add a new connection to use a different server URL.").font(.caption).foregroundStyle(.secondary)
            }
            SecureField(server == nil ? "API key" : "API key · leave empty to keep saved key", text: $key)
                .settingsInput().accessibilityLabel("Local model server API key")
            HStack {
                Button(busy ? "Connecting…" : "Connect") { connect() }
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(busy || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (server == nil && key.isEmpty))
                if let server {
                    Text(verified ? "Connected · \(server.models.count) models" : "Saved · \(server.models.count) models · checked \(server.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do { try await agent.removeLocalServer(server); changed() }
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
                try await agent.connectLocalServer(url: enteredURL, key: enteredKey, replacing: server)
                key = ""; verified = true; changed()
            } catch { self.error = error.localizedDescription }
        }
    }
}

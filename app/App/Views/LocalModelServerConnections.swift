import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct LocalModelServerConnections: View {
    @State private var servers = LocalModelServerStore.servers
    @State private var adding = false
    var body: some View {
        SettingsCard(title: "Local Model Server", detail: "Connect OpenAI Responses-compatible servers on this Mac or your Tailscale network.") {
            ForEach(servers) { server in
                LocalModelServerConnectionRow(server: server, changed: reload)
                Divider()
            }
            if adding || servers.isEmpty {
                LocalModelServerConnectionRow(server: nil) { adding = false; reload() }
            } else if servers.count < LocalModelServerStore.maximumServers {
                Button("Add model server") { adding = true }.buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }
    private func reload() { servers = LocalModelServerStore.servers }
}

private struct LocalModelServerConnectionRow: View {
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
                        do { try LocalModelServerStore.remove(server); changed() }
                        catch { self.error = error.localizedDescription }
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
                let savedKey = enteredKey.isEmpty ? try server.flatMap { try DefaultAgentSupport.key($0.id) } : enteredKey
                guard let savedKey, !savedKey.isEmpty else { throw DefaultAgentError.message("Enter the server API key.") }
                _ = try await LocalModelServerStore.connect(url: enteredURL, key: savedKey, replacing: server)
                key = ""; verified = true; changed()
            } catch { self.error = error.localizedDescription }
        }
    }
}

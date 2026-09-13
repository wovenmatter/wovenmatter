import SwiftUI
import WovenMatterClient

struct SettingsHermesView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var connection: HermesGatewayConnection?
    @State private var sessions: [HermesValue] = []
    @State private var known: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @State private var search = ""

    var body: some View {
        SettingsPage(title: "Hermes", detail: "Connect to Hermes and continue its conversations in Woven Matter.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            SettingsCard(title: "Connection", detail: "Uses the installed Hermes native Gateway and its selected profile.") {
                SettingsValueRow(label: "Profile home", value: connection?.home ?? "Not connected")
                SettingsValueRow(label: "Gateway", value: connection.map { "127.0.0.1:\($0.port)" } ?? "Enable Hermes in Local Agent Workspace")
                Text("Model and thinking choices apply to each conversation. Hermes keeps its own authentication and configuration.")
                    .font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
                Button(busy ? "Refreshing…" : "Refresh") { Task { await refresh() } }
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(busy)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground) }
            }
            SettingsCard(title: "Conversations", detail: "Up to 100 recent Hermes sessions. Imported conversations retain their original workspace.") {
                TextField("Search listed conversations", text: $search).textFieldStyle(.roundedBorder)
                if sessions.isEmpty { Text("No sessions listed.").font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground) }
                ForEach(sessions.filter { search.isEmpty || $0["title"].text.localizedCaseInsensitiveContains(search) }, id: \.self) { row in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row["title"].text.isEmpty ? "Untitled Hermes conversation" : row["title"].text)
                                .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(row["source"].text).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Spacer(minLength: 8)
                        let id = row["id"].text
                        Button(known.contains(id) ? "Added" : "Import") {
                            Task { await importSession(id) }
                        }.buttonStyle(SettingsQuietButtonStyle()).disabled(busy || known.contains(id))
                    }
                }
            }
        }.task { await refresh() }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let connected = try await model.hermesGatewayConnection()
            connection = connected
            let rpc = HermesGatewayRPC(connection: connected)
            do {
                try await rpc.connect()
                sessions = try await rpc.call("session.list", ["limit": .number(100)])["sessions"].array
                await rpc.disconnect()
            } catch { await rpc.disconnect(); throw error }
            known = try model.knownHermesSessions(home: connected.home)
        } catch { self.error = error.localizedDescription }
    }
    private func importSession(_ id: String) async {
        guard !busy, let connection else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await model.importHermesSession(connection: connection, sessionID: id)
            known = try model.knownHermesSessions(home: connection.home)
        } catch { self.error = error.localizedDescription }
    }
}

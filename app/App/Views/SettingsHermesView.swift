import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsHermesView: View {
    @Bindable var model: ApplicationModel
    var workspaceID: UUID?
    var isWorkspaceScoped = false
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onOpenAgent: (UUID) -> Void
    @State private var checking = false
    @State private var error: String?

    private var agents: [WorkspaceAgent] {
        model.localCLIAgents.filter { $0.runtimeKind == .hermes }
    }
    private var remoteConfigurations: [RemoteWorkspaceConfiguration] {
        model.remoteWorkspaces.workspaces.filter { !isWorkspaceScoped || $0.id == workspaceID }
    }

    var body: some View {
        SettingsPage(title: "Hermes", detail: "Independent Hermes settings for this Mac and each remote workspace.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if !isWorkspaceScoped || workspaceID == nil {
                SettingsCard(title: "Local agent workspace", detail: "Open an agent to manage its Woven Matter name and Gateway connection.") {
                    if agents.isEmpty { SettingsEmpty("No Hermes agents discovered.") }
                    ForEach(agents) { agent in
                        SettingsInset {
                            HStack(spacing: 12) {
                                DashboardHarnessLogoIcon(logo: .hermes, size: 20).frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.displayName).font(.system(size: 13, weight: .medium))
                                    Text("Local agent workspace").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                let linked = model.isHermesGatewayLinked(agentID: agent.id)
                                let ready = linked && !checking && model.hermesGatewayConnections[agent.id] != nil
                                SettingsPill(checking && linked ? "Checking…" : ready ? "Ready" : "Not connected",
                                    tone: ready ? .neutral : .warning)
                                Button("Settings") { onOpenAgent(agent.id) }.buttonStyle(SettingsQuietButtonStyle())
                            }
                        }
                    }
                }
            }
            if !isWorkspaceScoped || workspaceID != nil {
                SettingsCard(title: "Remote agent workspaces", detail: "Discover agents in each connected workspace.") {
                    if remoteConfigurations.isEmpty { SettingsEmpty("No remote agent workspaces connected.") }
                    ForEach(remoteConfigurations) { configuration in
                        remoteWorkspace(configuration)
                    }
                }
            }
            if let error { SettingsError(error) }
            SettingsNote("Each agent has its own connection and Gateway controls.")
        }
        .task {
            if !isWorkspaceScoped { model.remoteWorkspaces.refreshAll() }
            else if let workspaceID, let configuration = model.remoteWorkspaces.configuration(id: workspaceID) {
                model.remoteWorkspaces.refresh(configuration)
            }
            guard !isWorkspaceScoped || workspaceID == nil else { return }
            checking = true; error = nil
            defer { checking = false }
            for agent in agents where model.isHermesGatewayLinked(agentID: agent.id) {
                do { try await model.connectHermesGateway(agentID: agent.id) }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func remoteWorkspace(_ configuration: RemoteWorkspaceConfiguration) -> some View {
        SettingsInset {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(configuration.name).font(.system(size: 13, weight: .medium))
                        Text(configuration.hostName).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                let found = model.remoteWorkspaces.currentHarnesses(for: configuration).first {
                    $0.id == .hermes && $0.installationStatus == "installed"
                }
                if let found {
                    HStack(spacing: 12) {
                        DashboardHarnessLogoIcon(logo: .hermes, size: 20).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.remoteWorkspaceAgents.first { $0.runtimeKind == .hermes && $0.runtimeDeviceID == configuration.id }?.displayName ?? found.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Text(configuration.name).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        SettingsPill("Gateway unavailable", tone: .warning)
                    }
                    SettingsNote("Native Hermes Gateway connections are not yet supported in remote workspaces.")
                } else { SettingsEmpty("No Hermes agents discovered.") }
                Button("Scan workspace") { model.remoteWorkspaces.refresh(configuration) }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
            .disabled(model.remoteWorkspaces.busyWorkspaceIDs.contains(configuration.id))
        }
    }
}

struct SettingsHermesAgentView: View {
    @Bindable var model: ApplicationModel
    let agentID: UUID
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var sessions: [HermesValue] = []
    @State private var known: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    @State private var name = ""
    @State private var search = ""
    @State private var page = 0
    @State private var loaded = false

    private var agent: WorkspaceAgent? { model.localCLIAgents.first { $0.id == agentID && $0.runtimeKind == .hermes } }
    private var connection: HermesGatewayConnection? { model.hermesGatewayConnections[agentID] }
    private var filtered: [HermesValue] {
        sessions.filter { !known.contains($0["id"].text) && (search.isEmpty || $0["title"].text.localizedCaseInsensitiveContains(search)) }
    }
    private var pageCount: Int { max(1, (filtered.count + 24) / 25) }

    var body: some View {
        SettingsPage(title: agent?.displayName ?? "Hermes", detail: "Woven Matter name and live Gateway connection for this agent.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if agent != nil {
                SettingsCard(title: "Gateway connection", detail: "Live connection state for this Hermes on this Mac.") {
                    HStack {
                        SettingsPill(connection != nil ? "Ready" : "Not connected", tone: .neutral)
                        Spacer()
                        Button(model.isHermesGatewayLinked(agentID: agentID) ? "Reconnect" : "Connect Gateway") { Task { await connect() } }.buttonStyle(SettingsQuietButtonStyle())
                        Button("Unlink") {
                            model.unlinkHermesGateway(agentID: agentID)
                            onBack()
                        }.buttonStyle(SettingsQuietButtonStyle())
                    }
                    SettingsValueRow(label: "Location", value: "Local agent workspace")
                    if let checked = model.hermesGatewayCheckedAt[agentID] {
                        SettingsValueRow(label: "Last checked", value: checked.formatted(date: .omitted, time: .standard))
                    }
                }
                SettingsCard(title: "Woven Matter name", detail: "Changes how this agent appears in Woven Matter. It does not rename or reconfigure Hermes.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Agent name").font(.system(size: 11, weight: .medium)).foregroundStyle(DashboardPalette.mutedForeground)
                        TextField("Agent name", text: $name).textFieldStyle(.roundedBorder)
                        Button("Save Woven Matter Name") {
                            Task {
                                busy = true; error = nil
                                defer { busy = false }
                                do { try await model.renameHermesAgent(agentID: agentID, displayName: name) }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(DashboardPrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                SettingsCard(title: "Shared Hermes sessions", detail: "Import an existing conversation with its original working directory. Up to 100 recent sessions, 25 per page.") {
                    Button("Refresh sessions") { Task { await refresh() } }
                        .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 26)).disabled(connection == nil)
                    if loaded {
                        TextField("Search listed conversations", text: $search).textFieldStyle(.roundedBorder)
                            .onChange(of: search) { _, _ in page = 0 }
                        if filtered.isEmpty { SettingsEmpty("No sessions available to import.") }
                        ForEach(Array(filtered.dropFirst(page * 25).prefix(25)), id: \.self) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row["title"].text.isEmpty ? "Untitled Hermes conversation" : row["title"].text)
                                        .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(row["source"].text).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                }
                                Spacer(minLength: 8)
                                Button("Import") { Task { await importSession(row["id"].text) } }
                                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
                            }
                        }
                        HStack(spacing: 8) {
                            Button("Previous") { page -= 1 }.disabled(page == 0)
                            Text("Page \(page + 1) of \(pageCount)").font(.system(size: 10))
                            Button("Next") { page += 1 }.disabled(page + 1 >= pageCount)
                        }.buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
                    }
                }
                SettingsCard(title: "Gateway", detail: "Restarts this Gateway when idle, reconnects Woven Matter, and confirms that it is healthy.") {
                    Button("Restart Gateway") { Task { await connect(restart: true) } }
                        .buttonStyle(DashboardPrimaryButtonStyle())
                }
            } else { SettingsEmpty("This agent is no longer available.") }
            if let error { SettingsError(error) }
        }
        .disabled(busy)
        .task(id: agentID) {
            name = agent?.displayName ?? ""
            if model.isHermesGatewayLinked(agentID: agentID) { await connect() }
        }
    }

    private func connect(restart: Bool = false) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await model.connectHermesGateway(agentID: agentID, restart: restart) }
        catch { self.error = error.localizedDescription }
    }

    private func refresh() async {
        guard !busy, let connection else { return }
        busy = true; error = nil
        defer { busy = false }
        let rpc = HermesGatewayRPC(connection: connection)
        do {
            try await rpc.connect()
            let fetched = try await rpc.call("session.list", ["limit": .number(100)])["sessions"].array
            await rpc.disconnect()
            known = try model.knownHermesSessions(home: connection.home)
            sessions = fetched.filter { !known.contains($0["id"].text) }
            page = 0; loaded = true
        } catch { await rpc.disconnect(); self.error = error.localizedDescription }
    }

    private func importSession(_ id: String) async {
        guard !busy, let connection else { return }
        busy = true; error = nil
        defer { busy = false; page = min(page, pageCount - 1) }
        do {
            known = try model.knownHermesSessions(home: connection.home)
            sessions.removeAll { known.contains($0["id"].text) }
            guard !known.contains(id) else { return }
            try await model.importHermesSession(connection: connection, sessionID: id)
            sessions.removeAll { $0["id"].text == id }
            known = try model.knownHermesSessions(home: connection.home)
        } catch { self.error = error.localizedDescription }
    }
}

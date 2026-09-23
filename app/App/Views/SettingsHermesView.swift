import SwiftUI
import WovenMatterClient
import WovenMatterCore

private struct SettingsHermesProfileApprovals: View {
    @Bindable var model: ApplicationModel
    var agentID: UUID?
    var workspaceID: UUID?
    private var connected: Bool {
        if let workspaceID { return model.isRemoteHermesGatewayConnected(workspaceID: workspaceID) }
        if let agentID { return model.isHermesGatewayConnected(agentID: agentID) }
        return false
    }
    @State private var mode: String?
    @State private var busy = false
    @State private var error: String?
    @State private var requestID = UUID()

    private var selection: String {
        if let mode, let known = HermesProfileApprovalMode(rawValue: mode) { return known.displayName }
        if mode == "off" { return "Full access (profile)" }
        return busy ? "Loading…" : "Unavailable"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Approval policy").font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                SettingsMenuPicker(
                    selection: selection,
                    options: HermesProfileApprovalMode.allCases.map(\.displayName),
                    width: 190
                ) { label in
                    guard let choice = HermesProfileApprovalMode.allCases.first(where: { $0.displayName == label }) else { return }
                    Task { await update(choice) }
                }
                .accessibilityLabel("Hermes profile approval policy")
                .disabled(busy || !connected || mode == nil)
                Button("Refresh") { Task { await update(nil) } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(busy || !connected)
            }
            SettingsNote("This setting applies to every conversation in this Hermes profile. Smart approvals uses Hermes’s reviewer to decide when to ask. The conversation’s Full access option bypasses that policy until you return to Ask for approval.")
            if !connected { SettingsNote("Connect Gateway to choose this profile’s approval policy.") }
            if let error { SettingsError(error) }
        }
        .task(id: connected) { await update(nil) }
        .onDisappear { requestID = UUID() }
    }

    @MainActor
    private func update(_ choice: HermesProfileApprovalMode?) async {
        let id = UUID()
        requestID = id
        error = nil
        if choice == nil { mode = nil }
        guard connected else { busy = false; return }
        busy = true
        defer { if requestID == id { busy = false } }
        do {
            let confirmed = try await model.hermesProfileApproval(agentID: agentID, workspaceID: workspaceID, mode: choice)
            guard requestID == id, !Task.isCancelled else { return }
            mode = confirmed
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            if choice != nil { mode = nil }
            self.error = error.localizedDescription
        }
    }
}

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
        SettingsPage(title: "Hermes",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if !isWorkspaceScoped || workspaceID == nil {
                SettingsCard(title: "Local agent workspace") {
                    if agents.isEmpty {
                        SettingsLocalRuntimeInventoryRow(model: model, runtimeKind: .hermes)
                    }
                    ForEach(agents) { agent in
                        SettingsInset {
                            HStack(spacing: 12) {
                                DashboardHarnessLogoIcon(logo: .hermes, size: 20).frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.displayName).font(.system(size: 13, weight: .medium))
                                    Text("Local agent workspace").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                                    Text(model.runtimeInventories[.hermes]?.summary ?? "Checking installed components…")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                let linked = model.isHermesGatewayLinked(agentID: agent.id)
                                let ready = linked && !checking && model.isHermesGatewayConnected(agentID: agent.id)
                                SettingsPill(checking && linked ? "Checking…" : ready ? "Ready" : "Not connected",
                                    tone: ready ? .neutral : .warning)
                                SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: .hermes)
                                Button("Settings") { onOpenAgent(agent.id) }.buttonStyle(SettingsQuietButtonStyle())
                            }
                        }
                    }
                    SettingsRuntimeMaintenanceErrorView(
                        model: model,
                        runtimeKind: .hermes,
                        workspaceID: nil
                    )
                }
            }
            if !isWorkspaceScoped || workspaceID != nil {
                SettingsCard(title: "Remote agent workspaces") {
                    if remoteConfigurations.isEmpty { SettingsEmpty("No remote agent workspaces connected.") }
                    ForEach(remoteConfigurations) { configuration in
                        remoteWorkspace(configuration)
                    }
                }
            }
            if let error { SettingsError(error) }
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
                            Text(remoteRuntimeDetail(configuration))
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        SettingsPill(!model.isRemoteHermesGatewayConnected(workspaceID: configuration.id) ? "Not connected" : "Ready", tone: .neutral)
                        SettingsRemoteRuntimeUpdateButton(
                            model: model.remoteWorkspaces,
                            harness: found,
                            configuration: configuration
                        )
                    }
                    Button("Connect Gateway") {
                        Task {
                            do { try await model.connectRemoteHermes(configuration) }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(SettingsQuietButtonStyle())
                    Button("Stop Gateway and scheduler") {
                        Task { do { try await model.stopRemoteHermes(configuration) } catch { self.error=error.localizedDescription } }
                    }.buttonStyle(SettingsQuietButtonStyle())
                    SettingsNote("Stopping Hermes pauses scheduled jobs until you reconnect its Gateway.")
                    SettingsHermesProfileApprovals(model: model, workspaceID: configuration.id)
                } else { SettingsEmpty("No Hermes agents discovered.") }
                SettingsRuntimeMaintenanceErrorView(
                    model: model,
                    runtimeKind: .hermes,
                    workspaceID: configuration.id
                )
                Button("Scan workspace") { model.remoteWorkspaces.refresh(configuration) }
                    .buttonStyle(SettingsQuietButtonStyle())
            }
            .disabled(model.remoteWorkspaces.busyWorkspaceIDs.contains(configuration.id))
        }
    }

    private func remoteRuntimeDetail(_ configuration: RemoteWorkspaceConfiguration) -> String {
        guard let runtime = model.remoteWorkspaces.runtimeMaintenance[configuration.id]?.first(where: { $0.id == .hermes }) else {
            return "Runtime inventory unavailable."
        }
        return runtime.components.map {
            "\($0.displayName) \($0.installed ? $0.installedVersion ?? "version unavailable" : "missing")"
        }.joined(separator: " · ")
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
    private var connected: Bool { model.isHermesGatewayConnected(agentID: agentID) }
    private var filtered: [HermesValue] {
        sessions.filter { !known.contains($0["id"].text) && (search.isEmpty || $0["title"].text.localizedCaseInsensitiveContains(search)) }
    }
    private var pageCount: Int { max(1, (filtered.count + 24) / 25) }

    var body: some View {
        SettingsPage(title: agent?.displayName ?? "Hermes",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if agent != nil {
                SettingsCard(title: "Gateway connection") {
                    HStack {
                        SettingsPill(connected ? "Ready" : "Not connected", tone: .neutral)
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
                SettingsCard(title: "Approvals", detail: "Applies to every conversation using this Hermes profile.") {
                    SettingsHermesProfileApprovals(model: model, agentID: agentID)
                }
                SettingsCard(title: "Woven Matter name", detail: "This name is shown only in Woven Matter.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Agent name").font(.system(size: 11, weight: .medium)).foregroundStyle(DashboardPalette.mutedForeground)
                        TextField("Agent name", text: $name).textFieldStyle(.roundedBorder)
                        Button("Save name") {
                            Task {
                                busy = true; error = nil
                                defer { busy = false }
                                do { try await model.renameHermesAgent(agentID: agentID, displayName: name) }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(DashboardPrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                SettingsCard(title: "Shared Hermes sessions", detail: "Import a session with its original working folder.") {
                    Button("Refresh sessions") { Task { await refresh() } }
                        .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 26)).disabled(!connected)
                    if loaded {
                        TextField("Search listed conversations", text: $search).textFieldStyle(.roundedBorder)
                            .onChange(of: search) { _, _ in page = 0 }
                        if filtered.isEmpty { SettingsEmpty("No sessions available to import.") }
                        ForEach(Array(filtered.dropFirst(page * 25).prefix(25)), id: \.self) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row["title"].text.isEmpty ? "Untitled Hermes session" : row["title"].text)
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
                        Text("Up to 100 recent sessions.")
                            .font(.system(size: 10))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
                SettingsCard(title: "Gateway", detail: "Finish active chats and scheduled jobs before restarting.") {
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
        guard !busy, connected else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            sessions = try await model.availableHermesSessions(agentID: agentID)
            known = []
            page = 0; loaded = true
        } catch { self.error = error.localizedDescription }
    }

    private func importSession(_ id: String) async {
        guard !busy, connected else { return }
        busy = true; error = nil
        defer { busy = false; page = min(page, pageCount - 1) }
        do {
            try await model.importHermesSession(agentID: agentID, sessionID: id)
            sessions.removeAll { $0["id"].text == id }
            known.insert(id)
        } catch { self.error = error.localizedDescription }
    }
}

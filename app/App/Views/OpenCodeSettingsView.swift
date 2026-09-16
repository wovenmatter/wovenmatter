import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct OpenCodeSettingsCard: View {
    @Environment(\.openURL) private var openURL
    @Bindable var model: OpenCodeModel
    var workspace: String
    @State private var showingModels = false
    @State private var modelSearch = ""
    @State private var loadingModels = false
    @State private var modelsError: String?
    var body: some View {
        SettingsCard(title: "Server connection") {
            SettingsValueRow(label: "Location", value: model.workspaceName)
            if let configuration = model.remoteConfiguration {
                SettingsValueRow(label: "Host", value: configuration.hostName)
            }
            HStack {
                SettingsPill(model.isConnecting ? "Connecting…" : model.isReady ? "Ready" : "Not connected", tone: model.isReady ? .neutral : .warning)
                Spacer()
                if model.isReady && !model.isRemote {
                    Button("Open in browser") {
                        model.perform { openURL(try model.browserURL()) }
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                }
                Button("Manage models") { showingModels.toggle() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(!model.isReady)
                    .popover(isPresented: $showingModels, arrowEdge: .bottom) {
                        modelPicker
                            .task {
                                loadingModels = true
                                modelsError = nil
                                defer { loadingModels = false }
                                do { try await model.refreshSettingsModels(workspace: workspace) }
                                catch { modelsError = error.localizedDescription }
                            }
                    }
                Button(model.isRemote || model.isInstalled ? "Connect" : model.isInstalling ? "Downloading…" : "Download") {
                    model.perform {
                        if model.isInstalled { try await model.connectLocal() }
                        else { try await model.download() }
                    }
                }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isConnecting || model.isReady || model.isInstalling || model.isControllingServer || (model.isRemote && !model.canConnect))
            }
            HStack(spacing: 8) {
                Button("Stop server") { model.perform { try await model.stopServer() } }
                    .disabled(model.isControllingServer || model.isConnecting || !model.hasServerRegistration)
                Button("Restart server") { model.perform { try await model.restartServer() } }
                    .disabled(model.isControllingServer || model.isConnecting || !model.isInstalled || (model.isRemote && !model.canConnect))
                if model.isControllingServer { ProgressView().controlSize(.small) }
            }
            .buttonStyle(SettingsQuietButtonStyle())
            Toggle("Start OpenCode server when Woven Matter launches", isOn: $model.startServerOnLaunch)
                .toggleStyle(DashboardSwitchToggleStyle())
            Toggle("Stop OpenCode server when Woven Matter quits", isOn: $model.stopServerOnQuit)
                .toggleStyle(DashboardSwitchToggleStyle())
            Text("Stopping the server disconnects all its clients.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.isRemote {
                OpenCodeSessionLibrary(model: model)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            if !model.canConnect {
                Text(model.isRemote ? "Install and enable OpenCode in this remote workspace’s runtime settings to connect." : "Install OpenCode v2 to connect.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var sortedPickerModels: [OpenCodeValue] {
        let matching = model.settingsModels.filter {
            modelSearch.isEmpty || ($0["name"].text + " " + OpenCodeComposerMetadata.modelKey($0)).localizedCaseInsensitiveContains(modelSearch)
        }
        // Partition without disturbing the catalog order within either group.
        return matching.filter { !model.hiddenModels.contains(OpenCodeComposerMetadata.modelKey($0)) }
            + matching.filter { model.hiddenModels.contains(OpenCodeComposerMetadata.modelKey($0)) }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Models shown in Woven Matter").font(.headline)
            TextField("Search models", text: $modelSearch)
                .textFieldStyle(.roundedBorder)
            if loadingModels { ProgressView() }
            if let modelsError { Text(modelsError).font(.caption).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(sortedPickerModels, id: \.self) { option in
                        let key = OpenCodeComposerMetadata.modelKey(option)
                        Toggle(isOn: Binding(
                            get: { !model.hiddenModels.contains(key) },
                            set: { model.setModelVisible(key, visible: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option["name"].string ?? option["id"].text)
                                Text(option["providerID"].text).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(DashboardSwitchToggleStyle())
                        .accessibilityLabel((option["name"].string ?? option["id"].text) + ", " + option["providerID"].text)
                    }
                }
                // Native switch tracks extend slightly beyond their layout frame.
                // Keep that drawing inside the scroll viewport at every edge.
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(height: 300)
            Text("Existing chats keep their selected model.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
    }

}

struct SettingsOpenCodeView: View {
    @Bindable var model: ApplicationModel
    var workspaceID: UUID?
    var isWorkspaceScoped = false
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onOpenAgent: (UUID?) -> Void

    private var remoteConfigurations: [RemoteWorkspaceConfiguration] {
        model.remoteWorkspaces.workspaces.filter { !isWorkspaceScoped || $0.id == workspaceID }
    }

    var body: some View {
        SettingsPage(title: "OpenCode",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if !isWorkspaceScoped || workspaceID == nil {
                SettingsCard(title: "Local agent workspace") {
                    if let instance = model.openCode, instance.isInstalled {
                        agentRow(instance, workspaceID: nil)
                    } else {
                        localRuntimeRow
                    }
                    SettingsRuntimeMaintenanceErrorView(
                        model: model,
                        runtimeKind: .opencode,
                        workspaceID: nil
                    )
                }
            }
            if !isWorkspaceScoped || workspaceID != nil {
                SettingsCard(title: "Remote agent workspaces") {
                    if remoteConfigurations.isEmpty { SettingsEmpty("No remote agent workspaces connected.") }
                    ForEach(remoteConfigurations) { configuration in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(configuration.name).font(.system(size: 13, weight: .medium))
                            Text(configuration.hostName).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            if let instance = model.remoteOpenCodes[configuration.id], instance.isInstalled {
                                agentRow(instance, workspaceID: configuration.id)
                            } else if let harness = model.remoteWorkspaces.currentHarnesses(for: configuration).first(where: { $0.id == .opencode }) {
                                remoteRuntimeRow(harness, configuration: configuration)
                            } else { SettingsEmpty("No OpenCode agents discovered.") }
                            SettingsRuntimeMaintenanceErrorView(
                                model: model,
                                runtimeKind: .opencode,
                                workspaceID: configuration.id
                            )
                            Button("Scan workspace") { model.remoteWorkspaces.refresh(configuration) }
                                .buttonStyle(SettingsQuietButtonStyle())
                                .disabled(model.remoteWorkspaces.busyWorkspaceIDs.contains(configuration.id))
                        }
                    }
                }
            }
        }
        .task {
            await model.synchronizeRemoteOpenCodeInstances()
            for configuration in remoteConfigurations {
                model.remoteWorkspaces.refreshWorkspaceInstance(.opencode, configuration: configuration)
            }
        }
    }

    private func agentRow(_ instance: OpenCodeModel, workspaceID: UUID?) -> some View {
        let agent = (model.localCLIAgents + model.remoteWorkspaceAgents).first {
            $0.runtimeKind == .opencode && (workspaceID == nil ? $0.governingPlane != .remoteWorkspace : $0.runtimeDeviceID == workspaceID)
        }
        return SettingsInset {
            HStack(spacing: 12) {
                DashboardHarnessLogoIcon(logo: .openCode, size: 20).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent?.displayName ?? "OpenCode").font(.system(size: 13, weight: .medium))
                    Text(instance.workspaceName).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                    Text(runtimeDetail(workspaceID: workspaceID))
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }.frame(maxWidth: .infinity, alignment: .leading)
                SettingsPill(instance.isReady ? "Ready" : "Not connected", tone: instance.isReady ? .neutral : .warning)
                updateButton(workspaceID: workspaceID)
                Button("Settings") { onOpenAgent(workspaceID) }.buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }

    private var localRuntimeRow: some View {
        SettingsInset {
            HStack(spacing: 12) {
                DashboardHarnessLogoIcon(logo: .openCode, size: 20).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenCode").font(.system(size: 13, weight: .medium))
                    Text(model.runtimeInventories[.opencode]?.summary ?? "Checking installed components…")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }.frame(maxWidth: .infinity, alignment: .leading)
                SettingsPill(localRuntimeStatus, tone: .warning)
                SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: .opencode)
            }
        }
    }

    private func remoteRuntimeRow(
        _ harness: RemoteHarnessStatus,
        configuration: RemoteWorkspaceConfiguration
    ) -> some View {
        SettingsInset {
            HStack(spacing: 12) {
                DashboardHarnessLogoIcon(logo: .openCode, size: 20).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(harness.displayName).font(.system(size: 13, weight: .medium))
                    Text(runtimeDetail(workspaceID: configuration.id))
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }.frame(maxWidth: .infinity, alignment: .leading)
                SettingsPill(remoteRuntimeInstalled(configuration.id) ? "Not connected" : "Not installed", tone: .warning)
                SettingsRemoteRuntimeUpdateButton(
                    model: model.remoteWorkspaces,
                    harness: harness,
                    configuration: configuration
                )
            }
        }
    }

    @ViewBuilder
    private func updateButton(workspaceID: UUID?) -> some View {
        if let workspaceID,
           let configuration = model.remoteWorkspaces.configuration(id: workspaceID),
           let harness = model.remoteWorkspaces.currentHarnesses(for: configuration).first(where: { $0.id == .opencode }) {
            SettingsRemoteRuntimeUpdateButton(
                model: model.remoteWorkspaces,
                harness: harness,
                configuration: configuration
            )
        } else if workspaceID == nil {
            SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: .opencode)
        }
    }

    private func runtimeDetail(workspaceID: UUID?) -> String {
        guard let workspaceID else {
            return model.runtimeInventories[.opencode]?.summary ?? "Checking installed components…"
        }
        guard let runtime = model.remoteWorkspaces.runtimeMaintenance[workspaceID]?.first(where: { $0.id == .opencode }) else {
            return "Runtime inventory unavailable."
        }
        return runtime.components.map {
            "\($0.displayName) \($0.installed ? $0.installedVersion ?? "version unavailable" : "missing")"
        }.joined(separator: " · ")
    }

    private var localRuntimeStatus: String {
        guard let inventory = model.runtimeInventories[.opencode] else { return "Checking" }
        return inventory.isInstalled ? "Not connected" : "Not installed"
    }

    private func remoteRuntimeInstalled(_ workspaceID: UUID) -> Bool {
        model.remoteWorkspaces.runtimeMaintenance[workspaceID]?.first(where: { $0.id == .opencode })?.installed == true
    }
}

struct SettingsOpenCodeAgentView: View {
    @Bindable var model: ApplicationModel
    let workspaceID: UUID?
    var reservesRailControlSpace = false
    var onBack: () -> Void
    @State private var agentID: UUID?
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    private var instance: OpenCodeModel? { workspaceID.flatMap { model.remoteOpenCodes[$0] } ?? (workspaceID == nil ? model.openCode : nil) }
    private var workspace: String {
        if let configuration = instance?.remoteConfiguration { return model.remoteWorkspaces.remoteWorkspaceRoot(for: configuration) }
        return model.localACPWorkspaceAvailability.rootPath ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".woven-matter").path
    }
    var body: some View {
        SettingsPage(title: name.isEmpty ? "OpenCode" : name,
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if let instance {
                SettingsCard(title: "Woven Matter name", detail: "This name is shown only in Woven Matter.") {
                    Text("Agent name").font(.system(size: 11, weight: .medium)).foregroundStyle(DashboardPalette.mutedForeground)
                    TextField("Agent name", text: $name).textFieldStyle(.roundedBorder)
                    Button("Save name") {
                        guard let agentID else { return }
                        Task {
                            saving = true; error = nil
                            defer { saving = false }
                            do { try await model.renameOpenCodeAgent(agentID: agentID, displayName: name) }
                            catch { self.error = error.localizedDescription }
                        }
                    }.buttonStyle(DashboardPrimaryButtonStyle())
                        .disabled(agentID == nil || saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                OpenCodeSettingsCard(model: instance, workspace: workspace)
            } else { SettingsEmpty("This agent is no longer available.") }
            if let error { SettingsError(error) }
        }
        .task(id: workspaceID) {
            do {
                let agent = try await model.openCodeSettingsAgent(workspaceID: workspaceID)
                agentID = agent.id; name = agent.displayName
            } catch { self.error = error.localizedDescription }
        }
    }
}


private struct OpenCodeSessionLibrary: View {
    @Bindable var model: OpenCodeModel
    @State private var sessions: [OpenCodeValue] = []
    @State private var cursors: [String?] = [nil]
    @State private var page = 0
    @State private var next: String?
    @State private var busy = false
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared OpenCode sessions").font(.headline)
            HStack {
                Button("Refresh sessions") { load(page: 0) }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 26))
                if busy { ProgressView().controlSize(.small) }
            }
            ForEach(sessions, id: \.self) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session["title"].string ?? "OpenCode session").font(.system(size: 13, weight: .medium))
                        Text(session["location"]["directory"].text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DashboardPalette.mutedForeground).lineLimit(2)
                    }
                    Spacer()
                    Button("Import") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                try await model.importSession(session)
                                sessions.removeAll { $0["id"] == session["id"] }
                                feedback = "Added to chats."
                            } catch { feedback = error.localizedDescription }
                        }
                    }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
                }
            }
            HStack {
                Button("Previous") { load(page: page - 1) }.disabled(page == 0)
                Text("Page \(page + 1) of up to 10").font(.caption)
                Button("Next") {
                    if let next {
                        cursors = Array(cursors.prefix(page + 1)) + [next]
                        load(page: page + 1)
                    }
                }.disabled(next == nil || page >= 9)
            }
            .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
            if let feedback { Text(feedback).font(.system(size: 12)).textSelection(.enabled) }
        }
        .disabled(busy || !model.isReady)
    }

    private func load(page index: Int) {
        guard cursors.indices.contains(index) else { return }
        busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                let result = try await model.importableSessions(cursor: cursors[index])
                if index == 0 { cursors = [nil] }
                sessions = result.sessions
                page = index
                next = result.next
                if sessions.isEmpty { feedback = "No sessions available to import." }
            } catch { feedback = error.localizedDescription }
        }
    }
}

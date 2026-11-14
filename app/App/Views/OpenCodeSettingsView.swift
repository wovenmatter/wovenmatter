import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct OpenCodeSettingsSection: View {
    @Environment(\.openURL) private var openURL
    @Bindable var model: OpenCodeModel
    var workspace: String
    @State private var showingModels = false
    @State private var modelSearch = ""
    @State private var loadingModels = false
    @State private var modelsError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsRow(title: model.workspaceName, detail: model.remoteConfiguration?.hostName) {
                SettingsStatus(model.isConnecting ? "Connecting…" : model.isReady ? "Ready" : "Not connected", tone: model.isReady ? .good : .warning)
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
                Button("Manage models") { showingModels.toggle() }
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
                if model.isReady && !model.isRemote {
                    Button("Open in browser") {
                        model.perform { openURL(try await model.browserURL()) }
                    }
                }
                Button("Restart server") { model.perform { try await model.restartServer() } }
                    .disabled(model.isControllingServer || model.isConnecting || !model.isInstalled || (model.isRemote && !model.canConnect))
                Button("Stop server") { model.perform { try await model.stopServer() } }
                    .disabled(model.isControllingServer || model.isConnecting || !model.hasServerRegistration)
                if model.isControllingServer { ProgressView().controlSize(.small) }
            }
            .buttonStyle(SettingsQuietButtonStyle())
            SettingsSummaryRow("Server lifecycle", value: lifecycleSummary) {
                Toggle("Start when Woven Matter launches", isOn: $model.startServerOnLaunch)
                Toggle("Stop when Woven Matter quits", isOn: $model.stopServerOnQuit)
                SettingsNote("Stopping the server disconnects all its clients.")
            }
            if !model.isRemote {
                SettingsSummaryRow("Shared sessions") { OpenCodeSessionLibrary(model: model) }
            }
            if let error = model.error { SettingsError(error) }
            if !model.canConnect {
                SettingsNote(model.isRemote ? "Install OpenCode in this remote workspace to connect." : "Install OpenCode v2 to connect.")
            }
        }
    }

    private var lifecycleSummary: String {
        switch (model.startServerOnLaunch, model.stopServerOnQuit) {
        case (true, true): "Follows Woven Matter"
        case (true, false): "Starts with Woven Matter"
        case (false, true): "Stops with Woven Matter"
        case (false, false): "Manual"
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
            Text("Models shown in Woven Matter").font(.settingsSection)
            TextField("Search models", text: $modelSearch)
                .quietTextInput()
            if loadingModels { ProgressView() }
            if let modelsError { Text(modelsError).font(.settingsSecondary).foregroundStyle(WovenPalette.danger) }
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
                                Text(option["providerID"].text).font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityLabel((option["name"].string ?? option["id"].text) + ", " + option["providerID"].text)
                    }
                }
                // Native switch tracks extend slightly beyond their layout frame.
                // Keep that drawing inside the scroll viewport at every edge.
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .frame(height: 300)
            Text("Existing chats keep their selected model.")
                .font(.settingsSecondary).foregroundStyle(WovenPalette.mutedForeground)
        }
        .padding(16)
        .frame(width: 360)
    }

}

/// Each installed OpenCode service in the selected scope, on the agent page itself.
struct SettingsOpenCodeInstances: View {
    @Bindable var model: ApplicationModel
    let scope: String

    private var remotes: [RemoteWorkspaceConfiguration] {
        model.remoteWorkspaces.workspaces.filter {
            (scope == "global" || $0.id.uuidString.lowercased() == scope)
                && model.remoteOpenCodes[$0.id]?.isInstalled == true
        }
    }
    private var showsLocal: Bool {
        (scope == "global" || scope == "local") && model.openCode?.isInstalled == true
    }

    var body: some View {
        SettingsSection(title: "OpenCode service") {
            if !showsLocal && remotes.isEmpty {
                SettingsEmpty("Install OpenCode to manage its service.")
            }
            if showsLocal {
                SettingsSummaryRow("Local workspace", value: statusLabel(model.openCode)) {
                    OpenCodeInstanceSettings(model: model, workspaceID: nil)
                }
            }
            ForEach(remotes) { workspace in
                SettingsSummaryRow(workspace.name, value: statusLabel(model.remoteOpenCodes[workspace.id])) {
                    OpenCodeInstanceSettings(model: model, workspaceID: workspace.id)
                }
            }
        }
        .task { await model.synchronizeRemoteOpenCodeInstances() }
    }

    private func statusLabel(_ instance: OpenCodeModel?) -> String {
        instance?.isReady == true ? "Ready" : "Not connected"
    }
}

private struct OpenCodeInstanceSettings: View {
    @Bindable var model: ApplicationModel
    let workspaceID: UUID?
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
        VStack(alignment: .leading, spacing: 6) {
            if let instance {
                SettingsRow(title: "Name in Woven Matter") {
                    TextField("Agent name", text: $name)
                        .wovenInput()
                        .frame(width: 220)
                    Button("Save") {
                        guard let agentID else { return }
                        Task {
                            saving = true; error = nil
                            defer { saving = false }
                            do { try await model.renameOpenCodeAgent(agentID: agentID, displayName: name) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(agentID == nil || saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                OpenCodeSettingsSection(model: instance, workspace: workspace)
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
            HStack {
                Button("Refresh sessions") { load(page: 0) }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 26))
                if busy { ProgressView().controlSize(.small) }
            }
            ForEach(sessions, id: \.self) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session["title"].string ?? "OpenCode session").font(.settingsRow)
                        Text(session["location"]["directory"].text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(WovenPalette.mutedForeground).lineLimit(2)
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
                Text("Page \(page + 1) of up to 10").font(.settingsSecondary)
                Button("Next") {
                    if let next {
                        cursors = Array(cursors.prefix(page + 1)) + [next]
                        load(page: page + 1)
                    }
                }.disabled(next == nil || page >= 9)
            }
            .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
            if let feedback { Text(feedback).font(.settingsBody).textSelection(.enabled) }
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

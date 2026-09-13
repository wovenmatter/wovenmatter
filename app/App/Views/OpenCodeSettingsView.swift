import SwiftUI
import WovenMatterClient

struct OpenCodeSettingsCard: View {
    @Environment(\.openURL) private var openURL
    @Bindable var model: OpenCodeModel
    var workspace: String
    @State private var showingModels = false
    @State private var modelSearch = ""
    @State private var loadingModels = false
    @State private var modelsError: String?
    var body: some View {
        SettingsCard(title: model.workspaceName, detail: model.isRemote
            ? "OpenCode v2 through this remote workspace’s authenticated SSH connection."
            : "OpenCode v2 on this Mac. New chats use your Woven Matter workspace.") {
            if let configuration = model.remoteConfiguration {
                SettingsValueRow(label: "Host", value: configuration.hostName)
                SettingsNote("Authenticated workspace service over SSH, port \(configuration.remotePort). Connection settings belong to this remote workspace.")
            }
            HStack {
                SettingsPill(model.isConnecting ? "Connecting…" : model.isReady ? "Connected" : "Not connected", tone: model.isReady ? .neutral : .warning)
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
            Toggle("Start OpenCode server when WovenMatter launches", isOn: $model.startServerOnLaunch)
                .toggleStyle(DashboardSwitchToggleStyle())
            Toggle("Stop OpenCode server when WovenMatter quits", isOn: $model.stopServerOnQuit)
                .toggleStyle(DashboardSwitchToggleStyle())
            Text("Stopping the server also disconnects the browser and other OpenCode clients.")
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
            Text("Saved automatically. Existing chats keep their selected model.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
    }

}

struct SettingsOpenCodeView: View {
    @Bindable var model: ApplicationModel
    /// nil scope shows all eligible workspaces; a scoped nil ID means this Mac.
    var workspaceID: UUID?
    var isWorkspaceScoped = false
    var reservesRailControlSpace = false
    var onBack: () -> Void

    private var remoteConfigurations: [RemoteWorkspaceConfiguration] {
        if isWorkspaceScoped {
            return model.remoteWorkspaces.workspaces.filter { $0.id == workspaceID }
        }
        return model.remoteWorkspaces.enabledRuntimeWorkspaces(.opencode)
    }

    var body: some View {
        SettingsPage(title: "OpenCode",
            detail: "Independent OpenCode v2 connections for each workspace.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if !isWorkspaceScoped || workspaceID == nil, let openCode = model.openCode {
                OpenCodeSettingsCard(model: openCode, workspace: model.localACPWorkspaceAvailability.rootPath
                    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".woven-matter").path)
            }
            ForEach(remoteConfigurations) { configuration in
                if let instance = model.remoteOpenCodes[configuration.id] {
                    OpenCodeSettingsCard(model: instance,
                        workspace: model.remoteWorkspaces.remoteWorkspaceRoot(for: configuration))
                } else {
                    SettingsNote("Preparing the OpenCode connection for \(configuration.name)…")
                }
            }
        }
        .task {
            await model.synchronizeRemoteOpenCodeInstances()
            // A disabled runtime may still own a running server. Its workspace
            // status keeps Stop available without reconnecting or enabling it.
            for configuration in remoteConfigurations {
                model.remoteWorkspaces.refreshWorkspaceInstance(.opencode, configuration: configuration)
            }
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
                Button("Refresh sessions") { cursors = [nil]; load(page: 0) }
                    .buttonStyle(SettingsQuietButtonStyle(horizontalPadding: 8, minimumHeight: 22))
                if busy { ProgressView().controlSize(.small) }
            }
            ForEach(sessions, id: \.self) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session["title"].string ?? "OpenCode conversation").font(.system(size: 13, weight: .medium))
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
                                feedback = "Imported into the conversation list."
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
                sessions = result.sessions
                page = index
                next = result.next
                if sessions.isEmpty { feedback = "No sessions available to import." }
            } catch { feedback = error.localizedDescription }
        }
    }
}

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
        SettingsCard(title: "OpenCode", detail: "Uses the local OpenCode v2 service. New chats use your Woven Matter workspace.") {
            HStack {
                SettingsPill(model.isConnecting ? "Connecting…" : model.isReady ? "Connected" : "Not connected", tone: model.isReady ? .neutral : .warning)
                Spacer()
                if model.isReady {
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
                Button(model.isInstalled ? "Connect" : model.isInstalling ? "Downloading…" : "Download") {
                    model.perform {
                        if model.isInstalled { try await model.connectLocal() }
                        else { try await model.download() }
                    }
                }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isConnecting || model.isReady || model.isInstalling || model.isControllingServer)
            }
            HStack(spacing: 8) {
                Button("Stop server") { model.perform { try await model.stopServer() } }
                    .disabled(model.isControllingServer || model.isConnecting || !model.hasServerRegistration)
                Button("Restart server") { model.perform { try await model.restartServer() } }
                    .disabled(model.isControllingServer || model.isConnecting || !model.isInstalled)
                if model.isControllingServer { ProgressView().controlSize(.small) }
            }
            .buttonStyle(SettingsQuietButtonStyle())
            Toggle("Start OpenCode server when WovenMatter launches", isOn: $model.startServerOnLaunch)
                .toggleStyle(DashboardSwitchToggleStyle())
            Toggle("Stop OpenCode server when WovenMatter quits", isOn: $model.stopServerOnQuit)
                .toggleStyle(DashboardSwitchToggleStyle())
            Text("Stopping the server also disconnects the browser and other OpenCode clients.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.red) }
            if !model.canConnect {
                Text("Install OpenCode v2 to connect.").font(.caption).foregroundStyle(.secondary)
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
    var reservesRailControlSpace = false
    var onBack: () -> Void

    var body: some View {
        SettingsPage(title: "OpenCode",
            detail: "The local OpenCode v2 service and its connection on this Mac.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            if let openCode = model.openCode { OpenCodeSettingsCard(model: openCode, workspace: model.localACPWorkspaceAvailability.rootPath ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".woven-matter").path) }
        }
    }
}

import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct DashboardCalendarTaskFields: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    @Binding var task: WorkspaceCalendarTask
    let recurring: Bool
    @State private var metadata: LocalACPSessionMetadata?
    @State private var loading = false
    @State private var refreshID = 0
    @State private var error: String?

    private var catalogKey: String {
        [task.configuration.runtimeKind.rawValue, task.configuration.workspaceID?.uuidString ?? "local",
         task.configuration.nativeWorkingDirectory ?? "", task.configuration.model ?? ""].joined(separator: "|")
    }
    private func choice(_ key: WritableKeyPath<WorkspaceSessionCreationConfiguration, String?>) -> Binding<String> {
        Binding(get: { task.configuration[keyPath: key] ?? "" }, set: { value in
            task.configuration[keyPath: key] = value.isEmpty ? nil : value
            if key == \.model { task.configuration.thinking = nil }
            if key == \.nativeWorkingDirectory {
                task.configuration.nativeWorkspaceID = nil
                task.configuration.selectionWorkspace = task.configuration.workspaceID.map { "remote:" + $0.uuidString.lowercased() }
                    ?? "local:" + URL(fileURLWithPath: value).standardizedFileURL.path
            }
        })
    }
    private var workspace: Binding<String> {
        Binding(get: { task.configuration.workspaceID?.uuidString ?? "local" }, set: { raw in
            changeAgent(task.configuration.runtimeKind, workspaceID: raw == "local" ? nil : UUID(uuidString: raw))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session").font(.system(size: 14, weight: .semibold))
            Picker("Work location", selection: workspace) {
                Text("Local workspace").tag("local")
                if let id = task.configuration.workspaceID, model.remoteWorkspaces.configuration(id: id) == nil {
                    Text("Unavailable workspace").tag(id.uuidString)
                }
                ForEach(model.remoteWorkspaces.workspaces) { configuration in
                    Text(configuration.name).tag(configuration.id.uuidString)
                }
            }
            Picker("Agent", selection: Binding(get: { task.configuration.runtimeKind }, set: {
                changeAgent($0, workspaceID: task.configuration.workspaceID)
            })) {
                ForEach(AgentRuntimeKind.presentationOrder, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Session folder", selection: choice(\.folderID)) {
                Text("All Workspace").tag("")
                if let id = task.configuration.folderID, model.workspaceOverview?.folders.contains(where: { $0.id == id }) != true {
                    Text("Unavailable folder").tag(id)
                }
                ForEach(model.workspaceOverview?.folders ?? []) { Text($0.name).tag($0.id) }
            }
            TextField("Working directory", text: choice(\.nativeWorkingDirectory))
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("Session settings").font(.system(size: 12, weight: .medium))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { refreshID += 1 }.buttonStyle(DashboardQuietButtonStyle()).disabled(loading)
            }
            optionPicker("Model", selection: choice(\.model), choices: metadata?.selectableModels ?? [], metadata: metadata?.modelOptionMetadata ?? [:])
            optionPicker("Thinking", selection: choice(\.thinking), choices: metadata?.selectableThinkingLevels ?? [], metadata: metadata?.thinkingOptionMetadata ?? [:])
            if task.configuration.runtimeKind != .pi {
                optionPicker("Access", selection: choice(\.permission), choices: metadata?.permissionOptions ?? [], metadata: metadata?.permissionOptionMetadata ?? [:])
            }
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.danger).fixedSize(horizontal: false, vertical: true) }
            DisclosureGroup("Tools") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(WorkspaceToolGroup.allCases) { group in
                        Toggle(group.title, isOn: Binding(get: { task.configuration.tools.enabled.contains(group) }, set: {
                            if $0 { task.configuration.tools.enabled.insert(group) } else { task.configuration.tools.enabled.remove(group) }
                        })).toggleStyle(DashboardSwitchToggleStyle())
                    }
                }.padding(.top, 8)
            }
            if recurring {
                Picker("Send each occurrence to", selection: $task.sessionMode) {
                    ForEach(WorkspaceCalendarTask.SessionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Text("Prompt").font(.system(size: 12, weight: .medium))
            TextEditor(text: $task.prompt).font(.system(size: 13)).scrollIndicators(.never)
                .frame(minHeight: 110, maxHeight: 180).padding(6)
                .overlay { RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius).stroke(theme.palette.border) }
                .accessibilityLabel("Scheduled task prompt")
        }
        .font(.system(size: 12.5))
        .task(id: catalogKey + "|" + String(refreshID)) { await loadMetadata() }
    }

    private func optionPicker(_ title: String, selection: Binding<String>, choices: [String], metadata: [String: SessionOptionMetadata]) -> some View {
        Picker(title, selection: selection) {
            Text("Agent default").tag("")
            if !selection.wrappedValue.isEmpty && !choices.contains(selection.wrappedValue) {
                Text(selection.wrappedValue).tag(selection.wrappedValue)
            }
            ForEach(choices, id: \.self) { Text(metadata[$0]?.name ?? $0).tag($0) }
        }.disabled(loading)
    }

    private func changeAgent(_ runtime: AgentRuntimeKind, workspaceID: UUID?) {
        let current = task
        task = model.calendarTaskDefaults(runtime: runtime, workspaceID: workspaceID, title: current.configuration.title)
        task.prompt = current.prompt; task.sessionMode = current.sessionMode
        task.configuration.folderID = current.configuration.folderID
        metadata = nil; error = nil
    }

    private func loadMetadata() async {
        let key = catalogKey
        loading = true; error = nil; metadata = nil
        defer { if !Task.isCancelled, key == catalogKey { loading = false } }
        do {
            try await Task.sleep(for: .milliseconds(400))
            let value = try await model.calendarTaskMetadata(task)
            guard !Task.isCancelled, key == catalogKey else { return }
            metadata = value
        } catch is CancellationError { }
        catch { if !Task.isCancelled, key == catalogKey { self.error = error.localizedDescription } }
    }
}

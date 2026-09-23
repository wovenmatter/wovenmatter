import SwiftUI
import WovenMatterCore
import WovenMatterClient

struct DashboardCalendarTaskFields: View {
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
        VStack(alignment: .leading, spacing: 18) {
            Text("Session").font(.system(size: 14, weight: .semibold))
            DashboardCalendarField("Work location") {
                DashboardCalendarMenuPicker(title: "Work location", selection: workspace, options: workspaceOptions) { id in
                    id == "local" ? "Local workspace" : model.remoteWorkspaces.workspaces.first { $0.id.uuidString == id }?.name ?? "Unavailable workspace"
                }
            }
            DashboardCalendarField("Agent") {
                DashboardCalendarMenuPicker(title: "Agent", selection: Binding(get: { task.configuration.runtimeKind }, set: {
                    changeAgent($0, workspaceID: task.configuration.workspaceID)
                }), options: AgentRuntimeKind.presentationOrder, label: { $0.displayName })
            }
            DashboardCalendarField("Session folder") {
                DashboardCalendarMenuPicker(title: "Session folder", selection: choice(\.folderID), options: folderOptions) { id in
                    id.isEmpty ? "All Workspace" : model.workspaceOverview?.folders.first { $0.id == id }?.name ?? "Unavailable folder"
                }
            }
            DashboardCalendarField("Working directory") {
                TextField("Working directory", text: choice(\.nativeWorkingDirectory))
                    .modifier(DashboardCalendarInputStyle())
            }
            HStack {
                Text("Session settings").font(.system(size: 12, weight: .medium))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { refreshID += 1 }.buttonStyle(DashboardQuietButtonStyle()).disabled(loading)
            }
            optionPicker("Model", selection: choice(\.model), choices: metadata?.selectableModels ?? [], metadata: metadata?.modelOptionMetadata ?? [:])
            optionPicker("Thinking level", selection: choice(\.thinking), choices: metadata?.selectableThinkingLevels ?? [], metadata: metadata?.thinkingOptionMetadata ?? [:])
            if task.configuration.runtimeKind != .pi {
                optionPicker("Access", selection: choice(\.permission), choices: metadata?.permissionOptions ?? [], metadata: metadata?.permissionOptionMetadata ?? [:])
            }
            if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(DashboardPalette.danger).fixedSize(horizontal: false, vertical: true) }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(WorkspaceToolGroup.allCases) { group in
                        Toggle(group.title, isOn: Binding(get: { task.configuration.tools.enabled.contains(group) }, set: {
                            if $0 { task.configuration.tools.enabled.insert(group) } else { task.configuration.tools.enabled.remove(group) }
                        })).toggleStyle(DashboardSwitchToggleStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            } label: {
                Text("Tools").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            if recurring {
                DashboardCalendarField("Send each occurrence to") {
                    DashboardCalendarMenuPicker(title: "Send each occurrence to", selection: $task.sessionMode,
                        options: WorkspaceCalendarTask.SessionMode.allCases, label: { $0.title })
                }
            }
            DashboardCalendarField("Prompt") {
                TextEditor(text: $task.prompt)
                    .scrollContentBackground(.hidden).scrollIndicators(.never)
                    .frame(height: 120)
                    .modifier(DashboardCalendarInputStyle())
                    .accessibilityLabel("Scheduled task prompt")
            }
        }
        .font(.system(size: 12.5))
        .task(id: catalogKey + "|" + String(refreshID)) { await loadMetadata() }
    }

    private var workspaceOptions: [String] {
        var options = ["local"] + model.remoteWorkspaces.workspaces.map { $0.id.uuidString }
        if !options.contains(workspace.wrappedValue) { options.append(workspace.wrappedValue) }
        return options
    }

    private var folderOptions: [String] {
        var options = [""] + (model.workspaceOverview?.folders.map(\.id) ?? [])
        if let id = task.configuration.folderID, !options.contains(id) { options.append(id) }
        return options
    }

    private func optionPicker(_ title: String, selection: Binding<String>, choices: [String], metadata: [String: SessionOptionMetadata]) -> some View {
        let options = [""] + choices + (selection.wrappedValue.isEmpty || choices.contains(selection.wrappedValue) ? [] : [selection.wrappedValue])
        return DashboardCalendarField(title) {
            DashboardCalendarMenuPicker(title: title, selection: selection, options: options) {
                $0.isEmpty ? "Agent default" : metadata[$0]?.name ?? $0
            }
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

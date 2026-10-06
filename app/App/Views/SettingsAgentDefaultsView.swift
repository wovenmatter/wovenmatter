import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Defaults are edited in Settings and captured once when a conversation is
/// created. Options come from the selected harness and execution workspace.
struct SettingsAgentDefaultsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @State private var runtime = AgentRuntimeKind.defaultAgent
    @State private var scope = "global"
    @State private var stored = SessionSelections()
    @State private var resolved = SessionSelections()
    @State private var metadata: LocalACPSessionMetadata?
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var requestID = UUID()

    private var workspaceID: UUID? { UUID(uuidString: scope) }
    private var workspaceScope: String? {
        if scope == "global" { return nil }
        if let workspaceID { return "remote:" + workspaceID.uuidString.lowercased() }
        return model.localACPWorkspaceLaunchConfiguration.map { "local:" + $0.rootURL.standardizedFileURL.path }
    }
    private var scopeAvailable: Bool { scope != "local" || workspaceScope != nil }
    private var identity: String { runtime.rawValue + ":" + scope + ":" + (workspaceScope ?? "") }
    private var inheritedLabel: String { scope == "global" ? "Use agent default" : "Use All workspaces" }
    private var enabledTools: Set<String> {
        Set(resolved.tools ?? model.agentTools?.settings.enabledByDefault.map(\.rawValue) ?? [])
    }

    var body: some View {
        SettingsPage(title: "Agent defaults",
            detail: "Each new conversation uses these settings. Conversation changes stay in that conversation.",
            reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Agent", selection: $runtime) {
                    ForEach(AgentRuntimeKind.presentationOrder, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Settings for", selection: $scope) {
                    Text("All workspaces").tag("global")
                    Text("Local agent workspace").tag("local")
                    ForEach(model.remoteWorkspaces.workspaces) { Text($0.name).tag($0.id.uuidString.lowercased()) }
                }
                SettingsNote(scope == "global"
                    ? "Native options are read from the local agent workspace. Workspace overrides can use the options available on that host."
                    : "These choices override this agent’s All workspaces defaults.")
            }.frame(maxWidth: 440, alignment: .leading)
            SettingsCard(title: "Conversation defaults") {
                VStack(alignment: .leading, spacing: 14) {
                    selectionRow("Permissions", field: .permission, value: stored.permission,
                        effective: resolved.permission, options: metadata?.permissionOptions ?? [],
                        labels: metadata?.permissionOptionMetadata ?? [:])
                    selectionRow("Model", field: .model, value: stored.model,
                        effective: resolved.model, options: metadata?.selectableModels ?? [],
                        labels: metadata?.modelOptionMetadata ?? [:])
                    selectionRow("Thinking level", field: .thinking, value: stored.thinking,
                        effective: resolved.thinking, options: metadata?.selectableThinkingLevels ?? [],
                        labels: metadata?.thinkingOptionMetadata ?? [:])
                    HStack(spacing: 10) {
                        Button(loading ? "Reading native options…" : "Refresh native options") { Task { await loadOptions() } }
                            .buttonStyle(SettingsQuietButtonStyle()).disabled(loading || saving || !scopeAvailable)
                        if loading { ProgressView().controlSize(.small) }
                    }
                    if metadata != nil, metadata?.permissionOptions?.isEmpty != false {
                        SettingsNote("This agent does not expose a selectable permission policy.")
                    }
                    if metadata != nil, metadata?.selectableThinkingLevels.isEmpty != false {
                        SettingsNote("The selected model does not expose a thinking level control.")
                    }
                }
            }.disabled(!scopeAvailable)
            SettingsCard(title: "Woven tools", detail: "Choose tools for this agent’s new conversations. Inherited tools come from All workspaces or General.") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Choose tools for this agent", isOn: Binding(get: { stored.tools != nil }, set: { enabled in
                        save(.tools, selections: SessionSelections(tools: enabled ? enabledTools.sorted() : nil))
                    }))
                    if stored.tools != nil {
                        ForEach(WorkspaceToolGroup.allCases) { group in
                            Toggle(group.title, isOn: Binding(get: { enabledTools.contains(group.rawValue) }, set: { enabled in
                                var tools = enabledTools
                                if enabled { tools.insert(group.rawValue) } else { tools.remove(group.rawValue) }
                                save(.tools, selections: SessionSelections(tools: tools.sorted()))
                            }))
                        }
                    }
                    SettingsNote("Calendar access, session limits, and connected app selections retain their shared settings.")
                }
            }.disabled(!scopeAvailable)
            if let error { SettingsError(error) }
        }
        .disabled(saving)
        .task(id: identity) { await loadDefaults() }
        .onDisappear { requestID = UUID() }
    }

    private func selectionRow(_ title: String, field: SessionSelectionField, value: String?, effective: String?,
        options: [String], labels: [String: SessionOptionMetadata]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 8)
                Picker(title, selection: Binding(get: { value ?? "" }, set: { choice in
                    var selection = SessionSelections()
                    switch field {
                    case .model: selection.model = choice.isEmpty ? nil : choice
                    case .thinking: selection.thinking = choice.isEmpty ? nil : choice
                    case .permission: selection.permission = choice.isEmpty ? nil : choice
                    case .tools: break
                    }
                    save(field, selections: selection)
                })) {
                    Text(inheritedLabel).tag("")
                    if let value, !options.contains(value) {
                        Text(selectionLabel(value, field: field, labels: labels)).tag(value)
                    }
                    ForEach(options, id: \.self) { Text(selectionLabel($0, field: field, labels: labels)).tag($0) }
                }.labelsHidden().frame(maxWidth: 280)
            }
            if let effective {
                SettingsNote(value == nil ? "Current default: \(selectionLabel(effective, field: field, labels: labels))" : labels[effective]?.description ?? "")
            }
        }
    }

    private func selectionLabel(_ value: String, field: SessionSelectionField,
        labels: [String: SessionOptionMetadata]) -> String {
        if let nativeLabel = labels[value]?.name { return nativeLabel }
        guard field == .permission else { return value }
        // Known defaults can be named before discovery. The native catalog
        // still controls selectable options and takes precedence once loaded.
        return value == SessionSelectionPreferences.productDefaults(harness: runtime.rawValue).permission
            ? "Full Access" : value
    }

    @MainActor private func loadDefaults() async {
        requestID = UUID()
        let request = requestID
        metadata = nil; error = nil; loading = false
        stored = SessionSelections(); resolved = SessionSelections()
        guard scopeAvailable else {
            error = "The local agent workspace is unavailable. Connect it before editing its defaults."
            return
        }
        do {
            let defaults = try await model.agentSelectionDefaults(runtime: runtime, workspace: workspaceScope)
            guard requestID == request, !Task.isCancelled else { return }
            stored = defaults.stored; resolved = defaults.resolved
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    @MainActor private func loadOptions() async {
        guard scopeAvailable else { return }
        let request = UUID()
        requestID = request; loading = true; error = nil; metadata = nil
        let selectedRuntime = runtime, selectedWorkspace = workspaceID
        var task = model.calendarTaskDefaults(runtime: selectedRuntime, workspaceID: selectedWorkspace)
        task.configuration.model = resolved.model
        defer { if requestID == request { loading = false } }
        do {
            let result = try await model.calendarTaskMetadata(task)
            guard requestID == request, !Task.isCancelled else { return }
            metadata = result
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func save(_ field: SessionSelectionField, selections: SessionSelections) {
        guard scopeAvailable else { return }
        let request = UUID(), selectedIdentity = identity
        requestID = request; loading = false
        let selectedRuntime = runtime, selectedWorkspace = workspaceScope
        saving = true; error = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                let defaults = try await model.saveAgentSelectionDefault(runtime: selectedRuntime,
                    workspace: selectedWorkspace, field: field, selections: selections)
                guard identity == selectedIdentity, requestID == request else { return }
                stored = defaults.stored; resolved = defaults.resolved
                if field == .model {
                    // Read the selected model's actual catalog after the backend
                    // clears the previous model's explicit thinking default.
                    await loadOptions()
                }
            } catch {
                guard identity == selectedIdentity, requestID == request else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

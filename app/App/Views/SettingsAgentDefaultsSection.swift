import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Defaults are edited in Settings and captured once when a conversation is
/// created. Options come from the selected harness and execution workspace.
struct SettingsAgentDefaultsSection: View {
    @Bindable var model: ApplicationModel
    let runtime: AgentRuntimeKind
    let scope: String
    var showsModel = true
    /// Native harness pages manage their own sharing; Pi Durable's shares its page's control.
    var managesSharing = false
    @State private var usesShared = true
    @State private var defaultsReady = false
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
        if let workspaceID { return ApplicationModel.remoteDatabaseSourceID(workspaceID) }
        return model.localACPWorkspaceLaunchConfiguration.map { "local:" + $0.rootURL.standardizedFileURL.path }
    }
    private var scopeAvailable: Bool { scope != "local" || workspaceScope != nil }
    private var identity: String { runtime.rawValue + ":" + scope + ":" + (workspaceScope ?? "") }
    private var inheritedLabel: String { scope == "global" || (managesSharing && !usesShared) ? "Use agent default" : "Use shared settings" }
    private var inheritsDefaults: Bool {
        scope != "global" && (managesSharing ? usesShared : runtime == .defaultAgent && model.connections.inherits)
    }
    private var enabledTools: Set<String> {
        Set(resolved.tools ?? model.agentTools?.settings.enabledByDefault.map(\.rawValue) ?? WorkspaceToolSettings().enabledByDefault.map(\.rawValue))
    }
    private var toolsEnabled: Bool { !enabledTools.subtracting(["goals"]).isEmpty }
    private var toolsSummary: String {
        let groups = WorkspaceToolGroup.configurableCases
        let count = groups.filter { enabledTools.contains($0.rawValue) }.count
        return count == 0 ? "Off" : "\(count) of \(groups.count) tools"
    }

    var body: some View {
        SettingsSection(title: "Defaults for new chats", detail: "You can change these in each chat.") {
            if managesSharing && scope != "global" {
                SettingsToggleRow(
                    title: "Use shared chat settings",
                    detail: usesShared
                        ? "Models, thinking, permissions, and tool defaults follow All workspaces."
                        : "Defaults apply only to this workspace.",
                    isOn: Binding(get: { usesShared }, set: { setSharing($0) })
                )
                .disabled(saving || !defaultsReady)
            }
            Group {
                selectionRow("Permissions", field: .permission, value: stored.permission,
                    effective: resolved.permission, options: metadata?.permissionOptions ?? [],
                    labels: metadata?.permissionOptionMetadata ?? [:])
                if showsModel { selectionRow("Model", field: .model, value: stored.model,
                    effective: resolved.model, options: metadata?.selectableModels ?? [],
                    labels: metadata?.modelOptionMetadata ?? [:]) }
                selectionRow("Thinking level", field: .thinking, value: stored.thinking,
                    effective: resolved.thinking, options: metadata?.selectableThinkingLevels ?? [],
                    labels: metadata?.thinkingOptionMetadata ?? [:])
                if metadata != nil, metadata?.permissionOptions?.isEmpty != false {
                    SettingsNote("Permissions are managed by this agent.")
                }
                if metadata != nil, metadata?.selectableThinkingLevels.isEmpty != false {
                    SettingsNote("This model has no thinking-level options.")
                }
                SettingsSummaryRow("Woven MCP", value: toolsSummary) { toolControls }
            }
            .disabled(!scopeAvailable || inheritsDefaults)
            HStack(spacing: 10) {
                Button(loading ? "Refreshing…" : "Refresh options") { Task { await loadOptions() } }
                    .buttonStyle(SettingsQuietButtonStyle()).disabled(loading || saving || !scopeAvailable)
                if loading { ProgressView().controlSize(.small) }
            }
            if let error { SettingsError(error) }
        }
        .disabled(saving)
        .task(id: identity) { await loadDefaults() }
        .onDisappear { requestID = UUID() }
        .onChange(of: model.connections.inherits) { _, _ in
            if runtime == .defaultAgent { Task { await loadDefaults() } }
        }
        .onChange(of: model.connections.configuration.defaultModel) { _, _ in
            if runtime == .defaultAgent { Task { await loadDefaults() } }
        }
    }

    @ViewBuilder private var toolControls: some View {
        Toggle("Enable Woven MCP", isOn: Binding(get: { toolsEnabled }, set: { enabled in
            save(.tools, selections: SessionSelections(tools: enabled
                ? WorkspaceToolSettings().enabledByDefault.map(\.rawValue).sorted() : []))
        }))
        if toolsEnabled {
            ForEach(WorkspaceToolGroup.configurableCases) { group in
                Toggle(group.title, isOn: Binding(get: { enabledTools.contains(group.rawValue) }, set: { enabled in
                    var tools = enabledTools
                    if enabled { tools.insert(group.rawValue) } else { tools.remove(group.rawValue) }
                    save(.tools, selections: SessionSelections(tools: tools.sorted()))
                }))
            }
        }
        if stored.tools != nil && !managesSharing {
            Button("Use shared defaults") { save(.tools, selections: SessionSelections(tools: nil)) }
                .buttonStyle(SettingsQuietButtonStyle())
        }
        SettingsNote("Calendar access, session limits, and connected apps are set in Settings → Woven MCP.")
    }

    private func selectionRow(_ title: String, field: SessionSelectionField, value: String?, effective: String?,
        options: [String], labels: [String: SessionOptionMetadata]) -> some View {
        var choices = [""]
        if let value, !options.contains(value) { choices.append(value) }
        choices += options
        return SettingsRow(
            title: title,
            detail: effective.flatMap { effective in
                value == nil
                    ? "Current default: \(selectionLabel(effective, field: field, labels: labels))"
                    : labels[effective]?.description
            }
        ) {
            SettingsPicker(title, selection: Binding(get: { value ?? "" }, set: { choice in
                var selection = SessionSelections()
                switch field {
                case .model: selection.model = choice.isEmpty ? nil : choice
                case .thinking: selection.thinking = choice.isEmpty ? nil : choice
                case .permission: selection.permission = choice.isEmpty ? nil : choice
                case .tools: break
                }
                save(field, selections: selection)
            }), options: choices, popoverWidth: 300) { option in
                option.isEmpty ? inheritedLabel : selectionLabel(option, field: field, labels: labels)
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
        metadata = nil; error = nil; loading = false; defaultsReady = false
        stored = SessionSelections(); resolved = SessionSelections()
        guard scopeAvailable else {
            defaultsReady = true
            error = "The local workspace is unavailable. Connect it before editing its defaults."
            return
        }
        do {
            let defaults = try await model.agentSelectionDefaults(runtime: runtime, workspace: workspaceScope)
            guard requestID == request, !Task.isCancelled else { return }
            stored = defaults.stored; resolved = defaults.resolved; usesShared = defaults.usesShared
            defaultsReady = true
            if runtime != .defaultAgent || model.connections.configuration.defaultModel != nil { await loadOptions() }
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            defaultsReady = true
        }
    }

    private func setSharing(_ shared: Bool) {
        guard let workspace = workspaceScope, scopeAvailable else { return }
        let selectedIdentity = identity
        saving = true; error = nil
        requestID = UUID(); loading = false
        Task { @MainActor in
            defer { saving = false }
            do {
                let defaults = try await model.setAgentDefaultsSharing(runtime: runtime, workspace: workspace, shared: shared)
                guard identity == selectedIdentity else { return }
                stored = defaults.stored; resolved = defaults.resolved; usesShared = defaults.usesShared
                await loadOptions()
            } catch {
                guard identity == selectedIdentity else { return }
                self.error = error.localizedDescription
            }
        }
    }

    @MainActor private func loadOptions() async {
        guard scopeAvailable else { return }
        let request = UUID()
        requestID = request; loading = true; error = nil; metadata = nil
        let selectedRuntime = runtime, selectedWorkspace = workspaceID
        var task = model.calendarTaskDefaults(runtime: selectedRuntime, workspaceID: selectedWorkspace)
        task.configuration.model = runtime == .defaultAgent ? model.connections.configuration.defaultModel : resolved.model
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

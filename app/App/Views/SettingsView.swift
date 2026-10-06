import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

private enum HarnessSettingsOrigin: Equatable {
    case landing
    case localWorkspace
    case remoteWorkspaces

    var section: SettingsSection {
        switch self {
        case .landing: .landing
        case .localWorkspace: .localWorkspace
        case .remoteWorkspaces: .remoteWorkspaces
        }
    }
}

private enum SettingsSection: Equatable {
    case landing
    case general
    case agentDefaults
    case connections(String)
    case defaultAgent(String, HarnessSettingsOrigin)
    case harness(AgentRuntimeKind, UUID?, HarnessSettingsOrigin)
    case openClaw
    case openCode
    case hermes
    case hermesWorkspace(UUID?)
    case hermesAgent(UUID)
    case openCodeAgent(UUID?)
    case openCodeWorkspace(UUID?)
    case openClawWorkspace(UUID?)
    case openClawAgent(UUID)
    case localWorkspace
    case remoteWorkspaces
    case buzzWorkspaces
    case usage
}

struct SettingsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @State private var section: SettingsSection = .landing
    @State private var providerReturnSection: SettingsSection = .openClaw

    private var theme: DashboardTheme {
        DashboardTheme(rawValue: storedTheme) ?? .green
    }

    var body: some View {
        ZStack {
            theme.palette.workspace
                .ignoresSafeArea()

            switch section {
            case .landing:
                landing
            case .defaultAgent(let scope, let origin):
                SettingsDefaultAgentView(model: model, initialScope: scope, reservesRailControlSpace: reservesRailControlSpace, onBack: { section = origin.section })
            case .general:
                SettingsGeneralView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing }
                )
            case .agentDefaults:
                SettingsAgentDefaultsView(model: model, reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing })
            case .connections(let scope):
                SettingsConnectionsView(model: model, initialScope: scope,
                    reservesRailControlSpace: reservesRailControlSpace, onBack: { section = .landing })
            case .harness(let runtimeKind, let workspaceID, let origin):
                SettingsHarnessView(
                    model: model,
                    runtimeKind: runtimeKind,
                    workspaceID: workspaceID,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = origin.section }
                )
            case .openClaw:
                SettingsOpenClawView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing },
                    onOpenAgent: { providerReturnSection = .openClaw; section = .openClawAgent($0) }
                )
            case .hermes:
                SettingsHermesView(model: model, reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing },
                    onOpenAgent: { providerReturnSection = .hermes; section = .hermesAgent($0) })
            case .hermesWorkspace(let workspaceID):
                SettingsHermesView(model: model, workspaceID: workspaceID, isWorkspaceScoped: true,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = workspaceID == nil ? .localWorkspace : .remoteWorkspaces },
                    onOpenAgent: { providerReturnSection = .hermesWorkspace(workspaceID); section = .hermesAgent($0) })
            case .hermesAgent(let agentID):
                SettingsHermesAgentView(model: model, agentID: agentID,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = providerReturnSection })
            case .openCode:
                SettingsOpenCodeView(model: model, reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing },
                    onOpenAgent: { providerReturnSection = .openCode; section = .openCodeAgent($0) })
            case .openCodeWorkspace(let workspaceID):
                SettingsOpenCodeView(model: model, workspaceID: workspaceID, isWorkspaceScoped: true,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = workspaceID == nil ? .localWorkspace : .remoteWorkspaces },
                    onOpenAgent: { providerReturnSection = .openCodeWorkspace(workspaceID); section = .openCodeAgent($0) })
            case .openCodeAgent(let workspaceID):
                SettingsOpenCodeAgentView(model: model, workspaceID: workspaceID,
                    reservesRailControlSpace: reservesRailControlSpace, onBack: { section = providerReturnSection })
            case .openClawWorkspace(let workspaceID):
                SettingsOpenClawView(model: model, workspaceID: workspaceID, isWorkspaceScoped: true,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = workspaceID == nil ? .localWorkspace : .remoteWorkspaces },
                    onOpenAgent: { providerReturnSection = .openClawWorkspace(workspaceID); section = .openClawAgent($0) })
            case .openClawAgent(let agentID):
                SettingsOpenClawAgentView(
                    model: model,
                    agentID: agentID,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = providerReturnSection }
                )
            case .localWorkspace:
                SettingsLocalWorkspaceView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing },
                    onMore: {
                        section = harnessSettingsSection(
                            $0,
                            workspaceID: nil,
                            origin: .localWorkspace
                        )
                    }
                )
            case .remoteWorkspaces:
                SettingsRemoteWorkspacesView(
                    model: model.remoteWorkspaces,
                    credentialDisclosureAcknowledged:
                        model.hasAcknowledgedCredentialAccessDisclosure,
                    onAcknowledgeCredentialDisclosure: {
                        model.acknowledgeCredentialAccessDisclosure()
                    },
                    reservesRailControlSpace: reservesRailControlSpace,
                    onMoreRuntime: { kind, configuration in
                        section = harnessSettingsSection(
                            kind,
                            workspaceID: configuration.id,
                            origin: .remoteWorkspaces
                        )
                    },
                    onBack: { section = .landing }
                )
            case .buzzWorkspaces:
                SettingsBuzzWorkspacesView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing }
                )
            case .usage:
                SettingsUsageView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing }
                )
            }
        }
        .foregroundStyle(DashboardPalette.foreground)
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(.light)
        .tint(DashboardPalette.primary)
        .task {
            model.refreshLocalACPRuntimesNow()
        }
        .onAppear { openPendingHermesSettings(); openPendingDefaultAgentSettings(); openPendingConnections() }
        .onChange(of: model.pendingConnectionsScope) { _, _ in openPendingConnections() }
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-connections"))) { event in
            section = .connections(event.object as? String ?? "global")
        }
        .onChange(of: model.pendingDefaultAgentSettingsScope) { _, _ in openPendingDefaultAgentSettings() }
        .onChange(of: model.pendingHermesSettingsAgentID) { _, _ in openPendingHermesSettings() }
    }

    private func openPendingDefaultAgentSettings() {
        guard let scope = model.pendingDefaultAgentSettingsScope else { return }
        section = .defaultAgent(scope, .landing)
        model.pendingDefaultAgentSettingsScope = nil
    }
    private func openPendingConnections() {
        guard let scope = model.pendingConnectionsScope else { return }
        section = .connections(scope); model.pendingConnectionsScope = nil
    }

    private func openPendingHermesSettings() {
        guard let agentID = model.pendingHermesSettingsAgentID else { return }
        providerReturnSection = .hermes
        section = .hermesAgent(agentID)
        model.dismissPendingHermesSettings()
    }

    private var landing: some View {
        SettingsPage(
            title: "Settings",
            reservesRailControlSpace: reservesRailControlSpace
        ) {
            VStack(spacing: 2) {
                SettingsDestinationRow(
                    title: "General",
                    detail: "Theme, sidebar layout, and conversation titles.",
                    icon: { DashboardLucideIcon(glyph: .settings, size: 15) },
                    action: { section = .general }
                )
                SettingsDestinationRow(
                    title: "Connections",
                    detail: "Shared accounts, API keys, and local model servers.",
                    icon: {
                        DashboardLucideIcon(glyph: .plug, size: 15)
                            .rotationEffect(.degrees(45))
                    },
                    action: { section = .connections("global") }
                )
                SettingsDestinationRow(
                    title: "Agent defaults",
                    detail: "Permissions, model, thinking, and Woven tools for new conversations.",
                    icon: { DashboardLucideIcon(glyph: .bot, size: 15) },
                    action: { section = .agentDefaults }
                )
                SettingsDestinationRow(
                    title: "Built-in Agent",
                    detail: "Providers, search, and models across your workspaces.",
                    icon: { DashboardLucideIcon(glyph: .bot, size: 15) },
                    action: { section = .defaultAgent("global", .landing) }
                )
                SettingsDestinationRow(
                    title: "Local agent workspace",
                    detail: "Agents and files on this Mac.",
                    icon: { DashboardLucideIcon(glyph: .terminal, size: 15) },
                    action: { section = .localWorkspace }
                )
                SettingsDestinationRow(
                    title: "Remote agent workspaces",
                    detail: "Agents and files on remote Linux machines.",
                    icon: { DashboardLucideIcon(glyph: .container, size: 15) },
                    action: { section = .remoteWorkspaces }
                )
                SettingsDestinationRow(
                    title: "Codex",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .codex, size: 15) },
                    action: { section = .harness(.codex, nil, .landing) }
                )
                SettingsDestinationRow(
                    title: "Claude Code",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .claude, size: 15) },
                    action: { section = .harness(.claudeCode, nil, .landing) }
                )
                SettingsDestinationRow(
                    title: "Grok Build",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .grok, size: 15) },
                    action: { section = .harness(.grokBuild, nil, .landing) }
                )
                SettingsDestinationRow(
                    title: "Cursor",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .cursor, size: 15) },
                    action: { section = .harness(.cursor, nil, .landing) }
                )
                SettingsDestinationRow(
                    title: "OpenClaw",
                    detail: "Agent names and connections.",
                    icon: { DashboardHarnessLogoIcon(logo: .openClaw, size: 15) },
                    action: { section = .openClaw }
                )
                SettingsDestinationRow(
                    title: "Hermes",
                    detail: "Agent names and connections.",
                    icon: { DashboardHarnessLogoIcon(logo: .hermes, size: 15) },
                    action: { section = .hermes }
                )
                SettingsDestinationRow(
                    title: "OpenCode",
                    detail: "Agent names and connections.",
                    icon: { DashboardHarnessLogoIcon(logo: .openCode, size: 15) },
                    action: { section = .openCode }
                )
                SettingsDestinationRow(
                    title: "Pi",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .pi, size: 15) },
                    action: { section = .harness(.pi, nil, .landing) }
                )
                SettingsDestinationRow(
                    title: "Buzz agent workspaces",
                    detail: "Connect agents from local Buzz workspaces.",
                    icon: { DashboardLucideIcon(glyph: .radioTower, size: 15) },
                    action: { section = .buzzWorkspaces }
                )
                SettingsDestinationRow(
                    title: "Usage",
                    detail: "Accounts and usage tracking.",
                    icon: { DashboardLucideIcon(glyph: .barChart, size: 15) },
                    action: { section = .usage }
                )
            }
        }
    }

    private func harnessSettingsSection(
        _ runtimeKind: AgentRuntimeKind,
        workspaceID: UUID?,
        origin: HarnessSettingsOrigin
    ) -> SettingsSection {
        switch runtimeKind {
        case .defaultAgent: .defaultAgent(workspaceID?.uuidString.lowercased() ?? "local", origin)
        case .openclaw: .openClawWorkspace(workspaceID)
        case .hermes: .hermesWorkspace(workspaceID)
        case .opencode: .openCodeWorkspace(workspaceID)
        default: .harness(runtimeKind, workspaceID, origin)
        }
    }
}

private struct SettingsHarnessView: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    var workspaceID: UUID?
    var reservesRailControlSpace = false
    let onBack: () -> Void
    @Environment(\.dashboardTheme) private var theme

    @AppStorage(DashboardCodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        DashboardCodexLogoStyle.defaultStyle.rawValue

    private var codexLogoStyle: DashboardCodexLogoStyle {
        DashboardCodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    private var remoteWorkspace: RemoteWorkspaceConfiguration? {
        workspaceID.flatMap { model.remoteWorkspaces.configuration(id: $0) }
    }

    var body: some View {
        SettingsPage(
            title: runtimeKind.displayName,
            detail: workspaceID == nil
                ? "\(runtimeKind.displayName) on this Mac."
                : remoteWorkspace.map { "\(runtimeKind.displayName) in \($0.name)." },
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            if runtimeKind == .codex {
                codexIconCard
            }
            SettingsHarnessRuntimeMaintenanceView(
                model: model,
                runtimeKind: runtimeKind,
                workspaceID: workspaceID
            )
        }
    }

    private var codexIconCard: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex icon")
                    .font(.system(size: 14, weight: .semibold))
                Text("Choose the icon used for Codex throughout the app.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Change icon") {
                storedCodexLogoStyle = codexLogoStyle.next.rawValue
            }
            .buttonStyle(SettingsQuietButtonStyle())
            .help("Switch Codex to the \(codexLogoStyle.next.displayName) icon")
            .accessibilityLabel("Change Codex icon")
            .accessibilityValue(codexLogoStyle.displayName)
            .accessibilityHint("Switches to the \(codexLogoStyle.next.displayName) icon")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.workspace)
        .clipShape(DashboardShapes.card)
    }
}


/// Defaults are edited in Settings and captured once when a conversation is
/// created. Options come from the selected harness and execution workspace.
private struct SettingsAgentDefaultsView: View {
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

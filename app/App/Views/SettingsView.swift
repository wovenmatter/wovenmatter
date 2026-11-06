import SwiftUI
import WovenMatterClient
import WovenMatterCore

private enum HarnessSettingsOrigin: Equatable {
    case agents
    case remoteWorkspace(UUID)

    var route: SettingsRoute {
        switch self {
        case .agents: .agents
        case .remoteWorkspace(let id): .workspaces(id)
        }
    }
}

private enum SettingsRoute: Equatable {
    case landing
    case general
    case accounts(String)
    case agents
    case piDurable(String, HarnessSettingsOrigin)
    case harness(AgentRuntimeKind, UUID?, HarnessSettingsOrigin)
    case wovenMCP
    case workspaces(UUID?)
    case companion
    case backgroundServer
    case dictation
}

struct SettingsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @State private var route: SettingsRoute = .landing
    /// Accounts opens from the landing list or from Pi Durable, and returns to where it came from.
    @State private var accountsOrigin: SettingsRoute = .landing

    private var theme: DashboardTheme {
        DashboardTheme(rawValue: storedTheme) ?? .green
    }

    var body: some View {
        ZStack {
            theme.palette.workspace
                .ignoresSafeArea()

            switch route {
            case .landing:
                landing
            case .general:
                SettingsGeneralView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { route = .landing }
                )
            case .accounts(let scope):
                SettingsAccountsView(
                    model: model,
                    initialScope: scope,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: accountsOrigin == .landing ? "Settings" : "Pi Durable",
                    onBack: { route = accountsOrigin; accountsOrigin = .landing }
                )
            case .agents:
                SettingsAgentsView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { route = .landing },
                    onOpen: { route = harnessRoute($0, workspaceID: nil, origin: .agents) }
                )
            case .piDurable(let scope, let origin):
                SettingsDefaultAgentView(
                    model: model,
                    initialScope: scope,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: backTitle(origin),
                    onBack: { route = origin.route },
                    onOpenAccounts: { accountScope in
                        accountsOrigin = .piDurable(accountScope, origin)
                        route = .accounts(accountScope)
                    }
                )
            case .harness(let runtimeKind, let workspaceID, let origin):
                SettingsHarnessView(
                    model: model,
                    runtimeKind: runtimeKind,
                    workspaceID: workspaceID,
                    isWorkspaceScoped: origin != .agents,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: backTitle(origin),
                    onBack: { route = origin.route }
                )
            case .wovenMCP:
                SettingsWovenMCPView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { route = .landing }
                )
            case .workspaces(let workspaceID):
                SettingsWorkspacesView(
                    model: model.remoteWorkspaces,
                    application: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    initialWorkspaceID: workspaceID,
                    onMoreRuntime: { kind, configuration in
                        route = harnessRoute(kind, workspaceID: configuration.id, origin: .remoteWorkspace(configuration.id))
                    },
                    onBack: { route = .landing }
                )
            case .companion:
                SettingsCompanionView(model: model, host: model.companionHost,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { route = .landing })
            case .backgroundServer:
                SettingsBackgroundServerView(model: model, reservesRailControlSpace: reservesRailControlSpace, onBack: { route = .landing })
            case .dictation:
                SettingsDictationView(model: model,
                    reservesRailControlSpace: reservesRailControlSpace, onBack: { route = .landing })
            }
        }
        .foregroundStyle(DashboardPalette.foreground)
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(DashboardPalette.primary)
        .task {
            model.refreshLocalACPRuntimesNow()
        }
        .onAppear { openPendingDefaultAgentSettings(); openPendingConnections() }
        .onChange(of: model.pendingConnectionsScope) { _, _ in openPendingConnections() }
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-connections"))) { event in
            accountsOrigin = .landing
            route = .accounts(event.object as? String ?? "global")
        }
        .onChange(of: model.pendingDefaultAgentSettingsScope) { _, _ in openPendingDefaultAgentSettings() }
    }

    private func openPendingDefaultAgentSettings() {
        guard let scope = model.pendingDefaultAgentSettingsScope else { return }
        route = .piDurable(scope, .agents)
        model.pendingDefaultAgentSettingsScope = nil
    }

    private func openPendingConnections() {
        guard let scope = model.pendingConnectionsScope else { return }
        accountsOrigin = .landing
        route = .accounts(scope)
        model.pendingConnectionsScope = nil
    }

    private func backTitle(_ origin: HarnessSettingsOrigin) -> String {
        switch origin {
        case .agents: "Agents"
        case .remoteWorkspace(let id): model.remoteWorkspaces.configuration(id: id)?.name ?? "Workspaces"
        }
    }

    private func harnessRoute(
        _ runtimeKind: AgentRuntimeKind,
        workspaceID: UUID?,
        origin: HarnessSettingsOrigin
    ) -> SettingsRoute {
        guard runtimeKind == .defaultAgent else { return .harness(runtimeKind, workspaceID, origin) }
        return .piDurable(workspaceID?.uuidString.lowercased() ?? "global", origin)
    }

    private var landing: some View {
        SettingsPage(
            title: "Settings",
            reservesRailControlSpace: reservesRailControlSpace
        ) {
            VStack(spacing: 2) {
                SettingsDestinationRow(
                    title: "General",
                    detail: "Appearance, software updates, and privacy.",
                    icon: { DashboardLucideIcon(glyph: .settings, size: 15) },
                    action: { route = .general }
                )
                SettingsDestinationRow(
                    title: "Accounts",
                    detail: "Provider sign-ins, API keys, and web search.",
                    icon: { DashboardLucideIcon(glyph: .keyRound, size: 15) },
                    action: { accountsOrigin = .landing; route = .accounts("global") }
                )
                SettingsDestinationRow(
                    title: "Agents",
                    detail: "Pi Durable, Codex, Claude Code, Grok Build, and OpenCode.",
                    icon: { DashboardLucideIcon(glyph: .bot, size: 15) },
                    action: { route = .agents }
                )
                SettingsDestinationRow(
                    title: "Woven MCP",
                    detail: "Agent tools, connected apps, and outside access.",
                    icon: { DashboardLucideIcon(glyph: .plug, size: 15) },
                    action: { route = .wovenMCP }
                )
                SettingsDestinationRow(
                    title: "Workspaces",
                    detail: "Agents and files on this Mac and on remote Linux machines.",
                    icon: { DashboardLucideIcon(glyph: .container, size: 15) },
                    action: { route = .workspaces(nil) }
                )
                SettingsDestinationRow(
                    title: "Apple Devices",
                    detail: "Connect Macs, iPhones, and iPads to share your library.",
                    icon: { DashboardLucideIcon(glyph: .monitor, size: 15) },
                    action: { route = .companion }
                )
                SettingsDestinationRow(
                    title: "Background Server",
                    detail: "Keep agents working and see what is running.",
                    icon: { DashboardLucideIcon(glyph: .terminal, size: 15) },
                    action: { route = .backgroundServer }
                )
                SettingsDestinationRow(
                    title: "Dictation",
                    detail: "Language and your previous dictations.",
                    icon: { DashboardLucideIcon(glyph: .mic, size: 15) },
                    action: { route = .dictation }
                )
            }
        }
    }
}

private struct SettingsAgentsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    let onBack: () -> Void
    let onOpen: (AgentRuntimeKind) -> Void
    @Environment(\.openWindow) private var openWindow

    private let runtimes: [AgentRuntimeKind] = [.defaultAgent, .codex, .claudeCode, .grokBuild, .opencode]

    var body: some View {
        SettingsPage(title: "Agents", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            VStack(spacing: 2) {
                ForEach(runtimes, id: \.self) { runtime in
                    let status = status(runtime)
                    SettingsDestinationRow(
                        title: runtime.displayName,
                        status: status.text,
                        statusTone: status.tone,
                        icon: { DashboardHarnessLogoIcon(logo: DashboardHarnessLogo(runtimeKind: runtime), size: 15) },
                        action: { onOpen(runtime) }
                    )
                }
            }
            SettingsSection {
                SettingsRow(title: "Harness setup", detail: "The guided flow for installing and signing in to harnesses.") {
                    Button("Set up harnesses") { openWindow(id: HarnessSetupPresentation.windowID) }
                        .buttonStyle(SettingsQuietButtonStyle())
                }
                SettingsConversationTitlesRow(model: model)
                if let error = model.localACPAgentReconciliationError { SettingsError(error) }
                if let error = model.openCode?.error { SettingsError(error) }
                if let error = model.localRunError { SettingsError(error) }
            }
        }
        .task {
            await model.openCode?.resolveExecutable()
            model.refreshRuntimeInventory()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await model.refreshLocalSignInStatus() }
                for runtime in runtimes where runtime != .defaultAgent {
                    group.addTask { await model.refreshHarnessSignIn(runtime) }
                }
            }
        }
    }

    private func status(_ runtime: AgentRuntimeKind) -> (text: String, tone: SettingsStatusTone) {
        if runtime == .defaultAgent {
            let summary = HarnessAccountPresentation.providerSummary(model.localSignInStatuses)
            let connected = model.localSignInStatuses.contains { ["verified", "credentials_present"].contains($0.state) }
            return (summary, connected ? .good : .neutral)
        }
        if model.checkingLocalACPRuntimeKinds.contains(runtime) { return ("Checking", .neutral) }
        guard let inventory = model.runtimeInventories[runtime] else { return ("Checking", .neutral) }
        guard inventory.isInstalled else { return ("Not installed", .neutral) }
        if runtime != .opencode, let availability = model.localACPRuntimeAvailability.first(where: { $0.runtimeKind == runtime }) {
            if availability.isReady && !model.isLocalACPAgentReady(runtime) { return ("Workspace unavailable", .warning) }
            switch availability.state {
            case .ready: break
            case .cliMissing: return ("CLI required", .warning)
            case .adapterMissing: return ("Adapter required", .warning)
            case .adapterOutdated: return ("Update required", .warning)
            case .authenticationRequired: return ("Sign in required", .warning)
            case .executableUnavailable: return ("Setup required", .warning)
            }
        }
        guard let signIn = model.harnessSignIn.statuses[runtime] else { return ("Installed", .neutral) }
        return (signIn.label, ["verified", "credentials_present"].contains(signIn.state) ? .good : .warning)
    }
}

/// Names new chats. A single row until opened.
private struct SettingsConversationTitlesRow: View {
    @Bindable var model: ApplicationModel

    private var settings: ConversationTitleGenerationSettings { model.titleGenerationSettings }

    var body: some View {
        SettingsSummaryRow(
            "Conversation titles",
            value: settings.isEnabled ? "On, \(settings.model)" : "Off"
        ) {
            SettingsToggleRow(
                title: "Generate with Codex",
                detail: "Uses your local Codex account to name new chats. \(model.titleGenerationStatus)",
                isOn: Binding(get: { settings.isEnabled }, set: { model.setTitleGenerationEnabled($0) })
            )
            if settings.isEnabled {
                SettingsRow(title: "Model") {
                    SettingsPicker(
                        "Title model",
                        selection: Binding(get: { settings.model }, set: { model.setTitleGenerationModel($0) }),
                        options: options(model.titleGenerationCapabilities?.models, selected: settings.model)
                    ) { $0 }
                }
                SettingsRow(title: "Thinking level") {
                    SettingsPicker(
                        "Title thinking level",
                        selection: Binding(get: { settings.thinking }, set: { model.setTitleGenerationThinking($0) }),
                        options: options(model.titleGenerationCapabilities?.thinkingLevels, selected: settings.thinking)
                    ) { $0.capitalized }
                }
                Button(model.isRefreshingTitleGenerationCapabilities ? "Checking…" : "Refresh options") {
                    model.refreshTitleGenerationCapabilitiesNow()
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(model.isRefreshingTitleGenerationCapabilities)
            }
        }
    }

    private func options(_ available: [String]?, selected: String) -> [String] {
        let available = available ?? []
        return available.contains(selected) ? available : [selected] + available
    }
}

private struct SettingsHarnessView: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    var workspaceID: UUID?
    var isWorkspaceScoped = false
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    @State private var scope: String
    @State private var localOverrides = false

    init(
        model: ApplicationModel,
        runtimeKind: AgentRuntimeKind,
        workspaceID: UUID?,
        isWorkspaceScoped: Bool,
        reservesRailControlSpace: Bool,
        backTitle: String,
        onBack: @escaping () -> Void
    ) {
        self.model = model
        self.runtimeKind = runtimeKind
        self.workspaceID = workspaceID
        self.isWorkspaceScoped = isWorkspaceScoped
        self.reservesRailControlSpace = reservesRailControlSpace
        self.backTitle = backTitle
        self.onBack = onBack
        // Start in the right scope so a workspace page never loads the shared one first.
        _scope = State(initialValue: isWorkspaceScoped ? workspaceID?.uuidString.lowercased() ?? "local" : "global")
    }

    private var workspaces: [RemoteWorkspaceConfiguration] { model.remoteWorkspaces.workspaces }
    private var remoteWorkspace: RemoteWorkspaceConfiguration? {
        workspaceID.flatMap { model.remoteWorkspaces.configuration(id: $0) }
    }
    /// With no remote workspace there is nothing to choose, unless this Mac keeps its own defaults.
    private var showsWorkspacePicker: Bool { !workspaces.isEmpty || scope != "global" || localOverrides }

    var body: some View {
        SettingsPage(
            title: runtimeKind.displayName,
            detail: isWorkspaceScoped
                ? remoteWorkspace.map { "In \($0.name)." }
                : nil,
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            if showsWorkspacePicker {
                SettingsWorkspacePicker(title: "Applies to", scope: $scope, workspaces: workspaces)
            }
            SettingsHarnessAccounts(model: model, runtimeKind: runtimeKind, scope: scope)
            if runtimeKind == .opencode {
                SettingsOpenCodeInstances(model: model, scope: scope)
            }
            SettingsAgentDefaultsSection(model: model, runtime: runtimeKind, scope: scope, managesSharing: true)
        }
        .task(id: workspaceID) {
            guard workspaces.isEmpty, let local = model.localACPWorkspaceLaunchConfiguration else { return }
            let defaults = try? await model.agentSelectionDefaults(
                runtime: runtimeKind, workspace: "local:" + local.rootURL.standardizedFileURL.path)
            localOverrides = defaults?.usesShared == false
        }
    }
}

import SwiftUI
import WovenMatterClient
import WovenMatterCore

private enum HarnessSettingsOrigin: Equatable {
    case agents
    case general
    case remoteWorkspace(UUID)

    var route: SettingsRoute {
        switch self {
        case .agents: .agents
        case .general: .general
        case .remoteWorkspace(let id): .workspaces(id)
        }
    }
}

/// Pages other pages link to. Each returns to the page that opened it.
private enum CrossLinkedPage: Hashable {
    case accounts, permissions, wovenMCP, bots
}

private enum SettingsRoute: Equatable {
    case landing
    case general
    case permissions
    case accounts(String)
    case agents
    case piDurable(String, HarnessSettingsOrigin)
    case harness(AgentRuntimeKind, UUID?, HarnessSettingsOrigin)
    case wovenMCP
    case workspaces(UUID?)
    case appleDevices
    case backgroundServer
    case dictation
    case bots
    case botsMachine(String)
    case botsSection(machineID: String, PiBotSettingsSection)
    case botsResources(machineID: String)
}

struct SettingsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @State private var route: SettingsRoute = .landing
    /// Where each cross-linked page was opened from; Back returns there.
    @State private var origins: [CrossLinkedPage: SettingsRoute] = [:]
    @State private var macAccess = MacAccessSetupModel.shared

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
                    onBack: { route = .landing },
                    onOpenCodex: { route = harnessRoute(.codex, workspaceID: nil, origin: .general) }
                )
            case .permissions:
                SettingsPermissionsView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: backTitle(.permissions),
                    onBack: { back(from: .permissions) }
                )
            case .accounts(let scope):
                SettingsAccountsView(
                    model: model,
                    initialScope: scope,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: backTitle(.accounts),
                    onBack: { back(from: .accounts) }
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
                        open(.accounts, .accounts(accountScope), from: .piDurable(accountScope, origin))
                    }
                )
            case .harness(let runtimeKind, let workspaceID, let origin):
                SettingsHarnessView(
                    model: model,
                    runtimeKind: runtimeKind,
                    workspaceID: workspaceID,
                    isWorkspaceScoped: { if case .remoteWorkspace = origin { true } else { false } }(),
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: backTitle(origin),
                    onBack: { route = origin.route }
                )
            case .wovenMCP:
                SettingsWovenMCPView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: backTitle(.wovenMCP),
                    onBack: { back(from: .wovenMCP) },
                    onOpenPermissions: { open(.permissions, .permissions, from: .wovenMCP) }
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
            case .appleDevices:
                SettingsAppleDevicesView(model: model, host: model.libraryHost,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { route = .landing },
                    onOpenBots: { open(.bots, .bots, from: .appleDevices) })
            case .backgroundServer:
                SettingsBackgroundServerView(model: model, reservesRailControlSpace: reservesRailControlSpace, onBack: { route = .landing })
            case .dictation:
                SettingsDictationView(model: model,
                    reservesRailControlSpace: reservesRailControlSpace, onBack: { route = .landing },
                    onOpenPermissions: { open(.permissions, .permissions, from: .dictation) })
            case .bots:
                SettingsBotsView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: backTitle(.bots),
                    onBack: { back(from: .bots) },
                    onOpenMachine: { route = .botsMachine($0) },
                    onOpenWovenMCP: { open(.wovenMCP, .wovenMCP, from: .bots) }
                )
            case .botsMachine(let machineID):
                SettingsBotsMachineView(
                    bots: model.bots,
                    machineID: machineID,
                    workspaces: model.remoteWorkspaces.workspaces,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { route = .bots },
                    onOpenSection: { route = .botsSection(machineID: machineID, $0) },
                    onOpenResources: { route = .botsResources(machineID: machineID) },
                    onOpenAccounts: { open(.accounts, .accounts($0), from: .botsMachine(machineID)) }
                )
            case let .botsSection(machineID, botSection):
                if let session = model.bots.session(for: machineID) {
                    SettingsBotsSectionPage(
                        bots: session,
                        section: botSection,
                        reservesRailControlSpace: reservesRailControlSpace,
                        backTitle: machineTitle(machineID),
                        onBack: { route = .botsMachine(machineID) }
                    )
                } else {
                    SettingsPage(title: botSection.title, reservesRailControlSpace: reservesRailControlSpace,
                                 backTitle: machineTitle(machineID), onBack: { route = .botsMachine(machineID) }) {
                        SettingsEmpty("That machine's bots are not connected.")
                    }
                }
            case .botsResources(let machineID):
                SettingsBotsResourcesView(
                    bots: model.bots, machineID: machineID,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: machineTitle(machineID),
                    onBack: { route = .botsMachine(machineID) }
                )
            }
        }
        .foregroundStyle(DashboardPalette.foreground)
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(DashboardPalette.primary)
        .task {
            model.refreshLocalACPRuntimesNow()
        }
        .onAppear { openPendingDefaultAgentSettings(); openPendingConnections(); openPendingBotsSettings() }
        .onChange(of: model.pendingBotsSettings) { _, _ in openPendingBotsSettings() }
        .onChange(of: model.pendingConnectionsScope) { _, _ in openPendingConnections() }
        // Links inside Settings post these too; Back returns to the page that posted them.
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-connections"))) { event in
            let target = SettingsRoute.accounts(event.object as? String ?? "global")
            if route != target { open(.accounts, target, from: route) }
        }
        .onReceive(NotificationCenter.default.publisher(for: MacAccessSetupModel.openSettingsNotification)) { _ in
            if route != .permissions { open(.permissions, .permissions, from: route) }
        }
        .onChange(of: model.pendingDefaultAgentSettingsScope) { _, _ in openPendingDefaultAgentSettings() }
    }

    private func openPendingDefaultAgentSettings() {
        guard let scope = model.pendingDefaultAgentSettingsScope else { return }
        route = .piDurable(scope, .agents)
        model.pendingDefaultAgentSettingsScope = nil
    }

    private func openPendingBotsSettings() {
        guard model.pendingBotsSettings else { return }
        if let machineID = model.pendingBotProfilesMachine {
            route = .botsSection(machineID: machineID, .profiles)
            model.pendingBotProfilesMachine = nil
        } else if route != .bots { open(.bots, .bots, from: .landing) }
        model.pendingBotsSettings = false
    }

    /// Requests from outside Settings open their page with Back returning to the landing list.
    /// The window also forwards the in-Settings notifications here; a page that is already
    /// open keeps the origin its notification recorded.
    private func openPendingConnections() {
        guard let scope = model.pendingConnectionsScope else { return }
        switch scope {
        case "general": route = .general
        case "permissions": if route != .permissions { open(.permissions, .permissions, from: .landing) }
        default: if route != .accounts(scope) { open(.accounts, .accounts(scope), from: .landing) }
        }
        model.pendingConnectionsScope = nil
    }

    private func open(_ page: CrossLinkedPage, _ target: SettingsRoute, from origin: SettingsRoute) {
        origins[page] = origin
        route = target
    }

    private func back(from page: CrossLinkedPage) {
        route = origins[page] ?? .landing
        origins[page] = nil
    }

    private func backTitle(_ page: CrossLinkedPage) -> String {
        title(origins[page] ?? .landing)
    }

    /// The page name a Back button shows when it returns to `route`.
    private func title(_ route: SettingsRoute) -> String {
        switch route {
        case .landing: "Settings"
        case .general: "General"
        case .permissions: "Permissions & Access"
        case .accounts: "Subscriptions & API Keys"
        case .agents: "Agents"
        case .piDurable: "Pi Durable"
        case .harness(let kind, _, _): kind.displayName
        case .wovenMCP: "Woven MCP"
        case .workspaces(let id): id.flatMap { model.remoteWorkspaces.configuration(id: $0)?.name } ?? "Workspaces"
        case .appleDevices: "Apple Devices"
        case .backgroundServer: "Background Server"
        case .dictation: "Dictation"
        case .bots: "Bots"
        case .botsMachine(let id): machineTitle(id)
        case .botsSection(_, let section): section.title
        case .botsResources: "Resources"
        }
    }

    private func machineTitle(_ machineID: String) -> String {
        model.bots.machines.first { $0.id == machineID }?.displayName ?? "Bots"
    }

    private func backTitle(_ origin: HarnessSettingsOrigin) -> String {
        switch origin {
        case .agents: "Agents"
        case .general: "General"
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
                    title: "Permissions & Access",
                    detail: "Keychain and the macOS permissions agents use.",
                    status: macAccess.summary,
                    statusTone: macAccess.remaining.isEmpty ? .good : .warning,
                    icon: { DashboardLucideIcon(glyph: .shieldCheck, size: 15) },
                    action: { open(.permissions, .permissions, from: .landing) }
                )
                SettingsDestinationRow(
                    title: "Subscriptions & API Keys",
                    detail: "ChatGPT, Claude, Grok, and other providers, plus web search.",
                    icon: { DashboardLucideIcon(glyph: .keyRound, size: 15) },
                    action: { open(.accounts, .accounts("global"), from: .landing) }
                )
                SettingsDestinationRow(
                    title: "Agents",
                    detail: "Pi Durable, Codex, Claude Code, Grok Build, and OpenCode.",
                    icon: { DashboardLucideIcon(glyph: .bot, size: 15) },
                    action: { route = .agents }
                )
                SettingsDestinationRow(
                    title: "Bots",
                    detail: "Where your bots run, their models, and their resources.",
                    icon: { DashboardLucideIcon(glyph: .sparkles, size: 15) },
                    action: { open(.bots, .bots, from: .landing) }
                )
                SettingsDestinationRow(
                    title: "Woven MCP",
                    detail: "Agent tools, connected apps, bots, and outside access.",
                    icon: { DashboardLucideIcon(glyph: .plug, size: 15) },
                    action: { open(.wovenMCP, .wovenMCP, from: .landing) }
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
                    action: { route = .appleDevices }
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
        .task { macAccess.refresh(keychainReady: model.keychainAccessReady) }
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

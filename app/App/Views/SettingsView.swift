import SwiftUI

private enum HarnessSettingsOrigin: Equatable {
    case agents
    case general
    case machine(String)

    var route: SettingsRoute {
        switch self {
        case .agents: .agents
        case .general: .general
        case .machine(let id): .workspaces(id)
        }
    }
}

/// Pages other pages link to. Each returns to the page that opened it.
private enum CrossLinkedPage: Hashable {
    case accounts, permissions, wovenMCP, bots, updates
}

private enum SettingsRoute: Equatable {
    case landing
    case general
    case updates
    case permissions
    case accounts(String)
    case github
    case agents
    case piDurable(String, HarnessSettingsOrigin)
    case harness(AgentRuntimeKind, String?, HarnessSettingsOrigin)
    case wovenMCP
    case workspaces(String?)
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
    @AppStorage(WovenTheme.storageKey) private var storedTheme = WovenTheme.green.rawValue
    @State private var route: SettingsRoute = .landing
    /// Where each cross-linked page was opened from; Back returns there.
    @State private var origins: [CrossLinkedPage: SettingsRoute] = [:]
    @State private var macAccess = MacAccessSetupModel.shared
    private var updates: UpdatesStore { model.updates }

    private var theme: WovenTheme {
        WovenTheme(rawValue: storedTheme) ?? .green
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
                    onOpenCodex: { route = harnessRoute(.codex, machineID: nil, origin: .general) },
                    onOpenUpdates: { open(.updates, .updates, from: .general) }
                )
            case .updates:
                SettingsUpdatesView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: backTitle(.updates),
                    onBack: { back(from: .updates) }
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
            case .github:
                SettingsGitHubView(model: model, reservesRailControlSpace: reservesRailControlSpace,
                                   onBack: { route = .landing })
            case .agents:
                SettingsAgentsView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { route = .landing },
                    onOpen: { route = harnessRoute($0, machineID: nil, origin: .agents) }
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
            case .harness(let runtimeKind, let machineID, let origin):
                SettingsHarnessView(
                    model: model,
                    runtimeKind: runtimeKind,
                    machineID: machineID,
                    isMachineScoped: { if case .machine = origin { true } else { false } }(),
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
            case .workspaces(let machineID):
                SettingsWorkspacesView(
                    model: model.machines,
                    application: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    initialMachineID: machineID,
                    onMoreRuntime: { kind, machine in
                        route = harnessRoute(kind, machineID: machine.id, origin: .machine(machine.id))
                    },
                    onBack: { route = .landing }
                )
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
                    onOpenWovenMCP: { open(.wovenMCP, .wovenMCP, from: .bots) },
                    onOpenUpdates: { open(.updates, .updates, from: .bots) }
                )
            case .botsMachine(let machineID):
                SettingsBotsMachineView(
                    bots: model.bots,
                    machineID: machineID,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { route = .bots },
                    onOpenSection: { route = .botsSection(machineID: machineID, $0) },
                    onOpenResources: { route = .botsResources(machineID: machineID) },
                    onOpenAccounts: { open(.accounts, .accounts($0), from: .botsMachine(machineID)) }
                )
            case let .botsSection(machineID, botSection):
                SettingsBotsSectionPage(
                    bots: model.bots,
                    section: botSection,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: machineTitle(machineID),
                    onBack: { route = .botsMachine(machineID) }
                )
            case .botsResources(let machineID):
                SettingsBotsResourcesView(
                    bots: model.bots, machineID: machineID,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: machineTitle(machineID),
                    onBack: { route = .botsMachine(machineID) }
                )
            }
        }
        .foregroundStyle(WovenPalette.foreground)
        .environment(\.wovenTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(WovenPalette.primary)
        .onAppear { openPendingDefaultAgentSettings(); openPendingConnections(); openPendingBotsSettings() }
        .onChange(of: model.navigation.pendingBotsSettings) { _, _ in openPendingBotsSettings() }
        .onChange(of: model.navigation.pendingConnectionsScope) { _, _ in openPendingConnections() }
        // Links inside Settings post these too; Back returns to the page that posted them.
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-connections"))) { event in
            let target = SettingsRoute.accounts(event.object as? String ?? "global")
            if route != target { open(.accounts, target, from: route) }
        }
        .onReceive(NotificationCenter.default.publisher(for: MacAccessSetupModel.openSettingsNotification)) { _ in
            if route != .permissions { open(.permissions, .permissions, from: route) }
        }
        .onChange(of: model.navigation.pendingDefaultAgentSettingsScope) { _, _ in openPendingDefaultAgentSettings() }
    }

    private func openPendingDefaultAgentSettings() {
        guard let scope = model.navigation.pendingDefaultAgentSettingsScope else { return }
        route = .piDurable(scope, .agents)
        model.navigation.pendingDefaultAgentSettingsScope = nil
    }

    private func openPendingBotsSettings() {
        let navigation = model.navigation
        guard navigation.pendingBotsSettings else { return }
        if let machineID = navigation.pendingBotProfilesMachine {
            route = .botsSection(machineID: machineID, .profiles)
            navigation.pendingBotProfilesMachine = nil
        } else if route != .bots { open(.bots, .bots, from: .landing) }
        navigation.pendingBotsSettings = false
    }

    /// Requests from outside Settings open their page with Back returning to the landing list.
    /// The window also forwards the in-Settings notifications here; a page that is already
    /// open keeps the origin its notification recorded.
    private func openPendingConnections() {
        guard let scope = model.navigation.pendingConnectionsScope else { return }
        switch scope {
        case "general": route = .general
        #if DEBUG
        case "agents": route = .agents
        case "updates": route = .updates
        case "opencode": route = harnessRoute(.opencode, machineID: nil, origin: .agents)
        case "github": route = .github
        case "dictation": route = .dictation
        case "workspaces": route = .workspaces(nil)
        #endif
        case "permissions": if route != .permissions { open(.permissions, .permissions, from: .landing) }
        default: if route != .accounts(scope) { open(.accounts, .accounts(scope), from: .landing) }
        }
        model.navigation.pendingConnectionsScope = nil
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
        case .updates: "Updates"
        case .permissions: "Permissions & Access"
        case .accounts: "Subscriptions & API Keys"
        case .github: "GitHub"
        case .agents: "Agents"
        case .piDurable: "Pi Durable"
        case .harness(let kind, _, _): kind.displayName
        case .wovenMCP: "Woven MCP"
        case .workspaces(let id): id.flatMap { model.machines.machine(id: $0)?.name } ?? "Workspaces"
        case .backgroundServer: "Background Server"
        case .dictation: "Dictation"
        case .bots: "Bots"
        case .botsMachine(let id): machineTitle(id)
        case .botsSection(_, let section): section.title
        case .botsResources: "Resources"
        }
    }

    private func machineTitle(_ machineID: String) -> String {
        model.machines.machine(id: machineID)?.name ?? "Bots"
    }

    private func backTitle(_ origin: HarnessSettingsOrigin) -> String {
        switch origin {
        case .agents: "Agents"
        case .general: "General"
        case .machine(let id): model.machines.machine(id: id)?.name ?? "Workspaces"
        }
    }

    private func harnessRoute(
        _ runtimeKind: AgentRuntimeKind,
        machineID: String?,
        origin: HarnessSettingsOrigin
    ) -> SettingsRoute {
        guard runtimeKind == .defaultAgent else { return .harness(runtimeKind, machineID, origin) }
        return .piDurable(machineID ?? "global", origin)
    }

    private var landing: some View {
        SettingsPage(
            title: "Settings",
            reservesRailControlSpace: reservesRailControlSpace
        ) {
            VStack(spacing: 2) {
                SettingsDestinationRow(
                    title: "General",
                    detail: "Version, appearance, conversation titles, and privacy.",
                    icon: { LucideIcon(glyph: .settings, size: 15) },
                    action: { route = .general }
                )
                SettingsDestinationRow(
                    title: "Updates",
                    detail: "Woven Matter and harnesses on every device.",
                    status: updates.availableCount > 0 || updates.running ? updates.summary : nil,
                    statusTone: updates.availableCount > 0 ? .warning : .neutral,
                    icon: { LucideIcon(glyph: .rocket, size: 15) },
                    action: { open(.updates, .updates, from: .landing) }
                )
                SettingsDestinationRow(
                    title: "Permissions & Access",
                    detail: "The macOS permissions agents use.",
                    status: macAccess.summary,
                    statusTone: macAccess.remaining.isEmpty ? .good : .warning,
                    icon: { LucideIcon(glyph: .shieldCheck, size: 15) },
                    action: { open(.permissions, .permissions, from: .landing) }
                )
                SettingsDestinationRow(
                    title: "Subscriptions & API Keys",
                    detail: "ChatGPT, Claude, Grok, and other providers, plus web search.",
                    icon: { LucideIcon(glyph: .keyRound, size: 15) },
                    action: { open(.accounts, .accounts("global"), from: .landing) }
                )
                SettingsDestinationRow(
                    title: "GitHub",
                    detail: "Your SSH key and commit identity for agents and bots everywhere.",
                    status: model.settings.github.map { $0.key == nil ? "No key" : "Key added" },
                    statusTone: model.settings.github?.key == nil ? .neutral : .good,
                    icon: { LucideIcon(glyph: .gitBranch, size: 15) },
                    action: { route = .github }
                )
                SettingsDestinationRow(
                    title: "Agents",
                    detail: "Pi Durable, Codex, Claude Code, Grok Build, and OpenCode.",
                    icon: { LucideIcon(glyph: .bot, size: 15) },
                    action: { route = .agents }
                )
                SettingsDestinationRow(
                    title: "Bots",
                    detail: "Where your bots run, their models, and their resources.",
                    icon: { LucideIcon(glyph: .sparkles, size: 15) },
                    action: { open(.bots, .bots, from: .landing) }
                )
                SettingsDestinationRow(
                    title: "Woven MCP",
                    detail: "Agent tools, connected apps, bots, and outside access.",
                    icon: { LucideIcon(glyph: .plug, size: 15) },
                    action: { open(.wovenMCP, .wovenMCP, from: .landing) }
                )
                SettingsDestinationRow(
                    title: "Workspaces",
                    detail: "Agents and files on this Mac and on remote Linux machines.",
                    icon: { LucideIcon(glyph: .container, size: 15) },
                    action: { route = .workspaces(nil) }
                )
                SettingsDestinationRow(
                    title: "Background Server",
                    detail: "Keep agents working and see what is running.",
                    icon: { LucideIcon(glyph: .terminal, size: 15) },
                    action: { route = .backgroundServer }
                )
                SettingsDestinationRow(
                    title: "Dictation",
                    detail: "Language and your previous dictations.",
                    icon: { LucideIcon(glyph: .mic, size: 15) },
                    action: { route = .dictation }
                )
            }
        }
        .task {
            macAccess.refresh()
            updates.loadIfNeeded()
            await model.settings.loadGitHub()
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

    private var thisMachineID: String? { model.thisMachineID }

    var body: some View {
        SettingsPage(title: "Agents", reservesRailControlSpace: reservesRailControlSpace, onBack: onBack) {
            VStack(spacing: 2) {
                ForEach(runtimes, id: \.self) { runtime in
                    let status = status(runtime)
                    SettingsDestinationRow(
                        title: runtime.displayName,
                        status: status.text,
                        statusTone: status.tone,
                        icon: { HarnessLogoIcon(logo: HarnessLogo(runtimeKind: runtime), size: 15) },
                        action: { onOpen(runtime) }
                    )
                }
            }
            SettingsSection {
                SettingsRow(title: "Harness setup", detail: "The guided flow for installing and signing in to harnesses.") {
                    Button("Set up harnesses") { openWindow(id: HarnessSetupPresentation.windowID) }
                        .buttonStyle(SettingsQuietButtonStyle())
                }
            }
        }
        .task {
            guard let thisMachineID else { return }
            model.machines.refreshHarnesses(on: thisMachineID)
            await withTaskGroup(of: Void.self) { group in
                for runtime in runtimes where runtime != .defaultAgent {
                    group.addTask { await model.machines.refreshSignIn(runtime, on: thisMachineID) }
                }
            }
        }
    }

    private func status(_ runtime: AgentRuntimeKind) -> (text: String, tone: SettingsStatusTone) {
        guard let thisMachineID else { return ("Checking", .neutral) }
        let machines = model.machines
        if runtime == .defaultAgent {
            let statuses = machines.providerSignIns(on: thisMachineID)
            return (HarnessAccountPresentation.providerSummary(statuses), statuses.contains(where: \.hasCredentials) ? .good : .neutral)
        }
        if machines.isCheckingHarness(runtime, on: thisMachineID) { return ("Checking", .neutral) }
        guard let harness = machines.harness(runtime, on: thisMachineID) else { return ("Checking", .neutral) }
        guard harness.isInstalled else { return ("Not installed", .neutral) }
        switch harness.state {
        case .ready, .notInstalled: break
        case .signInRequired: return ("Sign in required", .warning)
        case .unavailable, .failed: return ("Setup required", .warning)
        }
        guard let signIn = machines.signInStatus(runtime, on: thisMachineID) else { return ("Installed", .neutral) }
        return (signIn.label, signIn.hasCredentials ? .good : .warning)
    }
}

/// One harness's accounts, instances and defaults, for every machine or one machine.
private struct SettingsHarnessView: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    var machineID: String?
    var isMachineScoped = false
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    let onBack: () -> Void
    @State private var scope: String
    @State private var localOverrides = false

    init(
        model: ApplicationModel,
        runtimeKind: AgentRuntimeKind,
        machineID: String?,
        isMachineScoped: Bool,
        reservesRailControlSpace: Bool,
        backTitle: String,
        onBack: @escaping () -> Void
    ) {
        self.model = model
        self.runtimeKind = runtimeKind
        self.machineID = machineID
        self.isMachineScoped = isMachineScoped
        self.reservesRailControlSpace = reservesRailControlSpace
        self.backTitle = backTitle
        self.onBack = onBack
        // Start in the right scope so a machine's page never loads the shared one first.
        _scope = State(initialValue: isMachineScoped ? machineID ?? model.thisMachineID ?? "global" : "global")
    }

    private var machines: [Machine] { model.machines.machines }
    private var scopedMachine: Machine? { machineID.flatMap { model.machines.machine(id: $0) } }
    /// With one machine there is nothing to choose, unless it keeps its own defaults.
    private var showsMachinePicker: Bool { machines.count > 1 || scope != "global" || localOverrides }

    var body: some View {
        SettingsPage(
            title: runtimeKind.displayName,
            detail: isMachineScoped ? scopedMachine.map { "In \($0.name)." } : nil,
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            if showsMachinePicker {
                SettingsWorkspacePicker(title: "Applies to", scope: $scope, machines: machines)
            }
            SettingsHarnessAccounts(model: model, runtimeKind: runtimeKind, scope: scope)
            SettingsAgentDefaultsSection(model: model, runtime: runtimeKind, scope: scope, managesSharing: true)
        }
        .task(id: machineID) {
            guard machines.count <= 1, let thisMachineID = model.thisMachineID else { return }
            let defaults = try? await model.settings.agentSelectionDefaults(runtime: runtimeKind, machineID: thisMachineID)
            localOverrides = defaults?.usesShared == false
        }
    }
}

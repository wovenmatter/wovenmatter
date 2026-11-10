import SwiftUI
import WovenMatterClient
import WovenMatterCore

private enum HarnessSettingsOrigin: Equatable {
    case agents
    case localWorkspace
    case remoteWorkspaces

    var section: SettingsSection {
        switch self {
        case .agents: .agents
        case .localWorkspace: .localWorkspace
        case .remoteWorkspaces: .remoteWorkspaces
        }
    }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .localWorkspace: "Local Workspace"
        case .remoteWorkspaces: "Remote Workspaces"
        }
    }
}

private enum SettingsSection: Equatable {
    case landing
    case agents
    case general
    case permissions
    case backgroundServer
    case connections(String)
    case defaultAgent(String, HarnessSettingsOrigin)
    case harness(AgentRuntimeKind, UUID?, HarnessSettingsOrigin)
    case companion
    case openCode
    case openCodeAgent(UUID?)
    case openCodeWorkspace(UUID?)
    case localWorkspace
    case remoteWorkspaces
    case usage
    case dictation
    case bots
    case botsSection(machineID: String, PiBotSettingsSection)
    case botsResources(machineID: String)
}

struct SettingsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @State private var section: SettingsSection = .landing
    @State private var providerReturnSection: SettingsSection = .openCode
    @State private var macAccess = MacAccessSetupModel.shared

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
            case .agents:
                agents
            case .companion:
                SettingsCompanionView(model: model, host: model.companionHost,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing })
            case .defaultAgent(let scope, let origin):
                SettingsDefaultAgentView(model: model, initialScope: scope,
                    reservesRailControlSpace: reservesRailControlSpace, backTitle: origin.title,
                    onBack: { section = origin.section })
            case .backgroundServer:
                SettingsBackgroundServerView(model: model, reservesRailControlSpace: reservesRailControlSpace, onBack: { section = .landing })
            case .general:
                SettingsGeneralView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing },
                    onOpenPermissions: { section = .permissions }
                )
            case .permissions:
                SettingsPermissionsView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing }
                )
            case .connections(let scope):
                SettingsDefaultAgentView(model: model, initialScope: scope,
                    reservesRailControlSpace: reservesRailControlSpace, backTitle: "Agents",
                    onBack: { section = .agents })
            case .harness(let runtimeKind, let workspaceID, let origin):
                SettingsHarnessView(
                    model: model,
                    runtimeKind: runtimeKind,
                    workspaceID: workspaceID,
                    isWorkspaceScoped: origin != .agents,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: origin.title,
                    onBack: { section = origin.section }
                )
            case .openCode:
                SettingsOpenCodeView(model: model, reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: "Agents", onBack: { section = .agents },
                    onOpenAgent: { providerReturnSection = .openCode; section = .openCodeAgent($0) })
            case .openCodeWorkspace(let workspaceID):
                SettingsOpenCodeView(model: model, workspaceID: workspaceID, isWorkspaceScoped: true,
                    reservesRailControlSpace: reservesRailControlSpace,
                    backTitle: workspaceID == nil ? "Local Workspace" : "Remote Workspaces",
                    onBack: { section = workspaceID == nil ? .localWorkspace : .remoteWorkspaces },
                    onOpenAgent: { providerReturnSection = .openCodeWorkspace(workspaceID); section = .openCodeAgent($0) })
            case .openCodeAgent(let workspaceID):
                SettingsOpenCodeAgentView(model: model, workspaceID: workspaceID,
                    reservesRailControlSpace: reservesRailControlSpace, onBack: { section = providerReturnSection })
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
                    application: model,
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
            case .dictation:
                SettingsDictationView(model: model,
                    reservesRailControlSpace: reservesRailControlSpace, onBack: { section = .landing },
                    onOpenPermissions: { section = .permissions })
            case .usage:
                SettingsUsageView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing }
                )
            case .bots:
                SettingsBotsView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing },
                    onOpenSection: { section = .botsSection(machineID: $0, $1) },
                    onOpenResources: { section = .botsResources(machineID: $0) },
                    onOpenConnections: { section = .connections("global") }
                )
            case let .botsSection(machineID, botSection):
                if let session = model.bots.session(for: machineID) {
                    SettingsBotsSectionPage(
                        bots: session,
                        section: botSection,
                        reservesRailControlSpace: reservesRailControlSpace,
                        onBack: { section = .bots }
                    )
                } else {
                    SettingsPage(title: botSection.title, reservesRailControlSpace: reservesRailControlSpace, backTitle: "Bots",
                                 onBack: { section = .bots }) { SettingsEmpty("That machine's bots are not connected.") }
                }
            case .botsResources(let machineID):
                SettingsBotsResourcesView(
                    bots: model.bots, machineID: machineID,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .bots }
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
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-connections"))) { event in
            section = .connections(event.object as? String ?? "global")
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-usage-settings"))) { _ in section = .usage }
        .onReceive(NotificationCenter.default.publisher(for: MacAccessSetupModel.openSettingsNotification)) { _ in section = .permissions }
        .onChange(of: model.pendingDefaultAgentSettingsScope) { _, _ in openPendingDefaultAgentSettings() }
    }

    private func openPendingDefaultAgentSettings() {
        guard let scope = model.pendingDefaultAgentSettingsScope else { return }
        section = .defaultAgent(scope, .agents)
        model.pendingDefaultAgentSettingsScope = nil
    }
    private func openPendingBotsSettings() {
        guard model.pendingBotsSettings else { return }
        section = .bots
        model.pendingBotsSettings = false
    }
    private func openPendingConnections() {
        guard let scope = model.pendingConnectionsScope else { return }
        section = switch scope {
        case "usage": .usage
        case "general": .general
        case "permissions": .permissions
        default: .connections(scope)
        }
        model.pendingConnectionsScope = nil
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
                    title: "Permissions & Access",
                    detail: macAccess.summary,
                    icon: { DashboardLucideIcon(glyph: .keyRound, size: 15) },
                    action: { section = .permissions }
                )
                SettingsDestinationRow(
                    title: "Agents",
                    detail: "Accounts, installation, and chat settings.",
                    icon: { DashboardLucideIcon(glyph: .bot, size: 15) },
                    action: { section = .agents }
                )
                SettingsDestinationRow(
                    title: "Bots",
                    detail: "Where your bots run, their resources, models, and Woven MCP access.",
                    icon: { DashboardLucideIcon(glyph: .sparkles, size: 15) },
                    action: { section = .bots }
                )
                SettingsDestinationRow(
                    title: "Dictation",
                    detail: "Read and copy your previous dictations.",
                    icon: { DashboardLucideIcon(glyph: .mic, size: 15) },
                    action: { section = .dictation }
                )
                SettingsDestinationRow(
                    title: "Local Workspace",
                    detail: "Agents and files on this Mac.",
                    icon: { DashboardLucideIcon(glyph: .terminal, size: 15) },
                    action: { section = .localWorkspace }
                )
                SettingsDestinationRow(
                    title: "Remote Workspaces",
                    detail: "Agents and files on remote Linux machines.",
                    icon: { DashboardLucideIcon(glyph: .container, size: 15) },
                    action: { section = .remoteWorkspaces }
                )
                SettingsDestinationRow(
                    title: "Apple Devices",
                    detail: "Connect Macs, iPhones, and iPads to share your library.",
                    icon: { DashboardLucideIcon(glyph: .monitor, size: 15) },
                    action: { section = .companion }
                )
                SettingsDestinationRow(
                    title: "Background Server",
                    detail: "Server controls and managed activity on this Mac and remote workspaces.",
                    icon: { DashboardLucideIcon(glyph: .terminal, size: 15) },
                    action: { section = .backgroundServer }
                )
                SettingsDestinationRow(
                    title: "Usage",
                    detail: "Accounts and usage tracking.",
                    icon: { DashboardLucideIcon(glyph: .barChart, size: 15) },
                    action: { section = .usage }
                )
            }
        }
        .task { macAccess.refresh(keychainReady: model.keychainAccessReady) }
    }

    private var agents: some View {
        SettingsPage(
            title: "Agents",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: { section = .landing }
        ) {
            VStack(spacing: 2) {
                SettingsDestinationRow(
                    title: AgentRuntimeKind.defaultAgent.displayName,
                    detail: "Conversation defaults, subagents, providers, and models.",
                    icon: { DashboardHarnessLogoIcon(logo: .defaultAgent, size: 15) },
                    action: { section = .defaultAgent("global", .agents) }
                )
                SettingsDestinationRow(
                    title: "Codex",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .codex, size: 15) },
                    action: { section = .harness(.codex, nil, .agents) }
                )
                SettingsDestinationRow(
                    title: "Claude Code",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .claude, size: 15) },
                    action: { section = .harness(.claudeCode, nil, .agents) }
                )
                SettingsDestinationRow(
                    title: "Grok Build",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .grok, size: 15) },
                    action: { section = .harness(.grokBuild, nil, .agents) }
                )
                SettingsDestinationRow(
                    title: AgentRuntimeKind.opencode.displayName,
                    detail: "Agent names and connections.",
                    icon: { DashboardHarnessLogoIcon(logo: .openCode, size: 15) },
                    action: { section = .openCode }
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
        case .opencode: .openCodeWorkspace(workspaceID)
        default: .harness(runtimeKind, workspaceID, origin)
        }
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
            detail: isWorkspaceScoped
                ? remoteWorkspace.map { "\(runtimeKind.displayName) in \($0.name)." } ?? "\(runtimeKind.displayName) in the local workspace."
                : "Conversation defaults and runtime settings.",
            reservesRailControlSpace: reservesRailControlSpace,
            backTitle: backTitle,
            onBack: onBack
        ) {
            SettingsAgentDefaultsSection(model: model, runtime: runtimeKind, includesHarnessSetup: true,
                initialScope: isWorkspaceScoped ? workspaceID?.uuidString.lowercased() ?? "local" : "global")
            if runtimeKind == .codex {
                codexIconCard
            }
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

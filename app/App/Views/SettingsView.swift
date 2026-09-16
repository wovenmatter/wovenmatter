import SwiftUI
import WovenMatterClient
import WovenMatterCore

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
            case .general:
                SettingsGeneralView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing }
                )
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
        .onAppear { openPendingHermesSettings() }
        .onChange(of: model.pendingHermesSettingsAgentID) { _, _ in openPendingHermesSettings() }
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
            detail: "Appearance, connections, and agent workspaces on this Mac.",
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
                    title: "Local agent workspace",
                    detail: "Direct CLI and ACP sessions, runtimes, and workspace folders.",
                    icon: { DashboardLucideIcon(glyph: .terminal, size: 15) },
                    action: { section = .localWorkspace }
                )
                SettingsDestinationRow(
                    title: "Remote agent workspaces",
                    detail: "Standalone Linux workspaces deployed through SSH.",
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
                    detail: "Gateway connections and Woven Matter names for every OpenClaw agent.",
                    icon: { DashboardHarnessLogoIcon(logo: .openClaw, size: 15) },
                    action: { section = .openClaw }
                )
                SettingsDestinationRow(
                    title: "Hermes",
                    detail: "Gateway connections and Woven Matter names for every Hermes agent.",
                    icon: { DashboardHarnessLogoIcon(logo: .hermes, size: 15) },
                    action: { section = .hermes }
                )
                SettingsDestinationRow(
                    title: "OpenCode",
                    detail: "Server connections and Woven Matter names for every OpenCode agent.",
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
                    detail: "Optional local workspace discovery and agent enrollment.",
                    icon: { DashboardLucideIcon(glyph: .radioTower, size: 15) },
                    action: { section = .buzzWorkspaces }
                )
                SettingsDestinationRow(
                    title: "Usage",
                    detail: "Usage collection and provider connection settings.",
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
            SettingsHarnessRuntimeMaintenanceView(
                model: model,
                runtimeKind: runtimeKind,
                workspaceID: workspaceID
            )
        }
    }
}

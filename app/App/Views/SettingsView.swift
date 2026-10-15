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
    case connections(String)
    case defaultAgent(String, HarnessSettingsOrigin)
    case harness(AgentRuntimeKind, UUID?, HarnessSettingsOrigin)
    case companion
    case workspaces
    case openCode
    case openCodeAgent(UUID?)
    case openCodeWorkspace(UUID?)
    case localWorkspace
    case remoteWorkspaces
    case usage
}

struct SettingsView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var executionOnly = false
    var clientContext: CentralLibraryClientModel?
    var applicationContext: ApplicationModel?
    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @State private var section: SettingsSection = .landing
    @State private var providerReturnSection: SettingsSection = .openCode

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
            case .companion:
                SettingsCompanionView(model: applicationContext ?? model, host: (applicationContext ?? model).companionHost,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing })
            case .workspaces:
                SettingsDeviceWorkspacesView(application: applicationContext ?? model, client: clientContext,
                    reservesRailControlSpace: reservesRailControlSpace, onBack: { section = .landing },
                    onLocalSettings: { section = .localWorkspace }, onRemoteSettings: { section = .remoteWorkspaces })
            case .defaultAgent(let scope, let origin):
                SettingsDefaultAgentView(model: model, initialScope: scope, reservesRailControlSpace: reservesRailControlSpace, onBack: { section = origin.section })
            case .general:
                SettingsGeneralView(
                    model: applicationContext ?? model,
                    showsBackgroundExecution: clientContext == nil,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing }
                )
            case .connections(let scope):
                SettingsConnectionsView(model: model, initialScope: scope,
                    reservesRailControlSpace: reservesRailControlSpace, onBack: { section = .landing })
            case .harness(let runtimeKind, let workspaceID, let origin):
                SettingsHarnessView(
                    model: model,
                    runtimeKind: runtimeKind,
                    workspaceID: workspaceID,
                    isWorkspaceScoped: origin != .landing,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = origin.section }
                )
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
        .preferredColorScheme(theme.colorScheme)
        .tint(DashboardPalette.primary)
        .task {
            model.refreshLocalACPRuntimesNow()
        }
        .onAppear { openPendingDefaultAgentSettings(); openPendingConnections() }
        .onChange(of: model.pendingConnectionsScope) { _, _ in openPendingConnections() }
        .onReceive(NotificationCenter.default.publisher(for: .init("wovenmatter.open-connections"))) { event in
            section = .connections(event.object as? String ?? "global")
        }
        .onChange(of: model.pendingDefaultAgentSettingsScope) { _, _ in openPendingDefaultAgentSettings() }
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

    private var landing: some View {
        SettingsPage(
            title: "Settings",
            reservesRailControlSpace: reservesRailControlSpace
        ) {
            VStack(spacing: 2) {
                if !executionOnly {
                SettingsDestinationRow(
                    title: "General",
                    detail: "Theme, sidebar layout, and conversation titles.",
                    icon: { DashboardLucideIcon(glyph: .settings, size: 15) },
                    action: { section = .general }
                )
                }
                if !executionOnly {
                SettingsDestinationRow(
                    title: "Device Connections",
                    detail: "Connect Macs, iPhones, and iPads to one central database over Tailscale.",
                    icon: { DashboardLucideIcon(glyph: .monitor, size: 15) },
                    action: { section = .companion }
                )
                }
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
                    title: AgentRuntimeKind.defaultAgent.displayName,
                    detail: "Conversation defaults, subagents, providers, and models.",
                    icon: { DashboardHarnessLogoIcon(logo: .defaultAgent, size: 15) },
                    action: { section = .defaultAgent("global", .landing) }
                )
                SettingsDestinationRow(
                    title: "Local agent workspace",
                    detail: "Agents and files on this Mac.",
                    icon: { DashboardLucideIcon(glyph: .terminal, size: 15) },
                    action: { section = .localWorkspace }
                )
                if !executionOnly {
                SettingsDestinationRow(title: "Workspaces", detail: "Local, Mac, and Linux agent workspaces.",
                    icon: { DashboardLucideIcon(glyph: .panelsTopLeft, size: 15) }, action: { section = .workspaces })
                }
                if !executionOnly && clientContext == nil {
                SettingsDestinationRow(
                    title: "Remote agent workspaces",
                    detail: "Agents and files on remote Linux machines.",
                    icon: { DashboardLucideIcon(glyph: .container, size: 15) },
                    action: { section = .remoteWorkspaces }
                )
                }
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
                    title: "OpenCode",
                    detail: "Agent names and connections.",
                    icon: { DashboardHarnessLogoIcon(logo: .openCode, size: 15) },
                    action: { section = .openCode }
                )
                if !executionOnly {
                SettingsDestinationRow(
                    title: "Usage",
                    detail: "Accounts and usage tracking.",
                    icon: { DashboardLucideIcon(glyph: .barChart, size: 15) },
                    action: { section = .usage }
                )
                }
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
                ? remoteWorkspace.map { "\(runtimeKind.displayName) in \($0.name)." } ?? "\(runtimeKind.displayName) on this Mac."
                : "Conversation defaults and runtime settings.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            SettingsAgentDefaultsSection(model: model, runtime: runtimeKind,
                fixedScope: isWorkspaceScoped ? workspaceID?.uuidString.lowercased() ?? "local" : nil)
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

import SwiftUI
import WovenMatterClient
import WovenMatterCore

enum SettingsSection: Equatable {
    case landing
    case general
    case openClaw
    case openCode
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
    @State private var navigationError: String?

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
            case .openClaw:
                SettingsOpenClawView(
                    model: model,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing },
                    onOpenAgent: { providerReturnSection = .openClaw; section = .openClawAgent($0) }
                )
            case .openCode:
                SettingsOpenCodeView(model: model, reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = .landing })
            case .openCodeWorkspace(let workspaceID):
                SettingsOpenCodeView(model: model, workspaceID: workspaceID, isWorkspaceScoped: true,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = workspaceID == nil ? .localWorkspace : .remoteWorkspaces })
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
                    onMore: { section = $0 == .opencode ? .openCodeWorkspace(nil) : .openClawWorkspace(nil) }
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
                    onOpenOpenClawAgent: { configuration in
                        Task {
                            do {
                                let agentID = try await model.remoteOpenClawAgentID(for: configuration)
                                providerReturnSection = .openClawWorkspace(configuration.id)
                                section = .openClawAgent(agentID)
                            } catch { navigationError = error.localizedDescription }
                        }
                    },
                    onMoreRuntime: { kind, configuration in
                        section = kind == .opencode ? .openCodeWorkspace(configuration.id) : .openClawWorkspace(configuration.id)
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
        .alert("Workspace unavailable", isPresented: Binding(get: { navigationError != nil }, set: { if !$0 { navigationError = nil } })) {
            Button("OK") { navigationError = nil }
        } message: { Text(navigationError ?? "") }
        .foregroundStyle(DashboardPalette.foreground)
        .environment(\.dashboardTheme, theme)
        .preferredColorScheme(.light)
        .tint(DashboardPalette.primary)
        .task {
            model.refreshLocalACPRuntimesNow()
        }
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
                    title: "OpenClaw",
                    detail: "Gateway connections and Woven Matter names for every OpenClaw agent.",
                    icon: { DashboardHarnessLogoIcon(logo: .openClaw, size: 15) },
                    action: { section = .openClaw }
                )
                SettingsDestinationRow(
                    title: "OpenCode",
                    detail: "The local OpenCode v2 service and browser connection.",
                    icon: { DashboardHarnessLogoIcon(logo: .openCode, size: 15) },
                    action: { section = .openCode }
                )
                SettingsDestinationRow(
                    title: "Local Agent Workspace",
                    detail: "Direct CLI and ACP sessions, runtimes, and workspace folders.",
                    icon: { DashboardLucideIcon(glyph: .terminal, size: 15) },
                    action: { section = .localWorkspace }
                )
                SettingsDestinationRow(
                    title: "Remote Agent Workspaces",
                    detail: "Standalone Linux workspaces deployed through SSH.",
                    icon: { DashboardLucideIcon(glyph: .container, size: 15) },
                    action: { section = .remoteWorkspaces }
                )
                SettingsDestinationRow(
                    title: "Buzz Agent Workspaces",
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
}

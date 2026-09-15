import SwiftUI
import WovenMatterClient
import WovenMatterCore

enum SettingsSection: Equatable {
    case landing
    case general
    case harness(AgentRuntimeKind, UUID?)
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
            case .harness(let runtimeKind, let workspaceID):
                SettingsHarnessView(
                    model: model,
                    runtimeKind: runtimeKind,
                    workspaceID: workspaceID,
                    reservesRailControlSpace: reservesRailControlSpace,
                    onBack: { section = workspaceID == nil ? .landing : .remoteWorkspaces }
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
                    onMore: { section = harnessSettingsSection($0, workspaceID: nil) }
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
                        section = harnessSettingsSection(kind, workspaceID: configuration.id)
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
                    action: { section = .harness(.codex, nil) }
                )
                SettingsDestinationRow(
                    title: "Claude Code",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .claude, size: 15) },
                    action: { section = .harness(.claudeCode, nil) }
                )
                SettingsDestinationRow(
                    title: "Grok Build",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .grok, size: 15) },
                    action: { section = .harness(.grokBuild, nil) }
                )
                SettingsDestinationRow(
                    title: "Cursor",
                    detail: "Local runtime status and workspace settings.",
                    icon: { DashboardHarnessLogoIcon(logo: .cursor, size: 15) },
                    action: { section = .harness(.cursor, nil) }
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
                    action: { section = .harness(.pi, nil) }
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
        workspaceID: UUID?
    ) -> SettingsSection {
        switch runtimeKind {
        case .openclaw: .openClawWorkspace(workspaceID)
        case .hermes: .hermesWorkspace(workspaceID)
        case .opencode: .openCodeWorkspace(workspaceID)
        default: .harness(runtimeKind, workspaceID)
        }
    }
}

private struct SettingsHarnessView: View {
    @Bindable var model: ApplicationModel
    let runtimeKind: AgentRuntimeKind
    var workspaceID: UUID?
    var reservesRailControlSpace = false
    let onBack: () -> Void

    private var availability: LocalACPRuntimeAvailability? {
        model.localACPRuntimeAvailability.first { $0.runtimeKind == runtimeKind }
    }

    private var remoteWorkspace: RemoteWorkspaceConfiguration? {
        workspaceID.flatMap { model.remoteWorkspaces.configuration(id: $0) }
    }

    private var remoteRuntime: RemoteRuntimeMaintenance? {
        guard let workspaceID else { return nil }
        return model.remoteWorkspaces.runtimeMaintenance[workspaceID]?.first {
            $0.id == runtimeKind
        }
    }

    private var remoteHarness: RemoteHarnessStatus? {
        guard let remoteWorkspace else { return nil }
        return model.remoteWorkspaces.currentHarnesses(for: remoteWorkspace).first {
            $0.id == runtimeKind
        }
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
            SettingsCard(
                title: workspaceID == nil
                    ? "Local agent workspace"
                    : remoteWorkspace?.name ?? "Remote agent workspace"
            ) {
                SettingsInset {
                    HStack(alignment: .center, spacing: 12) {
                        DashboardHarnessLogoIcon(
                            logo: DashboardHarnessLogo(runtimeKind: runtimeKind),
                            size: 24
                        )
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(runtimeKind.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Text(runtimeDetail)
                                .font(.system(size: 11))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        SettingsPill(
                            runtimeStatus,
                            tone: runtimeIsReady ? .neutral : .warning
                        )
                    }
                }
            }
        }
    }

    private var runtimeIsReady: Bool {
        if workspaceID != nil {
            return remoteHarness?.state == "ready"
        }
        return !model.checkingLocalACPRuntimeKinds.contains(runtimeKind)
            && availability?.isReady == true
            && model.isLocalACPAgentReady(runtimeKind)
    }

    private var runtimeStatus: String {
        if let workspaceID {
            if model.remoteWorkspaces.checkingRuntimeIDs[workspaceID]?.contains(runtimeKind) == true {
                return "Checking"
            }
            return remoteHarness?.state
                .replacingOccurrences(of: "_", with: " ")
                .capitalized ?? "Not checked"
        }
        if model.checkingLocalACPRuntimeKinds.contains(runtimeKind) {
            return "Checking"
        }
        if !model.isLocalACPRuntimeCredentialAccessEnabled(runtimeKind),
           availability?.executablePath != nil {
            return "Not enabled"
        }
        if availability?.isReady == true, !model.isLocalACPAgentReady(runtimeKind) {
            return "Workspace unavailable"
        }
        guard let availability else { return "Checking" }
        return switch availability.state {
        case .ready: "Ready"
        case .cliMissing: "CLI required"
        case .adapterMissing: "Adapter required"
        case .adapterOutdated: "Update required"
        case .authenticationRequired: "Sign in required"
        case .executableUnavailable: "Setup required"
        }
    }

    private var runtimeDetail: String {
        if workspaceID != nil {
            guard let remoteRuntime else { return "Runtime inventory unavailable." }
            return remoteRuntime.components.map { component in
                let installed = component.installed
                    ? component.installedVersion ?? "version unavailable"
                    : "missing"
                let newer = component.availableUpdateVersion.map { " → \($0)" } ?? ""
                return "\(component.displayName) \(installed)\(newer)"
            }.joined(separator: " · ")
        }
        if let inventory = model.runtimeInventories[runtimeKind] {
            return inventory.summary
        }
        return availability?.detail ?? "Checking the local runtime…"
    }
}

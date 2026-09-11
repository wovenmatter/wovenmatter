import SwiftUI
import WovenMatterCore

struct SettingsOpenClawView: View {
    @Bindable var model: ApplicationModel
    var workspaceID: UUID?
    var isWorkspaceScoped = false
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onOpenAgent: (UUID) -> Void
    @State private var instanceError: String?

    private var openClawAgents: [WorkspaceAgent] {
        (isWorkspaceScoped && workspaceID != nil ? [] : model.localCLIAgents)
            .filter { $0.runtimeKind == .openclaw }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        SettingsPage(
            title: "OpenClaw",
            detail: "Independent OpenClaw settings for this Mac and each remote workspace.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            if !isWorkspaceScoped || workspaceID == nil {
            SettingsCard(
                title: "Local Agent Workspace",
                detail: "Open an agent to manage its Woven Matter name and Gateway connection."
            ) {
                if openClawAgents.isEmpty {
                    SettingsEmpty("Enable local OpenClaw to configure its agent and Gateway connection.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(openClawAgents) { agent in
                            agentRow(agent)
                        }
                    }
                }
            }

            }
            ForEach(model.remoteWorkspaces.workspaces.filter { configuration in
                isWorkspaceScoped ? configuration.id == workspaceID
                    : model.remoteWorkspaces.isRuntimeEnabled(.openclaw, in: configuration)
            }) { configuration in
                RemoteWorkspaceInstanceSettingsCard(model: model.remoteWorkspaces,
                    configuration: configuration, runtimeKind: .openclaw,
                    onOpenAgentSettings: {
                        Task {
                            do { onOpenAgent(try await model.remoteOpenClawAgentID(for: configuration)) }
                            catch { instanceError = error.localizedDescription }
                        }
                    })
            }
            if let instanceError { SettingsError(instanceError) }
            SettingsNote("Each workspace owns its connection and gateway controls. Buzz is managed separately.")
        }
        .task(id: openClawAgents.map(\.id)) {
            for agent in openClawAgents
            where model.isOpenClawGatewayLinked(agentID: agent.id) {
                await model.refreshOpenClawGatewayStatus(agentID: agent.id)
            }
        }
    }

    private func agentRow(_ agent: WorkspaceAgent) -> some View {
        SettingsInset {
            HStack(alignment: .center, spacing: 12) {
                DashboardHarnessLogoIcon(logo: .openClaw, size: 20)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(locationLabel(for: agent))
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsPill(
                    statusLabel(for: agent),
                    tone: model.openClawGatewayLink(agentID: agent.id)?.connectionStatus == .ready
                        ? .neutral
                        : .warning
                )

                Button("Settings") {
                    onOpenAgent(agent.id)
                }
                .buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }

    private func statusLabel(for agent: WorkspaceAgent) -> String {
        if let link = model.openClawGatewayLink(agentID: agent.id) {
            return link.connectionStatus.label
        }
        return "Not linked"
    }

    private func locationLabel(for agent: WorkspaceAgent) -> String {
        switch model.openClawGatewayLink(agentID: agent.id)?.location {
        case .buzzLocal: "Local Buzz workspace"
        case .localAgentWorkspace: "Local Agent Workspace"
        case .remoteWorkspace: "Remote workspace"
        case nil: "Discovered OpenClaw"
        }
    }
}

struct SettingsOpenClawAgentView: View {
    @Bindable var model: ApplicationModel
    let agentID: UUID
    var reservesRailControlSpace = false
    var onBack: () -> Void

    private var agent: WorkspaceAgent? {
        (model.localCLIAgents + model.remoteWorkspaceAgents + model.buzzWorkspaceAgents)
            .first { $0.id == agentID }
    }

    var body: some View {
        SettingsPage(
            title: agent?.displayName ?? "OpenClaw",
            detail: "Woven Matter name and live Gateway connection for this agent.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            if let agent {
                OpenClawGatewayAgentSettingsView(model: model, agent: agent)
            } else {
                SettingsEmpty("This agent is no longer available.")
            }
        }
    }
}

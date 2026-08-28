import SwiftUI
import WovenMatterCore

struct SettingsOpenClawView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onOpenAgent: (UUID) -> Void

    private var openClawAgents: [WorkspaceAgent] {
        (model.localCLIAgents + model.remoteWorkspaceAgents + model.buzzWorkspaceAgents)
            .filter { $0.runtimeKind == .openclaw }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        SettingsPage(
            title: "OpenClaw",
            detail: "Every OpenClaw Woven Matter can reach, and its gateway connection on this Mac.",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            SettingsCard(
                title: "Agents",
                detail: "Open an agent to manage its Woven Matter name and Gateway connection."
            ) {
                if openClawAgents.isEmpty {
                    SettingsEmpty("No OpenClaw agents discovered yet. Local and Buzz workspace agents appear here when available.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(openClawAgents) { agent in
                            agentRow(agent)
                        }
                    }
                }
            }

            SettingsNote("Local and Buzz workspace OpenClaws can be linked by hand. Link state belongs only to this Mac.")
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

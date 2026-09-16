import SwiftUI
import WovenMatterClient
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
                    title: "Local agent workspace",
                    detail: "Open an agent to manage its Woven Matter name and Gateway connection."
                ) {
                    if openClawAgents.isEmpty {
                        SettingsEmpty("No OpenClaw agents discovered.")
                    } else {
                        VStack(spacing: 8) {
                            ForEach(openClawAgents) { agent in
                                agentRow(agent)
                            }
                        }
                    }
                }
            }
            if !isWorkspaceScoped {
                let buzzAgents = model.buzzWorkspaceAgents.filter { $0.runtimeKind == .openclaw }
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                if !buzzAgents.isEmpty {
                    SettingsCard(title: "Buzz workspaces", detail: "Agent names and existing Gateway connections.") {
                        VStack(spacing: 8) {
                            ForEach(buzzAgents) { agent in agentRow(agent) }
                        }
                    }
                }
            }
            if !isWorkspaceScoped || workspaceID != nil {
                SettingsCard(title: "Remote agent workspaces", detail: "Discover agents in each connected workspace.") {
                    let configurations = model.remoteWorkspaces.workspaces.filter { !isWorkspaceScoped || $0.id == workspaceID }
                    if configurations.isEmpty { SettingsEmpty("No remote agent workspaces connected.") }
                    ForEach(configurations) { configuration in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(configuration.name).font(.system(size: 13, weight: .medium))
                            Text(configuration.hostName).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            let agents = model.remoteWorkspaceAgents.filter { $0.runtimeKind == .openclaw && $0.runtimeDeviceID == configuration.id }
                            if !agents.isEmpty {
                                ForEach(agents) { agent in agentRow(agent) }
                            } else if let harness = model.remoteWorkspaces.currentHarnesses(for: configuration).first(where: { $0.id == .openclaw && $0.installationStatus == "installed" }) {
                                SettingsInset {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("OpenClaw").font(.system(size: 13, weight: .medium))
                                            Text(remoteRuntimeDetail(configuration))
                                                .font(.system(size: 11))
                                                .foregroundStyle(DashboardPalette.mutedForeground)
                                        }
                                        Spacer()
                                        SettingsPill("Not connected", tone: .warning)
                                        SettingsRemoteRuntimeUpdateButton(
                                            model: model.remoteWorkspaces,
                                            harness: harness,
                                            configuration: configuration
                                        )
                                        Button("Settings") {
                                            Task {
                                                do { onOpenAgent(try await model.remoteOpenClawAgentID(for: configuration)) }
                                                catch { instanceError = error.localizedDescription }
                                            }
                                        }.buttonStyle(SettingsQuietButtonStyle())
                                    }
                                }
                            } else { SettingsEmpty("No OpenClaw agents discovered.") }
                            Button("Scan workspace") { model.remoteWorkspaces.refresh(configuration) }
                                .buttonStyle(SettingsQuietButtonStyle())
                                .disabled(model.remoteWorkspaces.busyWorkspaceIDs.contains(configuration.id))
                        }
                    }
                }
            }
            if let instanceError { SettingsError(instanceError) }
            SettingsNote("Each agent has its own connection and Gateway controls.")
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
                    if let detail = runtimeDetail(for: agent) {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsPill(
                    statusLabel(for: agent),
                    tone: model.openClawGatewayLink(agentID: agent.id)?.connectionStatus == .ready
                        ? .neutral
                        : .warning
                )

                runtimeUpdateButton(for: agent)

                Button("Settings") {
                    onOpenAgent(agent.id)
                }
                .buttonStyle(SettingsQuietButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func runtimeUpdateButton(for agent: WorkspaceAgent) -> some View {
        if agent.governingPlane == .remoteWorkspace {
            if let workspaceID = agent.runtimeDeviceID,
               let configuration = model.remoteWorkspaces.configuration(id: workspaceID),
               let harness = model.remoteWorkspaces.currentHarnesses(for: configuration).first(where: { $0.id == .openclaw }) {
                SettingsRemoteRuntimeUpdateButton(
                    model: model.remoteWorkspaces,
                    harness: harness,
                    configuration: configuration
                )
            }
        } else if model.openClawGatewayLink(agentID: agent.id)?.location != .buzzLocal {
            SettingsLocalRuntimeUpdateButton(model: model, runtimeKind: .openclaw)
        }
    }

    private func runtimeDetail(for agent: WorkspaceAgent) -> String? {
        if agent.governingPlane == .remoteWorkspace {
            return agent.runtimeDeviceID.flatMap { model.remoteWorkspaces.configuration(id: $0) }
                .map(remoteRuntimeDetail)
        }
        guard model.openClawGatewayLink(agentID: agent.id)?.location != .buzzLocal else { return nil }
        return model.runtimeInventories[.openclaw]?.summary ?? "Checking installed components…"
    }

    private func remoteRuntimeDetail(_ configuration: RemoteWorkspaceConfiguration) -> String {
        guard let runtime = model.remoteWorkspaces.runtimeMaintenance[configuration.id]?.first(where: { $0.id == .openclaw }) else {
            return "Runtime inventory unavailable."
        }
        return runtime.components.map {
            "\($0.displayName) \($0.installed ? $0.installedVersion ?? "version unavailable" : "missing")"
        }.joined(separator: " · ")
    }

    private func statusLabel(for agent: WorkspaceAgent) -> String {
        if let link = model.openClawGatewayLink(agentID: agent.id) {
            return link.connectionStatus.label
        }
        return "Not connected"
    }

    private func locationLabel(for agent: WorkspaceAgent) -> String {
        switch model.openClawGatewayLink(agentID: agent.id)?.location {
        case .buzzLocal: "Local Buzz workspace"
        case .localAgentWorkspace: "Local agent workspace"
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

import SwiftUI
import WovenMatterCore

struct OpenClawGatewayAgentSettingsView: View {
    @Bindable var model: ApplicationModel
    let agent: WorkspaceAgent

    @State private var agentName = ""

    private var link: OpenClawGatewayLink? {
        model.openClawGatewayLink(agentID: agent.id)
    }

    private var isBusy: Bool {
        model.openClawGatewayOperationAgentIDs.contains(agent.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionCard
            nameCard
            if link != nil {
                OpenClawSessionLibrary(model: model, agentID: agent.id)
                    .id(agent.id)
                restartCard
            }
        }
        .onAppear { agentName = agent.displayName }
        .onChange(of: agent.displayName) { _, name in agentName = name }
        .task(id: link?.agentID) {
            guard link != nil else { return }
            await model.refreshOpenClawGatewayStatus(agentID: agent.id)
        }
    }

    private var connectionCard: some View {
        SettingsCard(
            title: "Gateway connection"
        ) {
            HStack(spacing: 10) {
                connectionIndicator
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.label)
                        .font(.system(size: 13, weight: .semibold))
                    if let statusDetail {
                        Text(statusDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
                Spacer(minLength: 12)
                connectionActions
            }

            if let link {
                SettingsValueRow(label: "Location", value: locationLabel)
                SettingsValueRow(
                    label: "Last checked",
                    value: link.updatedAt.formatted(date: .omitted, time: .standard)
                )
            }

            feedback
        }
    }

    private var nameCard: some View {
        SettingsCard(
            title: "Woven Matter name",
            detail: "This name is shown only in Woven Matter."
        ) {
            SettingsField("Agent name") {
                TextField("Agent name", text: $agentName)
                    .settingsInput()
            }
            Button("Save name") {
                model.renameOpenClawAgent(agentID: agent.id, displayName: agentName)
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(isBusy || agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var restartCard: some View {
        SettingsCard(title: "Gateway") {
            Button(status == .restarting ? "Restarting…" : "Restart Gateway") {
                model.restartOpenClawGateway(agentID: agent.id)
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var connectionActions: some View {
        if link == nil {
            Button("Link Gateway") { model.linkOpenClawGateway(agent: agent) }
                .buttonStyle(DashboardPrimaryButtonStyle())
                .disabled(isBusy)
        } else {
            Button("Reconnect") { model.reconnectOpenClawGateway(agentID: agent.id) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(isBusy)
            Button("Unlink") { model.unlinkOpenClawGateway(agentID: agent.id) }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = model.openClawGatewayErrors[agent.id] ?? link?.lastError {
            SettingsError(error)
        } else if let notice = model.openClawGatewayNotices[agent.id] {
            Text(notice)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DashboardPalette.mutedForeground)
        }
    }

    private var connectionIndicator: some View {
        Circle()
            .fill(status == .ready ? DashboardPalette.primary : indicatorColor)
            .frame(width: 9, height: 9)
            .overlay {
                if status == .connecting || status == .reconnecting
                    || status == .unlinking || status == .restarting {
                    ProgressView().controlSize(.mini).offset(x: 14)
                }
            }
            .frame(width: 28, alignment: .leading)
    }

    private var indicatorColor: Color {
        switch status {
        case .unavailable: DashboardPalette.danger
        case .notConnected: DashboardPalette.mutedForeground
        case .connecting, .reconnecting, .unlinking, .restarting: DashboardPalette.warning
        case .ready: DashboardPalette.primary
        }
    }

    private var status: OpenClawGatewayConnectionStatus {
        model.openClawGatewayOperationStatuses[agent.id]
            ?? link?.connectionStatus
            ?? .notConnected
    }

    private var statusDetail: String? {
        switch status {
        case .ready, .connecting, .reconnecting, .restarting, .notConnected: nil
        case .unlinking: "Removing the Gateway link from this Mac"
        case .unavailable: "Check that the Gateway is running, then reconnect."
        }
    }

    private var locationLabel: String {
        switch link?.location {
        case .buzzLocal: "Local Buzz workspace"
        case .localAgentWorkspace: "Local agent workspace"
        case .remoteWorkspace: "Remote workspace"
        case nil: "Discovered OpenClaw"
        }
    }
}

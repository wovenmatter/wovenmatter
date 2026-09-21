import SwiftUI
import WovenMatterCore

extension EnvironmentValues {
    @Entry var workspaceApplicationModel: ApplicationModel? = nil
    @Entry var openWorkspaceConversation: (String) -> Void = { _ in }
}

struct WorkspaceSessionIndicators: View {
    @Environment(\.workspaceApplicationModel) private var model
    let sessionID: String
    var body: some View {
        HStack(spacing: 5) {
            if model?.agentTools?.relationships[sessionID]?.coordinatorID != nil {
                Circle().fill(DashboardPalette.foreground).frame(width: 5, height: 5)
                    .help("Actively coordinated by another session").accessibilityLabel("Actively coordinated")
            }
            if model?.agentTools?.timers.contains(where: { $0.sessionID == sessionID && !$0.isPaused }) == true {
                Image(systemName: "timer").font(.system(size: 10)).foregroundStyle(DashboardPalette.foreground)
                    .help("Active timer").accessibilityLabel("Active timer")
            }
        }
    }
}

struct WorkspaceSessionProvenance: View {
    @Environment(\.workspaceApplicationModel) private var model
    @Environment(\.openWorkspaceConversation) private var open
    let sessionID: String
    var body: some View {
        if let tools = model?.agentTools {
            let relation = tools.relationships[sessionID]
            VStack(alignment: .leading, spacing: 7) {
                if let creator = relation?.createdBy { link("Created by", sessionID: creator) }
                if let coordinator = relation?.coordinatorID { link("Managed by", sessionID: coordinator) }
                let timers = tools.timers.filter { $0.sessionID == sessionID && !$0.isPaused }
                if !timers.isEmpty {
                    Label(timers.count == 1 ? "Active timer" : "\(timers.count) active timers", systemImage: "timer")
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.foreground)
                }
            }
        }
    }
    private func link(_ prefix: String, sessionID: String) -> some View {
        let title = model?.workspaceOverview?.conversations.first { $0.id == sessionID }?.title
        return Button { open(sessionID) } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "arrow.up.right").font(.system(size: 10))
                Text("\(prefix) \(title ?? "unavailable session")").lineLimit(2).multilineTextAlignment(.leading)
            }.font(.system(size: 12)).foregroundStyle(DashboardPalette.foreground)
        }.buttonStyle(.plain).disabled(title == nil)
    }
}

struct WorkspaceIncomingAgentHeader: View {
    @Environment(\.openWorkspaceConversation) private var open
    @Environment(\.workspaceApplicationModel) private var model
    let message: WorkspaceMessageRecord
    var body: some View {
        if let source = message.senderSessionID {
            let receipt = model?.agentTools?.receipts[message.conversationID]?.first { $0.messageID == message.id }
            let kind = message.senderKind ?? receipt?.kind
            if kind == .timer {
                Label("Timer", systemImage: "timer").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            } else {
                Button { open(source) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: kind == .notification ? "bell" : "arrow.down.left")
                        Text("\(kind == .notification ? "Update from" : "From") \(message.senderSessionTitle ?? "session")")
                            .lineLimit(2).multilineTextAlignment(.trailing)
                        if let harness = message.senderAgent {
                            Text(AgentRuntimeKind(rawValue: harness)?.displayName ?? harness)
                                .foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Image(systemName: "arrow.up.right")
                    }.font(.system(size: 11.5, weight: .medium)).foregroundStyle(DashboardPalette.foreground)
                }.buttonStyle(.plain).help("Open the session that sent this message")
            }
        }
    }
}

struct WorkspaceOutgoingReceipt: View {
    @Environment(\.workspaceApplicationModel) private var model
    @Environment(\.openWorkspaceConversation) private var open
    @Environment(\.dashboardTheme) private var theme
    let receipt: WorkspaceSessionDelivery
    @State private var expanded = false

    private var destination: WorkspaceConversationRecord? {
        model?.workspaceOverview?.conversations.first { $0.id == receipt.targetID }
    }
    private var modelName: String? {
        model?.openCodeModel(for: receipt.targetID)?.metadata(receipt.targetID)?.model
            ?? model?.localACPSessionMetadata[receipt.targetID]?.model ?? receipt.targetModel
    }
    private var sessionStatus: String {
        guard let model else { return "Unavailable" }
        let snapshot = model.openCodeModel(for: receipt.targetID)?.snapshots[receipt.targetID]
        if model.pendingLocalACPPermissions.contains(where: { $0.conversationID == receipt.targetID })
            || model.pendingLocalACPInteractions.contains(where: { $0.conversationID == receipt.targetID })
            || snapshot.map({ !$0.permissions.isEmpty || !$0.forms.isEmpty }) == true { return "Needs input" }
        if model.runningToolSessionIDs.contains(receipt.targetID) { return "Running" }
        if model.conversationState(for: receipt.targetID)?.error != nil { return "Needs attention" }
        return destination == nil ? "Unavailable" : "Idle"
    }

    private var deliveryStatus: String {
        switch receipt.status {
        case "accepted": "Sent"
        case "sending": "Sending"
        case "queued": "Queued"
        case "cancelled": "Not sent"
        case "failed": "Failed"
        case "uncertain": "Delivery unconfirmed"
        default: receipt.status.capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: receipt.kind == .created ? 10 : 6) {
            if receipt.kind == .created {
                Label("Created session", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { open(receipt.targetID) } label: {
                    HStack(spacing: 5) {
                        Text(destination?.title ?? receipt.targetTitle).lineLimit(2).multilineTextAlignment(.leading)
                        Image(systemName: "arrow.up.right").font(.system(size: 10))
                    }.font(.system(size: 13, weight: .medium))
                }.buttonStyle(.plain).help("Open destination session")
                Spacer(minLength: 8)
                Text(deliveryStatus).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { metadata }
                VStack(alignment: .leading, spacing: 3) { metadata }
            }.font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
            if receipt.kind == .created, let purpose = receipt.purpose, !purpose.isEmpty {
                Text(purpose).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if model?.agentTools?.relationships[receipt.targetID]?.coordinatorID == receipt.sourceID {
                    Text("Coordinated from this session").font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
            Text(receipt.text).font(.system(size: 12.5)).lineLimit(expanded ? nil : 3).textSelection(.enabled)
            if receipt.text.count > 180 || receipt.text.split(separator: "\n").count > 3 {
                Button(expanded ? "Show less" : "Show message") { expanded.toggle() }
                    .font(.system(size: 11)).buttonStyle(.plain)
            }
        }
        .foregroundStyle(DashboardPalette.foreground)
        .padding(receipt.kind == .created ? 14 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(receipt.kind == .created ? theme.palette.themeSoft : DashboardPalette.foreground.opacity(0.025),
            in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var metadata: some View {
        Text(AgentRuntimeKind(rawValue: receipt.targetHarness)?.displayName ?? receipt.targetHarness)
        if let modelName { Text(modelName).lineLimit(1) }
        Text(sessionStatus)
    }
}

/// Native commands can finish without producing a provider user-message ID.
/// Show the known incoming action without attributing an unrelated later message.
struct WorkspaceIncomingCommandReceipt: View {
    @Environment(\.openWorkspaceConversation) private var open
    let receipt: WorkspaceSessionDelivery

    private var outcome: String {
        switch receipt.status {
        case "accepted": "Command sent"
        case "uncertain": "Command delivery unconfirmed"
        case "failed", "cancelled": "Command not sent"
        case "queued": "Command queued"
        default: "Sending command"
        }
    }

    var body: some View {
        HStack {
            Spacer(minLength: 72)
            VStack(alignment: .trailing, spacing: 10) {
                if receipt.kind == .timer {
                    Label("Timer", systemImage: "timer")
                        .font(.system(size: 11.5, weight: .medium))
                } else {
                    Button { open(receipt.sourceID) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.left")
                            Text("From \(receipt.sourceTitle)").lineLimit(2).multilineTextAlignment(.trailing)
                            Text(AgentRuntimeKind(rawValue: receipt.sourceHarness)?.displayName ?? receipt.sourceHarness)
                                .foregroundStyle(DashboardPalette.mutedForeground)
                            Image(systemName: "arrow.up.right")
                        }.font(.system(size: 11.5, weight: .medium))
                    }.buttonStyle(.plain).help("Open the session that sent this command")
                }
                ConversationUserMessage(content: receipt.text, attachments: [], references: [])
                Text(outcome).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
        .foregroundStyle(DashboardPalette.foreground)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}

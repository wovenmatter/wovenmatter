import SwiftUI

extension EnvironmentValues {
    @Entry var workspaceApplicationModel: ApplicationModel? = nil
    @Entry var openWorkspaceConversation: (String) -> Void = { _ in }
}

struct WorkspaceSessionIndicators: View {
    @Environment(\.workspaceApplicationModel) private var model
    let sessionID: String
    var body: some View {
        HStack(spacing: 5) {
            if model?.agentTools.timers.contains(where: { $0.sessionID == sessionID && !$0.isPaused }) == true {
                Image(systemName: "timer").font(.system(size: 10)).foregroundStyle(WovenPalette.foreground)
                    .help("Active timer").accessibilityLabel("Active timer")
            }
        }
    }
}

struct WorkspaceSessionProvenance: View {
    @Environment(\.workspaceApplicationModel) private var model
    let sessionID: String
    var body: some View {
        if let tools = model?.agentTools {
            let timers = tools.timers.filter { $0.sessionID == sessionID && !$0.isPaused }
            if !timers.isEmpty {
                Label(timers.count == 1 ? "Active timer" : "\(timers.count) active timers", systemImage: "timer")
                    .font(.system(size: 12)).foregroundStyle(WovenPalette.foreground)
            }
        }
    }
}

struct WorkspaceIncomingAgentHeader: View {
    @Environment(\.openWorkspaceConversation) private var open
    @Environment(\.workspaceApplicationModel) private var model
    let message: WorkspaceMessageRecord
    var body: some View {
        if let source = message.senderSessionID {
            let kind = message.senderKind
            if kind == .goal {
                HStack(spacing: 5) { LucideIcon(glyph: .compass, size: 12); Text("Goal continuation") }
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(WovenPalette.mutedForeground)
            } else if kind == .timer {
                Label("Timer", systemImage: "timer").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(WovenPalette.mutedForeground)
            } else {
                Button { open(source) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.left")
                        Text("From \(message.senderSessionTitle ?? "session")")
                            .lineLimit(2).multilineTextAlignment(.trailing)
                        if let harness = message.senderAgent {
                            Text(AgentRuntimeKind(rawValue: harness)?.displayName ?? harness)
                                .foregroundStyle(WovenPalette.mutedForeground)
                        }
                        Image(systemName: "arrow.up.right")
                    }.font(.system(size: 11.5, weight: .medium)).foregroundStyle(WovenPalette.foreground)
                }.buttonStyle(.plain).help("Open the session that sent this message")
            }
        }
    }
}

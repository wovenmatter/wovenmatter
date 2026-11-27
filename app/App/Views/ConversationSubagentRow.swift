import SwiftUI

struct ConversationSubagentRow: View {
    let child: AgentRunSubagent
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { transcriptInteraction(); expanded = $0 })) {
            VStack(alignment: .leading, spacing: ConversationMetrics.rowGap) {
                if let task = child.task?.nonempty { textBlock("Task", task) }
                VStack(alignment: .leading, spacing: ConversationMetrics.hair) {
                    metadata("Model", child.modelID)
                    metadata("Provider", child.provider)
                    metadata("Connection", child.connectionLabel?.nonempty ?? child.connectionID)
                    metadata("Access", child.accessKind)
                    metadata("Thinking", child.thinking)
                }
                if let detail = child.detail?.nonempty { textBlock("Status", detail) }
                if let result = child.result?.nonempty { textBlock("Result", result) }
                if let activity = child.activity, !activity.isEmpty { entries("Activity", activity) }
                if let history = child.history, !history.isEmpty { entries("Recent Messages", history) }
            }
            .padding(.top, ConversationMetrics.rowGap)
            .padding(.leading, ConversationMetrics.tight)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: ConversationMetrics.rowGap) {
                Text(child.name?.nonempty ?? "Subagent")
                    .font(.system(size: 12.5, weight: .medium))
                if let label = child.statusLabel?.nonempty {
                    Text(label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(WovenPalette.foreground.opacity(0.72))
        }
    }

    @ViewBuilder
    private func metadata(_ label: String, _ value: String?) -> some View {
        if let value = value?.nonempty {
            Text("\(label): \(value)")
                .font(.system(size: 11.5))
                .foregroundStyle(WovenPalette.mutedForeground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func textBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: ConversationMetrics.hair) {
            Text(label).font(.system(size: 11.5, weight: .medium))
            Text(String(value.prefix(120_000)))
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(WovenPalette.mutedForeground)
    }

    private func entries(_ label: String, _ values: [AgentRunSubagentActivity]) -> some View {
        DisclosureGroup(label) {
            VStack(alignment: .leading, spacing: ConversationMetrics.rowGap) {
                ForEach(values) { entry in
                    VStack(alignment: .leading, spacing: ConversationMetrics.hair) {
                        Text(entry.title?.nonempty ?? entry.kind?.capitalized ?? "Activity")
                            .font(.system(size: 11.5, weight: .medium))
                        if let status = entry.status?.nonempty { metadata("Status", status) }
                        if let content = entry.content?.nonempty {
                            Text(String(content.prefix(120_000)))
                                .font(.system(size: 12.5))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, ConversationMetrics.tight)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(WovenPalette.mutedForeground)
    }
}

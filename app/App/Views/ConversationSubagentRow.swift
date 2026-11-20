import SwiftUI

private struct ConversationArchiveConversationKey: EnvironmentKey {
    static let defaultValue = ""
}

private struct ConversationSubagentHistoryKey: EnvironmentKey {
    static let defaultValue: (@MainActor (SubagentArchiveRequest) async throws -> SubagentArchivePage)? = nil
}

extension EnvironmentValues {
    var conversationArchiveConversationID: String {
        get { self[ConversationArchiveConversationKey.self] }
        set { self[ConversationArchiveConversationKey.self] = newValue }
    }
    var conversationSubagentHistory: (@MainActor (SubagentArchiveRequest) async throws -> SubagentArchivePage)? {
        get { self[ConversationSubagentHistoryKey.self] }
        set { self[ConversationSubagentHistoryKey.self] = newValue }
    }
}

struct ConversationSubagentRow: View {
    let child: AgentRunSubagent
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { transcriptInteraction(); expanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                if let task = child.task?.nonempty { textBlock("Task", task) }
                VStack(alignment: .leading, spacing: 3) {
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
                if let sourceID = child.sourceID,
                   let nativeSessionID = child.nativeSessionID,
                   let nativeConversationID = child.nativeConversationID {
                    ConversationSubagentHistory(sourceID: sourceID, nativeSessionID: nativeSessionID,
                        nativeConversationID: nativeConversationID)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
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
        VStack(alignment: .leading, spacing: 3) {
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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(values) { entry in
                    VStack(alignment: .leading, spacing: 3) {
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
            .padding(.top, 5)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(WovenPalette.mutedForeground)
    }
}

private struct ConversationSubagentHistory: View {
    let sourceID: String
    let nativeSessionID: String
    let nativeConversationID: String
    @Environment(\.conversationArchiveConversationID) private var conversationID
    @Environment(\.conversationSubagentHistory) private var loadHistory
    @State private var expanded = false
    @State private var rows: [SubagentArchiveRecord] = []
    @State private var cursor: Int64 = 0
    @State private var hasMore = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if loadHistory != nil {
            DisclosureGroup("History", isExpanded: $expanded) {
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows) { row in
                            ConversationSubagentArchiveEvent(request: request(eventID: row.id), record: row)
                        }
                        if let error { Text(error).foregroundStyle(WovenPalette.danger).textSelection(.enabled) }
                        if hasMore {
                            Button(rows.isEmpty ? "Load history" : "Load more history") { Task { await loadNextPage() } }
                                .buttonStyle(WovenQuietButtonStyle())
                                .disabled(busy)
                        }
                        if busy { Text("Loading history…") }
                    }.padding(.top, 5)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(WovenPalette.mutedForeground)
        }
    }

    private func request(eventID: String? = nil) -> SubagentArchiveRequest {
        .init(conversationID: conversationID, sourceID: sourceID,
            nativeSessionID: nativeSessionID, nativeConversationID: nativeConversationID,
            after: cursor, eventID: eventID)
    }

    @MainActor private func loadNextPage() async {
        guard !busy, let loadHistory else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let page = try await loadHistory(request())
            rows.append(contentsOf: page.records)
            hasMore = page.hasMore
            cursor = page.nextCursor
        } catch { self.error = error.localizedDescription }
    }
}

private struct ConversationSubagentArchiveEvent: View {
    let request: SubagentArchiveRequest
    let record: SubagentArchiveRecord
    @Environment(\.conversationSubagentHistory) private var loadHistory
    @State private var chunks: [String] = []
    @State private var offset = 0
    @State private var hasMore = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        DisclosureGroup(record.kind ?? "Native record") {
            VStack(alignment: .leading, spacing: 6) {
                if let text = record.text, !text.isEmpty {
                    Text(text).font(.system(size: 12.5)).textSelection(.enabled)
                }
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    Text(chunk).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                }
                if let error { Text(error).foregroundStyle(WovenPalette.danger).textSelection(.enabled) }
                if hasMore {
                    Button(chunks.isEmpty ? "Read native record" : "Read more") { Task { await loadNextChunk() } }
                        .buttonStyle(WovenQuietButtonStyle()).disabled(busy)
                }
                if busy { Text("Loading record…") }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
    }

    @MainActor private func loadNextChunk() async {
        guard !busy, let loadHistory else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var next = request; next.offset = offset
            let page = try await loadHistory(next)
            guard let row = page.records.first else {
                throw WorkspaceToolError.notFound("The native record is unavailable.")
            }
            chunks.append(row.payload ?? "")
            hasMore = row.payloadHasMore
            offset += 65536
        } catch { self.error = error.localizedDescription }
    }
}

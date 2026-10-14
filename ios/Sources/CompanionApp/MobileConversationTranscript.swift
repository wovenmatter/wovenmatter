import SwiftUI
import WovenMatterCompanion

/// Adapts transport records to the same run timeline and native response views
/// used by the desktop. No native SDK content is interpreted inside a View.
struct MobileConversationTranscript: View {
  let transcript: CompanionTranscript
  let disclosureState: ConversationTranscriptState
  let loadDetails: @MainActor (String) async throws -> AgentRunActivity?

  var body: some View {
    let rows = MobileConversationProjection.rows(transcript)
    ForEach(rows) { row in
      switch row.content {
      case .message(let message):
        HStack {
          Spacer(minLength: 40)
          ConversationUserBubble(content: message.content) { EmptyView() }
        }
      case .turn(let turn):
        VStack(alignment: .leading, spacing: 18) {
          ConversationWorkTranscript(run: turn.run, presentation: turn.presentation,
            records: turn.records, commentaryIDs: turn.commentaryIDs,
            hasFinalReply: !turn.content.isEmpty, timeline: turn.timeline)
          if !turn.content.isEmpty {
            ConversationResponse(content: turn.content, isStreaming: turn.isStreaming)
              .padding(.horizontal, 4).padding(.vertical, 2)
          }
          ConversationChangedFilesCard(records: turn.records)
        }
        .environment(\.conversationTranscriptState, disclosureState)
        .environment(\.conversationActivityDetails, { runID, activityID in
          if let full = try await loadDetails(activityID) { return full }
          return turn.records.last { $0.runID == runID && $0.activity.id == activityID }?.activity
        })
      }
    }
  }
}

struct MobileConversationProjection {
  struct Row: Identifiable {
    enum Content { case message(CompanionMessage), turn(Turn) }
    let id: String
    let content: Content
  }
  struct Turn {
    let run: ConversationWorkRun
    let presentation: ConversationWorkPresentation
    let records: [WorkspaceRunActivityRecord]
    let commentaryIDs: Set<String>
    let timeline: ConversationWorkTimeline
    let content: String
    let isStreaming: Bool
  }

  static func rows(_ transcript: CompanionTranscript) -> [Row] {
    var rows: [Row] = []
    var seen: Set<String> = []
    let messages = transcript.messages
    let runIDs = Dictionary((transcript.runs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
    func appendTurn(_ runID: String) {
      guard seen.insert(runID).inserted else { return }
      let runMessages = messages.filter { ($0.runID ?? $0.id) == runID && $0.role != "user" }
      let source = transcript.activities.filter { $0.runID == runID }
      let info = runIDs[runID]
      let isRunning = info?.status == "running" || transcript.activeRunID == runID
      var records: [WorkspaceRunActivityRecord] = source.enumerated().map { offset, activity in
        let projected = activity.projectionJSON.flatMap { try? JSONDecoder().decode(AgentRunActivity.self, from: Data($0.utf8)) }
          ?? AgentRunActivity(id: activity.id, kind: .tool, title: activity.title,
            status: activity.status, content: activity.detail)
        return .init(id: activity.id, runID: runID, conversationID: transcript.conversationID,
          activity: projected, createdAt: activity.createdAt ?? "", sequence: activity.sequence ?? Int64(offset))
      }
      // Text before subsequent work belongs inside its chronological work log.
      // Multiple text blocks after the final tool are one selectable response.
      let lastWork = source.compactMap(\.sequence).max()
      var reply: [CompanionMessage] = []
      var commentaryIDs: Set<String> = []
      for (index, message) in runMessages.enumerated() {
        if message.role == "tool" || message.role == "toolResult" {
          let activity = AgentRunActivity(id: message.id, kind: .tool, title: "Tool result",
            status: "completed", content: message.content)
          records.append(.init(id: message.id, runID: runID, conversationID: transcript.conversationID,
            activity: activity, createdAt: message.createdAt, sequence: message.sequence ?? Int64(index)))
        } else if let lastWork, let order = message.sequence, order < lastWork {
          let activity = AgentRunActivity(id: message.id, kind: .assistant, content: message.content, position: Int(order))
          records.append(.init(id: message.id, runID: runID, conversationID: transcript.conversationID,
            activity: activity, createdAt: message.createdAt, sequence: order))
          commentaryIDs.insert(message.id)
        } else { reply.append(message) }
      }
      let start = parsedDate(info?.startedAt ?? runMessages.first?.createdAt)
      let end = parsedDate(info?.completedAt ?? runMessages.last?.createdAt)
      let duration = start.flatMap { start in end.map { dashboardRunDuration($0.timeIntervalSince(start)) } }
      let status = isRunning ? "running" : (info?.status ?? (runMessages.last?.status == "error" ? "failed" : "completed"))
      let content = reply.map(\.content).joined(separator: "\n\n")
      let error = status == "failed" && content.isEmpty ? source.last(where: { $0.status == "failed" })?.detail : nil
      let turn = Turn(run: .init(id: runID, conversationID: transcript.conversationID, status: status, error: error),
        presentation: .init(startedAt: start, completedDuration: duration), records: records,
        commentaryIDs: commentaryIDs, timeline: .init(records: records, commentaryIDs: commentaryIDs),
        content: content, isStreaming: reply.last?.status == "streaming")
      rows.append(.init(id: "turn:" + runID, content: .turn(turn)))
    }
    for message in messages {
      if message.role == "user" {
        rows.append(.init(id: message.id, content: .message(message)))
        // Native turn ownership is explicit; this places tools before a reply
        // even when the agent has not emitted any assistant text yet.
        if let runID = message.runID, runIDs[runID] != nil { appendTurn(runID) }
      } else { appendTurn(message.runID ?? message.id) }
    }
    for activity in transcript.activities { appendTurn(activity.runID) }
    for run in transcript.runs ?? [] { appendTurn(run.id) }
    return rows
  }

  private static func parsedDate(_ text: String?) -> Date? {
    guard let text, !text.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: text)
  }
}

/// The model retains these UI choices across chat switches and tab navigation.
@MainActor
final class MobileConversationStates {
  private var values: [String: ConversationTranscriptState] = [:]
  func state(for conversationID: String) -> ConversationTranscriptState {
    if let value = values[conversationID] { return value }
    let value = ConversationTranscriptState()
    values[conversationID] = value
    return value
  }
}

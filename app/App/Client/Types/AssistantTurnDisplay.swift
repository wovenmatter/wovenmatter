import Foundation

/// What an assistant turn draws from its reply and its run's records: the
/// reply's text apart from the commentary the work log shows, that
/// commentary, the work timeline, and how the reply opens. Each is worked
/// out once for each change of the reply or the records
/// (`AssistantTurnDisplays`), not on every pass of the transcript.
struct AssistantTurnDisplay {
  /// The reply's text, apart from the commentary the work log shows.
  let body: String
  let commentaryIDs: Set<String>
  let timeline: ConversationWorkTimeline
  /// The run's activities in its records' order, from which the folder of
  /// its first path is read.
  let orderedActivities: [AgentRunActivity]
  /// The reply as drawn: `body`, or its ready part while it streams.
  let reply: String
  /// The reply has text to show below the work.
  let hasResponseText: Bool
  /// The reply opens with a box: fenced code or a table.
  let replyStartsWithBox: Bool

  /// `earlier`, worked out for the same records, lends its timeline when the
  /// commentary is the same, as it is while the reply streams on.
  init(messageID: String, content: String, isStreaming: Bool, records: [WorkspaceRunActivityRecord],
       earlier: AssistantTurnDisplay? = nil) {
    let work = records.map(\.activity)
    let partition = ConversationWorkTimeline.displayPartition(
      AssistantTranscriptProjection(messageID: messageID, content: content, activities: work), activities: work)
    body = partition.body
    commentaryIDs = partition.commentaryIDs
    if let earlier, earlier.commentaryIDs == partition.commentaryIDs {
      timeline = earlier.timeline
      orderedActivities = earlier.orderedActivities
    } else {
      timeline = ConversationWorkTimeline(records: records, commentaryIDs: partition.commentaryIDs)
      orderedActivities = records.sorted(by: WorkspaceRunActivityRecord.precedes).map(\.activity)
    }
    reply = isStreaming ? AssistantStreamingText.readyPrefix(of: partition.body) : partition.body
    hasResponseText = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    replyStartsWithBox = Self.startsWithBox(reply)
  }

  /// Whether reply text opens with a box: fenced code or a table.
  static func startsWithBox(_ text: String) -> Bool {
    guard let first = text.split(whereSeparator: \.isNewline).first(where: {
      !$0.trimmingCharacters(in: .whitespaces).isEmpty
    })?.trimmingCharacters(in: .whitespaces) else { return false }
    return first.hasPrefix("```") || first.hasPrefix("~~~") || first.hasPrefix("|")
  }
}

/// Each shown assistant turn's display, kept for the few chats shown last,
/// so a pass of the transcript, a page of older messages and a return to a
/// chat use what was worked out before. A turn's display is kept while its
/// reply and its run's records are the same, apart from where the message
/// window puts the records; when only the reply changed, its timeline is
/// kept too.
@MainActor
enum AssistantTurnDisplays {
  private final class Entry {
    var content: String
    var isStreaming: Bool
    var records: [WorkspaceRunActivityRecord]
    var display: AssistantTurnDisplay

    init(content: String, isStreaming: Bool, records: [WorkspaceRunActivityRecord], display: AssistantTurnDisplay) {
      self.content = content
      self.isStreaming = isStreaming
      self.records = records
      self.display = display
    }
  }

  private final class Session {
    var turns = WorkTimelineGenerations<String, Entry>(
      limit: AssistantTurnDisplays.turnLimit, costLimit: AssistantTurnDisplays.sessionGenerationBytes)
  }

  /// A chat keeps at most twice this many turns.
  nonisolated static let turnLimit = 1_024
  /// A chat's turns hold at most about twice this many bytes: tool output
  /// can be large, and a chat let go must not stay in memory through it.
  nonisolated static let sessionGenerationBytes = 16 * 1_024 * 1_024
  /// All kept chats' turns hold about this many bytes at most, beyond the
  /// chat shown last: the chats shown longest ago go first.
  static let totalBytes = 64 * 1_024 * 1_024
  /// The chats whose turns are kept: those shown most recently.
  static let sessionLimit = 6
  private static var sessions: [String: Session] = [:]
  /// The kept chats, the one shown last at the end.
  private static var recent: [String] = []

  static func display(sessionID: String, messageID: String, content: String, isStreaming: Bool,
                      records: [WorkspaceRunActivityRecord]) -> AssistantTurnDisplay {
    let session = self.session(sessionID)
    if let entry = session.turns.value(messageID),
       WorkspaceRunActivityRecord.sameIgnoringWindow(entry.records, records) {
      // Compared with the copy at hand next time, which is quicker while it lasts.
      entry.records = records
      // The same bytes, not only text that reads the same: the reply's file
      // links name library entries by their exact bytes.
      if WorkTimelineExactText(entry.content) == WorkTimelineExactText(content), entry.isStreaming == isStreaming {
        return entry.display
      }
      entry.display = AssistantTurnDisplay(messageID: messageID, content: content, isStreaming: isStreaming,
                                           records: records, earlier: entry.display)
      entry.content = content
      entry.isStreaming = isStreaming
      session.turns.insert(messageID, entry, cost: cost(content: content, records: records))
      trim(keeping: sessionID)
      return entry.display
    }
    let display = AssistantTurnDisplay(messageID: messageID, content: content, isStreaming: isStreaming, records: records)
    session.turns.insert(messageID, Entry(content: content, isStreaming: isStreaming, records: records, display: display),
                         cost: cost(content: content, records: records))
    trim(keeping: sessionID)
    return display
  }

  /// About how many bytes a kept turn holds: its records, and its reply's
  /// text as the message, the display's body and the reply drawn hold it.
  private static func cost(content: String, records: [WorkspaceRunActivityRecord]) -> Int {
    1_024 + 3 * content.utf8.count + records.reduce(0) { $0 + 256 + $1.activity.workTimelineRetainedBytes }
  }

  /// Lets the chats shown longest ago go while all kept turns hold more than `totalBytes`.
  private static func trim(keeping current: String) {
    var total = sessions.values.reduce(0) { $0 + $1.turns.cost }
    while total > totalBytes, let oldest = recent.first, oldest != current {
      recent.removeFirst()
      total -= sessions.removeValue(forKey: oldest)?.turns.cost ?? 0
    }
  }

  private static func session(_ id: String) -> Session {
    if recent.last != id {
      recent.removeAll { $0 == id }
      recent.append(id)
      if recent.count > sessionLimit { sessions[recent.removeFirst()] = nil }
    }
    if let session = sessions[id] { return session }
    let session = Session()
    sessions[id] = session
    return session
  }
}

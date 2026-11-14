import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

/// A conversation's `LibraryTranscript` is built from its rows: messages,
/// run activities, the runs its execution owner listed, and the active run
/// that owner reported (`execution_conversations.active_run_id`). Rows an
/// execution owner's projection wrote carry what its transcript said (see
/// `coreTablesSQL`); rows this Mac wrote are presented as they always were:
/// a user prompt in its display form, and an activity by its title, detail
/// and status.
extension WorkspaceDatabaseConnection {
  /// Messages in transcript order: the owner's sequence first, then the
  /// order the transcript first listed each one. Rows without a position
  /// (this Mac's, from before the conversation moved to its owner) come
  /// first, in the order they were written.
  static let transcriptMessageOrder = "sequence IS NULL, sequence, position IS NOT NULL, position, created_at, id"
  static let transcriptActivityOrder = "position IS NOT NULL, position, created_at, id"

  /// The whole transcript of a conversation.
  func libraryTranscriptUnlocked(_ conversationID: String) throws -> LibraryTranscript {
    LibraryTranscript(conversationID: conversationID,
      messages: try transcriptMessagesUnlocked(conversationID, offset: 0, limit: -1),
      activities: try transcriptActivitiesUnlocked(conversationID, offset: 0, limit: -1),
      activeRunID: try libraryIDsUnlocked("SELECT active_run_id FROM execution_conversations WHERE id=? AND active_run_id IS NOT NULL",
                                          bindings: [conversationID]).first,
      runs: try transcriptRunsUnlocked(conversationID))
  }

  func transcriptMessageCountUnlocked(_ conversationID: String) throws -> Int {
    Int(try federationScalarUnlocked("SELECT COUNT(*) FROM messages WHERE conversation_id=?", bindings: [conversationID]))
  }

  func transcriptActivityCountUnlocked(_ conversationID: String) throws -> Int {
    Int(try federationScalarUnlocked("SELECT COUNT(*) FROM run_activities WHERE conversation_id=?", bindings: [conversationID]))
  }

  /// `limit` messages from `offset` in transcript order; a negative limit is all of them.
  func transcriptMessagesUnlocked(_ conversationID: String, offset: Int, limit: Int) throws -> [LibraryMessage] {
    // Provenance the owner sent comes first; a delivery this Mac made names
    // the source of its own messages.
    func source(_ column: String) -> String {
      "COALESCE((SELECT \(column) FROM message_provenance WHERE message_id=m.id),(SELECT \(column) FROM session_deliveries WHERE message_id=m.id))"
    }
    let statement = try prepareUnlocked("""
      SELECT m.id,m.run_id,m.role,m.content,m.status,m.created_at,m.sequence,m.attachment_references,
        \(source("kind")),\(source("source_id")),\(source("source_title")),\(source("source_agent"))
      FROM messages m WHERE m.id IN (
        SELECT id FROM messages WHERE conversation_id=?1 ORDER BY \(Self.transcriptMessageOrder) LIMIT ?2 OFFSET ?3)
      ORDER BY \(Self.transcriptMessageOrder)
      """)
    defer { sqlite3_finalize(statement) }
    try bind(conversationID, at: 1, to: statement)
    sqlite3_bind_int64(statement, 2, Int64(limit)); sqlite3_bind_int64(statement, 3, Int64(offset))
    var messages: [LibraryMessage] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return messages }
      guard code == SQLITE_ROW else { throw stepError() }
      let role = try text(statement, column: 2), kind = optionalText(statement, column: 8)
      let source = optionalText(statement, column: 9)
      let content = try text(statement, column: 3), status = try text(statement, column: 4)
      messages.append(try LibraryMessage(id: text(statement, column: 0), conversationID: conversationID,
        runID: optionalText(statement, column: 1), role: role,
        content: role == "user" ? (kind == "goal" ? "Continuing toward the goal." : WorkspaceGoal.displayPrompt(content)) : content,
        status: status.isEmpty ? nil : status, createdAt: text(statement, column: 5),
        sequence: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6),
        agentSourceID: source, isAgentAuthored: source == nil ? nil : true,
        senderSessionTitle: optionalText(statement, column: 10), senderHarness: optionalText(statement, column: 11), senderKind: kind,
        attachments: optionalText(statement, column: 7).map { try JSONDecoder().decode([LibraryAttachmentReference].self, from: Data($0.utf8)) }))
    }
  }

  /// `limit` activities from `offset` in transcript order; a negative limit is all of them.
  func transcriptActivitiesUnlocked(_ conversationID: String, offset: Int, limit: Int) throws -> [LibraryActivity] {
    let statement = try prepareUnlocked("""
      SELECT id,run_id,content,title,detail,status,details_record_id,is_transient,sequence,created_at,completed_at
      FROM run_activities WHERE id IN (
        SELECT id FROM run_activities WHERE conversation_id=?1 ORDER BY \(Self.transcriptActivityOrder) LIMIT ?2 OFFSET ?3)
      ORDER BY \(Self.transcriptActivityOrder)
      """)
    defer { sqlite3_finalize(statement) }
    try bind(conversationID, at: 1, to: statement)
    sqlite3_bind_int64(statement, 2, Int64(limit)); sqlite3_bind_int64(statement, 3, Int64(offset))
    var activities: [LibraryActivity] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return activities }
      guard code == SQLITE_ROW else { throw stepError() }
      let id = try text(statement, column: 0), runID = try text(statement, column: 1), content = try text(statement, column: 2)
      if let title = optionalText(statement, column: 3) {
        let createdAt = try text(statement, column: 9)
        activities.append(LibraryActivity(id: id, runID: runID, title: title, detail: optionalText(statement, column: 4),
          status: optionalText(statement, column: 5) ?? "", projectionJSON: content, detailsRecordID: optionalText(statement, column: 6),
          isTransient: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 7) != 0,
          sequence: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 8),
          createdAt: createdAt.isEmpty ? nil : createdAt, completedAt: optionalText(statement, column: 10)))
      } else {
        let activity = try? JSONDecoder().decode(AgentRunActivity.self, from: Data(content.utf8))
        activities.append(LibraryActivity(id: id, runID: runID, title: activity?.title ?? activity?.kind.rawValue ?? "Activity",
          detail: activity?.detail ?? activity?.content ?? content, status: activity?.status ?? "completed"))
      }
    }
  }

  /// The runs the owner listed, in the order it first listed them; nil when it listed none.
  func transcriptRunsUnlocked(_ conversationID: String) throws -> [LibraryTranscriptRun]? {
    let statement = try prepareUnlocked("""
      SELECT id,status,started_at,completed_at,user_message_id,assistant_message_id FROM runs
      WHERE conversation_id=? AND position IS NOT NULL ORDER BY position
      """)
    defer { sqlite3_finalize(statement) }
    try bind(conversationID, at: 1, to: statement)
    var runs: [LibraryTranscriptRun] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return runs.isEmpty ? nil : runs }
      guard code == SQLITE_ROW else { throw stepError() }
      runs.append(try LibraryTranscriptRun(id: text(statement, column: 0), status: text(statement, column: 1),
        startedAt: optionalText(statement, column: 2), completedAt: optionalText(statement, column: 3),
        userMessageID: optionalText(statement, column: 4), assistantMessageID: optionalText(statement, column: 5)))
    }
  }
}

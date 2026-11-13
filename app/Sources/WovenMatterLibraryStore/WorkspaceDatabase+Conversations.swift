import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterClient
import WovenMatterCore

// Conversation metadata and read projections for messages, references and activity.
extension WorkspaceDatabaseConnection {
  public func workspaceRevision() throws -> Int64 {
    try withLock {
      let statement = try prepareUnlocked(
        "SELECT revision FROM workspace_revision WHERE singleton = 1"
      )
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
      return sqlite3_column_int64(statement, 0)
    }
  }

  @discardableResult
  public func markConversationRead(id: String) throws -> Bool {
    try transaction {
      let update = try prepareUnlocked("""
        UPDATE conversations
        SET unread = 0
        WHERE id = ? AND unread != 0 AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(update) }
      try bind(id, at: 1, to: update)
      try stepDone(update)
      return changedRowCountUnlocked == 1
    }
  }

  @discardableResult
  public func updateConversationTitleIfCurrent(
    id: String,
    expectedTitle: String,
    title: String,
    updatedAt: Date = Date()
  ) throws -> Bool {
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { return false }
    return try transaction {
      let authority = try prepareUnlocked("""
        SELECT 1
        FROM conversations
        WHERE id = ?
          AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(authority) }
      try bind(id, at: 1, to: authority)
      guard sqlite3_step(authority) == SQLITE_ROW else { return false }

      let timestamp = Self.timestamp(updatedAt)
      let conversation = try prepareUnlocked("""
        UPDATE conversations
        SET title = ?, updated_at = ?
        WHERE id = ? AND title = ? AND deleted_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM conversation_titles WHERE conversation_id = conversations.id)
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(cleanTitle, at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(id, at: 3, to: conversation)
      try bind(expectedTitle, at: 4, to: conversation)
      try stepDone(conversation)
      guard changedRowCountUnlocked == 1 else { return false }

      let session = try prepareUnlocked("""
        UPDATE harness_sessions
        SET title = ?, updated_at = ? WHERE conversation_id = ?
        """)
      defer { sqlite3_finalize(session) }
      try bind(cleanTitle, at: 1, to: session)
      try bind(timestamp, at: 2, to: session)
      try bind(id, at: 3, to: session)
      try stepDone(session)

      return true
    }
  }

  @discardableResult
  public func moveConversation(
    id: String,
    toFolderID folderID: String?,
    updatedAt: Date = Date()
  ) throws -> Bool {
    try transaction {
      // A draft's folder is its execution directory; only its executor moves it.
      try requireProtectedConversationMutationUnlocked(id)
      try validateFolderUnlocked(id: folderID)
      let root = try availableSessionExecutionRoot(id: id)
      guard             let row = try historyRowsUnlocked("SELECT folder_locked FROM session_execution_roots WHERE conversation_id=?", values: [id]).first?.objectValue,
            row["folder_locked"]?.intValue == 0,
            try historyRowsUnlocked("SELECT 1 FROM messages WHERE conversation_id=? AND role='user' LIMIT 1", values: [id]).isEmpty else {
        throw WorkspaceToolError.invalid("A chat's folder is fixed after its first message.")
      }
      let path: String
      if let folderID {
        guard let folder = try historyRowsUnlocked("SELECT * FROM folder_execution_roots WHERE folder_id=?", values: [folderID]).first?.objectValue,
              folder["workspace_id"]?.stringValue == root.workspaceID,
              let folderPath = folder["root_path"]?.stringValue else { throw WorkspaceToolError.invalid("Choose a folder in this agent's workspace.") }
        path = folderPath
      } else {
        // The default directory was captured at creation, not inferred on another device.
        guard let defaultPath = try historyRowsUnlocked("SELECT default_path FROM execution_workspace_defaults WHERE workspace_id=?", values: [root.workspaceID]).first?.objectValue?["default_path"]?.stringValue else { throw WorkspaceToolError.invalid("Workspace default directory unavailable.") }
        path = try sessionScratchDirectory(id: id)?.rootPath ?? defaultPath
      }
      try toolsExecuteUnlocked("UPDATE session_execution_roots SET root_path=? WHERE conversation_id=?", [path,id])

      let authority = try prepareUnlocked("""
        SELECT 1
        FROM conversations
        WHERE id = ?
          AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(authority) }
      try bind(id, at: 1, to: authority)
      guard sqlite3_step(authority) == SQLITE_ROW else { return false }

      let timestamp = Self.timestamp(updatedAt)
      let update = try prepareUnlocked("""
        UPDATE conversations
        SET folder_id = ?, updated_at = ?
        WHERE id = ? AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(update) }
      try bindNullable(folderID, at: 1, to: update)
      try bind(timestamp, at: 2, to: update)
      try bind(id, at: 3, to: update)
      try stepDone(update)
      guard changedRowCountUnlocked == 1 else { return false }

      return true
    }
  }

  public func conversationContent(id: String) throws -> WorkspaceConversationContent {
    try withLock { try conversationContentUnlocked(id: id) }
  }

  func conversationContentUnlocked(id: String) throws -> WorkspaceConversationContent {
    // Old desktop chats have no execution root, but retain their readable transcript.
    // Other archived chats keep their existing visibility rules.
    let messages = try decodeCanonicalRowsUnlocked(
      """
      SELECT \(Self.messageProjection)
      FROM messages AS message
      JOIN conversations AS conversation
        ON conversation.id = message.conversation_id
      WHERE \(Self.visibleConversationPredicate)
        AND NOT EXISTS (SELECT 1 FROM opencode_hidden_messages hidden WHERE hidden.message_id=message.id)
      ORDER BY message.created_at, message.id
      """,
      bindings: [id],
      as: WorkspaceMessageRecord.self
    )
    let runs = try decodeCanonicalRowsUnlocked(
      """
      SELECT \(Self.runProjection)
      FROM runs AS run
      JOIN conversations AS conversation
        ON conversation.id = run.conversation_id
      WHERE \(Self.visibleConversationPredicate)
      ORDER BY run.created_at, run.id
      """,
      bindings: [id],
      as: WorkspaceRunRecord.self
    )
    return WorkspaceConversationContent(
      conversationID: id,
      messages: messages,
      runs: runs,
      attachments: messages.isEmpty ? [] : try messageAttachmentRecordsUnlocked(conversationID: id),
      references: messages.isEmpty ? [] : try messageReferenceRecordsUnlocked(conversationID: id)
    )
  }

  public func conversationHistoryPage(
    id: String,
    before cursor: WorkspaceConversationHistoryCursor? = nil,
    limit: Int,
    compactActivities: Bool = false,
    activityCursor: Int64? = nil,
    knownActivityRunIDs: [String] = [],
    knownMessageIDs: [String] = []
  ) throws -> WorkspaceConversationHistoryPage {
    try withLock {
      let boundedLimit = min(max(limit, 1), 200)
      let cursorPredicate: String
      var bindings = [id]
      if let cursor {
        cursorPredicate = """
          AND (
            message.created_at < ?
            OR (message.created_at = ? AND message.id < ?)
          )
          """
        bindings.append(contentsOf: [cursor.createdAt, cursor.createdAt, cursor.messageID])
      } else {
        cursorPredicate = ""
      }
      let knownJSON = String(decoding: try JSONEncoder().encode(knownMessageIDs), as: UTF8.self)
      var retainedIDs: [String] = [], changedIDs: [String] = []
      if !knownMessageIDs.isEmpty {
        let metadata = try prepareUnlocked("""
          SELECT message.id, coalesce(revision.revision,0)
          FROM messages message
          JOIN conversations conversation ON conversation.id=message.conversation_id
          LEFT JOIN message_revisions revision ON revision.id=message.id
          WHERE message.conversation_id=? AND message.id IN (SELECT value FROM json_each(?))
            AND \(Self.listedConversation("conversation"))
            AND NOT EXISTS (SELECT 1 FROM opencode_hidden_messages hidden WHERE hidden.message_id=message.id)
          """)
        defer { sqlite3_finalize(metadata) }
        for (i, value) in [id, knownJSON].enumerated() { try bind(value, at: Int32(i+1), to: metadata) }
        while true {
          let code = sqlite3_step(metadata)
          if code == SQLITE_DONE { break }
          guard code == SQLITE_ROW else { throw stepError() }
          let messageID = try text(metadata, column: 0)
          retainedIDs.append(messageID)
          if activityCursor == nil || sqlite3_column_int64(metadata,1) > activityCursor! { changedIDs.append(messageID) }
        }
      }
      let changedJSON = String(decoding: try JSONEncoder().encode(changedIDs), as: UTF8.self)
      let retainedMessages: [WorkspaceMessageRecord] = changedIDs.isEmpty ? [] : try decodeCanonicalRowsUnlocked(
        """
        SELECT \(Self.messageProjection)
        FROM messages AS message
        WHERE message.id IN (SELECT value FROM json_each(?)) AND message.conversation_id=?
        ORDER BY message.created_at,message.id
        """, bindings: [changedJSON,id], as: WorkspaceMessageRecord.self)
      var newestFirst = try decodeCanonicalRowsUnlocked(
        """
        SELECT \(Self.messageProjection)
        FROM messages AS message
        JOIN conversations AS conversation
          ON conversation.id = message.conversation_id
        WHERE \(Self.visibleConversationPredicate)
          AND NOT EXISTS (SELECT 1 FROM opencode_hidden_messages hidden WHERE hidden.message_id=message.id)
          \(cursorPredicate)
        ORDER BY message.created_at DESC, message.id DESC
        LIMIT \(boundedLimit + 1)
        """,
        bindings: bindings,
        as: WorkspaceMessageRecord.self
      )
      let hasOlderMessages = newestFirst.count > boundedLimit
      if hasOlderMessages {
        newestFirst.removeLast(newestFirst.count - boundedLimit)
      }
      let messages = Array(newestFirst.reversed())
      let messageIDs = Array(Set(messages.map(\.id) + retainedIDs))
      let runs: [WorkspaceRunRecord]
      let activities: [WorkspaceRunActivityRecord]
      let attachments: [WorkspaceMessageAttachmentRecord]
      let references: [WorkspaceMessageReferenceRecord]
      var activityRevision: Int64?
      var removedActivityIDs: [String] = []
      var activityReadMetrics = ConversationActivityReadMetrics()
      if messageIDs.isEmpty {
        runs = []
        if compactActivities {
          let page = try compactRunActivitiesUnlocked(conversationID: id,
            runIDs: [], after: activityCursor, knownRunIDs: knownActivityRunIDs)
          activities = page.records
          activityRevision = page.revision
          removedActivityIDs = page.removed
          activityReadMetrics = page.metrics
        } else { activities = [] }
        attachments = []
        references = []
      } else {
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
        runs = try decodeCanonicalRowsUnlocked(
          """
          SELECT \(Self.runProjection)
          FROM runs AS run
          JOIN conversations AS conversation
            ON conversation.id = run.conversation_id
          WHERE \(Self.visibleConversationPredicate)
            AND (
              run.user_message_id IN (\(placeholders))
              OR run.assistant_message_id IN (\(placeholders))
            )
          ORDER BY run.created_at, run.id
          """,
          bindings: [id] + messageIDs + messageIDs,
          as: WorkspaceRunRecord.self
        )
        if compactActivities {
          let page = try compactRunActivitiesUnlocked(conversationID: id,
            runIDs: runs.map(\.id), after: activityCursor, knownRunIDs: knownActivityRunIDs)
          activities = page.records
          activityRevision = page.revision
          removedActivityIDs = page.removed
          activityReadMetrics = page.metrics
        } else {
          activities = try runActivityRecordsUnlocked(runIDs: runs.map(\.id))
        }
        attachments = try messageAttachmentRecordsUnlocked(messageIDs: messageIDs)
        references = try messageReferenceRecordsUnlocked(messageIDs: messageIDs)
      }
      return WorkspaceConversationHistoryPage(
        conversationID: id,
        messages: messages,
        runs: runs,
        activities: activities,
        attachments: attachments,
        references: references,
        hasOlderMessages: hasOlderMessages,
        activityRevision: activityRevision,
        activitiesAreDelta: compactActivities && activityCursor != nil && activityCursor! <= (activityRevision ?? -1),
        removedActivityIDs: removedActivityIDs,
        activityReadMetrics: activityReadMetrics,
        retainedMessages: retainedMessages,
        retainedMessageIDs: knownMessageIDs.isEmpty ? nil : retainedIDs
      )
    }
  }

  private func messageAttachmentRecordsUnlocked(
    messageIDs: [String] = [], conversationID: String? = nil
  ) throws -> [WorkspaceMessageAttachmentRecord] {
    guard conversationID != nil || !messageIDs.isEmpty else { return [] }
    // A full history must not allocate one SQLite parameter per retained message.
    let placeholders = conversationID != nil
      ? "SELECT id FROM messages WHERE conversation_id = ?"
      : Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
    let bindings = conversationID.map { [$0] } ?? messageIDs
    return try decodeCanonicalRowsUnlocked(
      """
      SELECT json_object(
        'id', id, 'conversation_id', conversation_id, 'message_id', message_id,
        'kind', kind, 'file_name', file_name, 'mime_type', mime_type,
        'size_bytes', size_bytes, 'content_hash', content_hash,
        'created_at', created_at
      )
      FROM message_attachments
      WHERE message_id IN (\(placeholders))
      ORDER BY created_at, id
      """,
      bindings: bindings,
      as: WorkspaceMessageAttachmentRecord.self
    )
  }

  private func messageReferenceRecordsUnlocked(
    messageIDs: [String] = [], conversationID: String? = nil
  ) throws -> [WorkspaceMessageReferenceRecord] {
    guard conversationID != nil || !messageIDs.isEmpty else { return [] }
    // A full history must not allocate one SQLite parameter per retained message.
    let placeholders = conversationID != nil
      ? "SELECT id FROM messages WHERE conversation_id = ?"
      : Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
    let bindings = conversationID.map { [$0] } ?? messageIDs
    return try decodeCanonicalRowsUnlocked(
      """
      SELECT json_object(
        'id', id, 'conversation_id', conversation_id, 'message_id', message_id,
        'resource_type', resource_type, 'resource_id', resource_id,
        'title_snapshot', title_snapshot, 'content_snapshot', content_snapshot,
        'revision_snapshot', revision_snapshot,
        'folder_id_snapshot', folder_id_snapshot,
        'folder_title_snapshot', folder_title_snapshot,
        'agent_codename_snapshot', agent_codename_snapshot,
        'created_at', created_at
      )
      FROM message_references
      WHERE message_id IN (\(placeholders))
      ORDER BY created_at, id
      """,
      bindings: bindings,
      as: WorkspaceMessageReferenceRecord.self
    )
  }

  func runActivityRecordsUnlocked(
    runIDs: [String] = [],
    assistantOnly: Bool = false,
    conversationID: String? = nil,
    recordIDs: [String]? = nil
  ) throws -> [WorkspaceRunActivityRecord] {
    guard conversationID != nil || !runIDs.isEmpty else { return [] }
    let placeholders = conversationID != nil
      ? "SELECT id FROM runs WHERE conversation_id = ?"
      : Array(repeating: "?", count: runIDs.count).joined(separator: ", ")
    let bindings = conversationID.map { [$0] } ?? runIDs
    func filter(_ ids: [String]?) throws -> String {
      guard let ids else { return "" }
      // The JSON array is bound separately, avoiding SQLite's parameter limit.
      return ids.isEmpty ? "AND 0" : "AND id IN (SELECT value FROM json_each(?))"
    }
    var records: [WorkspaceRunActivityRecord] = []
    let events = try prepareUnlocked("""
      SELECT id, run_id, conversation_id, event_type, content, created_at, rowid
      FROM run_activities
      WHERE run_id IN (\(placeholders))
        \(assistantOnly ? "AND event_type = 'assistant'" : "")
        \(try filter(recordIDs))
      ORDER BY created_at, rowid
      """)
    defer { sqlite3_finalize(events) }
    for (index, runID) in bindings.enumerated() {
      try bind(runID, at: Int32(index + 1), to: events)
    }
    if let recordIDs, !recordIDs.isEmpty {
      try bind(String(decoding: try JSONEncoder().encode(recordIDs), as: UTF8.self), at: Int32(bindings.count + 1), to: events)
    }
    while true {
      let code = sqlite3_step(events)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let content = try text(events, column: 4)
      let activity: AgentRunActivity
      if let decoded = try? JSONDecoder().decode(
        AgentRunActivity.self,
        from: Data(content.utf8)
      ) {
        activity = decoded
      } else {
        activity = AgentRunActivity(
          id: try text(events, column: 0),
          kind: .progress,
          phase: "update",
          title: try text(events, column: 3),
          content: content
        )
      }
      records.append(WorkspaceRunActivityRecord(
        id: try text(events, column: 0),
        runID: try text(events, column: 1),
        conversationID: try text(events, column: 2),
        activity: activity,
        createdAt: try text(events, column: 5),
        sequence: activity.position.map(Int64.init) ?? sqlite3_column_int64(events, 6)
      ))
    }

    return records.sorted(by: WorkspaceRunActivityRecord.precedes)
  }

  private static let messageProjection = """
    json_object(
      'id', message.id, 'conversation_id', message.conversation_id,
      'client_message_id', message.client_message_id,
      'sender_kind',COALESCE((SELECT kind FROM workspace_session_deliveries WHERE message_id=message.id),(SELECT kind FROM device_message_provenance WHERE message_id=message.id)),
      'sender_session_id',COALESCE((SELECT source_id FROM workspace_session_deliveries WHERE message_id=message.id),(SELECT source_id FROM device_message_provenance WHERE message_id=message.id)),
      'sender_agent',COALESCE((SELECT source_agent FROM workspace_session_deliveries WHERE message_id=message.id),(SELECT source_agent FROM device_message_provenance WHERE message_id=message.id)),
      'sender_session_title',COALESCE((SELECT source_title FROM workspace_session_deliveries WHERE message_id=message.id),(SELECT source_title FROM device_message_provenance WHERE message_id=message.id),(SELECT title FROM conversations WHERE id=(SELECT source_id FROM device_message_provenance WHERE message_id=message.id))),
      'run_id', message.run_id, 'role', message.role,
      'content', message.content, 'status', message.status,
      'created_at', message.created_at, 'updated_at', message.updated_at
    )
    """

  private static let runProjection = """
    json_object(
      'id', run.id, 'conversation_id', run.conversation_id,
      'agent_id', run.agent_id,
      'user_message_id', run.user_message_id,
      'assistant_message_id', run.assistant_message_id,
      'status', run.status, 'error', run.error,
      'started_at', run.started_at, 'completed_at', run.completed_at,
      'created_at', run.created_at, 'updated_at', run.updated_at
    )
    """

  /// A conversation the workspace lists: not deleted, and live or kept as
  /// retained read-only history.
  static func listedConversation(_ alias: String) -> String {
    """
    \(alias).deleted_at IS NULL
    AND (\(alias).is_archived = 0 OR EXISTS (SELECT 1 FROM retained_execution_history
      WHERE conversation_id=\(alias).id))
    """
  }

  private static let visibleConversationPredicate = "conversation.id = ? AND " + listedConversation("conversation")

  func decodeCanonicalRowsUnlocked<Value: Decodable>(
    _ sql: String,
    bindings: [String],
    as type: Value.Type
  ) throws -> [Value] {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() {
      try bind(value, at: Int32(offset + 1), to: statement)
    }
    let decoder = JSONDecoder()
    var values: [Value] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return values }
      guard code == SQLITE_ROW else { throw stepError() }
      do {
        values.append(try decoder.decode(Value.self, from: blob(statement, column: 0)))
      } catch {
        NSLog(
          "Ignoring incompatible cached %@ projection: %@",
          String(reflecting: Value.self),
          String(describing: error)
        )
      }
    }
  }
}

// MARK: - Async worker boundary

extension WorkspaceDatabase {
  public func workspaceRevision() async throws -> Int64 {
    try await read { try $0.workspaceRevision() }
  }

  @discardableResult
  public func markConversationRead(id: String) async throws -> Bool {
    try await write { try $0.markConversationRead(id: id) }
  }

  @discardableResult
  public func updateConversationTitleIfCurrent(
    id: String,
    expectedTitle: String,
    title: String,
    updatedAt: Date = Date()
  ) async throws -> Bool {
    try await write { try $0.updateConversationTitleIfCurrent(id: id, expectedTitle: expectedTitle, title: title, updatedAt: updatedAt) }
  }

  @discardableResult
  public func moveConversation(
    id: String,
    toFolderID folderID: String?,
    updatedAt: Date = Date()
  ) async throws -> Bool {
    try await write { try $0.moveConversation(id: id, toFolderID: folderID, updatedAt: updatedAt) }
  }

  public func conversationContent(id: String) async throws -> WorkspaceConversationContent {
    try await read { try $0.conversationContent(id: id) }
  }

  public func conversationHistoryPage(
    id: String,
    before cursor: WorkspaceConversationHistoryCursor? = nil,
    limit: Int,
    compactActivities: Bool = false,
    activityCursor: Int64? = nil,
    knownActivityRunIDs: [String] = [],
    knownMessageIDs: [String] = []
  ) async throws -> WorkspaceConversationHistoryPage {
    try await read { try $0.conversationHistoryPage(id: id, before: cursor, limit: limit,
      compactActivities: compactActivities, activityCursor: activityCursor, knownActivityRunIDs: knownActivityRunIDs, knownMessageIDs: knownMessageIDs) }
  }
}

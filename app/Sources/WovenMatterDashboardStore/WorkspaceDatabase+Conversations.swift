import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

// Conversation metadata and read projections for messages, references and activity.
extension WorkspaceDatabase {
  public func dashboardRevision() throws -> Int64 {
    try withLock {
      let statement = try prepareUnlocked(
        "SELECT revision FROM desktop_dashboard_revision WHERE singleton = 1"
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
        UPDATE dashboard_conversations
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
        FROM dashboard_conversations
        WHERE id = ? AND desktop_owned = 1 AND authority_kind = 'device_owned'
          AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(authority) }
      try bind(id, at: 1, to: authority)
      guard sqlite3_step(authority) == SQLITE_ROW else { return false }

      let timestamp = Self.timestamp(updatedAt)
      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET title = ?, updated_at = ?
        WHERE id = ? AND title = ? AND desktop_owned = 1
          AND authority_kind = 'device_owned' AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(cleanTitle, at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(id, at: 3, to: conversation)
      try bind(expectedTitle, at: 4, to: conversation)
      try stepDone(conversation)
      guard changedRowCountUnlocked == 1 else { return false }

      let session = try prepareUnlocked("""
        UPDATE desktop_local_acp_sessions
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
      let operatorID = try localMutationOperatorIDUnlocked()
      try validateFolderUnlocked(id: folderID, operatorID: operatorID)

      let authority = try prepareUnlocked("""
        SELECT 1
        FROM dashboard_conversations
        WHERE id = ? AND desktop_owned = 1 AND authority_kind = 'device_owned'
          AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(authority) }
      try bind(id, at: 1, to: authority)
      guard sqlite3_step(authority) == SQLITE_ROW else { return false }

      let timestamp = Self.timestamp(updatedAt)
      let update = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET folder_id = ?, updated_at = ?
        WHERE id = ? AND desktop_owned = 1
          AND authority_kind = 'device_owned' AND deleted_at IS NULL
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
    try withLock {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked() else {
        return WorkspaceConversationContent(conversationID: id, messages: [], runs: [])
      }
      let messages = try decodeCanonicalRowsUnlocked(
        """
        SELECT json_object(
          'id', message.id, 'conversation_id', message.conversation_id,
          'client_message_id', message.client_message_id,
          'sender_kind',(SELECT kind FROM workspace_session_deliveries WHERE message_id=message.id),
          'sender_session_id',(SELECT source_id FROM workspace_session_deliveries WHERE message_id=message.id),
          'sender_agent',(SELECT source_agent FROM workspace_session_deliveries WHERE message_id=message.id),
          'sender_session_title',(SELECT source_title FROM workspace_session_deliveries WHERE message_id=message.id),
          'run_id', message.run_id, 'role', message.role,
          'governing_plane', message.governing_plane,
          'authority_device_id', message.authority_device_id,
          'content', message.content, 'status', message.status,
          'created_at', message.created_at, 'updated_at', message.updated_at
        )
        FROM dashboard_messages AS message
        JOIN dashboard_conversations AS conversation
          ON conversation.id = message.conversation_id
        WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
          AND conversation.id = ?
          AND conversation.deleted_at IS NULL
          AND conversation.is_archived = 0
          AND conversation.governing_plane = 'wovenmatter_macos'
        ORDER BY message.created_at, message.id
        """,
        bindings: [operatorID, id],
        as: WorkspaceMessageRecord.self
      )
      let runs = try decodeCanonicalRowsUnlocked(
        """
        SELECT json_object(
          'id', run.id, 'conversation_id', run.conversation_id,
          'agent_id', run.agent_id,
          'governing_plane', run.governing_plane,
          'authority_device_id', run.authority_device_id,
          'user_message_id', run.user_message_id,
          'assistant_message_id', run.assistant_message_id,
          'status', run.status, 'error', run.error,
          'started_at', run.started_at, 'completed_at', run.completed_at,
          'created_at', run.created_at, 'updated_at', run.updated_at
        )
        FROM dashboard_runs AS run
        JOIN dashboard_conversations AS conversation
          ON conversation.id = run.conversation_id
        WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
          AND conversation.id = ?
          AND conversation.deleted_at IS NULL
          AND conversation.is_archived = 0
          AND conversation.governing_plane = 'wovenmatter_macos'
        ORDER BY run.created_at, run.id
        """,
        bindings: [operatorID, id],
        as: WorkspaceRunRecord.self
      )
      return WorkspaceConversationContent(
        conversationID: id,
        messages: messages,
        runs: runs,
        attachments: try messageAttachmentRecordsUnlocked(messageIDs: messages.map(\.id)),
        references: try messageReferenceRecordsUnlocked(messageIDs: messages.map(\.id))
      )
    }
  }

  public func conversationHistoryPage(
    id: String,
    before cursor: WorkspaceConversationHistoryCursor? = nil,
    limit: Int
  ) throws -> WorkspaceConversationHistoryPage {
    try withLock {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked() else {
        return WorkspaceConversationHistoryPage(
          conversationID: id,
          messages: [],
          runs: [],
          hasOlderMessages: false
        )
      }
      let boundedLimit = min(max(limit, 1), 200)
      let cursorPredicate: String
      var bindings = [operatorID, id]
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
      var newestFirst = try decodeCanonicalRowsUnlocked(
        """
        SELECT json_object(
          'id', message.id, 'conversation_id', message.conversation_id,
          'client_message_id', message.client_message_id,
          'sender_kind',(SELECT kind FROM workspace_session_deliveries WHERE message_id=message.id),
          'sender_session_id',(SELECT source_id FROM workspace_session_deliveries WHERE message_id=message.id),
          'sender_agent',(SELECT source_agent FROM workspace_session_deliveries WHERE message_id=message.id),
          'sender_session_title',(SELECT source_title FROM workspace_session_deliveries WHERE message_id=message.id),
          'run_id', message.run_id, 'role', message.role,
          'governing_plane', message.governing_plane,
          'authority_device_id', message.authority_device_id,
          'content', message.content, 'status', message.status,
          'created_at', message.created_at, 'updated_at', message.updated_at
        )
        FROM dashboard_messages AS message
        JOIN dashboard_conversations AS conversation
          ON conversation.id = message.conversation_id
        WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
          AND conversation.id = ?
          AND conversation.deleted_at IS NULL
          AND conversation.is_archived = 0
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
      let messageIDs = messages.map(\.id)
      let runs: [WorkspaceRunRecord]
      let activities: [WorkspaceRunActivityRecord]
      let attachments: [WorkspaceMessageAttachmentRecord]
      let references: [WorkspaceMessageReferenceRecord]
      if messageIDs.isEmpty {
        runs = []
        activities = []
        attachments = []
        references = []
      } else {
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
        runs = try decodeCanonicalRowsUnlocked(
          """
          SELECT json_object(
            'id', run.id, 'conversation_id', run.conversation_id,
            'agent_id', run.agent_id,
            'governing_plane', run.governing_plane,
            'authority_device_id', run.authority_device_id,
            'user_message_id', run.user_message_id,
            'assistant_message_id', run.assistant_message_id,
            'status', run.status, 'error', run.error,
            'started_at', run.started_at, 'completed_at', run.completed_at,
            'created_at', run.created_at, 'updated_at', run.updated_at
          )
          FROM dashboard_runs AS run
          JOIN dashboard_conversations AS conversation
            ON conversation.id = run.conversation_id
          WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
            AND conversation.id = ?
            AND conversation.deleted_at IS NULL
            AND conversation.is_archived = 0
            AND (
              run.user_message_id IN (\(placeholders))
              OR run.assistant_message_id IN (\(placeholders))
            )
          ORDER BY run.created_at, run.id
          """,
          bindings: [operatorID, id] + messageIDs + messageIDs,
          as: WorkspaceRunRecord.self
        )
        activities = try runActivityRecordsUnlocked(runIDs: runs.map(\.id))
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
        hasOlderMessages: hasOlderMessages
      )
    }
  }

  private func messageAttachmentRecordsUnlocked(
    messageIDs: [String]
  ) throws -> [WorkspaceMessageAttachmentRecord] {
    guard !messageIDs.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
    return try decodeCanonicalRowsUnlocked(
      """
      SELECT json_object(
        'id', id, 'conversation_id', conversation_id, 'message_id', message_id,
        'kind', kind, 'file_name', file_name, 'mime_type', mime_type,
        'size_bytes', size_bytes, 'content_hash', content_hash,
        'gateway_media_ref', gateway_media_ref, 'created_at', created_at
      )
      FROM dashboard_message_attachments
      WHERE message_id IN (\(placeholders))
      ORDER BY created_at, id
      """,
      bindings: messageIDs,
      as: WorkspaceMessageAttachmentRecord.self
    )
  }

  private func messageReferenceRecordsUnlocked(
    messageIDs: [String]
  ) throws -> [WorkspaceMessageReferenceRecord] {
    guard !messageIDs.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
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
      FROM dashboard_message_references
      WHERE message_id IN (\(placeholders))
      ORDER BY created_at, id
      """,
      bindings: messageIDs,
      as: WorkspaceMessageReferenceRecord.self
    )
  }

  func runActivityRecordsUnlocked(
    runIDs: [String],
    assistantOnly: Bool = false
  ) throws -> [WorkspaceRunActivityRecord] {
    guard !runIDs.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: runIDs.count).joined(separator: ", ")
    var records: [WorkspaceRunActivityRecord] = []
    let events = try prepareUnlocked("""
      SELECT id, run_id, conversation_id, event_type, content, created_at, rowid
      FROM dashboard_run_events
      WHERE run_id IN (\(placeholders))
        \(assistantOnly ? "AND event_type = 'assistant'" : "")
      ORDER BY created_at, rowid
      """)
    defer { sqlite3_finalize(events) }
    for (index, runID) in runIDs.enumerated() {
      try bind(runID, at: Int32(index + 1), to: events)
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

    if assistantOnly { return records.sorted(by: WorkspaceRunActivityRecord.precedes) }
    let traces = try prepareUnlocked("""
      SELECT id, run_id, conversation_id, event_type, event_name,
        event_phase, tool_name, content, raw_event_json, created_at
      FROM dashboard_run_trace_events
      WHERE run_id IN (\(placeholders))
        AND is_visible = 1
        AND event_type NOT IN ('assistant_delta', 'assistant_replace', 'done')
      ORDER BY created_at, seq, id
      """)
    defer { sqlite3_finalize(traces) }
    for (index, runID) in runIDs.enumerated() {
      try bind(runID, at: Int32(index + 1), to: traces)
    }
    while true {
      let code = sqlite3_step(traces)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let recordID = try text(traces, column: 0)
      let eventType = try text(traces, column: 3)
      let rawJSON = try text(traces, column: 8)
      let raw = (try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8)))
      let payload = Self.tracePayload(raw)
      let data = Self.dictionary(payload?["data"])
      let activityID = Self.traceString(data?["itemId"])
        ?? Self.traceString(data?["toolCallId"])
        ?? recordID
      let kind: AgentRunActivity.Kind = switch eventType {
      case "reasoning": .thought
      case "tool_call", "tool_result": .tool
      case "plan": .plan
      case "file_change": .fileChange
      case "progress": .progress
      default: .activity
      }
      let content = optionalText(traces, column: 7)
      records.append(WorkspaceRunActivityRecord(
        id: "trace-\(recordID)",
        runID: try text(traces, column: 1),
        conversationID: try text(traces, column: 2),
        activity: AgentRunActivity(
          id: activityID,
          kind: kind,
          phase: optionalText(traces, column: 5),
          title: Self.traceString(data?["title"])
            ?? Self.traceString(data?["name"])
            ?? optionalText(traces, column: 4),
          detail: Self.traceDetail(data),
          status: Self.traceString(data?["status"]),
          toolName: optionalText(traces, column: 6),
          content: content,
          contentIsDelta: optionalText(traces, column: 4) == "reasoning.delta",
          locations: Self.traceLocations(data),
          changes: Self.traceFileChanges(data),
          planEntries: Self.tracePlanEntries(data),
          rawInputJSON: Self.traceJSONString(data?["rawInput"] ?? data?["args"]),
          rawOutputJSON: Self.traceJSONString(data?["rawOutput"] ?? data?["result"]),
          rawPayloadJSON: rawJSON
        ),
        createdAt: try text(traces, column: 9)
      ))
    }
    return records.sorted(by: WorkspaceRunActivityRecord.precedes)
  }

  private static func tracePayload(_ value: Any?) -> [String: Any]? {
    let object = dictionary(value)
    return dictionary(object?["payload"]) ?? object
  }

  private static func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private static func traceString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
  }

  private static func traceJSONString(_ value: Any?) -> String? {
    guard let value,
          JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func traceDetail(_ data: [String: Any]?) -> String? {
    let args = dictionary(data?["args"])
    let result = dictionary(data?["result"])
    let parts = [
      traceString(args?["command"]).map { "$ \($0)" },
      traceString(args?["cwd"]).map { "cwd: \($0)" },
      traceString(result?["status"]),
    ].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  private static func traceLocations(_ data: [String: Any]?) -> [AgentRunLocation] {
    (data?["locations"] as? [[String: Any]] ?? []).compactMap { location in
      guard let path = traceString(location["path"]) else { return nil }
      return AgentRunLocation(path: path, line: location["line"] as? Int)
    }
  }

  private static func traceFileChanges(_ data: [String: Any]?) -> [AgentRunFileChange] {
    let values = (data?["content"] as? [[String: Any]] ?? [])
      + (data?["changes"] as? [[String: Any]] ?? [])
      + ((data?["path"] != nil || data?["filename"] != nil) ? [data ?? [:]] : [])
    return values.compactMap { change in
      guard let path = traceString(change["path"]) ?? traceString(change["filename"])
      else { return nil }
      return AgentRunFileChange(
        path: path,
        oldText: (change["oldText"] as? String) ?? (change["old_text"] as? String),
        newText: (change["newText"] as? String) ?? (change["new_text"] as? String) ?? "",
        unifiedDiff: (change["unified_diff"] as? String) ?? (change["diff"] as? String)
      )
    }
  }

  private static func tracePlanEntries(_ data: [String: Any]?) -> [AgentRunPlanEntry] {
    (data?["entries"] as? [[String: Any]] ?? []).compactMap { entry in
      guard let content = traceString(entry["content"]),
            let status = traceString(entry["status"]) else { return nil }
      return AgentRunPlanEntry(
        content: content,
        priority: traceString(entry["priority"]),
        status: status
      )
    }
  }

  func decodeCanonicalRowsUnlocked<Value: Decodable>(
    _ sql: String,
    operatorID: String,
    as type: Value.Type
  ) throws -> [Value] {
    try decodeCanonicalRowsUnlocked(
      sql,
      bindings: [operatorID],
      as: type
    )
  }

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

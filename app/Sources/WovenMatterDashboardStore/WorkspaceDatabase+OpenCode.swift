import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterClient
import WovenMatterCore

// Canonical OpenCode projections; legacy ACP rows are never migrated.
extension WorkspaceDatabaseConnection {
  public func knownOpenCodeSessionIDs(connectionID: String) throws -> Set<String> {
    try knownSessionIDs(sql: "SELECT session_id FROM opencode_sessions WHERE connection_id = ?", scope: connectionID)
  }

  public func openCodeLinks() throws -> [OpenCodeSessionLink] {
    try withLock {
      let statement = try prepareUnlocked("SELECT conversation_id, connection_id, session_id FROM opencode_sessions")
      defer { sqlite3_finalize(statement) }
      var result: [OpenCodeSessionLink] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(OpenCodeSessionLink(conversationID: try text(statement, column: 0),
          connectionID: try text(statement, column: 1), sessionID: try text(statement, column: 2)))
      }
      return result
    }
  }

  /// Saved snapshots remain readable even when their native execution is retired.
  public func openCodeExecutionRoot(conversationID: String) throws -> WorkspaceFolderLocation {
    try withLock {
      let statement = try prepareUnlocked("""
        SELECT r.workspace_id, r.root_path
        FROM session_execution_roots r
        JOIN conversations c ON c.id=r.conversation_id
        JOIN opencode_sessions o ON o.conversation_id=c.id
        WHERE c.id=? AND c.is_archived=0 AND c.deleted_at IS NULL
          AND NOT EXISTS(SELECT 1 FROM retained_execution_history WHERE conversation_id=c.id)
        """)
      defer { sqlite3_finalize(statement) }
      try bind(conversationID, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else {
        throw OpenCodeError.message("This saved OpenCode transcript is read-only. Start a new chat.")
      }
      return .init(workspaceID: try text(statement, column: 0),
        rootPath: try text(statement, column: 1), managed: false)
    }
  }

  public func resumableOpenCodeLinks() throws -> [OpenCodeSessionLink] {
    try openCodeLinks().filter { (try? openCodeExecutionRoot(conversationID: $0.conversationID)) != nil }
  }

  public func archiveImportedOpenCodeSession(conversationID: String) throws {
    try transaction {
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO retained_execution_history SELECT conversation_id FROM opencode_sessions WHERE conversation_id=?", [conversationID])
      try toolsExecuteUnlocked("UPDATE conversations SET is_archived=1 WHERE id=? AND EXISTS(SELECT 1 FROM opencode_sessions WHERE conversation_id=?)", [conversationID,conversationID])
    }
  }

  public func openCodeSnapshot(conversationID: String) throws -> OpenCodeSessionSnapshot? {
    try withLock {
      let statement = try prepareUnlocked("SELECT snapshot_json FROM opencode_sessions WHERE conversation_id = ?")
      defer { sqlite3_finalize(statement) }
      try bind(conversationID, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      return (try? JSONDecoder().decode(OpenCodeSessionSnapshot.self, from: Data(try text(statement, column: 0).utf8))) ?? OpenCodeSessionSnapshot()
    }
  }

  /// Snapshot, normalized transcript, activity, and acknowledged log watermark
  /// commit together. A failed write leaves the old recovery cursor intact.
  public func saveOpenCodeSnapshot(_ snapshot: OpenCodeSessionSnapshot, conversationID: String) throws {
    let session = try localACPSession(conversationID: conversationID)
    try transaction {
      try saveOpenCodeSnapshotUnlocked(snapshot, conversationID: conversationID, fallbackTitle: session.title)
    }
  }

  func saveOpenCodeSnapshotUnlocked(_ snapshot: OpenCodeSessionSnapshot, conversationID: String, fallbackTitle: String) throws {
      let previous = try openCodeSnapshot(conversationID: conversationID)
      let nativeIDs = Set(snapshot.messages.map { $0["id"].text })
      // A paged tail cannot hide unloaded history. Reconcile only the old
      // suffix covered by the new tail, or all previously visible messages
      // when the service reports that history starts here. Captured rows and
      // native archives remain intact; a later snapshot can restore visibility.
      let covered: [OpenCodeValue]
      if snapshot.olderCursor == nil { covered = previous?.messages ?? [] }
      else if let old = previous?.messages,
              let anchor = old.firstIndex(where: { nativeIDs.contains($0["id"].text) }) {
        covered = Array(old[anchor...])
      } else { covered = [] }
      for removed in covered where !nativeIDs.contains(removed["id"].text) {
        let messageID = "opencode:\(conversationID):\(removed["id"].text)"
        let hide = try prepareUnlocked("INSERT OR IGNORE INTO opencode_hidden_messages VALUES(?,?)")
        defer { sqlite3_finalize(hide) }
        try bind(messageID, at: 1, to: hide); try bind(conversationID, at: 2, to: hide); try stepDone(hide)
        try executeUnlocked("UPDATE activity_revision SET revision=revision+1 WHERE singleton=1")
        let invalidate = try prepareUnlocked("""
          UPDATE activity_summaries SET deleted=1,revision=(SELECT revision FROM activity_revision WHERE singleton=1)
          WHERE run_id=? AND conversation_id=? AND deleted=0
          """)
        defer { sqlite3_finalize(invalidate) }
        try bind(messageID + ":run", at: 1, to: invalidate)
        try bind(conversationID, at: 2, to: invalidate); try stepDone(invalidate)
      }
      for nativeID in nativeIDs {
        let show = try prepareUnlocked("DELETE FROM opencode_hidden_messages WHERE message_id=? AND conversation_id=?")
        defer { sqlite3_finalize(show) }
        try bind("opencode:\(conversationID):\(nativeID)", at: 1, to: show)
        try bind(conversationID, at: 2, to: show); try stepDone(show)
      }
      let now = Self.timestamp(Date())
      let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
      let state = try prepareUnlocked("UPDATE opencode_sessions SET snapshot_json = ? WHERE conversation_id = ?")
      defer { sqlite3_finalize(state) }
      try bind(json, at: 1, to: state); try bind(conversationID, at: 2, to: state); try stepDone(state)
      guard changedRowCountUnlocked == 1 else { throw LocalACPSessionDatabaseError.sessionNotFound }
      // Each save covers the whole loaded tail. Only rows whose content or
      // state changed are written, so an unrelated native change does not
      // rewrite, journal, and sync every message and run again.
      for message in snapshot.messages {
        let nativeID = message["id"].text
        guard !nativeID.isEmpty else { continue }
        let id = "opencode:\(conversationID):\(nativeID)"
        let assistant = message["type"].text == "assistant"
        let runID = assistant ? id + ":run" : nil
        let created = Self.timestamp(Date(timeIntervalSince1970: (message["time"]["created"].number ?? 0) / 1000))
        let status = assistant && message["time"]["completed"].isNull && snapshot.active ? "streaming" : "completed"
        let insert = try prepareUnlocked("""
          INSERT INTO messages(id, conversation_id, client_message_id, run_id, role, content,
            status, created_at, updated_at, owner_device_id)
          SELECT ?, c.id, ?, ?, ?, ?, ?, ?, ?, c.owner_device_id
          FROM conversations c WHERE c.id = ?
          ON CONFLICT(id) DO UPDATE SET content=excluded.content, status=excluded.status, updated_at=excluded.updated_at
            WHERE messages.content IS NOT excluded.content OR messages.status IS NOT excluded.status
          """)
        defer { sqlite3_finalize(insert) }
        try bind(id, at: 1, to: insert); try bind(nativeID, at: 2, to: insert)
        try bindNullable(runID, at: 3, to: insert)
        try bind(assistant ? "assistant" : message["type"].text == "user" ? "user" : "system", at: 4, to: insert)
        let inputContext = try historyRowsUnlocked("SELECT visible_text,delivery_id FROM workspace_opencode_input_context WHERE id=? AND conversation_id=?", values: [nativeID, conversationID]).first?.objectValue
        let visibleText = inputContext?["visible_text"]?.stringValue ?? OpenCodeSessionSnapshot.text(message)
        try bind(visibleText, at: 5, to: insert)
        try bind(status, at: 6, to: insert); try bind(created, at: 7, to: insert); try bind(now, at: 8, to: insert)
        try bind(conversationID, at: 9, to: insert); try stepDone(insert)
        let hasStoredInputFiles = !(try historyRowsUnlocked("SELECT 1 FROM message_attachments WHERE message_id=? LIMIT 1", values: [id])).isEmpty
        if status != "streaming", assistant || !hasStoredInputFiles {
          for file in message["files"].array + message["content"].array.filter({ $0["type"].text == "file" }) {
            let source = file["uri"].string ?? file["source"]["uri"].text
            let mime = file["mime"].string ?? file["mimeType"].string
            let title = file["name"].string ?? URL(string: source)?.lastPathComponent ?? "Attachment"
            try captureNativeLibraryFileUnlocked(source: source, title: title, mime: mime, base64: file["data"].string,
              messageID: id, conversationID: conversationID)
          }
        }
        if let deliveryID = inputContext?["delivery_id"]?.stringValue {
          try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET message_id=?,status='accepted' WHERE id=? AND target_id=? AND (message_id IS NULL OR message_id=?)", [id, deliveryID, conversationID, id])
        }
        if let runID {
          let runStatus = status == "streaming" ? "running" : message["error"].isNull ? "completed" : "failed"
          let run = try prepareUnlocked("""
            INSERT INTO runs(id, conversation_id, agent_id, agent_codename,
              owner_device_id, assistant_message_id, status, started_at,
              completed_at, created_at, updated_at)
            SELECT ?, c.id, c.agent_id, c.agent_codename, c.owner_device_id,
              ?, ?, ?, ?, ?, ? FROM conversations c WHERE c.id = ?
            ON CONFLICT(id) DO UPDATE SET completed_at=excluded.completed_at, updated_at=excluded.updated_at
              WHERE runs.completed_at IS NOT excluded.completed_at
            """)
          defer { sqlite3_finalize(run) }
          try bind(runID, at: 1, to: run); try bind(id, at: 2, to: run); try bind("running", at: 3, to: run)
          let completed = message["time"]["completed"].number.map { Self.timestamp(Date(timeIntervalSince1970: $0 / 1000)) } ?? created
          try bind(created, at: 4, to: run); try bindNullable(status == "streaming" ? nil : completed, at: 5, to: run)
          try bind(created, at: 6, to: run); try bind(now, at: 7, to: run); try bind(conversationID, at: 8, to: run)
          try stepDone(run)
          let reported = message["content"].array.filter { $0["type"].text == "step-finish" && !$0["tokens"].isNull }
          if !reported.isEmpty {
            var total: Int64 = 0
            for step in reported {
              let value = step["tokens"]
              guard let tokens = Self.goalStepTokens(value) else { total = -1; break }
              let sum = total.addingReportingOverflow(tokens)
              total = sum.overflow ? Int64.max : sum.partialValue
            }
            if total >= 0 { try recordGoalUsageUnlocked(runID: runID, tokens: total) }
          }
          let activities = OpenCodeSessionSnapshot.activities(message, assistantMessageID: id)
          let activityIDs = activities.map { "\(runID):activity:\($0.id)" }
          let placeholders = Array(repeating: "?", count: activityIDs.count).joined(separator: ",")
          // Published HTML belongs to the thread, independently of OpenCode's
          // current native part list. Reconciliation must keep those pages.
          let obsolete = try prepareUnlocked("DELETE FROM run_activities WHERE run_id = ? AND id NOT LIKE '%:activity:html-render:%'"
            + (activityIDs.isEmpty ? "" : " AND id NOT IN (\(placeholders))"))
          defer { sqlite3_finalize(obsolete) }
          try bind(runID, at: 1, to: obsolete)
          for (offset, activityID) in activityIDs.enumerated() {
            try bind(activityID, at: Int32(offset + 2), to: obsolete)
          }
          try stepDone(obsolete)
          // An identical surviving part need not fire the source UPDATE trigger.
          // Restore from current source rows, including tombstones left by an older
          // build that already removed the message's hidden marker.
          let revival = try prepareUnlocked("""
            UPDATE activity_revision SET revision=revision+1 WHERE singleton=1
              AND EXISTS(SELECT 1 FROM activity_summaries i
                JOIN run_activities e ON e.id=i.id
                WHERE i.run_id=? AND i.conversation_id=? AND i.deleted=1)
            """)
          defer { sqlite3_finalize(revival) }
          try bind(runID, at: 1, to: revival)
          try bind(conversationID, at: 2, to: revival); try stepDone(revival)
          if changedRowCountUnlocked > 0 {
            let restore = try prepareUnlocked("""
              UPDATE activity_summaries SET deleted=0,
                revision=(SELECT revision FROM activity_revision WHERE singleton=1)
              WHERE run_id=? AND conversation_id=? AND deleted=1
                AND EXISTS(SELECT 1 FROM run_activities e WHERE e.id=activity_summaries.id)
              """)
            defer { sqlite3_finalize(restore) }
            try bind(runID, at: 1, to: restore)
            try bind(conversationID, at: 2, to: restore); try stepDone(restore)
          }
          for activity in activities {
            try upsertRunActivityUnlocked(runID: runID, activity: activity, appendingContent: false, updatedAt: Date(),
              replacingActivity: true, allowingSettledRun: true)
          }
          // A new run settles after its parts, so its final activity archive
          // sees them. An unchanged status is not rewritten.
          let finish = try prepareUnlocked("UPDATE runs SET status=?1, updated_at=?2 WHERE id=?3 AND status IS NOT ?1")
          defer { sqlite3_finalize(finish) }
          try bind(runStatus, at: 1, to: finish); try bind(now, at: 2, to: finish); try bind(runID, at: 3, to: finish); try stepDone(finish)
        }
      }
      // ?1 title, ?2 preview (NULL keeps the current one), ?3 activity time, ?4 now, ?5 conversation.
      let title = "COALESCE((SELECT title FROM conversation_titles WHERE conversation_id=?5), ?1)"
      let lastAt = "MAX(?3, COALESCE((SELECT imported_at FROM session_imports WHERE conversation_id=?5), ''))"
      let preview = "COALESCE(?2, last_message_preview)"
      let update = try prepareUnlocked("""
        UPDATE conversations SET title=\(title), last_message_preview=\(preview), last_message_at=\(lastAt), updated_at=?4
        WHERE id=?5 AND (title IS NOT \(title) OR last_message_preview IS NOT \(preview) OR last_message_at IS NOT \(lastAt))
        """)
      defer { sqlite3_finalize(update) }
      try bind(snapshot.info["title"].string ?? fallbackTitle, at: 1, to: update)
      try bindNullable(try openCodePreviewUnlocked(snapshot, conversationID: conversationID).map { String($0.prefix(240)) }, at: 2, to: update)
      try bind(Self.timestamp(Date(timeIntervalSince1970: (snapshot.info["time"]["updated"].number ?? Date().timeIntervalSince1970 * 1000) / 1000)), at: 3, to: update)
      try bind(now, at: 4, to: update); try bind(conversationID, at: 5, to: update); try stepDone(update)
  }

  /// The latest message with visible text. Native configuration and other
  /// textless records never replace the preview; the input the user typed
  /// takes precedence over the transport text Woven sent for it.
  private func openCodePreviewUnlocked(_ snapshot: OpenCodeSessionSnapshot, conversationID: String) throws -> String? {
    for message in snapshot.messages.reversed() {
      let original = try historyRowsUnlocked("SELECT visible_text FROM workspace_opencode_input_context WHERE id=? AND conversation_id=?",
        values: [message["id"].text, conversationID]).first?.objectValue?["visible_text"]?.stringValue
      let text = original ?? OpenCodeSessionSnapshot.text(message)
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
    }
    return nil
  }

  public func saveOpenCodeSubmission(conversationID: String, id: String, payload: OpenCodeValue, status: String, visibleText: String? = nil, deliveryID: String? = nil, input: AgentMessageInput? = nil) throws {
    try transaction {
      // Fence new admission against Trash in the same writer transaction. Terminal
      // receipts must still settle after caller cancellation or a later visibility change.
      if status == "sending" { _ = try localACPSession(conversationID: conversationID) }
      let deliveryID = try deliveryID.map(canonicalDeliveryID)
      if let deliveryID { try markToolDeliveryTransportStartedUnlocked(id: deliveryID) }
      let statement = try prepareUnlocked("""
        INSERT INTO opencode_submissions(id, conversation_id, payload_json, status) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET status=excluded.status
        """)
      defer { sqlite3_finalize(statement) }
      try bind(id, at: 1, to: statement); try bind(conversationID, at: 2, to: statement)
      try bind(payload.json, at: 3, to: statement); try bind(status, at: 4, to: statement); try stepDone(statement)
      if let input, !input.attachments.isEmpty,
         try historyRowsUnlocked("SELECT 1 AS present FROM conversations WHERE id=?", values: [conversationID]).isEmpty == false {
        let messageID = "opencode:\(conversationID):\(id)"
        if (try historyRowsUnlocked("SELECT 1 FROM message_attachments WHERE message_id=? UNION ALL SELECT 1 FROM message_references WHERE message_id=?", values: [messageID, messageID])).isEmpty {
          try insertMessageAttachmentsUnlocked(input.attachments, conversationID: conversationID, messageID: messageID,
            createdAt: Date())
        }
      }
      if let visibleText {
        if let deliveryID {
          guard !(try historyRowsUnlocked("SELECT 1 FROM workspace_session_deliveries WHERE id=? AND target_id=? AND status='sending'", values: [deliveryID, conversationID])).isEmpty else {
            throw WorkspaceToolError.invalid("This delivery is not reserved for this session.")
          }
        }
        try toolsExecuteUnlocked("INSERT OR IGNORE INTO workspace_opencode_input_context(id,conversation_id,visible_text,delivery_id) VALUES(?,?,?,?)", [id, conversationID, visibleText, deliveryID])
      }
      if status == "accepted" {
        try toolsExecuteUnlocked("""
          UPDATE workspace_session_deliveries SET status='accepted'
          WHERE id=(SELECT delivery_id FROM workspace_opencode_input_context WHERE id=? AND conversation_id=?)
          """, [id, conversationID])
      }
    }
  }
  public func openCodeUncertainSubmissions(conversationID: String) throws -> [OpenCodeValue] {
    try withLock {
      let statement = try prepareUnlocked("SELECT id, payload_json, status FROM opencode_submissions WHERE conversation_id=? AND status IN ('sending', 'uncertain')")
      defer { sqlite3_finalize(statement) }; try bind(conversationID, at: 1, to: statement)
      var values: [OpenCodeValue] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        values.append(["id": .string(try text(statement, column: 0)), "payload": try OpenCodeValue.decode(Data(try text(statement, column: 1).utf8)), "status": .string(try text(statement, column: 2))])
      }
      return values
    }
  }
  /// Native snapshots remain verbatim in storage; only the presentation copy
  /// retains the original input, including for older messages with app prefixes.
  public func openCodeDisplaySnapshot(_ snapshot: OpenCodeSessionSnapshot, conversationID: String) throws -> OpenCodeSessionSnapshot {
    try withLock {
      var result = snapshot
      let rows = try historyRowsUnlocked("SELECT id,visible_text FROM workspace_opencode_input_context WHERE conversation_id=?", values: [conversationID])
      let textByID = Dictionary(uniqueKeysWithValues: rows.compactMap { value -> (String, String)? in
        guard let row = value.objectValue, let id = row["id"]?.stringValue, let text = row["visible_text"]?.stringValue else { return nil }
        return (id, text)
      })
      for i in result.messages.indices {
        if let text = textByID[result.messages[i]["id"].text], case .object(var message) = result.messages[i] {
          message["text"] = .string(text)
          result.messages[i] = .object(message)
        }
      }
      return result
    }
  }

}

// MARK: - Async worker boundary

extension WorkspaceDatabase {
  public func knownOpenCodeSessionIDs(connectionID: String) async throws -> Set<String> {
    try await read { try $0.knownOpenCodeSessionIDs(connectionID: connectionID) }
  }

  public func openCodeLinks() async throws -> [OpenCodeSessionLink] {
    try await read { try $0.openCodeLinks() }
  }

  public func openCodeExecutionRoot(conversationID: String) async throws -> WorkspaceFolderLocation {
    try await read { try $0.openCodeExecutionRoot(conversationID: conversationID) }
  }

  public func resumableOpenCodeLinks() async throws -> [OpenCodeSessionLink] {
    try await read { try $0.resumableOpenCodeLinks() }
  }

  public func archiveImportedOpenCodeSession(conversationID: String) async throws {
    try await write { try $0.archiveImportedOpenCodeSession(conversationID: conversationID) }
  }

  public func openCodeSnapshot(conversationID: String) async throws -> OpenCodeSessionSnapshot? {
    try await read { try $0.openCodeSnapshot(conversationID: conversationID) }
  }

  public func saveOpenCodeSnapshot(_ snapshot: OpenCodeSessionSnapshot, conversationID: String) async throws {
    try await write { try $0.saveOpenCodeSnapshot(snapshot, conversationID: conversationID) }
  }

  public func saveOpenCodeSubmission(conversationID: String, id: String, payload: OpenCodeValue, status: String, visibleText: String? = nil, deliveryID: String? = nil, input: AgentMessageInput? = nil) async throws {
    let operation: @Sendable (WorkspaceDatabaseConnection) throws -> Void = {
      try $0.saveOpenCodeSubmission(conversationID: conversationID, id: id, payload: payload, status: status, visibleText: visibleText, deliveryID: deliveryID, input: input)
    }
    if status == "sending" { try await write(operation) }
    else { try await finishWrite(operation) }
  }

  public func openCodeUncertainSubmissions(conversationID: String) async throws -> [OpenCodeValue] {
    try await read { try $0.openCodeUncertainSubmissions(conversationID: conversationID) }
  }

  public func openCodeDisplaySnapshot(_ snapshot: OpenCodeSessionSnapshot, conversationID: String) async throws -> OpenCodeSessionSnapshot {
    try await read { try $0.openCodeDisplaySnapshot(snapshot, conversationID: conversationID) }
  }
}

private extension WorkspaceDatabaseConnection {
  static func goalTokenCount(_ value: Double?) -> Int64? {
    guard let value, value.isFinite, value >= 0, value.rounded(.towardZero) == value else { return nil }
    return value >= Double(Int64.max) ? Int64.max : Int64(value)
  }

  static func goalStepTokens(_ value: OpenCodeValue) -> Int64? {
    if !value["total"].isNull { return goalTokenCount(value["total"].number) }
    guard let input = goalTokenCount(value["input"].number),
          let output = goalTokenCount(value["output"].number),
          let read = goalTokenCount(value["cache"]["read"].isNull ? 0 : value["cache"]["read"].number),
          let write = goalTokenCount(value["cache"]["write"].isNull ? 0 : value["cache"]["write"].number) else { return nil }
    return [input, output, read, write].reduce(Int64(0)) { total, count in
      let sum = total.addingReportingOverflow(count)
      return sum.overflow ? Int64.max : sum.partialValue
    }
  }
}

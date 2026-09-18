import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

// MARK: - OpenCode v2 canonical projections (legacy ACP rows are never migrated)
extension WorkspaceDatabase {
  public func openCodeLinks() throws -> [OpenCodeSessionLink] {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT conversation_id, connection_id, session_id FROM desktop_opencode_sessions")
      defer { sqlite3_finalize(statement) }
      var result: [OpenCodeSessionLink] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(OpenCodeSessionLink(conversationID: try text(statement, column: 0),
          connectionID: try text(statement, column: 1), sessionID: try text(statement, column: 2)))
      }
      return result
    }
  }

  public func attachOpenCodeSession(_ link: OpenCodeSessionLink) throws {
    try transaction {
      let statement = try prepareUnlocked("INSERT INTO desktop_opencode_sessions(conversation_id, connection_id, session_id, snapshot_json) VALUES (?, ?, ?, '{}')")
      defer { sqlite3_finalize(statement) }
      try bind(link.conversationID, at: 1, to: statement)
      try bind(link.connectionID, at: 2, to: statement)
      try bind(link.sessionID, at: 3, to: statement)
      try stepDone(statement)
    }
  }

  public func openCodeSnapshot(conversationID: String) throws -> OpenCodeSessionSnapshot? {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT snapshot_json FROM desktop_opencode_sessions WHERE conversation_id = ?")
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
      let now = Self.timestamp(Date())
      let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
      let state = try prepareUnlocked("UPDATE desktop_opencode_sessions SET snapshot_json = ? WHERE conversation_id = ?")
      defer { sqlite3_finalize(state) }
      try bind(json, at: 1, to: state); try bind(conversationID, at: 2, to: state); try stepDone(state)
      guard sqlite3_changes(connection) == 1 else { throw LocalACPSessionDatabaseError.sessionNotFound }
      for message in snapshot.messages {
        let nativeID = message["id"].text
        guard !nativeID.isEmpty else { continue }
        let id = "opencode:\(conversationID):\(nativeID)"
        let assistant = message["type"].text == "assistant"
        let runID = assistant ? id + ":run" : nil
        let created = Self.timestamp(Date(timeIntervalSince1970: (message["time"]["created"].number ?? 0) / 1000))
        let status = assistant && message["time"]["completed"].isNull && snapshot.active ? "streaming" : "completed"
        let insert = try prepareUnlocked("""
          INSERT INTO dashboard_messages(id, conversation_id, client_message_id, run_id, role, content,
            status, created_at, updated_at, desktop_owned, authority_device_id, authority_agent_id)
          SELECT ?, c.id, ?, ?, ?, ?, ?, ?, ?, 1, c.authority_device_id, c.authority_agent_id
          FROM dashboard_conversations c WHERE c.id = ?
          ON CONFLICT(id) DO UPDATE SET content=excluded.content, status=excluded.status, updated_at=excluded.updated_at
          """)
        defer { sqlite3_finalize(insert) }
        try bind(id, at: 1, to: insert); try bind(nativeID, at: 2, to: insert)
        try bindNullable(runID, at: 3, to: insert)
        try bind(assistant ? "assistant" : message["type"].text == "user" ? "user" : "system", at: 4, to: insert)
        try bind(OpenCodeSessionSnapshot.text(message), at: 5, to: insert)
        try bind(status, at: 6, to: insert); try bind(created, at: 7, to: insert); try bind(now, at: 8, to: insert)
        try bind(conversationID, at: 9, to: insert); try stepDone(insert)
        if let runID {
          let runStatus = status == "streaming" ? "running" : message["error"].isNull ? "completed" : "failed"
          let run = try prepareUnlocked("""
            INSERT INTO dashboard_runs(id, conversation_id, user_id, agent_id, agent_codename,
              authority_device_id, authority_agent_id, assistant_message_id, status, started_at,
              completed_at, created_at, updated_at, desktop_owned)
            SELECT ?, c.id, c.user_id, c.agent_id, c.agent_codename, c.authority_device_id,
              c.authority_agent_id, ?, ?, ?, ?, ?, ?, 1 FROM dashboard_conversations c WHERE c.id = ?
            ON CONFLICT(id) DO UPDATE SET status=excluded.status, completed_at=excluded.completed_at, updated_at=excluded.updated_at
            """)
          defer { sqlite3_finalize(run) }
          try bind(runID, at: 1, to: run); try bind(id, at: 2, to: run); try bind("running", at: 3, to: run)
          let completed = message["time"]["completed"].number.map { Self.timestamp(Date(timeIntervalSince1970: $0 / 1000)) } ?? created
          try bind(created, at: 4, to: run); try bindNullable(status == "streaming" ? nil : completed, at: 5, to: run)
          try bind(created, at: 6, to: run); try bind(now, at: 7, to: run); try bind(conversationID, at: 8, to: run)
          try stepDone(run)
          let activities = OpenCodeSessionSnapshot.activities(message, assistantMessageID: id)
          let activityIDs = activities.map { "\(runID):activity:\($0.id)" }
          let placeholders = Array(repeating: "?", count: activityIDs.count).joined(separator: ",")
          let obsolete = try prepareUnlocked("DELETE FROM dashboard_run_events WHERE run_id = ?"
            + (activityIDs.isEmpty ? "" : " AND id NOT IN (\(placeholders))"))
          defer { sqlite3_finalize(obsolete) }
          try bind(runID, at: 1, to: obsolete)
          for (offset, activityID) in activityIDs.enumerated() {
            try bind(activityID, at: Int32(offset + 2), to: obsolete)
          }
          try stepDone(obsolete)
          for activity in activities {
            try upsertDeviceOwnedRunActivityUnlocked(runID: runID, activity: activity, appendingContent: false, updatedAt: Date(), replacingActivity: true)
          }
          let finish = try prepareUnlocked("UPDATE dashboard_runs SET status=? WHERE id=?")
          defer { sqlite3_finalize(finish) }
          try bind(runStatus, at: 1, to: finish); try bind(runID, at: 2, to: finish); try stepDone(finish)
        }
      }
      let update = try prepareUnlocked("UPDATE dashboard_conversations SET title=?, last_message_preview=?, last_message_at=MAX(?, COALESCE((SELECT imported_at FROM desktop_session_imports WHERE conversation_id=dashboard_conversations.id), '')), updated_at=? WHERE id=?")
      defer { sqlite3_finalize(update) }
      try bind(snapshot.info["title"].string ?? fallbackTitle, at: 1, to: update)
      try bind(String(snapshot.messages.last.map(OpenCodeSessionSnapshot.text)?.prefix(240) ?? ""), at: 2, to: update)
      try bind(Self.timestamp(Date(timeIntervalSince1970: (snapshot.info["time"]["updated"].number ?? Date().timeIntervalSince1970 * 1000) / 1000)), at: 3, to: update)
      try bind(now, at: 4, to: update); try bind(conversationID, at: 5, to: update); try stepDone(update)
  }

  public func saveOpenCodeSubmission(conversationID: String, id: String, payload: OpenCodeValue, status: String) throws {
    try transaction {
      let statement = try prepareUnlocked("""
        INSERT INTO desktop_opencode_submissions(id, conversation_id, payload_json, status) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET status=excluded.status
        """)
      defer { sqlite3_finalize(statement) }
      try bind(id, at: 1, to: statement); try bind(conversationID, at: 2, to: statement)
      try bind(payload.json, at: 3, to: statement); try bind(status, at: 4, to: statement); try stepDone(statement)
    }
  }
  public func openCodeUncertainSubmissions(conversationID: String) throws -> [OpenCodeValue] {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT id, payload_json, status FROM desktop_opencode_submissions WHERE conversation_id=? AND status IN ('sending', 'uncertain')")
      defer { sqlite3_finalize(statement) }; try bind(conversationID, at: 1, to: statement)
      var values: [OpenCodeValue] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        values.append(["id": .string(try text(statement, column: 0)), "payload": try OpenCodeValue.decode(Data(try text(statement, column: 1).utf8)), "status": .string(try text(statement, column: 2))])
      }
      return values
    }
  }
}

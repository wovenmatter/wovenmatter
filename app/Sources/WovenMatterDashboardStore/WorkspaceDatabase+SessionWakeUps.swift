import Foundation
import WovenMatterCore

/// What `SessionWakeUps` keeps of the sessions an agent here created on other
/// workspaces (docs/architecture/WOVEN_EVERYWHERE.md, "Streaming", "Agent to
/// agent"; `SessionWakeUp` in shared/). Like `member_tool_sessions`, these
/// tables stay on this device: they are not in the paired sync table set.
public struct SessionWatchRecord: Equatable, Sendable {
  public var id: String
  public var callerID: String
  public var workspaceID: String
  public var workspaceName: String?
  public var title: String?
  public var harness: String?
  /// `running` or `needsInput`: an idle session is not watched.
  public var state: String
  public var runID: String?
  /// The sorted IDs of its pending interactions, comma-separated, while `needsInput`.
  public var questions: String?
  public init(id: String, callerID: String, workspaceID: String, workspaceName: String?, title: String?, harness: String?,
              state: String, runID: String?, questions: String?) {
    self.id = id; self.callerID = callerID; self.workspaceID = workspaceID; self.workspaceName = workspaceName
    self.title = title; self.harness = harness; self.state = state; self.runID = runID; self.questions = questions
  }
}

/// One pending wake-up: at most one per session.
public struct SessionWakeUpRecord: Equatable, Sendable {
  public var id: String
  public var callerID: String
  public var workspaceID: String
  public var kind: SessionWakeUp.Kind
  /// `finished:<run last seen running>` or `needsInput:<sorted interaction IDs>`.
  public var key: String
  public var title: String?
  public var workspaceName: String?
  public var harness: String?
  public var question: String?
  public var attempt: Int
  public var createdAt: String
  public init(id: String, callerID: String, workspaceID: String, kind: SessionWakeUp.Kind, key: String, title: String?,
              workspaceName: String?, harness: String?, question: String?, attempt: Int = 0, createdAt: String = "") {
    self.id = id; self.callerID = callerID; self.workspaceID = workspaceID; self.kind = kind; self.key = key
    self.title = title; self.workspaceName = workspaceName; self.harness = harness; self.question = question
    self.attempt = attempt; self.createdAt = createdAt
  }
}

extension WorkspaceDatabaseConnection {
  /// The event key of a wake-up's delivery row (`workspace_session_deliveries`).
  static let wakeUpEventPrefix = "wake-up:"

  func migrateSessionWakeUps() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS member_session_watch(id TEXT PRIMARY KEY, caller_id TEXT NOT NULL, workspace_id TEXT NOT NULL,
        workspace_name TEXT, title TEXT, harness TEXT, state TEXT NOT NULL, run_id TEXT, questions TEXT, updated_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS member_session_wakeups(id TEXT PRIMARY KEY, caller_id TEXT NOT NULL, workspace_id TEXT NOT NULL,
        kind TEXT NOT NULL, key TEXT NOT NULL, title TEXT, workspace_name TEXT, harness TEXT, question TEXT,
        attempt INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS member_session_wakeups_caller ON member_session_wakeups(caller_id, created_at);
      CREATE TABLE IF NOT EXISTS member_session_wakeup_counts(caller_id TEXT PRIMARY KEY, count INTEGER NOT NULL);
      """)
  }

  fileprivate func sessionWatchesUnlocked() throws -> [SessionWatchRecord] {
    try historyRowsUnlocked("SELECT * FROM member_session_watch ORDER BY updated_at, id", values: []).compactMap { row in
      guard let r = row.objectValue, let id = r["id"]?.stringValue, let caller = r["caller_id"]?.stringValue,
            let workspace = r["workspace_id"]?.stringValue, let state = r["state"]?.stringValue else { return nil }
      return .init(id: id, callerID: caller, workspaceID: workspace, workspaceName: r["workspace_name"]?.stringValue,
                   title: r["title"]?.stringValue, harness: r["harness"]?.stringValue, state: state,
                   runID: r["run_id"]?.stringValue, questions: r["questions"]?.stringValue)
    }
  }

  fileprivate func sessionWakeUpsUnlocked() throws -> [SessionWakeUpRecord] {
    try historyRowsUnlocked("SELECT * FROM member_session_wakeups ORDER BY created_at, rowid", values: []).compactMap { row in
      guard let r = row.objectValue, let id = r["id"]?.stringValue, let caller = r["caller_id"]?.stringValue,
            let workspace = r["workspace_id"]?.stringValue, let kind = r["kind"]?.stringValue.flatMap(SessionWakeUp.Kind.init(rawValue:)),
            let key = r["key"]?.stringValue else { return nil }
      return .init(id: id, callerID: caller, workspaceID: workspace, kind: kind, key: key, title: r["title"]?.stringValue,
                   workspaceName: r["workspace_name"]?.stringValue, harness: r["harness"]?.stringValue,
                   question: r["question"]?.stringValue, attempt: r["attempt"]?.intValue ?? 0, createdAt: r["created_at"]?.stringValue ?? "")
    }
  }
}

extension WorkspaceDatabase {
  public func sessionWatches() async throws -> [SessionWatchRecord] {
    try await read { try $0.sessionWatchesUnlocked() }
  }

  public func saveSessionWatch(_ record: SessionWatchRecord) async throws {
    let now = WorkspaceDatabaseConnection.timestamp(Date())
    try await write { try $0.toolsExecuteUnlocked("INSERT OR REPLACE INTO member_session_watch VALUES(?,?,?,?,?,?,?,?,?,?)",
      [record.id, record.callerID, record.workspaceID, record.workspaceName, record.title, record.harness, record.state,
       record.runID, record.questions, now]) }
  }

  public func removeSessionWatch(id: String) async throws {
    try await write { try $0.toolsExecuteUnlocked("DELETE FROM member_session_watch WHERE id=?", [id]) }
  }

  public func sessionWakeUps() async throws -> [SessionWakeUpRecord] {
    try await read { try $0.sessionWakeUpsUnlocked() }
  }

  /// Replaces the session's pending wake-up, if any.
  public func saveSessionWakeUp(_ record: SessionWakeUpRecord) async throws {
    let now = WorkspaceDatabaseConnection.timestamp(Date())
    try await write { try $0.toolsExecuteUnlocked("INSERT OR REPLACE INTO member_session_wakeups VALUES(?,?,?,?,?,?,?,?,?,?,?)",
      [record.id, record.callerID, record.workspaceID, record.kind.rawValue, record.key, record.title, record.workspaceName,
       record.harness, record.question, String(record.attempt), record.createdAt.isEmpty ? now : record.createdAt]) }
  }

  /// Removes the session's pending wake-up; with `key`, only while it is that one.
  public func removeSessionWakeUp(id: String, key: String? = nil) async throws {
    try await write { connection in
      if let key { try connection.toolsExecuteUnlocked("DELETE FROM member_session_wakeups WHERE id=? AND key=?", [id, key]) }
      else { try connection.toolsExecuteUnlocked("DELETE FROM member_session_wakeups WHERE id=?", [id]) }
    }
  }

  public func removeSessionWakeUps(callerID: String) async throws {
    try await write { try $0.toolsExecuteUnlocked("DELETE FROM member_session_wakeups WHERE caller_id=?", [callerID]) }
  }

  /// Whether a calling conversation still exists here.
  public func sessionWakeUpCallerExists(_ id: String) async throws -> Bool {
    try await read { !(try $0.historyRowsUnlocked("SELECT 1 FROM dashboard_conversations WHERE id=? AND deleted_at IS NULL", values: [id])).isEmpty }
  }

  public func botWakeUpCount(callerID: String) async throws -> Int {
    try await read { try $0.historyRowsUnlocked("SELECT count FROM member_session_wakeup_counts WHERE caller_id=?", values: [callerID])
      .first?.objectValue?["count"]?.intValue ?? 0 }
  }

  public func setBotWakeUpCount(callerID: String, count: Int?) async throws {
    try await write { connection in
      if let count { try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO member_session_wakeup_counts VALUES(?,?)", [callerID, String(count)]) }
      else { try connection.toolsExecuteUnlocked("DELETE FROM member_session_wakeup_counts WHERE caller_id=?", [callerID]) }
    }
  }

  /// How many of the conversation's latest runs, in a row, a wake-up started:
  /// the calling run's count (`SessionWakeUp`), at most `limit`.
  public func wakeUpRunsInARow(conversationID: String, limit: Int = StreamProtocol.maximumWakeUpsPerRun) async throws -> Int {
    try await read { connection in
      let rows = try connection.historyRowsUnlocked("""
        SELECT EXISTS(SELECT 1 FROM workspace_session_deliveries d WHERE d.message_id=r.user_message_id
          AND d.event_key LIKE '\(WorkspaceDatabaseConnection.wakeUpEventPrefix)%') AS woken
        FROM dashboard_runs r WHERE r.conversation_id=? ORDER BY r.created_at DESC, r.id DESC LIMIT \(max(1, limit + 1))
        """, values: [conversationID])
      return rows.prefix { $0.objectValue?["woken"]?.intValue == 1 }.count
    }
  }

  /// The delivery row of one wake-up into `callerID`: a notification whose
  /// source is the session it is about, so the chat shows "Update from" it.
  /// `id` names the attempt, so a retry after a crash replays it.
  public func reserveSessionWakeUpDelivery(id: String, callerID: String, sessionID: String, title: String?, harness: String?,
                                           text: String, key: String) async throws -> WorkspaceSessionDelivery {
    try await write { connection in
      try connection.transaction {
        let existing = try connection.historyRowsUnlocked("SELECT 1 FROM workspace_session_deliveries WHERE id=?", values: [id])
        guard existing.isEmpty else { return }
        try connection.toolsExecuteUnlocked("""
          INSERT INTO workspace_session_deliveries(id,source_id,target_id,content,status,source_agent,source_title,kind,
            target_title,target_harness,target_model,event_key)
          SELECT ?,?,?,?,'queued',?,?,'notification',coalesce(bt.display_name,t.title,'Bot'),
            coalesce(bt.display_name,d.runtime_kind,t.agent_codename),d.model,?
          FROM workspace_mcp_callers bt LEFT JOIN dashboard_conversations t ON t.id=bt.id
          LEFT JOIN desktop_local_acp_sessions d ON d.conversation_id=t.id WHERE bt.id=?
          """, [id, sessionID, callerID, text, harness ?? "wovenmatter", title ?? "Session",
                WorkspaceDatabaseConnection.wakeUpEventPrefix + id, callerID])
      }
    }
    guard let delivery = try await toolDelivery(id: id) else { throw WorkspaceToolError.invalid("This caller cannot be woken.") }
    return delivery
  }
}

import Foundation
import SQLite3
import WovenMatterCore
import WovenMatterClient

/// One recorder belongs to one native connection. Gateway responses omit the
/// session key, so retain bounded request correlation without altering raw bytes.
private final class GatewayHistoryRequestCorrelation: @unchecked Sendable {
  private let lock = NSLock()
  private var requests: [String: (key: String, order: UInt64)] = [:]
  private var sequence: UInt64 = 0

  func sessionKey(direction: String, data: Data) -> String? {
    guard let frame = (try? JSONDecoder().decode(GatewayJSONValue.self, from: data))?.objectValue else { return nil }
    let payload = frame["params"]?.objectValue ?? frame["payload"]?.objectValue ?? [:]
    let key = payload["sessionKey"]?.stringValue ?? payload["key"]?.stringValue
    return lock.withLock {
      if direction == "out", frame["type"]?.stringValue == "req",
         let id = frame["id"]?.stringValue, let key {
        sequence &+= 1
        requests[id] = (key, sequence)
        if requests.count > 1_024, let oldest = requests.min(by: { $0.value.order < $1.value.order })?.key {
          requests.removeValue(forKey: oldest)
        }
      }
      if direction == "in", frame["type"]?.stringValue == "res", let id = frame["id"]?.stringValue {
        return requests.removeValue(forKey: id)?.key ?? key
      }
      return key
    }
  }
}

// MARK: - User-owned history (same workspace.sqlite; independent of UI projections)
extension WorkspaceDatabase {
  func migrateWorkspaceHistory() throws {
    try transaction {
      try executeUnlocked(
        """
        CREATE TABLE IF NOT EXISTS workspace_history_schema(version INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS workspace_session_deliveries(
          id TEXT PRIMARY KEY,source_id TEXT NOT NULL,target_id TEXT NOT NULL,content TEXT NOT NULL,
          status TEXT NOT NULL,message_id TEXT UNIQUE,source_agent TEXT,source_title TEXT,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
        );
        CREATE INDEX IF NOT EXISTS session_deliveries_source ON workspace_session_deliveries(source_id,created_at);
        CREATE TABLE IF NOT EXISTS workspace_history_events(
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
          conversation_id TEXT, run_id TEXT, agent_id TEXT, harness TEXT NOT NULL,
          kind TEXT NOT NULL, payload TEXT NOT NULL, completeness TEXT NOT NULL DEFAULT 'observed',
          recorded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
        );
        CREATE INDEX IF NOT EXISTS history_conversation ON workspace_history_events(conversation_id,sequence);
        CREATE INDEX IF NOT EXISTS history_run ON workspace_history_events(run_id,sequence);
        CREATE INDEX IF NOT EXISTS history_harness ON workspace_history_events(harness,sequence);
        CREATE VIRTUAL TABLE IF NOT EXISTS workspace_history_search USING fts5(
          payload, content='workspace_history_events', content_rowid='sequence'
        );
        CREATE TRIGGER IF NOT EXISTS history_search_insert AFTER INSERT ON workspace_history_events BEGIN
          INSERT INTO workspace_history_search(rowid,payload) VALUES(new.sequence,new.payload);
        END;
        CREATE TABLE IF NOT EXISTS note_asset_versions(
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
          note_id TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL,
          revision TEXT NOT NULL, source TEXT NOT NULL, bytes INTEGER NOT NULL,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
        );
        CREATE INDEX IF NOT EXISTS note_versions_note ON note_asset_versions(note_id,sequence DESC);
        """)
      let columns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_history_events)", values: [])
        .compactMap { $0.objectValue?["name"]?.stringValue })
      for column in ["native_session_id", "source_connection_id"] where !columns.contains(column) {
        try executeUnlocked("ALTER TABLE workspace_history_events ADD COLUMN \(column) TEXT")
      }
      try executeUnlocked("""
        CREATE INDEX IF NOT EXISTS history_native_session ON workspace_history_events(harness,source_connection_id,agent_id,native_session_id)
          WHERE conversation_id IS NULL;
        CREATE TRIGGER IF NOT EXISTS history_opencode_import AFTER INSERT ON desktop_opencode_sessions BEGIN
          UPDATE workspace_history_events SET conversation_id=new.conversation_id
          WHERE conversation_id IS NULL AND harness='opencode'
            AND source_connection_id=new.connection_id AND native_session_id=new.session_id;
        END;
        CREATE TRIGGER IF NOT EXISTS history_openclaw_import AFTER INSERT ON desktop_openclaw_gateway_sessions BEGIN
          UPDATE workspace_history_events SET conversation_id=new.conversation_id
          WHERE conversation_id IS NULL AND harness='openclaw'
            AND agent_id=new.agent_id AND native_session_id=new.session_key;
        END;
        """)
      // Import only surviving projections once. Never imply that old raw traces existed.
      let version = try prepareUnlocked("SELECT 1 FROM workspace_history_schema WHERE version=1")
      defer { sqlite3_finalize(version) }
      if sqlite3_step(version) != SQLITE_ROW {
        try executeUnlocked(
          """
          INSERT OR IGNORE INTO workspace_history_events(id,conversation_id,run_id,harness,kind,payload,completeness)
          SELECT 'legacy-message:'||m.id,m.conversation_id,m.run_id,
            coalesce(s.runtime_kind,'unknown'),'message.snapshot',
            json_object('id',m.id,'role',m.role,'content',m.content,'status',m.status,'createdAt',m.created_at),
            'legacy-partial'
          FROM dashboard_messages m LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id=m.conversation_id;
          INSERT OR IGNORE INTO workspace_history_events(id,conversation_id,run_id,harness,kind,payload,completeness)
          SELECT 'legacy-activity:'||e.id,e.conversation_id,e.run_id,coalesce(s.runtime_kind,'unknown'),
            'activity.snapshot',json_object('id',e.id,'eventType',e.event_type,'content',e.content,'createdAt',e.created_at),'legacy-partial'
          FROM dashboard_run_events e LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id=e.conversation_id;
          INSERT OR IGNORE INTO workspace_history_events(id,conversation_id,run_id,harness,kind,payload,completeness)
          SELECT 'legacy-trace:'||id,conversation_id,run_id,'openclaw','trace.snapshot',raw_event_json,'legacy-partial'
          FROM dashboard_run_trace_events;
          INSERT INTO workspace_history_schema(version) VALUES(1);
          """)
      }
      // Current-state events complement native capture, covering human input and run
      // status even when an adapter fails before it emits a transport frame.
      for operation in ["INSERT", "UPDATE"] {
        let suffix = operation.lowercased()
        let content =
          operation == "INSERT"
          ? "new.content"
          : "CASE WHEN substr(new.content,1,length(old.content))=old.content THEN substr(new.content,length(old.content)+1) ELSE new.content END"
        let contentMode =
          operation == "INSERT"
          ? "'snapshot'"
          : "CASE WHEN substr(new.content,1,length(old.content))=old.content THEN 'append' ELSE 'replace' END"
        try executeUnlocked(
          """
          CREATE TRIGGER IF NOT EXISTS history_message_\(suffix) AFTER \(operation) ON dashboard_messages
          BEGIN
            INSERT INTO workspace_history_events(id,conversation_id,run_id,harness,kind,payload)
            VALUES(lower(hex(randomblob(16))),new.conversation_id,new.run_id,
              coalesce((SELECT runtime_kind FROM desktop_local_acp_sessions WHERE conversation_id=new.conversation_id),'unknown'),
              'message.\(suffix)',json_object('id',new.id,'role',new.role,'content',\(content),'contentMode',\(contentMode),'status',new.status));
          END;
          CREATE TRIGGER IF NOT EXISTS history_run_\(suffix) AFTER \(operation) ON dashboard_runs
          BEGIN
            INSERT INTO workspace_history_events(id,conversation_id,run_id,agent_id,harness,kind,payload)
            VALUES(lower(hex(randomblob(16))),new.conversation_id,new.id,new.agent_id,
              coalesce((SELECT runtime_kind FROM desktop_local_acp_sessions WHERE conversation_id=new.conversation_id),'unknown'),
              'run.\(suffix)',json_object('id',new.id,'status',new.status,'error',new.error,'nativeSession',new.openclaw_session_key));
          END;
          """)
      }
    }
  }

  /// Atomic and idempotent. An ID may only refer to the exact same event.
  public func recordHistory(_ event: WorkspaceHistoryEvent) throws {
    try transaction { try recordHistoryUnlocked(event) }
  }

  func recordHistoryUnlocked(_ incoming: WorkspaceHistoryEvent) throws {
    var event = incoming
    event.payload = WorkspaceHistoryPrivacy.redactingToolEndpoints(event.payload)
    if event.nativeSessionID == nil, event.harness == "openclaw",
      let object = try? JSONSerialization.jsonObject(with: Data(event.payload.utf8))
        as? [String: Any]
    {
      let payload =
        (object["payload"] as? [String: Any]) ?? (object["params"] as? [String: Any]) ?? object
      let key = (payload["sessionKey"] as? String) ?? (payload["key"] as? String)
      event.nativeSessionID = key
    }
    if event.conversationID == nil, let key = event.nativeSessionID {
      if event.harness == "openclaw" {
        let rows = try historyRowsUnlocked(
          "SELECT conversation_id FROM desktop_openclaw_gateway_sessions WHERE session_key=? AND agent_id=?",
          values: [key, event.agentID])
        if rows.count == 1 {
          event.conversationID = rows.first?.objectValue?["conversation_id"]?.stringValue
        }
      } else if event.harness == "opencode" {
        event.conversationID = try historyRowsUnlocked("SELECT conversation_id FROM desktop_opencode_sessions WHERE connection_id=? AND session_id=?",
          values: [event.sourceConnectionID, key]).first?.objectValue?["conversation_id"]?.stringValue
      }
    }
    let existing = try prepareUnlocked(
      "SELECT payload,kind,harness,conversation_id,agent_id,run_id,completeness,native_session_id,source_connection_id FROM workspace_history_events WHERE id=?")
    defer { sqlite3_finalize(existing) }
    try bind(event.id, at: 1, to: existing)
    if sqlite3_step(existing) == SQLITE_ROW {
      guard try text(existing, column: 0) == event.payload,
        try text(existing, column: 1) == event.kind,
        try text(existing, column: 2) == event.harness,
        optionalText(existing,column:3) == event.conversationID,
        optionalText(existing,column:4) == event.agentID,
        event.runID == nil || optionalText(existing,column:5) == event.runID,
        try text(existing,column:6) == event.completeness,
        optionalText(existing,column:7) == event.nativeSessionID,
        optionalText(existing,column:8) == event.sourceConnectionID
      else {
        throw WorkspaceDatabaseError.open("History event ID collision")
      }
      return
    }
    let statement = try prepareUnlocked(
      """
      INSERT INTO workspace_history_events(id,conversation_id,run_id,agent_id,harness,kind,payload,completeness,native_session_id,source_connection_id)
      VALUES(?,?,coalesce(?,(SELECT id FROM dashboard_runs WHERE conversation_id=?
        AND status IN ('queued','running') ORDER BY rowid DESC LIMIT 1)),?,?,?,?,?,?,?)
      """)
    defer { sqlite3_finalize(statement) }
    for (index, value) in [
      event.id, event.conversationID, event.runID, event.conversationID,
      event.agentID, event.harness, event.kind, event.payload, event.completeness,
      event.nativeSessionID, event.sourceConnectionID,
    ].enumerated() {
      try bindNullable(value, at: Int32(index + 1), to: statement)
    }
    try stepDone(statement)
  }

  public func historyWireRecorder(
    conversationID: String? = nil, agentID: String? = nil,
    harness: String
  ) -> WorkspaceWireRecorder {
    let correlation = GatewayHistoryRequestCorrelation()
    return { [self] direction, data in
      let key = harness == "openclaw" ? correlation.sessionKey(direction: direction, data: data) : nil
      try recordHistory(
        WorkspaceHistoryEvent(
          conversationID: conversationID, agentID: agentID,
          harness: harness, kind: "wire.\(direction)",
          payload: String(decoding: data, as: UTF8.self), nativeSessionID: key))
    }
  }

  public func openCodeHistoryRecorder(connectionID: String) -> WorkspaceWireRecorder {
    { [self] direction, data in
      let frame = try JSONDecoder().decode(WorkspaceHTTPObservation.self, from: data)
      let parts = frame.path.split(separator: "/").map(String.init)
      let nativeID = parts.firstIndex(of: "session").flatMap { index in
        index + 1 < parts.count ? parts[index + 1].removingPercentEncoding : nil
      }
      try transaction {
        let conversationID: String?
        if let nativeID {
          conversationID = try historyRowsUnlocked("SELECT conversation_id FROM desktop_opencode_sessions WHERE connection_id=? AND session_id=?", values: [connectionID, nativeID]).first?.objectValue?["conversation_id"]?.stringValue
        } else { conversationID = nil }
        try recordHistoryUnlocked(.init(conversationID: conversationID, harness: "opencode",
          kind: "wire.\(direction)", payload: String(decoding: data, as: UTF8.self),
          nativeSessionID: nativeID, sourceConnectionID: connectionID))
      }
    }
  }

  /// Agents cannot write application records through this API. The service itself
  /// journals query access; results are referenced, never recursively re-embedded.
  public func queryHistory(_ query: WorkspaceHistoryQuery) throws -> GatewayJSONValue {
    let queryID = UUID().uuidString.lowercased()
    try recordHistory(
      WorkspaceHistoryEvent(
        id: queryID, conversationID: query.callerConversationID,
        harness: "woven-history", kind: "cli.query",
        payload: String(decoding: try JSONEncoder().encode(query), as: UTF8.self)))
    do {
      return try transaction {
        guard query.schemaVersion == 1, (1...200).contains(query.limit), query.after >= 0,
          query.offset >= 0, query.offset < Int.max, (1...65536).contains(query.characters)
        else {
          throw WorkspaceDatabaseError.open("Unsupported history schema or invalid pagination")
        }
        let result = try queryHistoryUnlocked(query)
        let rowIDs = (result.objectValue?["rows"]?.arrayValue ?? []).compactMap {
          $0.objectValue?["id"]?.stringValue
        }
        try recordHistoryUnlocked(
          WorkspaceHistoryEvent(
            conversationID: query.callerConversationID,
            harness: "woven-history", kind: "cli.query.result",
            payload: String(
              decoding: try JSONEncoder().encode(
                [
                  "queryID": queryID, "command": query.command,
                  "resultIDs": rowIDs.joined(separator: ","),
                ]), as: UTF8.self)))
        return result
      }
    } catch {
      try recordHistory(
        WorkspaceHistoryEvent(
          conversationID: query.callerConversationID, harness: "woven-history",
          kind: "cli.query.error",
          payload: String(
            decoding: try JSONEncoder().encode(
              ["queryID": queryID, "error": error.localizedDescription]), as: UTF8.self)))
      throw error
    }
  }

  func queryHistoryUnlocked(_ query: WorkspaceHistoryQuery) throws -> GatewayJSONValue {
    var values: [String?] = []
    var sql: String
    switch query.command {
    case "events", "search", "trace":
      if query.command == "trace", query.id == nil, query.runID == nil {
        throw WorkspaceDatabaseError.open("trace requires a run ID")
      }
      var filters = ["e.sequence > ?"]
      values.append(String(query.after))
      if query.command == "search", query.kind == nil {
        // Retrieval journals contain the search term itself. Keep them available
        // through events/trace or an explicit kind filter, but do not let that
        // audit traffic manufacture a local match and suppress folder fallback.
        filters.append("e.kind NOT LIKE 'cli.%'")
      }
      for (column, value) in [
        ("conversation_id", query.conversationID),
        ("run_id", query.runID ?? (query.command == "trace" ? query.id : nil)),
        ("harness", query.harness), ("kind", query.kind),
      ] {
        if let value {
          filters.append("e.\(column) = ?")
          values.append(value)
        }
      }
      if let since = query.since {
        filters.append("e.recorded_at >= ?")
        guard let date = Self.date(since) else { throw WorkspaceToolError.invalid("--since requires an ISO 8601 date with a time zone.") }
        values.append(Self.timestamp(date))
      }
      if let until = query.until {
        filters.append("e.recorded_at <= ?")
        guard let date = Self.date(until) else { throw WorkspaceToolError.invalid("--until requires an ISO 8601 date with a time zone.") }
        values.append(Self.timestamp(date))
      }
      if let folderID = query.folderID {
        filters.append("e.conversation_id IN (SELECT id FROM dashboard_conversations WHERE folder_id=?)")
        values.append(folderID)
      }
      if let search = query.search, !search.isEmpty {
        filters.append(
          "e.sequence IN (SELECT rowid FROM workspace_history_search WHERE workspace_history_search MATCH ?)"
        )
        // Literal text search, not a user-supplied FTS expression.
        values.append("\"" + search.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
      }
      sql = """
        SELECT e.sequence,e.id,e.conversation_id,e.run_id,e.agent_id,e.harness,e.kind,
          e.completeness,e.recorded_at,length(e.payload) AS payload_characters,
          CASE WHEN length(e.payload)<=65536 THEN e.payload ELSE NULL END AS payload
        FROM workspace_history_events e WHERE
        """ + " " + filters.joined(separator: " AND ") + " ORDER BY e.sequence"
    case "event":
      guard let id = query.id else { throw WorkspaceDatabaseError.open("event requires an ID") }
      sql = """
        SELECT sequence,id,length(payload) AS payload_characters,
          substr(payload,?,?) AS payload FROM workspace_history_events WHERE id=? ORDER BY sequence
        """
      values = [String(query.offset + 1), String(query.characters), id]
    case "conversations":
      sql = """
        SELECT c.rowid AS sequence,c.id,c.title,c.agent_codename,c.folder_id,c.created_at,c.updated_at,c.deleted_at,
          coalesce(s.runtime_kind,CASE WHEN o.session_id IS NOT NULL THEN 'opencode' END,'openclaw') AS harness,
          s.model,s.thinking,s.remote_workspace_id,
          (SELECT status FROM dashboard_runs WHERE conversation_id=c.id ORDER BY rowid DESC LIMIT 1) AS status
        FROM dashboard_conversations c LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id=c.id
        LEFT JOIN desktop_opencode_sessions o ON o.conversation_id=c.id
        WHERE c.rowid > ? AND c.deleted_at IS NULL
        """
      values = [String(query.after)]
      if let id = query.id { sql += " AND c.id=?"; values.append(id) }
      if let folderID = query.folderID { sql += " AND c.folder_id=?"; values.append(folderID) }
      if let search = query.search {
        sql += " AND instr(lower(c.title),lower(?))>0"; values.append(search)
      }
      sql += " ORDER BY c.rowid"
    case "conversation":
      guard let id = query.id else {
        throw WorkspaceDatabaseError.open("conversation requires an ID")
      }
      sql =
        "SELECT m.rowid AS sequence,m.id,m.conversation_id,m.run_id,m.role,substr(m.content,1,16384) AS content,length(m.content) AS content_characters,m.status,m.created_at, d.source_id AS sender_session_id,d.source_agent AS sender_agent,d.source_title AS sender_session_title FROM dashboard_messages m LEFT JOIN workspace_session_deliveries d ON d.message_id=m.id WHERE m.conversation_id=? AND m.rowid>? ORDER BY m.rowid"
      values = [id, String(query.after)]
    case "message":
      guard let id = query.id else { throw WorkspaceDatabaseError.open("message requires an ID") }
      sql = "SELECT rowid AS sequence,id,conversation_id,length(content) AS content_characters,substr(content,?,?) AS content FROM dashboard_messages WHERE id=? ORDER BY rowid"
      values = [String(query.offset + 1), String(query.characters), id]
    case "runs":
      sql =
        "SELECT rowid AS sequence,id,conversation_id,agent_codename,status,error,started_at,completed_at FROM dashboard_runs WHERE rowid>?"
      values = [String(query.after)]
      if let id = query.conversationID {
        sql += " AND conversation_id=?"
        values.append(id)
      }
      sql += " ORDER BY rowid"
    case "versions":
      guard let id = query.id else {
        throw WorkspaceDatabaseError.open("versions requires a note ID")
      }
      sql =
        "SELECT sequence,id,note_id,title,revision,source,bytes,created_at FROM note_asset_versions WHERE note_id=? AND sequence>? ORDER BY sequence"
      values = [id, String(query.after)]
    case "version":
      guard let id = query.id else {
        throw WorkspaceDatabaseError.open("version requires a version ID")
      }
      sql = "SELECT sequence,id,note_id,title,revision,source,bytes,created_at,length(content) AS content_characters,substr(content,?,?) AS content FROM note_asset_versions WHERE id=? ORDER BY sequence"
      values = [String(query.offset + 1), String(query.characters), id]
    default: throw WorkspaceDatabaseError.open("Unknown read-only history command")
    }
    sql += " LIMIT ?"
    values.append(String(query.limit + 1))
    var rows = try historyRowsUnlocked(sql, values: values)
    let more = rows.count > query.limit
    if more { rows.removeLast() }
    let cursor = rows.last?.objectValue?["sequence"] ?? .number(Double(query.after))
    return .object([
      "schemaVersion": .number(1), "rows": .array(rows), "hasMore": .bool(more),
      "nextCursor": cursor,
      "historicalCoverage": .string(
        "Legacy records are partial; wire events preserve data observed since capture was enabled."),
    ])
  }

  func historyRowsUnlocked(_ sql: String, values: [String?]) throws -> [GatewayJSONValue] {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      try bindNullable(value, at: Int32(index + 1), to: statement)
    }
    var rows: [GatewayJSONValue] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw stepError() }
      var row: [String: GatewayJSONValue] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: row[name] = .null
        case SQLITE_INTEGER, SQLITE_FLOAT:
          row[name] = .number(sqlite3_column_double(statement, column))
        default: row[name] = .string(try text(statement, column: column))
        }
      }
      rows.append(.object(row))
    }
    return rows
  }

  /// Five-minute editor checkpoints; explicit agent/restore boundaries are immediate.
  /// Limits affect historical snapshots only, never the current notes row or events.
  func checkpointNoteUnlocked(id: String, source: String, force: Bool) throws {
    let note = try prepareUnlocked(
      """
      SELECT title,content,CAST(COALESCE((SELECT revision FROM companion_versions WHERE kind='note' AND resource_id=notes.id),1) AS TEXT) FROM notes WHERE id=? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(note) }
    try bind(id, at: 1, to: note)
    guard sqlite3_step(note) == SQLITE_ROW else { return }
    let title = try text(note, column: 0)
    let content = try text(note, column: 1)
    let revision = try text(note, column: 2)
    let last = try prepareUnlocked(
      "SELECT title,content,(julianday('now')-julianday(created_at))*86400 FROM note_asset_versions WHERE note_id=? ORDER BY sequence DESC LIMIT 1"
    )
    defer { sqlite3_finalize(last) }
    try bind(id, at: 1, to: last)
    if sqlite3_step(last) == SQLITE_ROW {
      if try text(last, column: 0) == title, try text(last, column: 1) == content { return }
      if !force && sqlite3_column_double(last, 2) < 300 { return }
    }
    let bytes = title.utf8.count + content.utf8.count
    guard bytes <= 20 * 1024 * 1024 else { return }  // Current oversized documents are still saved.
    let insert = try prepareUnlocked(
      "INSERT INTO note_asset_versions(id,note_id,title,content,revision,source,bytes) VALUES(?,?,?,?,?,?,?)"
    )
    defer { sqlite3_finalize(insert) }
    let versionID = UUID().uuidString.lowercased()
    for (index, value) in [versionID, id, title, content, revision, source, String(bytes)]
      .enumerated()
    {
      try bind(value, at: Int32(index + 1), to: insert)
    }
    try stepDone(insert)
    try recordHistoryUnlocked(
      WorkspaceHistoryEvent(
        harness: "woven-note", kind: "asset.checkpoint",
        payload: String(
          decoding: try JSONEncoder().encode([
            "noteID": id, "versionID": versionID, "revision": revision, "source": source,
          ]), as: UTF8.self)))
    let prune = try prepareUnlocked(
      """
      DELETE FROM note_asset_versions WHERE sequence IN (
        SELECT sequence FROM (SELECT sequence,row_number() OVER (ORDER BY sequence DESC) AS n,
          sum(bytes) OVER (ORDER BY sequence DESC) AS total FROM note_asset_versions WHERE note_id=?)
        WHERE n>50 OR total>20971520
      )
      """)
    defer { sqlite3_finalize(prune) }
    try bind(id, at: 1, to: prune)
    try stepDone(prune)
    try executeUnlocked(
      """
      DELETE FROM note_asset_versions WHERE sequence IN (
        SELECT sequence FROM (SELECT sequence,sum(bytes) OVER (ORDER BY sequence DESC) AS total FROM note_asset_versions)
        WHERE total>268435456
      )
      """)
  }

  public func noteAssetVersions(id: String) throws -> [NoteAssetVersion] {
    try withLock {
      let rows = try historyRowsUnlocked(
        "SELECT * FROM note_asset_versions WHERE note_id=? ORDER BY sequence DESC", values: [id])
      return rows.compactMap { value -> NoteAssetVersion? in
        guard let row = value.objectValue else { return nil }
        func s(_ key: String) -> String { row[key]?.stringValue ?? "" }
        return NoteAssetVersion(
          id: s("id"), noteID: s("note_id"), title: s("title"), content: s("content"),
          revision: s("revision"), createdAt: s("created_at"), source: s("source"))
      }
    }
  }

  /// Restore is an application mutation, deliberately not a history CLI command.
  public func restoreNoteAssetVersion(noteID: String, versionID: String, expectedRevision: String, callerConversationID: String? = nil,
                                      requestID: String? = nil) throws -> NoteEditingResponse
  {
    try transaction {
      if let callerConversationID { try requireToolUnlocked(.notes, sessionID: callerConversationID) }
      return try performToolMutationUnlocked(callerID: callerConversationID, requestID: requestID,
        operation: "notes.restore", input: [noteID, versionID, expectedRevision], receipt: noteMutationReceipt) {
        let operatorID = try localMutationOperatorIDUnlocked()
        let current = try noteForEditingUnlocked(id: noteID, operatorID: operatorID)
        guard current.revision == expectedRevision else {
          throw WorkspaceNoteMutationError.revisionConflict
        }
        let rows = try historyRowsUnlocked(
          "SELECT title,content FROM note_asset_versions WHERE id=? AND note_id=?",
          values: [versionID, noteID])
        guard let row = rows.first?.objectValue, let title = row["title"]?.stringValue,
          let content = row["content"]?.stringValue
        else {
          throw WorkspaceDatabaseError.open("This version is no longer retained")
        }
        try checkpointNoteUnlocked(id: noteID, source: "before-restore", force: true)
        let update = try prepareUnlocked(
          "UPDATE notes SET title=?,content=?,snippet=?,updated_at=? WHERE id=? AND user_id=?")
        defer { sqlite3_finalize(update) }
        let updatedAt = try nextNoteUpdatedAtUnlocked(id: noteID)
        for (index, value) in [
          title, content, Self.noteSnippet(content), updatedAt, noteID, operatorID,
        ].enumerated() {
          try bind(value, at: Int32(index + 1), to: update)
        }
        try stepDone(update)
        try checkpointNoteUnlocked(id: noteID, source: "restore", force: true)
        return NoteEditingResponse(
          success: true, noteID: noteID, title: title,
          revision: try noteForEditingUnlocked(id: noteID, operatorID: operatorID).revision,
          document: NoteDocument.decode(content))
      }.result
    }
  }
}

extension WorkspaceDatabase {
  public func checkpointNote(id: String) throws {
    try transaction { try checkpointNoteUnlocked(id: id, source: "editor-checkpoint", force: true) }
  }
}

extension WorkspaceDatabase {
  // Preserve chronological metadata even for writes within one millisecond.
  // Optimistic revision tokens come from companion_versions, never this timestamp.
  func nextNoteUpdatedAtUnlocked(id: String, now: Date = Date()) throws -> String {
    let rows = try historyRowsUnlocked("SELECT updated_at FROM notes WHERE id=?", values: [id])
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let previous = rows.first?.objectValue?["updated_at"]?.stringValue.flatMap {
      formatter.date(from: $0)
    }
    return Self.timestamp(max(now, (previous ?? .distantPast).addingTimeInterval(0.002)))
  }
}

extension WorkspaceDatabase {
  func attachSessionMessageUnlocked(requestID: String, messageID: String) throws {
    try validateClaimedToolDeliveryUnlocked(id: requestID)
    let statement = try prepareUnlocked(
      """
      UPDATE workspace_session_deliveries SET message_id=?,status='accepted' WHERE id=?
        AND target_id=(SELECT conversation_id FROM dashboard_messages WHERE id=?)
        AND message_id IS NULL AND status='sending'
      """)
    defer { sqlite3_finalize(statement) }
    try bind(messageID, at: 1, to: statement)
    try bind(requestID, at: 2, to: statement)
    try bind(messageID, at: 3, to: statement)
    try stepDone(statement)
    guard changedRowCountUnlocked == 1 else {
      throw WorkspaceDatabaseError.open("Unable to attach session attribution")
    }
  }
}

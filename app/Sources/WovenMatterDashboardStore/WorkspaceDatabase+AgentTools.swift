import Foundation
import CryptoKit
import SQLite3
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabaseConnection {
  func canonicalToolRequestID(_ value: String) throws -> String {
    guard let id = UUID(uuidString: value) else {
      throw WorkspaceToolError.invalid("A mutation request needs a UUID request ID.")
    }
    return id.uuidString.lowercased()
  }

  enum ToolReceiptTable: String {
    case mutations = "workspace_tool_mutations"
    case deliveries = "workspace_session_deliveries"
    case creations = "workspace_session_creations"
    case coordination = "workspace_coordination_access_requests"
  }

  /// New IDs use lowercase UUIDs; existing IDs retain their spelling so all
  /// persisted references continue to work. Never guess between legacy collisions.
  func persistedToolRequestID(_ value: String, in table: ToolReceiptTable,
                              sourceID: String? = nil) throws -> String {
    let canonical = try canonicalToolRequestID(value)
    let column = table == .mutations ? "request_id" : "id"
    var sql = "SELECT \(column) AS id FROM \(table.rawValue) WHERE \(column)=? COLLATE NOCASE"
    var values: [String?] = [canonical]
    if table == .mutations {
      guard let sourceID else { throw WorkspaceToolError.invalid("A mutation needs a bound caller.") }
      sql += " AND source_id=?"; values.append(sourceID)
    }
    let matches = try historyRowsUnlocked(sql + " LIMIT 2", values: values)
    guard matches.count <= 1 else {
      throw WorkspaceToolError.invalid("This request ID has conflicting legacy receipts. Inspect the existing results before starting a new request.")
    }
    return matches.first?.objectValue?["id"]?.stringValue ?? canonical
  }

  func migrateAgentTools() throws {
    try transaction {
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS workspace_tool_mutations(
          source_id TEXT NOT NULL REFERENCES dashboard_conversations(id), request_id TEXT NOT NULL,
          operation TEXT NOT NULL, input_digest TEXT NOT NULL, result_json TEXT NOT NULL,
          PRIMARY KEY(source_id,request_id));
        CREATE TABLE IF NOT EXISTS workspace_tool_settings(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_opencode_input_context(
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, visible_text TEXT NOT NULL, delivery_id TEXT);
        CREATE TABLE IF NOT EXISTS workspace_tool_schema(version INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS workspace_session_tools(
          session_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id), enabled_json TEXT NOT NULL,
          defaults_applied INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS workspace_executor_sessions(
          session_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id), profiles_json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_session_grants(
          source_id TEXT NOT NULL REFERENCES dashboard_conversations(id),
          target_id TEXT NOT NULL REFERENCES dashboard_conversations(id),
          kind TEXT NOT NULL CHECK(kind IN ('attachment','approved')),
          PRIMARY KEY(source_id,target_id,kind));
        CREATE TABLE IF NOT EXISTS workspace_session_relationships(
          session_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id),
          created_by TEXT REFERENCES dashboard_conversations(id),
          coordinator_id TEXT REFERENCES dashboard_conversations(id),
          purpose TEXT, notifications_enabled INTEGER NOT NULL DEFAULT 1,
          CHECK(session_id != created_by), CHECK(session_id != coordinator_id));
        CREATE INDEX IF NOT EXISTS workspace_coordinator ON workspace_session_relationships(coordinator_id);
        CREATE TABLE IF NOT EXISTS workspace_session_timers(
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES dashboard_conversations(id),
          instruction TEXT NOT NULL, next_fire_at REAL NOT NULL, interval_seconds REAL,
          is_paused INTEGER NOT NULL DEFAULT 0, pending_delivery_id TEXT);
        CREATE INDEX IF NOT EXISTS workspace_timer_due ON workspace_session_timers(is_paused,next_fire_at);
        CREATE TABLE IF NOT EXISTS workspace_coordination_access_requests(
          id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES dashboard_conversations(id),
          target_id TEXT NOT NULL REFERENCES dashboard_conversations(id), purpose TEXT NOT NULL,
          notifications INTEGER NOT NULL, state TEXT NOT NULL, error TEXT,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
        CREATE INDEX IF NOT EXISTS workspace_access_requests_state ON workspace_coordination_access_requests(state,created_at);
        CREATE TABLE IF NOT EXISTS workspace_session_creations(
          id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES dashboard_conversations(id),
          target_id TEXT NOT NULL UNIQUE, arguments_json TEXT NOT NULL,
          purpose TEXT NOT NULL, managed INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'planned');
        """)
      for table in [ToolReceiptTable.mutations, .deliveries, .creations, .coordination] {
        let columns = table == .mutations ? "source_id,request_id COLLATE NOCASE" : "id COLLATE NOCASE"
        try executeUnlocked("CREATE INDEX IF NOT EXISTS \(table.rawValue)_request_case ON \(table.rawValue)(\(columns))")
      }
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO workspace_tool_settings(id,value) VALUES(1,?)",
                               [try toolsJSON(WorkspaceToolSettings())])
      let toolColumns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_session_tools)", values: []).compactMap { $0.objectValue?["name"]?.stringValue })
      if !toolColumns.contains("defaults_applied") {
        // Existing sessions have already chosen their tools. Only new insertions
        // may consume captured defaults after this migration.
        try executeUnlocked("ALTER TABLE workspace_session_tools ADD COLUMN defaults_applied INTEGER NOT NULL DEFAULT 1")
      }
      let creationColumns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_session_creations)", values: []).compactMap { $0.objectValue?["name"]?.stringValue })
      if !creationColumns.contains("configuration_json") {
        try executeUnlocked("ALTER TABLE workspace_session_creations ADD COLUMN configuration_json TEXT")
      }
      if !creationColumns.contains("configuration_applied") {
        try executeUnlocked("ALTER TABLE workspace_session_creations ADD COLUMN configuration_applied INTEGER NOT NULL DEFAULT 0")
      }
      let accessColumns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_coordination_access_requests)", values: [])
        .compactMap { $0.objectValue?["name"]?.stringValue })
      if !accessColumns.contains("coordination_epoch") {
        try executeUnlocked("ALTER TABLE workspace_coordination_access_requests ADD COLUMN coordination_epoch TEXT")
      }
      let relationshipColumns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_session_relationships)", values: []).compactMap { $0.objectValue?["name"]?.stringValue })
      for column in ["coordination_epoch", "coordination_since"] where !relationshipColumns.contains(column) {
        try executeUnlocked("ALTER TABLE workspace_session_relationships ADD COLUMN \(column) TEXT")
      }
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS workspace_coordination_observations(
          epoch TEXT NOT NULL, event_key TEXT NOT NULL, PRIMARY KEY(epoch,event_key));
        UPDATE workspace_session_relationships SET coordination_epoch=lower(hex(randomblob(16))),
          coordination_since=strftime('%Y-%m-%dT%H:%M:%fZ','now')
          WHERE coordinator_id IS NOT NULL AND coordination_epoch IS NULL;
        """)
      let columns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_session_deliveries)", values: []).compactMap { $0.objectValue?["name"]?.stringValue })
      for (name, type) in [("kind", "TEXT NOT NULL DEFAULT 'message'"), ("purpose", "TEXT"),
                           ("target_title", "TEXT"), ("target_harness", "TEXT"), ("target_model", "TEXT"), ("event_key", "TEXT"),
                           ("transport_started", "INTEGER NOT NULL DEFAULT 1"), ("retry_after", "REAL"),
                           ("native_command", "TEXT"), ("failure_code", "TEXT"),
                           ("failure_reason", "TEXT")] where !columns.contains(name) {
        try executeUnlocked("ALTER TABLE workspace_session_deliveries ADD COLUMN \(name) \(type)")
      }
      try executeUnlocked("CREATE UNIQUE INDEX IF NOT EXISTS workspace_delivery_event ON workspace_session_deliveries(event_key) WHERE event_key IS NOT NULL")
      if try historyRowsUnlocked("SELECT 1 FROM workspace_tool_schema WHERE version=1", values: []).isEmpty {
        try executeUnlocked("""
          INSERT OR IGNORE INTO workspace_session_grants(source_id,target_id,kind)
            SELECT r.conversation_id,r.resource_id,'attachment' FROM dashboard_message_references r
            JOIN dashboard_conversations source ON source.id=r.conversation_id
            JOIN dashboard_conversations target ON target.id=r.resource_id
            WHERE r.resource_type='conversation' AND r.source='attached'
              AND source.deleted_at IS NULL AND target.deleted_at IS NULL;
          INSERT INTO workspace_tool_schema(version) VALUES(1);
          """)
      }
      // Existing and newly imported sessions take a snapshot of the defaults.
      try executeUnlocked("""
        INSERT OR IGNORE INTO workspace_session_tools(session_id,enabled_json,defaults_applied)
          SELECT id,(SELECT json_extract(value,'$.enabledByDefault') FROM workspace_tool_settings WHERE id=1),1
          FROM dashboard_conversations;
        INSERT OR IGNORE INTO workspace_executor_sessions(session_id,profiles_json)
          SELECT id,'[]' FROM dashboard_conversations;
        DROP TRIGGER IF EXISTS workspace_session_tool_defaults;
        CREATE TRIGGER workspace_session_tool_defaults AFTER INSERT ON dashboard_conversations BEGIN
          INSERT OR IGNORE INTO workspace_session_tools(session_id,enabled_json,defaults_applied)
            VALUES(new.id,(SELECT json_extract(value,'$.enabledByDefault') FROM workspace_tool_settings WHERE id=1),0);
          INSERT OR IGNORE INTO workspace_executor_sessions(session_id,profiles_json)
            VALUES(new.id,COALESCE((SELECT json_extract(value,'$.executor.defaultProfiles') FROM workspace_tool_settings WHERE id=1),'[]'));
        END;
        """)
    }
  }

  public func toolSettings() throws -> WorkspaceToolSettings {
    try withLock { try toolSettingsUnlocked() }
  }

  public func saveToolSettings(_ settings: WorkspaceToolSettings) throws {
    try settings.validate()
    try transaction { try toolsExecuteUnlocked("UPDATE workspace_tool_settings SET value=? WHERE id=1", [try toolsJSON(settings)]) }
  }

  func toolSettingsUnlocked() throws -> WorkspaceToolSettings {
    let rows = try historyRowsUnlocked("SELECT value FROM workspace_tool_settings WHERE id=1", values: [])
    guard let value = rows.first?.objectValue?["value"]?.stringValue else {
      throw WorkspaceToolError.invalid("Tool settings are unavailable.")
    }
    let settings = try JSONDecoder().decode(WorkspaceToolSettings.self, from: Data(value.utf8))
    try settings.validate()
    return settings
  }

  public func sessionTools(_ id: String) throws -> WorkspaceSessionTools {
    try withLock { try sessionToolsUnlocked(id) }
  }

  func sessionToolsUnlocked(_ id: String) throws -> WorkspaceSessionTools {
    try requireToolSessionUnlocked(id)
    let rows = try historyRowsUnlocked("SELECT enabled_json FROM workspace_session_tools WHERE session_id=?", values: [id])
    guard let json = rows.first?.objectValue?["enabled_json"]?.stringValue else {
      throw WorkspaceToolError.invalid("Session tool settings are unavailable.")
    }
    let selection = try historyRowsUnlocked("SELECT profiles_json FROM workspace_executor_sessions WHERE session_id=?", values: [id]).first?.objectValue?["profiles_json"]?.stringValue ?? "[]"
    return WorkspaceSessionTools(enabled: try JSONDecoder().decode(Set<WorkspaceToolGroup>.self, from: Data(json.utf8)), executorProfiles: try JSONDecoder().decode(Set<String>.self, from: Data(selection.utf8)))
  }

  /// Called by the user's controls, never exposed as an agent command.
  public func setSessionTools(_ tools: WorkspaceSessionTools, sessionID: String,
                              confirmedPausingTimers: Bool = false) throws {
    try transaction {
      try setSessionToolsUnlocked(tools, sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers)
    }
  }

  func setSessionToolEnabled(_ group: WorkspaceToolGroup, enabled: Bool,
    sessionID: String, confirmedPausingTimers: Bool) throws -> WorkspaceSessionTools {
    try transaction {
      var policy = try sessionToolsUnlocked(sessionID)
      if enabled { policy.enabled.insert(group) } else { policy.enabled.remove(group) }
      try setSessionToolsUnlocked(policy, sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers)
      return policy
    }
  }

  private func setSessionToolsUnlocked(_ tools: WorkspaceSessionTools, sessionID: String,
    confirmedPausingTimers: Bool) throws {
    try requireToolSessionUnlocked(sessionID)
    if !tools.enabled.contains(.timers) {
      let active = try historyRowsUnlocked("SELECT id FROM workspace_session_timers WHERE session_id=? AND is_paused=0 LIMIT 1", values: [sessionID])
      guard active.isEmpty || confirmedPausingTimers else { throw WorkspaceToolError.timerPauseConfirmation }
      try toolsExecuteUnlocked("UPDATE workspace_session_timers SET is_paused=1,pending_delivery_id=NULL WHERE session_id=?", [sessionID])
    }
    if !tools.enabled.contains(.sessions) {
      try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE coordinator_id=?", [sessionID])
      // Approved access lasts for a management assignment; attachments are independent.
      try toolsExecuteUnlocked("DELETE FROM workspace_session_grants WHERE source_id=? AND kind='approved'", [sessionID])
    }
    if let profiles = tools.executorProfiles {
      try toolsExecuteUnlocked("UPDATE workspace_executor_sessions SET profiles_json=? WHERE session_id=?", [try toolsJSON(profiles), sessionID])
    }
    try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=?,defaults_applied=1 WHERE session_id=?", [try toolsJSON(tools.enabled), sessionID])
  }

  /// New-chat defaults are applied at most once, before any tools run. An
  /// explicit user change also seals the snapshot, including an empty tool set.
  public func applyInitialSessionTools(_ tools: WorkspaceSessionTools, sessionID: String) throws {
    try transaction {
      try requireToolSessionUnlocked(sessionID)
      let row = try historyRowsUnlocked("SELECT defaults_applied FROM workspace_session_tools WHERE session_id=?", values: [sessionID]).first
      guard row?.objectValue?["defaults_applied"]?.intValue == 0 else { return }
      if let profiles = tools.executorProfiles {
        try toolsExecuteUnlocked("UPDATE workspace_executor_sessions SET profiles_json=? WHERE session_id=?", [try toolsJSON(profiles), sessionID])
      }
      try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=?,defaults_applied=1 WHERE session_id=?", [try toolsJSON(tools.enabled), sessionID])
    }
  }

  public func requireTool(_ group: WorkspaceToolGroup, sessionID: String, writesCalendar: Bool = false) throws {
    try withLock { try requireToolUnlocked(group, sessionID: sessionID, writesCalendar: writesCalendar) }
  }

  func requireToolUnlocked(_ group: WorkspaceToolGroup, sessionID: String, writesCalendar: Bool = false) throws {
    guard try sessionToolsUnlocked(sessionID).enabled.contains(group) else { throw WorkspaceToolError.disabled(group) }
    if group == .calendar, writesCalendar, try toolSettingsUnlocked().calendarAccess != .full {
      throw WorkspaceToolError.invalid("Calendar is read only. Change its access in General settings.")
    }
  }

  func requireToolSessionUnlocked(_ id: String) throws {
    guard !(try historyRowsUnlocked("SELECT id FROM dashboard_conversations WHERE id=? AND deleted_at IS NULL", values: [id])).isEmpty else {
      throw WorkspaceToolError.invalid("The session is unavailable.")
    }
  }

  /// Reference attachments are granted by the composer, not by text or CLI input.
  public func attachConversationReference(sourceID: String, targetID: String) throws {
    try transaction { try grantSessionReadUnlocked(sourceID: sourceID, targetID: targetID, kind: "attachment") }
  }

  public func removeConversationReference(sourceID: String, targetID: String) throws {
    try transaction { try toolsExecuteUnlocked("DELETE FROM workspace_session_grants WHERE source_id=? AND target_id=? AND kind='attachment'", [sourceID, targetID]) }
  }

  func grantSessionReadUnlocked(sourceID: String, targetID: String, kind: String) throws {
    try requireToolSessionUnlocked(sourceID)
    try requireToolSessionUnlocked(targetID)
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO workspace_session_grants(source_id,target_id,kind) VALUES(?,?,?)", [sourceID, targetID, kind])
  }

  public func requireTranscriptAccess(sourceID: String, targetID: String) throws {
    try withLock { try requireTranscriptAccessUnlocked(sourceID: sourceID, targetID: targetID) }
  }

  func requireTranscriptAccessUnlocked(sourceID: String, targetID: String) throws {
    let tools = try sessionToolsUnlocked(sourceID)
    try requireToolSessionUnlocked(targetID)
    if sourceID == targetID || tools.enabled.contains(.history) { return }
    if !(try historyRowsUnlocked("SELECT 1 FROM workspace_session_grants WHERE source_id=? AND target_id=? AND kind='attachment'", values: [sourceID, targetID])).isEmpty { return }
    if tools.enabled.contains(.sessions),
       try relationshipUnlocked(targetID).coordinatorID == sourceID { return }
    throw WorkspaceToolError.accessRequired(targetID)
  }

  public func sessionRelationships() throws -> [WorkspaceSessionRelationship] {
    try withLock {
      try historyRowsUnlocked("SELECT * FROM workspace_session_relationships", values: []).map(relationshipFromRow)
    }
  }

  public func sessionRelationship(_ id: String) throws -> WorkspaceSessionRelationship {
    try withLock { try relationshipUnlocked(id) }
  }

  func relationshipUnlocked(_ id: String) throws -> WorkspaceSessionRelationship {
    let rows = try historyRowsUnlocked("SELECT * FROM workspace_session_relationships WHERE session_id=?", values: [id])
    return rows.first.map(relationshipFromRow) ?? WorkspaceSessionRelationship(sessionID: id)
  }

  private func relationshipFromRow(_ value: GatewayJSONValue) -> WorkspaceSessionRelationship {
    let r = value.objectValue ?? [:]
    return WorkspaceSessionRelationship(sessionID: r["session_id"]?.stringValue ?? "",
      createdBy: r["created_by"]?.stringValue, coordinatorID: r["coordinator_id"]?.stringValue,
      purpose: r["purpose"]?.stringValue, notificationsEnabled: r["notifications_enabled"]?.intValue == 1,
      coordinationEpoch: r["coordination_epoch"]?.stringValue,
      coordinationSince: r["coordination_since"]?.stringValue)
  }

  /// Called only after app-owned session creation succeeds. Origin cannot be reassigned.
  public func recordSessionOrigin(sourceID: String, targetID: String, purpose: String, managed: Bool = true) throws {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      try requireToolSessionUnlocked(targetID)
      guard sourceID != targetID else { throw WorkspaceToolError.invalid("A session cannot create itself.") }
      let relationship = try relationshipUnlocked(targetID)
      guard relationship.createdBy == nil || relationship.createdBy == sourceID else {
        throw WorkspaceToolError.invalid("Session origin is permanent.")
      }
      if relationship.createdBy == sourceID { return }
      if managed { try validateCoordinationUnlocked(sourceID: sourceID, targetID: targetID) }
      try toolsExecuteUnlocked("""
        INSERT INTO workspace_session_relationships(session_id,created_by,purpose) VALUES(?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET created_by=excluded.created_by
        """, [targetID, sourceID, purpose])
      let inherited = try sessionToolsUnlocked(sourceID)
      try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=?,defaults_applied=1 WHERE session_id=?", [try toolsJSON(inherited.enabled), targetID])
      try toolsExecuteUnlocked("UPDATE workspace_executor_sessions SET profiles_json=? WHERE session_id=?", [try toolsJSON(inherited.executorProfiles ?? []), targetID])
      if managed { try beginCoordinationUnlocked(sourceID: sourceID, targetID: targetID, purpose: purpose, notifications: true) }
    }
  }

  public func beginCoordination(sourceID: String, targetID: String, purpose: String,
                                 notifications: Bool = true, userApprovedAccess: Bool = false) throws {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      try validateCoordinationUnlocked(sourceID: sourceID, targetID: targetID)
      if !userApprovedAccess { try requireTranscriptAccessUnlocked(sourceID: sourceID, targetID: targetID) }
      try beginCoordinationUnlocked(sourceID: sourceID, targetID: targetID, purpose: purpose, notifications: notifications)
    }
  }

  func validateCoordinationUnlocked(sourceID: String, targetID: String) throws {
    try requireToolSessionUnlocked(targetID)
    guard sourceID != targetID else { throw WorkspaceToolError.invalid("A session cannot coordinate itself.") }
    let existing = try relationshipUnlocked(targetID).coordinatorID
    if let existing, existing != sourceID { throw WorkspaceToolError.coordinationConflict(existing) }
    if existing == sourceID { return }
    let limit = try toolSettingsUnlocked().maximumManagedSessions
    guard try managedSessionCountUnlocked(sourceID, excluding: targetID) < limit else { throw WorkspaceToolError.managedLimit(limit) }
    var cursor: String? = sourceID
    var visited = Set<String>()
    while let id = cursor {
      guard id != targetID, visited.insert(id).inserted else { throw WorkspaceToolError.invalid("Coordination cannot form a cycle.") }
      cursor = try relationshipUnlocked(id).coordinatorID
    }
  }

  func managedSessionCountUnlocked(_ sourceID: String, excluding targetID: String? = nil) throws -> Int {
    let rows = try historyRowsUnlocked("""
      SELECT count(*) AS n FROM (
        SELECT r.session_id AS id FROM workspace_session_relationships r
          JOIN dashboard_conversations c ON c.id=r.session_id WHERE r.coordinator_id=? AND c.deleted_at IS NULL
        UNION SELECT target_id AS id FROM workspace_session_creations WHERE source_id=? AND managed=1 AND status='planned'
      ) WHERE id != coalesce(?,'')
      """, values: [sourceID, sourceID, targetID])
    return rows.first?.objectValue?["n"]?.intValue ?? 0
  }

  func beginCoordinationUnlocked(sourceID: String, targetID: String, purpose: String, notifications: Bool) throws {
    let existing = try relationshipUnlocked(targetID).coordinatorID
    let epoch = UUID().uuidString.lowercased()
    try toolsExecuteUnlocked("""
      INSERT INTO workspace_session_relationships(session_id,coordinator_id,purpose,notifications_enabled,coordination_epoch,coordination_since)
      VALUES(?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET
        coordinator_id=excluded.coordinator_id,purpose=excluded.purpose,notifications_enabled=excluded.notifications_enabled,
        coordination_epoch=CASE WHEN workspace_session_relationships.coordinator_id=excluded.coordinator_id
          THEN coalesce(workspace_session_relationships.coordination_epoch,excluded.coordination_epoch) ELSE excluded.coordination_epoch END,
        coordination_since=CASE WHEN workspace_session_relationships.coordinator_id=excluded.coordinator_id
          THEN coalesce(workspace_session_relationships.coordination_since,excluded.coordination_since) ELSE excluded.coordination_since END
      """, [targetID, sourceID, purpose, notifications ? "1" : "0", epoch, Self.timestamp(Date())])
    if existing != sourceID {
      // A reassigned session must not deliver stale queued notifications from a
      // previous assignment, even if the same coordinator later acquires it.
      try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='cancelled' WHERE source_id=? AND kind='notification' AND status='queued'", [targetID])
    }
  }

  public func setCoordinationNotifications(sourceID: String, targetID: String, enabled: Bool) throws {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      guard try relationshipUnlocked(targetID).coordinatorID == sourceID else {
        throw WorkspaceToolError.invalid("Only this session's coordinator may change its notifications.")
      }
      try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET notifications_enabled=? WHERE session_id=?", [enabled ? "1" : "0", targetID])
    }
  }

  public func setAgentCoordinationNotifications(sourceID: String, targetID: String, epoch: String,
                                                 enabled: Bool, requestID: String) throws -> WorkspaceCoordinationMutationReceipt {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      let input = CoordinationMutationInput(targetID: targetID, epoch: epoch, enabled: enabled)
      let outcome = try performToolMutationUnlocked(callerID: sourceID, requestID: requestID,
        operation: "sessions.notifications", input: input, receipt: { (value: WorkspaceCoordinationMutationReceipt) in
          var stored = value; stored.replayed = true; return stored
        }) {
          let relationship = try relationshipUnlocked(targetID)
          guard relationship.coordinatorID == sourceID else {
            throw WorkspaceToolError.accessRequired(targetID)
          }
          guard !epoch.isEmpty, epoch.utf8.count <= 128,
                relationship.coordinationEpoch == epoch else {
            throw WorkspaceToolError.revisionConflict("The coordination epoch is stale. Read sessions status and retry with its current epoch.")
          }
          try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET notifications_enabled=? WHERE session_id=?", [enabled ? "1" : "0", targetID])
          return WorkspaceCoordinationMutationReceipt(sessionID: targetID,
            coordinationEpoch: epoch, action: "notifications", notificationsEnabled: enabled)
        }
      return outcome.result
    }
  }

  public func releaseAgentCoordination(sourceID: String, targetID: String, epoch: String,
                                       requestID: String) throws -> WorkspaceCoordinationMutationReceipt {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      let input = CoordinationMutationInput(targetID: targetID, epoch: epoch, enabled: nil)
      let outcome = try performToolMutationUnlocked(callerID: sourceID, requestID: requestID,
        operation: "sessions.release", input: input, receipt: { (value: WorkspaceCoordinationMutationReceipt) in
          var stored = value; stored.replayed = true; return stored
        }) {
          let relationship = try relationshipUnlocked(targetID)
          guard relationship.coordinatorID == sourceID else {
            throw WorkspaceToolError.accessRequired(targetID)
          }
          guard !epoch.isEmpty, epoch.utf8.count <= 128,
                relationship.coordinationEpoch == epoch else {
            throw WorkspaceToolError.revisionConflict("The coordination epoch is stale. Read sessions status and retry with its current epoch.")
          }
          try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE session_id=?", [targetID])
          try toolsExecuteUnlocked("DELETE FROM workspace_session_grants WHERE target_id=? AND kind='approved'", [targetID])
          return WorkspaceCoordinationMutationReceipt(sessionID: targetID,
            coordinationEpoch: epoch, action: "released")
        }
      return outcome.result
    }
  }

  /// sourceID is bound by the endpoint. The user may stop any assignment through the UI.
  public func endCoordination(targetID: String, sourceID: String? = nil) throws {
    try transaction {
      if let sourceID {
        try requireToolUnlocked(.sessions, sessionID: sourceID)
        if let existing = try relationshipUnlocked(targetID).coordinatorID, existing != sourceID {
          throw WorkspaceToolError.coordinationConflict(existing)
        }
      }
      try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE session_id=?", [targetID])
      try toolsExecuteUnlocked("DELETE FROM workspace_session_grants WHERE target_id=? AND kind='approved'", [targetID])
    }
  }

  func toolsJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  func toolsExecuteUnlocked(_ sql: String, _ values: [String?] = []) throws {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() { try bindNullable(value, at: Int32(index + 1), to: statement) }
    try stepDone(statement)
  }
}

private struct CoordinationMutationInput: Codable {
  let targetID: String
  let epoch: String
  let enabled: Bool?
}


extension WorkspaceDatabaseConnection {
  /// Must run inside the mutation's transaction. A receipt and its write commit
  /// together, including when independent connections retry after an app restart.
  /// Callers recheck current authority before returning either a new or saved result.
  func performToolMutationUnlocked<Input: Encodable, Output: Codable>(
    callerID: String?, requestID: String?, operation: String, input: Input,
    receipt: (Output) -> Output = { $0 }, mutation: () throws -> Output
  ) throws -> (result: Output, replayed: Bool) {
    guard let rawRequestID = requestID else { return (try mutation(), false) }
    guard let callerID else {
      throw WorkspaceToolError.invalid("A mutation request needs a bound caller and UUID request ID.")
    }
    let requestID = try persistedToolRequestID(rawRequestID, in: .mutations, sourceID: callerID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = SHA256.hash(data: try encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
    let rows = try historyRowsUnlocked(
      "SELECT operation,input_digest,result_json FROM workspace_tool_mutations WHERE source_id=? AND request_id=?",
      values: [callerID, requestID])
    if let row = rows.first?.objectValue {
      guard row["operation"]?.stringValue == operation, row["input_digest"]?.stringValue == digest,
            let json = row["result_json"]?.stringValue else {
        throw WorkspaceToolError.invalid("This request ID was already used for a different mutation.")
      }
      return (try JSONDecoder().decode(Output.self, from: Data(json.utf8)), true)
    }
    let result = try mutation()
    let json = String(decoding: try encoder.encode(receipt(result)), as: UTF8.self)
    try toolsExecuteUnlocked(
      "INSERT INTO workspace_tool_mutations(source_id,request_id,operation,input_digest,result_json) VALUES(?,?,?,?,?)",
      [callerID, requestID, operation, digest, json])
    return (result, false)
  }

  /// Keep only an acknowledgement, never another unbounded copy of note contents.
  func noteMutationReceipt(_ response: NoteEditingResponse) -> NoteEditingResponse {
    NoteEditingResponse(success: response.success, noteID: response.noteID,
      revision: response.revision, error: response.error, replayed: true)
  }
}

// MARK: - Async worker boundary

extension WorkspaceDatabase {
  public func toolSettings() async throws -> WorkspaceToolSettings {
    try await read { try $0.toolSettings() }
  }

  public func saveToolSettings(_ settings: WorkspaceToolSettings) async throws {
    try await write { try $0.saveToolSettings(settings) }
  }

  public func sessionTools(_ id: String) async throws -> WorkspaceSessionTools {
    try await read { try $0.sessionTools(id) }
  }

  public func setSessionTools(_ tools: WorkspaceSessionTools, sessionID: String,
                              confirmedPausingTimers: Bool = false) async throws {
    try await write { try $0.setSessionTools(tools, sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers) }
  }

  public func applyInitialSessionTools(_ tools: WorkspaceSessionTools, sessionID: String) async throws {
    try await write { try $0.applyInitialSessionTools(tools, sessionID: sessionID) }
  }

  public func requireTool(_ group: WorkspaceToolGroup, sessionID: String, writesCalendar: Bool = false) async throws {
    try await read { try $0.requireTool(group, sessionID: sessionID, writesCalendar: writesCalendar) }
  }

  public func attachConversationReference(sourceID: String, targetID: String) async throws {
    try await write { try $0.attachConversationReference(sourceID: sourceID, targetID: targetID) }
  }

  public func removeConversationReference(sourceID: String, targetID: String) async throws {
    try await write { try $0.removeConversationReference(sourceID: sourceID, targetID: targetID) }
  }

  public func requireTranscriptAccess(sourceID: String, targetID: String) async throws {
    try await read { try $0.requireTranscriptAccess(sourceID: sourceID, targetID: targetID) }
  }

  public func sessionRelationships() async throws -> [WorkspaceSessionRelationship] {
    try await read { try $0.sessionRelationships() }
  }

  public func sessionRelationship(_ id: String) async throws -> WorkspaceSessionRelationship {
    try await read { try $0.sessionRelationship(id) }
  }

  public func recordSessionOrigin(sourceID: String, targetID: String, purpose: String, managed: Bool = true) async throws {
    try await write { try $0.recordSessionOrigin(sourceID: sourceID, targetID: targetID, purpose: purpose, managed: managed) }
  }

  public func beginCoordination(sourceID: String, targetID: String, purpose: String,
                                 notifications: Bool = true, userApprovedAccess: Bool = false) async throws {
    try await write { try $0.beginCoordination(sourceID: sourceID, targetID: targetID, purpose: purpose, notifications: notifications, userApprovedAccess: userApprovedAccess) }
  }

  public func setCoordinationNotifications(sourceID: String, targetID: String, enabled: Bool) async throws {
    try await write { try $0.setCoordinationNotifications(sourceID: sourceID, targetID: targetID, enabled: enabled) }
  }

  public func endCoordination(targetID: String, sourceID: String? = nil) async throws {
    try await write { try $0.endCoordination(targetID: targetID, sourceID: sourceID) }
  }
}

public struct WorkspaceToolStateSnapshot: Sendable {
  public let settings: WorkspaceToolSettings
  public let relationships: [WorkspaceSessionRelationship]
  public let timers: [WorkspaceSessionTimer]
  public let policies: [String: WorkspaceSessionTools]
  public let receipts: [String: [WorkspaceSessionDelivery]]
}

extension WorkspaceDatabase {
  public func setSessionExecutorProfiles(_ profiles: Set<String>, sessionID: String) async throws {
    try await write { connection in
      // Scope synchronization awaits network IO. Apply only its edited field to
      // the latest policy so another tool's concurrent revocation stays revoked.
      var policy = try connection.sessionTools(sessionID)
      policy.executorProfiles = profiles
      try connection.setSessionTools(policy, sessionID: sessionID)
    }
  }
  public func saveToolSettings(_ settings: WorkspaceToolSettings, from base: WorkspaceToolSettings) async throws {
    try await write { connection in
      let current = try connection.toolSettings()
      try connection.saveToolSettings(current.applyingChanges(from: base, to: settings))
    }
  }
  public func updateExecutor(configuration: ExecutorConfiguration? = nil, apps: [ExecutorAppProfile]? = nil,
                             setup: ExecutorSetupState? = nil, clearSetup: Bool = false) async throws {
    try await write { connection in
      var value = try connection.toolSettings()
      if var configuration {
        if let current = value.executor, current.id == configuration.id {
          configuration.defaultProfiles = current.defaultProfiles
          configuration.apps = current.apps
        }
        value.executor = configuration
      }
      if let apps {
        value.executor?.apps = apps
        value.executor?.defaultProfiles.formIntersection(Set(apps.map(\.id)))
      }
      if let setup { value.executorSetup = setup }
      if clearSetup { value.executorSetup = nil }
      try connection.saveToolSettings(value)
    }
  }
}

extension WorkspaceDatabase {
  public func toolStateSnapshot(sessionIDs: Set<String>, oldestReceipts: [String: String],
    receiptSessionIDs: Set<String>? = nil) async throws -> WorkspaceToolStateSnapshot {
    try await read { connection in
      var policies: [String: WorkspaceSessionTools] = [:]
      var receipts: [String: [WorkspaceSessionDelivery]] = [:]
      for id in sessionIDs {
        policies[id] = try? connection.sessionTools(id)
      }
      for id in receiptSessionIDs ?? sessionIDs {
        if let oldest = oldestReceipts[id] {
          receipts[id] = try connection.sessionActivityWindow(sessionID: id, throughID: oldest)
        } else {
          receipts[id] = try connection.sessionDeliveries(sessionID: id, limit: 201, activityOnly: true)
        }
      }
      return WorkspaceToolStateSnapshot(settings: try connection.toolSettings(),
        relationships: try connection.sessionRelationships(), timers: try connection.sessionTimers(),
        policies: policies, receipts: receipts)
    }
  }

  public func setSessionToolEnabled(_ group: WorkspaceToolGroup, enabled: Bool,
    sessionID: String, confirmedPausingTimers: Bool = false) async throws -> WorkspaceSessionTools {
    try await write { try $0.setSessionToolEnabled(group, enabled: enabled,
      sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers) }
  }
}

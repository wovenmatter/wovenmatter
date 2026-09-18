import Foundation
import SQLite3
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  func migrateAgentTools() throws {
    try transaction {
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS workspace_tool_settings(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_session_tools(
          session_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id), enabled_json TEXT NOT NULL);
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
        """)
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO workspace_tool_settings(id,value) VALUES(1,?)",
                               [try toolsJSON(WorkspaceToolSettings())])
      let columns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_session_deliveries)", values: []).compactMap { $0.objectValue?["name"]?.stringValue })
      for (name, type) in [("kind", "TEXT NOT NULL DEFAULT 'message'"), ("purpose", "TEXT"),
                           ("target_title", "TEXT"), ("target_harness", "TEXT"), ("target_model", "TEXT"), ("event_key", "TEXT")] where !columns.contains(name) {
        try executeUnlocked("ALTER TABLE workspace_session_deliveries ADD COLUMN \(name) \(type)")
      }
      try executeUnlocked("CREATE UNIQUE INDEX IF NOT EXISTS workspace_delivery_event ON workspace_session_deliveries(event_key) WHERE event_key IS NOT NULL")
      // Existing and newly imported sessions take a snapshot of the defaults.
      try executeUnlocked("""
        INSERT OR IGNORE INTO workspace_session_tools(session_id,enabled_json)
          SELECT id,(SELECT json_extract(value,'$.enabledByDefault') FROM workspace_tool_settings WHERE id=1)
          FROM dashboard_conversations;
        CREATE TRIGGER IF NOT EXISTS workspace_session_tool_defaults AFTER INSERT ON dashboard_conversations BEGIN
          INSERT OR IGNORE INTO workspace_session_tools(session_id,enabled_json)
            VALUES(new.id,(SELECT json_extract(value,'$.enabledByDefault') FROM workspace_tool_settings WHERE id=1));
        END;
        """)
    }
  }

  public func toolSettings() throws -> WorkspaceToolSettings {
    try lock.withLock { try toolSettingsUnlocked() }
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
    try lock.withLock { try sessionToolsUnlocked(id) }
  }

  func sessionToolsUnlocked(_ id: String) throws -> WorkspaceSessionTools {
    try requireToolSessionUnlocked(id)
    let rows = try historyRowsUnlocked("SELECT enabled_json FROM workspace_session_tools WHERE session_id=?", values: [id])
    guard let json = rows.first?.objectValue?["enabled_json"]?.stringValue else {
      throw WorkspaceToolError.invalid("Session tool settings are unavailable.")
    }
    return WorkspaceSessionTools(enabled: try JSONDecoder().decode(Set<WorkspaceToolGroup>.self, from: Data(json.utf8)))
  }

  /// Called by the user's controls, never exposed as an agent command.
  public func setSessionTools(_ tools: WorkspaceSessionTools, sessionID: String,
                              confirmedPausingTimers: Bool = false) throws {
    try transaction {
      try requireToolSessionUnlocked(sessionID)
      if !tools.enabled.contains(.timers) {
        let active = try historyRowsUnlocked("SELECT id FROM workspace_session_timers WHERE session_id=? AND is_paused=0 LIMIT 1", values: [sessionID])
        guard active.isEmpty || confirmedPausingTimers else { throw WorkspaceToolError.timerPauseConfirmation }
        try toolsExecuteUnlocked("UPDATE workspace_session_timers SET is_paused=1,pending_delivery_id=NULL WHERE session_id=?", [sessionID])
      }
      if !tools.enabled.contains(.sessions) {
        try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=NULL WHERE coordinator_id=?", [sessionID])
        // Approved access lasts for a management assignment; attachments are independent.
        try toolsExecuteUnlocked("DELETE FROM workspace_session_grants WHERE source_id=? AND kind='approved'", [sessionID])
      }
      try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=? WHERE session_id=?", [try toolsJSON(tools.enabled), sessionID])
    }
  }

  public func requireTool(_ group: WorkspaceToolGroup, sessionID: String, writesCalendar: Bool = false) throws {
    try lock.withLock { try requireToolUnlocked(group, sessionID: sessionID, writesCalendar: writesCalendar) }
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
    try lock.withLock { try requireTranscriptAccessUnlocked(sourceID: sourceID, targetID: targetID) }
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
    try lock.withLock {
      try historyRowsUnlocked("SELECT * FROM workspace_session_relationships", values: []).map(relationshipFromRow)
    }
  }

  public func sessionRelationship(_ id: String) throws -> WorkspaceSessionRelationship {
    try lock.withLock { try relationshipUnlocked(id) }
  }

  func relationshipUnlocked(_ id: String) throws -> WorkspaceSessionRelationship {
    let rows = try historyRowsUnlocked("SELECT * FROM workspace_session_relationships WHERE session_id=?", values: [id])
    return rows.first.map(relationshipFromRow) ?? WorkspaceSessionRelationship(sessionID: id)
  }

  private func relationshipFromRow(_ value: GatewayJSONValue) -> WorkspaceSessionRelationship {
    let r = value.objectValue ?? [:]
    return WorkspaceSessionRelationship(sessionID: r["session_id"]?.stringValue ?? "",
      createdBy: r["created_by"]?.stringValue, coordinatorID: r["coordinator_id"]?.stringValue,
      purpose: r["purpose"]?.stringValue, notificationsEnabled: r["notifications_enabled"]?.intValue == 1)
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
      try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=? WHERE session_id=?", [try toolsJSON(inherited.enabled), targetID])
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
    let rows = try historyRowsUnlocked("SELECT count(*) AS n FROM workspace_session_relationships r JOIN dashboard_conversations c ON c.id=r.session_id WHERE r.coordinator_id=? AND c.deleted_at IS NULL", values: [sourceID])
    guard (rows.first?.objectValue?["n"]?.intValue ?? 0) < limit else { throw WorkspaceToolError.managedLimit(limit) }
    var cursor: String? = sourceID
    var visited = Set<String>()
    while let id = cursor {
      guard id != targetID, visited.insert(id).inserted else { throw WorkspaceToolError.invalid("Coordination cannot form a cycle.") }
      cursor = try relationshipUnlocked(id).coordinatorID
    }
  }

  private func beginCoordinationUnlocked(sourceID: String, targetID: String, purpose: String, notifications: Bool) throws {
    try toolsExecuteUnlocked("""
      INSERT INTO workspace_session_relationships(session_id,coordinator_id,purpose,notifications_enabled) VALUES(?,?,?,?)
      ON CONFLICT(session_id) DO UPDATE SET coordinator_id=excluded.coordinator_id,purpose=excluded.purpose,notifications_enabled=excluded.notifications_enabled
      """, [targetID, sourceID, purpose, notifications ? "1" : "0"])
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
      try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=NULL WHERE session_id=?", [targetID])
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

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
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
    case mutations = "tool_mutations"
    case deliveries = "session_deliveries"
    case creations = "session_creations"
    case coordination = "coordination_access_requests"
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

  /// A session's tool choices. `defaults_applied` is 0 until the session's
  /// default tools have been chosen for it.
  static let sessionToolsSQL = """
    CREATE TABLE IF NOT EXISTS session_tools (
      session_id TEXT PRIMARY KEY REFERENCES conversations(id), enabled_json TEXT NOT NULL,
      defaults_applied INTEGER NOT NULL DEFAULT 0);
    """

  func migrateAgentTools() throws {
    try transaction {
      // A source (`source_id`, `created_by`, `coordinator_id`) is any MCP
      // caller: a conversation or an app-wide caller such as a bot. A target
      // is always a conversation.
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS mcp_callers(id TEXT PRIMARY KEY, display_name TEXT, machine_id TEXT,
          revoked INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS mcp_bot_machines(machine_id TEXT PRIMARY KEY, active INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS input_contexts(
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
          note_id TEXT, created_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS tool_mutations(
          source_id TEXT NOT NULL REFERENCES mcp_callers(id), request_id TEXT NOT NULL,
          operation TEXT NOT NULL, input_digest TEXT NOT NULL, result_json TEXT NOT NULL,
          PRIMARY KEY(source_id,request_id));
        CREATE TABLE IF NOT EXISTS tool_settings(id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS opencode_input_contexts(
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, visible_text TEXT NOT NULL, delivery_id TEXT);
        CREATE TABLE IF NOT EXISTS automation_requests(
          source_id TEXT NOT NULL REFERENCES mcp_callers(id), request_id TEXT NOT NULL,
          input_digest TEXT NOT NULL, PRIMARY KEY(source_id,request_id));
        CREATE TABLE IF NOT EXISTS automation_cancellations(
          source_id TEXT NOT NULL REFERENCES mcp_callers(id), request_id TEXT NOT NULL,
          PRIMARY KEY(source_id,request_id));
        \(Self.sessionToolsSQL)
        CREATE TABLE IF NOT EXISTS session_executor_profiles(
          session_id TEXT PRIMARY KEY REFERENCES conversations(id), profiles_json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS session_grants(
          source_id TEXT NOT NULL REFERENCES mcp_callers(id),
          target_id TEXT NOT NULL REFERENCES conversations(id),
          kind TEXT NOT NULL CHECK(kind IN ('attachment','approved')),
          PRIMARY KEY(source_id,target_id,kind));
        CREATE TABLE IF NOT EXISTS session_relationships(
          session_id TEXT PRIMARY KEY REFERENCES conversations(id),
          created_by TEXT REFERENCES mcp_callers(id),
          coordinator_id TEXT REFERENCES mcp_callers(id),
          purpose TEXT, notifications_enabled INTEGER NOT NULL DEFAULT 1,
          coordination_epoch TEXT, coordination_since TEXT,
          CHECK(session_id != created_by), CHECK(session_id != coordinator_id));
        CREATE INDEX IF NOT EXISTS session_relationships_coordinator ON session_relationships(coordinator_id);
        -- A timer's target is a conversation or a bot principal (a bot's own
        -- schedule), so it references neither. Timers of a missing conversation
        -- are never listed or fired.
        CREATE TABLE IF NOT EXISTS session_timers(
          id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
          instruction TEXT NOT NULL, next_fire_at REAL NOT NULL, interval_seconds REAL,
          is_paused INTEGER NOT NULL DEFAULT 0, pending_delivery_id TEXT, outside_mcp INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS session_timers_due ON session_timers(is_paused,next_fire_at);
        CREATE INDEX IF NOT EXISTS session_timers_session ON session_timers(session_id);
        CREATE TABLE IF NOT EXISTS coordination_access_requests(
          id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES mcp_callers(id),
          target_id TEXT NOT NULL REFERENCES conversations(id), purpose TEXT NOT NULL,
          notifications INTEGER NOT NULL, state TEXT NOT NULL, error TEXT,
          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')), coordination_epoch TEXT);
        CREATE INDEX IF NOT EXISTS coordination_access_requests_state ON coordination_access_requests(state,created_at);
        CREATE TABLE IF NOT EXISTS coordination_observations(
          epoch TEXT NOT NULL, event_key TEXT NOT NULL, PRIMARY KEY(epoch,event_key));
        CREATE TABLE IF NOT EXISTS session_creations(
          id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES mcp_callers(id),
          target_id TEXT NOT NULL UNIQUE, arguments_json TEXT NOT NULL,
          purpose TEXT NOT NULL, managed INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'planned',
          configuration_json TEXT, configuration_applied INTEGER NOT NULL DEFAULT 0);
        CREATE UNIQUE INDEX IF NOT EXISTS session_deliveries_event ON session_deliveries(event_key) WHERE event_key IS NOT NULL;
        """)
      for table in [ToolReceiptTable.mutations, .deliveries, .creations, .coordination] {
        let columns = table == .mutations ? "source_id,request_id COLLATE NOCASE" : "id COLLATE NOCASE"
        try executeUnlocked("CREATE INDEX IF NOT EXISTS \(table.rawValue)_request_case ON \(table.rawValue)(\(columns))")
      }
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO tool_settings(id,value) VALUES(1,?)",
                               [try toolsJSON(WorkspaceToolSettings())])
      // Each new session takes a snapshot of the tool and executor defaults.
      try executeUnlocked("""
        CREATE TRIGGER IF NOT EXISTS conversations_session_tools_insert AFTER INSERT ON conversations BEGIN
          INSERT OR IGNORE INTO session_tools(session_id,enabled_json,defaults_applied)
            VALUES(new.id,(SELECT json_extract(value,'$.enabledByDefault') FROM tool_settings WHERE id=1),0);
          INSERT OR IGNORE INTO session_executor_profiles(session_id,profiles_json)
            VALUES(new.id,COALESCE((SELECT json_extract(value,'$.executor.defaultProfiles') FROM tool_settings WHERE id=1),'[]'));
        END;
        """)
      try migrateMCPCallersUnlocked()
    }
  }

  public func toolSettings() throws -> WorkspaceToolSettings {
    try withLock { try toolSettingsUnlocked() }
  }

  public func saveToolSettings(_ settings: WorkspaceToolSettings) throws {
    try settings.validate()
    try transaction {
      try toolsExecuteUnlocked("UPDATE tool_settings SET value=? WHERE id=1", [try toolsJSON(settings)])
      if !settings.botMCP.enabledGroups.contains(.sessions) {
        try executeUnlocked("UPDATE session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE coordinator_id IN (SELECT id FROM mcp_callers WHERE machine_id IS NOT NULL)")
        try executeUnlocked("DELETE FROM session_grants WHERE kind='approved' AND source_id IN (SELECT id FROM mcp_callers WHERE machine_id IS NOT NULL)")
        try executeUnlocked("UPDATE session_deliveries SET status='cancelled' WHERE status='queued' AND (source_id IN (SELECT id FROM mcp_callers WHERE machine_id IS NOT NULL) OR target_id IN (SELECT id FROM mcp_callers WHERE machine_id IS NOT NULL))")
      }
      if settings.externalMCP?.enabledGroups.contains(.sessions) != true {
        try toolsExecuteUnlocked("UPDATE session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE coordinator_id=?", [WovenMCPCaller.outside])
        try toolsExecuteUnlocked("DELETE FROM session_grants WHERE source_id=? AND kind='approved'", [WovenMCPCaller.outside])
        try toolsExecuteUnlocked("UPDATE session_deliveries SET status='cancelled' WHERE source_id=? AND status='queued' AND kind IN ('message','created')", [WovenMCPCaller.outside])
      }
    }
  }

  func toolSettingsUnlocked() throws -> WorkspaceToolSettings {
    let rows = try historyRowsUnlocked("SELECT value FROM tool_settings WHERE id=1", values: [])
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
    if WovenMCPCaller.isAppWide(id) {
      let settings = try toolSettingsUnlocked()
      try requireActiveBotUnlocked(id)
      let access = WovenMCPCaller.parseBot(id) != nil ? settings.botMCP : settings.externalMCP ?? .init()
      guard access.isEnabled else { throw WorkspaceToolError.invalid("Outside MCP access is disabled.") }
      return .init(enabled: access.enabledGroups, executorProfiles: settings.executor?.defaultProfiles ?? [])
    }
    try requireToolSessionUnlocked(id)
    let rows = try historyRowsUnlocked("SELECT enabled_json FROM session_tools WHERE session_id=?", values: [id])
    guard let json = rows.first?.objectValue?["enabled_json"]?.stringValue else {
      throw WorkspaceToolError.invalid("Session tool settings are unavailable.")
    }
    let selection = try historyRowsUnlocked("SELECT profiles_json FROM session_executor_profiles WHERE session_id=?", values: [id]).first?.objectValue?["profiles_json"]?.stringValue ?? "[]"
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
      let active = try historyRowsUnlocked("SELECT id FROM session_timers WHERE session_id=? AND is_paused=0 LIMIT 1", values: [sessionID])
      guard active.isEmpty || confirmedPausingTimers else { throw WorkspaceToolError.timerPauseConfirmation }
      try toolsExecuteUnlocked("UPDATE session_timers SET is_paused=1,pending_delivery_id=NULL WHERE session_id=?", [sessionID])
    }
    if !tools.enabled.contains(.sessions) {
      try toolsExecuteUnlocked("UPDATE session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE coordinator_id=?", [sessionID])
      // Approved access lasts for a management assignment; attachments are independent.
      try toolsExecuteUnlocked("DELETE FROM session_grants WHERE source_id=? AND kind='approved'", [sessionID])
    }
    if let profiles = tools.executorProfiles {
      try toolsExecuteUnlocked("UPDATE session_executor_profiles SET profiles_json=? WHERE session_id=?", [try toolsJSON(profiles), sessionID])
    }
    try toolsExecuteUnlocked("UPDATE session_tools SET enabled_json=?,defaults_applied=1 WHERE session_id=?", [try toolsJSON(tools.enabled), sessionID])
  }

  /// New-chat defaults are applied at most once, before any tools run. An
  /// explicit user change also seals the snapshot, including an empty tool set.
  public func applyInitialSessionTools(_ tools: WorkspaceSessionTools, sessionID: String) throws {
    try transaction {
      try requireToolSessionUnlocked(sessionID)
      let row = try historyRowsUnlocked("SELECT defaults_applied FROM session_tools WHERE session_id=?", values: [sessionID]).first
      guard row?.objectValue?["defaults_applied"]?.intValue == 0 else { return }
      if let profiles = tools.executorProfiles {
        try toolsExecuteUnlocked("UPDATE session_executor_profiles SET profiles_json=? WHERE session_id=?", [try toolsJSON(profiles), sessionID])
      }
      try toolsExecuteUnlocked("UPDATE session_tools SET enabled_json=?,defaults_applied=1 WHERE session_id=?", [try toolsJSON(tools.enabled), sessionID])
    }
  }

  public func requireTool(_ group: WorkspaceToolGroup, sessionID: String, writesCalendar: Bool = false) throws {
    try withLock { try requireToolUnlocked(group, sessionID: sessionID, writesCalendar: writesCalendar) }
  }

  func requireToolUnlocked(_ group: WorkspaceToolGroup, sessionID: String, writesCalendar: Bool = false) throws {
    guard try sessionToolsUnlocked(sessionID).enabled.contains(group) else { throw WorkspaceToolError.disabled(group) }
    if group == .calendar, writesCalendar, !WovenMCPCaller.isAppWide(sessionID), try toolSettingsUnlocked().calendarAccess != .full {
      throw WorkspaceToolError.invalid("Calendar is read only. Change its access in Settings → Woven MCP.")
    }
  }

  func requireToolSessionUnlocked(_ id: String) throws {
    if WovenMCPCaller.isAppWide(id) {
      try requireActiveBotUnlocked(id)
      let settings = try toolSettingsUnlocked()
      guard WovenMCPCaller.parseBot(id) != nil ? settings.botMCP.isEnabled : settings.externalMCP?.isEnabled == true else {
        throw WorkspaceToolError.invalid("Outside MCP access is disabled.")
      }
      return
    }
    guard !(try historyRowsUnlocked("SELECT id FROM conversations WHERE id=? AND deleted_at IS NULL", values: [id])).isEmpty else {
      throw WorkspaceToolError.invalid("The session is unavailable.")
    }
  }

  /// Reference attachments are granted by the composer, not by text or CLI input.
  public func attachConversationReference(sourceID: String, targetID: String) throws {
    try transaction { try grantSessionReadUnlocked(sourceID: sourceID, targetID: targetID, kind: "attachment") }
  }

  func grantSessionReadUnlocked(sourceID: String, targetID: String, kind: String) throws {
    try requireToolSessionUnlocked(sourceID)
    try requireToolSessionUnlocked(targetID)
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO session_grants(source_id,target_id,kind) VALUES(?,?,?)", [sourceID, targetID, kind])
  }

  func requireTranscriptAccessUnlocked(sourceID: String, targetID: String) throws {
    let tools = try sessionToolsUnlocked(sourceID)
    try requireToolSessionUnlocked(targetID)
    guard try canReadTranscriptUnlocked(sourceID: sourceID, targetID: targetID, enabled: tools.enabled) else {
      throw WorkspaceToolError.accessRequired(targetID)
    }
  }

  func canReadTranscriptUnlocked(sourceID: String, targetID: String, enabled: Set<WorkspaceToolGroup>) throws -> Bool {
    guard !(try historyRowsUnlocked("SELECT 1 FROM conversations WHERE id=? AND deleted_at IS NULL", values: [targetID])).isEmpty else { return false }
    if sourceID == targetID || enabled.contains(.history) { return true }
    if !(try historyRowsUnlocked("SELECT 1 FROM session_grants WHERE source_id=? AND target_id=? AND kind='attachment'", values: [sourceID, targetID])).isEmpty { return true }
    return try enabled.contains(.sessions) && relationshipUnlocked(targetID).coordinatorID == sourceID
  }

  public func sessionRelationships() throws -> [WorkspaceSessionRelationship] {
    try withLock {
      try historyRowsUnlocked("SELECT * FROM session_relationships", values: []).map(relationshipFromRow)
    }
  }

  public func sessionRelationship(_ id: String) throws -> WorkspaceSessionRelationship {
    try withLock { try relationshipUnlocked(id) }
  }

  func relationshipUnlocked(_ id: String) throws -> WorkspaceSessionRelationship {
    let rows = try historyRowsUnlocked("SELECT * FROM session_relationships WHERE session_id=?", values: [id])
    return rows.first.map(relationshipFromRow) ?? WorkspaceSessionRelationship(sessionID: id)
  }

  private func relationshipFromRow(_ value: JSONValue) -> WorkspaceSessionRelationship {
    let r = value.objectValue ?? [:]
    return WorkspaceSessionRelationship(sessionID: r["session_id"]?.stringValue ?? "",
      createdBy: r["created_by"]?.stringValue, coordinatorID: r["coordinator_id"]?.stringValue,
      purpose: r["purpose"]?.stringValue, notificationsEnabled: r["notifications_enabled"]?.intValue == 1,
      coordinationEpoch: r["coordination_epoch"]?.stringValue,
      coordinationSince: r["coordination_since"]?.stringValue)
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
        SELECT r.session_id AS id FROM session_relationships r
          JOIN conversations c ON c.id=r.session_id WHERE r.coordinator_id=? AND c.deleted_at IS NULL
        UNION SELECT target_id AS id FROM session_creations WHERE source_id=? AND managed=1 AND status='planned'
      ) WHERE id != coalesce(?,'')
      """, values: [sourceID, sourceID, targetID])
    return rows.first?.objectValue?["n"]?.intValue ?? 0
  }

  func beginCoordinationUnlocked(sourceID: String, targetID: String, purpose: String, notifications: Bool) throws {
    let existing = try relationshipUnlocked(targetID).coordinatorID
    let epoch = UUID().uuidString.lowercased()
    try toolsExecuteUnlocked("""
      INSERT INTO session_relationships(session_id,coordinator_id,purpose,notifications_enabled,coordination_epoch,coordination_since)
      VALUES(?,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET
        coordinator_id=excluded.coordinator_id,purpose=excluded.purpose,notifications_enabled=excluded.notifications_enabled,
        coordination_epoch=CASE WHEN session_relationships.coordinator_id=excluded.coordinator_id
          THEN coalesce(session_relationships.coordination_epoch,excluded.coordination_epoch) ELSE excluded.coordination_epoch END,
        coordination_since=CASE WHEN session_relationships.coordinator_id=excluded.coordinator_id
          THEN coalesce(session_relationships.coordination_since,excluded.coordination_since) ELSE excluded.coordination_since END
      """, [targetID, sourceID, purpose, notifications && sourceID != WovenMCPCaller.outside ? "1" : "0", epoch, Self.timestamp(Date())])
    if existing != sourceID {
      // A reassigned session must not deliver stale queued notifications from a
      // previous assignment, even if the same coordinator later acquires it.
      try toolsExecuteUnlocked("UPDATE session_deliveries SET status='cancelled' WHERE source_id=? AND kind='notification' AND status='queued'", [targetID])
    }
  }

  public func setCoordinationNotifications(sourceID: String, targetID: String, enabled: Bool) throws {
    guard sourceID != WovenMCPCaller.outside || !enabled else {
      throw WorkspaceToolError.invalid("Outside agents poll status and receipts; Woven cannot wake an outside process.")
    }
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      guard try relationshipUnlocked(targetID).coordinatorID == sourceID else {
        throw WorkspaceToolError.invalid("Only this session's coordinator may change its notifications.")
      }
      try toolsExecuteUnlocked("UPDATE session_relationships SET notifications_enabled=? WHERE session_id=?", [enabled ? "1" : "0", targetID])
    }
  }

  public func setAgentCoordinationNotifications(sourceID: String, targetID: String, epoch: String,
                                                 enabled: Bool, requestID: String) throws -> WorkspaceCoordinationMutationReceipt {
    guard sourceID != WovenMCPCaller.outside || !enabled else {
      throw WorkspaceToolError.invalid("Outside agents poll status and receipts; Woven cannot wake an outside process.")
    }
    return try transaction {
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
          try toolsExecuteUnlocked("UPDATE session_relationships SET notifications_enabled=? WHERE session_id=?", [enabled ? "1" : "0", targetID])
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
          try toolsExecuteUnlocked("UPDATE session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE session_id=?", [targetID])
          try toolsExecuteUnlocked("DELETE FROM session_grants WHERE target_id=? AND kind='approved'", [targetID])
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
      try toolsExecuteUnlocked("UPDATE session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE session_id=?", [targetID])
      try toolsExecuteUnlocked("DELETE FROM session_grants WHERE target_id=? AND kind='approved'", [targetID])
    }
  }

  public func reserveAutomationRequest(callerID: String, request: WovenMatterToolRequest) throws -> Bool {
    try transaction {
      let command = try WovenMatterToolCommand(request.arguments)
      guard let group = command.group, group.isAutomation else { throw WorkspaceToolError.invalid("Invalid automation group.") }
      try requireToolUnlocked(group, sessionID: callerID, writesCalendar: false)
      let id = try canonicalToolRequestID(request.requestID)
      try requireAutomationNotCancelled(callerID: callerID, requestID: id)
      let digest = SHA256.hash(data: try JSONEncoder().encode(request.operationArguments)).hexString
      let rows = try historyRowsUnlocked("SELECT input_digest FROM automation_requests WHERE source_id=? AND request_id=?", values: [callerID, id])
      if let prior = rows.first?.objectValue?["input_digest"]?.stringValue {
        guard prior == digest else { throw WorkspaceToolError.invalid("This request ID was already used for another automation call.") }
        return false
      }
      // Commit before crossing the UI boundary. A lost process or response can
      // never cause automatic repetition of a click, upload or typed text.
      try toolsExecuteUnlocked("INSERT INTO automation_requests(source_id,request_id,input_digest) VALUES(?,?,?)", [callerID, id, digest])
      return true
    }
  }

  func requireAutomationNotCancelled(callerID: String, requestID: String) throws {
    let id = try canonicalToolRequestID(requestID)
    guard try historyRowsUnlocked("SELECT request_id FROM automation_cancellations WHERE source_id=? AND request_id=?", values: [callerID, id]).isEmpty else {
      throw WorkspaceToolError.invalid("This automation request was cancelled. Inspect fresh state before starting another action.")
    }
  }

  func cancelAutomationRequest(callerID: String, requestID: String) throws {
    let id = try canonicalToolRequestID(requestID)
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO automation_cancellations(source_id,request_id) VALUES(?,?)", [callerID, id])
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
    let digest = SHA256.hash(data: try encoder.encode(input)).hexString
    let rows = try historyRowsUnlocked(
      "SELECT operation,input_digest,result_json FROM tool_mutations WHERE source_id=? AND request_id=?",
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
      "INSERT INTO tool_mutations(source_id,request_id,operation,input_digest,result_json) VALUES(?,?,?,?,?)",
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
  public func reserveAutomationRequest(callerID: String, request: WovenMatterToolRequest) async throws -> Bool {
    try await write { try $0.reserveAutomationRequest(callerID: callerID, request: request) }
  }
  public func cancelAutomationRequest(callerID: String, requestID: String) async throws {
    // Cancellation can beat the original request to the GUI. Persist it even
    // when no action is running, and let cleanup survive its caller's Stop.
    try await finishWrite { try $0.cancelAutomationRequest(callerID: callerID, requestID: requestID) }
  }
  public func cancelAutomationRequests(callerID: String) async throws {
    try await finishWrite {
      try $0.toolsExecuteUnlocked("INSERT OR IGNORE INTO automation_cancellations(source_id,request_id) SELECT source_id,request_id FROM automation_requests WHERE source_id=?", [callerID])
    }
  }
  public func requireAutomationRequest(_ group: WorkspaceToolGroup, callerID: String, requestID: String) async throws {
    try await read {
      try $0.requireToolUnlocked(group, sessionID: callerID, writesCalendar: false)
      try $0.requireAutomationNotCancelled(callerID: callerID, requestID: requestID)
    }
  }
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

  public func sessionRelationship(_ id: String) async throws -> WorkspaceSessionRelationship {
    try await read { try $0.sessionRelationship(id) }
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
  public func updateExecutor(configuration: ExecutorConfiguration? = nil, apps: [ExecutorAppTarget]? = nil,
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

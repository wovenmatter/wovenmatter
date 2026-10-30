import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Source identities may be conversations or the app-wide Tailnet caller.
  /// Target foreign keys remain conversation-bound. Preserve receipts and indexes
  /// while moving source foreign keys to the shared caller registry.
  func migrateMCPCallersUnlocked() throws {
    try executeUnlocked("CREATE TABLE IF NOT EXISTS workspace_mcp_callers(id TEXT PRIMARY KEY)")
    try executeUnlocked("INSERT OR IGNORE INTO workspace_mcp_callers SELECT id FROM dashboard_conversations")
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO workspace_mcp_callers(id) VALUES(?)", [WovenMCPCaller.outside])
    try executeUnlocked("""
      CREATE TRIGGER IF NOT EXISTS workspace_mcp_caller_insert AFTER INSERT ON dashboard_conversations BEGIN
        INSERT OR IGNORE INTO workspace_mcp_callers(id) VALUES(new.id);
      END;
      """)
    for table in ["workspace_tool_mutations", "workspace_automation_requests", "workspace_automation_cancellations",
                  "workspace_session_grants", "workspace_session_relationships", "workspace_coordination_access_requests",
                  "workspace_session_creations"] {
      guard let sql = try historyRowsUnlocked("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", values: [table])
        .first?.objectValue?["sql"]?.stringValue else { continue }
      var replacement = sql
      for column in ["source_id TEXT NOT NULL", "created_by TEXT", "coordinator_id TEXT"] {
        replacement = replacement.replacingOccurrences(of: column + " REFERENCES dashboard_conversations(id)",
          with: column + " REFERENCES workspace_mcp_callers(id)")
      }
      guard replacement != sql else { continue }
      let indexes = try historyRowsUnlocked("SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name=? AND sql IS NOT NULL", values: [table])
      guard let declaration = replacement.range(of: "CREATE TABLE(?: IF NOT EXISTS)? \"?" + table + "\"?", options: .regularExpression) else {
        throw WorkspaceToolError.invalid("Cannot migrate the MCP caller schema for " + table)
      }
      replacement.replaceSubrange(declaration, with: "CREATE TABLE " + table + "_mcp")
      try executeUnlocked(replacement)
      try executeUnlocked("INSERT INTO \(table)_mcp SELECT * FROM \(table)")
      try executeUnlocked("DROP TABLE \(table)")
      try executeUnlocked("ALTER TABLE \(table)_mcp RENAME TO \(table)")
      for index in indexes {
        if let sql = index.objectValue?["sql"]?.stringValue { try executeUnlocked(sql) }
      }
    }
  }

  /// A retained transcript is not a live MCP principal. Moving execution to a
  /// different owner also retires credentials issued by its previous owner.
  func requireMCPCaller(_ sessionID: String) throws {
    try withLock {
      _ = try availableSessionExecutionRoot(id: sessionID)
      guard !(try historyRowsUnlocked("SELECT id FROM dashboard_conversations WHERE id=? AND deleted_at IS NULL AND is_archived=0", values: [sessionID])).isEmpty,
            (try historyRowsUnlocked("SELECT conversation_id FROM companion_execution_adoptions WHERE conversation_id=?", values: [sessionID])).isEmpty else {
        throw WorkspaceToolError.invalid("This MCP caller was archived, removed, or moved to another execution owner.")
      }
    }
  }
}

extension WorkspaceDatabase {
  /// Change only the user's outside policy in one serialized write, retaining
  /// concurrent edits to defaults, runtime inventory, and other app settings.
  public func updateExternalMCP(enabled: Bool? = nil, group: WorkspaceToolGroup? = nil, groupEnabled: Bool = true) async throws {
    try await write { connection in
      var settings = try connection.toolSettings()
      var outside = settings.externalMCP ?? .init()
      if let enabled { outside.isEnabled = enabled }
      if let group {
        guard WorkspaceToolGroup.configurableCases.contains(group) else { throw WorkspaceToolError.invalid("Choose a configurable tool group.") }
        if groupEnabled { outside.groups.insert(group) } else { outside.groups.remove(group) }
      }
      settings.externalMCP = outside
      try connection.saveToolSettings(settings)
    }
  }

  public func requireMCPCaller(_ sessionID: String) async throws {
    try await read { try $0.requireMCPCaller(sessionID) }
  }
}

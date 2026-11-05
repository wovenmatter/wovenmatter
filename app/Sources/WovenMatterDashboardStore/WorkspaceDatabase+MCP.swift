import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Source identities may be conversations or app-wide callers.
  /// Target foreign keys remain conversation-bound. Preserve receipts and indexes
  /// while moving source foreign keys to the shared caller registry.
  func migrateMCPCallersUnlocked() throws {
    try executeUnlocked("CREATE TABLE IF NOT EXISTS workspace_mcp_callers(id TEXT PRIMARY KEY)")
    let columns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_mcp_callers)", values: []).compactMap { $0.objectValue?["name"]?.stringValue })
    if !columns.contains("display_name") { try executeUnlocked("ALTER TABLE workspace_mcp_callers ADD COLUMN display_name TEXT") }
    if !columns.contains("installation_id") { try executeUnlocked("ALTER TABLE workspace_mcp_callers ADD COLUMN installation_id TEXT") }
    try executeUnlocked("CREATE TABLE IF NOT EXISTS workspace_mcp_bot_installations(installation_id TEXT PRIMARY KEY, active INTEGER NOT NULL)")
    try executeUnlocked("INSERT OR IGNORE INTO workspace_mcp_callers(id) SELECT id FROM dashboard_conversations")
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
    // These tables synchronize between paired Macs and the caller registry does not, so a
    // bot hosted elsewhere arrives with no row here. This placeholder satisfies the reference
    // and authorizes nothing: it has no installation, so it can neither call nor be retired.
    // It never conflicts, because an outer statement's conflict policy would override the trigger's.
    for (table, column) in [("workspace_session_relationships", "created_by"), ("workspace_session_relationships", "coordinator_id"), ("workspace_session_grants", "source_id")]
    where try !historyRowsUnlocked("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", values: [table]).isEmpty {
      for (name, event) in [("insert", "INSERT"), ("update", "UPDATE OF " + column)] {
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS \(table)_\(column)_bot_\(name) BEFORE \(event) ON \(table)
          WHEN NEW.\(column) LIKE 'woven:bot:%'
          BEGIN INSERT INTO workspace_mcp_callers(id) SELECT NEW.\(column) WHERE NOT EXISTS (SELECT 1 FROM workspace_mcp_callers WHERE id=NEW.\(column)); END;
          """)
      }
    }
  }

  func requireActiveBotUnlocked(_ callerID: String) throws {
    guard let bot = WovenMCPCaller.parseBot(callerID) else { return }
    guard !(try historyRowsUnlocked("SELECT 1 FROM workspace_mcp_bot_installations WHERE installation_id=? AND active=1", values: [bot.installationID])).isEmpty else {
      throw WorkspaceToolError.invalid("This bot installation grant was revoked.")
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

  public func setBotInstallation(_ installationID: String, active: Bool) async throws {
    try await write { connection in
      try connection.transaction {
        try connection.toolsExecuteUnlocked("INSERT INTO workspace_mcp_bot_installations VALUES(?,?) ON CONFLICT(installation_id) DO UPDATE SET active=excluded.active", [installationID, active ? "1" : "0"])
        if !active {
          try connection.toolsExecuteUnlocked("UPDATE workspace_session_creations SET status='failed' WHERE status='planned' AND source_id IN (SELECT id FROM workspace_mcp_callers WHERE installation_id=?)", [installationID])
          try connection.toolsExecuteUnlocked("DELETE FROM workspace_session_grants WHERE source_id IN (SELECT id FROM workspace_mcp_callers WHERE installation_id=?)", [installationID])
          try connection.toolsExecuteUnlocked("UPDATE workspace_coordination_access_requests SET state='cancelled' WHERE state='pending' AND source_id IN (SELECT id FROM workspace_mcp_callers WHERE installation_id=?)", [installationID])
          try connection.toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE coordinator_id IN (SELECT id FROM workspace_mcp_callers WHERE installation_id=?)", [installationID])
          try connection.toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='cancelled' WHERE status IN ('queued','sending') AND (source_id IN (SELECT id FROM workspace_mcp_callers WHERE installation_id=?) OR target_id IN (SELECT id FROM workspace_mcp_callers WHERE installation_id=?))", [installationID, installationID])
        }
      }
    }
  }

  public func registerBotCaller(_ callerID: String, displayName: String) async throws {
    try await write { connection in
      try connection.transaction {
        guard let bot = WovenMCPCaller.parseBot(callerID) else { throw WorkspaceToolError.invalid("Invalid bot caller.") }
        try connection.requireActiveBotUnlocked(callerID)
        try connection.toolsExecuteUnlocked("INSERT INTO workspace_mcp_callers(id,display_name,installation_id) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name", [callerID, displayName, bot.installationID])
      }
    }
  }

  public func updateBotMCP(enabled: Bool? = nil, group: WorkspaceToolGroup? = nil, groupEnabled: Bool = true) async throws {
    try await write { connection in
      var settings = try connection.toolSettings()
      if let enabled { settings.botMCP.isEnabled = enabled }
      if let group {
        guard WorkspaceToolGroup.configurableCases.contains(group) else { throw WorkspaceToolError.invalid("Choose a configurable tool group.") }
        if groupEnabled { settings.botMCP.groups.insert(group) } else { settings.botMCP.groups.remove(group) }
      }
      try connection.saveToolSettings(settings)
    }
  }

  public func requireMCPCaller(_ sessionID: String) async throws {
    try await read { try $0.requireMCPCaller(sessionID) }
  }
}

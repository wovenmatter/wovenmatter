import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Every conversation is an MCP caller, and so is the outside caller.
  func migrateMCPCallersUnlocked() throws {
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO workspace_mcp_callers(id) VALUES(?)", [WovenMCPCaller.outside])
    try executeUnlocked("""
      CREATE TRIGGER IF NOT EXISTS conversations_mcp_caller_insert AFTER INSERT ON conversations BEGIN
        INSERT OR IGNORE INTO workspace_mcp_callers(id) VALUES(new.id);
      END;
      """)
    // These tables synchronize between paired Macs and the caller registry does not, so a
    // bot hosted elsewhere arrives with no row here. This placeholder satisfies the reference
    // and authorizes nothing: it has no machine, so it can neither call nor be retired.
    // It never conflicts, because an outer statement's conflict policy would override the trigger's.
    for (table, column) in [("workspace_session_relationships", "created_by"), ("workspace_session_relationships", "coordinator_id"), ("workspace_session_grants", "source_id")] {
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
    guard !(try historyRowsUnlocked("SELECT 1 FROM workspace_mcp_bot_machines WHERE machine_id=? AND active=1", values: [bot.machineID])).isEmpty else {
      throw WorkspaceToolError.invalid("Bots on this machine are paused or were disconnected from Woven MCP.")
    }
    guard (try historyRowsUnlocked("SELECT 1 FROM workspace_mcp_callers WHERE id=? AND revoked=1", values: [callerID])).isEmpty else {
      throw WorkspaceToolError.invalid("This bot's Woven MCP key was revoked.")
    }
  }

  /// Ends what bots started when their keys stop working: planned creations,
  /// grants, pending access requests, coordination and undelivered messages.
  func retireBotCallersUnlocked(_ callers: String, _ values: [String]) throws {
    try toolsExecuteUnlocked("UPDATE workspace_session_creations SET status='failed' WHERE status='planned' AND source_id IN (" + callers + ")", values)
    try toolsExecuteUnlocked("DELETE FROM workspace_session_grants WHERE source_id IN (" + callers + ")", values)
    try toolsExecuteUnlocked("UPDATE workspace_coordination_access_requests SET state='cancelled' WHERE state='pending' AND source_id IN (" + callers + ")", values)
    try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE coordinator_id IN (" + callers + ")", values)
    try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='cancelled' WHERE status IN ('queued','sending') AND (source_id IN (" + callers + ") OR target_id IN (" + callers + "))", values + values)
  }

  /// A retained transcript is not a live MCP principal. Moving execution to a
  /// different owner also retires credentials issued by its previous owner.
  func requireMCPCaller(_ sessionID: String) throws {
    try withLock {
      _ = try availableSessionExecutionRoot(id: sessionID)
      guard !(try historyRowsUnlocked("SELECT id FROM conversations WHERE id=? AND deleted_at IS NULL AND is_archived=0", values: [sessionID])).isEmpty,
            (try historyRowsUnlocked("SELECT conversation_id FROM execution_adoptions WHERE conversation_id=?", values: [sessionID])).isEmpty else {
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

  /// Resumes or pauses every bot this instance serves for one machine.
  public func setBotMachine(_ machineID: String, active: Bool) async throws {
    guard WovenMCPCaller.isIdentifier(machineID) else { throw WorkspaceToolError.invalid("Invalid bot machine ID.") }
    let machine = machineID.lowercased()
    try await write { connection in
      try connection.transaction {
        try connection.toolsExecuteUnlocked("INSERT INTO workspace_mcp_bot_machines VALUES(?,?) ON CONFLICT(machine_id) DO UPDATE SET active=excluded.active", [machine, active ? "1" : "0"])
        if !active { try connection.retireBotCallersUnlocked("SELECT id FROM workspace_mcp_callers WHERE machine_id=?", [machine]) }
      }
    }
  }

  /// Registers or renames a bot's caller. A paused machine's bots may still get keys,
  /// which work once it resumes; a revoked bot may not unless `reinstate` is set.
  public func registerBotCaller(_ callerID: String, displayName: String, reinstate: Bool = false) async throws {
    try await write { connection in
      try connection.transaction {
        guard let bot = WovenMCPCaller.parseBot(callerID) else { throw WorkspaceToolError.invalid("Invalid bot caller.") }
        if reinstate { try connection.toolsExecuteUnlocked("UPDATE workspace_mcp_callers SET revoked=0 WHERE id=?", [callerID]) }
        // The first key for a machine enables it; a paused machine stays paused.
        try connection.toolsExecuteUnlocked("INSERT OR IGNORE INTO workspace_mcp_bot_machines VALUES(?,1)", [bot.machineID])
        guard (try connection.historyRowsUnlocked("SELECT 1 FROM workspace_mcp_callers WHERE id=? AND revoked=1", values: [callerID])).isEmpty else {
          throw WorkspaceToolError.invalid("This bot's Woven MCP key was revoked.")
        }
        try connection.toolsExecuteUnlocked("INSERT INTO workspace_mcp_callers(id,display_name,machine_id) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,machine_id=excluded.machine_id", [callerID, displayName, bot.machineID])
      }
    }
  }

  /// Revokes one bot's key and retires what it started.
  public func revokeBotCaller(_ callerID: String) async throws {
    guard let bot = WovenMCPCaller.parseBot(callerID) else { throw WorkspaceToolError.invalid("Invalid bot caller.") }
    try await write { connection in
      try connection.transaction {
        try connection.toolsExecuteUnlocked("INSERT INTO workspace_mcp_callers(id,machine_id,revoked) VALUES(?,?,1) ON CONFLICT(id) DO UPDATE SET revoked=1", [callerID, bot.machineID])
        try connection.retireBotCallersUnlocked("?", [callerID])
      }
    }
  }

  /// A bot its runtime deleted: retire what it started without blocking a later key.
  public func retireBotCaller(_ callerID: String) async throws {
    guard WovenMCPCaller.parseBot(callerID) != nil else { throw WorkspaceToolError.invalid("Invalid bot caller.") }
    try await write { connection in
      try connection.transaction { try connection.retireBotCallersUnlocked("?", [callerID]) }
    }
  }

  public func reinstateBotCaller(_ callerID: String) async throws {
    guard WovenMCPCaller.parseBot(callerID) != nil else { throw WorkspaceToolError.invalid("Invalid bot caller.") }
    try await write { connection in
      try connection.toolsExecuteUnlocked("UPDATE workspace_mcp_callers SET revoked=0 WHERE id=?", [callerID])
    }
  }

  public func isBotMachinePaused(_ machineID: String) async throws -> Bool {
    try await read { connection in
      try connection.withLock {
        try connection.historyRowsUnlocked("SELECT active FROM workspace_mcp_bot_machines WHERE machine_id=?", values: [machineID.lowercased()])
          .first?.objectValue?["active"]?.intValue == 0
      }
    }
  }

  /// The bots that hold or held a key here, for Settings: attribution and revoke.
  public func botCallers() async throws -> [WovenBotCaller] {
    try await read { connection in
      try connection.withLock {
        try connection.historyRowsUnlocked("""
          SELECT c.id,c.display_name,c.machine_id,c.revoked,coalesce(m.active,0) AS active FROM workspace_mcp_callers c
          LEFT JOIN workspace_mcp_bot_machines m ON m.machine_id=c.machine_id WHERE c.machine_id IS NOT NULL ORDER BY c.display_name,c.id
          """, values: []).compactMap { row in
          guard let object = row.objectValue, let id = object["id"]?.stringValue, let bot = WovenMCPCaller.parseBot(id) else { return nil }
          return WovenBotCaller(callerID: id, machineID: bot.machineID, botID: bot.botID,
            displayName: object["display_name"]?.stringValue ?? "Bot",
            revoked: object["revoked"]?.intValue == 1, paused: object["active"]?.intValue != 1)
        }
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

public struct WovenBotCaller: Codable, Equatable, Sendable, Identifiable {
  public var id: String { callerID }
  public let callerID: String
  public let machineID: String
  public let botID: String
  public let displayName: String
  public let revoked: Bool
  public let paused: Bool
}

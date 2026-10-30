import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabase {
  /// This imports an older workspace from the SAME physical Mac, once during
  /// upgrade. It is never exposed by the peer protocol or used for remote data.
  /// Native checkpoints and execution queues remain local to their original Mac.
  public func importLegacyLocalMacWorkspace(from source: URL) async throws {
    guard source.standardizedFileURL != fileURL.standardizedFileURL else { return }
    try await backUpBeforePeerSync()
    try await write { connection in
      let attach = try connection.prepareUnlocked("ATTACH DATABASE ? AS legacy_mac")
      try connection.bind("file:" + source.path + "?mode=ro", at: 1, to: attach)
      try connection.stepDone(attach); sqlite3_finalize(attach)
      defer { try? connection.executeUnlocked("DETACH DATABASE legacy_mac") }
      try connection.executeUnlocked("PRAGMA foreign_keys=OFF")
      defer { try? connection.executeUnlocked("PRAGMA foreign_keys=ON") }
      try connection.transaction {
        let excluded: Set<String> = ["desktop_local_identity", "companion_workspace", "companion_library_identity",
          "companion_changes", "companion_versions", "companion_execution_replica_context", "companion_calendar_execution_context",
          "workspace_history_schema", "workspace_tool_schema", "desktop_dashboard_revision", "desktop_activity_revision",
          "desktop_activity_index", "desktop_activity_index_schema", "desktop_message_revisions", "library_settings", "usage_metadata", "usage_runtime_cursors"]
        let tables = try connection.historyRowsUnlocked("SELECT name,sql FROM legacy_mac.sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", values: [])
        for item in tables {
          guard let table = item.objectValue?["name"]?.stringValue, let sql = item.objectValue?["sql"]?.stringValue,
                !excluded.contains(table), !table.hasPrefix("paired_"), !table.hasPrefix("workspace_history_search"),
                !sql.uppercased().contains("VIRTUAL TABLE") else { continue }
          let local = try connection.historyRowsUnlocked("PRAGMA main.table_info(\(WorkspaceDatabaseConnection.peerQuote(table)))", values: [])
          let incoming = try connection.historyRowsUnlocked("PRAGMA legacy_mac.table_info(\(WorkspaceDatabaseConnection.peerQuote(table)))", values: [])
          guard local == incoming else { throw CompanionAPIError(code: "legacy_version", message: "The saved local workspace needs a compatible schema before it can be combined. Both originals are retained.") }
          let generated = sql.uppercased().contains("AUTOINCREMENT")
            ? incoming.first(where: { $0.objectValue?["pk"]?.doubleValue == 1 })?.objectValue?["name"]?.stringValue : nil
          let names = incoming.compactMap { $0.objectValue?["name"]?.stringValue }.filter { $0 != generated }.map(WorkspaceDatabaseConnection.peerQuote).joined(separator: ",")
          try connection.executeUnlocked("INSERT OR IGNORE INTO main.\(WorkspaceDatabaseConnection.peerQuote(table))(\(names)) SELECT \(names) FROM legacy_mac.\(WorkspaceDatabaseConnection.peerQuote(table))")
        }
      }
    }
  }

  public func adoptLegacyPairedMacIdentity(_ deviceID: String) async throws {
    guard UUID(uuidString: deviceID) != nil else { throw WorkspaceDatabaseError.corruptRow }
    try await write { connection in
      try connection.transaction {
        let previous = try connection.companionLibraryIdentityUnlocked().hostDeviceID
        guard previous != deviceID else { return }
        guard try connection.historyRowsUnlocked("SELECT device_id FROM paired_mac_routes", values: []).isEmpty else {
          throw CompanionAPIError(code: "legacy_identity", message: "This library already has a paired Mac identity. Its saved legacy data is retained for recovery.")
        }
        try connection.toolsExecuteUnlocked("UPDATE companion_library_identity SET host_device_id=?", [deviceID])
        try connection.toolsExecuteUnlocked("UPDATE paired_library_clock SET device_id=?", [deviceID])
        for table in ["paired_calendar_owners", "paired_conversation_owners", "paired_agent_owners"] {
          try connection.toolsExecuteUnlocked("UPDATE \(table) SET device_id=? WHERE device_id=?", [deviceID, previous])
        }
      }
    }
  }
}

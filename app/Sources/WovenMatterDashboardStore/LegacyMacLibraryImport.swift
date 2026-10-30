import CryptoKit
import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabase {
  /// Writes a consistent, integrity-checked copy of another SQLite file,
  /// including committed WAL content, without migrating or modifying it.
  public static func snapshotDatabase(from source: URL, to target: URL) throws {
    guard !FileManager.default.fileExists(atPath: target.path) else { return }
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let partial = target.deletingLastPathComponent().appending(path: UUID().uuidString + ".partial")
    defer { try? FileManager.default.removeItem(at: partial) }
    var original: OpaquePointer?, copy: OpaquePointer?
    guard sqlite3_open_v2(source.path, &original, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let original else {
      sqlite3_close(original); throw WorkspaceDatabaseError.open("Could not read the saved local workspace.")
    }
    defer { sqlite3_close(original) }
    guard sqlite3_open(partial.path, &copy) == SQLITE_OK, let copy else {
      sqlite3_close(copy); throw WorkspaceDatabaseError.open("Could not create the saved workspace copy.")
    }
    defer { sqlite3_close(copy) }
    guard let backup = sqlite3_backup_init(copy, "main", original, "main") else { throw WorkspaceDatabaseError.execute("Could not copy the saved local workspace.") }
    let status = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
    guard status == SQLITE_DONE, finish == SQLITE_OK, sqlite3_exec(copy, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
      throw WorkspaceDatabaseError.execute("The saved local workspace copy did not complete.")
    }
    var check: OpaquePointer?
    guard sqlite3_prepare_v2(copy, "PRAGMA integrity_check", -1, &check, nil) == SQLITE_OK, let check else { throw WorkspaceDatabaseError.corruptRow }
    defer { sqlite3_finalize(check) }
    guard sqlite3_step(check) == SQLITE_ROW, let result = sqlite3_column_text(check, 0), String(cString: result) == "ok" else { throw WorkspaceDatabaseError.corruptRow }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
    try FileManager.default.moveItem(at: partial, to: target)
  }

  /// Tables a former node's execution database held as projections of the
  /// central library, or as federation state in that library's namespace. The
  /// original central rows arrive through pairing and must win; importing these
  /// stale copies as fresh local edits would overwrite current writing.
  static let legacyProjectionTables: Set<String> = [
    "notes", "folders", "folder_execution_roots", "note_asset_versions",
    "dashboard_calendar_items", "workspace_calendar_remote_ownership",
  ]

  /// This imports an older workspace from the SAME physical Mac, once during
  /// upgrade. It is never exposed by the peer protocol or used for remote data.
  /// Native checkpoints and execution queues remain local to their original Mac.
  /// Pass a migrated snapshot copy; the retained original is never modified.
  /// The import and its completion marker commit together, so a retry after
  /// a later upgrade step fails never duplicates generated-key rows.
  public func importLegacyLocalMacWorkspace(from source: URL) async throws {
    guard source.standardizedFileURL != fileURL.standardizedFileURL else { return }
    try await backUpBeforePeerSync()
    let marker = "legacy.import." + SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    try await write { connection in
      guard try connection.pairedStateUnlocked(marker) == nil else { return }
      let attach = try connection.prepareUnlocked("ATTACH DATABASE ? AS legacy_mac")
      try connection.bind("file:" + source.path + "?mode=ro", at: 1, to: attach)
      try connection.stepDone(attach); sqlite3_finalize(attach)
      defer { try? connection.executeUnlocked("DETACH DATABASE legacy_mac") }
      try connection.executeUnlocked("PRAGMA foreign_keys=OFF")
      defer { try? connection.executeUnlocked("PRAGMA foreign_keys=ON") }
      try connection.transaction {
        // Goals this library already had are never touched by the import.
        let existingGoals = Set(try connection.historyRowsUnlocked("SELECT session_id FROM main.workspace_session_goals", values: [])
          .compactMap { $0.objectValue?["session_id"]?.stringValue })
        let existingGoalIDs = Set(try connection.historyRowsUnlocked("SELECT json_extract(value,'$.id') AS id FROM main.workspace_session_goals", values: [])
          .compactMap { $0.objectValue?["id"]?.stringValue })
        // Only goals this import actually inserts bring their accounting. A goal
        // already here, by chat or by ID, keeps its own runs and usage totals.
        let importedGoalIDs = try connection.historyRowsUnlocked("SELECT session_id,json_extract(value,'$.id') AS id FROM legacy_mac.workspace_session_goals", values: [])
          .compactMap { row -> String? in
            guard let session = row.objectValue?["session_id"]?.stringValue, let id = row.objectValue?["id"]?.stringValue,
                  !existingGoals.contains(session), !existingGoalIDs.contains(id) else { return nil }
            return id
          }
        let importedGoals = String(decoding: try JSONEncoder().encode(importedGoalIDs), as: UTF8.self)
        let excluded = Set<String>(["desktop_local_identity", "library_settings", "usage_metadata", "usage_runtime_cursors",
          "workspace_history_schema", "workspace_tool_schema", "desktop_dashboard_revision", "desktop_activity_revision",
          "desktop_activity_index", "desktop_activity_index_schema", "desktop_message_revisions", "workspace_tool_settings",
          // Federation, replica and identity state in the former central library's namespace.
          "companion_workspace", "companion_library_identity", "companion_changes", "companion_versions",
          "companion_mutation_receipts", "companion_workspace_publishers", "companion_execution_workspaces",
          "companion_execution_journal", "companion_execution_conversations", "companion_execution_runs",
          "companion_execution_adoptions", "companion_execution_replica_context", "companion_retained_settlements",
          "companion_native_history", "companion_native_history_parts", "companion_calendar_owners",
          "companion_calendar_run_owners", "companion_calendar_runs", "companion_calendar_receipts",
          "companion_calendar_execution_context", "companion_calendar_execution_conflicts"])
          .union(Self.legacyProjectionTables)
        let tables = try connection.historyRowsUnlocked("SELECT name,sql FROM legacy_mac.sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", values: [])
        for item in tables {
          guard let table = item.objectValue?["name"]?.stringValue, let sql = item.objectValue?["sql"]?.stringValue,
                !excluded.contains(table), !table.hasPrefix("paired_"),
                !table.hasPrefix("workspace_history_search"), !sql.uppercased().contains("VIRTUAL TABLE") else { continue }
          let local = try connection.historyRowsUnlocked("PRAGMA main.table_info(\(WorkspaceDatabaseConnection.peerQuote(table)))", values: [])
          let incoming = try connection.historyRowsUnlocked("PRAGMA legacy_mac.table_info(\(WorkspaceDatabaseConnection.peerQuote(table)))", values: [])
          guard local == incoming else { throw CompanionAPIError(code: "legacy_version", message: "The saved local workspace needs a compatible schema before it can be combined. Both originals are retained.") }
          let generated = sql.uppercased().contains("AUTOINCREMENT")
            ? incoming.first(where: { $0.objectValue?["pk"]?.doubleValue == 1 })?.objectValue?["name"]?.stringValue : nil
          let names = incoming.compactMap { $0.objectValue?["name"]?.stringValue }.filter { $0 != generated }.map(WorkspaceDatabaseConnection.peerQuote).joined(separator: ",")
          let order = table == "dashboard_runs" ? " ORDER BY rowid" : ""
          let insert = "INSERT OR IGNORE INTO main.\(WorkspaceDatabaseConnection.peerQuote(table))(\(names)) SELECT \(names) FROM legacy_mac.\(WorkspaceDatabaseConnection.peerQuote(table))"
          switch table {
          case "workspace_goal_runs", "workspace_goal_usage":
            try connection.toolsExecuteUnlocked(insert + " WHERE goal_id IN (SELECT value FROM json_each(?))", [importedGoals])
          case "workspace_session_goals":
            try connection.toolsExecuteUnlocked(insert + " WHERE json_extract(value,'$.id') IN (SELECT value FROM json_each(?))", [importedGoals])
          default:
            try connection.executeUnlocked(insert + order)
          }
        }
        try connection.adoptImportedGoals(excluding: existingGoals)
        try connection.setPairedStateUnlocked(marker, "1")
      }
    }
  }

  /// Live note identities in a saved legacy workspace, for preserving writing
  /// that never reached the former node's replica.
  public func legacyLiveNoteIDs() async throws -> [String] {
    try await read { connection in
      try connection.historyRowsUnlocked("SELECT id FROM notes WHERE deleted_at IS NULL ORDER BY id", values: []).compactMap { $0.objectValue?["id"]?.stringValue }
    }
  }

  public func adoptLegacyPairedMacIdentity(_ deviceID: String) async throws {
    guard UUID(uuidString: deviceID) != nil else { throw WorkspaceDatabaseError.corruptRow }
    try await write { connection in
      try connection.transaction {
        let previous = try connection.companionLibraryIdentityUnlocked().hostDeviceID
        guard previous != deviceID else { return }
        // This Mac's own advertised route may already exist from an earlier
        // launch; any other Mac means peer data may already carry this identity.
        guard try connection.historyRowsUnlocked("SELECT device_id FROM paired_mac_routes WHERE device_id<>?", values: [previous]).isEmpty,
              try connection.historyRowsUnlocked("SELECT peer_id FROM paired_library_cursors LIMIT 1", values: []).isEmpty else {
          throw CompanionAPIError(code: "legacy_identity", message: "This library already has a paired Mac identity. Its saved legacy data is retained for recovery.")
        }
        try connection.toolsExecuteUnlocked("DELETE FROM paired_mac_routes WHERE device_id=?", [previous])
        try connection.toolsExecuteUnlocked("UPDATE companion_library_identity SET host_device_id=?", [deviceID])
        try connection.toolsExecuteUnlocked("UPDATE paired_library_clock SET device_id=?", [deviceID])
        for table in ["paired_calendar_owners", "paired_conversation_owners", "paired_agent_owners"] {
          try connection.toolsExecuteUnlocked("UPDATE \(table) SET device_id=? WHERE device_id=?", [deviceID, previous])
        }
      }
    }
  }
}

extension WorkspaceDatabaseConnection {
  /// Goal membership is kept by stable run IDs, never by renumbered row
  /// sequences. For each goal this import actually inserted: an active goal
  /// first enrolls every source run after its source fence (by source row
  /// order), so no turn or usage is lost; then all fences move to this
  /// library's current end for the chat, so only future runs enroll later and
  /// usage for already enrolled runs still counts. Active goals are paused so
  /// nothing continues automatically on upgrade.
  func adoptImportedGoals(excluding existing: Set<String>) throws {
    for row in try historyRowsUnlocked("SELECT session_id,value FROM legacy_mac.workspace_session_goals", values: []) {
      guard let session = row.objectValue?["session_id"]?.stringValue, !existing.contains(session),
            let source = row.objectValue?["value"]?.stringValue,
            let sourceGoal = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any],
            let goalID = sourceGoal["id"] as? String,
            let imported = try historyRowsUnlocked("SELECT value FROM main.workspace_session_goals WHERE session_id=?", values: [session])
              .first?.objectValue?["value"]?.stringValue,
            var goal = try JSONSerialization.jsonObject(with: Data(imported.utf8)) as? [String: Any], goal["id"] as? String == goalID else { continue }
      if goal["status"] as? String == "active" {
        let fence = (sourceGoal["enrolledRunSequence"] as? NSNumber)?.int64Value ?? 0
        try toolsExecuteUnlocked("""
          INSERT OR IGNORE INTO main.workspace_goal_runs(goal_id,run_id)
          SELECT ?,id FROM legacy_mac.dashboard_runs WHERE conversation_id=? AND rowid>? ORDER BY rowid
          """, [goalID, session, String(fence)])
        goal["status"] = "paused"; goal["pendingDeliveryID"] = nil
        goal["evidence"] = "Paused after the pairing upgrade. Resume to continue."
      }
      let end = Int64(try historyRowsUnlocked("SELECT COALESCE(MAX(rowid),0) AS fence FROM main.dashboard_runs WHERE conversation_id=?", values: [session])
        .first?.objectValue?["fence"]?.intValue ?? 0)
      for key in ["baselineRunSequence", "observedRunSequence", "enrolledRunSequence"] { goal[key] = NSNumber(value: end) }
      let data = try JSONSerialization.data(withJSONObject: goal, options: [.sortedKeys])
      try toolsExecuteUnlocked("UPDATE main.workspace_session_goals SET value=? WHERE session_id=?", [String(decoding: data, as: UTF8.self), session])
    }
  }
}

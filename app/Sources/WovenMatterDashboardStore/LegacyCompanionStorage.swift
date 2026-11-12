import Foundation

extension WorkspaceDatabaseConnection {
  /// The tables libraries created before November 2026 used, and their names
  /// now. Everything in them is kept: the library ID, device grants and
  /// receipts, execution workspaces with their journals and conversations,
  /// which device runs each scheduled item, and device transcripts and files.
  static let legacyCompanionTables: [(old: String, new: String)] = [
    ("companion_library_identity", "library_identity"),
    ("companion_versions", "device_sync_revisions"),
    ("companion_changes", "device_sync_changes"),
    ("companion_mutation_receipts", "device_mutation_receipts"),
    ("companion_command_receipts", "device_command_receipts"),
    ("companion_draft_receipts", "device_draft_receipts"),
    ("companion_tool_receipts", "device_tool_receipts"),
    ("companion_workspace_mcp_grants", "execution_workspace_mcp_grants"),
    ("companion_workspace_publishers", "execution_workspace_publishers"),
    ("companion_scheduled_mcp_callers", "device_scheduled_mcp_callers"),
    ("companion_message_provenance", "device_message_provenance"),
    ("companion_saved_artifacts", "device_saved_artifacts"),
    ("companion_artifact_uploads", "device_artifact_uploads"),
    ("companion_artifact_chunks", "device_artifact_chunks"),
    ("companion_execution_workspaces", "execution_workspaces"),
    ("companion_execution_journal", "execution_journal"),
    ("companion_execution_conversations", "execution_conversations"),
    ("companion_execution_adoptions", "execution_adoptions"),
    ("companion_execution_runs", "execution_runs"),
    ("companion_execution_receipts", "execution_receipts"),
    ("companion_execution_replica_context", "execution_replica_context"),
    ("companion_retained_settlements", "execution_retained_settlements"),
    ("companion_native_history", "execution_native_history"),
    ("companion_native_history_parts", "execution_native_history_parts"),
    ("companion_calendar_owners", "calendar_task_executors"),
    ("companion_calendar_run_owners", "calendar_run_publishers"),
    ("companion_calendar_runs", "calendar_published_runs"),
    ("companion_calendar_receipts", "device_calendar_receipts"),
    ("companion_calendar_execution_context", "calendar_replica_context"),
    ("companion_calendar_execution_conflicts", "calendar_execution_conflicts"),
  ]

  /// Renames a pre-November 2026 library's `companion_*` tables in place.
  ///
  /// The old triggers are dropped first: every one is recreated under its new
  /// name, and leaving one would keep writing to a renamed table or, like
  /// `paired_conversation_owner_v2`, read one that no longer exists. The
  /// library ID moves from `companion_workspace` into `library_identity`.
  /// Peer sync bookkeeping names tables, so it is rewritten to the new names:
  /// every updated device does the same, so peers keep their versions and
  /// cursors and nothing is sent again.
  func renameLegacyCompanionStorageUnlocked() throws {
    let tables = Set(try historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='table'", values: [])
      .compactMap { $0.objectValue?["name"]?.stringValue })
    let triggers = try historyRowsUnlocked("""
      SELECT name FROM sqlite_master WHERE type='trigger'
        AND (name LIKE 'companion\\_%' ESCAPE '\\' OR sql LIKE '%companion\\_%' ESCAPE '\\')
      """, values: []).compactMap { $0.objectValue?["name"]?.stringValue }
    for name in triggers { try executeUnlocked("DROP TRIGGER IF EXISTS \(Self.peerQuote(name))") }
    guard tables.contains(where: { $0.hasPrefix("companion_") }) else { return }

    // Rename without re-parsing every other trigger and view: one left behind
    // by an older build must not keep this library from opening.
    try executeUnlocked("PRAGMA legacy_alter_table=ON")
    defer { try? executeUnlocked("PRAGMA legacy_alter_table=OFF") }
    for (old, new) in Self.legacyCompanionTables where tables.contains(old) {
      // A newer table only exists if a build of this change already ran; it
      // then holds the current state.
      if tables.contains(new) {
        try executeUnlocked("DROP TABLE \(Self.peerQuote(old))")
        for bookkeeping in ["paired_library_rows", "paired_library_frontier", "paired_library_reassert", "paired_library_seeded"]
          where tables.contains(bookkeeping) {
          try toolsExecuteUnlocked("DELETE FROM \(bookkeeping) WHERE table_name=?", [old])
        }
        continue
      }
      try executeUnlocked("ALTER TABLE \(Self.peerQuote(old)) RENAME TO \(Self.peerQuote(new))")
      for bookkeeping in ["paired_library_rows", "paired_library_frontier", "paired_library_reassert", "paired_library_seeded"]
        where tables.contains(bookkeeping) {
        try toolsExecuteUnlocked("UPDATE \(bookkeeping) SET table_name=? WHERE table_name=?", [new, old])
      }
      // Pending, quarantine and conflict IDs are hashes of the old payload
      // text. They are only local de-duplication keys: a peer that sends the
      // same record again queues it once more, and applying it is idempotent.
      for bookkeeping in ["paired_library_rows", "paired_library_frontier", "paired_library_changes", "paired_library_pending",
                          "paired_library_quarantine", "paired_library_conflicts"] where tables.contains(bookkeeping) {
        try toolsExecuteUnlocked("""
          UPDATE \(bookkeeping) SET payload=json_set(payload,'$.table',?)
          WHERE json_valid(payload) AND json_extract(payload,'$.table')=?
          """, [new, old])
      }
    }
    if tables.contains("companion_workspace") {
      let columns = Set(try historyRowsUnlocked("PRAGMA table_info(library_identity)", values: [])
        .compactMap { $0.objectValue?["name"]?.stringValue })
      if !columns.isEmpty, !columns.contains("library_id") {
        try executeUnlocked("ALTER TABLE library_identity ADD COLUMN library_id TEXT")
      }
      if !columns.isEmpty {
        try executeUnlocked("""
          UPDATE library_identity SET library_id=(SELECT workspace_id FROM companion_workspace WHERE singleton=1)
          WHERE library_id IS NULL
          """)
      }
      try executeUnlocked("DROP TABLE companion_workspace")
    }
  }
}

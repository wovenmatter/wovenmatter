import Foundation

extension WorkspaceDatabaseConnection {
  /// Libraries created before November 2026 kept the state for other devices
  /// in `companion_*` tables, now `device_*`. That state is not carried over:
  /// devices pair again, and execution workspaces, device schedules and device
  /// transcripts start fresh. Library content (notes, folders, chats, runs,
  /// calendar, note history) never lived in these tables and is untouched.
  ///
  /// Old triggers are dropped first: they would otherwise keep writing into the
  /// abandoned tables, and one of them (`paired_conversation_owner_v2`) reads a
  /// table that is dropped here, which would make every new conversation fail.
  /// Peer sync bookkeeping that names the old tables is removed too, so a peer
  /// catching up never receives records for tables no current build accepts.
  func removeLegacyCompanionStorageUnlocked() throws {
    let legacy = "LIKE 'companion\\_%' ESCAPE '\\'"
    let triggers = try historyRowsUnlocked(
      "SELECT name FROM sqlite_master WHERE type='trigger' AND (name \(legacy) OR sql \(legacy.replacingOccurrences(of: "'companion", with: "'%companion")))",
      values: []).compactMap { $0.objectValue?["name"]?.stringValue }
    for name in triggers + ["paired_conversation_owner_v3"] {
      try executeUnlocked("DROP TRIGGER IF EXISTS \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"")
    }
    let tables = Set(try historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='table'", values: [])
      .compactMap { $0.objectValue?["name"]?.stringValue })
    for table in ["paired_library_rows", "paired_library_frontier", "paired_library_reassert", "paired_library_seeded"]
      where tables.contains(table) {
      try executeUnlocked("DELETE FROM \(table) WHERE table_name \(legacy)")
    }
    for table in ["paired_library_changes", "paired_library_pending", "paired_library_quarantine"] where tables.contains(table) {
      try executeUnlocked("DELETE FROM \(table) WHERE json_valid(payload) AND json_extract(payload,'$.table') \(legacy)")
    }
    for table in tables.sorted() where table.hasPrefix("companion_") {
      try executeUnlocked("DROP TABLE IF EXISTS \"\(table)\"")
    }
  }
}

import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension WorkspaceDatabaseConnection {
  func createFederationSchemaUnlocked() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS library_identity (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1), host_device_id TEXT NOT NULL, library_id TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS execution_workspaces (
        id TEXT PRIMARY KEY, owner_device_id TEXT NOT NULL, revision INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS device_workspace_publishers (
        workspace_id TEXT PRIMARY KEY, digest BLOB NOT NULL UNIQUE, payload BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS execution_journal (
        cursor INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
        workspace_id TEXT NOT NULL, origin_sequence INTEGER NOT NULL,
        fingerprint BLOB NOT NULL, payload BLOB NOT NULL,
        UNIQUE(workspace_id, origin_sequence)
      );
      CREATE TABLE IF NOT EXISTS execution_retained_settlements (
        event_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, fingerprint BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS execution_conversations (
        id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
        conversation BLOB NOT NULL, transcript BLOB
      );
      CREATE TABLE IF NOT EXISTS execution_adoptions (
        conversation_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, payload BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS device_message_provenance (
        message_id TEXT PRIMARY KEY, source_id TEXT NOT NULL,
        source_title TEXT, source_agent TEXT, kind TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS execution_runs (
        id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, conversation_id TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS execution_receipts (
        workspace_id TEXT NOT NULL, command_id TEXT NOT NULL, device_id TEXT NOT NULL,
        payload BLOB NOT NULL, PRIMARY KEY(workspace_id, command_id)
      );
      CREATE TABLE IF NOT EXISTS execution_native_history (
        workspace_id TEXT NOT NULL, record_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
        run_id TEXT, format TEXT NOT NULL, part_count INTEGER NOT NULL, byte_count INTEGER NOT NULL,
        sha256 TEXT NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(workspace_id, record_id)
      );
      CREATE TABLE IF NOT EXISTS execution_native_history_parts (
        workspace_id TEXT NOT NULL, record_id TEXT NOT NULL, part_index INTEGER NOT NULL, bytes BLOB NOT NULL,
        PRIMARY KEY(workspace_id, record_id, part_index)
      );
      CREATE TABLE IF NOT EXISTS device_saved_artifacts (
        id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS device_artifact_uploads (
        id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest BLOB NOT NULL,
        next_offset INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS device_artifact_chunks (
        artifact_id TEXT NOT NULL, revision INTEGER NOT NULL, offset INTEGER NOT NULL,
        bytes BLOB NOT NULL, PRIMARY KEY(artifact_id, revision, offset)
      );
      """)
    // library_identity holds this replica's device ID (host_device_id) and the
    // library's ID (library_id), which every device paired with it names.
    // A library from before library_id moved here gains the column; its value
    // is carried over by renameLegacyCompanionStorageUnlocked.
    let columns = Set(try historyRowsUnlocked("PRAGMA table_info(library_identity)", values: [])
      .compactMap { $0.objectValue?["name"]?.stringValue })
    if !columns.contains("library_id") { try executeUnlocked("ALTER TABLE library_identity ADD COLUMN library_id TEXT") }
    // The host device ID is the paired-library clock's origin, and ownership
    // records name it. A library that already has a clock keeps that identity.
    let libraryID = UUID().uuidString.lowercased()
    if try historyRowsUnlocked("SELECT 1 AS present FROM sqlite_master WHERE type='table' AND name='paired_library_clock'", values: []).isEmpty == false {
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO library_identity SELECT 1,device_id,? FROM paired_library_clock WHERE singleton=1", [libraryID])
    }
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO library_identity VALUES (1, ?, ?)", [UUID().uuidString.lowercased(), libraryID])
    try toolsExecuteUnlocked("UPDATE library_identity SET library_id=? WHERE library_id IS NULL", [libraryID])
  }
}

import Foundation
import SQLite3

extension WorkspaceDatabaseConnection {
  func createCompanionFederationSchemaUnlocked() throws {
    // Additive tables deliberately preserve v3 credentials, revisions and outboxes.
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS companion_library_identity (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1), host_device_id TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS companion_execution_workspaces (
        id TEXT PRIMARY KEY, owner_device_id TEXT NOT NULL, revision INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS companion_execution_journal (
        cursor INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
        workspace_id TEXT NOT NULL, origin_sequence INTEGER NOT NULL,
        fingerprint BLOB NOT NULL, payload BLOB NOT NULL,
        UNIQUE(workspace_id, origin_sequence)
      );
      CREATE TABLE IF NOT EXISTS companion_execution_conversations (
        id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
        conversation BLOB NOT NULL, transcript BLOB
      );
      CREATE TABLE IF NOT EXISTS companion_execution_adoptions (
        conversation_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, payload BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS companion_execution_runs (
        id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, conversation_id TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS companion_execution_receipts (
        workspace_id TEXT NOT NULL, command_id TEXT NOT NULL, device_id TEXT NOT NULL,
        payload BLOB NOT NULL, PRIMARY KEY(workspace_id, command_id)
      );
      CREATE TABLE IF NOT EXISTS companion_native_history (
        workspace_id TEXT NOT NULL, record_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
        run_id TEXT, format TEXT NOT NULL, part_count INTEGER NOT NULL, byte_count INTEGER NOT NULL,
        sha256 TEXT NOT NULL, complete INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(workspace_id, record_id)
      );
      CREATE TABLE IF NOT EXISTS companion_native_history_parts (
        workspace_id TEXT NOT NULL, record_id TEXT NOT NULL, part_index INTEGER NOT NULL, bytes BLOB NOT NULL,
        PRIMARY KEY(workspace_id, record_id, part_index)
      );
      CREATE TABLE IF NOT EXISTS companion_saved_artifacts (
        id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest BLOB NOT NULL
      );
      CREATE TABLE IF NOT EXISTS companion_artifact_uploads (
        id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest BLOB NOT NULL,
        next_offset INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS companion_artifact_chunks (
        artifact_id TEXT NOT NULL, revision INTEGER NOT NULL, offset INTEGER NOT NULL,
        bytes BLOB NOT NULL, PRIMARY KEY(artifact_id, revision, offset)
      );
      """)
    try companionExecuteUnlocked("INSERT OR IGNORE INTO companion_library_identity VALUES (1, ?)",
                                 values: [UUID().uuidString.lowercased()])
  }
}

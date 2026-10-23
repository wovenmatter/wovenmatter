import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  func createCompanionSchemaUnlocked() throws {
    try createCompanionFederationSchemaUnlocked()
    try createProductAnalyticsSchemaUnlocked()
    try createCompanionToolSchemaUnlocked()
    try executeUnlocked("""
      CREATE INDEX IF NOT EXISTS desktop_cache_runs_active_conversation
        ON dashboard_runs(conversation_id, status, created_at DESC, id DESC);
      CREATE TABLE IF NOT EXISTS dictation_history (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
        created_at REAL NOT NULL, payload_json TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS dictation_history_date ON dictation_history(created_at DESC, id DESC);
      CREATE TABLE IF NOT EXISTS companion_workspace (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1), workspace_id TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS companion_versions (
        kind TEXT NOT NULL, resource_id TEXT NOT NULL, revision INTEGER NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(kind, resource_id)
      );
      CREATE TABLE IF NOT EXISTS companion_changes (
        cursor INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
        resource_id TEXT NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS companion_mutation_receipts (
        device_id TEXT NOT NULL, operation_id TEXT NOT NULL, request BLOB NOT NULL,
        response BLOB NOT NULL, PRIMARY KEY(device_id, operation_id)
      );
      CREATE TABLE IF NOT EXISTS companion_command_receipts (
        device_id TEXT NOT NULL, command_id TEXT NOT NULL, request BLOB NOT NULL,
        response BLOB NOT NULL, PRIMARY KEY(device_id, command_id)
      );
      CREATE TABLE IF NOT EXISTS companion_draft_receipts (
        operation_id TEXT PRIMARY KEY, note_id TEXT NOT NULL, title TEXT NOT NULL,
        content TEXT NOT NULL, revision TEXT NOT NULL
      );
      """)
    let identity = try prepareUnlocked("INSERT OR IGNORE INTO companion_workspace VALUES (1, ?)")
    defer { sqlite3_finalize(identity) }
    try bind(UUID().uuidString.lowercased(), at: 1, to: identity)
    try stepDone(identity)
    for (table, kind, identifier, deletion) in [
      ("folders", "folder", "id", "0"),
      ("notes", "note", "id", "CASE WHEN NEW.deleted_at IS NULL THEN 0 ELSE 1 END"),
      ("dashboard_conversations", "conversation", "id", "CASE WHEN NEW.deleted_at IS NULL AND NEW.is_archived = 0 THEN 0 ELSE 1 END"),
      ("dashboard_messages", "transcript", "conversation_id", "0"),
      ("dashboard_runs", "transcript", "conversation_id", "0"),
      ("dashboard_run_events", "transcript", "conversation_id", "0"),
      ("dashboard_run_trace_events", "transcript", "conversation_id", "0"),
      ("dashboard_message_attachments", "transcript", "conversation_id", "0"),
      ("dashboard_message_references", "transcript", "conversation_id", "0"),
      ("dashboard_agents", "providers", "id", "0"),
    ] {
      // Some legacy databases do not yet have optional activity projections.
      let exists = try prepareUnlocked("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
      try bind(table, at: 1, to: exists)
      let present = sqlite3_step(exists) == SQLITE_ROW
      sqlite3_finalize(exists)
      guard present else { continue }
      if kind == "folder" || kind == "note" || kind == "conversation" {
        let initialDeletion = deletion.replacingOccurrences(of: "NEW.", with: "")
        try executeUnlocked("""
          INSERT OR IGNORE INTO companion_versions(kind, resource_id, revision, deleted)
          SELECT '\(kind)', \(identifier), 1, \(initialDeletion) FROM \(table);
          """)
      }
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let row = operation == "DELETE" ? "OLD" : "NEW"
        // Removing one message/run changes its transcript, not the conversation's existence.
        let deleted = operation == "DELETE" ? (["folder", "note", "conversation"].contains(kind) ? "1" : "0") : deletion
        // Pinning affects presentation, not the note's edit revision. Replace the
        // legacy trigger when upgrading an earlier companion database.
        let increment = table == "notes" && operation == "UPDATE"
          ? "CASE WHEN NEW.title IS NOT OLD.title OR NEW.content IS NOT OLD.content OR NEW.folder_id IS NOT OLD.folder_id OR NEW.deleted_at IS NOT OLD.deleted_at OR NEW.updated_at IS NOT OLD.updated_at THEN 1 ELSE 0 END"
          : "1"
        if table == "notes", operation == "UPDATE" { try executeUnlocked("DROP TRIGGER IF EXISTS companion_notes_update") }
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS companion_\(table)_\(operation.lowercased())
          AFTER \(operation) ON \(table)
          BEGIN
            INSERT INTO companion_versions(kind, resource_id, revision, deleted)
            VALUES ('\(kind)', \(row).\(identifier), 1, \(deleted))
            ON CONFLICT(kind, resource_id) DO UPDATE SET revision = revision + \(increment), deleted = excluded.deleted;
            INSERT INTO companion_changes(kind, resource_id, revision, deleted)
            SELECT kind, resource_id, revision, deleted FROM companion_versions
            WHERE kind = '\(kind)' AND resource_id = \(row).\(identifier);
            DELETE FROM companion_changes WHERE cursor <=
              (SELECT COALESCE(MAX(cursor), 0) - \(CompanionProtocol.maximumReplayChanges) FROM companion_changes);
          END;
          """)
      }
    }
    // Detach notes and unbound conversations at every deletion entry point.
    // Rooted sessions retain their captured folder identity and execution directory.
    try executeUnlocked("""
      DROP TRIGGER IF EXISTS companion_folder_detach;
      CREATE TRIGGER companion_folder_detach BEFORE DELETE ON folders
      BEGIN
        UPDATE notes SET folder_id = NULL WHERE folder_id = OLD.id;
        UPDATE dashboard_conversations SET folder_id = NULL WHERE folder_id = OLD.id
          AND NOT EXISTS(SELECT 1 FROM session_execution_roots WHERE conversation_id = dashboard_conversations.id);
      END;
      """)
  }
}

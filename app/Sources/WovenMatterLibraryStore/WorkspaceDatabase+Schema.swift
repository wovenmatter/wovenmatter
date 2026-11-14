import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// The library's core tables, its workspace revision and their triggers.
extension WorkspaceDatabaseConnection {
  /// Conversations, their transcripts and runs, agents, folders, notes,
  /// calendar items and the local harness sessions. Every table is created
  /// in its current shape; `upgradeLibrarySchemaUnlocked` brings an older
  /// library to it first.
  ///
  /// A conversation's transcript (`libraryTranscriptUnlocked`) is its rows.
  /// The columns only an execution owner's projection writes, NULL in rows
  /// this Mac writes, hold what its `LibraryTranscript` said:
  /// - `position` on messages, run activities and runs: the order in which
  ///   the transcript first listed the row. A run with one is in the
  ///   transcript's `runs`.
  /// - `messages.sequence` and `attachment_references` (JSON of
  ///   `[LibraryAttachmentReference]`, files the owner holds).
  /// - on run activities, the transcript row's `title`, `detail`, `status`,
  ///   `details_record_id`, `is_transient`, `sequence` and `completed_at`;
  ///   `content` is then the owner's projection as it sent it.
  /// An empty `status` or `created_at` is one the owner did not send.
  static let coreTablesSQL = """
    CREATE TABLE IF NOT EXISTS surface_profiles (
      id TEXT PRIMARY KEY, device_id TEXT, theme TEXT NOT NULL DEFAULT 'green',
      sidebar_style TEXT NOT NULL DEFAULT 'split',
      single_sidebar_side TEXT NOT NULL DEFAULT 'left',
      left_rail_visible INTEGER NOT NULL DEFAULT 1,
      right_rail_visible INTEGER NOT NULL DEFAULT 1,
      single_rail_visible INTEGER NOT NULL DEFAULT 1,
      chat_width_percent REAL NOT NULL DEFAULT 58,
      note_on_left INTEGER NOT NULL DEFAULT 0,
      workspace_mode TEXT NOT NULL DEFAULT 'chats',
      agent_order_json TEXT NOT NULL DEFAULT '[]',
      revision INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS folders (
      id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
      icon TEXT NOT NULL DEFAULT 'folder', position INTEGER NOT NULL DEFAULT 0,
      is_pinned INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS folder_execution_roots (
      folder_id TEXT PRIMARY KEY REFERENCES folders(id) ON DELETE CASCADE,
      workspace_id TEXT NOT NULL, root_path TEXT NOT NULL,
      managed INTEGER NOT NULL, reference_paths TEXT NOT NULL DEFAULT '[]'
    );
    CREATE TABLE IF NOT EXISTS session_scratch_directories (
      session_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
      workspace_root TEXT NOT NULL, root_path TEXT NOT NULL,
      UNIQUE(workspace_id, root_path)
    );
    CREATE TABLE IF NOT EXISTS execution_workspace_defaults (workspace_id TEXT PRIMARY KEY, default_path TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS retained_execution_history (
      conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS session_execution_roots (
      conversation_id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL,
      root_path TEXT NOT NULL, folder_locked INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY, folder_id TEXT,
      title TEXT NOT NULL DEFAULT 'Untitled Note', content TEXT NOT NULL DEFAULT '',
      snippet TEXT, is_pinned INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
      deleted_at TEXT, original_folder_id TEXT,
      created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS opencode_sessions (
      conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
      connection_id TEXT NOT NULL, session_id TEXT NOT NULL, snapshot_json TEXT NOT NULL,
      UNIQUE(connection_id, session_id)
    );
    CREATE TABLE IF NOT EXISTS opencode_submissions (
      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS agents (
      id TEXT PRIMARY KEY, codename TEXT NOT NULL DEFAULT '',
      display_name TEXT NOT NULL DEFAULT '', icon TEXT NOT NULL DEFAULT 'bot',
      execution_location TEXT NOT NULL DEFAULT 'local', owner_device_id TEXT,
      runtime_kind TEXT NOT NULL, runtime_device_id TEXT, platform_codename TEXT,
      status TEXT NOT NULL DEFAULT 'offline', revision INTEGER NOT NULL DEFAULT 1,
      deleted_at TEXT, created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY, agent_id TEXT, agent_codename TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL DEFAULT 'New conversation',
      unread INTEGER NOT NULL DEFAULT 0, last_message_preview TEXT,
      is_archived INTEGER NOT NULL DEFAULT 0, last_message_at TEXT NOT NULL DEFAULT '',
      folder_id TEXT, original_folder_id TEXT, is_pinned INTEGER NOT NULL DEFAULT 0, deleted_at TEXT,
      created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS conversation_titles (
      conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
      title TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '', client_message_id TEXT,
      run_id TEXT, role TEXT NOT NULL DEFAULT 'assistant',
      content TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'completed',
      created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
      sequence INTEGER, position INTEGER, attachment_references TEXT
    );
    CREATE TABLE IF NOT EXISTS message_attachments (
      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
      message_id TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'file',
      file_name TEXT NOT NULL DEFAULT '', mime_type TEXT NOT NULL DEFAULT '',
      size_bytes INTEGER NOT NULL DEFAULT 0, content_hash TEXT, created_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS message_references (
      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
      message_id TEXT NOT NULL DEFAULT '',
      resource_type TEXT NOT NULL DEFAULT 'note', resource_id TEXT NOT NULL DEFAULT '',
      source TEXT NOT NULL DEFAULT 'attached', title_snapshot TEXT NOT NULL DEFAULT '',
      content_snapshot TEXT NOT NULL DEFAULT '',
      folder_id_snapshot TEXT, folder_title_snapshot TEXT, agent_codename_snapshot TEXT,
      revision_snapshot TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS runs (
      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '', agent_id TEXT,
      agent_codename TEXT NOT NULL DEFAULT '',
      native_session_id TEXT NOT NULL DEFAULT '', user_message_id TEXT,
      assistant_message_id TEXT, status TEXT NOT NULL DEFAULT 'queued', error TEXT,
      started_at TEXT, completed_at TEXT,
      created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
      position INTEGER
    );
    CREATE TABLE IF NOT EXISTS run_visible_notes (
      run_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
      note_id TEXT NOT NULL DEFAULT '', revision_snapshot TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS run_program_statuses (
      run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
      source TEXT NOT NULL, records_json TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      PRIMARY KEY(run_id, source)
    );
    CREATE TABLE IF NOT EXISTS remote_note_edits (
      run_id TEXT PRIMARY KEY, assistant_message_id TEXT NOT NULL,
      note_id TEXT NOT NULL, expected_revision TEXT NOT NULL,
      nonce TEXT NOT NULL, note_kind TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'pending', error TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS run_activities (
      id TEXT PRIMARY KEY, run_id TEXT NOT NULL DEFAULT '',
      conversation_id TEXT NOT NULL DEFAULT '',
      event_type TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL DEFAULT '',
      position INTEGER, sequence INTEGER, title TEXT, detail TEXT, status TEXT,
      details_record_id TEXT, is_transient INTEGER, completed_at TEXT
    );
    CREATE TABLE IF NOT EXISTS harness_sessions (
      conversation_id TEXT PRIMARY KEY, agent_id TEXT,
      runtime_kind TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
      title TEXT NOT NULL,
      native_session_id TEXT, model TEXT, thinking TEXT, permission TEXT,
      remote_workspace_id TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS session_imports (
      conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
      imported_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS calendar_items (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL DEFAULT '', description TEXT, starts_at TEXT NOT NULL DEFAULT '',
      ends_at TEXT, all_day INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'scheduled',
      source TEXT NOT NULL DEFAULT 'user', calendar_json TEXT, next_fire_at REAL,
      task_session_id TEXT, deleted_at TEXT,
      created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
    );
    CREATE TABLE IF NOT EXISTS workspace_revision (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      revision INTEGER NOT NULL DEFAULT 0
    );
    """

  private func createCoreTablesUnlocked() throws {
    try executeUnlocked(Self.coreTablesSQL + """
      INSERT OR IGNORE INTO workspace_revision (singleton, revision) VALUES (1, 0);
      CREATE INDEX IF NOT EXISTS conversations_recent
        ON conversations(is_archived, deleted_at, last_message_at DESC);
      CREATE INDEX IF NOT EXISTS conversations_folder
        ON conversations(folder_id) WHERE folder_id IS NOT NULL;
      CREATE INDEX IF NOT EXISTS messages_conversation_created
        ON messages(conversation_id, created_at, id);
      CREATE INDEX IF NOT EXISTS messages_conversation_position
        ON messages(conversation_id, position) WHERE position IS NOT NULL;
      CREATE INDEX IF NOT EXISTS message_attachments_message_created
        ON message_attachments(message_id, created_at, id);
      CREATE INDEX IF NOT EXISTS message_references_message_created
        ON message_references(message_id, created_at, id);
      CREATE INDEX IF NOT EXISTS run_activities_run_created
        ON run_activities(run_id, created_at, id);
      CREATE INDEX IF NOT EXISTS run_activities_conversation_created
        ON run_activities(conversation_id, created_at, id);
      CREATE INDEX IF NOT EXISTS run_activities_conversation_position
        ON run_activities(conversation_id, position) WHERE position IS NOT NULL;
      CREATE INDEX IF NOT EXISTS runs_conversation_user_message
        ON runs(conversation_id, user_message_id);
      CREATE INDEX IF NOT EXISTS runs_conversation_assistant_message
        ON runs(conversation_id, assistant_message_id);
      CREATE INDEX IF NOT EXISTS runs_conversation_status
        ON runs(conversation_id, status, created_at DESC, id DESC);
      CREATE INDEX IF NOT EXISTS notes_recent
        ON notes(deleted_at, updated_at DESC);
      CREATE INDEX IF NOT EXISTS notes_folder
        ON notes(folder_id) WHERE folder_id IS NOT NULL;
      CREATE INDEX IF NOT EXISTS opencode_submissions_conversation
        ON opencode_submissions(conversation_id, status);
      """)
  }

  func migrate() throws {
    try transaction {
      try createCoreTablesUnlocked()
      try createWorkspaceRevisionTriggersUnlocked()
      try createDeviceSchemaUnlocked()
    }
  }

  /// Every change to these tables advances `workspace_revision`, the
  /// workspace overview's change counter.
  private func createWorkspaceRevisionTriggersUnlocked() throws {
    for table in [
      "folders",
      "folder_execution_roots",
      "session_execution_roots",
      "retained_execution_history",
      "surface_profiles",
      "agents",
      "conversations",
      "messages",
      "notes",
      "runs",
      "run_program_statuses",
      "calendar_items",
      "harness_sessions",
      "opencode_sessions",
      "opencode_submissions",
    ] {
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS \(table)_workspace_revision_\(operation.lowercased())
          AFTER \(operation) ON \(table)
          BEGIN
            UPDATE workspace_revision SET revision = revision + 1 WHERE singleton = 1;
          END
          """)
      }
    }
  }
}

import Foundation
import SQLite3

// Schema creation, compatibility columns and revision triggers.
extension WorkspaceDatabase {
  private func createWorkspaceCacheTablesUnlocked() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS profiles (
        id TEXT PRIMARY KEY, email TEXT, name TEXT, avatar_url TEXT, time_zone TEXT,
        theme TEXT, origin_device_id TEXT, created_at TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS surface_profiles (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '',
        surface TEXT NOT NULL CHECK (surface IN (
          'server_web', 'mac_native', 'web', 'mac'
        )),
        device_id TEXT, theme TEXT NOT NULL DEFAULT 'green',
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
        authority_kind TEXT NOT NULL DEFAULT 'device_owned',
        authority_device_id TEXT, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS folders (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', name TEXT NOT NULL DEFAULT '',
        icon TEXT NOT NULL DEFAULT 'folder', position INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', folder_id TEXT,
        title TEXT NOT NULL DEFAULT 'Untitled Note', content TEXT NOT NULL DEFAULT '',
        snippet TEXT, is_favorite INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT, original_folder_id TEXT, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS desktop_scheduled_result_routes (
        provider TEXT NOT NULL, agent_id TEXT NOT NULL, job_id TEXT NOT NULL,
        destination TEXT NOT NULL, PRIMARY KEY(provider, agent_id, job_id)
      );
      CREATE TABLE IF NOT EXISTS desktop_scheduled_result_receipts (
        provider TEXT NOT NULL, agent_id TEXT NOT NULL, job_id TEXT NOT NULL,
        run_id TEXT NOT NULL, conversation_id TEXT NOT NULL, message_id TEXT NOT NULL,
        collected_at TEXT NOT NULL, PRIMARY KEY(provider, agent_id, job_id, run_id)
      );
      CREATE TABLE IF NOT EXISTS desktop_opencode_sessions (
        conversation_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id),
        connection_id TEXT NOT NULL, session_id TEXT NOT NULL, snapshot_json TEXT NOT NULL,
        UNIQUE(connection_id, session_id)
      );
      CREATE TABLE IF NOT EXISTS desktop_opencode_submissions (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS dashboard_agents (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', codename TEXT NOT NULL DEFAULT '',
        display_name TEXT NOT NULL DEFAULT '', role TEXT, description TEXT,
        icon TEXT NOT NULL DEFAULT 'bot', execution_location TEXT NOT NULL DEFAULT 'local',
        agent_bucket TEXT NOT NULL DEFAULT 'local_cli',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT,
        runtime_kind TEXT NOT NULL DEFAULT 'openclaw', runtime_device_id TEXT,
        platform_codename TEXT, model TEXT, fallback_model TEXT,
        status TEXT NOT NULL DEFAULT 'offline', is_primary INTEGER NOT NULL DEFAULT 0,
        runtime_metadata_json TEXT NOT NULL DEFAULT '{}', revision INTEGER NOT NULL DEFAULT 1,
        origin_device_id TEXT, deleted_at TEXT, created_at TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT '', desktop_owned INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS dashboard_conversations (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '',
        agent_id TEXT, agent_codename TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, title TEXT NOT NULL DEFAULT 'New conversation',
        unread INTEGER NOT NULL DEFAULT 0, last_message_preview TEXT,
        openclaw_session_key TEXT, kind TEXT NOT NULL DEFAULT 'dashboard',
        is_deletable INTEGER NOT NULL DEFAULT 1,
        is_archived INTEGER NOT NULL DEFAULT 0, context_generation INTEGER NOT NULL DEFAULT 0,
        last_message_at TEXT NOT NULL DEFAULT '', folder_id TEXT, original_folder_id TEXT,
        is_pinned INTEGER NOT NULL DEFAULT 0, deleted_at TEXT, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
        desktop_owned INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS dashboard_messages (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '', client_message_id TEXT,
        run_id TEXT, role TEXT NOT NULL DEFAULT 'assistant',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT,
        message_source TEXT NOT NULL DEFAULT 'client_observed', content TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'completed', origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
        desktop_owned INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS dashboard_message_attachments (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
        message_id TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'file',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        file_name TEXT NOT NULL DEFAULT '', mime_type TEXT NOT NULL DEFAULT '',
        size_bytes INTEGER NOT NULL DEFAULT 0, content_hash TEXT, gateway_media_ref TEXT,
        origin_device_id TEXT, created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_message_references (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
        message_id TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        resource_type TEXT NOT NULL DEFAULT 'note', resource_id TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'attached', title_snapshot TEXT NOT NULL DEFAULT '',
        content_snapshot TEXT NOT NULL DEFAULT '',
        folder_id_snapshot TEXT, folder_title_snapshot TEXT, agent_codename_snapshot TEXT,
        revision_snapshot TEXT NOT NULL DEFAULT '', origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_runs (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
        user_id TEXT NOT NULL DEFAULT '', agent_id TEXT,
        agent_codename TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT,
        openclaw_session_key TEXT NOT NULL DEFAULT '', user_message_id TEXT,
        assistant_message_id TEXT, status TEXT NOT NULL DEFAULT 'queued', error TEXT,
        started_at TEXT, completed_at TEXT, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
        desktop_owned INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS dashboard_run_visible_context (
        run_id TEXT PRIMARY KEY, message_id TEXT NOT NULL DEFAULT '',
        conversation_id TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        note_id TEXT NOT NULL DEFAULT '', note_title_snapshot TEXT NOT NULL DEFAULT '',
        folder_id_snapshot TEXT, folder_title_snapshot TEXT,
        revision_snapshot TEXT NOT NULL DEFAULT '', origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS desktop_remote_note_edits (
        run_id TEXT PRIMARY KEY, assistant_message_id TEXT NOT NULL,
        note_id TEXT NOT NULL, expected_revision TEXT NOT NULL,
        nonce TEXT NOT NULL, note_kind TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending', error TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS dashboard_run_events (
        id TEXT PRIMARY KEY, run_id TEXT NOT NULL DEFAULT '',
        conversation_id TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        event_type TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '',
        origin_device_id TEXT, created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_run_trace_events (
        id TEXT PRIMARY KEY, run_id TEXT NOT NULL DEFAULT '',
        conversation_id TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        agent_codename TEXT NOT NULL DEFAULT '', openclaw_session_key TEXT NOT NULL DEFAULT '',
        seq INTEGER NOT NULL DEFAULT 0, event_source TEXT NOT NULL DEFAULT 'broker',
        event_type TEXT NOT NULL DEFAULT '', event_name TEXT, event_phase TEXT, tool_name TEXT,
        content TEXT, is_visible INTEGER NOT NULL DEFAULT 0,
        projection_applied INTEGER NOT NULL DEFAULT 0,
        raw_event_json TEXT NOT NULL DEFAULT '{}', stream_event_json TEXT NOT NULL DEFAULT '[]',
        origin_device_id TEXT, created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_user_view_state (
        user_id TEXT PRIMARY KEY, selected_agent_codename TEXT,
        active_conversation_id TEXT, active_note_id TEXT, selected_folder_id TEXT,
        workspace_mode TEXT NOT NULL DEFAULT 'chats', pane_order TEXT NOT NULL DEFAULT 'chat-note',
        chat_width_percent REAL NOT NULL DEFAULT 58, agent_rail_collapsed INTEGER NOT NULL DEFAULT 0,
        inbox_collapsed INTEGER NOT NULL DEFAULT 0, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS desktop_local_acp_sessions (
        conversation_id TEXT PRIMARY KEY, agent_id TEXT,
        runtime_kind TEXT NOT NULL,
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT,
        revision INTEGER NOT NULL DEFAULT 1,
        title TEXT NOT NULL,
        acp_session_id TEXT, model TEXT, thinking TEXT,
        buzz_workspace_link_id TEXT, buzz_agent_id TEXT,
        remote_workspace_id TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_local_identity (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        device_id TEXT NOT NULL,
        bound_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_session_imports (
        conversation_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id) ON DELETE CASCADE,
        imported_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_import_activity (
        conversation_id TEXT PRIMARY KEY REFERENCES dashboard_conversations(id) ON DELETE CASCADE,
        imported_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_transcript_entries (
        conversation_id TEXT NOT NULL, entry_id TEXT NOT NULL,
        message_id TEXT NOT NULL, payload BLOB NOT NULL,
        PRIMARY KEY (conversation_id, entry_id)
      );
      CREATE TRIGGER IF NOT EXISTS desktop_openclaw_transcript_delete
      AFTER DELETE ON dashboard_conversations BEGIN
        DELETE FROM desktop_openclaw_transcript_entries WHERE conversation_id = OLD.id;
      END;
      CREATE TABLE IF NOT EXISTS desktop_openclaw_run_inputs (
        conversation_id TEXT NOT NULL, local_run_id TEXT NOT NULL, remote_run_id TEXT NOT NULL,
        user_message_id TEXT NOT NULL, assistant_message_id TEXT NOT NULL,
        PRIMARY KEY (conversation_id, remote_run_id)
      );
      CREATE INDEX IF NOT EXISTS desktop_openclaw_run_inputs_local ON desktop_openclaw_run_inputs(local_run_id);
      CREATE TRIGGER IF NOT EXISTS desktop_openclaw_run_inputs_delete
      AFTER DELETE ON dashboard_conversations BEGIN
        DELETE FROM desktop_openclaw_run_inputs WHERE conversation_id = OLD.id;
      END;
      CREATE TABLE IF NOT EXISTS desktop_buzz_workspace_links (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        local_workspace_url TEXT NOT NULL,
        local_agent_store_url TEXT NOT NULL,
        is_enabled INTEGER NOT NULL DEFAULT 1
          CHECK (is_enabled IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_buzz_agent_enrollments (
        id TEXT PRIMARY KEY,
        workspace_link_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        handle_snapshot TEXT NOT NULL,
        display_name_snapshot TEXT NOT NULL,
        harness_identifier TEXT NOT NULL,
        runtime_kind TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE (workspace_link_id, agent_id),
        FOREIGN KEY (workspace_link_id)
          REFERENCES desktop_buzz_workspace_links(id) ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_gateway_links (
        agent_id TEXT PRIMARY KEY,
        location TEXT NOT NULL CHECK (location IN (
          'buzz_local', 'local_agent_workspace', 'remote_workspace'
        )),
        endpoint_url TEXT NOT NULL,
        authorization TEXT NOT NULL CHECK (authorization IN (
          'localService', 'remoteWorkspace'
        )),
        status TEXT NOT NULL,
        openclaw_version TEXT,
        last_connected_at TEXT,
        last_error TEXT,
        linked_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_gateway_sessions (
        conversation_id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        session_key TEXT NOT NULL,
        model TEXT,
        thinking_level TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES dashboard_conversations(id)
          ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_cron_jobs (
        agent_id TEXT NOT NULL,
        remote_job_id TEXT NOT NULL,
        name TEXT NOT NULL,
        schedule TEXT NOT NULL,
        enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
        native_session_id TEXT,
        native_session_key TEXT,
        archive_state TEXT NOT NULL CHECK (archive_state IN ('active', 'deleted')),
        remote_payload BLOB NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (agent_id, remote_job_id)
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_cron_runs (
        agent_id TEXT NOT NULL,
        remote_run_id TEXT NOT NULL,
        remote_job_id TEXT NOT NULL,
        status TEXT NOT NULL,
        output TEXT,
        native_session_id TEXT,
        native_session_key TEXT,
        started_at TEXT,
        completed_at TEXT,
        remote_payload BLOB NOT NULL,
        PRIMARY KEY (agent_id, remote_run_id)
      );
      CREATE TABLE IF NOT EXISTS desktop_scheduled_result_routes (
        provider TEXT NOT NULL, agent_id TEXT NOT NULL, job_id TEXT NOT NULL,
        destination TEXT NOT NULL, PRIMARY KEY(provider, agent_id, job_id)
      );
      CREATE TABLE IF NOT EXISTS desktop_scheduled_result_receipts (
        provider TEXT NOT NULL, agent_id TEXT NOT NULL, job_id TEXT NOT NULL,
        run_id TEXT NOT NULL, conversation_id TEXT NOT NULL, message_id TEXT NOT NULL,
        collected_at TEXT NOT NULL, PRIMARY KEY(provider, agent_id, job_id, run_id)
      );
      CREATE TABLE IF NOT EXISTS dashboard_calendar_items (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '', description TEXT, starts_at TEXT NOT NULL DEFAULT '',
        ends_at TEXT, all_day INTEGER NOT NULL DEFAULT 0, agent_codename TEXT,
        pinned_folder_id TEXT, delivery_folder_id TEXT, status TEXT NOT NULL DEFAULT 'scheduled',
        schedule_label TEXT, source TEXT NOT NULL DEFAULT 'user', origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS desktop_cache_conversations_user_last
        ON dashboard_conversations(user_id, is_archived, deleted_at, last_message_at DESC);
      CREATE INDEX IF NOT EXISTS desktop_cache_messages_conversation_created
        ON dashboard_messages(conversation_id, created_at);
      CREATE INDEX IF NOT EXISTS desktop_cache_messages_conversation_created_id
        ON dashboard_messages(conversation_id, created_at, id);
      CREATE INDEX IF NOT EXISTS desktop_cache_attachments_message_created_id
        ON dashboard_message_attachments(message_id, created_at, id);
      CREATE INDEX IF NOT EXISTS desktop_cache_references_message_created_id
        ON dashboard_message_references(message_id, created_at, id);
      CREATE INDEX IF NOT EXISTS desktop_cache_events_run_created_id
        ON dashboard_run_events(run_id, created_at, id);
      CREATE INDEX IF NOT EXISTS desktop_cache_visible_traces_run_created_id
        ON dashboard_run_trace_events(run_id, created_at, seq, id)
        WHERE is_visible = 1;
      CREATE INDEX IF NOT EXISTS desktop_cache_runs_conversation_user_message
        ON dashboard_runs(conversation_id, user_message_id);
      CREATE INDEX IF NOT EXISTS desktop_cache_runs_conversation_assistant_message
        ON dashboard_runs(conversation_id, assistant_message_id);
      CREATE INDEX IF NOT EXISTS desktop_cache_notes_user_updated
        ON notes(user_id, deleted_at, updated_at DESC);
      CREATE INDEX IF NOT EXISTS desktop_buzz_workspace_links_name
        ON desktop_buzz_workspace_links(display_name);
      CREATE INDEX IF NOT EXISTS desktop_buzz_agent_enrollments_workspace
        ON desktop_buzz_agent_enrollments(workspace_link_id, display_name_snapshot);
      CREATE INDEX IF NOT EXISTS desktop_openclaw_gateway_sessions_agent
        ON desktop_openclaw_gateway_sessions(agent_id, updated_at DESC);
      CREATE INDEX IF NOT EXISTS desktop_openclaw_cron_jobs_state
        ON desktop_openclaw_cron_jobs(agent_id, archive_state, updated_at DESC);
      CREATE INDEX IF NOT EXISTS desktop_openclaw_cron_runs_job
        ON desktop_openclaw_cron_runs(agent_id, remote_job_id, started_at DESC);
      """)
  }

  func migrate() throws {
    try transaction {
      try createWorkspaceCacheTablesUnlocked()
      try addCurrentColumnsUnlocked()
      try createDashboardRevisionTrackingUnlocked()
    }
  }

  private func addCurrentColumnsUnlocked() throws {
    let traces = try prepareUnlocked("PRAGMA table_info(dashboard_run_trace_events)")
    defer { sqlite3_finalize(traces) }
    var hasProjectionApplied = false
    while true {
      let code = sqlite3_step(traces)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      if optionalText(traces, column: 1) == "projection_applied" { hasProjectionApplied = true }
    }
    if !hasProjectionApplied {
      try executeUnlocked("ALTER TABLE dashboard_run_trace_events ADD COLUMN projection_applied INTEGER NOT NULL DEFAULT 0")
    }

    let cron = try prepareUnlocked("PRAGMA table_info(desktop_openclaw_cron_runs)")
    defer { sqlite3_finalize(cron) }
    var hasFullOutput = false
    while true {
      let code = sqlite3_step(cron)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      if optionalText(cron, column: 1) == "full_output" { hasFullOutput = true }
    }
    if !hasFullOutput {
      try executeUnlocked("ALTER TABLE desktop_openclaw_cron_runs ADD COLUMN full_output INTEGER NOT NULL DEFAULT 0")
    }

    let statement = try prepareUnlocked(
      "PRAGMA table_info(desktop_local_acp_sessions)"
    )
    defer { sqlite3_finalize(statement) }
    var columns: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = optionalText(statement, column: 1) { columns.insert(name) }
    }
    if !columns.contains("remote_workspace_id") {
      try executeUnlocked(
        "ALTER TABLE desktop_local_acp_sessions ADD COLUMN remote_workspace_id TEXT"
      )
    }
  }

  private func createDashboardRevisionTrackingUnlocked() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS desktop_dashboard_revision (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        revision INTEGER NOT NULL DEFAULT 0
      );
      INSERT OR IGNORE INTO desktop_dashboard_revision (singleton, revision)
      VALUES (1, 0);
      """)
    for table in [
      "folders",
      "surface_profiles",
      "dashboard_agents",
      "dashboard_conversations",
      "dashboard_messages",
      "notes",
      "dashboard_runs",
      "dashboard_calendar_items",
      "desktop_local_acp_sessions",
      "desktop_buzz_workspace_links",
      "desktop_buzz_agent_enrollments",
      "desktop_openclaw_gateway_links",
      "desktop_openclaw_gateway_sessions",
      "desktop_openclaw_cron_jobs",
      "desktop_openclaw_cron_runs",
    ] {
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let trigger = "desktop_dashboard_revision_\(table)_\(operation.lowercased())"
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS \(trigger)
          AFTER \(operation) ON \(table)
          BEGIN
            UPDATE desktop_dashboard_revision
            SET revision = revision + 1
            WHERE singleton = 1;
          END
          """)
      }
    }
  }
}

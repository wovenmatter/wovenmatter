#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

/// Converts a library written by v0.4.2, or by a build before the versioned
/// schema, to the current schema in place.
///
/// v0.4.2 still used the names of the codebase the library came from: core
/// tables named `dashboard_*` and `desktop_*`, OpenClaw gateway tables and
/// columns, and per-row boilerplate (`user_id`, `governing_plane`,
/// `authority_kind`, `authority_agent_id`, `origin_device_id`,
/// `desktop_owned`) that every current writer sets to the same value. Its
/// later tables were named for where they came from (`paired_*`, `device_*`,
/// `workspace_*`) rather than what they hold, and it stored JSON as BLOB.
/// This renames the tables and columns that hold current data, drops what
/// nothing reads any more, stores JSON as text, moves each execution
/// owner's transcript document into its rows, moves the bytes of saved
/// artifact chunks and native history parts into files of the chunk store,
/// and rewrites the paired-sync bookkeeping to match, so paired Macs that
/// update together keep their versions and cursors.
///
/// It runs on open, before anything else creates schema, for a library whose
/// `user_version` is 0, and stamps `librarySchemaVersion` in the same
/// transaction. Every trigger is dropped first, and every index of a renamed
/// table and every index in `droppedLibraryIndexes` is dropped: the regular
/// schema creation that follows recreates both under their current names.
/// Each step checks what is present, so a partly converted or partly
/// created library converges on the same result.
extension WorkspaceDatabaseConnection {
  /// `PRAGMA user_version` of the current schema. A library created or
  /// converted by this build carries it, so it skips the conversion below
  /// and the next schema change is gated on the version instead of on what
  /// the file happens to contain. 0 is every library before it.
  static let librarySchemaVersion = 1

  func libraryVersionUnlocked() throws -> Int {
    try historyRowsUnlocked("PRAGMA user_version", values: []).first?.objectValue?["user_version"]?.intValue ?? 0
  }

  static let renamedLibraryTables: [(old: String, new: String)] = [
    ("dashboard_agents", "agents"),
    ("dashboard_conversations", "conversations"),
    ("dashboard_messages", "messages"),
    ("dashboard_message_attachments", "message_attachments"),
    ("dashboard_message_references", "message_references"),
    ("dashboard_runs", "runs"),
    ("dashboard_run_visible_context", "run_visible_notes"),
    ("dashboard_run_events", "run_activities"),
    ("dashboard_calendar_items", "calendar_items"),
    ("desktop_local_acp_sessions", "harness_sessions"),
    ("desktop_conversation_titles", "conversation_titles"),
    ("desktop_session_imports", "session_imports"),
    ("desktop_opencode_sessions", "opencode_sessions"),
    ("desktop_opencode_submissions", "opencode_submissions"),
    ("desktop_opencode_hidden_messages", "opencode_hidden_messages"),
    ("desktop_program_status", "run_program_statuses"),
    ("desktop_remote_note_edits", "remote_note_edits"),
    ("desktop_dashboard_revision", "workspace_revision"),
    ("desktop_activity_index", "activity_summaries"),
    ("desktop_activity_revision", "activity_revision"),
    ("desktop_message_revisions", "message_revisions"),
    // Named for what they hold: "workspace" is an execution host, and the
    // paired-sync and Device API prefixes said where a table came from.
    ("paired_agent_owners", "agent_owners"),
    ("paired_conversation_owners", "conversation_owners"),
    ("paired_calendar_owners", "calendar_item_owners"),
    ("paired_mac_routes", "mac_routes"),
    ("paired_remote_workspaces", "remote_workspace_configurations"),
    ("device_message_provenance", "message_provenance"),
    ("device_saved_artifacts", "saved_artifacts"),
    ("device_artifact_uploads", "artifact_uploads"),
    ("device_artifact_chunks", "artifact_chunks"),
    ("workspace_automation_cancellations", "automation_cancellations"),
    ("workspace_automation_requests", "automation_requests"),
    ("workspace_calendar_remote_ownership", "calendar_remote_ownership"),
    ("workspace_calendar_remote_receipts", "calendar_remote_receipts"),
    ("workspace_calendar_runs", "calendar_runs"),
    ("workspace_calendar_sessions", "calendar_task_sessions"),
    ("workspace_coordination_access_requests", "coordination_access_requests"),
    ("workspace_coordination_observations", "coordination_observations"),
    ("workspace_executor_sessions", "session_executor_profiles"),
    ("workspace_goal_runs", "goal_runs"),
    ("workspace_goal_usage", "goal_usage"),
    ("workspace_history_events", "history_events"),
    ("workspace_history_search", "history_search"),
    ("workspace_input_contexts", "input_contexts"),
    ("workspace_mcp_bot_machines", "mcp_bot_machines"),
    ("workspace_mcp_callers", "mcp_callers"),
    ("workspace_opencode_input_context", "opencode_input_contexts"),
    ("workspace_session_creations", "session_creations"),
    ("workspace_session_deliveries", "session_deliveries"),
    ("workspace_session_goals", "session_goals"),
    ("workspace_session_grants", "session_grants"),
    ("workspace_session_relationships", "session_relationships"),
    ("workspace_session_timers", "session_timers"),
    ("workspace_session_tools", "session_tools"),
    ("workspace_tool_mutations", "tool_mutations"),
    ("workspace_tool_settings", "tool_settings"),
  ]

  /// Tables nothing reads or writes any more.
  static let droppedLibraryTables = [
    // OpenClaw gateway traces and bookkeeping; their chats stay as plain history.
    "dashboard_run_trace_events", "desktop_openclaw_gateway_sessions",
    "desktop_openclaw_import_activity", "desktop_openclaw_run_inputs",
    // Results of the OpenClaw dashboard's scheduled jobs, and its user profiles.
    "desktop_scheduled_result_routes", "desktop_scheduled_result_receipts", "profiles",
    // A copy of the device ID the `dashboard-device-id` file holds.
    "desktop_local_identity",
    // Runs a Linux host kept for chats that ran over SSH.
    "desktop_local_acp_durable_runs",
    // Version markers of one-time upgrades v0.4.2 libraries already ran.
    "desktop_activity_index_schema", "workspace_history_schema", "workspace_tool_schema",
    // Peer, workspace publisher and replica records of removed compatibility paths.
    "paired_library_seen", "execution_workspace_publishers", "execution_workspace_mcp_grants",
    "execution_replica_context", "calendar_replica_context", "calendar_execution_conflicts",
  ]

  /// Indexes recreated under a new name, or dropped with their table or column.
  static let droppedLibraryIndexes = [
    "desktop_cache_conversations_user_last", "desktop_cache_messages_conversation_created",
    "desktop_cache_messages_conversation_created_id", "desktop_cache_attachments_message_created_id",
    "desktop_cache_references_message_created_id", "desktop_cache_events_run_created_id",
    "desktop_cache_visible_traces_run_created_id", "desktop_cache_runs_conversation_user_message",
    "desktop_cache_runs_conversation_assistant_message", "desktop_cache_runs_active_conversation",
    "desktop_cache_notes_user_updated", "activity_index_conversation_revision", "activity_index_run",
    "history_conversation", "history_run", "history_harness", "history_native_session", "history_native_record",
    "library_dirty_messages", "library_message_items", "library_conversation_items", "library_pending_files",
    "note_versions_note", "session_deliveries_source", "workspace_access_requests_state",
    "workspace_calendar_due", "workspace_calendar_run_event", "workspace_calendar_pending_runs",
    "workspace_coordinator", "workspace_delivery_event", "workspace_timer_due",
    "usage_events_dedupe_idx", "usage_events_timestamp_idx", "usage_events_harness_idx",
    "usage_events_model_idx", "usage_events_route_idx", "usage_events_source_idx",
  ]

  /// Columns renamed in place, by their table's current name.
  static let renamedLibraryColumns: [(table: String, old: String, new: String)] = [
    // Each run's native harness session, which OpenClaw called its session key.
    ("runs", "openclaw_session_key", "native_session_id"),
    ("harness_sessions", "acp_session_id", "native_session_id"),
    // The device that owns the agent: the Mac that created it, or the
    // workspace owner for a remote harness.
    ("agents", "authority_device_id", "owner_device_id"),
  ]

  /// Columns dropped, by their table's current name. The six per-row columns
  /// every current writer sets to the same value: `user_id` (the single
  /// operator), `governing_plane` (always `wovenmatter_macos` outside agents,
  /// where `execution_location` says the same), `authority_kind`
  /// (always `device_owned`), `authority_agent_id` (a copy of `agent_id`),
  /// `origin_device_id` (a copy of the owner) and `desktop_owned` (always 1 for
  /// rows Woven writes). A conversation's, message's and run's device
  /// (`authority_device_id`, later `owner_device_id`) was a copy that mixed
  /// two kinds of device ID; ownership is the owner tables and
  /// `execution_conversations`. The rest have no writer or no reader.
  static let droppedLibraryColumns: [(table: String, columns: [String])] = [
    ("surface_profiles", ["user_id", "surface", "authority_kind", "authority_device_id", "origin_device_id"]),
    ("folders", ["user_id", "origin_device_id"]),
    ("notes", ["user_id", "is_favorite", "origin_device_id"]),
    ("agents", ["user_id", "role", "description", "agent_bucket", "governing_plane", "authority_kind",
                "authority_agent_id", "model", "fallback_model", "is_primary", "runtime_metadata_json",
                "origin_device_id", "desktop_owned"]),
    ("conversations", ["user_id", "governing_plane", "authority_kind", "authority_agent_id", "openclaw_session_key",
                       "kind", "is_deletable", "context_generation", "origin_device_id", "desktop_owned", "is_main",
                       "authority_device_id", "owner_device_id"]),
    ("messages", ["governing_plane", "authority_kind", "authority_agent_id", "message_source", "origin_device_id",
                  "desktop_owned", "authority_device_id", "owner_device_id"]),
    ("message_attachments", ["governing_plane", "authority_kind", "authority_device_id", "authority_agent_id",
                             "desktop_owned", "gateway_media_ref", "origin_device_id"]),
    ("message_references", ["user_id", "governing_plane", "authority_kind", "authority_device_id",
                            "authority_agent_id", "desktop_owned", "origin_device_id"]),
    ("runs", ["user_id", "governing_plane", "authority_kind", "authority_agent_id", "origin_device_id", "desktop_owned",
              "authority_device_id", "owner_device_id"]),
    ("run_visible_notes", ["user_id", "governing_plane", "authority_kind", "authority_device_id", "authority_agent_id",
                           "desktop_owned", "folder_title_snapshot", "origin_device_id",
                           "message_id", "note_title_snapshot", "folder_id_snapshot", "created_at"]),
    ("run_activities", ["user_id", "governing_plane", "authority_kind", "authority_device_id", "authority_agent_id",
                        "desktop_owned", "origin_device_id"]),
    ("harness_sessions", ["governing_plane", "authority_kind", "authority_device_id", "authority_agent_id"]),
    // One row per run activity now that OpenClaw traces are gone.
    ("activity_summaries", ["source_kind", "source_id", "activity_id"]),
    // An accepted analytics event is kept only to deduplicate its ID.
    ("product_analytics_events", ["payload", "status"]),
    ("calendar_items", ["user_id", "agent_codename", "pinned_folder_id", "delivery_folder_id", "schedule_label",
                        "origin_device_id"]),
    // A whole transcript in one shared row; its rows hold it now.
    ("execution_conversations", ["transcript"]),
    // Bytes in shared rows; the chunk store holds them, named by `sha256`.
    ("artifact_chunks", ["bytes"]), ("execution_native_history_parts", ["bytes"]),
  ]

  /// Columns added, by their table's current name, with their declarations
  /// (`coreTablesSQL` and `createFederationSchemaUnlocked` declare them for
  /// a new library). They hold what an execution owner's transcript said,
  /// which v0.4.2 kept only in `execution_conversations.transcript`.
  static let addedLibraryColumns: [(table: String, columns: [(name: String, declaration: String)])] = [
    ("messages", [("sequence", "INTEGER"), ("position", "INTEGER"), ("attachment_references", "TEXT")]),
    ("runs", [("position", "INTEGER")]),
    ("run_activities", [("position", "INTEGER"), ("sequence", "INTEGER"), ("title", "TEXT"), ("detail", "TEXT"),
                        ("status", "TEXT"), ("details_record_id", "TEXT"), ("is_transient", "INTEGER"), ("completed_at", "TEXT")]),
    ("execution_conversations", [("active_run_id", "TEXT")]),
  ]

  /// JSON documents stored as BLOB, by their table's current name. They are
  /// TEXT now, so SQLite's JSON functions read them without a cast. Hashes
  /// stay BLOB; `execution_conversations.transcript` and the chunk and part
  /// bytes are dropped instead.
  static let jsonTextColumns: [(table: String, columns: [String])] = [
    ("execution_workspaces", ["payload"]), ("execution_journal", ["payload"]),
    ("execution_conversations", ["conversation"]), ("execution_adoptions", ["payload"]),
    ("execution_receipts", ["payload"]), ("saved_artifacts", ["manifest"]),
    ("artifact_uploads", ["manifest"]), ("product_analytics_preference", ["payload"]),
    ("device_mutation_receipts", ["response"]), ("device_command_receipts", ["response"]),
    ("device_tool_receipts", ["response"]),
  ]

  /// Paired-sync bookkeeping that names a table (`table_name`) or holds a
  /// record payload (`$.table`, `$.key`, `$.row`).
  private static let peerNamedBookkeeping = ["paired_library_rows", "paired_library_frontier",
                                             "paired_library_seeded", "paired_library_reassert"]
  private static let peerPayloadBookkeeping = ["paired_library_rows", "paired_library_frontier", "paired_library_changes",
                                               "paired_library_pending", "paired_library_quarantine", "paired_library_conflicts"]

  func upgradeLibrarySchemaUnlocked() throws {
    var tables = Set(try historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='table'", values: [])
      .compactMap { $0.objectValue?["name"]?.stringValue })
    func columns(_ table: String) throws -> Set<String> {
      Set(try historyRowsUnlocked("SELECT name FROM pragma_table_info(?)", values: [table])
        .compactMap { $0.objectValue?["name"]?.stringValue })
    }
    // A file without a library (new, or holding only the usage index) is
    // created and stamped by the regular schema creation instead.
    guard tables.contains("conversations") || tables.contains("dashboard_conversations") else { return }

    // Foreign keys stay off while tables are renamed and dropped (a dropped
    // parent must not cascade into its children); renaming still rewrites
    // every reference to the new name.
    try executeUnlocked("PRAGMA foreign_keys=OFF; PRAGMA legacy_alter_table=OFF")
    try transaction {
      let bookkeeping = tables.intersection(Self.peerPayloadBookkeeping + Self.peerNamedBookkeeping)
      for trigger in try historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='trigger'", values: [])
        .compactMap({ $0.objectValue?["name"]?.stringValue }) {
        try executeUnlocked("DROP TRIGGER IF EXISTS \(Self.peerQuote(trigger))")
      }
      for index in Self.droppedLibraryIndexes { try executeUnlocked("DROP INDEX IF EXISTS \(Self.peerQuote(index))") }

      var moved: [String: String] = [:]
      for (old, new) in Self.renamedLibraryTables where tables.contains(old) {
        // A table under its new name only exists if a partial conversion or
        // a fresh creation already made it; it then holds the current state.
        if tables.contains(new) {
          try executeUnlocked("DROP TABLE \(Self.peerQuote(old))")
          try dropPeerRecordsUnlocked(old, bookkeeping: bookkeeping)
        } else {
          try executeUnlocked("ALTER TABLE \(Self.peerQuote(old)) RENAME TO \(Self.peerQuote(new))")
          for index in try historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=? AND sql IS NOT NULL",
                                               values: [new]).compactMap({ $0.objectValue?["name"]?.stringValue }) {
            try executeUnlocked("DROP INDEX \(Self.peerQuote(index))")
          }
          moved[old] = new
        }
        tables.remove(old); tables.insert(new)
      }
      // One pass over each bookkeeping table renames every moved table.
      if !moved.isEmpty {
        let map = String(decoding: try JSONEncoder().encode(moved), as: UTF8.self)
        for table in Self.peerNamedBookkeeping where bookkeeping.contains(table) {
          try toolsExecuteUnlocked("""
            UPDATE \(table) SET table_name=(SELECT value FROM json_each(?1) WHERE key=table_name)
            WHERE table_name IN (SELECT key FROM json_each(?1))
            """, [map])
        }
        for table in Self.peerPayloadBookkeeping where bookkeeping.contains(table) {
          try toolsExecuteUnlocked("""
            UPDATE \(table) SET payload=json_set(payload,'$.table',(SELECT value FROM json_each(?1) WHERE key=json_extract(payload,'$.table')))
            WHERE json_valid(payload) AND json_extract(payload,'$.table') IN (SELECT key FROM json_each(?1))
            """, [map])
        }
      }

      // v0.4.2 listed only the rows of its operator: the most common user ID
      // among live rows and dashboard profiles.
      var users: [String] = []
      for (table, live) in [("conversations", "deleted_at IS NULL"), ("agents", "deleted_at IS NULL"),
                            ("notes", "deleted_at IS NULL"), ("folders", "1"), ("calendar_items", "1")]
      where tables.contains(table) {
        if try columns(table).contains("user_id") { users.append("SELECT user_id FROM \(table) WHERE \(live)") }
      }
      if tables.contains("profiles") { users.append("SELECT id AS user_id FROM profiles") }
      let operatorID = users.isEmpty ? nil : try historyRowsUnlocked(
        "SELECT user_id FROM (\(users.joined(separator: " UNION ALL "))) GROUP BY user_id ORDER BY COUNT(*) DESC, user_id LIMIT 1",
        values: []).first?.objectValue?["user_id"]?.stringValue

      // An imported OpenClaw chat keeps its import time; Woven's own gateway
      // runs never had one.
      if tables.contains("desktop_openclaw_import_activity"), tables.contains("session_imports") {
        let native = try columns("conversations").contains("openclaw_session_key")
          ? "WHERE instr(COALESCE(c.openclaw_session_key,''),':wovenmatter:')=0" : ""
        try executeUnlocked("""
          INSERT OR IGNORE INTO session_imports(conversation_id, imported_at)
          SELECT a.conversation_id, a.imported_at FROM desktop_openclaw_import_activity a
          JOIN conversations c ON c.id=a.conversation_id \(native)
          """)
      }
      if tables.contains("activity_summaries"), try columns("activity_summaries").contains("source_kind") {
        try executeUnlocked("DELETE FROM activity_summaries WHERE source_kind='trace'")
      }
      for table in Self.droppedLibraryTables where tables.contains(table) {
        try executeUnlocked("DROP TABLE \(Self.peerQuote(table))")
        try dropPeerRecordsUnlocked(table, bookkeeping: bookkeeping)
        tables.remove(table)
      }

      try settleLegacyRowsUnlocked(tables: tables, columns: columns, operatorID: operatorID, bookkeeping: bookkeeping)
      // Markers of the one-time peer-sync upgrades v0.4.2 libraries already ran.
      if tables.contains("paired_library_state") {
        try executeUnlocked("""
          DELETE FROM paired_library_state WHERE name IN ('owners.bootstrap','frontier.v1','projection.v2','frontier.v2')
          """)
      }

      for (table, old, new) in Self.renamedLibraryColumns where tables.contains(table) {
        let present = try columns(table)
        guard present.contains(old) else { continue }
        if present.contains(new) {
          try executeUnlocked("ALTER TABLE \(Self.peerQuote(table)) DROP COLUMN \(Self.peerQuote(old))")
        } else {
          try executeUnlocked("ALTER TABLE \(Self.peerQuote(table)) RENAME COLUMN \(Self.peerQuote(old)) TO \(Self.peerQuote(new))")
        }
        for name in Self.peerPayloadBookkeeping where bookkeeping.contains(name) {
          try toolsExecuteUnlocked("""
            UPDATE \(name) SET payload=json_set(json_remove(payload,'$.row.\(old)'),'$.row.\(new)',json(json_extract(payload,'$.row.\(old)')))
            WHERE json_valid(payload) AND json_extract(payload,'$.table')=? AND json_type(payload,'$.row.\(old)') IS NOT NULL
            """, [table])
        }
      }
      try addTranscriptColumnsUnlocked(tables: tables, columns: columns, bookkeeping: bookkeeping)
      try moveChunkBytesToFilesUnlocked(tables: tables, columns: columns, bookkeeping: bookkeeping)
      for (table, dropped) in Self.droppedLibraryColumns where tables.contains(table) {
        let present = try columns(table), gone = dropped.filter(present.contains)
        guard !gone.isEmpty else { continue }
        for column in gone { try executeUnlocked("ALTER TABLE \(Self.peerQuote(table)) DROP COLUMN \(Self.peerQuote(column))") }
        // One pass over each bookkeeping table removes all of a table's dropped columns.
        let paths = gone.map { "'$.row.\($0)'" }.joined(separator: ",")
        for name in Self.peerPayloadBookkeeping where bookkeeping.contains(name) {
          let match = Self.peerNamedBookkeeping.contains(name) ? "table_name=?" : "json_valid(payload) AND json_extract(payload,'$.table')=?"
          try toolsExecuteUnlocked("UPDATE \(name) SET payload=json_remove(payload,\(paths)) WHERE \(match)", [table])
        }
      }
      try storeJSONAsTextUnlocked(tables: tables, bookkeeping: bookkeeping)
      // The chunk columns were added nullable; their declaration says NOT NULL.
      for table in Self.peerChunkTables.sorted() where tables.contains(table) {
        if try historyRowsUnlocked("SELECT 1 AS present FROM pragma_table_info(?) WHERE name='sha256' AND \"notnull\"=0", values: [table]).isEmpty == false {
          try rebuildCoreTableUnlocked(table, from: Self.federationTablesSQL)
        }
      }
      // v0.4.2 declared `runtime_kind DEFAULT 'openclaw'`; a column default
      // only changes by rebuilding the table, which keeps every row and rowid.
      if tables.contains("agents"), try historyRowsUnlocked(
        "SELECT 1 AS present FROM sqlite_master WHERE name='agents' AND instr(sql,'''openclaw''')>0", values: []).isEmpty == false {
        try rebuildCoreTableUnlocked("agents")
      }
      try executeUnlocked("PRAGMA user_version=\(Self.librarySchemaVersion)")
    }
    try executeUnlocked("PRAGMA foreign_keys=ON")
  }

  /// Adds the transcript columns, fills them from each transcript an
  /// execution owner's projection kept as one document, and records the
  /// values in every recorded version of those rows. Each member that
  /// updates derives the same values from the same shared document, so
  /// nothing is sent to peers as a new version.
  private func addTranscriptColumnsUnlocked(tables: Set<String>, columns: (String) throws -> Set<String>,
                                            bookkeeping: Set<String>) throws {
    var added: [String: [String]] = [:]
    for (table, wanted) in Self.addedLibraryColumns where tables.contains(table) {
      let present = try columns(table)
      for column in wanted where !present.contains(column.name) {
        try executeUnlocked("ALTER TABLE \(Self.peerQuote(table)) ADD COLUMN \(Self.peerQuote(column.name)) \(column.declaration)")
        added[table, default: []].append(column.name)
      }
    }
    var changed: [String: Set<String>] = [:]
    if tables.contains("execution_conversations"), try columns("execution_conversations").contains("transcript") {
      changed = try moveTranscriptsToRowsUnlocked(bookkeeping: bookkeeping)
    }
    for (table, names) in added { try refreshPeerColumnsUnlocked(table, names, ids: nil, bookkeeping: bookkeeping) }
    // Existing columns the move rewrote, in the rows it touched.
    for (table, names) in [("messages", ["status", "created_at"]), ("run_activities", ["content", "created_at"]),
                           ("runs", ["user_message_id", "assistant_message_id"])] {
      guard let ids = changed[table], !ids.isEmpty else { continue }
      try refreshPeerColumnsUnlocked(table, names, ids: ids.sorted(), bookkeeping: bookkeeping)
    }
  }

  /// Writes what each Linux or iPhone transcript held into its rows: every
  /// message's, activity's and run's position, the message and activity
  /// fields only the transcript had, its active run, and any row it held
  /// that the tables lack. A legacy tool message it retired is deleted. A
  /// paired Mac's projection was a copy of that Mac's rows and is skipped.
  /// Returns the IDs of existing rows whose existing columns changed, by table.
  private func moveTranscriptsToRowsUnlocked(bookkeeping: Set<String>) throws -> [String: Set<String>] {
    var documents: [(id: String, transcript: LibraryTranscript)] = []
    let read = try prepareUnlocked("""
      SELECT c.id,c.transcript FROM execution_conversations c LEFT JOIN execution_workspaces w ON w.id=c.workspace_id
      WHERE c.transcript IS NOT NULL AND json_extract(CAST(w.payload AS TEXT),'$.kind') IS NOT 'mac'
      """)
    defer { sqlite3_finalize(read) }
    while true {
      let code = sqlite3_step(read)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      // An unreadable document has nothing to move; its rows stay as they are.
      guard let transcript = try? JSONDecoder().decode(LibraryTranscript.self, from: blob(read, column: 1)) else { continue }
      documents.append((try text(read, column: 0), transcript))
    }
    var changed: [String: Set<String>] = [:], deleted: [String] = []
    let now = Self.timestamp(Date())
    func owner(_ table: String, _ id: String) throws -> String? {
      try libraryIDsUnlocked("SELECT conversation_id FROM \(table) WHERE id=?", bindings: [id]).first
    }
    for (conversationID, transcript) in documents {
      try toolsExecuteUnlocked("UPDATE execution_conversations SET active_run_id=? WHERE id=?", [transcript.activeRunID, conversationID])
      for (index, message) in transcript.messages.enumerated() {
        let values: [String?] = [message.sequence.map(String.init), String(index + 1), try message.attachments.map { try toolsJSON($0) },
                                 message.status ?? "", message.createdAt, message.id]
        switch try owner("messages", message.id) {
        case conversationID?:
          try toolsExecuteUnlocked("UPDATE messages SET sequence=?,position=?,attachment_references=?,status=?,created_at=? WHERE id=?", values)
          changed["messages", default: []].insert(message.id)
        case nil:
          try toolsExecuteUnlocked("""
            INSERT INTO messages(sequence,position,attachment_references,status,created_at,id,conversation_id,run_id,role,content,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, values + [conversationID, message.runID, message.role, message.content, now])
        default: continue
        }
      }
      for id in transcript.removedMessageIDs ?? [] {
        guard try federationScalarUnlocked("SELECT COUNT(*) FROM messages WHERE id=? AND conversation_id=? AND role<>'user'",
                                           bindings: [id, conversationID]) != 0 else { continue }
        try toolsExecuteUnlocked("DELETE FROM messages WHERE id=?", [id])
        deleted.append(id)
      }
      for (index, activity) in transcript.activities.enumerated() {
        let present = try owner("run_activities", activity.id)
        guard present == nil || present == conversationID else { continue }
        // An activity read from this Mac's rows into the transcript (a chat
        // that moved to its owner) carries only its title, detail and status,
        // which its row already gives.
        let legacy = activity.projectionJSON == nil && activity.detailsRecordID == nil && activity.isTransient == nil
          && activity.sequence == nil && activity.createdAt == nil && activity.completedAt == nil
        if legacy, present != nil {
          try toolsExecuteUnlocked("UPDATE run_activities SET position=? WHERE id=?", [String(index + 1), activity.id])
          continue
        }
        let content = try activity.projectionJSON.flatMap { json in
          (try? JSONDecoder().decode(AgentRunActivity.self, from: Data(json.utf8))).map { _ in json }
        } ?? toolsJSON(AgentRunActivity(id: activity.id, kind: .activity, title: activity.title, detail: activity.detail, status: activity.status))
        let values: [String?] = [String(index + 1), activity.title, activity.detail, activity.status, activity.detailsRecordID,
                                 activity.isTransient.map { $0 ? "1" : "0" }, activity.sequence.map(String.init), activity.completedAt,
                                 activity.createdAt ?? "", content, activity.id]
        if present == nil {
          try toolsExecuteUnlocked("""
            INSERT INTO run_activities(position,title,detail,status,details_record_id,is_transient,sequence,completed_at,created_at,content,id,
              run_id,conversation_id,event_type) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,'activity')
            """, values + [activity.runID, conversationID])
        } else {
          try toolsExecuteUnlocked("""
            UPDATE run_activities SET position=?,title=?,detail=?,status=?,details_record_id=?,is_transient=?,sequence=?,completed_at=?,
              created_at=?,content=? WHERE id=?
            """, values)
          changed["run_activities", default: []].insert(activity.id)
        }
      }
      for (index, run) in (transcript.runs ?? []).enumerated() {
        let values: [String?] = [String(index + 1), run.userMessageID, run.assistantMessageID, run.id]
        switch try owner("runs", run.id) {
        case conversationID?:
          try toolsExecuteUnlocked("""
            UPDATE runs SET position=?,user_message_id=COALESCE(?,user_message_id),assistant_message_id=COALESCE(?,assistant_message_id) WHERE id=?
            """, values)
          changed["runs", default: []].insert(run.id)
        case nil:
          try toolsExecuteUnlocked("""
            INSERT INTO runs(position,user_message_id,assistant_message_id,id,conversation_id,status,started_at,completed_at,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, values + [conversationID, run.status, run.startedAt, run.completedAt, run.startedAt ?? now, now])
        default: continue
        }
      }
    }
    // A deleted message's recorded versions become its deletion, which
    // every member records alike.
    if !deleted.isEmpty {
      let ids = String(decoding: try JSONEncoder().encode(deleted), as: UTF8.self)
      for name in ["paired_library_rows", "paired_library_frontier"] where bookkeeping.contains(name) {
        try toolsExecuteUnlocked("""
          UPDATE \(name) SET payload=json_set(payload,'$.deleted',json('true'))
          WHERE table_name='messages' AND record_key IN (SELECT json_array(value) FROM json_each(?))
          """, [ids])
      }
    }
    return changed
  }

  /// Writes each saved artifact chunk's and native history part's bytes to
  /// the chunk store and names them in the row by `sha256` and `byte_count`;
  /// the dropped-columns pass then removes `bytes`. Every recorded version
  /// gets the same two values, computed from the bytes it holds itself (or
  /// the peer record file of their hex it references), so members that
  /// update record identical versions and nothing is sent as a new one. A
  /// version whose referenced file is not here yet keeps no bytes and is
  /// quarantined when it is applied.
  private func moveChunkBytesToFilesUnlocked(tables: Set<String>, columns: (String) throws -> Set<String>,
                                             bookkeeping: Set<String>) throws {
    let moving = try Self.peerChunkTables.sorted().filter { try tables.contains($0) && columns($0).contains("bytes") }
    guard !moving.isEmpty else { return }
    for table in moving {
      let present = try columns(table)
      for (name, declaration) in [("sha256", "TEXT"), ("byte_count", "INTEGER")] where !present.contains(name) {
        try executeUnlocked("ALTER TABLE \(table) ADD COLUMN \(name) \(declaration)")
      }
      var named: [(rowid: Int64, hash: String, count: Int64)] = []
      let read = try prepareUnlocked("SELECT rowid,bytes FROM \(table)")
      defer { sqlite3_finalize(read) }
      while true {
        let code = sqlite3_step(read)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else { throw stepError() }
        let bytes = try blob(read, column: 1)
        named.append((sqlite3_column_int64(read, 0), try libraryFiles.retainChunk(bytes), Int64(bytes.count)))
      }
      let update = try prepareUnlocked("UPDATE \(table) SET sha256=?,byte_count=? WHERE rowid=?")
      defer { sqlite3_finalize(update) }
      for row in named {
        sqlite3_reset(update)
        try bind(row.hash, at: 1, to: update); sqlite3_bind_int64(update, 2, row.count); sqlite3_bind_int64(update, 3, row.rowid)
        try stepDone(update)
      }
    }
    let list = String(decoding: try JSONEncoder().encode(moving), as: UTF8.self)
    let records = libraryFiles.supportDirectory.appending(path: "paired-records")
    for name in Self.peerPayloadBookkeeping where bookkeeping.contains(name) {
      let named = Self.peerNamedBookkeeping.contains(name)
      let table = named ? "table_name" : "json_extract(payload,'$.table')"
      let rowids = try historyRowsUnlocked("""
        SELECT rowid AS id FROM \(name) WHERE \(named ? "" : "json_valid(payload) AND ")\(table) IN (SELECT value FROM json_each(?))
          AND json_type(payload,'$.row.bytes') IS NOT NULL ORDER BY rowid
        """, values: [list]).compactMap { $0.objectValue?["id"]?.intValue }
      for rowid in rowids {
        guard let payload = try historyRowsUnlocked("SELECT payload FROM \(name) WHERE rowid=?", values: [String(rowid)]).first?.objectValue?["payload"]?.stringValue,
              let record = try? JSONDecoder().decode(PairedLibraryRecord.self, from: Data(payload.utf8)),
              let value = record.row["bytes"], let stored = value.value else { continue }
        let hex: String?
        switch value.type {
        case "blob": hex = stored
        case "reference:blob":
          hex = stored.wholeMatch(of: /[0-9a-f]{64}/) == nil ? nil : try? String(contentsOf: records.appending(path: stored), encoding: .utf8)
        default: hex = nil
        }
        guard let hex, let bytes = Self.bytesFromHex(hex) else { continue }
        let data = Data(bytes)
        try toolsExecuteUnlocked("""
          UPDATE \(name) SET payload=json_set(payload,'$.row.sha256',json_object('type','text','value',?),
            '$.row.byte_count',json_object('type','integer','value',?)) WHERE rowid=?
          """, [try libraryFiles.retainChunk(data), String(data.count), String(rowid)])
      }
    }
  }

  /// Records the current value of `columns` (null for a row that is gone)
  /// in every recorded version of the table's rows, or of the rows `ids`
  /// names. The table is keyed by `id`.
  private func refreshPeerColumnsUnlocked(_ table: String, _ columns: [String], ids: [String]?, bookkeeping: Set<String>) throws {
    for name in Self.peerPayloadBookkeeping where bookkeeping.contains(name) {
      let named = Self.peerNamedBookkeeping.contains(name)
      let key = named ? "\(name).record_key" : "json_extract(\(name).payload,'$.key')"
      let values = columns.map { column in
        let live = "(SELECT json_object('type',typeof(s.\(column)),'value',CAST(s.\(column) AS TEXT)) FROM \(Self.peerQuote(table)) s WHERE s.id=json_extract(\(key),'$[0]'))"
        return "'$.row.\(column)',json(COALESCE(\(live),json_object('type','null','value',NULL)))"
      }.joined(separator: ",")
      var filter = named ? "table_name=?1" : "json_valid(payload) AND json_extract(payload,'$.table')=?1"
      var bindings: [String?] = [table]
      if let ids {
        filter += " AND json_extract(\(key),'$[0]') IN (SELECT value FROM json_each(?2))"
        bindings.append(String(decoding: try JSONEncoder().encode(ids), as: UTF8.self))
      }
      try toolsExecuteUnlocked("UPDATE \(name) SET payload=json_set(payload,\(values)) WHERE \(filter)", bindings)
    }
  }

  /// Recreates a table from its current declaration in `sql` and copies its
  /// rows, rowids included. Nothing references these tables by foreign key.
  private func rebuildCoreTableUnlocked(_ table: String, from sql: String = coreTablesSQL) throws {
    guard let start = sql.range(of: "CREATE TABLE IF NOT EXISTS \(table) ("),
          let end = sql.range(of: ");", range: start.upperBound..<sql.endIndex) else {
      throw WorkspaceDatabaseError.execute("No current declaration for \(table)")
    }
    let rebuilt = table + "_rebuilt"
    let declaration = "CREATE TABLE \(rebuilt) (" + sql[start.upperBound..<end.upperBound]
    try executeUnlocked("DROP TABLE IF EXISTS \(rebuilt);\n" + declaration)
    let present = Set(try historyRowsUnlocked("SELECT name FROM pragma_table_info(?)", values: [table])
      .compactMap { $0.objectValue?["name"]?.stringValue })
    let columns = try historyRowsUnlocked("SELECT name FROM pragma_table_info(?)", values: [rebuilt])
      .compactMap { $0.objectValue?["name"]?.stringValue }.filter(present.contains).map(Self.peerQuote).joined(separator: ",")
    try executeUnlocked("""
      INSERT INTO \(rebuilt)(rowid,\(columns)) SELECT rowid,\(columns) FROM \(table);
      DROP TABLE \(table);
      ALTER TABLE \(rebuilt) RENAME TO \(table);
      """)
  }

  /// Rebuilds each table whose JSON columns are declared BLOB from its own
  /// declaration with those columns as TEXT, keeping every row, rowid and
  /// AUTOINCREMENT sequence; the regular schema creation that follows
  /// recreates its indexes and triggers. Peer bookkeeping then records the
  /// text, so the change is not sent to peers as a new version: each member
  /// that updates converts the same values the same way. Hex is decoded here
  /// rather than with SQL `unhex()`, which a Linux host's SQLite may lack.
  private func storeJSONAsTextUnlocked(tables: Set<String>, bookkeeping: Set<String>) throws {
    for (table, json) in Self.jsonTextColumns where tables.contains(table) {
      let info = try historyRowsUnlocked("SELECT name,type FROM pragma_table_info(?)", values: [table]).compactMap(\.objectValue)
      let blobs = info.filter { $0["type"]?.stringValue?.uppercased() == "BLOB" }.compactMap { $0["name"]?.stringValue }.filter(json.contains)
      guard !blobs.isEmpty,
            let sql = try historyRowsUnlocked("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", values: [table])
              .first?.objectValue?["sql"]?.stringValue, let open = sql.firstIndex(of: "(") else { continue }
      let rebuilt = table + "_text"
      var declaration = "CREATE TABLE " + Self.peerQuote(rebuilt) + sql[open...]
      for column in blobs {
        let pattern = #"([(,]\s*"?"# + NSRegularExpression.escapedPattern(for: column) + #""?\s+)BLOB\b"#
        declaration = declaration.replacingOccurrences(of: pattern, with: "$1TEXT", options: [.regularExpression, .caseInsensitive])
      }
      try executeUnlocked("DROP TABLE IF EXISTS \(Self.peerQuote(rebuilt));\n" + declaration)
      guard try historyRowsUnlocked("SELECT 1 AS blob FROM pragma_table_info(?) WHERE upper(type)='BLOB' AND name IN (SELECT value FROM json_each(?))",
                                    values: [rebuilt, String(decoding: try JSONEncoder().encode(blobs), as: UTF8.self)]).isEmpty else {
        throw WorkspaceDatabaseError.execute("Could not store \(table) JSON as text")
      }
      let names = info.compactMap { $0["name"]?.stringValue }
      let values = names.map { blobs.contains($0) ? "CAST(\(Self.peerQuote($0)) AS TEXT)" : Self.peerQuote($0) }
      let sequence = tables.contains("sqlite_sequence")
        ? try historyRowsUnlocked("SELECT seq FROM sqlite_sequence WHERE name=?", values: [table]).first?.objectValue?["seq"]?.intValue : nil
      try executeUnlocked("""
        INSERT INTO \(Self.peerQuote(rebuilt))(rowid,\(names.map(Self.peerQuote).joined(separator: ","))) SELECT rowid,\(values.joined(separator: ",")) FROM \(Self.peerQuote(table));
        DROP TABLE \(Self.peerQuote(table));
        ALTER TABLE \(Self.peerQuote(rebuilt)) RENAME TO \(Self.peerQuote(table));
        """)
      if let sequence {
        try toolsExecuteUnlocked("DELETE FROM sqlite_sequence WHERE name=? AND seq<?", [table, String(sequence)])
        try toolsExecuteUnlocked("INSERT INTO sqlite_sequence(name,seq) SELECT ?,? WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name=?)",
                                 [table, String(sequence), table])
      }
    }

    // Recorded versions of shared rows hold a blob as hex, or as a reference
    // to a peer file of that hex when it was too large to travel inline.
    let shared = Self.jsonTextColumns.filter { PairedLibraryTables.names.contains($0.table) }
    guard !shared.isEmpty else { return }
    let columns = Dictionary(uniqueKeysWithValues: shared.map { ($0.table, $0.columns) })
    let list = String(decoding: try JSONEncoder().encode(shared.map(\.table)), as: UTF8.self)
    let files = libraryFiles.supportDirectory.appending(path: "paired-records")
    for name in Self.peerPayloadBookkeeping where bookkeeping.contains(name) {
      let named = Self.peerNamedBookkeeping.contains(name)
      let table = named ? "table_name" : "json_extract(payload,'$.table')"
      let blob = shared.flatMap { entry in entry.columns.map { "json_extract(payload,'$.row.\($0).type') IN ('blob','reference:blob')" } }
      let rowids = try historyRowsUnlocked("""
        SELECT rowid AS id FROM \(name) WHERE \(named ? "" : "json_valid(payload) AND ")\(table) IN (SELECT value FROM json_each(?))
          AND (\(Set(blob).sorted().joined(separator: " OR ")))
        """, values: [list]).compactMap { $0.objectValue?["id"]?.intValue }
      for rowid in rowids {
        guard let payload = try historyRowsUnlocked("SELECT payload FROM \(name) WHERE rowid=?", values: [String(rowid)]).first?.objectValue?["payload"]?.stringValue,
              let record = try? JSONDecoder().decode(PairedLibraryRecord.self, from: Data(payload.utf8)) else { continue }
        for column in columns[record.table] ?? [] {
          guard let value = record.row[column], let stored = value.value else { continue }
          let text: PairedLibraryValue
          switch value.type {
          case "blob":
            guard let decoded = Self.utf8FromHex(stored) else { continue }
            text = .init(type: "text", value: decoded)
          case "reference:blob":
            let source = files.appending(path: stored)
            guard stored.wholeMatch(of: /[0-9a-f]{64}/) != nil, let hex = try? String(contentsOf: source, encoding: .utf8),
                  let decoded = Self.utf8FromHex(hex) else { continue }
            let bytes = Data(decoded.utf8), hash = SHA256.hash(data: bytes).hexString, file = files.appending(path: hash)
            if !FileManager.default.fileExists(atPath: file.path) {
              try bytes.write(to: file, options: .atomic)
              try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            }
            text = .init(type: "reference:text", value: hash)
          default: continue
          }
          try toolsExecuteUnlocked("UPDATE \(name) SET payload=json_set(payload,'$.row.\(column)',json_object('type',?,'value',?)) WHERE rowid=?",
                                   [text.type, text.value, String(rowid)])
        }
      }
    }
  }

  /// The UTF-8 text a hex string of bytes spells, or nil.
  static func utf8FromHex(_ hex: String) -> String? {
    bytesFromHex(hex).flatMap { String(bytes: $0, encoding: .utf8) }
  }

  /// The bytes a hex string spells, or nil.
  static func bytesFromHex(_ hex: String) -> [UInt8]? {
    let digits = Array(hex.utf8)
    guard digits.count.isMultiple(of: 2) else { return nil }
    var bytes = [UInt8](); bytes.reserveCapacity(digits.count / 2)
    func nibble(_ digit: UInt8) -> UInt8? {
      switch digit {
      case 48...57: digit - 48
      case 65...70: digit - 55
      case 97...102: digit - 87
      default: nil
      }
    }
    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
      bytes.append(high << 4 | low)
    }
    return bytes
  }

  /// Rows the old columns hid or kept read-only stay that way once the
  /// columns are gone. In v0.4.2 a conversation was listed only when it was
  /// `wovenmatter_macos`, and it was writable only when `desktop_owned`;
  /// rows from the OpenClaw dashboard had another plane, another user or
  /// `desktop_owned=0`. A hidden one is archived and never retained; a listed
  /// dashboard chat becomes retained read-only history, as every other chat
  /// without a session already is. An agent is listed by
  /// `execution_location`, which takes its plane's value, and a hidden one is
  /// marked deleted. Surface profiles of the web dashboard are removed.
  private func settleLegacyRowsUnlocked(tables: Set<String>, columns: (String) throws -> Set<String>,
                                        operatorID: String?, bookkeeping: Set<String>) throws {
    let conversation = tables.contains("conversations") ? try columns("conversations") : []
    let agent = tables.contains("agents") ? try columns("agents") : []
    func foreign(_ present: Set<String>) -> String? {
      guard let operatorID, present.isSuperset(of: ["user_id", "desktop_owned"]) else { return nil }
      return "(desktop_owned=0 AND user_id<>'\(operatorID.replacingOccurrences(of: "'", with: "''"))')"
    }

    if !conversation.isEmpty {
      var hidden = [foreign(conversation)].compactMap { $0 }
      if conversation.contains("governing_plane") { hidden.append("governing_plane<>'wovenmatter_macos'") }
      let hiddenPredicate = hidden.isEmpty ? "0" : hidden.joined(separator: " OR ")
      let dashboardRow = conversation.contains("desktop_owned") ? "desktop_owned=0" : "0"
      let retained = tables.contains("retained_execution_history")
      if retained {
        try executeUnlocked("""
          DELETE FROM retained_execution_history WHERE conversation_id IN (
            SELECT id FROM conversations WHERE (\(hiddenPredicate)) OR (\(dashboardRow) AND is_archived=1))
          """)
      }
      let archived = try historyRowsUnlocked("""
        SELECT id FROM conversations WHERE is_archived=0 AND ((\(hiddenPredicate)) OR \(dashboardRow))
        """, values: []).compactMap { $0.objectValue?["id"]?.stringValue }
      if retained {
        try executeUnlocked("""
          INSERT OR IGNORE INTO retained_execution_history(conversation_id)
          SELECT id FROM conversations WHERE is_archived=0 AND \(dashboardRow) AND NOT (\(hiddenPredicate))
          """)
      }
      try executeUnlocked("UPDATE conversations SET is_archived=1 WHERE is_archived=0 AND ((\(hiddenPredicate)) OR \(dashboardRow))")
      try refreshPeerFieldUnlocked("conversations", "is_archived", ids: archived, bookkeeping: bookkeeping)
    }

    if agent.contains("governing_plane") {
      var hidden = ["governing_plane NOT IN ('wovenmatter_macos','remote_workspace')"]
      if let foreign = foreign(agent) { hidden.append(foreign) }
      let predicate = "deleted_at IS NULL AND (" + hidden.joined(separator: " OR ") + ")"
      let retired = try historyRowsUnlocked("SELECT id FROM agents WHERE \(predicate)", values: [])
        .compactMap { $0.objectValue?["id"]?.stringValue }
      try executeUnlocked("UPDATE agents SET deleted_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE \(predicate)")
      try refreshPeerFieldUnlocked("agents", "deleted_at", ids: retired, bookkeeping: bookkeeping)
      let location = "CASE governing_plane WHEN 'remote_workspace' THEN 'remote' ELSE 'local' END"
      let moved = try historyRowsUnlocked("SELECT id FROM agents WHERE execution_location IS NOT \(location)", values: [])
        .compactMap { $0.objectValue?["id"]?.stringValue }
      try executeUnlocked("UPDATE agents SET execution_location=\(location) WHERE execution_location IS NOT \(location)")
      try refreshPeerFieldUnlocked("agents", "execution_location", ids: moved, bookkeeping: bookkeeping)
    }

    if tables.contains("surface_profiles"), try columns("surface_profiles").contains("surface") {
      try executeUnlocked("DELETE FROM surface_profiles WHERE surface<>'mac_native'")
      for table in ["paired_library_rows", "paired_library_frontier"] where bookkeeping.contains(table) {
        try executeUnlocked("""
          DELETE FROM \(table) WHERE table_name='surface_profiles'
            AND json_extract(payload,'$.row.surface.value') IS NOT 'mac_native'
          """)
      }
    }
  }

  /// A dropped table's records leave every peer's bookkeeping.
  private func dropPeerRecordsUnlocked(_ table: String, bookkeeping: Set<String>) throws {
    for name in Self.peerNamedBookkeeping where bookkeeping.contains(name) {
      try toolsExecuteUnlocked("DELETE FROM \(name) WHERE table_name=?", [table])
    }
    for name in Self.peerPayloadBookkeeping where bookkeeping.contains(name) && !Self.peerNamedBookkeeping.contains(name) {
      try toolsExecuteUnlocked("DELETE FROM \(name) WHERE json_valid(payload) AND json_extract(payload,'$.table')=?", [table])
    }
  }

  /// Records the value a settled row now has in every recorded version of
  /// it, so the change is not sent to peers as a new version: each Mac that
  /// updates settles the same rows the same way.
  private func refreshPeerFieldUnlocked(_ table: String, _ column: String, ids: [String], bookkeeping: Set<String>) throws {
    guard !ids.isEmpty else { return }
    let list = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
    func value(_ key: String) -> String {
      "json((SELECT json_object('type',typeof(s.\(column)),'value',CAST(s.\(column) AS TEXT)) FROM \(table) s WHERE json_array(s.id)=\(key)))"
    }
    for name in ["paired_library_rows", "paired_library_frontier"] where bookkeeping.contains(name) {
      try toolsExecuteUnlocked("""
        UPDATE \(name) SET payload=json_set(payload,'$.row.\(column)',\(value("\(name).record_key")))
        WHERE table_name=? AND record_key IN (SELECT json_array(value) FROM json_each(?))
        """, [table, list])
    }
    for name in ["paired_library_changes", "paired_library_pending", "paired_library_quarantine", "paired_library_conflicts"]
    where bookkeeping.contains(name) {
      try toolsExecuteUnlocked("""
        UPDATE \(name) SET payload=json_set(payload,'$.row.\(column)',\(value("json_extract(\(name).payload,'$.key')")))
        WHERE json_valid(payload) AND json_extract(payload,'$.table')=?
          AND json_extract(payload,'$.key') IN (SELECT json_array(value) FROM json_each(?))
        """, [table, list])
    }
  }
}

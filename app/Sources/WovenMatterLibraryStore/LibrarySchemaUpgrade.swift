#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Converts a library written by v0.4.2 to the current schema in place.
///
/// v0.4.2 still used the names of the codebase the library came from: core
/// tables named `dashboard_*` and `desktop_*`, OpenClaw gateway tables and
/// columns, and per-row boilerplate (`user_id`, `governing_plane`,
/// `authority_kind`, `authority_agent_id`, `origin_device_id`,
/// `desktop_owned`) that every current writer sets to the same value. This
/// renames the tables and columns that hold current data, drops what nothing
/// reads any more, and rewrites the paired-sync bookkeeping to the new names,
/// so paired Macs that update together keep their versions and cursors.
///
/// It runs on open before anything else creates schema. Every trigger is
/// dropped first and every index it renames is dropped by its old name: the
/// regular schema creation that follows recreates both under their current
/// names. Each step checks what is present, so a partly converted or
/// partly created library converges on the same result, and a current library
/// is left untouched.
extension WorkspaceDatabaseConnection {
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
  ]

  /// JSON documents stored as BLOB, by their table's current name. They are
  /// TEXT now, so SQLite's JSON functions read them without a cast. Binary
  /// columns (hashes, artifact chunks, native history parts) stay BLOB, and
  /// `execution_conversations.transcript` is left for its own removal.
  static let jsonTextColumns: [(table: String, columns: [String])] = [
    ("execution_workspaces", ["payload"]), ("execution_journal", ["payload"]),
    ("execution_conversations", ["conversation"]), ("execution_adoptions", ["payload"]),
    ("execution_receipts", ["payload"]), ("device_saved_artifacts", ["manifest"]),
    ("device_artifact_uploads", ["manifest"]), ("product_analytics_preference", ["payload"]),
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
    var legacyColumns = false
    for (table, dropped) in Self.droppedLibraryColumns {
      let present = try columns(tables.contains(table) ? table : Self.renamedLibraryTables.first { $0.new == table }?.old ?? table)
      if !present.isDisjoint(with: dropped) { legacyColumns = true; break }
    }
    var jsonBlobs = false
    for (table, json) in Self.jsonTextColumns where !jsonBlobs {
      let name = tables.contains(table) ? table : Self.renamedLibraryTables.first { $0.new == table }?.old ?? table
      jsonBlobs = try !historyRowsUnlocked("SELECT 1 AS blob FROM pragma_table_info(?) WHERE upper(type)='BLOB' AND name IN (SELECT value FROM json_each(?))",
                                            values: [name, String(decoding: try JSONEncoder().encode(json), as: UTF8.self)]).isEmpty
    }
    guard legacyColumns || jsonBlobs || Self.renamedLibraryTables.contains(where: { tables.contains($0.old) })
            || Self.droppedLibraryTables.contains(where: tables.contains) else { return }

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

      for (old, new) in Self.renamedLibraryTables where tables.contains(old) {
        // A table under its new name only exists if a partial conversion or
        // a fresh creation already made it; it then holds the current state.
        if tables.contains(new) {
          try executeUnlocked("DROP TABLE \(Self.peerQuote(old))")
          try dropPeerRecordsUnlocked(old, bookkeeping: bookkeeping)
        } else {
          try executeUnlocked("ALTER TABLE \(Self.peerQuote(old)) RENAME TO \(Self.peerQuote(new))")
          for table in Self.peerNamedBookkeeping where bookkeeping.contains(table) {
            try toolsExecuteUnlocked("UPDATE \(table) SET table_name=? WHERE table_name=?", [new, old])
          }
          for table in Self.peerPayloadBookkeeping where bookkeeping.contains(table) {
            try toolsExecuteUnlocked("""
              UPDATE \(table) SET payload=json_set(payload,'$.table',?)
              WHERE json_valid(payload) AND json_extract(payload,'$.table')=?
              """, [new, old])
          }
        }
        tables.remove(old); tables.insert(new)
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
      for (table, dropped) in Self.droppedLibraryColumns where tables.contains(table) {
        let present = try columns(table)
        for column in dropped where present.contains(column) {
          try executeUnlocked("ALTER TABLE \(Self.peerQuote(table)) DROP COLUMN \(Self.peerQuote(column))")
          for name in Self.peerPayloadBookkeeping where bookkeeping.contains(name) {
            try toolsExecuteUnlocked("""
              UPDATE \(name) SET payload=json_remove(payload,'$.row.\(column)')
              WHERE json_valid(payload) AND json_extract(payload,'$.table')=? AND json_type(payload,'$.row.\(column)') IS NOT NULL
              """, [table])
          }
        }
      }
      try storeJSONAsTextUnlocked(tables: tables, bookkeeping: bookkeeping)
      // v0.4.2 declared `runtime_kind DEFAULT 'openclaw'`; a column default
      // only changes by rebuilding the table, which keeps every row and rowid.
      if tables.contains("agents"), try historyRowsUnlocked(
        "SELECT 1 AS present FROM sqlite_master WHERE name='agents' AND instr(sql,'''openclaw''')>0", values: []).isEmpty == false {
        try rebuildCoreTableUnlocked("agents")
      }
    }
    try executeUnlocked("PRAGMA foreign_keys=ON")
  }

  /// Recreates a core table from its current declaration and copies its rows,
  /// rowids included. Nothing references these tables by foreign key.
  private func rebuildCoreTableUnlocked(_ table: String) throws {
    guard let start = Self.coreTablesSQL.range(of: "CREATE TABLE IF NOT EXISTS \(table) ("),
          let end = Self.coreTablesSQL.range(of: ");", range: start.upperBound..<Self.coreTablesSQL.endIndex) else {
      throw WorkspaceDatabaseError.execute("No current declaration for \(table)")
    }
    let rebuilt = table + "_rebuilt"
    let declaration = "CREATE TABLE \(rebuilt) (" + Self.coreTablesSQL[start.upperBound..<end.upperBound]
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
    return String(bytes: bytes, encoding: .utf8)
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

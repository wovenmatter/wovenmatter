import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

/// Tables named `companion_*` that the previous release left in a library
/// and never read: what the library held for other devices before its
/// tables were renamed. That release created the renamed tables empty
/// beside them, with a new library ID and a new device identity
/// (`library_identity`), so the library forgot which of its chats run on a
/// phone and lost the history those phones had published.
///
/// The library keeps the identity it has now. What a phone or tablet
/// published is adopted into the current tables: its workspace, the chats
/// that run on it, their runs, its journal, its native history and saved
/// files, and the receipts of what it asked this library to do. Such a
/// device keeps its own identity and offers its journal again when it is
/// paired again; with these rows in place the library recognises every
/// entry it already holds and continues after the last one. Without them
/// it would refuse the first entry, because the chat it names is already a
/// chat of this library that nothing says the phone runs.
///
/// Everything else in these tables is dropped with them:
/// - The earlier library ID and device identity, and the change feed
///   counted from them (`companion_workspace`, `companion_library_identity`,
///   `companion_versions`, `companion_changes`). Devices pair again and
///   read the current feed from its start.
/// - A Mac's workspace and the chats shown on it. Every Mac registers
///   itself under its present identity, and what runs on a Mac follows from
///   its owner records.
/// - A Linux host's workspace, chats and history. The Mac that adds the
///   host registers it and reads its journal from the host again.
/// - State of work that was in flight: uploads, scheduled callers, the
///   tables of roles the previous release had already removed.
///
/// An adopted row is not recorded as a new version for peers: each Mac
/// adopts its own copy of what both held, and a row travels the next time
/// its owner changes it.
extension WorkspaceDatabaseConnection {
  private static let leftoverDeviceTable = "name LIKE 'companion\\_%' ESCAPE '\\'"

  func holdsLeftoverDeviceTablesUnlocked() throws -> Bool {
    try !historyRowsUnlocked("SELECT 1 AS leftover FROM sqlite_master WHERE type='table' AND \(Self.leftoverDeviceTable) LIMIT 1",
                             values: []).isEmpty
  }

  func adoptLeftoverDeviceTablesUnlocked() throws {
    let tables = try libraryTableNamesUnlocked()
    /// Whether the library has the leftover table and all of `current`.
    func has(_ leftover: String, _ current: String...) -> Bool { tables.contains(leftover) && tables.isSuperset(of: current) }
    /// The workspace `id` names is registered here as a phone's or tablet's.
    func phoneWorkspace(_ id: String) -> String {
      "EXISTS(SELECT 1 FROM execution_workspaces w WHERE w.id=\(id) AND w.deleted=0 AND json_extract(w.payload,'$.kind')='ios')"
    }
    /// The device `id` names owns such a workspace.
    func phone(_ id: String) -> String {
      "EXISTS(SELECT 1 FROM execution_workspaces w WHERE w.owner_device_id=\(id) AND w.deleted=0 AND json_extract(w.payload,'$.kind')='ios')"
    }
    let library = "(SELECT library_id FROM library_identity WHERE singleton=1)"

    // A phone's workspace, as registered with this library.
    if has("companion_execution_workspaces", "execution_workspaces", "library_identity") {
      try executeUnlocked("""
        INSERT OR IGNORE INTO execution_workspaces(id,owner_device_id,revision,deleted,payload)
        SELECT o.id,o.owner_device_id,o.revision,0,json_set(CAST(o.payload AS TEXT),'$.libraryID',\(library))
        FROM companion_execution_workspaces o
        WHERE o.deleted=0 AND json_valid(CAST(o.payload AS TEXT)) AND json_extract(CAST(o.payload AS TEXT),'$.kind')='ios'
        """)
    }
    guard tables.contains("execution_workspaces") else { return try dropLeftoverDeviceTablesUnlocked() }

    // The chats that run on it. A chat this library has since given an
    // owner or a native session of its own stays where it is.
    if has("companion_execution_conversations", "execution_conversations", "conversations", "conversation_owners", "harness_sessions",
           "library_identity") {
      let adopted = try libraryIDsUnlocked("""
        SELECT o.id FROM companion_execution_conversations o
        WHERE \(phoneWorkspace("o.workspace_id")) AND json_valid(CAST(o.conversation AS TEXT))
          AND EXISTS(SELECT 1 FROM conversations c WHERE c.id=o.id)
          AND NOT EXISTS(SELECT 1 FROM execution_conversations x WHERE x.id=o.id)
          AND NOT EXISTS(SELECT 1 FROM conversation_owners n WHERE n.id=o.id)
          AND NOT EXISTS(SELECT 1 FROM harness_sessions h WHERE h.conversation_id=o.id)
        """, bindings: [])
      let ids = String(decoding: try JSONEncoder().encode(adopted), as: UTF8.self)
      try toolsExecuteUnlocked("""
        INSERT INTO execution_conversations(id,workspace_id,deleted,conversation)
        SELECT o.id,o.workspace_id,o.deleted,json_set(CAST(o.conversation AS TEXT),'$.libraryID',\(library))
        FROM companion_execution_conversations o WHERE o.id IN (SELECT value FROM json_each(?))
        """, [ids])
      if try libraryColumnNamesUnlocked("companion_execution_conversations").contains("transcript") {
        try moveLeftoverTranscriptsToRowsUnlocked(ids)
      }
    }
    /// The chat `conversation` names runs on the workspace `workspace` names.
    func runsOn(_ conversation: String, _ workspace: String) -> String {
      "EXISTS(SELECT 1 FROM execution_conversations x WHERE x.id=\(conversation) AND x.workspace_id=\(workspace)) AND \(phoneWorkspace(workspace))"
    }
    if has("companion_execution_runs", "execution_runs", "execution_conversations") {
      try executeUnlocked("""
        INSERT OR IGNORE INTO execution_runs(id,workspace_id,conversation_id)
        SELECT o.id,o.workspace_id,o.conversation_id FROM companion_execution_runs o WHERE \(runsOn("o.conversation_id", "o.workspace_id"))
        """)
    }

    // Native history: each record under its format's current name, and the
    // bytes of its parts as files of the chunk store.
    if has("companion_native_history", "companion_native_history_parts", "execution_native_history", "execution_native_history_parts",
           "execution_conversations") {
      let adopted = """
        \(runsOn("o.conversation_id", "o.workspace_id")) AND NOT EXISTS(
          SELECT 1 FROM execution_native_history n WHERE n.workspace_id=o.workspace_id AND n.record_id=o.record_id)
        """
      try moveLeftoverBytesToChunksUnlocked(
        read: """
          SELECT p.workspace_id,p.record_id,p.part_index,p.bytes FROM companion_native_history_parts p
          JOIN companion_native_history o ON o.workspace_id=p.workspace_id AND o.record_id=p.record_id WHERE \(adopted)
          """,
        write: "INSERT OR IGNORE INTO execution_native_history_parts(workspace_id,record_id,part_index,sha256,byte_count) VALUES(?,?,?,?,?)")
      try executeUnlocked("""
        INSERT INTO execution_native_history(workspace_id,record_id,conversation_id,run_id,format,part_count,byte_count,sha256,complete)
        SELECT o.workspace_id,o.record_id,o.conversation_id,o.run_id,\(Self.currentRecordFormatSQL("o.format")),o.part_count,o.byte_count,
          o.sha256,o.complete FROM companion_native_history o WHERE \(adopted)
        """)
    }
    if has("companion_execution_journal", "execution_journal") { try adoptLeftoverJournalsUnlocked(phoneWorkspace("o.workspace_id")) }

    // Saved files a phone published, with their bytes as files of the chunk store.
    if has("companion_saved_artifacts", "companion_artifact_chunks", "saved_artifacts", "artifact_chunks") {
      let adopted = """
        json_valid(CAST(o.manifest AS TEXT)) AND \(phoneWorkspace("json_extract(CAST(o.manifest AS TEXT),'$.workspaceID')"))
          AND NOT EXISTS(SELECT 1 FROM saved_artifacts n WHERE n.id=o.id)
        """
      try moveLeftoverBytesToChunksUnlocked(
        read: """
          SELECT p.artifact_id,p.revision,p.offset,p.bytes FROM companion_artifact_chunks p
          JOIN companion_saved_artifacts o ON o.id=p.artifact_id AND o.revision=p.revision WHERE \(adopted)
          """,
        write: "INSERT OR IGNORE INTO artifact_chunks(artifact_id,revision,offset,sha256,byte_count) VALUES(?,?,?,?,?)")
      try executeUnlocked("""
        INSERT INTO saved_artifacts(id,revision,manifest) SELECT o.id,o.revision,CAST(o.manifest AS TEXT) FROM companion_saved_artifacts o
        WHERE \(adopted)
        """)
    }

    // Rows kept as they are: the same key means the same thing in the
    // current table, and a key the library already has is the current one.
    let kept: [(leftover: String, current: String, needs: [String], columns: String, values: String, valid: String)] = [
      // What a phone's commands came to, by workspace.
      ("companion_execution_receipts", "execution_receipts", [], "workspace_id,command_id,device_id,payload",
       "o.workspace_id,o.command_id,o.device_id,CAST(o.payload AS TEXT)", phoneWorkspace("o.workspace_id")),
      // Which session a message a phone's agent wrote came from.
      ("companion_message_provenance", "message_provenance", ["messages"], "message_id,source_id,source_title,source_agent,kind",
       "o.message_id,o.source_id,o.source_title,o.source_agent,o.kind", "EXISTS(SELECT 1 FROM messages m WHERE m.id=o.message_id)"),
      // What this library answered a phone's requests with: a request the
      // phone repeats is answered the same way, not carried out twice.
      ("companion_mutation_receipts", "device_mutation_receipts", [], "device_id,operation_id,request,response",
       "o.device_id,o.operation_id,o.request,CAST(o.response AS TEXT)", phone("o.device_id")),
      ("companion_command_receipts", "device_command_receipts", [], "device_id,command_id,request,response",
       "o.device_id,o.command_id,o.request,CAST(o.response AS TEXT)", phone("o.device_id")),
      ("companion_tool_receipts", "device_tool_receipts", ["conversations"], "device_id,request_id,conversation_id,fingerprint,response",
       "o.device_id,o.request_id,o.conversation_id,o.fingerprint,CAST(o.response AS TEXT)",
       "\(phone("o.device_id")) AND EXISTS(SELECT 1 FROM conversations c WHERE c.id=o.conversation_id)"),
      ("companion_calendar_receipts", "device_calendar_receipts", [], "device_id,mutation_id,input_json,result_json",
       "o.device_id,o.mutation_id,o.input_json,o.result_json", phone("o.device_id")),
      ("companion_draft_receipts", "device_draft_receipts", ["notes"], "operation_id,note_id,title,content,revision",
       "o.operation_id,o.note_id,o.title,o.content,o.revision", "EXISTS(SELECT 1 FROM notes n WHERE n.id=o.note_id)"),
      // The schedules a phone runs itself, and the runs it published.
      ("companion_calendar_owners", "calendar_task_executors", ["calendar_items"], "event_id,device_id,tools_json",
       "o.event_id,o.device_id,o.tools_json", "\(phone("o.device_id")) AND EXISTS(SELECT 1 FROM calendar_items i WHERE i.id=o.event_id)"),
      ("companion_calendar_run_owners", "calendar_run_publishers", ["calendar_items"], "event_id,device_id",
       "o.event_id,o.device_id", "\(phone("o.device_id")) AND EXISTS(SELECT 1 FROM calendar_items i WHERE i.id=o.event_id)"),
      ("companion_calendar_runs", "calendar_published_runs", ["calendar_items"], "id,event_id,device_id,payload_json",
       "o.id,o.event_id,o.device_id,o.payload_json", "\(phone("o.device_id")) AND EXISTS(SELECT 1 FROM calendar_items i WHERE i.id=o.event_id)"),
    ]
    for entry in kept where tables.contains(entry.leftover) && tables.contains(entry.current) && tables.isSuperset(of: entry.needs) {
      try executeUnlocked("""
        INSERT OR IGNORE INTO \(entry.current)(\(entry.columns)) SELECT \(entry.values) FROM \(entry.leftover) o WHERE \(entry.valid)
        """)
    }
    try dropLeftoverDeviceTablesUnlocked()
  }

  /// Drops every leftover table, with its indexes, and whatever peer
  /// bookkeeping names one.
  private func dropLeftoverDeviceTablesUnlocked() throws {
    let tables = try libraryTableNamesUnlocked()
    for table in try historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='table' AND \(Self.leftoverDeviceTable)", values: [])
      .compactMap({ $0.objectValue?["name"]?.stringValue }) {
      try executeUnlocked("DROP TABLE \(Self.peerQuote(table))")
    }
    // The names between `companion_` and the next prefix, through each table's index.
    for name in ["peer_sync_versions", "peer_sync_conflicts", "peer_sync_quarantine", "peer_sync_seeded", "peer_sync_reassert"]
    where tables.contains(name) {
      try executeUnlocked("DELETE FROM \(name) WHERE table_name>='companion_' AND table_name<'companion`'")
    }
  }

  /// Writes the bytes each row of `read` holds in its fourth column to the
  /// chunk store and names them in the row `write` inserts: the first three
  /// columns, then the chunk's `sha256` and `byte_count`.
  private func moveLeftoverBytesToChunksUnlocked(read: String, write: String) throws {
    let source = try prepareUnlocked(read), insert = try prepareUnlocked(write)
    defer { sqlite3_finalize(source); sqlite3_finalize(insert) }
    while true {
      let code = sqlite3_step(source)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let bytes = try blob(source, column: 3)
      sqlite3_reset(insert)
      try bind(text(source, column: 0), at: 1, to: insert)
      for column: Int32 in [1, 2] {
        // A record ID is text; a part index, a revision and an offset are integers.
        if sqlite3_column_type(source, column) == SQLITE_INTEGER { sqlite3_bind_int64(insert, column + 1, sqlite3_column_int64(source, column)) }
        else { try bind(text(source, column: column), at: column + 1, to: insert) }
      }
      try bind(libraryFiles.retainChunk(bytes), at: 4, to: insert)
      sqlite3_bind_int64(insert, 5, Int64(bytes.count))
      try stepDone(insert)
    }
  }

  /// Adopts a phone's journal where the library holds none for its
  /// workspace: the entries from the first on, as far as they follow one
  /// another and this build reads them. Each is stored as this build writes
  /// an entry it accepts, its record's format under the current name, with
  /// the fingerprint a repeated upload of it is compared with; the phone
  /// uploads the rest again.
  private func adoptLeftoverJournalsUnlocked(_ phoneWorkspace: String) throws {
    let workspaces = try libraryIDsUnlocked("""
      SELECT DISTINCT o.workspace_id FROM companion_execution_journal o
      WHERE \(phoneWorkspace) AND NOT EXISTS(SELECT 1 FROM execution_journal n WHERE n.workspace_id=o.workspace_id)
      """, bindings: [])
    let read = try prepareUnlocked("SELECT event_id,origin_sequence,payload FROM companion_execution_journal WHERE workspace_id=? ORDER BY origin_sequence")
    let insert = try prepareUnlocked("""
      INSERT INTO execution_journal(event_id,workspace_id,origin_sequence,fingerprint,payload)
      SELECT ?1,?2,?3,?4,?5 WHERE NOT EXISTS(SELECT 1 FROM execution_journal WHERE event_id=?1)
      """)
    defer { sqlite3_finalize(read); sqlite3_finalize(insert) }
    for workspace in workspaces {
      sqlite3_reset(read)
      try bind(workspace, at: 1, to: read)
      var next: Int64 = 1
      while true {
        let code = sqlite3_step(read)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else { throw stepError() }
        let eventID = try text(read, column: 0)
        guard sqlite3_column_int64(read, 1) == next,
              var entry = try? JSONDecoder().decode(ExecutionJournalEntry.self, from: blob(read, column: 2)),
              entry.eventID == eventID, entry.workspaceID == workspace, entry.originSequence == next else { break }
        if let format = entry.nativeRecord?.format { entry.nativeRecord?.format = Self.currentRecordFormat(format) }
        sqlite3_reset(insert)
        try bind(eventID, at: 1, to: insert); try bind(workspace, at: 2, to: insert); sqlite3_bind_int64(insert, 3, next)
        try bind(libraryFingerprint(entry), at: 4, to: insert); try bind(toolsJSON(entry), at: 5, to: insert)
        try stepDone(insert)
        guard changedRowCountUnlocked == 1 else { break }
        next += 1
      }
    }
  }

  /// Writes what each adopted chat's transcript document held into its
  /// rows, as the projection of a phone's journal writes them now: every
  /// message's, activity's and run's position, the fields only the document
  /// had, its active run, and any row it held that the tables lack. A tool
  /// message it retired is deleted. Rows that changed take their new values
  /// in each recorded version of them.
  private func moveLeftoverTranscriptsToRowsUnlocked(_ conversations: String) throws {
    var documents: [(id: String, transcript: LibraryTranscript)] = []
    let read = try prepareUnlocked("""
      SELECT id,transcript FROM companion_execution_conversations
      WHERE transcript IS NOT NULL AND id IN (SELECT value FROM json_each(?))
      """)
    defer { sqlite3_finalize(read) }
    try bind(conversations, at: 1, to: read)
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
    // Every Mac that converts the same document writes the same text.
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    func sortedJSON<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    func owner(_ table: String, _ id: String) throws -> String? {
      try libraryIDsUnlocked("SELECT conversation_id FROM \(table) WHERE id=?", bindings: [id]).first
    }
    for (conversationID, transcript) in documents {
      try toolsExecuteUnlocked("UPDATE execution_conversations SET active_run_id=? WHERE id=?", [transcript.activeRunID, conversationID])
      for (index, message) in transcript.messages.enumerated() {
        let values: [String?] = [message.sequence.map(String.init), String(index + 1), try message.attachments.map { try sortedJSON($0) },
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
        // An activity read from this Mac's rows into the document carries
        // only its title, detail and status, which its row already gives.
        let plain = activity.projectionJSON == nil && activity.detailsRecordID == nil && activity.isTransient == nil
          && activity.sequence == nil && activity.createdAt == nil && activity.completedAt == nil
        if plain, present != nil {
          try toolsExecuteUnlocked("UPDATE run_activities SET position=? WHERE id=?", [String(index + 1), activity.id])
          changed["run_activities", default: []].insert(activity.id)
          continue
        }
        let content = try activity.projectionJSON.flatMap { json in
          (try? JSONDecoder().decode(AgentRunActivity.self, from: Data(json.utf8))).map { _ in json }
        } ?? sortedJSON(AgentRunActivity(id: activity.id, kind: .activity, title: activity.title, detail: activity.detail, status: activity.status))
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
        let values: [String?] = [String(index + 1), run.userMessageID, run.assistantMessageID, run.status, run.startedAt, run.completedAt, run.id]
        switch try owner("runs", run.id) {
        case conversationID?:
          try toolsExecuteUnlocked("""
            UPDATE runs SET position=?,user_message_id=COALESCE(?,user_message_id),assistant_message_id=COALESCE(?,assistant_message_id),
              status=?,started_at=COALESCE(started_at,?),completed_at=? WHERE id=?
            """, values)
          changed["runs", default: []].insert(run.id)
        case nil:
          try toolsExecuteUnlocked("""
            INSERT INTO runs(position,user_message_id,assistant_message_id,status,started_at,completed_at,id,conversation_id,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, values + [conversationID, run.startedAt ?? now, now])
        default: continue
        }
      }
    }
    for (table, columns) in [
      ("messages", ["sequence", "position", "attachment_references", "status", "created_at"]),
      ("run_activities", ["position", "title", "detail", "status", "details_record_id", "is_transient", "sequence", "completed_at",
                          "created_at", "content"]),
      ("runs", ["position", "user_message_id", "assistant_message_id", "status", "started_at", "completed_at"]),
    ] {
      try recordConvertedValuesUnlocked(table, columns: columns, ids: (changed[table] ?? []).sorted())
    }
    // A deleted message's recorded versions become its deletion, which
    // every Mac that converts the same document records alike.
    if !deleted.isEmpty, try libraryTableNamesUnlocked().contains("peer_sync_versions") {
      try toolsExecuteUnlocked("""
        UPDATE peer_sync_versions SET payload=json_set(payload,'$.deleted',json('true'))
        WHERE table_name='messages' AND record_key IN (SELECT json_array(value) FROM json_each(?))
        """, [String(decoding: try JSONEncoder().encode(deleted), as: UTF8.self)])
    }
  }
}

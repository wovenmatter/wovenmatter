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

extension WorkspaceDatabaseConnection {
  struct PeerTable {
    let name: String
    /// Column names sorted by name, never by physical position: a library
    /// migrated over time adds columns at the end, a fresh one declares them
    /// in place, and both exchange rows by name.
    let columns: [String]
    /// Declared type (upper case) of each column.
    let types: [String: String]
    /// Primary-key columns in key order; the record identity is their array.
    let keys: [String]
    /// What a deletion records of the deleted row, sorted by name: its key
    /// columns and `peerAuthorityColumns`. Applying a deletion removes the
    /// row by its key; nothing else reads its old values.
    var tombstoneColumns: [String] { columns.filter { keys.contains($0) || WorkspaceDatabaseConnection.peerAuthorityColumns.contains($0) } }
  }
  /// Columns a deletion still carries, because a receiver decides with them
  /// whether and where the deletion applies: `conversation_id` names the
  /// conversation whose execution owner alone removes its runtime rows (and
  /// which a receive projects), `workspace_id` and `device_id` are what a
  /// Linux sender's execution conversation, owner, executor and publisher
  /// rows are checked against, and `owner_device_id` names the Mac whose
  /// workspace projection a receive refreshes.
  static let peerAuthorityColumns: Set<String> = ["conversation_id", "workspace_id", "device_id", "owner_device_id"]
  static func peerQuote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
  func peerTables() throws -> [PeerTable] {
    try PairedLibraryTables.names.compactMap { table in
      let columns = try historyRowsUnlocked("PRAGMA table_info(\(Self.peerQuote(table)))", values: []).compactMap(\.objectValue)
      guard !columns.isEmpty else { return nil }
      let sql = try historyRowsUnlocked("SELECT sql FROM sqlite_master WHERE name=?", values: [table]).first?.objectValue?["sql"]?.stringValue ?? ""
      let generated = sql.uppercased().contains("AUTOINCREMENT")
        ? columns.first { $0["pk"]?.doubleValue == 1 && $0["type"]?.stringValue?.uppercased() == "INTEGER" }?["name"]?.stringValue : nil
      var types: [String: String] = [:]
      for column in columns {
        guard let name = column["name"]?.stringValue, name != generated else { continue }
        types[name] = (column["type"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).uppercased()
      }
      let names = types.keys.sorted()
      var keys = columns.filter { ($0["pk"]?.doubleValue ?? 0) > 0 }.sorted { ($0["pk"]?.doubleValue ?? 0) < ($1["pk"]?.doubleValue ?? 0) }
        .compactMap { $0["name"]?.stringValue }.filter { $0 != generated }
      if keys.isEmpty { keys = names.contains("event_id") ? ["event_id"] : names.contains("id") ? ["id"] : [] }
      guard !keys.isEmpty else { throw peerError("A shared table has no stable identity: " + table) }
      return PeerTable(name: table, columns: names, types: types, keys: keys)
    }
  }
  private func peerError(_ message: String) -> LibraryAPIError { .init(code: "peer_sync", message: message) }
  /// A page in another exchange format (`PairedLibraryFormat.exchange`), or
  /// from a build before it. Nothing is applied and no cursor moves, so the
  /// exchange resumes where it stopped once both devices run the same format.
  static let peerUpdateRequired = LibraryAPIError(code: "update_required",
    message: "Update Woven Matter on every device before synchronizing.")

  /// Whether this build can apply `record`: it knows the record's table and
  /// every column the record carries, and can read its content
  /// (`PairedLibraryFormat`). A record that fails this comes from a newer
  /// build. It is kept waiting exactly as received and relayed, and applies
  /// once this device updates; it is never rejected or cut down to the
  /// columns this build knows, which would lose the rest on every device
  /// the cut-down row reached.
  private func peerRecordUnderstood(_ record: PairedLibraryRecord, _ tables: [String: PeerTable]) -> Bool {
    guard (record.needs ?? 0) <= PairedLibraryFormat.content, let table = tables[record.table] else { return false }
    return record.row.keys.allSatisfy { table.types[$0] != nil }
  }
  private func peerJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  /// The shared-table identity peers must agree on: per table, its column
  /// names with their declared types, sorted by name, and its key columns in
  /// key order. Physical column order is not part of it.
  private func peerSchema() throws -> String {
    let graph = try peerTables().map { table in
      table.name + ":" + table.columns.map { $0 + " " + (table.types[$0] ?? "") }.joined(separator: ",") + ":" + table.keys.joined(separator: ",")
    }.joined(separator: "\n")
    return SHA256.hash(data: Data(("v3\n" + graph).utf8)).hexString
  }

  /// The local peer-sync bookkeeping (`peer_sync_*`).
  /// - `peer_sync_versions` holds, for each shared row, the versions that
  ///   still matter: every causally maximal version this device has applied
  ///   (the winner and any concurrent version), plus received versions still
  ///   waiting for their bytes (`pending_peer`, the peer they came from).
  ///   A version is identified by its origin and clock. Each capture or
  ///   newly kept version takes the next `cursor` of one AUTOINCREMENT
  ///   sequence and every version it supersedes is deleted, so paging by
  ///   cursor returns each row's current versions once.
  ///   `waits_for_update` marks a waiting version this build cannot apply
  ///   yet (`peerRecordUnderstood`); it is retried once the schema or the
  ///   content level this build reads has changed, not on every pass.
  /// - `peer_sync_conflicts` keeps losing versions while they are still
  ///   concurrent; `peer_sync_quarantine` keeps rejected records until a
  ///   version covering them applies.
  static let peerSyncTablesSQL = """
    CREATE TABLE IF NOT EXISTS peer_sync_clock(singleton INTEGER PRIMARY KEY CHECK(singleton=1), device_id TEXT NOT NULL, tick INTEGER NOT NULL DEFAULT 0, vector TEXT NOT NULL DEFAULT '{}', applying INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS peer_sync_versions(cursor INTEGER PRIMARY KEY AUTOINCREMENT,table_name TEXT NOT NULL,record_key TEXT NOT NULL,
      origin TEXT NOT NULL,clock INTEGER NOT NULL,pending_peer TEXT,waits_for_update INTEGER NOT NULL DEFAULT 0,payload TEXT NOT NULL,
      UNIQUE(table_name,record_key,origin,clock));
    CREATE TABLE IF NOT EXISTS peer_sync_conflicts(id TEXT PRIMARY KEY,table_name TEXT NOT NULL,record_key TEXT NOT NULL,origin TEXT NOT NULL,clock INTEGER NOT NULL,payload TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS peer_sync_quarantine(id TEXT PRIMARY KEY,peer_id TEXT NOT NULL,table_name TEXT NOT NULL,record_key TEXT NOT NULL,origin TEXT NOT NULL,clock INTEGER NOT NULL,payload TEXT NOT NULL,error TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS peer_sync_cursors(peer_id TEXT PRIMARY KEY,pulled INTEGER NOT NULL DEFAULT 0,pushed INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS peer_sync_state(name TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS peer_sync_file_cursors(peer_id TEXT PRIMARY KEY,cursor TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS peer_sync_seeded(table_name TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS peer_sync_reassert(table_name TEXT NOT NULL,record_key TEXT NOT NULL,PRIMARY KEY(table_name,record_key));
    """

  /// Triggers commit a durable change in the same transaction as the content.
  /// They are enabled for all writers, including notes saved during a sync call.
  func migratePeerSync() throws {
    try transaction {
      try executeUnlocked(Self.peerSyncTablesSQL + """
        CREATE INDEX IF NOT EXISTS peer_sync_versions_pending ON peer_sync_versions(cursor) WHERE pending_peer IS NOT NULL;
        CREATE INDEX IF NOT EXISTS peer_sync_versions_waiting ON peer_sync_versions(cursor) WHERE waits_for_update=1;
        INSERT OR IGNORE INTO peer_sync_clock(singleton,device_id) SELECT 1,host_device_id FROM library_identity WHERE singleton=1;
        CREATE TABLE IF NOT EXISTS mac_routes(device_id TEXT PRIMARY KEY,library_id TEXT NOT NULL,endpoint TEXT NOT NULL,name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS remote_workspace_configurations(id TEXT PRIMARY KEY,owner_device_id TEXT NOT NULL,configuration TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS agent_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS conversation_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS calendar_item_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        """)
      // A local writer owns what it creates. Federation inserts its execution
      // projection first, so independent workspaces are never claimed here.
      // The conversation trigger is recreated on every open so its body always
      // names the current execution table.
      try executeUnlocked("""
        DROP TRIGGER IF EXISTS conversations_owner_insert;
        CREATE TRIGGER IF NOT EXISTS agents_owner_insert AFTER INSERT ON agents
        WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 BEGIN
          INSERT OR IGNORE INTO agent_owners VALUES(NEW.id,(SELECT device_id FROM peer_sync_clock WHERE singleton=1));
        END;
        CREATE TRIGGER conversations_owner_insert AFTER INSERT ON conversations
        WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0
          AND NOT EXISTS(SELECT 1 FROM execution_conversations c WHERE c.id=NEW.id) BEGIN
          INSERT OR IGNORE INTO conversation_owners VALUES(NEW.id,(SELECT device_id FROM peer_sync_clock WHERE singleton=1));
        END;
        CREATE TRIGGER IF NOT EXISTS calendar_items_owner_insert AFTER INSERT ON calendar_items
        WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0 BEGIN
          INSERT OR IGNORE INTO calendar_item_owners VALUES(NEW.id,(SELECT device_id FROM peer_sync_clock WHERE singleton=1));
        END;
        """)
      // Replaying observed rows must not manufacture fresh native history or
      // derived library work. FTS indexing still runs on the original, stable
      // incoming event IDs.
      let derived = [
        "messages_history_insert", "messages_history_update", "runs_history_insert", "runs_history_update",
        "message_attachments_history_insert", "message_attachments_history_update",
        "message_references_history_insert", "message_references_history_update",
        "run_activities_history_insert", "run_activities_history_update", "runs_final_activity_history_update",
        "opencode_sessions_history_insert", "messages_library_insert", "messages_library_update",
        "message_attachments_library_insert",
      ]
      for item in try historyRowsUnlocked(
        "SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name IN (" + derived.map { _ in "?" }.joined(separator: ",") + ")",
        values: derived) {
        guard let name = item.objectValue?["name"]?.stringValue,
              let sql = item.objectValue?["sql"]?.stringValue, !sql.contains("peer_sync_clock"),
              let begin = sql.range(of: #"\bBEGIN\b"#, options: [.regularExpression, .caseInsensitive]) else { continue }
        var header = String(sql[..<begin.lowerBound])
        if let when = header.range(of: #"\bWHEN\b"#, options: [.regularExpression, .caseInsensitive]) {
          let condition = String(header[when.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
          header = String(header[..<when.lowerBound]) + " WHEN (SELECT applying FROM peer_sync_clock)=0 AND (" + condition + ") "
        } else { header += " WHEN (SELECT applying FROM peer_sync_clock)=0 " }
        try executeUnlocked("DROP TRIGGER " + Self.peerQuote(name))
        try executeUnlocked(header + sql[begin.lowerBound...])
      }
      for table in try peerTables() {
        for operation in ["INSERT", "UPDATE", "DELETE"] {
          let row = operation == "DELETE" ? "OLD" : "NEW"
          let name = "\(table.name)_peer_sync_\(operation.lowercased())"
          let condition = operation == "UPDATE" ? " AND (" + table.columns.map { "OLD.\(Self.peerQuote($0)) IS NOT NEW.\(Self.peerQuote($0))" }.joined(separator: " OR ") + ")" : ""
          let capture = peerCapture(table, row: row, deleted: operation == "DELETE", source: "(SELECT \(peerKey(table, row: row)) AS peer_key) i")
          // SQLite stores the statement as written, without its semicolon. A
          // trigger written for other columns is replaced.
          let create = """
            CREATE TRIGGER \(name) AFTER \(operation) ON \(Self.peerQuote(table.name))
            WHEN (SELECT applying FROM peer_sync_clock WHERE singleton=1)=0\(condition)
            BEGIN
              \(Self.peerTick);
              \(capture.insert);
              \(capture.supersede);
            END
            """
          let stored = try historyRowsUnlocked("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", values: [name]).first?.objectValue?["sql"]?.stringValue
          guard stored != create else { continue }
          try executeUnlocked("DROP TRIGGER IF EXISTS \(name);\n" + create + ";")
        }
        let seeded = try historyRowsUnlocked("SELECT table_name FROM peer_sync_seeded WHERE table_name=?", values: [table.name])
        if seeded.isEmpty {
          try executeUnlocked(Self.peerTick)
          let capture = peerCapture(table, row: "i", deleted: false,
            source: "(SELECT \(peerKey(table, row: "s")) AS peer_key,s.* FROM \(Self.peerQuote(table.name)) s) i")
          try executeUnlocked(capture.insert + ";\n" + capture.supersede)
          try toolsExecuteUnlocked("INSERT INTO peer_sync_seeded VALUES(?)", [table.name])
        }
      }
      // What this build understands changed (an update added a table or a
      // column, or reads newer content): versions kept for it are tried again.
      let understands = try peerSchema() + ":" + String(PairedLibraryFormat.content)
      if try peerSyncStateUnlocked("understands") != understands {
        try executeUnlocked("UPDATE peer_sync_versions SET waits_for_update=0 WHERE waits_for_update=1")
        try setPeerSyncStateUnlocked("understands", understands)
      }
    }
  }

  func peerSyncStateUnlocked(_ name: String) throws -> String? {
    try historyRowsUnlocked("SELECT value FROM peer_sync_state WHERE name=?", values: [name]).first?.objectValue?["value"]?.stringValue
  }
  func setPeerSyncStateUnlocked(_ name: String, _ value: String?) throws {
    if let value { try toolsExecuteUnlocked("INSERT INTO peer_sync_state VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value", [name, value]) }
    else { try toolsExecuteUnlocked("DELETE FROM peer_sync_state WHERE name=?", [name]) }
  }
  private func decodePeerRecord(_ payload: String) throws -> PairedLibraryRecord {
    try JSONDecoder().decode(PairedLibraryRecord.self, from: Data(payload.utf8))
  }

  /// A local write's new tick, which its version carries as its clock.
  private static let peerTick = #"UPDATE peer_sync_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1"#

  /// The record identity of `row`: the JSON array of its key columns.
  private func peerKey(_ table: PeerTable, row: String) -> String {
    "printf('%s',json_array(" + table.keys.map { row + "." + Self.peerQuote($0) }.joined(separator: ",") + "))"
  }

  /// The record a local write of `row` produces, built once. `key` is its
  /// identity and `c` the clock row, already advanced. A deletion carries
  /// only the tombstone columns.
  private func capturePayload(_ table: PeerTable, row: String, key: String, deleted: Bool) -> String {
    func field(_ name: String) -> String { row + "." + Self.peerQuote(name) }
    let fields = (deleted ? table.tombstoneColumns : table.columns).flatMap { column -> [String] in
      let value = field(column)
      return ["'\(column)'", "json_object('type',typeof(\(value)),'value',CASE typeof(\(value)) WHEN 'blob' THEN hex(\(value)) WHEN 'real' THEN printf('%!.17g',\(value)) ELSE CAST(\(value) AS TEXT) || '' END)"]
    }.joined(separator: ",")
    let tombstone = deleted ? "json('true')" : table.columns.contains("deleted_at") ? "json(CASE WHEN \(field("deleted_at")) IS NOT NULL THEN 'true' ELSE 'false' END)" : table.columns.contains("deleted") ? "json(CASE WHEN \(field("deleted"))<>0 THEN 'true' ELSE 'false' END)" : "json('false')"
    return "json_object('table','\(table.name)','key',\(key),'row',json_object(\(fields)),'deleted',\(tombstone),'clock',c.tick,'origin',c.device_id,'vector',\(captureVector(table, key: key)))"
  }

  /// The causal vector a local write of one identity carries. A version still
  /// waiting for its bytes has not been seen here, although later writing from
  /// its origin has advanced this Mac's clock. For each such version that the
  /// identity's applied versions do not already cover, the write stays below
  /// it, so it is concurrent with that version instead of silently superseding
  /// it on every Mac.
  private func captureVector(_ table: PeerTable, key: String) -> String {
    let waiting = "w.table_name='\(table.name)' AND w.record_key=\(key) AND w.pending_peer IS NOT NULL"
    let seen = """
      (SELECT COALESCE(MAX(json_extract(a.payload,'$.vector."' || v.key || '"')),0) FROM peer_sync_versions a
        WHERE a.table_name='\(table.name)' AND a.record_key=\(key) AND a.pending_peer IS NULL)
      """
    let cap = "(SELECT MIN(w.clock)-1 FROM peer_sync_versions w WHERE \(waiting) AND w.origin=v.key AND w.clock>\(seen))"
    return """
      json(CASE WHEN NOT EXISTS(SELECT 1 FROM peer_sync_versions w WHERE \(waiting)) THEN c.vector
        ELSE (SELECT json_group_object(key,value) FROM (SELECT v.key,MIN(v.value,COALESCE(\(cap),v.value)) AS value
          FROM json_each(c.vector) v) WHERE value>0) END)
      """
  }

  /// Records a local version of each row of `source` (which names the row
  /// `row` and its identity `i.peer_key`): one new entry with a new cursor,
  /// then the removal of every version of that row this Mac has applied,
  /// which the write causally supersedes. Versions still waiting for their
  /// bytes stay: the write is concurrent with them.
  private func peerCapture(_ table: PeerTable, row: String, deleted: Bool, source: String) -> (insert: String, supersede: String) {
    let name = "'\(table.name)'"
    return ("""
      INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload)
      SELECT \(name),i.peer_key,c.device_id,c.tick,\(capturePayload(table, row: row, key: "i.peer_key", deleted: deleted)) FROM peer_sync_clock c,\(source)
      """, """
      DELETE FROM peer_sync_versions WHERE table_name=\(name) AND pending_peer IS NULL AND record_key IN (SELECT i.peer_key FROM \(source))
        AND NOT (origin=(SELECT device_id FROM peer_sync_clock) AND clock=(SELECT tick FROM peer_sync_clock))
      """)
  }

  /// The local row with identity `?1` as a source for `peerCapture`.
  private func peerLocalRow(_ table: PeerTable) -> String {
    "(SELECT \(peerKey(table, row: "s")) AS peer_key,s.* FROM \(Self.peerQuote(table.name)) s WHERE json_array(" +
      table.keys.map { "s." + Self.peerQuote($0) }.joined(separator: ",") + ")=?1) i"
  }

  /// The execution owner republishes its native row as a new local version
  /// after declining a stale observed one, so every Mac converges on it.
  private func reassertLocalRowsUnlocked(_ tables: [String: PeerTable]) throws {
    for item in try historyRowsUnlocked("SELECT table_name,record_key FROM peer_sync_reassert", values: []) {
      guard let name = item.objectValue?["table_name"]?.stringValue, let key = item.objectValue?["record_key"]?.stringValue,
            let table = tables[name] else { continue }
      let source = peerLocalRow(table)
      guard try historyRowsUnlocked("SELECT 1 AS present FROM \(source)", values: [key]).isEmpty == false else { continue }
      try executeUnlocked(Self.peerTick)
      let capture = peerCapture(table, row: "i", deleted: false, source: source)
      try toolsExecuteUnlocked(capture.insert, [key])
      try toolsExecuteUnlocked(capture.supersede, [key])
    }
    try executeUnlocked("DELETE FROM peer_sync_reassert")
  }

  func pairedLibraryPage(after cursor: Int64, limit: Int = 100) throws -> PairedLibraryPage {
    guard cursor >= 0 else { throw peerError("Invalid peer cursor.") }
    let query = try prepareUnlocked("SELECT cursor,payload FROM peer_sync_versions WHERE cursor>? ORDER BY cursor LIMIT ?")
    defer { sqlite3_finalize(query) }
    sqlite3_bind_int64(query, 1, cursor); sqlite3_bind_int(query, 2, Int32(max(1, min(limit, 100))))
    var entries: [PairedLibraryRecord] = [], next = cursor, bytes = 0
    while sqlite3_step(query) == SQLITE_ROW {
      let original = try text(query, column: 1)
      let record = try externalizePeerValues(JSONDecoder().decode(PairedLibraryRecord.self, from: Data(original.utf8)))
      let payload = try peerJSON(record)
      if !entries.isEmpty && bytes + payload.utf8.count > 8 * 1_024 * 1_024 { break }
      guard payload.utf8.count <= 32 * 1_024 * 1_024 else { throw peerError("A shared record exceeds the transfer limit; its local copy is safe.") }
      entries.append(record)
      bytes += payload.utf8.count; next = sqlite3_column_int64(query, 0)
    }
    let more = try historyRowsUnlocked("SELECT 1 AS present FROM peer_sync_versions WHERE cursor>? LIMIT 1", values: [String(next)]).isEmpty == false
    return try .init(format: PairedLibraryFormat.exchange, schema: peerSchema(), entries: entries, cursor: next, hasMore: more)
  }

  /// The page and its receive cursor commit together. Records merge through a
  /// durable causal frontier, so arrival order, exact retries and restarts all
  /// converge on the same winner without executing a command or creating a
  /// second conflict/recovery copy.
  func receivePairedLibrary(_ page: PairedLibraryPage, from peer: String, sender: PairedLibrarySender? = nil) throws {
    guard page.format == PairedLibraryFormat.exchange else { throw Self.peerUpdateRequired }
    guard UUID(uuidString: peer) != nil, page.entries.count <= 100, page.cursor >= 0 else { throw peerError("Invalid shared page.") }
    try applyPeerRecords(page.entries.map { ($0, nil) }, from: peer, cursor: page.cursor, senders: sender.map { [peer.lowercased(): $0] })
  }

  private struct PeerRecordRejected: Error { let message: String }

  private func peerText(_ value: PairedLibraryValue?) -> String? {
    guard let value, ["text", "integer"].contains(value.type) else { return nil }
    return value.value
  }

  /// Rows whose meaning depends on who wrote them, checked as they arrive.
  /// Origins are self-declared and records are relayed, so only the sender
  /// is known. Returns false to skip a record (it arrives again from a
  /// device allowed to send it); throws to quarantine a forged one.
  /// - Member entries and revocations are signed records: they are never
  ///   deleted, must match their signed payload, and never roll back to an
  ///   older entry or rewrite a revocation.
  /// - A Linux host (any sender but a Mac) writes registry and ownership rows
  ///   only for what it serves itself: its own workspace's registration and
  ///   that workspace's sessions, and owner rows naming itself. Everything
  ///   else it relays is skipped, so it can never point a Mac's workspace or
  ///   sessions at itself.
  private func peerRecordAllowed(_ record: PairedLibraryRecord, sender: PairedLibrarySender?) throws -> Bool {
    func column(_ name: String) -> String? { peerText(record.row[name]) }
    switch record.table {
    case "library_members":
      guard !record.deleted else { throw PeerRecordRejected(message: "A member entry cannot be deleted.") }
      guard let payload = column("payload"), let entry = try? JSONDecoder().decode(LibraryMemberEntry.self, from: Data(payload.utf8)), entry.isWellFormed,
            column("device_id") == entry.deviceID, column("added_by") == entry.addedBy, column("added_at") == String(entry.addedAt) else {
        throw PeerRecordRejected(message: "A member entry does not match its signed record.")
      }
      guard let existing = try historyRowsUnlocked("SELECT added_at,payload FROM library_members WHERE device_id=? AND added_by=?",
                                                  values: [entry.deviceID, entry.addedBy]).first?.objectValue else { return true }
      let time = existing["added_at"]?.intValue.map(Int64.init) ?? 0
      if time > entry.addedAt { return false }
      if time == entry.addedAt, existing["payload"]?.stringValue != payload { throw PeerRecordRejected(message: "A member entry was rewritten.") }
      return true
    case "library_member_revocations":
      guard !record.deleted else { throw PeerRecordRejected(message: "A member removal cannot be deleted.") }
      guard let payload = column("payload"), let revocation = try? JSONDecoder().decode(LibraryMemberRevocation.self, from: Data(payload.utf8)),
            revocation.isWellFormed, column("event_id") == revocation.eventID, column("device_id") == revocation.deviceID else {
        throw PeerRecordRejected(message: "A member removal does not match its signed record.")
      }
      if let existing = try historyRowsUnlocked("SELECT payload FROM library_member_revocations WHERE event_id=?", values: [revocation.eventID])
        .first?.objectValue?["payload"]?.stringValue, existing != payload { throw PeerRecordRejected(message: "A member removal was rewritten.") }
      return true
    default: break
    }
    guard let sender, sender.kind != .mac else { return true }
    let own = sender.deviceID.lowercased()
    func serves(_ workspace: ExecutionWorkspace?) -> Bool {
      workspace.map { MemberAudience.serving($0, members: sender.members) == own } ?? false
    }
    func servesWorkspace(_ id: String?) throws -> Bool { try serves(id.flatMap { try federationWorkspaceUnlocked($0) }) }
    switch record.table {
    case "execution_workspaces":
      guard let id = column("id"), let payload = column("payload"),
            let incoming = try? JSONDecoder().decode(ExecutionWorkspace.self, from: Data(payload.utf8)), incoming.id == id else { return false }
      let existing = try federationWorkspaceUnlocked(id)
      return serves(incoming) && (existing == nil || serves(existing))
    case "execution_conversations":
      guard let id = column("id"), try servesWorkspace(column("workspace_id")) else { return false }
      let current = try historyRowsUnlocked("SELECT workspace_id FROM execution_conversations WHERE id=?", values: [id])
        .first?.objectValue?["workspace_id"]?.stringValue
      return try current == nil || servesWorkspace(current)
    case "mac_routes", "remote_workspace_configurations":
      return false
    case "agent_owners", "conversation_owners", "calendar_item_owners":
      guard column("device_id")?.lowercased() == own, let id = column("id") else { return false }
      let current = try historyRowsUnlocked("SELECT device_id FROM \(record.table) WHERE id=?", values: [id]).first?.objectValue?["device_id"]?.stringValue
      return current == nil || current?.lowercased() == own
    case "calendar_task_executors":
      guard column("device_id")?.lowercased() == own, let id = column("event_id") else { return false }
      let current = try historyRowsUnlocked("SELECT device_id FROM calendar_task_executors WHERE event_id=?", values: [id]).first?.objectValue?["device_id"]?.stringValue
      return current == nil || current?.lowercased() == own
    case "calendar_run_publishers":
      return column("device_id")?.lowercased() == own
    default:
      return true
    }
  }
  private struct ProjectionScope { var conversations = Set<String>(); var owners = Set<String>() }

  /// `entries` pairs each record with the cursor of its waiting entry when it
  /// is retried from `peer_sync_versions` (`materializePendingPeerRecords`).
  /// `senders` names the current Mac and Linux members by device ID; each
  /// record is checked against the one it came from (`peerRecordAllowed`),
  /// when it arrives and again when a waiting one is retried. Retries skip
  /// a peer that is not among them (`materializePendingPeerRecords`); were
  /// one to reach here, it is treated as an unknown Linux host, which may
  /// write nothing it does not serve. Only fixtures that stand in for a
  /// Mac pass nil.
  private func applyPeerRecords(_ entries: [(record: PairedLibraryRecord, pending: Int64?)], from peer: String,
                                cursor: Int64?, senders: [String: PairedLibrarySender]?) throws {
    let tables = Dictionary(uniqueKeysWithValues: try peerTables().map { ($0.name, $0) })
    let sender = senders.map { $0[peer.lowercased()] ?? PairedLibrarySender(deviceID: peer, kind: .linux,
      members: [.init(deviceID: peer.lowercased(), kind: .linux, endpoints: [], revoked: true)]) }
    // Foreign references can arrive in the next bounded page. Preserve them;
    // do not let a transient missing parent discard an offline child edit.
    try executeUnlocked("PRAGMA foreign_keys=OFF")
    defer { try? executeUnlocked("PRAGMA foreign_keys=ON") }
    try transaction {
      try executeUnlocked("UPDATE peer_sync_clock SET applying=1 WHERE singleton=1")
      var vector = try JSONDecoder().decode([String: Int64].self, from: Data(historyRowsUnlocked("SELECT vector FROM peer_sync_clock", values: []).first!.objectValue!["vector"]!.stringValue!.utf8))
      var scope = ProjectionScope()
      // A retried entry that applied in place is no longer waiting; any other
      // outcome (applied as an echo, superseded, skipped, quarantined) ends it.
      func finish(_ pending: Int64?) throws {
        if let pending { try toolsExecuteUnlocked("DELETE FROM peer_sync_versions WHERE cursor=? AND pending_peer IS NOT NULL", [String(pending)]) }
      }
      for (received, pending) in entries {
        let record: PairedLibraryRecord, table: PeerTable
        // Each record applies inside its own savepoint, so a deterministic
        // rejection discovered mid-materialization leaves no partial change.
        try executeUnlocked("SAVEPOINT peer_record")
        do {
          // Everything checkable without the referenced bytes is checked first,
          // so a malformed record is never queued or relayed.
          guard UUID(uuidString: received.origin) != nil,
                received.clock > 0, received.clock < Int64.max - 1,
                received.vector.count <= 4096, received.vector[received.origin] == received.clock,
                received.vector.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 && $0.value <= received.clock }) else {
            throw PeerRecordRejected(message: "Invalid shared record in " + received.table + ".")
          }
          // A table, column or content this build does not know yet: the
          // record waits as received and is relayed (`peerRecordUnderstood`).
          guard peerRecordUnderstood(received, tables), let known = tables[received.table] else {
            if let pending { try toolsExecuteUnlocked("UPDATE peer_sync_versions SET waits_for_update=1 WHERE cursor=?", [String(pending)]) }
            else { try queuePeerRecordUnlocked(received, from: peer, waitsForUpdate: true) }
            try executeUnlocked("RELEASE peer_record")
            continue
          }
          // A record carries its identity and any of the table's columns: all
          // of them from a build with this schema, fewer from an older one
          // (the rest keep their local values), and a deletion its tombstone
          // columns.
          guard known.keys.allSatisfy({ received.row[$0] != nil }) else {
            throw PeerRecordRejected(message: "Invalid shared record in " + received.table + ".")
          }
          table = known
          try validatePeerKey(received, table: table)
          guard try peerRecordAllowed(received, sender: sender) else {
            try executeUnlocked("RELEASE peer_record")
            try finish(pending)
            continue
          }
          guard let hydrated = try hydratePeerValues(received) else {
            if pending == nil { try queuePeerRecordUnlocked(received, from: peer, waitsForUpdate: false) }
            try executeUnlocked("RELEASE peer_record")
            continue
          }
          record = hydrated
          try applyPeerRecordUnlocked(record, table: table, scope: &scope)
        } catch let rejected as PeerRecordRejected {
          // One malformed record must not stall every independent resource
          // stream. It is retained durably for diagnosis and never applied.
          // Storage and database failures still abort the whole page.
          try executeUnlocked("ROLLBACK TO peer_record"); try executeUnlocked("RELEASE peer_record")
          let payload = try peerJSON(received)
          try toolsExecuteUnlocked("INSERT OR IGNORE INTO peer_sync_quarantine VALUES(?,?,?,?,?,?,?,?)", [
            SHA256.hash(data: Data(payload.utf8)).hexString, peer, received.table, received.key, received.origin,
            String(received.clock), payload, rejected.message])
          try finish(pending)
          continue
        }
        try executeUnlocked("RELEASE peer_record")
        try finish(pending)
        for (origin, tick) in record.vector { vector[origin] = max(vector[origin, default: 0], tick) }
        try toolsExecuteUnlocked("UPDATE peer_sync_clock SET tick=MAX(tick,CAST(? AS INTEGER))", [String(record.clock)])
      }
      try projectConversationOwners(scope)
      try toolsExecuteUnlocked("UPDATE peer_sync_clock SET vector=?,applying=0", [try peerJSON(vector)])
      try reassertLocalRowsUnlocked(tables)
      try pruneSettledPeerStateUnlocked()
      if let cursor {
        try toolsExecuteUnlocked("INSERT INTO peer_sync_cursors(peer_id,pulled) VALUES(?,?) ON CONFLICT(peer_id) DO UPDATE SET pulled=MAX(pulled,excluded.pulled)", [peer, String(cursor)])
      }
    }
  }

  /// A conflict matters while its losing version is still one of the row's
  /// concurrent versions; a later write that covers it (made on a Mac that
  /// held both) settles it. The bytes a losing `library_items` version
  /// references are kept while its conflict exists, so those conflicts stay.
  /// A quarantined record is moot once an applied version covers its origin's
  /// write.
  func pruneSettledPeerStateUnlocked() throws {
    try executeUnlocked("""
      DELETE FROM peer_sync_conflicts WHERE table_name<>'library_items' AND NOT EXISTS(SELECT 1 FROM peer_sync_versions v
        WHERE v.table_name=peer_sync_conflicts.table_name AND v.record_key=peer_sync_conflicts.record_key
          AND v.origin=peer_sync_conflicts.origin AND v.clock=peer_sync_conflicts.clock AND v.pending_peer IS NULL);
      DELETE FROM peer_sync_quarantine WHERE EXISTS(SELECT 1 FROM peer_sync_versions v
        WHERE v.table_name=peer_sync_quarantine.table_name AND v.record_key=peer_sync_quarantine.record_key AND v.pending_peer IS NULL
          AND COALESCE(json_extract(v.payload,'$.vector."' || peer_sync_quarantine.origin || '"'),0)>=peer_sync_quarantine.clock);
      """)
  }

  /// Queues a received version whose bytes are not here yet. It is relayed at
  /// once, in arrival order, ahead of any later writing that covers it: a Mac
  /// that receives that writing from here then also knows this version is
  /// outstanding. A version this Mac already applied, or one an applied
  /// version supersedes, would never win and is not kept.
  private func queuePeerRecordUnlocked(_ received: PairedLibraryRecord, from peer: String, waitsForUpdate: Bool) throws {
    let members = try frontierMembersUnlocked(table: received.table, key: received.key)
    if let same = members.first(where: { $0.origin == received.origin && $0.clock == received.clock }) {
      guard same.vector == received.vector else { throw PeerRecordRejected(message: "A shared change identity was reused for different content.") }
      return
    }
    if members.contains(where: { $0.vector == received.vector || $0.dominates(received) }) { return }
    let payload = try peerJSON(received)
    if let existing = try historyRowsUnlocked("""
      SELECT payload FROM peer_sync_versions WHERE table_name=? AND record_key=? AND origin=? AND clock=CAST(? AS INTEGER)
      """, values: [received.table, received.key, received.origin, String(received.clock)]).first?.objectValue?["payload"]?.stringValue {
      guard existing == payload else { throw PeerRecordRejected(message: "A shared change identity was reused for different content.") }
      return
    }
    // An earlier waiting write of the same device, relayed by the same peer,
    // that this one supersedes would never win: a row a newer build keeps
    // rewriting therefore waits as one version, not one per write. Nothing
    // else is dropped for a version this build has not been able to check.
    for waiting in try historyRowsUnlocked("""
      SELECT cursor,payload FROM peer_sync_versions WHERE table_name=? AND record_key=? AND origin=? AND pending_peer=?
      """, values: [received.table, received.key, received.origin, peer]).compactMap(\.objectValue) {
      guard let cursor = waiting["cursor"]?.intValue, let version = try waiting["payload"]?.stringValue.map(decodePeerRecord),
            received.dominates(version) else { continue }
      try toolsExecuteUnlocked("DELETE FROM peer_sync_versions WHERE cursor=?", [String(cursor)])
    }
    try toolsExecuteUnlocked("""
      INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,pending_peer,waits_for_update,payload) VALUES(?,?,?,CAST(? AS INTEGER),?,?,?)
      """, [received.table, received.key, received.origin, String(received.clock), peer, waitsForUpdate ? "1" : "0", payload])
  }

  /// Keeps every causally maximal version of one identity. A dominated version
  /// is obsolete forever; the deterministic winner of the remaining concurrent
  /// versions is materialized and the losing writing stays recoverable.
  private func applyPeerRecordUnlocked(_ record: PairedLibraryRecord, table: PeerTable, scope: inout ProjectionScope) throws {
    let members = try frontierMembersUnlocked(table: record.table, key: record.key)
    if let same = members.first(where: { $0.vector == record.vector || ($0.origin == record.origin && $0.clock == record.clock) }) {
      // One version can arrive in two shapes: from a build that knows fewer
      // columns and from one that knows more. The columns both carry agree.
      guard same.vector == record.vector, same.deleted == record.deleted,
            same.row.allSatisfy({ record.row[$0.key] == nil || record.row[$0.key] == $0.value }) else {
        throw PeerRecordRejected(message: "A shared change identity was reused for different content.")
      }
      return
    }
    if members.contains(where: { $0.dominates(record) }) { return }
    try settleFrontierUnlocked(from: members, to: members.filter { !record.dominates($0) } + [record], adding: record, table: table, scope: &scope)
  }

  /// Every version of one identity this Mac has applied: the current winner
  /// plus retained concurrent versions.
  func frontierMembersUnlocked(table: String, key: String) throws -> [PairedLibraryRecord] {
    let stored = try historyRowsUnlocked("SELECT payload FROM peer_sync_versions WHERE table_name=? AND record_key=? AND pending_peer IS NULL",
                                         values: [table, key]).compactMap { $0.objectValue?["payload"]?.stringValue }.map(decodePeerRecord)
    return PairedLibraryRecord.frontier(stored)
  }

  /// Moves one identity from the versions `previous` to `members`, which add
  /// `record`. The deterministic winner of `members` is materialized when it
  /// changed, and losing writing stays recoverable. `record` is kept with a
  /// new cursor, or, when it was waiting for its bytes, with the cursor it was
  /// relayed under (peers past it already hold the same record). Versions it
  /// supersedes leave, as do waiting versions that can no longer win.
  private func settleFrontierUnlocked(from previous: [PairedLibraryRecord], to members: [PairedLibraryRecord], adding record: PairedLibraryRecord,
                                      table: PeerTable, scope: inout ProjectionScope) throws {
    guard let next = PairedLibraryRecord.winner(members) else { return }
    for loser in members where loser.vector != next.vector && (loser.row != next.row || loser.deleted != next.deleted) {
      try retainPeerConflict(loser)
    }
    let row = completedWinner(next, among: members, table: table)
    let before = PairedLibraryRecord.winner(previous).map { completedWinner($0, among: previous, table: table) }
    if next.vector != before?.vector || row.row != before?.row {
      try materializePeerRecord(row, table: table)
      for name in ["conversations", "conversation_owners", "execution_conversations"] where next.table == name {
        if let id = next.row["id"]?.value { scope.conversations.insert(id) }
      }
      if table.columns.contains("conversation_id"), let id = next.row["conversation_id"]?.value { scope.conversations.insert(id) }
      if next.table == "execution_workspaces", let owner = next.row["owner_device_id"]?.value { scope.owners.insert(owner) }
    }
    for gone in previous where !members.contains(where: { $0.vector == gone.vector }) {
      try toolsExecuteUnlocked("DELETE FROM peer_sync_versions WHERE table_name=? AND record_key=? AND origin=? AND clock=CAST(? AS INTEGER)",
                               [gone.table, gone.key, gone.origin, String(gone.clock)])
    }
    try toolsExecuteUnlocked("""
      INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,payload) VALUES(?,?,?,CAST(? AS INTEGER),?)
      ON CONFLICT(table_name,record_key,origin,clock) DO UPDATE SET payload=excluded.payload,pending_peer=NULL
      """, [record.table, record.key, record.origin, String(record.clock), try peerJSON(record)])
    for waiting in try historyRowsUnlocked("""
      SELECT cursor,payload FROM peer_sync_versions WHERE table_name=? AND record_key=? AND pending_peer IS NOT NULL
      """, values: [record.table, record.key]).compactMap(\.objectValue) {
      guard let cursor = waiting["cursor"]?.intValue, let version = try waiting["payload"]?.stringValue.map(decodePeerRecord),
            members.contains(where: { $0.vector == version.vector || $0.dominates(version) }) else { continue }
      try toolsExecuteUnlocked("DELETE FROM peer_sync_versions WHERE cursor=?", [String(cursor)])
    }
  }

  /// Whether applying `record` removes its row outright.
  private func removesRow(_ record: PairedLibraryRecord) -> Bool {
    record.deleted && record.row["deleted_at"]?.value == nil && record.row["deleted"]?.value != "1"
  }

  /// The row a winning version gives. A winner from a build that knows
  /// fewer columns than this one does not say what the others hold; each is
  /// taken from the highest-ranked concurrent version that carries it, so
  /// every device arrives at the same row whatever order the versions came
  /// in. A column no concurrent version carries keeps its local value.
  private func completedWinner(_ winner: PairedLibraryRecord, among members: [PairedLibraryRecord], table: PeerTable) -> PairedLibraryRecord {
    let missing = table.columns.filter { winner.row[$0] == nil }
    guard !missing.isEmpty, !removesRow(winner) else { return winner }
    let others = members.filter { $0.vector != winner.vector && !removesRow($0) }.sorted { $0.outranks($1) }
    guard !others.isEmpty else { return winner }
    var row = winner.row
    for column in missing {
      if let value = others.lazy.compactMap({ $0.row[column] }).first { row[column] = value }
    }
    return winner.with(row: row)
  }

  private func externalizePeerValues(_ record: PairedLibraryRecord) throws -> PairedLibraryRecord {
    var row = record.row
    for (name, value) in row where ["text", "blob"].contains(value.type) && (value.value?.utf8.count ?? 0) > 262_144 {
      let bytes = Data(value.value!.utf8)
      let hash = SHA256.hash(data: bytes).hexString
      let directory = libraryFiles.supportDirectory.appending(path: "paired-records")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let file = directory.appending(path: hash)
      if !FileManager.default.fileExists(atPath: file.path) {
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
      }
      row[name] = .init(type: "reference:" + value.type, value: hash)
    }
    return record.with(row: row)
  }
  /// Shared rows whose bytes are a file in the library's chunk store, named
  /// by the row's `sha256` and `byte_count`. A received version waits until
  /// the file sync has installed that file, as a large value waits for its
  /// peer record file; a deletion needs no bytes.
  static let peerChunkTables: Set<String> = ["artifact_chunks", "execution_native_history_parts"]

  /// Whether the record's chunk file is here; throws for a malformed name.
  private func peerChunkAvailable(_ record: PairedLibraryRecord) throws -> Bool {
    guard Self.peerChunkTables.contains(record.table), !record.deleted else { return true }
    guard let hash = record.row["sha256"], hash.type == "text", let name = hash.value, name.wholeMatch(of: /[0-9a-f]{64}/) != nil,
          let count = record.row["byte_count"], count.type == "integer", let size = count.value.flatMap(Int64.init),
          size >= 0, size <= Int64(FederationProtocol.maximumArtifactChunkBytes) else {
      throw PeerRecordRejected(message: "Invalid shared chunk in " + record.table + ".")
    }
    guard let stored = libraryFiles.chunkSize(name) else { return false }
    // Installed files were hashed against their name; the size is the row's claim.
    guard stored == size else { throw PeerRecordRejected(message: "A shared chunk does not match its file.") }
    return true
  }

  /// Returns nil while referenced bytes are unavailable. A corrupt local copy
  /// is discarded so a healthy peer can supply the same content again.
  private func hydratePeerValues(_ record: PairedLibraryRecord) throws -> PairedLibraryRecord? {
    guard try peerChunkAvailable(record) else { return nil }
    var row = record.row
    for (name, value) in row where value.type.hasPrefix("reference:") {
      guard ["reference:text", "reference:blob"].contains(value.type), let hash = value.value,
            hash.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw PeerRecordRejected(message: "Invalid large shared value.") }
      let file = libraryFiles.supportDirectory.appending(path: "paired-records/" + hash)
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard count <= 256 * 1_024 * 1_024 else { throw PeerRecordRejected(message: "Shared record exceeds its storage limit.") }
      let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
      guard SHA256.hash(data: bytes).hexString == hash,
            let text = String(data: bytes, encoding: .utf8) else {
        try? FileManager.default.removeItem(at: file)
        return nil
      }
      row[name] = .init(type: String(value.type.dropFirst("reference:".count)), value: text)
    }
    return record.with(row: row)
  }
  private func pendingReferencesAvailable(_ record: PairedLibraryRecord) -> Bool {
    // A malformed chunk name is ready: applying it quarantines it.
    guard (try? peerChunkAvailable(record)) != false else { return false }
    return record.row.values.allSatisfy { value in
      guard value.type.hasPrefix("reference:") else { return true }
      guard let hash = value.value, hash.wholeMatch(of: /[0-9a-f]{64}/) != nil else { return true }
      return FileManager.default.fileExists(atPath: libraryFiles.supportDirectory.appending(path: "paired-records/" + hash).path)
    }
  }
  /// Scans waiting records with a durable rotating position, so unavailable
  /// bytes at the start of the queue never starve later ready records.
  func materializePendingPeerRecords(budget: Int = 500, senders: [String: PairedLibrarySender]? = nil) throws {
    let tables = Dictionary(uniqueKeysWithValues: try peerTables().map { ($0.name, $0) })
    var after = Int64(try peerSyncStateUnlocked("pending.after") ?? "") ?? 0, scanned = 0, wrapped = after == 0
    while scanned < budget {
      let rows = try historyRowsUnlocked("""
        SELECT cursor,payload,pending_peer FROM peer_sync_versions
        WHERE pending_peer IS NOT NULL AND waits_for_update=0 AND cursor>? ORDER BY cursor LIMIT 100
        """, values: [String(after)])
      if rows.isEmpty {
        if wrapped { after = 0; break }
        after = 0; wrapped = true; continue
      }
      var ready: [String: [(record: PairedLibraryRecord, pending: Int64?)]] = [:]
      for row in rows {
        guard let fields = row.objectValue, let cursor = fields["cursor"]?.intValue, let payload = fields["payload"]?.stringValue,
              let peer = fields["pending_peer"]?.stringValue else { continue }
        scanned += 1; after = Int64(cursor)
        let record = try decodePeerRecord(payload)
        // A record from a newer build stays until this build understands it.
        guard peerRecordUnderstood(record, tables) else {
          try toolsExecuteUnlocked("UPDATE peer_sync_versions SET waits_for_update=1 WHERE cursor=?", [String(cursor)])
          continue
        }
        if pendingReferencesAvailable(record) { ready[peer, default: []].append((record, Int64(cursor))) }
      }
      // A record is applied only while the member it came from can be
      // checked. One from a peer the caller could not vouch for (no longer a
      // member, or the member list was unavailable just now) keeps waiting:
      // dropping it would lose it for good, since its relay has moved on.
      for (peer, entries) in ready.sorted(by: { $0.key < $1.key }) where senders == nil || senders?[peer.lowercased()] != nil {
        try applyPeerRecords(entries, from: peer, cursor: nil, senders: senders)
      }
    }
    try setPeerSyncStateUnlocked("pending.after", after == 0 ? nil : String(after))
  }
  func pairedLibrarySchemaUnlocked() throws -> String { try peerSchema() }
  func peerSyncWaitingForUpdate() throws -> Int {
    try historyRowsUnlocked("SELECT count(*) AS count FROM peer_sync_versions WHERE waits_for_update=1", values: [])
      .first?.objectValue?["count"]?.intValue ?? 0
  }
  func peerSyncQuarantineCount() throws -> Int {
    try historyRowsUnlocked("SELECT count(*) AS count FROM peer_sync_quarantine", values: []).first?.objectValue?["count"]?.intValue ?? 0
  }

  private func validatePeerKey(_ record: PairedLibraryRecord, table: PeerTable) throws {
    let query = try prepareUnlocked("SELECT json_array(" + table.keys.map { _ in "?" }.joined(separator: ",") + ")")
    defer { sqlite3_finalize(query) }
    for (index, key) in table.keys.enumerated() {
      guard let value = record.row[key], value.type != "null" else { throw PeerRecordRejected(message: "Missing shared identity.") }
      try bindPeer(value, query, Int32(index + 1))
    }
    guard sqlite3_step(query) == SQLITE_ROW, try text(query, column: 0) == record.key else { throw PeerRecordRejected(message: "Shared record identity mismatch.") }
  }

  private func bindPeer(_ value: PairedLibraryValue, _ statement: OpaquePointer, _ index: Int32) throws {
    switch value.type {
    case "null": guard value.value == nil else { throw PeerRecordRejected(message: "Invalid NULL.") }; sqlite3_bind_null(statement, index)
    case "text": guard let text = value.value else { throw PeerRecordRejected(message: "Invalid text.") }; try bind(text, at: index, to: statement)
    case "integer": guard let text = value.value, let number = Int64(text) else { throw PeerRecordRejected(message: "Invalid integer.") }; sqlite3_bind_int64(statement, index, number)
    case "real": guard let text = value.value, let number = Double(text), number.isFinite else { throw PeerRecordRejected(message: "Invalid real.") }; sqlite3_bind_double(statement, index, number)
    case "blob":
      guard let hex = value.value, hex.utf8.count.isMultiple(of: 2) else { throw PeerRecordRejected(message: "Invalid binary data.") }
      let chars = Array(hex.utf8); var bytes = Data(); bytes.reserveCapacity(chars.count / 2)
      for i in stride(from: 0, to: chars.count, by: 2) {
        guard let byte = UInt8(String(decoding: chars[i...i+1], as: UTF8.self), radix: 16) else { throw PeerRecordRejected(message: "Invalid binary data.") }; bytes.append(byte)
      }
      try bind(bytes, at: index, to: statement)
    default: throw PeerRecordRejected(message: "Unsupported shared value.")
    }
  }

  /// Runtime rows of a conversation are authored only by its execution owner.
  private static let ownerRuntimeTables: Set<String> = [
    "messages", "message_attachments", "message_references", "runs",
    "run_visible_notes", "run_activities", "session_execution_roots",
  ]
  /// Presentation any Mac may change without runtime effects. Trash and
  /// restore are owner-validated below; folder, archive and every other column
  /// are native binding authored only by the execution owner.
  private static let sharedConversationColumns: Set<String> = ["title", "is_pinned", "unread", "updated_at"]

  /// True when this Mac currently executes the chat natively: its owner record
  /// names this Mac and no adoption, retained history or independent execution
  /// projection has taken it over. A synthetic paired-Mac projection does not
  /// veto, so stale routing can still be repaired.
  private func executesNativelyUnlocked(_ conversation: String, local: String) throws -> Bool {
    try historyRowsUnlocked("""
      SELECT 1 AS owned FROM conversation_owners o WHERE o.id=?1 AND o.device_id=?2
        AND NOT EXISTS(SELECT 1 FROM execution_adoptions a WHERE a.conversation_id=?1)
        AND NOT EXISTS(SELECT 1 FROM retained_execution_history r WHERE r.conversation_id=?1)
        AND NOT EXISTS(SELECT 1 FROM execution_conversations x WHERE x.id=?1 AND NOT EXISTS(
          SELECT 1 FROM execution_workspaces w WHERE w.id=x.workspace_id AND json_extract(w.payload,'$.kind')='mac'))
      """, values: [conversation, local]).isEmpty == false
  }

  /// The owner's own trash check: running, uncertain or pending native work.
  private func conversationBusyUnlocked(_ id: String) throws -> Bool {
    try historyRowsUnlocked("""
      SELECT 1 AS busy FROM runs WHERE conversation_id=?1 AND status IN ('queued','accepted','running','uncertain')
      UNION ALL SELECT 1 FROM opencode_sessions WHERE conversation_id=?1 AND json_extract(snapshot_json,'$.active')=1
      UNION ALL SELECT 1 FROM opencode_submissions WHERE conversation_id=?1 AND status IN ('sending','uncertain') LIMIT 1
      """, values: [id]).isEmpty == false
  }

  /// On the execution owner, an observed version of its own native row keeps
  /// the owner's runtime truth: agent binding, authority, folder and run or
  /// message state. Title and pin edits apply. A trash request from another
  /// Mac is accepted only when the owner itself is idle, with the owner's
  /// trash effects; otherwise it is declined. Rows the owner lacks are still
  /// inserted, and the owner republishes the result so other Macs converge.
  private func preservingOwnerNativeRow(_ record: PairedLibraryRecord, table: PeerTable) throws -> PairedLibraryRecord? {
    let conversation: String?
    if table.name == "conversations" { conversation = record.row["id"]?.value }
    else if Self.ownerRuntimeTables.contains(table.name) { conversation = record.row["conversation_id"]?.value }
    else { return record }
    guard let conversation,
          let local = try historyRowsUnlocked("SELECT device_id FROM peer_sync_clock WHERE singleton=1", values: []).first?.objectValue?["device_id"]?.stringValue,
          record.origin != local, try executesNativelyUnlocked(conversation, local: local) else { return record }
    guard let current = try historyRowsUnlocked("""
      SELECT \(capturePayload(table, row: "i", key: "i.peer_key", deleted: false)) AS payload FROM peer_sync_clock c,\(peerLocalRow(table))
      """, values: [record.key])
      .first?.objectValue?["payload"]?.stringValue.map(decodePeerRecord) else { return record }
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO peer_sync_reassert VALUES(?,?)", [table.name, record.key])
    // Only the owner removes its native rows.
    guard table.name == "conversations", !(record.deleted && record.row["deleted_at"]?.value == nil) else { return nil }
    var row = current.row
    for column in Self.sharedConversationColumns { if let value = record.row[column] { row[column] = value } }
    let requested = record.row["deleted_at"]?.value, existing = current.row["deleted_at"]?.value
    if let requested, existing == nil {
      if try !conversationBusyUnlocked(conversation) {
        row["deleted_at"] = .init(type: "text", value: requested)
        row["original_folder_id"] = current.row["folder_id"] ?? .init(type: "null")
        try applyOwnerTrashEffectsUnlocked(conversation, reassertGoal: true)
      }
    } else if requested == nil, existing != nil {
      row["deleted_at"] = .init(type: "null")
      row["folder_id"] = current.row["original_folder_id"] ?? .init(type: "null")
      row["original_folder_id"] = .init(type: "null")
    }
    return record.with(row: row, deleted: row["deleted_at"]?.value != nil)
  }

  /// The owner's trash effects: pause an active goal with the owner's own run
  /// sequence, stop timers and cancel queued deliveries. For an accepted remote
  /// trash request the owner also republishes its goal.
  func applyOwnerTrashEffectsUnlocked(_ id: String, reassertGoal: Bool) throws {
    if var goal = try goalUnlocked(id), goal.status == .active {
      try captureGoalRunsUnlocked(&goal)
      try cancelQueuedGoalDeliveryUnlocked(goal)
      goal.status = .paused; goal.evidence = "This conversation was moved to Trash. Resume to continue."
      try saveGoalUnlocked(goal)
      if reassertGoal { try toolsExecuteUnlocked("INSERT OR IGNORE INTO peer_sync_reassert VALUES('session_goals',?)", [try peerJSON([id])]) }
    }
    try toolsExecuteUnlocked("UPDATE session_timers SET is_paused=1,pending_delivery_id=NULL WHERE session_id=?", [id])
    try toolsExecuteUnlocked("""
      UPDATE session_deliveries SET status='cancelled' WHERE (target_id=? OR source_id=?)
        AND (status='queued' OR (status='sending' AND transport_started=0))
      """, [id, id])
  }

  /// A rename stored as a title override applies whichever of the override or
  /// the conversation row arrives last, on every Mac, across restarts.
  private func applyTitleOverrideUnlocked(_ id: String) throws {
    try toolsExecuteUnlocked("""
      UPDATE conversations SET title=(SELECT title FROM conversation_titles WHERE conversation_id=?1)
      WHERE id=?1 AND EXISTS(SELECT 1 FROM conversation_titles WHERE conversation_id=?1)
        AND title IS NOT (SELECT title FROM conversation_titles WHERE conversation_id=?1)
      """, [id])
  }

  private func materializePeerRecord(_ incoming: PairedLibraryRecord, table: PeerTable, recoverConstraint: Bool = true) throws {
    guard let record = try preservingOwnerNativeRow(incoming, table: table) else { return }
    let match = table.keys.map { Self.peerQuote($0) + " IS ?" }.joined(separator: " AND ")
    // A version from a build with fewer columns writes the ones it carries;
    // the others keep their local values, or their defaults in a new row.
    let names = table.columns.filter { record.row[$0] != nil }
    let hardDelete = removesRow(record)
    let sql = hardDelete ? "DELETE FROM \(Self.peerQuote(table.name)) WHERE \(match)"
      : "INSERT INTO \(Self.peerQuote(table.name))(\(names.map(Self.peerQuote).joined(separator: ","))) VALUES(\(names.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(\(table.keys.map(Self.peerQuote).joined(separator: ","))) DO UPDATE SET \(names.map { Self.peerQuote($0) + "=excluded." + Self.peerQuote($0) }.joined(separator: ","))"
    let query = try prepareUnlocked(sql); defer { sqlite3_finalize(query) }
    let fields = hardDelete ? table.keys : names
    for (index, name) in fields.enumerated() {
      var value = record.row[name]!
      if !hardDelete, table.name == "tool_settings", name == "value" { value = try preservingLocalExposure(value, record: record, table: table) }
      try bindPeer(value, query, Int32(index + 1))
    }
    // Ownership rows are shared records of their own. An editor is not an
    // executor, so materializing an observed row never guesses its owner.
    let status = sqlite3_step(query)
    if status == SQLITE_CONSTRAINT || status & 0xff == SQLITE_CONSTRAINT {
      // A secondary constraint conflict is recoverable content, never a reason
      // to silently discard a row or block every independent resource stream.
      if recoverConstraint { try retainPeerConflict(record, recoverCopy: false) }
    } else if status != SQLITE_DONE { throw stepError() }
    if table.name == "conversations", let id = record.row["id"]?.value { try applyTitleOverrideUnlocked(id) }
    if table.name == "conversation_titles", let id = record.row["conversation_id"]?.value { try applyTitleOverrideUnlocked(id) }
  }

  /// Network exposure is a property of one Mac. Shared tool choices synchronize,
  /// while this Mac's outside MCP policy is never enabled or replaced by a peer.
  private func preservingLocalExposure(_ value: PairedLibraryValue, record: PairedLibraryRecord, table: PeerTable) throws -> PairedLibraryValue {
    // Settings that this version cannot load are a deterministic rejection of
    // this record, never a storage failure that stalls the page or a stored
    // value that fails every later reload.
    func loadable(_ data: Data) -> Bool { (try? JSONDecoder().decode(WorkspaceToolSettings.self, from: data).validate()) != nil }
    guard value.type == "text", let incoming = value.value, loadable(Data(incoming.utf8)),
          var settings = try? JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any] else {
      throw PeerRecordRejected(message: "Invalid shared tool settings.")
    }
    let match = table.keys.map { Self.peerQuote($0) + " IS ?" }.joined(separator: " AND ")
    let query = try prepareUnlocked("SELECT value FROM \(Self.peerQuote(table.name)) WHERE \(match)")
    defer { sqlite3_finalize(query) }
    for (index, key) in table.keys.enumerated() { try bindPeer(record.row[key]!, query, Int32(index + 1)) }
    let local = sqlite3_step(query) == SQLITE_ROW ? optionalText(query, column: 0) : nil
    // An unreadable local value carries no exposure to keep: it stays disabled.
    let localSettings = local.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    if let exposure = localSettings?["externalMCP"] { settings["externalMCP"] = exposure } else { settings.removeValue(forKey: "externalMCP") }
    var data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
    if !loadable(data) {
      // An unreadable local exposure is not kept: it stays disabled.
      settings.removeValue(forKey: "externalMCP")
      data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
    }
    return .init(type: "text", value: String(decoding: data, as: UTF8.self))
  }

  /// Projects only conversations touched by this receive. Unchanged foreign
  /// conversations are not rewritten on every bounded synchronization turn.
  private func projectConversationOwners(_ scope: ProjectionScope) throws {
    guard !scope.conversations.isEmpty || !scope.owners.isEmpty else { return }
    let localID = try libraryIdentityUnlocked().hostDeviceID
    let workspaces = try libraryExecutionWorkspaces()
    let rows = try historyRowsUnlocked("""
      SELECT id,device_id FROM conversation_owners
      WHERE id IN (SELECT value FROM json_each(?)) OR device_id IN (SELECT value FROM json_each(?))
      """, values: [try peerJSON(scope.conversations.sorted()), try peerJSON(scope.owners.sorted())])
    // A projection onto a Mac workspace is synthetic paired-Mac routing and is
    // rebuilt from the authoritative owner record, which also repairs routing an
    // earlier build guessed from an edit's origin. Independent Linux and iOS
    // execution projections are never replaced.
    let macWorkspaces = Set(workspaces.filter { $0.kind == .mac }.map(\.id))
    for row in rows {
      guard let id = row.objectValue?["id"]?.stringValue, let owner = row.objectValue?["device_id"]?.stringValue else { continue }
      let current = try historyRowsUnlocked("SELECT workspace_id FROM execution_conversations WHERE id=?", values: [id]).first?.objectValue?["workspace_id"]?.stringValue
      if let current, !macWorkspaces.contains(current) { continue }
      if owner == localID {
        if current != nil { try toolsExecuteUnlocked("DELETE FROM execution_conversations WHERE id=?", [id]) }
        continue
      }
      guard let workspace = workspaces.first(where: { $0.kind == .mac && $0.ownerDeviceID == owner && !$0.deleted }),
            let conversation = try libraryConversationUnlocked(id: id) else { continue }
      var projected = conversation; projected.workspaceID = workspace.id; projected.libraryID = workspace.libraryID
      if let current = try historyRowsUnlocked("SELECT title,folder_id,is_pinned FROM conversations WHERE id=?", values: [id]).first?.objectValue {
        projected.title = current["title"]?.stringValue ?? projected.title
        projected.folderID = current["folder_id"]?.stringValue
        projected.isPinned = current["is_pinned"]?.doubleValue == 1
      }
      let query = try prepareUnlocked("INSERT INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET workspace_id=excluded.workspace_id,conversation=excluded.conversation")
      defer { sqlite3_finalize(query) }
      try bind(id, at: 1, to: query); try bind(workspace.id, at: 2, to: query)
      try bindJSON(projected, at: 3, to: query); try stepDone(query)
    }
  }

  private func retainPeerConflict(_ record: PairedLibraryRecord, recoverCopy: Bool = true) throws {
    let payload = try peerJSON(record)
    let id = SHA256.hash(data: Data(payload.utf8)).hexString
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO peer_sync_conflicts VALUES(?,?,?,?,CAST(? AS INTEGER),?)",
                             [id, record.table, record.key, record.origin, String(record.clock), payload])
    // Only live writing gets a visible copy; a losing deletion has no content
    // to recover and must not resurrect a note.
    guard recoverCopy, record.table == "notes", !record.deleted else { return }
    // A deterministic visible copy makes conflicting writing recoverable in
    // Notes on every Mac, including an edit made concurrently with deletion.
    var row = record.row
    var bytes = Array(SHA256.hash(data: Data(("recovered:" + id).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
    let copyID = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
    row["id"] = .init(type: "text", value: copyID)
    row["title"] = .init(type: "text", value: (row["title"]?.value ?? "Untitled note") + " (Recovered edit)")
    row["deleted_at"] = .init(type: "null")
    let copy = PairedLibraryRecord(table: "notes", key: try peerJSON([copyID]), row: row, deleted: false, clock: record.clock, origin: record.origin, vector: record.vector, needs: record.needs)
    // Every Mac derives the same copy; one received from a peer is not recreated.
    if try frontierMembersUnlocked(table: copy.table, key: copy.key).isEmpty,
       let table = try peerTables().first(where: { $0.name == "notes" }) {
      try materializePeerRecord(copy, table: table, recoverConstraint: false)
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO peer_sync_versions(table_name,record_key,origin,clock,payload) VALUES(?,?,?,CAST(? AS INTEGER),?)",
                               [copy.table, copy.key, copy.origin, String(copy.clock), try peerJSON(copy)])
    }
  }
  func peerSyncCursors(_ peer: String) throws -> (Int64, Int64) {
    let query = try prepareUnlocked("SELECT pulled,pushed FROM peer_sync_cursors WHERE peer_id=?"); defer { sqlite3_finalize(query) }
    try bind(peer, at: 1, to: query)
    return sqlite3_step(query) == SQLITE_ROW ? (sqlite3_column_int64(query, 0), sqlite3_column_int64(query, 1)) : (0, 0)
  }
  func peerSyncConflicts() throws -> [PairedLibraryConflict] {
    try historyRowsUnlocked("SELECT id,payload FROM peer_sync_conflicts ORDER BY id", values: []).map {
      let row = $0.objectValue!
      return try .init(id: row["id"]!.stringValue!, record: JSONDecoder().decode(PairedLibraryRecord.self, from: Data(row["payload"]!.stringValue!.utf8)))
    }
  }
}

extension WorkspaceDatabase {
  public func peerSyncFileCursor(_ peer: String) async throws -> String {
    try await read { try $0.historyRowsUnlocked("SELECT cursor FROM peer_sync_file_cursors WHERE peer_id=?", values: [peer]).first?.objectValue?["cursor"]?.stringValue ?? "" }
  }
  public func savePeerSyncFileCursor(_ cursor: String, peer: String) async throws {
    try await write { try $0.toolsExecuteUnlocked("INSERT INTO peer_sync_file_cursors VALUES(?,?) ON CONFLICT(peer_id) DO UPDATE SET cursor=excluded.cursor", [peer, cursor]) }
  }
  /// `senders`: the current Mac and Linux members by device ID, so a waiting
  /// record is checked against the member it came from
  /// (`peerRecordAllowed`); one from a peer not among them keeps waiting.
  /// Only fixtures that stand in for Macs pass nil.
  public func materializePendingPeerRecords(senders: [String: PairedLibrarySender]? = nil) async throws {
    try await write { try $0.materializePendingPeerRecords(senders: senders) }
  }
  /// Records from a newer build that wait until this device updates.
  public func peerSyncWaitingForUpdate() async throws -> Int { try await read { try $0.peerSyncWaitingForUpdate() } }
  public func pairedLibraryPage(after cursor: Int64) async throws -> PairedLibraryPage { try await read { try $0.pairedLibraryPage(after: cursor) } }
  /// `sender`: the member that sent the page, for the checks in
  /// `peerRecordAllowed` (`LibraryPeerSync` always names it; fixtures that
  /// stand in for a Mac pass nil).
  /// Refused with `peer_unavailable` until the recovery backup this library
  /// asked for exists (`prepareForPeerSync`).
  public func receivePairedLibrary(_ page: PairedLibraryPage, from peer: String, sender: PairedLibrarySender? = nil) async throws {
    guard acceptsPeerImports else { throw Self.peerBackupPending }
    try await write { try $0.receivePairedLibrary(page, from: peer, sender: sender) }
  }
  public func peerSyncCursors(_ peer: String) async throws -> (pulled: Int64, pushed: Int64) { try await read { try $0.peerSyncCursors(peer) } }
  /// Records that `peer` holds this device's changes up to `cursor`, so later
  /// pushes start after it. Never moves back, and never past this device's
  /// own versions.
  public func acknowledgePairedLibrary(peer: String, cursor: Int64) async throws {
    try await write { try $0.toolsExecuteUnlocked("""
      INSERT INTO peer_sync_cursors(peer_id,pushed)
        VALUES(?,MIN(CAST(? AS INTEGER),COALESCE((SELECT seq FROM sqlite_sequence WHERE name='peer_sync_versions'),0)))
      ON CONFLICT(peer_id) DO UPDATE SET pushed=MAX(pushed,excluded.pushed)
      """, [peer, String(cursor)]) }
  }
  public func peerSyncConflicts() async throws -> [PairedLibraryConflict] { try await read { try $0.peerSyncConflicts() } }
  public func peerSyncQuarantineCount() async throws -> Int { try await read { try $0.peerSyncQuarantineCount() } }
  /// The newest cursor of `peer_sync_versions`.
  public func peerSyncHead() async throws -> Int64 {
    try await read { Int64(try $0.historyRowsUnlocked("SELECT seq FROM sqlite_sequence WHERE name='peer_sync_versions'", values: []).first?.objectValue?["seq"]?.doubleValue ?? 0) }
  }
  /// The shared-table graph, hashed. Peers report it; a difference means one
  /// of them has additions the other keeps waiting (`PairedLibraryFormat`).
  public func pairedLibrarySchema() async throws -> String { try await read { try $0.pairedLibrarySchemaUnlocked() } }
}

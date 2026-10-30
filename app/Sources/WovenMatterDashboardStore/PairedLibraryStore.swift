import CryptoKit
import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  struct PeerTable {
    let name: String
    let columns: [String]
    let keys: [String]
  }
  static func peerQuote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
  private func peerTables() throws -> [PeerTable] {
    try PairedLibraryTables.names.compactMap { table in
      let columns = try historyRowsUnlocked("PRAGMA table_info(\(Self.peerQuote(table)))", values: []).compactMap(\.objectValue)
      guard !columns.isEmpty else { return nil }
      let sql = try historyRowsUnlocked("SELECT sql FROM sqlite_master WHERE name=?", values: [table]).first?.objectValue?["sql"]?.stringValue ?? ""
      let generated = sql.uppercased().contains("AUTOINCREMENT")
        ? columns.first { $0["pk"]?.doubleValue == 1 && $0["type"]?.stringValue?.uppercased() == "INTEGER" }?["name"]?.stringValue : nil
      let names = columns.compactMap { $0["name"]?.stringValue }.filter { $0 != generated }
      var keys = columns.filter { ($0["pk"]?.doubleValue ?? 0) > 0 }.sorted { ($0["pk"]?.doubleValue ?? 0) < ($1["pk"]?.doubleValue ?? 0) }
        .compactMap { $0["name"]?.stringValue }.filter { $0 != generated }
      if keys.isEmpty { keys = names.contains("event_id") ? ["event_id"] : names.contains("id") ? ["id"] : [] }
      guard !keys.isEmpty else { throw peerError("A shared table has no stable identity: " + table) }
      return PeerTable(name: table, columns: names, keys: keys)
    }
  }
  private func peerError(_ message: String) -> CompanionAPIError { .init(code: "peer_sync", message: message) }
  private func peerJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  private func peerSchema() throws -> String {
    let graph = try peerTables().map { $0.name + ":" + $0.columns.joined(separator: ",") + ":" + $0.keys.joined(separator: ",") }.joined(separator: "\n")
    return SHA256.hash(data: Data(graph.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Triggers commit a durable change in the same transaction as the content.
  /// They are enabled for all writers, including notes saved during a sync call.
  func migratePairedLibrary() throws {
    try transaction {
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS paired_library_clock(singleton INTEGER PRIMARY KEY CHECK(singleton=1), device_id TEXT NOT NULL, tick INTEGER NOT NULL DEFAULT 0, vector TEXT NOT NULL DEFAULT '{}', applying INTEGER NOT NULL DEFAULT 0);
        INSERT OR IGNORE INTO paired_library_clock(singleton,device_id) SELECT 1,host_device_id FROM companion_library_identity WHERE singleton=1;
        CREATE TABLE IF NOT EXISTS paired_library_rows(table_name TEXT NOT NULL,record_key TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(table_name,record_key));
        CREATE TABLE IF NOT EXISTS paired_library_changes(cursor INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_conflicts(id TEXT PRIMARY KEY,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_cursors(peer_id TEXT PRIMARY KEY,pulled INTEGER NOT NULL DEFAULT 0,pushed INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS paired_mac_routes(device_id TEXT PRIMARY KEY,library_id TEXT NOT NULL,endpoint TEXT NOT NULL,name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_remote_workspaces(id TEXT PRIMARY KEY,owner_device_id TEXT NOT NULL,configuration TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS paired_agent_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        INSERT OR IGNORE INTO paired_agent_owners SELECT id,(SELECT device_id FROM paired_library_clock) FROM dashboard_agents;
        CREATE TRIGGER IF NOT EXISTS paired_agent_owner AFTER INSERT ON dashboard_agents
        WHEN (SELECT applying FROM paired_library_clock)=0 BEGIN
          INSERT OR IGNORE INTO paired_agent_owners VALUES(NEW.id,(SELECT device_id FROM paired_library_clock));
        END;
        CREATE TABLE IF NOT EXISTS paired_conversation_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        INSERT OR IGNORE INTO paired_conversation_owners SELECT id,(SELECT device_id FROM paired_library_clock) FROM dashboard_conversations
          WHERE NOT EXISTS(SELECT 1 FROM companion_execution_conversations c WHERE c.id=dashboard_conversations.id);
        CREATE TRIGGER IF NOT EXISTS paired_conversation_owner AFTER INSERT ON dashboard_conversations
        WHEN (SELECT applying FROM paired_library_clock)=0 BEGIN
          INSERT OR IGNORE INTO paired_conversation_owners VALUES(NEW.id,(SELECT device_id FROM paired_library_clock));
        END;
        CREATE TABLE IF NOT EXISTS paired_calendar_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        INSERT OR IGNORE INTO paired_calendar_owners SELECT id,(SELECT device_id FROM paired_library_clock) FROM dashboard_calendar_items;
        CREATE TRIGGER IF NOT EXISTS paired_calendar_owner AFTER INSERT ON dashboard_calendar_items
        WHEN (SELECT applying FROM paired_library_clock)=0 BEGIN
          INSERT OR IGNORE INTO paired_calendar_owners VALUES(NEW.id,(SELECT device_id FROM paired_library_clock));
        END;
        CREATE TABLE IF NOT EXISTS paired_library_pending(id TEXT PRIMARY KEY,payload TEXT NOT NULL,peer_id TEXT NOT NULL,cursor INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_seen(id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS paired_library_seeded(table_name TEXT PRIMARY KEY);
        """)
      // Replaying observed rows must not manufacture fresh native history.
      // FTS indexing still runs on the original, stable incoming event IDs.
      for item in try historyRowsUnlocked("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND name LIKE 'history_%'", values: []) {
        guard let name = item.objectValue?["name"]?.stringValue,
              !["history_search_insert", "history_search_delete"].contains(name),
              let sql = item.objectValue?["sql"]?.stringValue, !sql.contains("paired_library_clock"),
              let begin = sql.range(of: #"\bBEGIN\b"#, options: [.regularExpression, .caseInsensitive]) else { continue }
        var header = String(sql[..<begin.lowerBound])
        if let when = header.range(of: #"\bWHEN\b"#, options: [.regularExpression, .caseInsensitive]) {
          let condition = String(header[when.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
          header = String(header[..<when.lowerBound]) + " WHEN (SELECT applying FROM paired_library_clock)=0 AND (" + condition + ") "
        } else { header += " WHEN (SELECT applying FROM paired_library_clock)=0 " }
        try executeUnlocked("DROP TRIGGER " + Self.peerQuote(name))
        try executeUnlocked(header + sql[begin.lowerBound...])
      }
      for table in try peerTables() {
        for operation in ["INSERT", "UPDATE", "DELETE"] {
          let row = operation == "DELETE" ? "OLD" : "NEW"
          let condition = operation == "UPDATE" ? " AND (" + table.columns.map { "OLD.\(Self.peerQuote($0)) IS NOT NEW.\(Self.peerQuote($0))" }.joined(separator: " OR ") + ")" : ""
          try executeUnlocked("""
            CREATE TRIGGER IF NOT EXISTS paired_\(table.name)_\(operation) AFTER \(operation) ON \(Self.peerQuote(table.name))
            WHEN (SELECT applying FROM paired_library_clock WHERE singleton=1)=0\(condition)
            BEGIN
              UPDATE paired_library_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1;
              \(peerCapture(table, row: row, deleted: operation == "DELETE"))
            END;
            """)
        }
        let seeded = try historyRowsUnlocked("SELECT table_name FROM paired_library_seeded WHERE table_name=?", values: [table.name])
        if seeded.isEmpty {
          try executeUnlocked(#"UPDATE paired_library_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1"#)
          try executeUnlocked(peerCapture(table, row: "s", deleted: false, source: " FROM \(Self.peerQuote(table.name)) s"))
          try toolsExecuteUnlocked("INSERT INTO paired_library_seeded VALUES(?)", [table.name])
        }
      }
    }
  }

  private func peerCapture(_ table: PeerTable, row: String, deleted: Bool, source: String = "") -> String {
    func field(_ name: String) -> String { row + "." + Self.peerQuote(name) }
    let key = "json_array(" + table.keys.map(field).joined(separator: ",") + ")"
    let fields = table.columns.flatMap { column -> [String] in
      let value = field(column)
      return ["'\(column)'", "json_object('type',typeof(\(value)),'value',CASE WHEN typeof(\(value))='blob' THEN hex(\(value)) WHEN typeof(\(value))='real' THEN printf('%!.17g',\(value)) ELSE CAST(\(value) AS TEXT) || '' END)"]
    }.joined(separator: ",")
    let tombstone = deleted ? "json('true')" : table.columns.contains("deleted_at") ? "json(CASE WHEN \(field("deleted_at")) IS NOT NULL THEN 'true' ELSE 'false' END)" : table.columns.contains("deleted") ? "json(CASE WHEN \(field("deleted"))<>0 THEN 'true' ELSE 'false' END)" : "json('false')"
    let payload = "json_object('table','\(table.name)','key',printf('%s',\(key)),'row',json_object(\(fields)),'deleted',\(tombstone),'clock',(SELECT tick FROM paired_library_clock),'origin',(SELECT device_id FROM paired_library_clock),'vector',json((SELECT vector FROM paired_library_clock)))"
    return """
      INSERT INTO paired_library_changes(payload) SELECT \(payload)\(source);
      INSERT INTO paired_library_rows(table_name,record_key,payload) SELECT '\(table.name)',\(key),\(payload)\(source) WHERE true
      ON CONFLICT(table_name,record_key) DO UPDATE SET payload=excluded.payload;
      """
  }

  func pairedLibraryPage(after cursor: Int64, limit: Int = 100) throws -> PairedLibraryPage {
    guard cursor >= 0 else { throw peerError("Invalid peer cursor.") }
    let query = try prepareUnlocked("SELECT cursor,payload FROM paired_library_changes WHERE cursor>? ORDER BY cursor LIMIT ?")
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
    let more = try historyRowsUnlocked("SELECT 1 AS present FROM paired_library_changes WHERE cursor>? LIMIT 1", values: [String(next)]).isEmpty == false
    return try .init(schema: peerSchema(), entries: entries, cursor: next, hasMore: more)
  }

  /// The page and its receive cursor commit together. Exact retries neither
  /// execute a command nor create a second conflict/recovery copy.
  func receivePairedLibrary(_ page: PairedLibraryPage, from peer: String) throws {
    guard UUID(uuidString: peer) != nil, page.entries.count <= 100, page.cursor >= 0,
          page.schema == (try peerSchema()) else { throw peerError("Update both Macs to the same Woven Matter version before synchronizing.") }
    let tables = Dictionary(uniqueKeysWithValues: try peerTables().map { ($0.name, $0) })
    // Foreign references can arrive in the next bounded page. Preserve them;
    // do not let a transient missing parent discard an offline child edit.
    try executeUnlocked("PRAGMA foreign_keys=OFF")
    defer { try? executeUnlocked("PRAGMA foreign_keys=ON") }
    try transaction {
      try executeUnlocked("UPDATE paired_library_clock SET applying=1 WHERE singleton=1")
      var vector = try JSONDecoder().decode([String: Int64].self, from: Data(historyRowsUnlocked("SELECT vector FROM paired_library_clock", values: []).first!.objectValue!["vector"]!.stringValue!.utf8))
      for received in page.entries {
        guard let record = try hydratePeerValues(received) else {
          let payload = try peerJSON(received)
          let id = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
          try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_pending VALUES(?,?,?,?)", [id, payload, peer, String(page.cursor)])
          continue
        }
        guard let table = tables[record.table], UUID(uuidString: record.origin) != nil,
              record.clock > 0, record.clock < Int64.max - 1,
              record.vector.count <= 4096, record.vector[record.origin] == record.clock,
              record.vector.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 && $0.value <= record.clock }),
              Set(record.row.keys) == Set(table.columns) else { throw peerError("Invalid shared record in " + record.table + ". Local data is retained.") }
        try validatePeerKey(record, table: table)
        let priorJSON = try historyRowsUnlocked("SELECT payload FROM paired_library_rows WHERE table_name=? AND record_key=?", values: [record.table, record.key]).first?.objectValue?["payload"]?.stringValue
        let prior = try priorJSON.map { try JSONDecoder().decode(PairedLibraryRecord.self, from: Data($0.utf8)) }
        if let prior, prior.vector == record.vector {
          guard prior == record else { throw peerError("A shared change identity was reused for different content.") }
          continue
        }
        let payload = try peerJSON(record)
        let changeID = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        let seen = try historyRowsUnlocked("SELECT id FROM paired_library_seen WHERE id=?", values: [changeID]).isEmpty == false
        if seen { continue }
        try toolsExecuteUnlocked("INSERT INTO paired_library_seen VALUES(?)", [changeID])
        try toolsExecuteUnlocked("INSERT INTO paired_library_changes(payload) VALUES(?)", [payload])
        let wins = prior.map { record.supersedes($0) } ?? true
        if let prior, record.concurrent(with: prior), prior.row != record.row || prior.deleted != record.deleted {
          try retainPeerConflict(wins ? prior : record)
        }
        if wins {
          try materializePeerRecord(record, table: table)
          try toolsExecuteUnlocked("INSERT INTO paired_library_rows VALUES(?,?,?) ON CONFLICT(table_name,record_key) DO UPDATE SET payload=excluded.payload", [record.table, record.key, payload])
        }
        for (origin, tick) in record.vector { vector[origin] = max(vector[origin, default: 0], tick) }
        try toolsExecuteUnlocked("UPDATE paired_library_clock SET tick=MAX(tick,CAST(? AS INTEGER))", [String(record.clock)])
      }
      try projectPairedConversationOwners()
      try toolsExecuteUnlocked("UPDATE paired_library_clock SET vector=?,applying=0", [try peerJSON(vector)])
      try toolsExecuteUnlocked("INSERT INTO paired_library_cursors(peer_id,pulled) VALUES(?,?) ON CONFLICT(peer_id) DO UPDATE SET pulled=MAX(pulled,excluded.pulled)", [peer, String(page.cursor)])
    }
  }

  private func externalizePeerValues(_ record: PairedLibraryRecord) throws -> PairedLibraryRecord {
    var row = record.row
    for (name, value) in row where ["text", "blob"].contains(value.type) && (value.value?.utf8.count ?? 0) > 262_144 {
      let bytes = Data(value.value!.utf8)
      let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let directory = libraryFiles.supportDirectory.appending(path: "paired-records")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let file = directory.appending(path: hash)
      if !FileManager.default.fileExists(atPath: file.path) {
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
      }
      row[name] = .init(type: "reference:" + value.type, value: hash)
    }
    return .init(table: record.table, key: record.key, row: row, deleted: record.deleted, clock: record.clock, origin: record.origin, vector: record.vector)
  }
  private func hydratePeerValues(_ record: PairedLibraryRecord) throws -> PairedLibraryRecord? {
    var row = record.row
    for (name, value) in row where value.type.hasPrefix("reference:") {
      guard ["reference:text", "reference:blob"].contains(value.type), let hash = value.value,
            hash.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw peerError("Invalid large shared value.") }
      let file = libraryFiles.supportDirectory.appending(path: "paired-records/" + hash)
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard count <= 256 * 1_024 * 1_024 else { throw peerError("Shared record exceeds its storage limit.") }
      let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
      guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash,
            let text = String(data: bytes, encoding: .utf8) else { throw peerError("A large shared record failed its content check.") }
      row[name] = .init(type: String(value.type.dropFirst("reference:".count)), value: text)
    }
    return .init(table: record.table, key: record.key, row: row, deleted: record.deleted, clock: record.clock, origin: record.origin, vector: record.vector)
  }
  func materializePendingPeerRecords() throws {
    let pending = try historyRowsUnlocked("SELECT * FROM paired_library_pending ORDER BY cursor,id LIMIT 100", values: [])
    for item in pending {
      let fields = item.objectValue!
      guard let payload = fields["payload"]?.stringValue,
            let record = try hydratePeerValues(JSONDecoder().decode(PairedLibraryRecord.self, from: Data(payload.utf8))) else { continue }
      let cursor = Int64(fields["cursor"]?.stringValue ?? "") ?? Int64(fields["cursor"]?.doubleValue ?? 0)
      try receivePairedLibrary(.init(schema: peerSchema(), entries: [record], cursor: cursor, hasMore: false), from: fields["peer_id"]!.stringValue!)
      try toolsExecuteUnlocked("DELETE FROM paired_library_pending WHERE id=?", [fields["id"]!.stringValue!])
    }
  }

  private func validatePeerKey(_ record: PairedLibraryRecord, table: PeerTable) throws {
    let query = try prepareUnlocked("SELECT json_array(" + table.keys.map { _ in "?" }.joined(separator: ",") + ")")
    defer { sqlite3_finalize(query) }
    for (index, key) in table.keys.enumerated() {
      guard let value = record.row[key], value.type != "null" else { throw peerError("Missing shared identity.") }
      try bindPeer(value, query, Int32(index + 1))
    }
    guard sqlite3_step(query) == SQLITE_ROW, try text(query, column: 0) == record.key else { throw peerError("Shared record identity mismatch.") }
  }

  private func bindPeer(_ value: PairedLibraryValue, _ statement: OpaquePointer, _ index: Int32) throws {
    switch value.type {
    case "null": guard value.value == nil else { throw peerError("Invalid NULL.") }; sqlite3_bind_null(statement, index)
    case "text": guard let text = value.value else { throw peerError("Invalid text.") }; try bind(text, at: index, to: statement)
    case "integer": guard let text = value.value, let number = Int64(text) else { throw peerError("Invalid integer.") }; sqlite3_bind_int64(statement, index, number)
    case "real": guard let text = value.value, let number = Double(text), number.isFinite else { throw peerError("Invalid real.") }; sqlite3_bind_double(statement, index, number)
    case "blob":
      guard let hex = value.value, hex.utf8.count.isMultiple(of: 2) else { throw peerError("Invalid binary data.") }
      let chars = Array(hex.utf8); var bytes = Data(); bytes.reserveCapacity(chars.count / 2)
      for i in stride(from: 0, to: chars.count, by: 2) {
        guard let byte = UInt8(String(decoding: chars[i...i+1], as: UTF8.self), radix: 16) else { throw peerError("Invalid binary data.") }; bytes.append(byte)
      }
      try bind(bytes, at: index, to: statement)
    default: throw peerError("Unsupported shared value.")
    }
  }

  private func materializePeerRecord(_ record: PairedLibraryRecord, table: PeerTable) throws {
    let match = table.keys.map { Self.peerQuote($0) + " IS ?" }.joined(separator: " AND ")
    let names = table.columns
    let hardDelete = record.deleted && record.row["deleted_at"]?.value == nil && record.row["deleted"]?.value != "1"
    let sql = hardDelete ? "DELETE FROM \(Self.peerQuote(table.name)) WHERE \(match)"
      : "INSERT INTO \(Self.peerQuote(table.name))(\(names.map(Self.peerQuote).joined(separator: ","))) VALUES(\(names.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(\(table.keys.map(Self.peerQuote).joined(separator: ","))) DO UPDATE SET \(names.map { Self.peerQuote($0) + "=excluded." + Self.peerQuote($0) }.joined(separator: ","))"
    let query = try prepareUnlocked(sql); defer { sqlite3_finalize(query) }
    let fields = hardDelete ? table.keys : names
    for (index, name) in fields.enumerated() {
      var value = record.row[name]!
      if name == "user_id", value.type == "text" { value = .init(type: "text", value: try localMutationOperatorIDUnlocked()) }
      // Runtime ownership never moves with an observed conversation or agent.
      if name == "desktop_owned" { value = .init(type: "integer", value: "1") }
      try bindPeer(value, query, Int32(index + 1))
    }
    if table.name == "dashboard_agents", let id = record.row["id"]?.value {
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_agent_owners VALUES(?,?)", [id, record.origin])
    }
    if table.name == "dashboard_conversations", let id = record.row["id"]?.value {
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_conversation_owners VALUES(?,?)", [id, record.origin])
    }
    if table.name == "dashboard_calendar_items", let id = record.row["id"]?.value {
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_calendar_owners VALUES(?,?)", [id, record.origin])
    }
    let status = sqlite3_step(query)
    if status == SQLITE_CONSTRAINT || status & 0xff == SQLITE_CONSTRAINT {
      // A secondary UNIQUE conflict is recoverable content, never a reason to
      // silently discard a row or block every independent resource stream.
      try retainPeerConflict(record)
    } else if status != SQLITE_DONE { throw stepError() }
  }

  private func projectPairedConversationOwners() throws {
    let localID = try companionLibraryIdentityUnlocked().hostDeviceID
    let workspaces = try companionExecutionWorkspaces()
    for row in try historyRowsUnlocked("SELECT id,device_id FROM paired_conversation_owners", values: []) {
      guard let id = row.objectValue?["id"]?.stringValue, let owner = row.objectValue?["device_id"]?.stringValue,
            let workspace = workspaces.first(where: { $0.kind == .mac && $0.ownerDeviceID == owner && !$0.deleted }) else { continue }
      if owner == localID {
        try toolsExecuteUnlocked("DELETE FROM companion_execution_conversations WHERE id=? AND workspace_id=?", [id, workspace.id])
        continue
      }
      guard let conversation = try companionConversationUnlocked(id: id) else { continue }
      if let existing = conversation.workspaceID, existing != workspace.id { continue }
      var projected = conversation; projected.workspaceID = workspace.id; projected.libraryID = workspace.libraryID
      if let current = try historyRowsUnlocked("SELECT title,folder_id,is_pinned FROM dashboard_conversations WHERE id=?", values: [id]).first?.objectValue {
        projected.title = current["title"]?.stringValue ?? projected.title
        projected.folderID = current["folder_id"]?.stringValue
        projected.isPinned = current["is_pinned"]?.doubleValue == 1
      }
      let transcript = try federationLegacyTranscriptUnlocked(id)
      let query = try prepareUnlocked("INSERT INTO companion_execution_conversations(id,workspace_id,conversation,transcript) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET conversation=excluded.conversation,transcript=excluded.transcript")
      defer { sqlite3_finalize(query) }
      try bind(id, at: 1, to: query); try bind(workspace.id, at: 2, to: query)
      try bind(JSONEncoder().encode(projected), at: 3, to: query); try bind(JSONEncoder().encode(transcript), at: 4, to: query); try stepDone(query)
    }
  }

  private func retainPeerConflict(_ record: PairedLibraryRecord) throws {
    let payload = try peerJSON(record)
    let id = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_conflicts VALUES(?,?)", [id, payload])
    guard record.table == "notes" else { return }
    // A deterministic visible copy makes conflicting writing recoverable in
    // Notes on every Mac, including an edit made concurrently with deletion.
    var row = record.row
    var bytes = Array(SHA256.hash(data: Data(("recovered:" + id).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
    let copyID = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
    row["id"] = .init(type: "text", value: copyID)
    row["title"] = .init(type: "text", value: (row["title"]?.value ?? "Untitled note") + " (Recovered edit)")
    row["deleted_at"] = .init(type: "null")
    let copy = PairedLibraryRecord(table: "notes", key: try peerJSON([copyID]), row: row, deleted: false, clock: record.clock, origin: record.origin, vector: record.vector)
    if try historyRowsUnlocked("SELECT id FROM notes WHERE id=?", values: [copyID]).isEmpty,
       let table = try peerTables().first(where: { $0.name == "notes" }) {
      try materializePeerRecord(copy, table: table)
      let recovery = try peerJSON(copy)
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_rows VALUES(?,?,?)", [copy.table, copy.key, recovery])
      try toolsExecuteUnlocked("INSERT INTO paired_library_changes(payload) VALUES(?)", [recovery])
    }

  }
  func pairedLibraryCursors(_ peer: String) throws -> (Int64, Int64) {
    let query = try prepareUnlocked("SELECT pulled,pushed FROM paired_library_cursors WHERE peer_id=?"); defer { sqlite3_finalize(query) }
    try bind(peer, at: 1, to: query)
    return sqlite3_step(query) == SQLITE_ROW ? (sqlite3_column_int64(query, 0), sqlite3_column_int64(query, 1)) : (0, 0)
  }
  func pairedLibraryConflicts() throws -> [PairedLibraryConflict] {
    try historyRowsUnlocked("SELECT id,payload FROM paired_library_conflicts ORDER BY id", values: []).map {
      let row = $0.objectValue!
      return try .init(id: row["id"]!.stringValue!, record: JSONDecoder().decode(PairedLibraryRecord.self, from: Data(row["payload"]!.stringValue!.utf8)))
    }
  }
}

extension WorkspaceDatabase {
  public func materializePendingPeerRecords() async throws { try await write { try $0.materializePendingPeerRecords() } }
  public func pairedLibraryPage(after cursor: Int64) async throws -> PairedLibraryPage { try await read { try $0.pairedLibraryPage(after: cursor) } }
  public func receivePairedLibrary(_ page: PairedLibraryPage, from peer: String) async throws { try await write { try $0.receivePairedLibrary(page, from: peer) } }
  public func pairedLibraryCursors(_ peer: String) async throws -> (pulled: Int64, pushed: Int64) { try await read { try $0.pairedLibraryCursors(peer) } }
  public func acknowledgePairedLibrary(peer: String, cursor: Int64) async throws {
    try await write { try $0.toolsExecuteUnlocked("INSERT INTO paired_library_cursors(peer_id,pushed) VALUES(?,?) ON CONFLICT(peer_id) DO UPDATE SET pushed=MAX(pushed,excluded.pushed)", [peer, String(cursor)]) }
  }
  public func pairedLibraryConflicts() async throws -> [PairedLibraryConflict] { try await read { try $0.pairedLibraryConflicts() } }
}

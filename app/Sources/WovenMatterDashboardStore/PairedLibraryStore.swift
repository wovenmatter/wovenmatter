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
        CREATE TABLE IF NOT EXISTS paired_library_frontier(table_name TEXT NOT NULL,record_key TEXT NOT NULL,version TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(table_name,record_key,version));
        CREATE TABLE IF NOT EXISTS paired_library_changes(cursor INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_conflicts(id TEXT PRIMARY KEY,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_quarantine(id TEXT PRIMARY KEY,peer_id TEXT NOT NULL,payload TEXT NOT NULL,error TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_cursors(peer_id TEXT PRIMARY KEY,pulled INTEGER NOT NULL DEFAULT 0,pushed INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS paired_library_state(name TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_mac_routes(device_id TEXT PRIMARY KEY,library_id TEXT NOT NULL,endpoint TEXT NOT NULL,name TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_remote_workspaces(id TEXT PRIMARY KEY,owner_device_id TEXT NOT NULL,configuration TEXT NOT NULL,deleted INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS paired_agent_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_conversation_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_calendar_owners(id TEXT PRIMARY KEY,device_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_file_cursors(peer_id TEXT PRIMARY KEY,cursor TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_pending(id TEXT PRIMARY KEY,payload TEXT NOT NULL,peer_id TEXT NOT NULL,cursor INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS paired_library_seen(id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS paired_library_seeded(table_name TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS paired_library_reassert(table_name TEXT NOT NULL,record_key TEXT NOT NULL,PRIMARY KEY(table_name,record_key));
        """)
      // Ownership of pre-existing rows is claimed exactly once, before any peer
      // data can arrive. Rows later received without their owner record stay
      // read-only and are never adopted by a restart. A schedule assigned to
      // this Mac's own execution context stays local; one assigned to a client
      // device keeps that executor.
      if try pairedStateUnlocked("owners.bootstrap") == nil {
        let received = try historyRowsUnlocked("SELECT 1 AS present FROM paired_library_cursors UNION ALL SELECT 1 FROM paired_library_pending LIMIT 1", values: []).isEmpty == false
        if !received {
          try executeUnlocked("""
            INSERT OR IGNORE INTO paired_agent_owners SELECT id,(SELECT device_id FROM paired_library_clock WHERE singleton=1) FROM dashboard_agents;
            INSERT OR IGNORE INTO paired_conversation_owners SELECT id,(SELECT device_id FROM paired_library_clock WHERE singleton=1) FROM dashboard_conversations
              WHERE NOT EXISTS(SELECT 1 FROM companion_execution_conversations c WHERE c.id=dashboard_conversations.id);
            INSERT OR IGNORE INTO paired_calendar_owners SELECT i.id,CASE
                WHEN o.device_id IS NULL OR o.device_id=(SELECT workspace_id FROM companion_calendar_execution_context WHERE singleton=1)
                  OR o.device_id=(SELECT host_device_id FROM companion_library_identity WHERE singleton=1)
                THEN (SELECT device_id FROM paired_library_clock WHERE singleton=1) ELSE o.device_id END
              FROM dashboard_calendar_items i LEFT JOIN companion_calendar_owners o ON o.event_id=i.id;
            """)
        }
        try setPairedStateUnlocked("owners.bootstrap", "1")
      }
      // A local writer owns what it creates. Federation inserts its execution
      // projection first, so independent workspaces are never claimed here.
      try executeUnlocked("""
        DROP TRIGGER IF EXISTS paired_conversation_owner;
        CREATE TRIGGER IF NOT EXISTS paired_agent_owner AFTER INSERT ON dashboard_agents
        WHEN (SELECT applying FROM paired_library_clock WHERE singleton=1)=0 BEGIN
          INSERT OR IGNORE INTO paired_agent_owners VALUES(NEW.id,(SELECT device_id FROM paired_library_clock WHERE singleton=1));
        END;
        CREATE TRIGGER IF NOT EXISTS paired_conversation_owner_v2 AFTER INSERT ON dashboard_conversations
        WHEN (SELECT applying FROM paired_library_clock WHERE singleton=1)=0
          AND NOT EXISTS(SELECT 1 FROM companion_execution_conversations c WHERE c.id=NEW.id) BEGIN
          INSERT OR IGNORE INTO paired_conversation_owners VALUES(NEW.id,(SELECT device_id FROM paired_library_clock WHERE singleton=1));
        END;
        CREATE TRIGGER IF NOT EXISTS paired_calendar_owner AFTER INSERT ON dashboard_calendar_items
        WHEN (SELECT applying FROM paired_library_clock WHERE singleton=1)=0 BEGIN
          INSERT OR IGNORE INTO paired_calendar_owners VALUES(NEW.id,(SELECT device_id FROM paired_library_clock WHERE singleton=1));
        END;
        """)
      // Replaying observed rows must not manufacture fresh native history or
      // derived library work. FTS indexing still runs on the original, stable
      // incoming event IDs.
      for item in try historyRowsUnlocked("SELECT name,sql FROM sqlite_master WHERE type='trigger' AND (name LIKE 'history_%' OR name IN ('library_new_message','library_changed_message','library_new_attachment','library_cleared_conversation'))", values: []) {
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
          let name = "paired_\(table.name)_\(operation)"
          if let sql = try historyRowsUnlocked("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", values: [name]).first?.objectValue?["sql"]?.stringValue,
             !sql.contains("paired_library_frontier") { try executeUnlocked("DROP TRIGGER " + Self.peerQuote(name)) }
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
      // Earlier builds kept only one winner per row. Retained concurrent
      // versions that are still causally maximal become frontier members.
      if try pairedStateUnlocked("frontier.v1") == nil {
        for conflict in try pairedLibraryConflicts() {
          let record = conflict.record
          let winner = try pairedWinnerUnlocked(table: record.table, key: record.key)
          guard let winner, winner.vector != record.vector, !winner.dominates(record) else { continue }
          try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_frontier VALUES(?,?,?,?)", [record.table, record.key, try peerVersion(record), try peerJSON(record)])
        }
        try setPairedStateUnlocked("frontier.v1", "1")
      }
      if try pairedStateUnlocked("projection.v2") == nil {
        let owners = Set(try historyRowsUnlocked("SELECT DISTINCT device_id FROM paired_conversation_owners", values: []).compactMap { $0.objectValue?["device_id"]?.stringValue })
        try executeUnlocked("UPDATE paired_library_clock SET applying=1 WHERE singleton=1")
        try projectPairedConversationOwners(.init(conversations: [], owners: owners))
        try executeUnlocked("UPDATE paired_library_clock SET applying=0 WHERE singleton=1")
        try setPairedStateUnlocked("projection.v2", "1")
      }
      if try pairedStateUnlocked("frontier.v2") == nil {
        try recomputeFrontiersUnlocked()
        try setPairedStateUnlocked("frontier.v2", "1")
      }
    }
  }

  func pairedStateUnlocked(_ name: String) throws -> String? {
    try historyRowsUnlocked("SELECT value FROM paired_library_state WHERE name=?", values: [name]).first?.objectValue?["value"]?.stringValue
  }
  func setPairedStateUnlocked(_ name: String, _ value: String?) throws {
    if let value { try toolsExecuteUnlocked("INSERT INTO paired_library_state VALUES(?,?) ON CONFLICT(name) DO UPDATE SET value=excluded.value", [name, value]) }
    else { try toolsExecuteUnlocked("DELETE FROM paired_library_state WHERE name=?", [name]) }
  }
  private func peerVersion(_ record: PairedLibraryRecord) throws -> String {
    SHA256.hash(data: Data(try peerJSON(record.vector).utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func decodePeerRecord(_ payload: String) throws -> PairedLibraryRecord {
    try JSONDecoder().decode(PairedLibraryRecord.self, from: Data(payload.utf8))
  }
  private func pairedWinnerUnlocked(table: String, key: String) throws -> PairedLibraryRecord? {
    try historyRowsUnlocked("SELECT payload FROM paired_library_rows WHERE table_name=? AND record_key=?", values: [table, key])
      .first?.objectValue?["payload"]?.stringValue.map(decodePeerRecord)
  }

  private func capturePayload(_ table: PeerTable, row: String, deleted: Bool) -> String {
    func field(_ name: String) -> String { row + "." + Self.peerQuote(name) }
    let key = "json_array(" + table.keys.map(field).joined(separator: ",") + ")"
    let fields = table.columns.flatMap { column -> [String] in
      let value = field(column)
      return ["'\(column)'", "json_object('type',typeof(\(value)),'value',CASE WHEN typeof(\(value))='blob' THEN hex(\(value)) WHEN typeof(\(value))='real' THEN printf('%!.17g',\(value)) ELSE CAST(\(value) AS TEXT) || '' END)"]
    }.joined(separator: ",")
    let tombstone = deleted ? "json('true')" : table.columns.contains("deleted_at") ? "json(CASE WHEN \(field("deleted_at")) IS NOT NULL THEN 'true' ELSE 'false' END)" : table.columns.contains("deleted") ? "json(CASE WHEN \(field("deleted"))<>0 THEN 'true' ELSE 'false' END)" : "json('false')"
    return "json_object('table','\(table.name)','key',printf('%s',\(key)),'row',json_object(\(fields)),'deleted',\(tombstone),'clock',(SELECT tick FROM paired_library_clock),'origin',(SELECT device_id FROM paired_library_clock),'vector',json((SELECT vector FROM paired_library_clock)))"
  }

  /// The execution owner republishes its native row as a new local version
  /// after declining a stale observed one, so every Mac converges on it.
  private func reassertLocalRowsUnlocked(_ tables: [String: PeerTable]) throws {
    for item in try historyRowsUnlocked("SELECT table_name,record_key FROM paired_library_reassert", values: []) {
      guard let name = item.objectValue?["table_name"]?.stringValue, let key = item.objectValue?["record_key"]?.stringValue,
            let table = tables[name] else { continue }
      let match = "json_array(" + table.keys.map { "s." + Self.peerQuote($0) }.joined(separator: ",") + ")=?"
      guard try historyRowsUnlocked("SELECT 1 AS present FROM \(Self.peerQuote(name)) s WHERE \(match)", values: [key]).isEmpty == false else { continue }
      try executeUnlocked(#"UPDATE paired_library_clock SET tick=tick+1,vector=json_set(vector,'$."' || device_id || '"',tick+1) WHERE singleton=1"#)
      guard let payload = try historyRowsUnlocked("SELECT \(capturePayload(table, row: "s", deleted: false)) AS payload FROM \(Self.peerQuote(name)) s WHERE \(match)", values: [key])
        .first?.objectValue?["payload"]?.stringValue else { continue }
      try toolsExecuteUnlocked("INSERT INTO paired_library_changes(payload) VALUES(?)", [payload])
      try toolsExecuteUnlocked("INSERT INTO paired_library_rows VALUES(?,?,?) ON CONFLICT(table_name,record_key) DO UPDATE SET payload=excluded.payload", [name, key, payload])
      try toolsExecuteUnlocked("DELETE FROM paired_library_frontier WHERE table_name=? AND record_key=?", [name, key])
    }
    try executeUnlocked("DELETE FROM paired_library_reassert")
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
    // A local write causally supersedes every version this Mac has applied,
    // so its retained concurrent versions for that identity are obsolete.
    let collapse = source.isEmpty ? "DELETE FROM paired_library_frontier WHERE table_name='\(table.name)' AND record_key=printf('%s',\(key));" : ""
    return """
      \(collapse)
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

  /// The page and its receive cursor commit together. Records merge through a
  /// durable causal frontier, so arrival order, exact retries and restarts all
  /// converge on the same winner without executing a command or creating a
  /// second conflict/recovery copy.
  func receivePairedLibrary(_ page: PairedLibraryPage, from peer: String) throws {
    guard UUID(uuidString: peer) != nil, page.entries.count <= 100, page.cursor >= 0,
          page.schema == (try peerSchema()) else { throw peerError("Update both Macs to the same Woven Matter version before synchronizing.") }
    try applyPeerRecords(page.entries.map { ($0, nil) }, from: peer, cursor: page.cursor, completesBaseline: !page.hasMore)
  }

  private struct PeerRecordRejected: Error { let message: String }
  private struct ProjectionScope { var conversations = Set<String>(); var owners = Set<String>() }

  private func applyPeerRecords(_ entries: [(record: PairedLibraryRecord, pendingID: String?)], from peer: String,
                                cursor: Int64?, completesBaseline: Bool = false) throws {
    let tables = Dictionary(uniqueKeysWithValues: try peerTables().map { ($0.name, $0) })
    // Foreign references can arrive in the next bounded page. Preserve them;
    // do not let a transient missing parent discard an offline child edit.
    try executeUnlocked("PRAGMA foreign_keys=OFF")
    defer { try? executeUnlocked("PRAGMA foreign_keys=ON") }
    try transaction {
      try executeUnlocked("UPDATE paired_library_clock SET applying=1 WHERE singleton=1")
      var vector = try JSONDecoder().decode([String: Int64].self, from: Data(historyRowsUnlocked("SELECT vector FROM paired_library_clock", values: []).first!.objectValue!["vector"]!.stringValue!.utf8))
      var scope = ProjectionScope()
      for (received, pendingID) in entries {
        let record: PairedLibraryRecord, table: PeerTable
        // Each record applies inside its own savepoint, so a deterministic
        // rejection discovered mid-materialization leaves no partial change.
        try executeUnlocked("SAVEPOINT paired_record")
        do {
          guard let hydrated = try hydratePeerValues(received) else {
            if pendingID == nil {
              let payload = try peerJSON(received)
              let id = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
              try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_pending VALUES(?,?,?,?)", [id, payload, peer, String(cursor ?? 0)])
            }
            try executeUnlocked("RELEASE paired_record")
            continue
          }
          record = hydrated
          guard let known = tables[record.table], UUID(uuidString: record.origin) != nil,
                record.clock > 0, record.clock < Int64.max - 1,
                record.vector.count <= 4096, record.vector[record.origin] == record.clock,
                record.vector.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value > 0 && $0.value <= record.clock }),
                Set(record.row.keys) == Set(known.columns) else { throw PeerRecordRejected(message: "Invalid shared record in " + record.table + ".") }
          table = known
          try validatePeerKey(record, table: table)
          try applyPeerRecordUnlocked(record, table: table, scope: &scope)
        } catch let rejected as PeerRecordRejected {
          // One malformed record must not stall every independent resource
          // stream. It is retained durably for diagnosis and never applied.
          // Storage and database failures still abort the whole page.
          try executeUnlocked("ROLLBACK TO paired_record"); try executeUnlocked("RELEASE paired_record")
          let payload = try peerJSON(received)
          let id = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
          try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_quarantine VALUES(?,?,?,?)", [id, peer, payload, rejected.message])
          if let pendingID { try toolsExecuteUnlocked("DELETE FROM paired_library_pending WHERE id=?", [pendingID]) }
          continue
        }
        try executeUnlocked("RELEASE paired_record")
        if let pendingID { try toolsExecuteUnlocked("DELETE FROM paired_library_pending WHERE id=?", [pendingID]) }
        for (origin, tick) in record.vector { vector[origin] = max(vector[origin, default: 0], tick) }
        try toolsExecuteUnlocked("UPDATE paired_library_clock SET tick=MAX(tick,CAST(? AS INTEGER))", [String(record.clock)])
      }
      try projectPairedConversationOwners(scope)
      try toolsExecuteUnlocked("UPDATE paired_library_clock SET vector=?,applying=0", [try peerJSON(vector)])
      try reassertLocalRowsUnlocked(tables)
      if let cursor {
        try toolsExecuteUnlocked("INSERT INTO paired_library_cursors(peer_id,pulled) VALUES(?,?) ON CONFLICT(peer_id) DO UPDATE SET pulled=MAX(pulled,excluded.pulled)", [peer, String(cursor)])
        if completesBaseline { try setPairedStateUnlocked("baseline." + peer, String(cursor)) }
      }
    }
  }

  /// Keeps every causally maximal version of one identity. A dominated version
  /// is obsolete forever; the deterministic winner of the remaining concurrent
  /// versions is materialized and the losing writing stays recoverable.
  private func applyPeerRecordUnlocked(_ record: PairedLibraryRecord, table: PeerTable, scope: inout ProjectionScope) throws {
    let members = try frontierMembersUnlocked(table: record.table, key: record.key)
    if let same = members.first(where: { $0.vector == record.vector }) {
      guard same == record else { throw PeerRecordRejected(message: "A shared change identity was reused for different content.") }
      return
    }
    if members.contains(where: { $0.dominates(record) }) { return }
    try settleFrontierUnlocked(members.filter { !record.dominates($0) } + [record], table: table, scope: &scope)
    // Relay only versions that entered the frontier. Echoes and dominated
    // versions are already represented by something this Mac relays.
    try toolsExecuteUnlocked("INSERT INTO paired_library_changes(payload) VALUES(?)", [try peerJSON(record)])
  }

  /// The current winner plus retained concurrent versions, minus any version a
  /// later local or received write has causally superseded.
  private func frontierMembersUnlocked(table: String, key: String) throws -> [PairedLibraryRecord] {
    let winner = try pairedWinnerUnlocked(table: table, key: key)
    let stored = try historyRowsUnlocked("SELECT payload FROM paired_library_frontier WHERE table_name=? AND record_key=?", values: [table, key])
      .compactMap { $0.objectValue?["payload"]?.stringValue }.map(decodePeerRecord)
    return PairedLibraryRecord.frontier((winner.map { [$0] } ?? []) + stored)
  }

  /// Keeps every causally maximal version of one identity. The deterministic
  /// winner of the remaining concurrent versions is materialized and losing
  /// writing stays recoverable.
  private func settleFrontierUnlocked(_ members: [PairedLibraryRecord], table: PeerTable, scope: inout ProjectionScope) throws {
    guard let next = PairedLibraryRecord.winner(members) else { return }
    let winner = try pairedWinnerUnlocked(table: next.table, key: next.key)
    for loser in members where loser.vector != next.vector && (loser.row != next.row || loser.deleted != next.deleted) {
      try retainPeerConflict(loser)
    }
    if next.vector != winner?.vector {
      try materializePeerRecord(next, table: table)
      try toolsExecuteUnlocked("INSERT INTO paired_library_rows VALUES(?,?,?) ON CONFLICT(table_name,record_key) DO UPDATE SET payload=excluded.payload", [next.table, next.key, try peerJSON(next)])
      for name in ["dashboard_conversations", "paired_conversation_owners", "companion_execution_conversations"] where next.table == name {
        if let id = next.row["id"]?.value { scope.conversations.insert(id) }
      }
      if table.columns.contains("conversation_id"), let id = next.row["conversation_id"]?.value { scope.conversations.insert(id) }
      if next.table == "companion_execution_workspaces", let owner = next.row["owner_device_id"]?.value { scope.owners.insert(owner) }
    }
    try toolsExecuteUnlocked("DELETE FROM paired_library_frontier WHERE table_name=? AND record_key=?", [next.table, next.key])
    for member in members where member.vector != next.vector {
      try toolsExecuteUnlocked("INSERT INTO paired_library_frontier VALUES(?,?,?,?)", [member.table, member.key, try peerVersion(member), try peerJSON(member)])
    }
  }

  /// Older builds kept one arrival-order winner. Recompute the canonical winner
  /// of every retained frontier so those databases converge without a replay.
  private func recomputeFrontiersUnlocked() throws {
    let tables = Dictionary(uniqueKeysWithValues: try peerTables().map { ($0.name, $0) })
    var scope = ProjectionScope()
    try executeUnlocked("UPDATE paired_library_clock SET applying=1 WHERE singleton=1")
    for row in try historyRowsUnlocked("SELECT DISTINCT table_name,record_key FROM paired_library_frontier ORDER BY table_name,record_key", values: []) {
      guard let name = row.objectValue?["table_name"]?.stringValue, let key = row.objectValue?["record_key"]?.stringValue,
            let table = tables[name] else { continue }
      try settleFrontierUnlocked(try frontierMembersUnlocked(table: name, key: key), table: table, scope: &scope)
    }
    try projectPairedConversationOwners(scope)
    try executeUnlocked("UPDATE paired_library_clock SET applying=0 WHERE singleton=1")
    try reassertLocalRowsUnlocked(tables)
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
  /// Returns nil while referenced bytes are unavailable. A corrupt local copy
  /// is discarded so a healthy peer can supply the same content again.
  private func hydratePeerValues(_ record: PairedLibraryRecord) throws -> PairedLibraryRecord? {
    var row = record.row
    for (name, value) in row where value.type.hasPrefix("reference:") {
      guard ["reference:text", "reference:blob"].contains(value.type), let hash = value.value,
            hash.wholeMatch(of: /[0-9a-f]{64}/) != nil else { throw PeerRecordRejected(message: "Invalid large shared value.") }
      let file = libraryFiles.supportDirectory.appending(path: "paired-records/" + hash)
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      let count = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
      guard count <= 256 * 1_024 * 1_024 else { throw PeerRecordRejected(message: "Shared record exceeds its storage limit.") }
      let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
      guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash,
            let text = String(data: bytes, encoding: .utf8) else {
        try? FileManager.default.removeItem(at: file)
        return nil
      }
      row[name] = .init(type: String(value.type.dropFirst("reference:".count)), value: text)
    }
    return .init(table: record.table, key: record.key, row: row, deleted: record.deleted, clock: record.clock, origin: record.origin, vector: record.vector)
  }
  private func pendingReferencesAvailable(_ record: PairedLibraryRecord) -> Bool {
    record.row.values.allSatisfy { value in
      guard value.type.hasPrefix("reference:") else { return true }
      guard let hash = value.value, hash.wholeMatch(of: /[0-9a-f]{64}/) != nil else { return true }
      return FileManager.default.fileExists(atPath: libraryFiles.supportDirectory.appending(path: "paired-records/" + hash).path)
    }
  }
  /// Scans waiting records with a durable rotating position, so unavailable
  /// bytes at the start of the queue never starve later ready records.
  func materializePendingPeerRecords(budget: Int = 500) throws {
    var after = try pairedStateUnlocked("pending.after") ?? "", scanned = 0, wrapped = after.isEmpty
    while scanned < budget {
      let rows = try historyRowsUnlocked("SELECT id,payload,peer_id FROM paired_library_pending WHERE id>? ORDER BY id LIMIT 100", values: [after])
      if rows.isEmpty {
        if wrapped { after = ""; break }
        after = ""; wrapped = true; continue
      }
      var ready: [String: [(record: PairedLibraryRecord, pendingID: String?)]] = [:]
      for row in rows {
        guard let fields = row.objectValue, let id = fields["id"]?.stringValue, let payload = fields["payload"]?.stringValue,
              let peer = fields["peer_id"]?.stringValue else { continue }
        scanned += 1; after = id
        let record = try decodePeerRecord(payload)
        if pendingReferencesAvailable(record) { ready[peer, default: []].append((record, id)) }
      }
      for (peer, entries) in ready.sorted(by: { $0.key < $1.key }) { try applyPeerRecords(entries, from: peer, cursor: nil) }
    }
    try setPairedStateUnlocked("pending.after", after.isEmpty ? nil : after)
  }
  func pairedLibraryBaseline(_ peer: String) throws -> Bool {
    try pairedStateUnlocked("baseline." + peer) != nil
      && historyRowsUnlocked("SELECT 1 AS present FROM paired_library_pending WHERE peer_id=? LIMIT 1", values: [peer]).isEmpty
  }
  func pairedLibraryQuarantineCount() throws -> Int {
    try historyRowsUnlocked("SELECT count(*) AS count FROM paired_library_quarantine", values: []).first?.objectValue?["count"]?.intValue ?? 0
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
    "dashboard_messages", "dashboard_message_attachments", "dashboard_message_references", "dashboard_runs",
    "dashboard_run_visible_context", "dashboard_run_events", "dashboard_run_trace_events", "session_execution_roots",
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
      SELECT 1 AS owned FROM paired_conversation_owners o WHERE o.id=?1 AND o.device_id=?2
        AND NOT EXISTS(SELECT 1 FROM companion_execution_adoptions a WHERE a.conversation_id=?1)
        AND NOT EXISTS(SELECT 1 FROM retained_execution_history r WHERE r.conversation_id=?1)
        AND NOT EXISTS(SELECT 1 FROM companion_execution_conversations x WHERE x.id=?1 AND NOT EXISTS(
          SELECT 1 FROM companion_execution_workspaces w WHERE w.id=x.workspace_id AND json_extract(CAST(w.payload AS TEXT),'$.kind')='mac'))
      """, values: [conversation, local]).isEmpty == false
  }

  /// The owner's own trash check: running, uncertain or pending native work.
  private func conversationBusyUnlocked(_ id: String) throws -> Bool {
    try historyRowsUnlocked("""
      SELECT 1 AS busy FROM dashboard_runs WHERE conversation_id=?1 AND status IN ('queued','accepted','running','uncertain')
      UNION ALL SELECT 1 FROM desktop_opencode_sessions WHERE conversation_id=?1 AND json_extract(snapshot_json,'$.active')=1
      UNION ALL SELECT 1 FROM desktop_opencode_submissions WHERE conversation_id=?1 AND status IN ('sending','uncertain') LIMIT 1
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
    if table.name == "dashboard_conversations" { conversation = record.row["id"]?.value }
    else if Self.ownerRuntimeTables.contains(table.name) { conversation = record.row["conversation_id"]?.value }
    else { return record }
    guard let conversation,
          let local = try historyRowsUnlocked("SELECT device_id FROM paired_library_clock WHERE singleton=1", values: []).first?.objectValue?["device_id"]?.stringValue,
          record.origin != local, try executesNativelyUnlocked(conversation, local: local) else { return record }
    let match = "json_array(" + table.keys.map { "s." + Self.peerQuote($0) }.joined(separator: ",") + ")=?"
    guard let current = try historyRowsUnlocked("SELECT \(capturePayload(table, row: "s", deleted: false)) AS payload FROM \(Self.peerQuote(table.name)) s WHERE \(match)", values: [record.key])
      .first?.objectValue?["payload"]?.stringValue.map(decodePeerRecord) else { return record }
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_reassert VALUES(?,?)", [table.name, record.key])
    // Only the owner removes its native rows.
    guard table.name == "dashboard_conversations", !(record.deleted && record.row["deleted_at"]?.value == nil) else { return nil }
    var row = current.row
    for column in Self.sharedConversationColumns { if let value = record.row[column] { row[column] = value } }
    let requested = record.row["deleted_at"]?.value, existing = current.row["deleted_at"]?.value
    if let requested, existing == nil {
      if try !conversationBusyUnlocked(conversation) {
        row["deleted_at"] = .init(type: "text", value: requested)
        row["original_folder_id"] = current.row["folder_id"] ?? .init(type: "null")
        try applyOwnerTrashEffectsUnlocked(conversation)
      }
    } else if requested == nil, existing != nil {
      row["deleted_at"] = .init(type: "null")
      row["folder_id"] = current.row["original_folder_id"] ?? .init(type: "null")
      row["original_folder_id"] = .init(type: "null")
    }
    return .init(table: record.table, key: record.key, row: row, deleted: row["deleted_at"]?.value != nil, clock: record.clock, origin: record.origin, vector: record.vector)
  }

  /// The owner's trash effects for an accepted remote trash request: pause an
  /// active goal with the owner's own run sequence, stop timers and cancel
  /// queued deliveries. The owner republishes its goal.
  private func applyOwnerTrashEffectsUnlocked(_ id: String) throws {
    if var goal = try goalUnlocked(id), goal.status == .active {
      try captureGoalRunsUnlocked(&goal)
      try cancelQueuedGoalDeliveryUnlocked(goal)
      goal.status = .paused; goal.evidence = "This conversation was moved to Trash. Resume to continue."
      try saveGoalUnlocked(goal)
      try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_reassert VALUES('workspace_session_goals',?)", [try peerJSON([id])])
    }
    try toolsExecuteUnlocked("UPDATE workspace_session_timers SET is_paused=1,pending_delivery_id=NULL WHERE session_id=?", [id])
    try toolsExecuteUnlocked("""
      UPDATE workspace_session_deliveries SET status='cancelled' WHERE (target_id=? OR source_id=?)
        AND (status='queued' OR (status='sending' AND transport_started=0))
      """, [id, id])
  }

  /// A rename stored as a title override applies whichever of the override or
  /// the conversation row arrives last, on every Mac, across restarts.
  private func applyTitleOverrideUnlocked(_ id: String) throws {
    try toolsExecuteUnlocked("""
      UPDATE dashboard_conversations SET title=(SELECT title FROM desktop_conversation_titles WHERE conversation_id=?1)
      WHERE id=?1 AND EXISTS(SELECT 1 FROM desktop_conversation_titles WHERE conversation_id=?1)
        AND title IS NOT (SELECT title FROM desktop_conversation_titles WHERE conversation_id=?1)
      """, [id])
  }

  private func materializePeerRecord(_ incoming: PairedLibraryRecord, table: PeerTable, recoverConstraint: Bool = true) throws {
    guard let record = try preservingOwnerNativeRow(incoming, table: table) else { return }
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
      if !hardDelete, table.name == "workspace_tool_settings", name == "value" { value = try preservingLocalExposure(value, record: record, table: table) }
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
    if table.name == "dashboard_conversations", let id = record.row["id"]?.value { try applyTitleOverrideUnlocked(id) }
    if table.name == "desktop_conversation_titles", let id = record.row["conversation_id"]?.value { try applyTitleOverrideUnlocked(id) }
  }

  /// Network exposure is a property of one Mac. Shared tool choices synchronize,
  /// while this Mac's outside MCP policy is never enabled or replaced by a peer.
  private func preservingLocalExposure(_ value: PairedLibraryValue, record: PairedLibraryRecord, table: PeerTable) throws -> PairedLibraryValue {
    guard value.type == "text", let incoming = value.value,
          var settings = try JSONSerialization.jsonObject(with: Data(incoming.utf8)) as? [String: Any] else { return value }
    let match = table.keys.map { Self.peerQuote($0) + " IS ?" }.joined(separator: " AND ")
    let query = try prepareUnlocked("SELECT value FROM \(Self.peerQuote(table.name)) WHERE \(match)")
    defer { sqlite3_finalize(query) }
    for (index, key) in table.keys.enumerated() { try bindPeer(record.row[key]!, query, Int32(index + 1)) }
    let local = sqlite3_step(query) == SQLITE_ROW ? optionalText(query, column: 0) : nil
    let localSettings = try local.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    if let exposure = localSettings?["externalMCP"] { settings["externalMCP"] = exposure } else { settings.removeValue(forKey: "externalMCP") }
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
    return .init(type: "text", value: String(decoding: data, as: UTF8.self))
  }

  /// Projects only conversations touched by this receive. Unchanged foreign
  /// transcripts are not rewritten on every bounded synchronization turn.
  private func projectPairedConversationOwners(_ scope: ProjectionScope) throws {
    guard !scope.conversations.isEmpty || !scope.owners.isEmpty else { return }
    let localID = try companionLibraryIdentityUnlocked().hostDeviceID
    let workspaces = try companionExecutionWorkspaces()
    let rows = try historyRowsUnlocked("""
      SELECT id,device_id FROM paired_conversation_owners
      WHERE id IN (SELECT value FROM json_each(?)) OR device_id IN (SELECT value FROM json_each(?))
      """, values: [try peerJSON(scope.conversations.sorted()), try peerJSON(scope.owners.sorted())])
    // A projection onto a Mac workspace is synthetic paired-Mac routing and is
    // rebuilt from the authoritative owner record, which also repairs routing an
    // earlier build guessed from an edit's origin. Independent Linux and iOS
    // execution projections are never replaced.
    let macWorkspaces = Set(workspaces.filter { $0.kind == .mac }.map(\.id))
    for row in rows {
      guard let id = row.objectValue?["id"]?.stringValue, let owner = row.objectValue?["device_id"]?.stringValue else { continue }
      let current = try historyRowsUnlocked("SELECT workspace_id FROM companion_execution_conversations WHERE id=?", values: [id]).first?.objectValue?["workspace_id"]?.stringValue
      if let current, !macWorkspaces.contains(current) { continue }
      if owner == localID {
        if current != nil { try toolsExecuteUnlocked("DELETE FROM companion_execution_conversations WHERE id=?", [id]) }
        continue
      }
      guard let workspace = workspaces.first(where: { $0.kind == .mac && $0.ownerDeviceID == owner && !$0.deleted }),
            let conversation = try companionConversationUnlocked(id: id) else { continue }
      var projected = conversation; projected.workspaceID = workspace.id; projected.libraryID = workspace.libraryID
      if let current = try historyRowsUnlocked("SELECT title,folder_id,is_pinned FROM dashboard_conversations WHERE id=?", values: [id]).first?.objectValue {
        projected.title = current["title"]?.stringValue ?? projected.title
        projected.folderID = current["folder_id"]?.stringValue
        projected.isPinned = current["is_pinned"]?.doubleValue == 1
      }
      let transcript = try federationLegacyTranscriptUnlocked(id)
      let query = try prepareUnlocked("INSERT INTO companion_execution_conversations(id,workspace_id,conversation,transcript) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET workspace_id=excluded.workspace_id,conversation=excluded.conversation,transcript=excluded.transcript")
      defer { sqlite3_finalize(query) }
      try bind(id, at: 1, to: query); try bind(workspace.id, at: 2, to: query)
      try bind(JSONEncoder().encode(projected), at: 3, to: query); try bind(JSONEncoder().encode(transcript), at: 4, to: query); try stepDone(query)
    }
  }

  private func retainPeerConflict(_ record: PairedLibraryRecord, recoverCopy: Bool = true) throws {
    let payload = try peerJSON(record)
    let id = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    try toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_library_conflicts VALUES(?,?)", [id, payload])
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
    let copy = PairedLibraryRecord(table: "notes", key: try peerJSON([copyID]), row: row, deleted: false, clock: record.clock, origin: record.origin, vector: record.vector)
    // Every Mac derives the same copy; one received from a peer is not recreated.
    if try pairedWinnerUnlocked(table: copy.table, key: copy.key) == nil,
       let table = try peerTables().first(where: { $0.name == "notes" }) {
      try materializePeerRecord(copy, table: table, recoverConstraint: false)
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
  public func pairedLibraryFileCursor(_ peer: String) async throws -> String {
    try await read { try $0.historyRowsUnlocked("SELECT cursor FROM paired_library_file_cursors WHERE peer_id=?", values: [peer]).first?.objectValue?["cursor"]?.stringValue ?? "" }
  }
  public func savePairedLibraryFileCursor(_ cursor: String, peer: String) async throws {
    try await write { try $0.toolsExecuteUnlocked("INSERT INTO paired_library_file_cursors VALUES(?,?) ON CONFLICT(peer_id) DO UPDATE SET cursor=excluded.cursor", [peer, cursor]) }
  }
  public func materializePendingPeerRecords() async throws { try await write { try $0.materializePendingPeerRecords() } }
  public func pairedLibraryPage(after cursor: Int64) async throws -> PairedLibraryPage { try await read { try $0.pairedLibraryPage(after: cursor) } }
  public func receivePairedLibrary(_ page: PairedLibraryPage, from peer: String) async throws { try await write { try $0.receivePairedLibrary(page, from: peer) } }
  public func pairedLibraryCursors(_ peer: String) async throws -> (pulled: Int64, pushed: Int64) { try await read { try $0.pairedLibraryCursors(peer) } }
  public func acknowledgePairedLibrary(peer: String, cursor: Int64) async throws {
    try await write { try $0.toolsExecuteUnlocked("INSERT INTO paired_library_cursors(peer_id,pushed) VALUES(?,?) ON CONFLICT(peer_id) DO UPDATE SET pushed=MAX(pushed,excluded.pushed)", [peer, String(cursor)]) }
  }
  public func pairedLibraryConflicts() async throws -> [PairedLibraryConflict] { try await read { try $0.pairedLibraryConflicts() } }
  public func pairedLibraryQuarantineCount() async throws -> Int { try await read { try $0.pairedLibraryQuarantineCount() } }
  /// True after this Mac durably received the peer's complete journal up to a
  /// page without more records, with no bytes from that peer still waiting.
  public func pairedLibraryBaseline(_ peer: String) async throws -> Bool { try await read { try $0.pairedLibraryBaseline(peer) } }
}

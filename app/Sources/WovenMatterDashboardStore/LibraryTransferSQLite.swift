import CryptoKit
import Foundation
import SQLite3
import WovenMatterCore

/// Only app-generated snapshots with the same table graph can be merged. The
/// incoming database is read-only and never supplies executable schema to main.
public enum LibraryTransferSQLite {
  public struct MergeResult: Codable, Equatable, Sendable {
    public var importedRows = 0
    public var recoveredItems = 0
    public var retainedConflicts = 0
    public init() {}
  }
  enum Value: Codable, Equatable, Sendable {
    case null, integer(Int64), real(Double), text(String), blob(Data)
    var string: String? { if case .text(let value) = self { value } else { nil } }
  }
  struct Column: Equatable { let name: String; let type: String; let primary: Int32 }
  static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
  static func error(_ db: OpaquePointer) -> WorkspaceDatabaseError { .execute(String(cString: sqlite3_errmsg(db))) }
  static func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db) }
  }
  static func open(_ url: URL, readOnly: Bool) throws -> OpaquePointer {
    var pointer: OpaquePointer?
    let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &pointer, flags, nil) == SQLITE_OK, let pointer else {
      if let pointer { sqlite3_close(pointer) }
      throw WorkspaceDatabaseError.open("Could not open the database transfer snapshot")
    }
    sqlite3_busy_timeout(pointer, 5000)
    return pointer
  }
  static func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var value: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw error(db) }
    return value
  }
  static func value(_ row: OpaquePointer, _ column: Int32) -> Value {
    switch sqlite3_column_type(row, column) {
    case SQLITE_INTEGER: .integer(sqlite3_column_int64(row, column))
    case SQLITE_FLOAT: .real(sqlite3_column_double(row, column))
    case SQLITE_TEXT:
      .text(String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(row, column), count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self))
    case SQLITE_BLOB:
      .blob(sqlite3_column_blob(row, column).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(row, column))) } ?? Data())
    default: .null
    }
  }
  static func bind(_ value: Value, to statement: OpaquePointer, at index: Int32) throws {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let result: Int32
    switch value {
    case .null: result = sqlite3_bind_null(statement, index)
    case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
    case .real(let value): result = sqlite3_bind_double(statement, index, value)
    case .text(let value): result = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
    case .blob(let value):
      result = value.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0)
        : value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
    }
    guard result == SQLITE_OK else { throw WorkspaceDatabaseError.bind("Could not bind a transferred value") }
  }
  static func columns(_ db: OpaquePointer, table: String) throws -> [Column] {
    let query = try statement(db, "PRAGMA table_info(\(quoted(table)))"); defer { sqlite3_finalize(query) }
    var columns: [Column] = []
    while sqlite3_step(query) == SQLITE_ROW {
      columns.append(.init(name: value(query, 1).string!, type: value(query, 2).string!, primary: sqlite3_column_int(query, 5)))
    }
    return columns
  }
  public static func verify(_ url: URL) throws {
    do {
    let db = try open(url, readOnly: true); defer { sqlite3_close(db) }
    let check = try statement(db, "PRAGMA integrity_check"); defer { sqlite3_finalize(check) }
    guard sqlite3_step(check) == SQLITE_ROW, value(check, 0) == .text("ok"), sqlite3_step(check) == SQLITE_DONE else {
      throw WorkspaceDatabaseError.execute("The database transfer snapshot did not pass its integrity check")
    }
    } catch { throw WorkspaceDatabaseError.execute("Snapshot integrity (\(url.lastPathComponent)): \(error)") }
  }
  static func copy(_ source: OpaquePointer, into destination: OpaquePointer) throws {
    guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw WorkspaceDatabaseError.execute("Database snapshot initialization: " + String(cString: sqlite3_errmsg(destination))) }
    let status = sqlite3_backup_step(backup, -1)
    let message = String(cString: sqlite3_errmsg(destination))
    let finish = sqlite3_backup_finish(backup)
    guard status == SQLITE_DONE, finish == SQLITE_OK else { throw WorkspaceDatabaseError.execute("Database snapshot copy (\(status), \(finish)): " + message) }
  }
  static func backup(_ source: OpaquePointer, to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceDatabaseError.execute("A transfer backup already exists at this path") }
    let destination = try open(url, readOnly: false)
    do {
      try copy(source, into: destination)
      // The transfer unit is one independently readable SQLite file. Close its
      // writer and checkpoint any WAL before opening the verifier or hashing it.
      try execute(destination, "PRAGMA journal_mode=DELETE")
      guard sqlite3_close(destination) == SQLITE_OK else { throw WorkspaceDatabaseError.execute("Could not close the completed snapshot") }
    } catch { sqlite3_close(destination); throw error }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try verify(url)
  }
  static func restore(_ url: URL, into destination: OpaquePointer) throws {
    try verify(url)
    let source = try open(url, readOnly: true); defer { sqlite3_close(source) }
    try copy(source, into: destination)
  }
  public static func snapshot(_ source: URL, to destination: URL) throws {
    let db = try open(source, readOnly: true); defer { sqlite3_close(db) }
    try backup(db, to: destination)
  }
  public static func identity(_ source: URL) throws -> CompanionLibraryIdentity {
    let db = try open(source, readOnly: true); defer { sqlite3_close(db) }
    let query = try statement(db, "SELECT workspace_id,host_device_id FROM companion_workspace CROSS JOIN companion_library_identity WHERE companion_workspace.singleton=1 AND companion_library_identity.singleton=1")
    defer { sqlite3_finalize(query) }
    guard sqlite3_step(query) == SQLITE_ROW, let library = value(query, 0).string,
          let host = value(query, 1).string, UUID(uuidString: library) != nil, UUID(uuidString: host) != nil else {
      throw WorkspaceDatabaseError.execute("The source snapshot has no valid library identity")
    }
    return .init(libraryID: library, hostDeviceID: host)
  }

  /// The destination is a private staging copy, never a serving database. All
  /// conflicts retain the exact incoming row. User content also gets a visible
  /// recovery copy, so choosing the destination never silently discards writing.
  public static func merge(source: URL, into destination: URL, transferID: String,
                           sourceLibraryID: String, destinationLibraryID: String) throws -> MergeResult {
    try verify(source); try verify(destination)
    let sourceHost = try identity(source).hostDeviceID
    let incoming = try open(source, readOnly: true); defer { sqlite3_close(incoming) }
    let db = try open(destination, readOnly: false); defer { sqlite3_close(db) }
    try WorkspaceSQLiteTextFunctions.register(on: db)
    let query = try statement(incoming, "SELECT name,sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    defer { sqlite3_finalize(query) }
    var tables: [(String, String)] = []
    while sqlite3_step(query) == SQLITE_ROW { tables.append((value(query, 0).string!, value(query, 1).string ?? "")) }
    // Never import FTS shadow tables, schema identities, device runtime state or
    // disposable projections. Exact original bytes remain in the retained backup.
    let excluded: Set<String> = ["companion_workspace", "companion_library_identity", "companion_changes",
      "desktop_local_identity", "desktop_local_acp_sessions", "desktop_local_acp_durable_runs",
      "desktop_opencode_sessions", "desktop_opencode_submissions", "desktop_openclaw_gateway_links",
      "desktop_openclaw_gateway_sessions", "desktop_openclaw_cron_jobs", "desktop_openclaw_cron_runs",
      "session_scratch_directories", "execution_workspace_defaults", "desktop_dashboard_revision",
      "desktop_activity_revision", "desktop_activity_index", "desktop_activity_index_schema",
      "desktop_message_revisions", "companion_execution_replica_context", "companion_calendar_execution_context",
      "workspace_executor_sessions", "workspace_automation_requests", "workspace_automation_cancellations",
      "workspace_session_creations", "workspace_coordination_access_requests", "product_analytics_limits"]
    let allowed = tables.filter { name, sql in
      !excluded.contains(name) && !name.hasPrefix("workspace_history_search") && (!name.hasPrefix("library_transfer_") || ["library_transfer_conflicts", "library_transfer_runtime_owners"].contains(name))
        && !sql.uppercased().contains("VIRTUAL TABLE")
    }
    // Validate every table before any import. Unknown/new schema cannot cause a
    // successful-looking partial migration, even if its table happens to be empty.
    for (table, _) in allowed {
      guard try columns(incoming, table: table) == columns(db, table: table) else {
        throw CompanionAPIError(code: "transfer_version", message: "Update both Macs to the same Woven Matter version before merging their databases.")
      }
    }
    try execute(db, "PRAGMA foreign_keys=OFF")
    try execute(db, "BEGIN IMMEDIATE")
    do {
      try execute(db, "CREATE TABLE IF NOT EXISTS library_transfer_conflicts(transfer_id TEXT NOT NULL, table_name TEXT NOT NULL, identity TEXT NOT NULL, incoming BLOB NOT NULL, PRIMARY KEY(transfer_id,table_name,identity))")
      try execute(db, "CREATE TABLE IF NOT EXISTS library_transfer_imports(id TEXT PRIMARY KEY,result BLOB NOT NULL)")
      let prior = try statement(db, "SELECT result FROM library_transfer_imports WHERE id=?"); defer { sqlite3_finalize(prior) }
      try bind(.text(transferID), to: prior, at: 1)
      if sqlite3_step(prior) == SQLITE_ROW, case .blob(let bytes) = value(prior, 0) {
        let result = try JSONDecoder().decode(MergeResult.self, from: bytes)
        try execute(db, "ROLLBACK"); return result
      }
      let operatorQuery = try statement(db, "SELECT user_id FROM dashboard_conversations WHERE user_id<>'' UNION SELECT user_id FROM notes WHERE user_id<>'' UNION SELECT id FROM profiles LIMIT 1")
      defer { sqlite3_finalize(operatorQuery) }
      let operatorID = sqlite3_step(operatorQuery) == SQLITE_ROW ? value(operatorQuery, 0).string : nil
      var deletedResources = Set<String>()
      for connection in [incoming, db] {
        let deleted = try statement(connection, "SELECT kind,resource_id FROM companion_versions WHERE deleted=1 AND kind IN('note','folder')")
        defer { sqlite3_finalize(deleted) }
        while sqlite3_step(deleted) == SQLITE_ROW { deletedResources.insert(value(deleted, 0).string! + ":" + value(deleted, 1).string!) }
        let calendar = try statement(connection, "SELECT id FROM dashboard_calendar_items WHERE deleted_at IS NOT NULL")
        defer { sqlite3_finalize(calendar) }
        while sqlite3_step(calendar) == SQLITE_ROW { deletedResources.insert("calendar:" + value(calendar, 0).string!) }
      }
      var result = MergeResult()
      var noteCopies: [String: String] = [:]
      var folderCopies: [String: String] = [:]
      var artifactCopies: [String: String] = [:]
      let immutable = Set(["companion_execution_journal", "companion_retained_settlements", "companion_command_receipts", "companion_mutation_receipts", "companion_execution_receipts", "companion_native_history_parts", "companion_artifact_chunks"])
      // Folder/note recovery identities must be known before dependent rows.
      let ordered = allowed.sorted { a, b in
        func rank(_ name: String) -> Int { ["profiles", "companion_versions", "folders", "notes", "dashboard_calendar_items", "companion_saved_artifacts", "companion_artifact_uploads", "companion_artifact_chunks"].firstIndex(of: name) ?? 10 }
        return rank(a.0) == rank(b.0) ? a.0 < b.0 : rank(a.0) < rank(b.0)
      }
      for (table, sql) in ordered {
        let schema = try columns(db, table: table)
        let generated = sql.uppercased().contains("AUTOINCREMENT") ? schema.first(where: { $0.primary == 1 && $0.type.uppercased() == "INTEGER" })?.name : nil
        let selected = schema.filter { $0.name != generated }
        let names = selected.map(\.name)
        let primary = schema.filter { $0.primary > 0 && $0.name != generated }.sorted { $0.primary < $1.primary }.map(\.name)
        let natural = primary.isEmpty && names.contains("id") ? ["id"] : primary.isEmpty && names.contains("event_id") ? ["event_id"] : primary
        let read = try statement(incoming, "SELECT \(names.map(quoted).joined(separator: ",")) FROM \(quoted(table))")
        defer { sqlite3_finalize(read) }
        while true {
          let status = sqlite3_step(read)
          if status == SQLITE_DONE { break }
          guard status == SQLITE_ROW else { throw error(incoming) }
          let original = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, value(read, Int32($0.offset))) })
          var row = original
          if let operatorID, row["user_id"] != nil { row["user_id"] = .text(operatorID) }
          if let folder = row["folder_id"]?.string, let copy = folderCopies[folder] { row["folder_id"] = .text(copy) }
          if let note = row["note_id"]?.string, let copy = noteCopies[note] {
            row["note_id"] = .text(copy)
            if table == "note_asset_versions", let version = row["id"]?.string { row["id"] = .text(recoveryID(transferID: transferID, table: table, id: version)) }
          }
          for name in table == "companion_artifact_chunks" ? ["artifact_id"] : table == "companion_artifact_uploads" ? ["id"] : [] {
            if let id = row[name]?.string, let copy = artifactCopies[id] {
              row[name] = .text(copy)
              if case .blob(let bytes) = row["manifest"] {
                var manifest = try JSONDecoder().decode(CompanionArtifactManifest.self, from: bytes)
                manifest.id = copy; row["manifest"] = .blob(try JSONEncoder().encode(manifest))
              }
            }
          }
          if ["companion_execution_workspaces", "companion_workspace_publishers", "companion_workspace_publisher_aliases", "companion_workspace_mcp_aliases", "companion_execution_conversations", "companion_workspace_mcp_grants", "companion_execution_journal", "companion_execution_receipts"].contains(table) {
            for name in ["payload", "conversation", "transcript"] {
              if case .blob(let bytes) = row[name], let rewritten = try? CompanionLibraryJSON.rewrite(bytes, from: sourceLibraryID, to: destinationLibraryID) { row[name] = .blob(rewritten) }
            }
          }
          if table == "companion_execution_journal", case .blob(let bytes) = row["payload"] {
            let entry = try JSONDecoder().decode(CompanionJournalEntry.self, from: bytes)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            row["fingerprint"] = .blob(Data(SHA256.hash(data: try encoder.encode(entry))))
          }
          var existing: [String: Value]?
          if !natural.isEmpty {
            let lookup = try statement(db, "SELECT \(names.map(quoted).joined(separator: ",")) FROM \(quoted(table)) WHERE \(natural.map { quoted($0) + " IS ?" }.joined(separator: " AND "))")
            defer { sqlite3_finalize(lookup) }
            for (index, name) in natural.enumerated() { try bind(row[name] ?? .null, to: lookup, at: Int32(index + 1)) }
            if sqlite3_step(lookup) == SQLITE_ROW { existing = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, value(lookup, Int32($0.offset))) }) }
          }
          if existing == row { continue }
          if existing != nil, table == "companion_versions" {
            let revision = try statement(db, "UPDATE companion_versions SET revision=MAX(revision,?),deleted=MAX(deleted,?) WHERE kind=? AND resource_id=?")
            defer { sqlite3_finalize(revision) }
            for (index, field) in ["revision", "deleted", "kind", "resource_id"].enumerated() { try bind(row[field]!, to: revision, at: Int32(index + 1)) }
            guard sqlite3_step(revision) == SQLITE_DONE else { throw error(db) }
            continue
          }
          if let existing, table == "notes", ["title", "content", "folder_id", "deleted_at"].allSatisfy({ existing[$0] == row[$0] }) { continue }
          if let existing, table == "folders", ["name", "icon"].allSatisfy({ existing[$0] == row[$0] }) { continue }
          if existing != nil {
            if immutable.contains(table) {
              throw CompanionAPIError(code: "transfer_event_conflict", message: "The libraries disagree about an immutable event or accepted operation. The handoff stopped safely; both original databases are retained.")
            }
            if table == "companion_saved_artifacts", let id = row["id"]?.string, case .blob(let bytes) = row["manifest"] {
              let copy = recoveryID(transferID: transferID, table: table, id: id)
              var manifest = try JSONDecoder().decode(CompanionArtifactManifest.self, from: bytes)
              manifest.id = copy; manifest.title += " (recovered from other Mac)"
              row["id"] = .text(copy); row["manifest"] = .blob(try JSONEncoder().encode(manifest))
              try insert(db, table: table, row: row); artifactCopies[id] = copy; result.recoveredItems += 1; continue
            }
            if ["companion_workspace_publishers", "companion_workspace_mcp_grants"].contains(table) {
              let aliases = table == "companion_workspace_publishers" ? "companion_workspace_publisher_aliases" : "companion_workspace_mcp_aliases"
              try insert(db, table: aliases, row: row); result.importedRows += 1; continue
            }
            if table == "companion_workspace_access", row["enabled"] == .integer(0) {
              let update = try statement(db, "UPDATE companion_workspace_access SET enabled=0 WHERE device_id=? AND workspace_id=?")
              defer { sqlite3_finalize(update) }; try bind(row["device_id"]!, to: update, at: 1); try bind(row["workspace_id"]!, to: update, at: 2)
              guard sqlite3_step(update) == SQLITE_DONE else { throw error(db) }
            }
            let identity = natural.map { String(describing: original[$0]!) }.joined(separator: ":")
            try insert(db, table: "library_transfer_conflicts", row: ["transfer_id": .text(transferID), "table_name": .text(table), "identity": .text(identity), "incoming": .blob(try JSONEncoder().encode(original))])
            result.retainedConflicts += 1
            if ["notes", "folders", "dashboard_calendar_items"].contains(table), let oldID = row["id"]?.string {
              let copyID = recoveryID(transferID: transferID, table: table, id: oldID)
              row["id"] = .text(copyID)
              for field in ["title", "name"] { if let title = row[field]?.string { row[field] = .text(title + " (recovered from other Mac)") } }
              // A recovered schedule is data for review, never a new execution.
              if table == "dashboard_calendar_items" { row["next_fire_at"] = .null }
              if table == "notes", row["deleted_at"] != .null, existing?["deleted_at"] == .null, var live = existing {
                live["id"] = .text(recoveryID(transferID: transferID, table: "live-before-delete", id: oldID))
                if let title = live["title"]?.string { live["title"] = .text(title + " (recovered before deletion)") }
                try insert(db, table: table, row: live); result.recoveredItems += 1
                let deleted = try statement(db, "UPDATE notes SET deleted_at=?,updated_at=? WHERE id=?")
                defer { sqlite3_finalize(deleted) }; try bind(row["deleted_at"]!, to: deleted, at: 1)
                try bind(row["updated_at"]!, to: deleted, at: 2); try bind(.text(oldID), to: deleted, at: 3)
                guard sqlite3_step(deleted) == SQLITE_DONE else { throw error(db) }
              }
              try insert(db, table: table, row: row)
              if table == "notes" { noteCopies[oldID] = copyID }
              if table == "folders" { folderCopies[oldID] = copyID }
              result.recoveredItems += 1
              if table == "notes" {
                let sourceRevision = try statement(incoming, "SELECT revision FROM companion_versions WHERE kind='note' AND resource_id=?")
                defer { sqlite3_finalize(sourceRevision) }; try bind(.text(oldID), to: sourceRevision, at: 1)
                let incomingRevision = sqlite3_step(sourceRevision) == SQLITE_ROW ? sqlite3_column_int64(sourceRevision, 0) : 0
                let revision = try statement(db, "UPDATE companion_versions SET revision=MAX(revision,?)+1 WHERE kind='note' AND resource_id=?")
                defer { sqlite3_finalize(revision) }; try bind(.integer(incomingRevision), to: revision, at: 1); try bind(.text(oldID), to: revision, at: 2)
                guard sqlite3_step(revision) == SQLITE_DONE else { throw error(db) }
                let change = try statement(db, "INSERT INTO companion_changes(kind,resource_id,revision,deleted) SELECT kind,resource_id,revision,deleted FROM companion_versions WHERE kind='note' AND resource_id=?")
                defer { sqlite3_finalize(change) }; try bind(.text(oldID), to: change, at: 1); guard sqlite3_step(change) == SQLITE_DONE else { throw error(db) }
              }
            }
            continue
          }
          let changes = try insert(db, table: table, row: row)
          if changes == 0 {
            if immutable.contains(table) { throw CompanionAPIError(code: "transfer_event_conflict", message: "An immutable event identity or origin sequence conflicts. Both original databases remain safe.") }
            // A secondary UNIQUE key may also collide. Preserve the exact row;
            // silently dropping it would turn an apparently successful merge into loss.
            let identity = SHA256.hash(data: try JSONEncoder().encode(original)).map { String(format: "%02x", $0) }.joined()
            try insert(db, table: "library_transfer_conflicts", row: ["transfer_id": .text(transferID), "table_name": .text(table), "identity": .text(identity), "incoming": .blob(try JSONEncoder().encode(original))])
            result.retainedConflicts += 1
          } else {
            result.importedRows += changes
            if ["workspace_session_timers", "workspace_session_deliveries"].contains(table), let id = row["id"]?.string {
              try insert(db, table: "library_transfer_runtime_owners", row: ["table_name": .text(table), "record_id": .text(id), "device_id": .text(sourceHost)])
            }
          }
        }
      }
      // A deletion on either side keeps the original synchronized identity
      // deleted. Live writing remains visible under a fresh recovery identity.
      for resource in deletedResources.sorted() {
        let pieces = resource.split(separator: ":", maxSplits: 1).map(String.init)
        let table = pieces[0] == "note" ? "notes" : pieces[0] == "folder" ? "folders" : "dashboard_calendar_items", id = pieces[1]
        let names = try columns(db, table: table).map(\.name)
        let select = try statement(db, "SELECT \(names.map(quoted).joined(separator: ",")) FROM \(table) WHERE id=?")
        defer { sqlite3_finalize(select) }; try bind(.text(id), to: select, at: 1)
        if sqlite3_step(select) == SQLITE_ROW {
          var live = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, value(select, Int32($0.offset))) })
          if table == "folders" || live["deleted_at"] == .null {
            let copyID = recoveryID(transferID: transferID, table: "live-before-delete-" + table, id: id)
            live["id"] = .text(copyID)
            let title = table == "folders" ? "name" : "title"
            if let text = live[title]?.string { live[title] = .text(text + " (recovered before deletion)") }
            if table == "dashboard_calendar_items" { live["next_fire_at"] = .null; live["task_session_id"] = .null }
            try insert(db, table: table, row: live); result.recoveredItems += 1
            if table == "folders" {
              let roots = try statement(db, "INSERT OR IGNORE INTO folder_execution_roots SELECT ?,workspace_id,root_path,managed,reference_paths FROM folder_execution_roots WHERE folder_id=?")
              defer { sqlite3_finalize(roots) }; try bind(.text(copyID), to: roots, at: 1); try bind(.text(id), to: roots, at: 2)
              guard sqlite3_step(roots) == SQLITE_DONE else { throw error(db) }
              let move = try statement(db, "UPDATE notes SET folder_id=? WHERE folder_id=?")
              defer { sqlite3_finalize(move) }; try bind(.text(copyID), to: move, at: 1); try bind(.text(id), to: move, at: 2)
              guard sqlite3_step(move) == SQLITE_DONE else { throw error(db) }
            }
          }
          if table == "folders" {
            let roots = try statement(db, "DELETE FROM folder_execution_roots WHERE folder_id=?")
            defer { sqlite3_finalize(roots) }; try bind(.text(id), to: roots, at: 1)
            guard sqlite3_step(roots) == SQLITE_DONE else { throw error(db) }
          }
          let remove = try statement(db, table == "folders" ? "DELETE FROM folders WHERE id=?" : "UPDATE \(table) SET deleted_at=COALESCE(deleted_at,'1970-01-01T00:00:00.000Z')\(table == "dashboard_calendar_items" ? ",next_fire_at=NULL" : "") WHERE id=?")
          defer { sqlite3_finalize(remove) }; try bind(.text(id), to: remove, at: 1)
          guard sqlite3_step(remove) == SQLITE_DONE else { throw error(db) }
        }
        if table == "dashboard_calendar_items" { continue }
        let tombstone = try statement(db, "UPDATE companion_versions SET deleted=1,revision=revision+1 WHERE kind=? AND resource_id=?")
        defer { sqlite3_finalize(tombstone) }; try bind(.text(pieces[0]), to: tombstone, at: 1); try bind(.text(id), to: tombstone, at: 2)
        guard sqlite3_step(tombstone) == SQLITE_DONE else { throw error(db) }
        let change = try statement(db, "INSERT INTO companion_changes(kind,resource_id,revision,deleted) SELECT kind,resource_id,revision,deleted FROM companion_versions WHERE kind=? AND resource_id=?")
        defer { sqlite3_finalize(change) }; try bind(.text(pieces[0]), to: change, at: 1); try bind(.text(id), to: change, at: 2)
        guard sqlite3_step(change) == SQLITE_DONE else { throw error(db) }
      }
      try insert(db, table: "library_transfer_imports", row: ["id": .text(transferID), "result": .blob(try JSONEncoder().encode(result))])
      let foreign = try statement(db, "PRAGMA foreign_key_check"); defer { sqlite3_finalize(foreign) }
      guard sqlite3_step(foreign) == SQLITE_DONE else { throw WorkspaceDatabaseError.execute("The merged library has an unresolved reference in \(value(foreign, 0).string ?? "an unknown table"); both original databases remain safe") }
      try execute(db, "COMMIT")
      try verify(destination)
      return result
    } catch { try? execute(db, "ROLLBACK"); throw error }
  }
  @discardableResult static func insert(_ db: OpaquePointer, table: String, row: [String: Value]) throws -> Int {
    let names = row.keys.sorted()
    let query = try statement(db, "INSERT OR IGNORE INTO \(quoted(table))(\(names.map(quoted).joined(separator: ","))) VALUES(\(names.map { _ in "?" }.joined(separator: ",")))")
    defer { sqlite3_finalize(query) }
    for (index, name) in names.enumerated() { try bind(row[name]!, to: query, at: Int32(index + 1)) }
    guard sqlite3_step(query) == SQLITE_DONE else { throw error(db) }
    return Int(sqlite3_changes(db))
  }
  public static func recoveryID(transferID: String, table: String, id: String) -> String {
    var bytes = Array(SHA256.hash(data: Data((transferID + ":" + table + ":" + id).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])).uuidString.lowercased()
  }
}

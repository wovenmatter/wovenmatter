import Foundation
import SQLite3
import WovenMatterCompanion

/// Offline history and its upload queue commit together in SQLite.
public actor MobileDictationStore {
  private let file: URL
  public init(file: URL) throws {
    self.file = file
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.access(file) { db in
      try Self.execute(db, "CREATE TABLE IF NOT EXISTS dictations(id TEXT PRIMARY KEY, created_at REAL NOT NULL, payload TEXT NOT NULL, pending INTEGER NOT NULL)")
      try Self.execute(db, "CREATE INDEX IF NOT EXISTS dictations_date ON dictations(created_at DESC, id DESC)")
      try Self.execute(db, "CREATE TABLE IF NOT EXISTS sync(singleton INTEGER PRIMARY KEY CHECK(singleton=1), workspace TEXT, cursor INTEGER NOT NULL DEFAULT 0)")
      try Self.execute(db, "INSERT OR IGNORE INTO sync(singleton) VALUES(1)")
    }
  }
  public func save(_ record: DictationRecord) throws {
    try record.validate()
    try Self.access(file) { db in try Self.insert(db, record, pending: true) }
  }
  public func records(limit: Int = 100) throws -> [DictationRecord] {
    try Self.access(file) { db in
      try Self.rows(db, "SELECT payload FROM dictations ORDER BY created_at DESC, id DESC LIMIT ?", [String(max(1, limit))]).map { try Self.decode($0[0]) }
    }
  }
  public func pending(workspaceID: String? = nil) throws -> [DictationRecord] {
    try Self.access(file) { db in
      try Self.requireWorkspace(db, workspaceID)
      return try Self.rows(db, "SELECT payload FROM dictations WHERE pending=1 ORDER BY created_at, id LIMIT 100").map { try Self.decode($0[0]) } }
  }
  public func pendingCount() throws -> Int {
    try Self.access(file) { db in Int(try Self.rows(db, "SELECT COUNT(*) FROM dictations WHERE pending=1")[0][0]) ?? 0 }
  }
  public func bindWorkspace(_ id: String) throws {
    try Self.access(file) { db in
      let existing = try Self.rows(db, "SELECT COALESCE(workspace, '') FROM sync")[0][0]
      guard existing.isEmpty || existing == id else { throw DictationHistoryError.wrongWorkspace }
      try Self.execute(db, "UPDATE sync SET workspace=? WHERE singleton=1", [id])
    }
  }
  /// Explicit library changes follow the same recovery-and-republish policy as notes.
  public func backup(to destination: URL) throws {
    try Self.access(file) { _ in
      // No write has occurred in this transaction. The reserved lock excludes
      // writers while copying the committed rollback-journal database.
      try FileManager.default.copyItem(at: file, to: destination)
    }
  }
  public func moveLocalWriting(to workspaceID: String) throws {
    try Self.access(file) { db in
      let existing = try Self.rows(db, "SELECT COALESCE(workspace, '') FROM sync")[0][0]
      guard existing != workspaceID else { return }
      try Self.execute(db, "UPDATE dictations SET pending=1")
      try Self.execute(db, "UPDATE sync SET workspace=?, cursor=0 WHERE singleton=1", [workspaceID])
    }
  }
  public func cursor() throws -> Int64 {
    try Self.access(file) { db in Int64(try Self.rows(db, "SELECT cursor FROM sync")[0][0]) ?? 0 }
  }
  public func acknowledge(_ record: DictationRecord, workspaceID: String) throws {
    try Self.access(file) { db in
      try Self.requireWorkspace(db, workspaceID)
      guard let json = try Self.rows(db, "SELECT payload FROM dictations WHERE id=?", [record.id]).first?.first,
        try Self.decode(json) == record else { throw DictationHistoryError.invalidPage }
      try Self.execute(db, "UPDATE dictations SET pending=0 WHERE id=?", [record.id])
    }
  }
  public func apply(_ page: DictationHistoryPage, after: Int64) throws {
    try Self.access(file) { db in
      let metadata = try Self.rows(db, "SELECT COALESCE(workspace, ''), cursor FROM sync")[0]
      guard metadata[0] == page.workspaceID else { throw DictationHistoryError.wrongWorkspace }
      guard Int64(metadata[1]) == after, page.cursor >= after,
        page.records.isEmpty ? (!page.hasMore && page.cursor == after) : page.cursor > after else { throw DictationHistoryError.invalidPage }
      for record in page.records { try record.validate(); try Self.insert(db, record, pending: false) }
      try Self.execute(db, "UPDATE sync SET cursor=? WHERE singleton=1", [String(page.cursor)])
    }
  }
  private static func requireWorkspace(_ db: OpaquePointer, _ id: String?) throws {
    if let id {
      guard try rows(db, "SELECT COALESCE(workspace, '') FROM sync")[0][0] == id else { throw DictationHistoryError.wrongWorkspace }
    }
  }
  private static func decode(_ json: String) throws -> DictationRecord { try JSONDecoder().decode(DictationRecord.self, from: Data(json.utf8)) }
  private static func insert(_ db: OpaquePointer, _ record: DictationRecord, pending: Bool) throws {
    if let json = try rows(db, "SELECT payload FROM dictations WHERE id=?", [record.id]).first?.first {
      guard try decode(json) == record else { throw DictationHistoryError.identityConflict }
      return
    }
    let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
    try execute(db, "INSERT INTO dictations VALUES(?,?,?,?)", [record.id, String(record.createdAt.timeIntervalSince1970), json, pending ? "1" : "0"])
  }
  private static func access<T>(_ file: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db = handle else {
      if let handle { sqlite3_close(handle) }; throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 5_000)
    try execute(db, "PRAGMA synchronous=FULL")
    try execute(db, "BEGIN IMMEDIATE")
    do { let value = try body(db); try execute(db, "COMMIT"); return value }
    catch { try? execute(db, "ROLLBACK"); throw error }
  }
  private static func execute(_ db: OpaquePointer, _ sql: String, _ values: [String] = []) throws { _ = try rows(db, sql, values) }
  private static func rows(_ db: OpaquePointer, _ sql: String, _ values: [String] = []) throws -> [[String]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CocoaError(.fileReadCorruptFile) }
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() {
      let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
      guard result == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
    var result: [[String]] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW:
        result.append((0..<sqlite3_column_count(statement)).map { column in
          sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        })
      case SQLITE_DONE: return result
      default: throw CocoaError(.fileWriteUnknown)
      }
    }
  }
}

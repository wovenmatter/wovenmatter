import Foundation
import WovenProtocol
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// One database's SQLite file: the owner's own file, which only its server
/// writes, or a published copy, which is only ever read. Every call opens its
/// own connection and blocks until done; callers keep it off shared threads.
public struct DatabaseFile: Sendable {
  public let url: URL
  /// A published copy from the content store: opened immutable, never written.
  public let isCopy: Bool

  public init(url: URL, isCopy: Bool) {
    self.url = url
    self.isCopy = isCopy
  }

  /// Makes an empty database at `url`.
  public static func create(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: url.path) else { throw LibraryError(.invalid, "\(url.path) already exists.") }
    let db = try Handle(url, .create)
    try db.exec("PRAGMA journal_mode = WAL")
  }

  /// Makes the owner's file at `url` from a published copy, after checking it.
  public static func adopt(copy: URL, at url: URL) throws {
    try validate(copy: copy)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: url.path) else { throw LibraryError(.invalid, "\(url.path) already exists.") }
    let partial = url.appendingPathExtension("partial")
    try? FileManager.default.removeItem(at: partial)
    try FileManager.default.copyItem(at: copy, to: partial)
    do {
      try Handle(partial, .write).exec("PRAGMA journal_mode = WAL")
      try FileManager.default.moveItem(at: partial, to: url)
    } catch {
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
  }

  /// Checks that a file received as a copy is a whole, sound SQLite database
  /// within the size limit.
  public static func validate(copy url: URL) throws {
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    guard size <= DatabaseLimits.maximumCopyBytes else { throw LibraryError(.invalid, "The database copy is too large.") }
    let handle = try FileHandle(forReadingFrom: url)
    let header = try handle.read(upToCount: 100) ?? Data()
    try? handle.close()
    guard header.count == 100, header.starts(with: Data("SQLite format 3\0".utf8)) else {
      throw LibraryError(.invalid, "The database copy is not an SQLite database.")
    }
    let db = try Handle(url, .copy)
    guard try db.rows("PRAGMA quick_check").first?.first == "ok" else {
      throw LibraryError(.invalid, "The database copy is damaged.")
    }
  }

  /// Removes the owner's file with its journal files.
  public static func remove(at url: URL) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  /// Runs SQL that changes the database as one transaction, and returns the
  /// rows it inserted, changed or deleted. The SQL may change its own tables
  /// and schema; it may not attach files, run pragmas, load extensions or
  /// control the transaction. A write that would grow the file past the copy
  /// limit is rolled back.
  public func execute(_ sql: String) throws -> Int64 {
    guard !isCopy else { throw LibraryError(.invalid, "A database copy is never written.") }
    guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError(.invalid, "There is no SQL to run.") }
    guard sql.utf8.count <= DatabaseLimits.maximumExecuteSQLBytes else {
      throw LibraryError(.invalid, "SQL to run may be at most \(DatabaseLimits.maximumExecuteSQLBytes / 1024) KiB.")
    }
    let db = try Handle(url, .write)
    sqlite3_limit(db.pointer, SQLITE_LIMIT_LENGTH, Int32(DatabaseLimits.maximumCopyBytes))
    sqlite3_limit(db.pointer, SQLITE_LIMIT_ATTACHED, 0)
    let before = sqlite3_total_changes64(db.pointer)
    try db.exec("BEGIN IMMEDIATE")
    do {
      sqlite3_set_authorizer(db.pointer, { _, action, _, detail, _, _ in
        switch action {
        case SQLITE_ATTACH, SQLITE_DETACH, SQLITE_TRANSACTION, SQLITE_SAVEPOINT, SQLITE_PRAGMA: return SQLITE_DENY
        case SQLITE_FUNCTION where isLoadExtension(detail): return SQLITE_DENY
        default: return SQLITE_OK
        }
      }, nil)
      try db.timed { try db.exec(sql) }
      sqlite3_set_authorizer(db.pointer, nil, nil)
      let changes = sqlite3_total_changes64(db.pointer) - before
      let pages = try db.rows("PRAGMA page_count").first?.first.flatMap { Int64($0) } ?? 0
      let pageSize = try db.rows("PRAGMA page_size").first?.first.flatMap { Int64($0) } ?? 0
      guard pages * pageSize <= DatabaseLimits.maximumCopyBytes else {
        throw LibraryError(.invalid, "The write would make the database larger than \(DatabaseLimits.maximumCopyBytes / 1_048_576) MiB.")
      }
      try db.exec("COMMIT")
      return changes
    } catch {
      sqlite3_set_authorizer(db.pointer, nil, nil)
      try? db.exec("ROLLBACK")
      throw error
    }
  }

  /// Runs one read-only statement. Each value comes as text (a blob as hex,
  /// null as empty), and the same rows as a JSON array of objects with
  /// sorted keys.
  public func query(_ sql: String) throws -> (columns: [String], rows: [[String]], json: String) {
    guard sql.utf8.count <= DatabaseLimits.maximumQuerySQLBytes else {
      throw LibraryError(.invalid, "A query may be at most \(DatabaseLimits.maximumQuerySQLBytes / 1024) KiB.")
    }
    let db = try Handle(url, isCopy ? .copy : .read)
    sqlite3_limit(db.pointer, SQLITE_LIMIT_LENGTH, Int32(DatabaseLimits.maximumResultBytes))
    sqlite3_limit(db.pointer, SQLITE_LIMIT_ATTACHED, 0)
    sqlite3_set_authorizer(db.pointer, { _, action, _, detail, _, _ in
      switch action {
      case SQLITE_FUNCTION where isLoadExtension(detail): return SQLITE_DENY
      case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE: return SQLITE_OK
      default: return SQLITE_DENY
      }
    }, nil)
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    let prepared = sql.withCString { text -> Bool in
      var tail: UnsafePointer<CChar>?
      let status = sqlite3_prepare_v2(db.pointer, text, -1, &statement, &tail)
      return status == SQLITE_OK && (tail.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true)
    }
    guard prepared, let statement else {
      throw LibraryError(.invalid, statement == nil ? db.message : "A query must be one statement.")
    }
    guard sqlite3_stmt_readonly(statement) != 0 else { throw LibraryError(.invalid, "A query may only read.") }
    let count = sqlite3_column_count(statement)
    let columns = (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) }
    guard !columns.isEmpty, columns.count <= DatabaseLimits.maximumColumns, Set(columns).count == columns.count else {
      throw LibraryError(.invalid, "A query must return 1 to \(DatabaseLimits.maximumColumns) columns with unique names.")
    }
    var rows: [[String]] = []
    var bytes = 0
    try db.timed {
      while rows.count < DatabaseLimits.maximumRows {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW else { throw LibraryError(.invalid, db.message) }
        var row: [String] = []
        for column in 0..<count {
          let size = Int(sqlite3_column_bytes(statement, column))
          bytes += size + columns[Int(column)].utf8.count + 8
          guard bytes <= DatabaseLimits.maximumResultBytes else { throw LibraryError(.invalid, "The query's result is too large.") }
          if sqlite3_column_type(statement, column) == SQLITE_BLOB, let value = sqlite3_column_blob(statement, column) {
            row.append(Data(bytes: value, count: size).map { String(format: "%02x", $0) }.joined())
          } else if let value = sqlite3_column_text(statement, column) {
            row.append(String(decoding: UnsafeBufferPointer(start: value, count: size), as: UTF8.self))
          } else {
            row.append("")
          }
        }
        rows.append(row)
      }
    }
    let objects = rows.map { row in Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element, row[$0.offset]) }) }
    let json = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    guard json.count <= DatabaseLimits.maximumResultBytes else { throw LibraryError(.invalid, "The query's result is too large.") }
    return (columns, rows, String(decoding: json, as: UTF8.self))
  }

  /// The database's own tables with their columns and row counts.
  public func describe() throws -> [DatabaseTable] {
    let db = try Handle(url, isCopy ? .copy : .read)
    return try db.timed {
      try db.rows("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
        .compactMap(\.first).map { name in
          let columns = try db.rows("SELECT name, type FROM pragma_table_info(?)", [name]).map {
            DatabaseColumn(name: $0[0], type: $0[1])
          }
          let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
          let count = try db.rows("SELECT COUNT(*) FROM \(quoted)").first?.first.flatMap { Int64($0) } ?? 0
          return DatabaseTable(name: name, columns: columns, rowCount: count)
        }
    }
  }

  /// Writes a consistent copy of the whole database to `target`, as one file
  /// with no journal beside it.
  public func copy(to target: URL) throws {
    let source = try Handle(url, isCopy ? .copy : .read)
    let destination = try Handle(target, .create)
    guard let backup = sqlite3_backup_init(destination.pointer, "main", source.pointer, "main") else {
      throw LibraryError(.invalid, "Could not copy the database: \(destination.message)")
    }
    let stepped = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    guard stepped == SQLITE_DONE, finished == SQLITE_OK else {
      throw LibraryError(.invalid, "Could not copy the database: \(destination.message)")
    }
    try destination.exec("PRAGMA journal_mode = DELETE")
  }
}

private func isLoadExtension(_ name: UnsafePointer<CChar>?) -> Bool {
  guard let name else { return false }
  return String(cString: name).lowercased() == "load_extension"
}

/// One open connection, closed when released.
private final class Handle {
  enum Mode {
    case create, write, read
    /// A file that never changes: read-only and immutable, so SQLite writes
    /// no journal or lock beside it.
    case copy
  }

  let pointer: OpaquePointer

  init(_ url: URL, _ mode: Mode) throws {
    let path: String
    var flags: Int32
    switch mode {
    case .create: (path, flags) = (url.path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    case .write: (path, flags) = (url.path, SQLITE_OPEN_READWRITE)
    // The owner's file is in WAL mode; a reader is refused writes by `query_only`.
    case .read: (path, flags) = (url.path, SQLITE_OPEN_READWRITE)
    case .copy: (path, flags) = (URL(fileURLWithPath: url.path).absoluteString + "?immutable=1", SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
    }
    if mode != .create, !FileManager.default.fileExists(atPath: url.path) {
      throw LibraryError(.notFound, "The database file is missing.")
    }
    flags |= SQLITE_OPEN_NOMUTEX
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the database."
      sqlite3_close(handle)
      throw LibraryError(.invalid, message)
    }
    pointer = handle
    sqlite3_busy_timeout(handle, Int32(DatabaseLimits.maximumSeconds * 1000))
    #if !canImport(SQLite3)
    // Off by default; the SDK on Apple platforms does not offer it at all.
    sqlite3_enable_load_extension(handle, 0)
    #endif
    if mode == .read { try exec("PRAGMA query_only = ON") }
  }

  deinit { sqlite3_close_v2(pointer) }

  var message: String { String(cString: sqlite3_errmsg(pointer)) }

  /// Runs SQL that returns nothing, possibly several statements.
  func exec(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(pointer, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? self.message
      sqlite3_free(error)
      throw LibraryError(.invalid, message)
    }
  }

  /// Every row of one statement, each value as text.
  func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw LibraryError(.invalid, message)
    }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) }
    var rows: [[String]] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return rows }
      guard status == SQLITE_ROW else { throw LibraryError(.invalid, message) }
      rows.append((0..<sqlite3_column_count(statement)).map { column in
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
      })
    }
  }

  /// Runs `body`, interrupting any statement still running after the time limit.
  func timed<T>(_ body: () throws -> T) throws -> T {
    let deadline = Deadline(Date().timeIntervalSince1970 + DatabaseLimits.maximumSeconds)
    sqlite3_progress_handler(pointer, 1000, { context in
      guard let context else { return 1 }
      return Date().timeIntervalSince1970 > Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().time ? 1 : 0
    }, Unmanaged.passUnretained(deadline).toOpaque())
    defer { sqlite3_progress_handler(pointer, 0, nil, nil) }
    return try withExtendedLifetime(deadline) {
      do { return try body() } catch {
        guard Date().timeIntervalSince1970 > deadline.time else { throw error }
        throw LibraryError(.invalid, "The statement ran longer than \(Int(DatabaseLimits.maximumSeconds)) seconds.")
      }
    }
  }
}

private final class Deadline {
  let time: Double
  init(_ time: Double) { self.time = time }
}

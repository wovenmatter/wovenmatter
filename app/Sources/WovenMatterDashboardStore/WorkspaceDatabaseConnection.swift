import Foundation
import SQLite3
import WovenMatterCore

public enum WorkspaceDatabaseError: Error, Equatable {
  case open(String)
  case execute(String)
  case prepare(String)
  case bind(String)
  case step(String)
  case readOnlyProjection
  case corruptRow
}

/// Synchronous SQL implementation. Only the async facade may own a connection;
/// all calls and connection teardown run on a dedicated database worker.
final class WorkspaceDatabaseConnection {
  private let workerQueue: DispatchQueue
  private var connection: OpaquePointer?
  public let isReadOnlyProjection: Bool
  let libraryFiles: LibraryFileStore

  init(url: URL, readOnlyProjection: Bool = false, workerQueue: DispatchQueue) throws {
    self.workerQueue = workerQueue
    dispatchPrecondition(condition: .onQueue(workerQueue))
    isReadOnlyProjection = readOnlyProjection
    libraryFiles = LibraryFileStore(supportDirectory: url.deletingLastPathComponent(), readOnlyProjection: readOnlyProjection)
    var database: OpaquePointer?
    let flags = (readOnlyProjection ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to allocate SQLite connection"
      if let database { sqlite3_close(database) }
      throw WorkspaceDatabaseError.open(message)
    }
    connection = database

    do {
      try WorkspaceSQLiteTextFunctions.register(on: database)
      if readOnlyProjection {
        try execute("PRAGMA query_only = ON")
        try execute("PRAGMA busy_timeout = 5000")
        return
      }
      try execute("PRAGMA busy_timeout = 5000")
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA foreign_keys = ON")
      try migrate()
      try migrateWorkspaceHistory()
      try migrateAgentTools()
      try migrateCalendar()
      try migrateLibrary()
      try createNativeRunArchive()
      try createConversationActivityIndex()
    } catch {
      sqlite3_close(database)
      connection = nil
      throw error
    }
  }

  deinit {
    dispatchPrecondition(condition: .onQueue(workerQueue))
    if let connection { sqlite3_close(connection) }
  }

  func transaction<T>(_ operation: () throws -> T) throws -> T {
    try withLock {
      if isReadOnlyProjection, let connection, sqlite3_get_autocommit(connection) == 0 { return try operation() }
      try executeUnlocked(isReadOnlyProjection ? "BEGIN DEFERRED" : "BEGIN IMMEDIATE")
      do {
        let result = try operation()
        try executeUnlocked("COMMIT")
        return result
      } catch {
        try? executeUnlocked("ROLLBACK")
        throw error
      }
    }
  }

  private func execute(_ sql: String) throws {
    try withLock { try executeUnlocked(sql) }
  }

  func executeUnlocked(_ sql: String) throws {
    guard let connection else { throw WorkspaceDatabaseError.execute("Database is closed") }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(connection, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
      sqlite3_free(errorMessage)
      throw WorkspaceDatabaseError.execute(message)
    }
  }

  func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
    guard let connection else { throw WorkspaceDatabaseError.prepare("Database is closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw WorkspaceDatabaseError.prepare(String(cString: sqlite3_errmsg(connection)))
    }
    return statement
  }

  func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
    guard let byteCount = Int32(exactly: value.utf8.count) else {
      throw WorkspaceDatabaseError.bind("Text exceeds SQLite's byte-length limit")
    }
    // withCString supplies a nonnil terminator even for empty TEXT. The explicit
    // byte count preserves embedded NULs; TRANSIENT copies before this scope ends.
    let status = value.withCString { bytes in
      sqlite3_bind_text(statement, index, bytes, byteCount, SQLITE_TRANSIENT)
    }
    guard status == SQLITE_OK else { throw bindError() }
  }

  func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
    if value.isEmpty {
      guard sqlite3_bind_zeroblob(statement, index, 0) == SQLITE_OK else {
        throw bindError()
      }
      return
    }
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement,
        index,
        bytes.baseAddress,
        Int32(bytes.count),
        SQLITE_TRANSIENT
      )
    }
    guard result == SQLITE_OK else { throw bindError() }
  }

  func bindNullable(
    _ value: String?,
    at index: Int32,
    to statement: OpaquePointer
  ) throws {
    if let value {
      try bind(value, at: index, to: statement)
    } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
      throw bindError()
    }
  }

  func text(_ statement: OpaquePointer, column: Int32) throws -> String {
    guard let value = sqlite3_column_text(statement, column) else { throw WorkspaceDatabaseError.corruptRow }
    return String(decoding: UnsafeBufferPointer(start: value,
      count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
  }

  func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    return String(decoding: UnsafeBufferPointer(start: value,
      count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
  }

  func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0 else { return Data() }
    guard let bytes = sqlite3_column_blob(statement, column) else { throw WorkspaceDatabaseError.corruptRow }
    return Data(bytes: bytes, count: count)
  }

  func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
  }

  func bindError() -> WorkspaceDatabaseError {
    .bind(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
  }

  func stepError() -> WorkspaceDatabaseError {
    .step(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
  }

  static func dashboardDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    return date(value)
  }

  private static let timestamps = WorkspaceTimestampCodec()

  static func timestamp(_ date: Date) -> String {
    timestamps.string(from: date)
  }

  static func date(_ value: String) -> Date? {
    timestamps.date(from: value)
  }

  // Domain helpers execute only on the connection owner queue. Their historical
  // withLock/Unlocked names now denote scopes within one synchronous worker job.
  func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    dispatchPrecondition(condition: .onQueue(workerQueue))
    return try operation()
  }

  var changedRowCountUnlocked: Int32 { sqlite3_changes(connection) }
}

/// The configured formatters are reused across worker connections. Their mutable
/// Foundation implementation is accessed only while holding this lock.
private final class WorkspaceTimestampCodec: @unchecked Sendable {
  private let lock = NSLock()
  private let fractional: ISO8601DateFormatter
  private let whole: ISO8601DateFormatter

  init() {
    fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
  }

  func string(from date: Date) -> String {
    lock.withLock { fractional.string(from: date) }
  }

  func date(from value: String) -> Date? {
    lock.withLock { fractional.date(from: value) ?? whole.date(from: value) }
  }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)


/// Register on every connection that reads or writes the workspace database.
/// Archive triggers share the privacy and text-window functions with history
/// queries. Registration is connection-local and safe to repeat, including for
/// synthetic SQL writers that bypass the async database facade in tests.
/// SQLite's built-in TEXT length/substr stop at embedded NUL; these windows count
/// UTF-8 scalar boundaries without allocating a whole String for a small slice.
enum WorkspaceSQLiteTextFunctions {
  static func register(on database: OpaquePointer) throws {
    let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
    let redactStatus = sqlite3_create_function_v2(database, "woven_history_redact", 1, flags, nil,
      { context, _, arguments in
        guard let context, let value = arguments?[0] else { return }
        guard sqlite3_value_type(value) != SQLITE_NULL else { sqlite3_result_null(context); return }
        guard let bytes = sqlite3_value_text(value) else { sqlite3_result_error_nomem(context); return }
        let count = Int(sqlite3_value_bytes(value))
        let original = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        let safe = WorkspaceHistoryPrivacy.redactingToolEndpoints(original)
        safe.withCString { sqlite3_result_text(context, $0, Int32(safe.utf8.count), SQLITE_TRANSIENT) }
      }, nil, nil, nil)
    guard redactStatus == SQLITE_OK else { throw WorkspaceDatabaseError.open("Unable to register history privacy filter") }
    let lengthStatus = sqlite3_create_function_v2(database, "woven_text_length", 1, flags, nil,
      { context, _, arguments in
        guard let context, let value = arguments?[0] else { return }
        guard sqlite3_value_type(value) != SQLITE_NULL else { sqlite3_result_null(context); return }
        guard let bytes = sqlite3_value_text(value) else { sqlite3_result_error_nomem(context); return }
        let count = Int(sqlite3_value_bytes(value))
        sqlite3_result_int64(context, WorkspaceSQLiteTextFunctions.scalarCount(bytes, count: count))
      }, nil, nil, nil)
    guard lengthStatus == SQLITE_OK else { throw WorkspaceDatabaseError.open("Unable to register history text length") }
    for arity: Int32 in [2, 3] {
      let status = sqlite3_create_function_v2(database, "woven_text_substr", arity, flags, nil,
        { context, count, arguments in
          guard let context, let arguments, let value = arguments[0], let position = arguments[1] else { return }
          guard sqlite3_value_type(value) != SQLITE_NULL, sqlite3_value_type(position) != SQLITE_NULL,
                count != 3 || sqlite3_value_type(arguments[2]) != SQLITE_NULL else {
            sqlite3_result_null(context); return
          }
          guard let bytes = sqlite3_value_text(value) else { sqlite3_result_error_nomem(context); return }
          let byteCount = Int(sqlite3_value_bytes(value))
          var start = sqlite3_value_int64(position)
          let requested = count == 3 ? sqlite3_value_int64(arguments[2]) : Int64.max
          let backwards = requested < 0
          var width = requested == Int64.min ? Int64.max : backwards ? -requested : requested
          // Match SQLite's one-based/negative index and negative length rules.
          if start < 0 {
            start += WorkspaceSQLiteTextFunctions.scalarCount(bytes, count: byteCount)
            if start < 0 { width += start; start = 0 }
          } else if start > 0 { start -= 1 }
          else if width > 0 { width -= 1 }
          width = max(0, width)
          if backwards {
            start -= width
            if start < 0 { width += start; start = 0 }
          }
          var begin = 0
          while start > 0, begin < byteCount {
            begin = WorkspaceSQLiteTextFunctions.nextScalar(bytes, count: byteCount, from: begin)
            start -= 1
          }
          var end = begin
          while width > 0, end < byteCount {
            end = WorkspaceSQLiteTextFunctions.nextScalar(bytes, count: byteCount, from: end)
            width -= 1
          }
          let result = UnsafeRawPointer(bytes.advanced(by: begin)).assumingMemoryBound(to: CChar.self)
          sqlite3_result_text(context, result, Int32(end - begin), SQLITE_TRANSIENT)
        }, nil, nil, nil)
      guard status == SQLITE_OK else { throw WorkspaceDatabaseError.open("Unable to register history text window") }
    }
  }

  private static func scalarCount(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int64 {
    var offset = 0
    var scalars: Int64 = 0
    while offset < count {
      offset = nextScalar(bytes, count: count, from: offset)
      scalars += 1
    }
    return scalars
  }

  private static func nextScalar(_ bytes: UnsafePointer<UInt8>, count: Int, from offset: Int) -> Int {
    var next = offset + 1
    if bytes[offset] >= 0xc0 {
      while next < count, bytes[next] & 0xc0 == 0x80 { next += 1 }
    }
    return next
  }
}


extension WorkspaceDatabaseConnection {
  /// A coherent snapshot for multi-query reads, with cooperative SQLite query
  /// interruption. query_only additionally rejects accidental writes on readers.
  func readSnapshot<T>(context: DatabaseJobContext, _ operation: () throws -> T) throws -> T {
    guard let connection else { throw WorkspaceDatabaseError.execute("Database is closed") }
    let pointer = Unmanaged.passUnretained(context).toOpaque()
    sqlite3_progress_handler(connection, 1_000, { pointer in
      guard let pointer else { return 0 }
      do { try Unmanaged<DatabaseJobContext>.fromOpaque(pointer).takeUnretainedValue().check(); return 0 }
      catch { return 1 }
    }, pointer)
    sqlite3_busy_handler(connection, { pointer, attempt in
      guard let pointer, attempt < 500 else { return 0 }
      do { try Unmanaged<DatabaseJobContext>.fromOpaque(pointer).takeUnretainedValue().check() }
      catch { return 0 }
      sqlite3_sleep(10)
      return 1
    }, pointer)
    defer {
      sqlite3_progress_handler(connection, 0, nil, nil)
      sqlite3_busy_timeout(connection, 5000)
    }
    try executeUnlocked("BEGIN DEFERRED")
    do {
      let value = try operation()
      try context.check()
      try executeUnlocked("COMMIT")
      return value
    } catch {
      sqlite3_progress_handler(connection, 0, nil, nil)
      try? executeUnlocked("ROLLBACK")
      try context.check()
      throw error
    }
  }
}

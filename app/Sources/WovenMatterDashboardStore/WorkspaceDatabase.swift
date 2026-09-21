import Foundation
import SQLite3

public enum WorkspaceDatabaseError: Error, Equatable {
  case open(String)
  case execute(String)
  case prepare(String)
  case bind(String)
  case step(String)
  case corruptRow
}

/// A single connection and lock shared by the domain operations in WorkspaceDatabase+*.swift.
/// Public operations retain their original lock/transaction boundaries.
public final class WorkspaceDatabase: @unchecked Sendable {
  private let lock = NSLock()
  private var connection: OpaquePointer?

  public init(url: URL) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to allocate SQLite connection"
      if let database { sqlite3_close(database) }
      throw WorkspaceDatabaseError.open(message)
    }
    connection = database

    do {
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA foreign_keys = ON")
      try execute("PRAGMA busy_timeout = 5000")
      try migrate()
      try migrateWorkspaceHistory()
      try migrateAgentTools()
    } catch {
      sqlite3_close(database)
      connection = nil
      throw error
    }
  }

  deinit {
    if let connection { sqlite3_close(connection) }
  }

  func transaction<T>(_ operation: () throws -> T) throws -> T {
    try lock.withLock {
      try executeUnlocked("BEGIN IMMEDIATE")
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
    try lock.withLock { try executeUnlocked(sql) }
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
    guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
      throw bindError()
    }
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
    return String(cString: value)
  }

  func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
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

  private static func formatter(includingFractionalSeconds: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = includingFractionalSeconds
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter
  }

  static func timestamp(_ date: Date) -> String {
    formatter(includingFractionalSeconds: true).string(from: date)
  }

  static func date(_ value: String) -> Date? {
    formatter(includingFractionalSeconds: true).date(from: value)
      ?? formatter(includingFractionalSeconds: false).date(from: value)
  }

  // Domain extensions use these primitives under this same lock. Unlocked helpers
  // require an existing withLock/transaction scope; they must never reacquire it.
  func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    try lock.withLock(operation)
  }

  var changedRowCountUnlocked: Int32 { sqlite3_changes(connection) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension NSLock {
  func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try operation()
  }
}

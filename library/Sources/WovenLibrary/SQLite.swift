import Foundation
import WovenProtocol
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// SQLite reported an error.
public struct DatabaseError: Error, CustomStringConvertible, Sendable {
  public let description: String
  init(_ description: String) { self.description = description }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One row of a query, by column name.
public struct Row: Sendable {
  let columns: [String: Int]
  let values: [SQLValue]

  public subscript(_ name: String) -> SQLValue {
    columns[name].map { values[$0] } ?? .null
  }

  public func text(_ name: String) -> String? {
    switch self[name] {
    case .text(let value): value
    case .integer(let value): String(value)
    case .real(let value): String(value)
    default: nil
    }
  }

  public func integer(_ name: String) -> Int64? {
    switch self[name] {
    case .integer(let value): value
    case .real(let value): Int64(value)
    case .text(let value): Int64(value)
    default: nil
    }
  }

  public func bool(_ name: String) -> Bool { (integer(name) ?? 0) != 0 }

  func date(_ name: String) -> Date {
    Date(timeIntervalSince1970: Double(integer(name) ?? 0) / 1000)
  }

  /// Every column except those named, for passing a row on.
  func values(excluding names: Set<String>) -> [String: SQLValue] {
    var result: [String: SQLValue] = [:]
    for (name, index) in columns where !names.contains(name) { result[name] = values[index] }
    return result
  }
}

/// A thin wrapper over one SQLite connection. Not thread-safe: its owner
/// confines it to one queue at a time.
final class Connection: @unchecked Sendable {
  private var handle: OpaquePointer?
  private var statements: [String: OpaquePointer] = [:]

  init(path: String, readOnly: Bool) throws {
    let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
                         : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open \(path)"
      sqlite3_close(handle)
      throw DatabaseError(message)
    }
    self.handle = handle
    try execute("PRAGMA busy_timeout = 5000")
    if readOnly { try execute("PRAGMA query_only = ON") }
  }

  deinit {
    for statement in statements.values { sqlite3_finalize(statement) }
    sqlite3_close(handle)
  }

  /// Runs SQL that returns nothing, possibly several statements.
  func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? lastError
      sqlite3_free(error)
      throw DatabaseError(message)
    }
  }

  func run(_ sql: String, _ values: [SQLValue] = []) throws {
    let statement = try prepare(sql, values)
    defer { sqlite3_reset(statement) }
    let status = sqlite3_step(statement)
    guard status == SQLITE_DONE || status == SQLITE_ROW else { throw DatabaseError(lastError) }
  }

  func query(_ sql: String, _ values: [SQLValue] = []) throws -> [Row] {
    let statement = try prepare(sql, values)
    defer { sqlite3_reset(statement) }
    let count = sqlite3_column_count(statement)
    var columns: [String: Int] = [:]
    for index in 0..<count { columns[String(cString: sqlite3_column_name(statement, index))] = Int(index) }
    var rows: [Row] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw DatabaseError(lastError) }
      rows.append(Row(columns: columns, values: (0..<count).map { column(statement, $0) }))
    }
    return rows
  }

  /// Runs `body` in one transaction that holds the write lock from the start.
  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  /// Runs `body` in one read transaction, so every query sees one instant.
  func snapshot<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN DEFERRED")
    defer { try? execute("COMMIT") }
    return try body()
  }

  private var lastError: String { String(cString: sqlite3_errmsg(handle)) }

  private func prepare(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
    let statement: OpaquePointer
    if let cached = statements[sql] {
      statement = cached
    } else {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &prepared, nil) == SQLITE_OK,
            let prepared else { throw DatabaseError("\(lastError) in \(sql)") }
      statements[sql] = prepared
      statement = prepared
    }
    sqlite3_clear_bindings(statement)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let status: Int32
      switch value {
      case .null: status = sqlite3_bind_null(statement, index)
      case .integer(let value): status = sqlite3_bind_int64(statement, index, value)
      case .real(let value): status = sqlite3_bind_double(statement, index, value)
      case .text(let value): status = sqlite3_bind_text(statement, index, value, -1, transient)
      case .blob(let value):
        status = value.withUnsafeBytes { bytes in
          sqlite3_bind_blob64(statement, index, bytes.baseAddress, sqlite3_uint64(bytes.count), transient)
        }
      }
      guard status == SQLITE_OK else { throw DatabaseError(lastError) }
    }
    return statement
  }

  private func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
    case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, index))
      guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
      return .blob(Data(bytes: bytes, count: count))
    default: return .null
    }
  }
}

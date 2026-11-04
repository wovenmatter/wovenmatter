import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

/// A credential store that never holds a key. With `recordsAccess`, every call
/// records an issue so SQLite import fixtures prove they never touch credentials.
struct UsageNoCredentials: UsageCredentialStoring {
  var recordsAccess = false
  private func accessed() {
    if recordsAccess { Issue.record("SQLite import fixtures must not access credentials") }
  }
  func hasOpenRouterAPIKey() throws -> Bool { accessed(); return false }
  func authorizeOpenRouterAPIKey() throws -> String? { accessed(); return nil }
  func saveOpenRouterAPIKey(_ key: String) throws { accessed() }
  func deleteOpenRouterAPIKey() throws { accessed() }
}

final class PersistenceSQL {
  private let connection: OpaquePointer

  init(url: URL) throws {
    var pointer: OpaquePointer?
    let code = sqlite3_open(url.path, &pointer)
    guard code == SQLITE_OK, let pointer else {
      if let pointer { sqlite3_close(pointer) }
      throw WorkspaceDatabaseError.open("Synthetic database failed to open")
    }
    connection = pointer
    do {
      try WorkspaceSQLiteTextFunctions.register(on: pointer)
      // Re-registration must remain safe on independently opened writers.
      try WorkspaceSQLiteTextFunctions.register(on: pointer)
    } catch {
      sqlite3_close(pointer)
      throw error
    }
  }

  deinit { sqlite3_close(connection) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
      throw WorkspaceDatabaseError.execute(String(cString: sqlite3_errmsg(connection)))
    }
  }

  func scalar(_ sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw WorkspaceDatabaseError.prepare(String(cString: sqlite3_errmsg(connection)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw WorkspaceDatabaseError.step(String(cString: sqlite3_errmsg(connection)))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }
}

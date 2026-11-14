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

extension WorkspaceDatabaseConnection {
  static func libraryContentFingerprint(_ content: String) -> String {
    SHA256.hash(data: Data(content.utf8)).hexString
  }

  public func libraryDraftRevision(operationID: String) throws -> String? {
    try withLock { try libraryDraftReceiptUnlocked(operationID: operationID)?.revision }
  }

  func libraryDraftReceiptUnlocked(operationID: String) throws -> (id: String, title: String, content: String, revision: String)? {
    let statement = try prepareUnlocked("SELECT note_id, title, content, revision FROM device_draft_receipts WHERE operation_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind(operationID, at: 1, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return try (text(statement, column: 0), text(statement, column: 1), text(statement, column: 2), text(statement, column: 3))
  }

  func saveLibraryDraftReceiptUnlocked(operationID: String?, id: String, title: String, content: String, revision: String) throws {
    guard let operationID else { return }
    try toolsExecuteUnlocked("INSERT INTO device_draft_receipts(operation_id, note_id, title, content, revision) VALUES (?, ?, ?, ?, ?)", [operationID, id, title, Self.libraryContentFingerprint(content), revision])
  }
}

extension WorkspaceDatabase {
  public func libraryDraftRevision(operationID: String) async throws -> String? {
    try await read { try $0.libraryDraftRevision(operationID: operationID) }
  }
}

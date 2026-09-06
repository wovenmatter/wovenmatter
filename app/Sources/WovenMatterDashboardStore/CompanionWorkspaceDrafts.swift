import CryptoKit
import Foundation
import SQLite3

extension WorkspaceDatabase {
  static func companionContentFingerprint(_ content: String) -> String {
    SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public func companionDraftRevision(operationID: String) throws -> String? {
    try lock.withLock { try companionDraftReceiptUnlocked(operationID: operationID)?.revision }
  }

  func companionDraftReceiptUnlocked(operationID: String) throws -> (id: String, title: String, content: String, revision: String)? {
    let statement = try prepareUnlocked("SELECT note_id, title, content, revision FROM companion_draft_receipts WHERE operation_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind(operationID, at: 1, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return try (text(statement, column: 0), text(statement, column: 1), text(statement, column: 2), text(statement, column: 3))
  }

  func saveCompanionDraftReceiptUnlocked(operationID: String?, id: String, title: String, content: String, revision: String) throws {
    guard let operationID else { return }
    try companionExecuteUnlocked("INSERT INTO companion_draft_receipts(operation_id, note_id, title, content, revision) VALUES (?, ?, ?, ?, ?)", values: [operationID, id, title, Self.companionContentFingerprint(content), revision])
  }
}

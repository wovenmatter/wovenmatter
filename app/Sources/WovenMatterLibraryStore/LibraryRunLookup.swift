import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension WorkspaceDatabaseConnection {
  /// A control lookup must not materialize transcript bodies or attachment payloads.
  public func activeRunID(conversationID: String) throws -> String? {
    try withLock {
      let statement = try prepareUnlocked("""
        SELECT id FROM runs
        WHERE conversation_id = ? AND status = 'running'
          AND \(PairedLibraryOwnership.localConversation("runs.conversation_id"))
        ORDER BY created_at DESC, id DESC LIMIT 1
        """)
      defer { sqlite3_finalize(statement) }
      try bind(conversationID, at: 1, to: statement)
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return nil }
      guard code == SQLITE_ROW else { throw stepError() }
      return try text(statement, column: 0)
    }
  }
}

extension WorkspaceDatabase {
  public func activeRunID(conversationID: String) async throws -> String? {
    try await read { try $0.activeRunID(conversationID: conversationID) }
  }
}

import Foundation
import SQLite3

extension WorkspaceDatabase {
  /// A control lookup must not materialize transcript bodies or attachment payloads.
  public func activeRunID(conversationID: String) throws -> String? {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        SELECT id FROM dashboard_runs
        WHERE conversation_id = ? AND status = 'running'
          AND desktop_owned = 1 AND authority_kind = 'device_owned'
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

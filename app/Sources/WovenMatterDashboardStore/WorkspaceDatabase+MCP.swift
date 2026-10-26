import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// A retained transcript is not a live MCP principal. Moving execution to a
  /// different owner also retires credentials issued by its previous owner.
  func requireMCPCaller(_ sessionID: String) throws {
    try withLock {
      guard !(try historyRowsUnlocked("SELECT id FROM dashboard_conversations WHERE id=? AND deleted_at IS NULL AND is_archived=0", values: [sessionID])).isEmpty,
            (try historyRowsUnlocked("SELECT conversation_id FROM companion_execution_adoptions WHERE conversation_id=?", values: [sessionID])).isEmpty else {
        throw WorkspaceToolError.invalid("This MCP caller was archived, removed, or moved to another execution owner.")
      }
    }
  }
}

extension WorkspaceDatabase {
  public func requireMCPCaller(_ sessionID: String) async throws {
    try await read { try $0.requireMCPCaller(sessionID) }
  }
}

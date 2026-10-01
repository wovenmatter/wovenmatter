import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  public func mutateConversation(id: String, mutation: WorkspaceConversationMutation) throws {
    try transaction {
      let restoring: Bool = if case .restore = mutation { true } else { false }
      let rows = try historyRowsUnlocked("""
        SELECT id FROM dashboard_conversations
        WHERE id = ? AND desktop_owned = 1 AND authority_kind = 'device_owned'
          AND governing_plane = 'wovenmatter_macos' AND is_archived = 0
          AND deleted_at IS \(restoring ? "NOT NULL" : "NULL")
        """, values: [id])
      guard !rows.isEmpty else { throw WorkspaceConversationActionError.unavailable }
      let timestamp = Self.timestamp(Date())
      switch mutation {
      case .setPinned(let pinned):
        try toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_pinned = ?, updated_at = ? WHERE id = ?",
          [pinned ? "1" : "0", timestamp, id])
      case .rename(let title):
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw WorkspaceConversationActionError.emptyTitle }
        guard !cleanTitle.contains("\0"), cleanTitle.utf8.count <= 4_096 else {
          throw WorkspaceConversationActionError.invalidTitle
        }
        try toolsExecuteUnlocked("""
          INSERT INTO desktop_conversation_titles(conversation_id, title) VALUES (?, ?)
          ON CONFLICT(conversation_id) DO UPDATE SET title = excluded.title
          """, [id, cleanTitle])
        try toolsExecuteUnlocked("UPDATE dashboard_conversations SET title = ?, updated_at = ? WHERE id = ?",
          [cleanTitle, timestamp, id])
        try toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET title = ?, updated_at = ? WHERE conversation_id = ?",
          [cleanTitle, timestamp, id])
      case .moveToTrash:
        // Recheck at the write boundary, including work admitted after the menu opened.
        if let run = try historyRowsUnlocked("""
          SELECT status FROM dashboard_runs WHERE conversation_id = ?
            AND status IN ('queued', 'accepted', 'running', 'uncertain') LIMIT 1
          """, values: [id]).first {
          // A lost continuation receipt is still unresolved native work even if
          // the original prompt has finished. PR84 owns exact-ID reconciliation.
          throw run.objectValue?["status"]?.stringValue == "uncertain"
            ? WorkspaceConversationActionError.pendingInput : WorkspaceConversationActionError.running
        }
        // Native OpenCode work can exist before its first normalized dashboard run.
        guard try historyRowsUnlocked("""
          SELECT 1 FROM desktop_opencode_sessions WHERE conversation_id = ?
            AND json_extract(snapshot_json, '$.active') = 1 LIMIT 1
          """, values: [id]).isEmpty else { throw WorkspaceConversationActionError.running }
        guard try historyRowsUnlocked("""
          SELECT 1 FROM desktop_opencode_submissions WHERE conversation_id = ?
            AND status IN ('sending', 'uncertain') LIMIT 1
          """, values: [id]).isEmpty else { throw WorkspaceConversationActionError.pendingInput }
        try toolsExecuteUnlocked("""
          UPDATE dashboard_conversations SET deleted_at = ?, updated_at = ?,
            original_folder_id = folder_id WHERE id = ?
          """, [timestamp, timestamp, id])
        try toolsExecuteUnlocked("""
          UPDATE workspace_session_timers SET is_paused = 1, pending_delivery_id = NULL WHERE session_id = ?
          """, [id])
        try toolsExecuteUnlocked("""
          UPDATE workspace_session_deliveries SET status = 'cancelled'
          WHERE (target_id = ? OR source_id = ?)
            AND (status = 'queued' OR (status = 'sending' AND transport_started = 0))
          """, [id, id])
      case .restore:
        // A folder may have been removed while this chat was in Trash.
        try toolsExecuteUnlocked("""
          UPDATE dashboard_conversations SET deleted_at = NULL, updated_at = ?,
            folder_id = (SELECT id FROM folders WHERE id = original_folder_id AND user_id = ?), original_folder_id = NULL
          WHERE id = ?
          """, [timestamp, try localMutationOperatorIDUnlocked(), id])
      }
    }
  }

  public func trashedConversations() throws -> [WorkspaceTrashedConversation] {
    try withLock {
      try historyRowsUnlocked("""
        SELECT id, title, deleted_at FROM dashboard_conversations
        WHERE desktop_owned = 1 AND authority_kind = 'device_owned'
          AND governing_plane = 'wovenmatter_macos' AND is_archived = 0 AND deleted_at IS NOT NULL
        ORDER BY deleted_at DESC, id
        """, values: []).map { row in
          guard let value = row.objectValue, let id = value["id"]?.stringValue,
                let title = value["title"]?.stringValue, let date = value["deleted_at"]?.stringValue else {
            throw WorkspaceDatabaseError.corruptRow
          }
          return WorkspaceTrashedConversation(id: id, title: title, deletedAt: date)
        }
    }
  }
}

// Keep each mutation inside one complete worker transaction.
extension WorkspaceDatabase {
  public func mutateConversation(id: String, mutation: WorkspaceConversationMutation) async throws {
    try await write { try $0.mutateConversation(id: id, mutation: mutation) }
  }

  public func trashedConversations() async throws -> [WorkspaceTrashedConversation] {
    try await read { try $0.trashedConversations() }
  }
}

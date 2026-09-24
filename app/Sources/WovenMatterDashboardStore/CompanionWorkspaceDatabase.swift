import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabase {
  public func companionWorkspaceID() throws -> String {
    try withLock { try companionWorkspaceIDUnlocked() }
  }

  func companionWorkspaceIDUnlocked() throws -> String {
    let statement = try prepareUnlocked("SELECT workspace_id FROM companion_workspace WHERE singleton = 1")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
    return try text(statement, column: 0)
  }

  public func companionSnapshot(bodyByteBudget: Int = 1_024 * 1_024) throws -> CompanionSnapshot {
    try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      let folders = try companionIDsUnlocked("SELECT id FROM folders WHERE user_id = ? ORDER BY position, id", bindings: [operatorID])
      let notes = try companionIDsUnlocked("SELECT id FROM notes WHERE user_id = ? AND deleted_at IS NULL ORDER BY updated_at DESC, id", bindings: [operatorID])
      let conversations = try companionIDsUnlocked("SELECT id FROM dashboard_conversations WHERE (user_id = ? OR desktop_owned = 1) AND deleted_at IS NULL AND is_archived = 0 ORDER BY updated_at DESC, id", bindings: [operatorID])
      var remainingBodyBytes = max(0, min(bodyByteBudget, 4 * 1_024 * 1_024))
      return try CompanionSnapshot(
        workspaceID: companionWorkspaceIDUnlocked(), cursor: companionCursorUnlocked(),
        folders: folders.compactMap { try companionFolderUnlocked(id: $0) },
        notes: notes.compactMap { try companionNoteUnlocked(id: $0).map { companionBudgetedNote($0, remainingBytes: &remainingBodyBytes) } },
        conversations: conversations.compactMap { try companionConversationUnlocked(id: $0) }
      )
    }
  }

  public func companionNote(id: String) throws -> CompanionNote? {
    try withLock { try companionNoteUnlocked(id: id) }
  }

  public func companionChanges(after cursor: Int64, limit: Int = 200) throws -> CompanionChangePage {
    try transaction {
      let workspaceID = try companionWorkspaceIDUnlocked()
      let current = try companionCursorUnlocked()
      let oldestStatement = try prepareUnlocked("SELECT COALESCE(MIN(cursor), 0) FROM companion_changes")
      defer { sqlite3_finalize(oldestStatement) }
      guard sqlite3_step(oldestStatement) == SQLITE_ROW else { throw stepError() }
      let oldest = sqlite3_column_int64(oldestStatement, 0)
      guard cursor >= 0, cursor <= current, oldest == 0 || cursor >= oldest - 1 else {
        return CompanionChangePage(workspaceID: workspaceID, cursor: current, resetRequired: true)
      }
      let statement = try prepareUnlocked("SELECT cursor, kind, resource_id, revision, deleted FROM companion_changes WHERE cursor > ? ORDER BY cursor LIMIT ?")
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, cursor)
      sqlite3_bind_int(statement, 2, Int32(min(max(limit, 1), CompanionProtocol.maximumChangePage)))
      var changes: [CompanionChange] = []
      var scannedCursor = cursor
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else { throw stepError() }
        scannedCursor = sqlite3_column_int64(statement, 0)
        guard let kind = CompanionChange.ResourceKind(rawValue: try text(statement, column: 1)) else { continue }
        let id = try text(statement, column: 2)
        var change = CompanionChange(cursor: sqlite3_column_int64(statement, 0), resourceKind: kind, resourceID: id,
                                     operation: sqlite3_column_int(statement, 4) == 0 ? .upsert : .delete,
                                     revision: sqlite3_column_int64(statement, 3))
        // Changes are invalidations with the latest canonical value; a page is
        // transactionally consistent and may safely coalesce intervening edits.
        switch kind {
        case .folder:
          change.folder = try companionFolderUnlocked(id: id)
          change.operation = change.folder == nil ? .delete : .upsert
          change.revision = change.folder?.revision ?? change.revision
        case .note:
          change.note = try companionNoteUnlocked(id: id)
          change.operation = change.note == nil ? .delete : .upsert
          change.revision = change.note?.revision ?? change.revision
        case .conversation:
          change.conversation = try companionConversationUnlocked(id: id)
          change.operation = change.conversation == nil ? .delete : .upsert
        case .transcript, .providers: break
        }
        changes.removeAll { $0.resourceKind == change.resourceKind && $0.resourceID == change.resourceID }
        changes.append(change)
      }
      var remainingBodyBytes = 512 * 1_024
      for index in changes.indices {
        if let note = changes[index].note { changes[index].note = companionBudgetedNote(note, remainingBytes: &remainingBodyBytes) }
      }
      let next = scannedCursor == cursor ? current : scannedCursor
      return CompanionChangePage(workspaceID: workspaceID, cursor: next, changes: changes, hasMore: next < current)
    }
  }

  func companionCursorUnlocked() throws -> Int64 {
    // sqlite_sequence preserves the high-water mark if a log is compacted.
    let statement = try prepareUnlocked("SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'companion_changes'), 0)")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return sqlite3_column_int64(statement, 0)
  }

  func companionIDsUnlocked(_ sql: String, bindings: [String]) throws -> [String] {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() { try bind(value, at: Int32(offset + 1), to: statement) }
    var result: [String] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return result }
      guard code == SQLITE_ROW else { throw stepError() }
      result.append(try text(statement, column: 0))
    }
  }

  func companionVersionUnlocked(kind: String, id: String) throws -> (revision: Int64, deleted: Bool)? {
    let statement = try prepareUnlocked("SELECT revision, deleted FROM companion_versions WHERE kind = ? AND resource_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind(kind, at: 1, to: statement); try bind(id, at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return (sqlite3_column_int64(statement, 0), sqlite3_column_int(statement, 1) != 0)
  }

  func companionFolderUnlocked(id: String) throws -> CompanionFolder? {
    let statement = try prepareUnlocked("SELECT id, name, updated_at FROM folders WHERE id = ? AND user_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement); try bind(localMutationOperatorIDUnlocked(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return try CompanionFolder(id: text(statement, column: 0), name: text(statement, column: 1),
                               revision: companionVersionUnlocked(kind: "folder", id: id)?.revision ?? 1,
                               updatedAt: text(statement, column: 2))
  }

  func companionNoteUnlocked(id: String) throws -> CompanionNote? {
    let statement = try prepareUnlocked("SELECT id, folder_id, title, content, updated_at FROM notes WHERE id = ? AND user_id = ? AND deleted_at IS NULL")
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement); try bind(localMutationOperatorIDUnlocked(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return try CompanionNote(id: text(statement, column: 0), folderID: optionalText(statement, column: 1),
                             title: text(statement, column: 2), content: text(statement, column: 3),
                             revision: companionVersionUnlocked(kind: "note", id: id)?.revision ?? 1,
                             updatedAt: text(statement, column: 4), kind: companionNoteKind(content: text(statement, column: 3)))
  }

  func companionBudgetedNote(_ note: CompanionNote, remainingBytes: inout Int) -> CompanionNote {
    var copy = note
    // Reserve JSON escaping overhead as well as raw bytes. Metadata remains
    // discoverable; omitted bodies are fetched individually by stable note ID.
    let cost = min(Int.max / 6, note.contentByteCount) * 6
    if note.contentByteCount <= 256 * 1_024, cost <= remainingBytes {
      remainingBytes -= cost
    } else {
      copy.content = ""
      copy.contentIncluded = false
    }
    return copy
  }

  func companionNoteKind(content: String) -> NoteArtifactKind? {
    guard let data = content.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .note }
    return (object["kind"] as? String).flatMap(NoteArtifactKind.init(rawValue:))
  }

  func companionConversationUnlocked(id: String) throws -> CompanionConversation? {
    let statement = try prepareUnlocked("""
      SELECT c.id, c.title, c.folder_id,
        CASE WHEN g.agent_id IS NOT NULL THEN 'gateway:' || g.agent_id
          WHEN s.remote_workspace_id IS NOT NULL THEN 'remote:' || s.remote_workspace_id || ':' || s.runtime_kind
          WHEN enrollment.id IS NOT NULL THEN 'buzz:' || enrollment.id
          WHEN s.runtime_kind IS NOT NULL THEN 'local:' || s.runtime_kind
          ELSE NULL END,
        COALESCE(s.runtime_kind, CASE WHEN g.agent_id IS NOT NULL THEN 'openclaw' ELSE NULL END),
        c.last_message_preview, c.updated_at,
        (SELECT id FROM dashboard_runs WHERE conversation_id = c.id AND status = 'running' ORDER BY created_at DESC LIMIT 1),
        s.remote_workspace_id
      FROM dashboard_conversations c LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id = c.id
      LEFT JOIN desktop_openclaw_gateway_sessions g ON g.conversation_id = c.id
      LEFT JOIN desktop_buzz_agent_enrollments enrollment
        ON enrollment.workspace_link_id = s.buzz_workspace_link_id AND enrollment.agent_id = s.buzz_agent_id
      WHERE c.id = ? AND (c.user_id = ? OR c.desktop_owned = 1) AND c.deleted_at IS NULL AND c.is_archived = 0
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement); try bind(localMutationOperatorIDUnlocked(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return try CompanionConversation(id: text(statement, column: 0), title: text(statement, column: 1),
      folderID: optionalText(statement, column: 2), providerID: optionalText(statement, column: 3),
      routeID: optionalText(statement, column: 3), runtimeKind: optionalText(statement, column: 4),
      activeRunID: optionalText(statement, column: 7), preview: optionalText(statement, column: 5) ?? "", updatedAt: text(statement, column: 6))
  }
}

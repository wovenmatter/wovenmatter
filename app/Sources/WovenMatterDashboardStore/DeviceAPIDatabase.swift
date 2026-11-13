import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  public func libraryID() throws -> String {
    try withLock { try libraryIDUnlocked() }
  }

  func libraryIDUnlocked() throws -> String {
    let statement = try prepareUnlocked("SELECT library_id FROM library_identity WHERE singleton = 1")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
    return try text(statement, column: 0)
  }

  public func librarySnapshot(bodyByteBudget: Int = 1_024 * 1_024) throws -> LibrarySnapshot {
    try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      let folders = try libraryIDsUnlocked("SELECT id FROM folders WHERE user_id = ? ORDER BY position, id", bindings: [operatorID])
      let notes = try libraryIDsUnlocked("SELECT id FROM notes WHERE user_id = ? AND deleted_at IS NULL ORDER BY updated_at DESC, id", bindings: [operatorID])
      let conversations = try libraryIDsUnlocked("SELECT id FROM dashboard_conversations WHERE (user_id = ? OR desktop_owned = 1) AND deleted_at IS NULL AND is_archived = 0 ORDER BY updated_at DESC, id", bindings: [operatorID])
      var remainingBodyBytes = max(0, min(bodyByteBudget, 4 * 1_024 * 1_024))
      return try LibrarySnapshot(
        workspaceID: libraryIDUnlocked(), cursor: libraryCursorUnlocked(),
        folders: folders.compactMap { try libraryFolderUnlocked(id: $0) },
        notes: notes.compactMap { try libraryNoteUnlocked(id: $0).map { libraryBudgetedNote($0, remainingBytes: &remainingBodyBytes) } },
        conversations: conversations.compactMap { try libraryConversationUnlocked(id: $0) }
      )
    }
  }

  public func libraryNote(id: String) throws -> LibraryNote? {
    try withLock { try libraryNoteUnlocked(id: id) }
  }

  public func libraryChanges(after cursor: Int64, limit: Int = 200) throws -> LibraryChangePage {
    try transaction {
      let workspaceID = try libraryIDUnlocked()
      let current = try libraryCursorUnlocked()
      let oldestStatement = try prepareUnlocked("SELECT COALESCE(MIN(cursor), 0) FROM device_sync_changes")
      defer { sqlite3_finalize(oldestStatement) }
      guard sqlite3_step(oldestStatement) == SQLITE_ROW else { throw stepError() }
      let oldest = sqlite3_column_int64(oldestStatement, 0)
      guard cursor >= 0, cursor <= current, oldest == 0 || cursor >= oldest - 1 else {
        return LibraryChangePage(workspaceID: workspaceID, cursor: current, resetRequired: true)
      }
      let statement = try prepareUnlocked("SELECT cursor, kind, resource_id, revision, deleted FROM device_sync_changes WHERE cursor > ? ORDER BY cursor LIMIT ?")
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, cursor)
      sqlite3_bind_int(statement, 2, Int32(min(max(limit, 1), LibraryProtocol.maximumChangePage)))
      var changes: [LibraryChange] = []
      var scannedCursor = cursor
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else { throw stepError() }
        scannedCursor = sqlite3_column_int64(statement, 0)
        guard let kind = LibraryChange.ResourceKind(rawValue: try text(statement, column: 1)) else { continue }
        let id = try text(statement, column: 2)
        var change = LibraryChange(cursor: sqlite3_column_int64(statement, 0), resourceKind: kind, resourceID: id,
                                     operation: sqlite3_column_int(statement, 4) == 0 ? .upsert : .delete,
                                     revision: sqlite3_column_int64(statement, 3))
        // Changes are invalidations with the latest canonical value; a page is
        // transactionally consistent and may safely coalesce intervening edits.
        switch kind {
        case .folder:
          change.folder = try libraryFolderUnlocked(id: id)
          change.operation = change.folder == nil ? .delete : .upsert
          change.revision = change.folder?.revision ?? change.revision
        case .note:
          change.note = try libraryNoteUnlocked(id: id)
          change.operation = change.note == nil ? .delete : .upsert
          change.revision = change.note?.revision ?? change.revision
        case .conversation:
          change.conversation = try libraryConversationUnlocked(id: id)
          change.operation = change.conversation == nil ? .delete : .upsert
        case .transcript, .providers: break
        }
        changes.removeAll { $0.resourceKind == change.resourceKind && $0.resourceID == change.resourceID }
        changes.append(change)
      }
      var remainingBodyBytes = 512 * 1_024
      for index in changes.indices {
        if let note = changes[index].note { changes[index].note = libraryBudgetedNote(note, remainingBytes: &remainingBodyBytes) }
      }
      let next = scannedCursor == cursor ? current : scannedCursor
      return LibraryChangePage(workspaceID: workspaceID, cursor: next, changes: changes, hasMore: next < current)
    }
  }

  func libraryCursorUnlocked() throws -> Int64 {
    // sqlite_sequence preserves the high-water mark if a log is compacted.
    let statement = try prepareUnlocked("SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'device_sync_changes'), 0)")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return sqlite3_column_int64(statement, 0)
  }

  func libraryIDsUnlocked(_ sql: String, bindings: [String]) throws -> [String] {
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

  func libraryVersionUnlocked(kind: String, id: String) throws -> (revision: Int64, deleted: Bool)? {
    let statement = try prepareUnlocked("SELECT revision, deleted FROM device_sync_revisions WHERE kind = ? AND resource_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind(kind, at: 1, to: statement); try bind(id, at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return (sqlite3_column_int64(statement, 0), sqlite3_column_int(statement, 1) != 0)
  }

  func libraryFolderUnlocked(id: String) throws -> LibraryFolder? {
    let statement = try prepareUnlocked("SELECT id, name, updated_at, (SELECT workspace_id FROM folder_execution_roots WHERE folder_id=folders.id), (SELECT root_path FROM folder_execution_roots WHERE folder_id=folders.id) FROM folders WHERE id = ? AND user_id = ?")
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement); try bind(localMutationOperatorIDUnlocked(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return try LibraryFolder(id: text(statement, column: 0), name: text(statement, column: 1),
                               revision: libraryVersionUnlocked(kind: "folder", id: id)?.revision ?? 1,
                               updatedAt: text(statement, column: 2),
                               execution: optionalText(statement, column: 3).flatMap { owner in
                                 optionalText(statement, column: 4).map { .init(workspaceID: owner, rootPath: $0) }
                               })
  }

  func libraryNoteUnlocked(id: String) throws -> LibraryNote? {
    let statement = try prepareUnlocked("SELECT id, folder_id, title, content, updated_at, is_pinned FROM notes WHERE id = ? AND user_id = ? AND deleted_at IS NULL")
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement); try bind(localMutationOperatorIDUnlocked(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    // Devices see the document; synchronization clocks stay in this store.
    let content = NoteSync.strip(try text(statement, column: 3))
    return try LibraryNote(id: text(statement, column: 0), folderID: optionalText(statement, column: 1),
                             title: text(statement, column: 2), content: content,
                             revision: libraryVersionUnlocked(kind: "note", id: id)?.revision ?? 1,
                             updatedAt: text(statement, column: 4), kind: libraryNoteKind(content: content), isPinned: sqlite3_column_int(statement, 5) != 0)
  }

  func libraryBudgetedNote(_ note: LibraryNote, remainingBytes: inout Int) -> LibraryNote {
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

  func libraryNoteKind(content: String) -> NoteArtifactKind? {
    guard let data = content.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .note }
    return (object["kind"] as? String).flatMap(NoteArtifactKind.init(rawValue:))
  }

  func libraryConversationUnlocked(id: String) throws -> LibraryConversation? {
    if let federated = try federationConversationUnlocked(id) { return federated }
    let statement = try prepareUnlocked("""
      SELECT c.id, c.title, c.folder_id,
        CASE WHEN g.agent_id IS NOT NULL THEN 'gateway:' || g.agent_id
          WHEN s.remote_workspace_id IS NOT NULL THEN 'remote:' || s.remote_workspace_id || ':' || s.runtime_kind
          WHEN s.runtime_kind IS NOT NULL THEN 'local:' || s.runtime_kind
          ELSE NULL END,
        COALESCE(s.runtime_kind, CASE WHEN g.agent_id IS NOT NULL THEN 'openclaw' ELSE NULL END),
        c.last_message_preview, c.updated_at,
        (SELECT id FROM dashboard_runs WHERE conversation_id = c.id AND status = 'running' ORDER BY created_at DESC LIMIT 1),
        s.remote_workspace_id, c.is_pinned
      FROM dashboard_conversations c LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id = c.id
      LEFT JOIN desktop_openclaw_gateway_sessions g ON g.conversation_id = c.id
      WHERE c.id = ? AND (c.user_id = ? OR c.desktop_owned = 1) AND c.deleted_at IS NULL AND c.is_archived = 0
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement); try bind(localMutationOperatorIDUnlocked(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw stepError() }
    return try LibraryConversation(id: text(statement, column: 0), title: text(statement, column: 1),
      folderID: optionalText(statement, column: 2), providerID: optionalText(statement, column: 3),
      routeID: optionalText(statement, column: 3), runtimeKind: optionalText(statement, column: 4),
      activeRunID: optionalText(statement, column: 7), preview: optionalText(statement, column: 5) ?? "", updatedAt: text(statement, column: 6), isPinned: sqlite3_column_int(statement, 9) != 0)
  }
}

extension WorkspaceDatabase {
  public func libraryID() async throws -> String {
    try await read { try $0.libraryID() }
  }
  public func librarySnapshot(bodyByteBudget: Int = 1_024 * 1_024) async throws -> LibrarySnapshot {
    try await read { try $0.librarySnapshot(bodyByteBudget: bodyByteBudget) }
  }
  public func libraryNote(id: String) async throws -> LibraryNote? {
    try await read { try $0.libraryNote(id: id) }
  }
  public func libraryChanges(after cursor: Int64, limit: Int = 200) async throws -> LibraryChangePage {
    try await read { try $0.libraryChanges(after: cursor, limit: limit) }
  }
}

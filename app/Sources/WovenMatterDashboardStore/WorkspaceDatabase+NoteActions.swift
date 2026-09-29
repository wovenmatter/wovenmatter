import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  public func noteActionRevision(id: String, trashed: Bool = false) throws -> String {
    try withLock {
      let operatorID = try localMutationOperatorIDUnlocked()
      guard let row = try historyRowsUnlocked("""
        SELECT updated_at FROM notes WHERE id = ? AND user_id = ?
          AND deleted_at IS \(trashed ? "NOT NULL" : "NULL")
        """, values: [id, operatorID]).first?.objectValue,
        let revision = row["updated_at"]?.stringValue else { throw WorkspaceNoteMutationError.noteNotFound }
      return revision
    }
  }

  public func mutateNote(id: String, mutation: WorkspaceNoteMutation, expectedRevision: String) throws {
    try transaction {
      let restoring: Bool = if case .restore = mutation { true } else { false }
      let current = try noteActionRevision(id: id, trashed: restoring)
      guard current == expectedRevision else { throw WorkspaceNoteMutationError.revisionConflict }
      let operatorID = try localMutationOperatorIDUnlocked()
      let revision = if case .setPinned = mutation { current } else { try nextNoteRevisionUnlocked(id: id) }
      switch mutation {
      case .setPinned(let pinned):
        // Pin state is not document activity. The dashboard UPDATE trigger still
        // refreshes presentation without changing the note's revision or order.
        try toolsExecuteUnlocked("UPDATE notes SET is_pinned = ? WHERE id = ? AND user_id = ?",
          [pinned ? "1" : "0", id, operatorID])
      case .rename(let title):
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw WorkspaceNoteActionError.emptyTitle }
        try checkpointNoteUnlocked(id: id, source: "before-rename", force: true)
        try toolsExecuteUnlocked("UPDATE notes SET title = ?, updated_at = ? WHERE id = ? AND user_id = ?",
          [title, revision, id, operatorID])
        try checkpointNoteUnlocked(id: id, source: "rename", force: true)
      case .moveToFolder(let folderID):
        try validateFolderUnlocked(id: folderID, operatorID: operatorID)
        try toolsExecuteUnlocked("""
          UPDATE notes SET folder_id = ?, position = (
            SELECT COALESCE(MAX(position), -1) + 1 FROM notes
            WHERE user_id = ? AND folder_id IS ? AND deleted_at IS NULL AND id != ?
          ), updated_at = ? WHERE id = ? AND user_id = ?
          """, [folderID, operatorID, folderID, id, revision, id, operatorID])
      case .moveToTrash:
        // Keep the document, history, links, and pin intact. Only visibility changes.
        try checkpointNoteUnlocked(id: id, source: "before-trash", force: true)
        try toolsExecuteUnlocked("""
          UPDATE notes SET deleted_at = ?, original_folder_id = folder_id, updated_at = ?
          WHERE id = ? AND user_id = ?
          """, [revision, revision, id, operatorID])
      case .restore:
        try toolsExecuteUnlocked("""
          UPDATE notes SET deleted_at = NULL, folder_id = (
            SELECT id FROM folders WHERE id = notes.original_folder_id AND user_id = ?
          ), original_folder_id = NULL, updated_at = ? WHERE id = ? AND user_id = ?
          """, [operatorID, revision, id, operatorID])
      }
    }
  }

  public func trashedNotes() throws -> [WorkspaceTrashedNote] {
    try withLock {
      let operatorID = try localMutationOperatorIDUnlocked()
      return try historyRowsUnlocked("""
        SELECT id, title, deleted_at, is_pinned FROM notes
        WHERE user_id = ? AND deleted_at IS NOT NULL ORDER BY deleted_at DESC, id DESC
        """, values: [operatorID]).map { value in
          guard let row = value.objectValue, let id = row["id"]?.stringValue,
                let title = row["title"]?.stringValue, let deletedAt = row["deleted_at"]?.stringValue else {
            throw WorkspaceDatabaseError.corruptRow
          }
          return WorkspaceTrashedNote(id: id, title: title, deletedAt: deletedAt,
            isPinned: row["is_pinned"]?.intValue == 1)
        }
    }
  }

  public func noteExport(id: String, format: WorkspaceNoteExportFormat, expectedRevision: String) throws -> WorkspaceNoteExportContent {
    try withLock {
      let operatorID = try localMutationOperatorIDUnlocked()
      let note = try noteForEditingUnlocked(id: id, operatorID: operatorID)
      guard note.revision == expectedRevision else { throw WorkspaceNoteMutationError.revisionConflict }
      return try NoteDocument.decode(note.content).exported(title: note.title, format: format)
    }
  }
}

extension WorkspaceDatabase {
  public func noteActionRevision(id: String, trashed: Bool = false) async throws -> String {
    try await read { try $0.noteActionRevision(id: id, trashed: trashed) }
  }

  public func mutateNote(id: String, mutation: WorkspaceNoteMutation, expectedRevision: String) async throws {
    try await write { try $0.mutateNote(id: id, mutation: mutation, expectedRevision: expectedRevision) }
  }

  public func trashedNotes() async throws -> [WorkspaceTrashedNote] {
    try await read { try $0.trashedNotes() }
  }

  public func noteExport(id: String, format: WorkspaceNoteExportFormat, expectedRevision: String) async throws -> WorkspaceNoteExportContent {
    try await read { try $0.noteExport(id: id, format: format, expectedRevision: expectedRevision) }
  }
}

import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

extension WorkspaceDatabase {
  @discardableResult
  public func createFolder(
    id: UUID = UUID(),
    name: String,
    createdAt: Date = Date()
  ) throws -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw WorkspaceFolderMutationError.emptyName
    }

    return try transaction {
      let folderID = id.uuidString.lowercased()
      let operatorID = try localMutationOperatorIDUnlocked()
      let timestamp = Self.timestamp(createdAt)
      let positionStatement = try prepareUnlocked("""
        SELECT COALESCE(MAX(position), -1) + 1
        FROM folders
        WHERE user_id = ?
        """)
      defer { sqlite3_finalize(positionStatement) }
      try bind(operatorID, at: 1, to: positionStatement)
      guard sqlite3_step(positionStatement) == SQLITE_ROW else {
        throw stepError()
      }
      let position = sqlite3_column_int64(positionStatement, 0)

      let insert = try prepareUnlocked("""
        INSERT INTO folders (
          id, user_id, name, icon, position, is_pinned, created_at, updated_at
        ) VALUES (?, ?, ?, 'folder', ?, 0, ?, ?)
        """)
      defer { sqlite3_finalize(insert) }
      try bind(folderID, at: 1, to: insert)
      try bind(operatorID, at: 2, to: insert)
      try bind(normalizedName, at: 3, to: insert)
      guard sqlite3_bind_int64(insert, 4, position) == SQLITE_OK else {
        throw bindError()
      }
      try bind(timestamp, at: 5, to: insert)
      try bind(timestamp, at: 6, to: insert)
      try stepDone(insert)

      return folderID
    }
  }

  @discardableResult
  public func renameFolder(
    id: String,
    name: String,
    updatedAt: Date = Date()
  ) throws -> Bool {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw WorkspaceFolderMutationError.emptyName
    }

    return try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      let update = try prepareUnlocked("""
        UPDATE folders
        SET name = ?, updated_at = ?
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(update) }
      try bind(normalizedName, at: 1, to: update)
      try bind(Self.timestamp(updatedAt), at: 2, to: update)
      try bind(id, at: 3, to: update)
      try bind(operatorID, at: 4, to: update)
      try stepDone(update)
      guard sqlite3_changes(connection) == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  @discardableResult
  public func setFolderPinned(
    id: String,
    isPinned: Bool,
    updatedAt: Date = Date()
  ) throws -> Bool {
    try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      let update = try prepareUnlocked("""
        UPDATE folders
        SET is_pinned = ?, updated_at = ?
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(update) }
      guard sqlite3_bind_int(update, 1, isPinned ? 1 : 0) == SQLITE_OK else {
        throw bindError()
      }
      try bind(Self.timestamp(updatedAt), at: 2, to: update)
      try bind(id, at: 3, to: update)
      try bind(operatorID, at: 4, to: update)
      try stepDone(update)
      guard sqlite3_changes(connection) == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  @discardableResult
  public func moveFolder(
    id: String,
    direction: WorkspaceFolderMoveDirection,
    updatedAt: Date = Date()
  ) throws -> Bool {
    return try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      let isPinned: Bool = try {
        let sourceLookup = try prepareUnlocked("""
          SELECT is_pinned
          FROM folders
          WHERE id = ? AND user_id = ?
          """)
        defer { sqlite3_finalize(sourceLookup) }
        try bind(id, at: 1, to: sourceLookup)
        try bind(operatorID, at: 2, to: sourceLookup)
        let sourceCode = sqlite3_step(sourceLookup)
        guard sourceCode == SQLITE_ROW else {
          if sourceCode == SQLITE_DONE {
            throw WorkspaceFolderMutationError.folderNotFound
          }
          throw stepError()
        }
        return sqlite3_column_int(sourceLookup, 0) != 0
      }()

      var section: [(id: String, name: String, position: Int64)] = try {
        let sectionLookup = try prepareUnlocked("""
          SELECT id, name, position
          FROM folders
          WHERE user_id = ? AND is_pinned = ?
          """)
        defer { sqlite3_finalize(sectionLookup) }
        try bind(operatorID, at: 1, to: sectionLookup)
        guard sqlite3_bind_int(sectionLookup, 2, isPinned ? 1 : 0) == SQLITE_OK else {
          throw bindError()
        }

        var values: [(id: String, name: String, position: Int64)] = []
        while true {
          let code = sqlite3_step(sectionLookup)
          if code == SQLITE_DONE { break }
          guard code == SQLITE_ROW else { throw stepError() }
          values.append((
            id: try text(sectionLookup, column: 0),
            name: try text(sectionLookup, column: 1),
            position: sqlite3_column_int64(sectionLookup, 2)
          ))
        }
        return values
      }()
      section.sort {
        if $0.position != $1.position { return $0.position < $1.position }
        let nameComparison = $0.name.localizedCaseInsensitiveCompare($1.name)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return $0.id < $1.id
      }
      guard let sourceIndex = section.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFolderMutationError.folderNotFound
      }
      let targetIndex: Int
      switch direction {
      case .up:
        guard sourceIndex > 0 else { return false }
        targetIndex = sourceIndex - 1
      case .down:
        guard sourceIndex < section.count - 1 else { return false }
        targetIndex = sourceIndex + 1
      }
      section.swapAt(sourceIndex, targetIndex)

      let update = try prepareUnlocked("""
        UPDATE folders
        SET position = ?, updated_at = ?
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(update) }
      let timestamp = Self.timestamp(updatedAt)
      var changed = false
      for (offset, folder) in section.enumerated() {
        let position = Int64(offset)
        guard folder.position != position else { continue }
        sqlite3_reset(update)
        sqlite3_clear_bindings(update)
        guard sqlite3_bind_int64(update, 1, position) == SQLITE_OK else {
          throw bindError()
        }
        try bind(timestamp, at: 2, to: update)
        try bind(folder.id, at: 3, to: update)
        try bind(operatorID, at: 4, to: update)
        try stepDone(update)
        guard sqlite3_changes(connection) == 1 else {
          throw WorkspaceFolderMutationError.folderNotFound
        }
        changed = true
      }

      return changed
    }
  }

  @discardableResult
  public func deleteFolder(
    id: String
  ) throws -> Bool {
    try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      let existing = try prepareUnlocked("""
        SELECT 1 FROM folders
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(existing) }
      try bind(id, at: 1, to: existing)
      try bind(operatorID, at: 2, to: existing)
      guard sqlite3_step(existing) == SQLITE_ROW else {
        throw WorkspaceFolderMutationError.folderNotFound
      }
      let delete = try prepareUnlocked("""
        DELETE FROM folders
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(delete) }
      try bind(id, at: 1, to: delete)
      try bind(operatorID, at: 2, to: delete)
      try stepDone(delete)
      guard sqlite3_changes(connection) == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  @discardableResult
  public func createNote(
    id: UUID = UUID(),
    folderID: String?,
    title: String = "Untitled Note",
    content: String = "",
    kind: NoteArtifactKind = .note,
    createdAt: Date = Date()
  ) throws -> String {
    try transaction {
      let content = try (content.isEmpty
        ? NoteDocument(kind: kind)
        : NoteDocument.decode(content)).encoded()
      let noteID = id.uuidString.lowercased()
      let operatorID = try localMutationOperatorIDUnlocked()
      try validateFolderUnlocked(id: folderID, operatorID: operatorID)
      let timestamp = Self.timestamp(createdAt)
      let position = try nextNotePositionUnlocked(
        folderID: folderID,
        operatorID: operatorID
      )

      let note = try prepareUnlocked("""
        INSERT INTO notes (
          id, user_id, folder_id, title, content, snippet, is_pinned, position,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
        """)
      defer { sqlite3_finalize(note) }
      try bind(noteID, at: 1, to: note)
      try bind(operatorID, at: 2, to: note)
      try bindNullable(folderID, at: 3, to: note)
      try bind(title, at: 4, to: note)
      try bind(content, at: 5, to: note)
      try bind(Self.noteSnippet(content), at: 6, to: note)
      guard sqlite3_bind_int64(note, 7, Int64(position)) == SQLITE_OK else {
        throw bindError()
      }
      try bind(timestamp, at: 8, to: note)
      try bind(timestamp, at: 9, to: note)
      try stepDone(note)

      return noteID
    }
  }

  @discardableResult
  public func updateNote(
    id: String,
    title: String,
    content: String,
    updatedAt: Date = Date()
  ) throws -> Bool {
    try transaction {
      let content = try NoteDocument.decode(content).encoded()
      let operatorID = try localMutationOperatorIDUnlocked()
      let update = try prepareUnlocked("""
        UPDATE notes
        SET title = ?, content = ?, snippet = ?, updated_at = ?
        WHERE id = ? AND user_id = ? AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(update) }
      try bind(title, at: 1, to: update)
      try bind(content, at: 2, to: update)
      try bind(Self.noteSnippet(content), at: 3, to: update)
      try bind(Self.timestamp(updatedAt), at: 4, to: update)
      try bind(id, at: 5, to: update)
      try bind(operatorID, at: 6, to: update)
      try stepDone(update)
      guard sqlite3_changes(connection) == 1 else {
        throw WorkspaceNoteMutationError.noteNotFound
      }

      return true
    }
  }

  @discardableResult
  public func persistNoteDraft(
    id: String,
    title: String,
    content: String,
    folderID: String? = nil,
    createdAt: String? = nil,
    updatedAt: Date = Date()
  ) throws -> Bool {
    try transaction {
      let content = try NoteDocument.decode(content).encoded()
      let operatorID = try localMutationOperatorIDUnlocked()
      let timestamp = Self.timestamp(updatedAt)
      let update = try prepareUnlocked("""
        UPDATE notes
        SET title = ?, content = ?, snippet = ?, updated_at = ?
        WHERE id = ? AND user_id = ? AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(update) }
      try bind(title, at: 1, to: update)
      try bind(content, at: 2, to: update)
      try bind(Self.noteSnippet(content), at: 3, to: update)
      try bind(timestamp, at: 4, to: update)
      try bind(id, at: 5, to: update)
      try bind(operatorID, at: 6, to: update)
      try stepDone(update)

      let restoredMissingNote = sqlite3_changes(connection) != 1
      if restoredMissingNote {
        try validateFolderUnlocked(id: folderID, operatorID: operatorID)
        let position = try nextNotePositionUnlocked(
          folderID: folderID,
          operatorID: operatorID
        )
        let insert = try prepareUnlocked("""
          INSERT INTO notes (
            id, user_id, folder_id, title, content, snippet, is_pinned,
            position, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
          """)
        defer { sqlite3_finalize(insert) }
        try bind(id, at: 1, to: insert)
        try bind(operatorID, at: 2, to: insert)
        try bindNullable(folderID, at: 3, to: insert)
        try bind(title, at: 4, to: insert)
        try bind(content, at: 5, to: insert)
        try bind(Self.noteSnippet(content), at: 6, to: insert)
        guard sqlite3_bind_int64(insert, 7, Int64(position)) == SQLITE_OK else {
          throw bindError()
        }
        try bind(createdAt ?? timestamp, at: 8, to: insert)
        try bind(timestamp, at: 9, to: insert)
        try stepDone(insert)
      }

      return true
    }
  }

  public func readNoteForEditing(id: String) throws -> NoteEditingResponse {
    try lock.withLock {
      let operatorID = try localMutationOperatorIDUnlocked()
      let note = try noteForEditingUnlocked(id: id, operatorID: operatorID)
      return NoteEditingResponse(
        success: true,
        noteID: id,
        title: note.title,
        revision: note.revision,
        document: NoteDocument.decode(note.content)
      )
    }
  }

  public func applyNoteEdits(_ request: NoteEditingRequest) throws -> NoteEditingResponse {
    try transaction {
      try applyNoteEditsUnlocked(request)
    }
  }

  func applyNoteEditsUnlocked(
    _ request: NoteEditingRequest
  ) throws -> NoteEditingResponse {
    let operatorID = try localMutationOperatorIDUnlocked()
    let note = try noteForEditingUnlocked(id: request.noteID, operatorID: operatorID)
    if let expected = request.expectedRevision, expected != note.revision {
      throw WorkspaceNoteMutationError.revisionConflict
    }
    guard !request.operations.isEmpty else {
      return NoteEditingResponse(
        success: true, noteID: request.noteID, title: note.title,
        revision: note.revision, document: NoteDocument.decode(note.content)
      )
    }
    var document = NoteDocument.decode(note.content)
    if document.kind == .html,
       request.operations.contains(where: {
         if case .setTitle = $0 { true } else { false }
       }) {
      throw NoteEditError.artifactKindMismatch
    }
    let updatedTitle = try document.apply(request.operations) ?? note.title
    let content = try document.encoded()
    let revision = Self.timestamp(Date())
    let update = try prepareUnlocked("""
      UPDATE notes SET title = ?, content = ?, snippet = ?, updated_at = ?
      WHERE id = ? AND user_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(update) }
    try bind(updatedTitle, at: 1, to: update)
    try bind(content, at: 2, to: update)
    try bind(Self.noteSnippet(content), at: 3, to: update)
    try bind(revision, at: 4, to: update)
    try bind(request.noteID, at: 5, to: update)
    try bind(operatorID, at: 6, to: update)
    try stepDone(update)
    guard sqlite3_changes(connection) == 1 else {
      throw WorkspaceNoteMutationError.noteNotFound
    }
    return NoteEditingResponse(
      success: true, noteID: request.noteID, title: updatedTitle,
      revision: revision, document: document
    )
  }

  public func dashboardRecordCounts() throws -> DashboardRecordCounts {
    try lock.withLock {
      let operatorID = try canonicalWorkspaceOperatorIDUnlocked()
      func count(_ table: String, where predicate: String? = nil) throws -> Int {
        var sql = "SELECT COUNT(*) FROM \(table)"
        if let predicate {
          sql += " WHERE \(predicate)"
        }
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        if predicate?.contains("?") == true, let operatorID {
          try bind(operatorID, at: 1, to: statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
        return Int(sqlite3_column_int64(statement, 0))
      }

      let scoped = operatorID == nil ? nil : "user_id = ?"
      let activeScoped = operatorID == nil ? "deleted_at IS NULL" : "user_id = ? AND deleted_at IS NULL"
      let activeAgentScoped = operatorID == nil
        ? "deleted_at IS NULL"
        : "(user_id = ? OR desktop_owned = 1) AND deleted_at IS NULL"
      let activeConversationScoped = operatorID == nil
        ? "deleted_at IS NULL AND is_archived = 0"
        : "(user_id = ? OR desktop_owned = 1) AND deleted_at IS NULL AND is_archived = 0"
      let conversationChildScope = operatorID == nil ? nil : """
        conversation_id IN (
          SELECT id FROM dashboard_conversations
          WHERE (user_id = ? OR desktop_owned = 1)
            AND deleted_at IS NULL AND is_archived = 0
        )
        """

      return try DashboardRecordCounts(
        profiles: count("profiles", where: operatorID == nil ? nil : "id = ?"),
        folders: count("folders", where: scoped),
        notes: count("notes", where: activeScoped),
        agents: count("dashboard_agents", where: activeAgentScoped),
        conversations: count("dashboard_conversations", where: activeConversationScoped),
        messages: count("dashboard_messages", where: conversationChildScope),
        runs: count("dashboard_runs", where: conversationChildScope),
        calendarItems: count("dashboard_calendar_items", where: scoped)
      )
    }
  }

  public func calendarItems() throws -> [WorkspaceCalendarItemRecord] {
    try lock.withLock {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked() else { return [] }
      return try decodeCanonicalRowsUnlocked(
        """
        SELECT json_object(
          'id', id, 'user_id', user_id, 'kind', kind, 'title', title,
          'description', description, 'starts_at', starts_at,
          'ends_at', ends_at, 'all_day', all_day, 'status', status,
          'source', source, 'created_at', created_at, 'updated_at', updated_at
        )
        FROM dashboard_calendar_items
        WHERE user_id = ?
        ORDER BY starts_at, id
        """,
        operatorID: operatorID,
        as: WorkspaceCalendarItemRecord.self
      )
    }
  }

  @discardableResult
  public func createCalendarItem(
    id: UUID = UUID(),
    title: String,
    details: String? = nil,
    startsAt: Date,
    endsAt: Date?,
    allDay: Bool,
    createdAt: Date = Date()
  ) throws -> String {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty else {
      throw WorkspaceCalendarMutationError.emptyTitle
    }
    if let endsAt, endsAt <= startsAt {
      throw WorkspaceCalendarMutationError.invalidDateRange
    }
    let normalizedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)

    return try transaction {
      let itemID = id.uuidString.lowercased()
      let operatorID = try localMutationOperatorIDUnlocked()
      let timestamp = Self.timestamp(createdAt)
      let insert = try prepareUnlocked("""
        INSERT INTO dashboard_calendar_items (
          id, user_id, kind, title, description, starts_at, ends_at, all_day,
          status, source, created_at, updated_at
        ) VALUES (?, ?, 'event', ?, ?, ?, ?, ?, 'scheduled', 'user', ?, ?)
        """)
      defer { sqlite3_finalize(insert) }
      try bind(itemID, at: 1, to: insert)
      try bind(operatorID, at: 2, to: insert)
      try bind(normalizedTitle, at: 3, to: insert)
      try bindNullable(normalizedDetails?.isEmpty == true ? nil : normalizedDetails, at: 4, to: insert)
      try bind(Self.timestamp(startsAt), at: 5, to: insert)
      try bindNullable(endsAt.map(Self.timestamp), at: 6, to: insert)
      guard sqlite3_bind_int(insert, 7, allDay ? 1 : 0) == SQLITE_OK else {
        throw bindError()
      }
      try bind(timestamp, at: 8, to: insert)
      try bind(timestamp, at: 9, to: insert)
      try stepDone(insert)

      return itemID
    }
  }

}

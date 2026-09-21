import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

public enum WorkspaceNoteMutationError: LocalizedError, Equatable, Sendable {
  case folderNotFound
  case noteNotFound
  case revisionConflict

  public var errorDescription: String? {
    switch self {
    case .folderNotFound:
      "The selected folder is no longer available."
    case .noteNotFound:
      "The note is no longer available."
    case .revisionConflict:
      "The note changed since it was read. Read it again before applying edits."
    }
  }
}

public struct PendingRemoteNoteEdit: Equatable, Sendable {
  public let runID: String
  public let assistantMessageID: String
  public let noteID: String
  public let expectedRevision: String
  public let nonce: String
  public let noteKind: NoteArtifactKind
  public let assistantContent: String
}

// Note drafts, editing and mediated edit recovery within the original transactions.
extension WorkspaceDatabase {
  func insertNoteContextUnlocked(
    _ context: AgentNoteContext?,
    identifiers: LocalACPRunIdentifiers,
    conversationID: String,
    userID: String,
    governingPlane: String,
    authorityDeviceID: String?,
    authorityAgentID: String?,
    createdAt: Date
  ) throws {
    guard let context else { return }
    let timestamp = Self.timestamp(createdAt)
    let reference = try prepareUnlocked("""
      INSERT INTO dashboard_message_references (
        id, conversation_id, message_id, user_id, governing_plane,
        authority_kind, authority_device_id, authority_agent_id, desktop_owned,
        resource_type, resource_id, source, title_snapshot, folder_id_snapshot,
        revision_snapshot, created_at
      ) VALUES (?, ?, ?, ?, ?, 'device_owned', ?, ?, 1,
        'note', ?, 'open_note', ?, ?, ?, ?)
      """)
    defer { sqlite3_finalize(reference) }
    try bind(UUID().uuidString.lowercased(), at: 1, to: reference)
    try bind(conversationID, at: 2, to: reference)
    try bind(identifiers.userMessageID, at: 3, to: reference)
    try bind(userID, at: 4, to: reference)
    try bind(governingPlane, at: 5, to: reference)
    try bindNullable(authorityDeviceID, at: 6, to: reference)
    try bindNullable(authorityAgentID, at: 7, to: reference)
    try bind(context.noteID, at: 8, to: reference)
    try bind(context.title, at: 9, to: reference)
    try bindNullable(context.folderID, at: 10, to: reference)
    try bind(context.revision, at: 11, to: reference)
    try bind(timestamp, at: 12, to: reference)
    try stepDone(reference)

    let visibleContext = try prepareUnlocked("""
      INSERT INTO dashboard_run_visible_context (
        run_id, message_id, conversation_id, user_id, governing_plane,
        authority_kind, authority_device_id, authority_agent_id, desktop_owned,
        note_id, note_title_snapshot, folder_id_snapshot, revision_snapshot,
        created_at
      ) VALUES (?, ?, ?, ?, ?, 'device_owned', ?, ?, 1, ?, ?, ?, ?, ?)
      """)
    defer { sqlite3_finalize(visibleContext) }
    try bind(identifiers.runID, at: 1, to: visibleContext)
    try bind(identifiers.userMessageID, at: 2, to: visibleContext)
    try bind(conversationID, at: 3, to: visibleContext)
    try bind(userID, at: 4, to: visibleContext)
    try bind(governingPlane, at: 5, to: visibleContext)
    try bindNullable(authorityDeviceID, at: 6, to: visibleContext)
    try bindNullable(authorityAgentID, at: 7, to: visibleContext)
    try bind(context.noteID, at: 8, to: visibleContext)
    try bind(context.title, at: 9, to: visibleContext)
    try bindNullable(context.folderID, at: 10, to: visibleContext)
    try bind(context.revision, at: 11, to: visibleContext)
    try bind(timestamp, at: 12, to: visibleContext)
    try stepDone(visibleContext)

    if let nonce = context.remoteEditNonce,
       let kind = context.artifactKind {
      let pending = try prepareUnlocked("""
        INSERT INTO desktop_remote_note_edits (
          run_id, assistant_message_id, note_id, expected_revision,
          nonce, note_kind, state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
        """)
      defer { sqlite3_finalize(pending) }
      try bind(identifiers.runID, at: 1, to: pending)
      try bind(identifiers.assistantMessageID, at: 2, to: pending)
      try bind(context.noteID, at: 3, to: pending)
      try bind(context.revision, at: 4, to: pending)
      try bind(nonce, at: 5, to: pending)
      try bind(kind.rawValue, at: 6, to: pending)
      try bind(timestamp, at: 7, to: pending)
      try bind(timestamp, at: 8, to: pending)
      try stepDone(pending)
    }
  }

  public func pendingRemoteNoteEdits() throws -> [PendingRemoteNoteEdit] {
    try withLock {
      let statement = try prepareUnlocked("""
        SELECT edit.run_id, edit.assistant_message_id, edit.note_id,
          edit.expected_revision, edit.nonce, edit.note_kind, message.content
        FROM desktop_remote_note_edits AS edit
        JOIN dashboard_runs AS run ON run.id = edit.run_id
        JOIN dashboard_messages AS message
          ON message.id = edit.assistant_message_id AND message.run_id = edit.run_id
        WHERE edit.state = 'pending' AND run.status = 'completed'
        ORDER BY edit.created_at, edit.run_id
        """)
      defer { sqlite3_finalize(statement) }
      var rows: [PendingRemoteNoteEdit] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let kind = try text(statement, column: 5)
        guard let noteKind = NoteArtifactKind(rawValue: kind) else { continue }
        rows.append(PendingRemoteNoteEdit(
          runID: try text(statement, column: 0),
          assistantMessageID: try text(statement, column: 1),
          noteID: try text(statement, column: 2),
          expectedRevision: try text(statement, column: 3),
          nonce: try text(statement, column: 4),
          noteKind: noteKind,
          assistantContent: try text(statement, column: 6)
        ))
      }
      return rows
    }
  }

  public func applyPendingRemoteNoteEdit(
    _ pending: PendingRemoteNoteEdit,
    envelope: RemoteNoteEditEnvelope,
    visibleAssistantContent: String
  ) throws -> NoteEditingResponse {
    try transaction {
      let authorization = try prepareUnlocked("""
        SELECT run.status
        FROM desktop_remote_note_edits AS edit
        JOIN dashboard_runs AS run ON run.id = edit.run_id
        JOIN dashboard_run_visible_context AS context ON context.run_id = edit.run_id
        WHERE edit.run_id = ? AND edit.state = 'pending'
          AND edit.assistant_message_id = ? AND edit.note_id = ?
          AND edit.expected_revision = ? AND edit.nonce = ? AND edit.note_kind = ?
          AND context.note_id = edit.note_id
          AND context.revision_snapshot = edit.expected_revision
        """)
      defer { sqlite3_finalize(authorization) }
      try bind(pending.runID, at: 1, to: authorization)
      try bind(pending.assistantMessageID, at: 2, to: authorization)
      try bind(pending.noteID, at: 3, to: authorization)
      try bind(pending.expectedRevision, at: 4, to: authorization)
      try bind(pending.nonce, at: 5, to: authorization)
      try bind(pending.noteKind.rawValue, at: 6, to: authorization)
      guard sqlite3_step(authorization) == SQLITE_ROW,
            try text(authorization, column: 0) == "completed",
            envelope.nonce == pending.nonce,
            envelope.noteID == pending.noteID,
            envelope.expectedRevision == pending.expectedRevision else {
        throw RemoteNoteEditError.invalidEnvelope
      }
      let operatorID = try localMutationOperatorIDUnlocked()
      let note = try noteForEditingUnlocked(id: pending.noteID, operatorID: operatorID)
      guard note.revision == pending.expectedRevision else {
        throw WorkspaceNoteMutationError.revisionConflict
      }
      try envelope.validateApplying(to: NoteDocument.decode(note.content))
      let response = try applyNoteEditsUnlocked(NoteEditingRequest(
        command: .apply,
        noteID: pending.noteID,
        expectedRevision: pending.expectedRevision,
        operations: envelope.operations
      ))
      let timestamp = Self.timestamp(Date())
      let message = try prepareUnlocked("""
        UPDATE dashboard_messages SET content = ?, updated_at = ?
        WHERE id = ? AND run_id = ? AND role = 'assistant'
        """)
      defer { sqlite3_finalize(message) }
      try bind(visibleAssistantContent, at: 1, to: message)
      try bind(timestamp, at: 2, to: message)
      try bind(pending.assistantMessageID, at: 3, to: message)
      try bind(pending.runID, at: 4, to: message)
      try stepDone(message)
      guard changedRowCountUnlocked == 1 else {
        throw RemoteNoteEditError.invalidEnvelope
      }
      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, updated_at = ?
        WHERE id = (
          SELECT conversation_id FROM dashboard_messages WHERE id = ?
        ) AND NOT EXISTS (
          SELECT 1 FROM dashboard_messages AS newer
          WHERE newer.conversation_id = dashboard_conversations.id
            AND newer.created_at > (
              SELECT created_at FROM dashboard_messages WHERE id = ?
            )
        )
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(Self.localPreview(visibleAssistantContent), at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(pending.assistantMessageID, at: 3, to: conversation)
      try bind(pending.assistantMessageID, at: 4, to: conversation)
      try stepDone(conversation)
      let complete = try prepareUnlocked("""
        UPDATE desktop_remote_note_edits
        SET state = 'applied', updated_at = ?
        WHERE run_id = ? AND state = 'pending'
        """)
      defer { sqlite3_finalize(complete) }
      try bind(timestamp, at: 1, to: complete)
      try bind(pending.runID, at: 2, to: complete)
      try stepDone(complete)
      guard changedRowCountUnlocked == 1 else {
        throw RemoteNoteEditError.invalidEnvelope
      }
      return response
    }
  }

  public func dismissPendingRemoteNoteEdit(runID: String) throws {
    try transaction {
      let lookup = try prepareUnlocked("""
        SELECT message.id, message.content
        FROM desktop_remote_note_edits AS edit
        JOIN dashboard_messages AS message
          ON message.id = edit.assistant_message_id AND message.run_id = edit.run_id
        WHERE edit.run_id = ? AND edit.state = 'pending'
        """)
      defer { sqlite3_finalize(lookup) }
      try bind(runID, at: 1, to: lookup)
      let timestamp = Self.timestamp(Date())
      if sqlite3_step(lookup) == SQLITE_ROW {
        let messageID = try text(lookup, column: 0)
        let visible = RemoteNoteEditEnvelope.redactingEnvelopes(
          in: try text(lookup, column: 1)
        )
        let message = try prepareUnlocked("""
          UPDATE dashboard_messages SET content = ?, updated_at = ? WHERE id = ?
          """)
        defer { sqlite3_finalize(message) }
        try bind(visible, at: 1, to: message)
        try bind(timestamp, at: 2, to: message)
        try bind(messageID, at: 3, to: message)
        try stepDone(message)
        let conversation = try prepareUnlocked("""
          UPDATE dashboard_conversations SET last_message_preview = ?, updated_at = ?
          WHERE id = (SELECT conversation_id FROM dashboard_messages WHERE id = ?)
            AND NOT EXISTS (
              SELECT 1 FROM dashboard_messages AS newer
              WHERE newer.conversation_id = dashboard_conversations.id
                AND newer.created_at > (
                  SELECT created_at FROM dashboard_messages WHERE id = ?
                )
            )
          """)
        defer { sqlite3_finalize(conversation) }
        try bind(Self.localPreview(visible), at: 1, to: conversation)
        try bind(timestamp, at: 2, to: conversation)
        try bind(messageID, at: 3, to: conversation)
        try bind(messageID, at: 4, to: conversation)
        try stepDone(conversation)
      }
      let statement = try prepareUnlocked("""
        UPDATE desktop_remote_note_edits SET state = 'dismissed', updated_at = ?
        WHERE run_id = ? AND state = 'pending'
        """)
      defer { sqlite3_finalize(statement) }
      try bind(timestamp, at: 1, to: statement)
      try bind(runID, at: 2, to: statement)
      try stepDone(statement)
    }
  }

  public func dismissTerminalRemoteNoteEdits() throws {
    let runIDs = try withLock {
      let statement = try prepareUnlocked("""
        SELECT edit.run_id FROM desktop_remote_note_edits AS edit
        JOIN dashboard_runs AS run ON run.id = edit.run_id
        WHERE edit.state = 'pending' AND run.status IN ('failed', 'cancelled')
        """)
      defer { sqlite3_finalize(statement) }
      var values: [String] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        values.append(try text(statement, column: 0))
      }
      return values
    }
    for runID in runIDs {
      try dismissPendingRemoteNoteEdit(runID: runID)
    }
  }

  @discardableResult
  public func createNote(
    id: UUID = UUID(),
    folderID: String?,
    title: String = "Untitled Note",
    content: String = "",
    kind: NoteArtifactKind = .note,
    createdAt: Date = Date(),
    callerConversationID: String? = nil,
    requestID: String? = nil
  ) throws -> String {
    try transaction {
      if let callerConversationID { try requireToolUnlocked(.notes, sessionID: callerConversationID) }
      return try performToolMutationUnlocked(callerID: callerConversationID, requestID: requestID,
        operation: "notes.create", input: [folderID, title, content, kind.rawValue]) {
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

        try checkpointNoteUnlocked(id: noteID, source: "created", force: true)
        return noteID
      }.result
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
      try checkpointNoteUnlocked(id: id, source: "editor", force: false)
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
      try bind(nextNoteRevisionUnlocked(id:id,now:updatedAt), at: 4, to: update)
      try bind(id, at: 5, to: update)
      try bind(operatorID, at: 6, to: update)
      try stepDone(update)
      guard changedRowCountUnlocked == 1 else {
        throw WorkspaceNoteMutationError.noteNotFound
      }

      try checkpointNoteUnlocked(id: id, source: "editor", force: false)
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
      try checkpointNoteUnlocked(id: id, source: "editor", force: false)
      let content = try NoteDocument.decode(content).encoded()
      let operatorID = try localMutationOperatorIDUnlocked()
      let timestamp = try nextNoteRevisionUnlocked(id:id,now:updatedAt)
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

      let restoredMissingNote = changedRowCountUnlocked != 1
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

      try checkpointNoteUnlocked(id: id, source: "editor", force: false)
      return true
    }
  }

  public func readNoteForEditing(id: String, callerConversationID: String? = nil) throws -> NoteEditingResponse {
    try withLock {
      if let callerConversationID { try requireToolUnlocked(.notes, sessionID: callerConversationID) }
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

  public func applyNoteEdits(_ request: NoteEditingRequest, callerConversationID: String? = nil,
                             requestID: String? = nil) throws -> NoteEditingResponse {
    try transaction {
      if let callerConversationID { try requireToolUnlocked(.notes, sessionID: callerConversationID) }
      return try performToolMutationUnlocked(callerID: callerConversationID, requestID: requestID,
        operation: "notes.apply", input: request, receipt: noteMutationReceipt) {
          try applyNoteEditsUnlocked(request)
        }.result
    }
  }

  private func applyNoteEditsUnlocked(
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
    try checkpointNoteUnlocked(id: request.noteID, source: "before-agent-edit", force: true)
    var document = NoteDocument.decode(note.content)
    if document.kind == .html,
       request.operations.contains(where: {
         if case .setTitle = $0 { true } else { false }
       }) {
      throw NoteEditError.artifactKindMismatch
    }
    let updatedTitle = try document.apply(request.operations) ?? note.title
    let content = try document.encoded()
    let revision = try nextNoteRevisionUnlocked(id:request.noteID)
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
    guard changedRowCountUnlocked == 1 else {
      throw WorkspaceNoteMutationError.noteNotFound
    }
    try checkpointNoteUnlocked(id: request.noteID, source: "agent", force: true)
    return NoteEditingResponse(
      success: true, noteID: request.noteID, title: updatedTitle,
      revision: revision, document: document
    )
  }

  private func nextNotePositionUnlocked(
    folderID: String?,
    operatorID: String
  ) throws -> Int {
    let statement = try prepareUnlocked(folderID == nil ? """
      SELECT COALESCE(MAX(position), -1) + 1
      FROM notes
      WHERE user_id = ? AND folder_id IS NULL AND deleted_at IS NULL
      """ : """
      SELECT COALESCE(MAX(position), -1) + 1
      FROM notes
      WHERE user_id = ? AND folder_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(statement) }
    try bind(operatorID, at: 1, to: statement)
    if let folderID {
      try bind(folderID, at: 2, to: statement)
    }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  func noteForEditingUnlocked(
    id: String,
    operatorID: String
  ) throws -> (title: String, content: String, revision: String) {
    let statement = try prepareUnlocked("""
      SELECT title, content, updated_at
      FROM notes
      WHERE id = ? AND user_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(operatorID, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw WorkspaceNoteMutationError.noteNotFound
    }
    return (
      try text(statement, column: 0),
      try text(statement, column: 1),
      try text(statement, column: 2)
    )
  }

  static func noteSnippet(_ content: String) -> String {
    let content = NoteDocument.decode(content).plainText
    let replacements: [(String, String, String.CompareOptions)] = [
      (#"</p>\s*<p[^>]*>"#, " ", .regularExpression),
      (#"<br\s*/?>"#, " ", [.regularExpression, .caseInsensitive]),
      (#"</li>\s*<li[^>]*>"#, " ", [.regularExpression, .caseInsensitive]),
      (#"<[^>]+>"#, "", .regularExpression),
      ("&nbsp;", " ", []),
      ("&amp;", "&", []),
      ("&lt;", "<", []),
      ("&gt;", ">", []),
      ("&quot;", "\"", []),
      ("&#39;", "'", []),
      ("&#x27;", "'", [.caseInsensitive]),
    ]
    var text = content
    for (source, replacement, options) in replacements {
      text = text.replacingOccurrences(
        of: source,
        with: replacement,
        options: options
      )
    }
    text = text
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.count > 180 ? "\(text.prefix(177))..." : text
  }
}

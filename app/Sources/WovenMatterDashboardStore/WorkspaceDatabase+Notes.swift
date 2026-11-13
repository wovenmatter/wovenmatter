import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
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
extension WorkspaceDatabaseConnection {
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
    if context.requireCurrentRevision == true {
      // This executes inside run acceptance, after any asynchronous discovery or
      // attachment staging, so a phone cannot grant editing from a stale base.
      try requireToolUnlocked(.notes, sessionID: conversationID)
      let current = try noteForEditingUnlocked(id: context.noteID,
        operatorID: localMutationOperatorIDUnlocked())
      guard current.revision == context.revision else {
        throw WorkspaceNoteMutationError.revisionConflict
      }
    }
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
      try envelope.validateApplying(to: NoteDocument.editableDocument(from: note.content))
      let runConversation = try historyRowsUnlocked("SELECT conversation_id FROM dashboard_runs WHERE id=?", values: [pending.runID])
        .first?.objectValue?["conversation_id"]?.stringValue
      let response = try applyNoteEditsUnlocked(NoteEditingRequest(
        command: .apply,
        noteID: pending.noteID,
        expectedRevision: pending.expectedRevision,
        operations: envelope.operations
      ), actor: boardActorUnlocked(callerConversationID: runConversation))
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
      guard title.utf8.count <= 1_024 else {
        throw WorkspaceToolError.invalid("A note title must be at most 1,024 bytes.")
      }
      return try performToolMutationUnlocked(callerID: callerConversationID, requestID: requestID,
        operation: "notes.create", input: [folderID, title, content, kind.rawValue]) {
        let content = try (content.isEmpty
          ? NoteDocument(kind: kind)
          : NoteDocument.editableDocument(from: content)).encoded()
        guard content.utf8.count <= RemoteNoteEditEnvelope.maximumEnvelopeBytes else {
          throw WorkspaceToolError.invalid("A note document must be at most 1 MiB.")
        }
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
        try bind(try syncedNoteContentUnlocked(id: noteID, content: content, title: title, folderID: .some(folderID)), at: 5, to: note)
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

  /// Whole-document autosave shares the optimistic boundary used by mobile and
  /// agent edits. A missing or deleted note is never recreated under its old ID.
  @discardableResult
  public func persistNoteDraft(
    id: String,
    title: String,
    content: String,
    updatedAt: Date = Date(),
    expectedRevision: String? = nil,
    operationID: String? = nil,
    baseContent: String? = nil,
    baseTitle: String? = nil
  ) throws -> Bool {
    try transaction {
      if let operationID, let receipt = try libraryDraftReceiptUnlocked(operationID: operationID) {
        guard receipt.id == id, receipt.title == title,
              receipt.content == Self.libraryContentFingerprint(content) else {
          throw WorkspaceNoteMutationError.revisionConflict
        }
        return true
      }
      let operatorID = try localMutationOperatorIDUnlocked()
      let note = try noteForEditingUnlocked(id: id, operatorID: operatorID)
      if note.title == title, note.content == content {
        try saveLibraryDraftReceiptUnlocked(operationID: operationID, id: id,
          title: title, content: content, revision: note.revision)
        return true
      }
      let resolved = try resolveNoteDraftUnlocked(note: note, title: title, content: content,
        expectedRevision: expectedRevision, baseContent: baseContent, baseTitle: baseTitle)
      // A stale draft can resolve to exactly what is stored. Nothing moves, so no
      // other writer's revision goes stale because of it.
      if resolved.title == note.title, resolved.content == note.content {
        try saveLibraryDraftReceiptUnlocked(operationID: operationID, id: id,
          title: title, content: content, revision: note.revision)
        return true
      }
      // Decoding must preserve every supported field; persist the editor's raw
      // bytes so a title-only change can retain an unsupported future document.
      if resolved.content != note.content {
        _ = try NoteDocument.editableDocument(from: note.content)
        let candidate = try NoteDocument.editableDocument(from: resolved.content)
        // Every participant must still be able to change a Page. A larger
        // existing Page can shrink, but it cannot grow further out of reach.
        if candidate.kind == .canvas, resolved.content.utf8.count > NoteDocument.maximumBoardBytes,
           resolved.content.utf8.count > note.content.utf8.count {
          throw NoteDocumentSafetyError.tooLarge
        }
      }
      try checkpointNoteUnlocked(id: id, source: "editor", force: false)
      try toolsExecuteUnlocked(
        "UPDATE notes SET title = ?, content = ?, snippet = ?, updated_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
        [resolved.title, try syncedNoteContentUnlocked(id: id, content: resolved.content, title: resolved.title), Self.noteSnippet(resolved.content),
         try nextNoteUpdatedAtUnlocked(id: id, now: updatedAt), id, operatorID]
      )
      guard changedRowCountUnlocked == 1 else { throw WorkspaceNoteMutationError.noteNotFound }
      try checkpointNoteUnlocked(id: id, source: "editor", force: false)
      let revision = try noteForEditingUnlocked(id: id, operatorID: operatorID).revision
      // The receipt identifies what was submitted, so a retry of a merged draft replays it.
      try saveLibraryDraftReceiptUnlocked(operationID: operationID, id: id,
        title: title, content: content, revision: revision)
      return true
    }
  }

  /// What a draft should store, given the row as it is now. Pages and Artifacts have a
  /// finer unit than the document revision, so another writer's change to a different
  /// component or to saved state need not fail this save. Anything that cannot combine
  /// without losing someone's writing throws `revisionConflict`, so draft recovery keeps it.
  private func resolveNoteDraftUnlocked(
    note: (title: String, content: String, revision: String), title: String, content: String,
    expectedRevision: String?, baseContent: String?, baseTitle: String?
  ) throws -> (title: String, content: String) {
    let isCurrent = expectedRevision == note.revision && expectedRevision != nil
    guard let current = try? NoteDocument.editableDocument(from: note.content),
          let draft = try? NoteDocument.editableDocument(from: content),
          current.kind == draft.kind, current.kind == .canvas || current.kind == .html else {
      guard isCurrent else { throw WorkspaceNoteMutationError.revisionConflict }
      return (title, content)
    }
    // A chained autosave names the latest revision while its text derives from an earlier
    // draft. If an earlier save was merged, that text lacks the other writer's change.
    let derivesFromCurrent = isCurrent && (baseContent == nil || baseContent == note.content)
    let base = baseContent.flatMap { try? NoteDocument.editableDocument(from: $0) }
    let resolvedTitle: String
    if derivesFromCurrent || title == note.title { resolvedTitle = title }
    else if title == baseTitle { resolvedTitle = note.title }
    else if note.title == baseTitle, baseTitle != nil { resolvedTitle = title }
    else { throw WorkspaceNoteMutationError.revisionConflict }

    if current.kind == .html {
      let code = { (document: NoteDocument) in document.replacingArtifactState(with: nil).normalized() }
      let stateBase: [String: ArtifactStateEntry]?
      let chosen: NoteDocument
      if derivesFromCurrent {
        stateBase = current.artifactState; chosen = draft
      } else if let base, base.kind == .html, code(draft) == code(current) {
        // Without a base, every state difference would look like this draft's own change.
        stateBase = base.artifactState; chosen = current
      } else if let base, base.kind == .html {
        stateBase = base.artifactState
        if code(base) == code(current) { chosen = draft }      // Only state moved underneath this draft.
        else if code(draft) == code(base) { chosen = current } // Only the title changed here.
        else { throw WorkspaceNoteMutationError.revisionConflict }
      } else {
        throw WorkspaceNoteMutationError.revisionConflict
      }
      let state: [String: ArtifactStateEntry]?
      do {
        state = try NoteDocument.mergeArtifactState(base: stateBase, draft: draft.artifactState, current: current.artifactState, at: Self.timestamp(Date()))
      } catch ArtifactStateError.conflict { throw WorkspaceNoteMutationError.revisionConflict }
      // Raw bytes stay when the draft is already right.
      if code(chosen) == code(draft), state == draft.artifactState { return (resolvedTitle, content) }
      return (resolvedTitle, try chosen.replacingArtifactState(with: state).encoded())
    }

    if derivesFromCurrent { return (resolvedTitle, content) }
    guard let base, base.kind == .canvas else { throw WorkspaceNoteMutationError.revisionConflict }
    guard var merged = try? NoteDocument.mergePage(base: base, local: draft, remote: current).document else {
      throw WorkspaceNoteMutationError.revisionConflict
    }
    merged.stampBoardChanges(from: current.materializedPage(), actor: BoardActor(kind: .user), at: Self.timestamp(Date()))
    return (resolvedTitle, try merged.encoded())
  }

  /// Saves one key of an Artifact's state for the user's own app. It takes no document
  /// revision and no document: only `artifactState` changes, on the latest row, so code
  /// read from a stale view can never be written back. Nothing is written for a no-op.
  public func applyArtifactStateEdit(noteID: String, edit: ArtifactStateEdit) throws -> ArtifactStateWriteResult {
    try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      let note = try noteForEditingUnlocked(id: noteID, operatorID: operatorID)
      var document = try NoteDocument.editableDocument(from: note.content)
      guard try document.applyArtifactStateEdits([edit], at: Self.timestamp(Date())) else {
        return ArtifactStateWriteResult(noteID: noteID, key: edit.key, version: document.artifactState?[edit.key]?.version ?? 0,
          changed: false, revision: note.revision, snapshot: document.artifactStateSnapshot)
      }
      let content = try document.encoded()
      guard content.utf8.count <= LibraryProtocol.maximumNoteBytes else { throw ArtifactStateError.stateTooLarge }
      // Saved inputs change often. Coalesce their history so they cannot crowd out real versions.
      try checkpointNoteUnlocked(id: noteID, source: "artifact-state", force: false)
      try toolsExecuteUnlocked(
        "UPDATE notes SET content = ?, updated_at = ? WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
        [try syncedNoteContentUnlocked(id: noteID, content: content), try nextNoteUpdatedAtUnlocked(id: noteID), noteID, operatorID])
      guard changedRowCountUnlocked == 1 else { throw WorkspaceNoteMutationError.noteNotFound }
      try checkpointNoteUnlocked(id: noteID, source: "artifact-state", force: false)
      return ArtifactStateWriteResult(noteID: noteID, key: edit.key, version: document.artifactState?[edit.key]?.version ?? 0,
        changed: true, revision: try noteForEditingUnlocked(id: noteID, operatorID: operatorID).revision,
        snapshot: document.artifactStateSnapshot)
    }
  }

  public func artifactStateSnapshot(noteID: String) throws -> ArtifactStateSnapshot {
    try withLock {
      let note = try noteForEditingUnlocked(id: noteID, operatorID: try localMutationOperatorIDUnlocked())
      let document = try NoteDocument.editableDocument(from: note.content)
      guard document.kind == .html else { throw ArtifactStateError.notArtifact }
      return document.artifactStateSnapshot
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
        document: try NoteDocument.editableDocument(from: note.content)
      )
    }
  }

  public func applyNoteEdits(_ request: NoteEditingRequest, callerConversationID: String? = nil,
                             requestID: String? = nil) throws -> NoteEditingResponse {
    try transaction {
      if let callerConversationID { try requireToolUnlocked(.notes, sessionID: callerConversationID) }
      return try performToolMutationUnlocked(callerID: callerConversationID, requestID: requestID,
        operation: "notes.apply", input: request, receipt: noteMutationReceipt) {
          // Upgraded clients must still replay a completed legacy receipt whose
          // original request predates mandatory revisions. Only new writes need
          // the revision; current tool authority is checked before either path.
          if RemoteNoteEditEnvelope.requiresRevision(request.operations),
             request.expectedRevision == nil {
            throw WorkspaceToolError.revisionRequired("This note operation requires --revision. Read the note again and pass its current revision.")
          }
          return try applyNoteEditsUnlocked(request, actor: boardActorUnlocked(callerConversationID: callerConversationID))
        }.result
    }
  }

  /// Attribution comes from the caller this transaction authorized, never from
  /// tool arguments. No caller means the user's own app.
  private func boardActorUnlocked(callerConversationID: String?) throws -> BoardActor {
    guard let id = callerConversationID else { return BoardActor(kind: .user) }
    if id == WovenMCPCaller.outside { return BoardActor(kind: .outside) }
    // A bot is an app-wide caller, not a conversation, so it has no chat to open.
    if WovenMCPCaller.parseBot(id) != nil {
      let name = try historyRowsUnlocked("SELECT display_name FROM workspace_mcp_callers WHERE id=?", values: [id])
        .first?.objectValue?["display_name"]?.stringValue
      return BoardActor(kind: .outside, label: name.map { String($0.prefix(160)) })
    }
    let title = try historyRowsUnlocked("SELECT title FROM dashboard_conversations WHERE id=?", values: [id])
      .first?.objectValue?["title"]?.stringValue
    return BoardActor(kind: .session, sessionID: id, label: title.map { String($0.prefix(160)) })
  }

  /// The newly linked asset IDs that are not notes in this library.
  private func firstMissingAssetUnlocked(_ ids: Set<String>, operatorID: String) throws -> String? {
    let list = String(decoding: try JSONEncoder().encode(ids.sorted()), as: UTF8.self)
    let found = Set(try historyRowsUnlocked(
      "SELECT id FROM notes WHERE user_id=? AND deleted_at IS NULL AND id IN (SELECT value FROM json_each(?))",
      values: [operatorID, list]).compactMap { $0.objectValue?["id"]?.stringValue })
    return ids.subtracting(found).sorted().first
  }

  private func applyNoteEditsUnlocked(
    _ request: NoteEditingRequest,
    actor: BoardActor
  ) throws -> NoteEditingResponse {
    let operatorID = try localMutationOperatorIDUnlocked()
    let note = try noteForEditingUnlocked(id: request.noteID, operatorID: operatorID)
    if let expected = request.expectedRevision, expected != note.revision {
      throw WorkspaceNoteMutationError.revisionConflict
    }
    guard !request.operations.isEmpty else {
      return NoteEditingResponse(
        success: true, noteID: request.noteID, title: note.title,
        revision: note.revision, document: try NoteDocument.editableDocument(from: note.content)
      )
    }
    let edit = try PageTool.apply(request.operations, title: note.title, content: note.content, pageID: request.noteID,
      actor: actor, at: Self.timestamp(Date())) { try firstMissingAssetUnlocked($0, operatorID: operatorID) }
    let document = edit.document, updatedTitle = edit.title
    if (document.kind == .canvas || document.kind == .html), !edit.changed {
      return NoteEditingResponse(success: true, noteID: request.noteID, title: note.title, revision: note.revision, document: document)
    }
    try checkpointNoteUnlocked(id: request.noteID, source: "before-agent-edit", force: edit.forceCheckpoint)
    let content = try document.encoded()
    let updatedAt = try nextNoteUpdatedAtUnlocked(id: request.noteID)
    let update = try prepareUnlocked("""
      UPDATE notes SET title = ?, content = ?, snippet = ?, updated_at = ?
      WHERE id = ? AND user_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(update) }
    try bind(updatedTitle, at: 1, to: update)
    try bind(try syncedNoteContentUnlocked(id: request.noteID, content: content, title: updatedTitle), at: 2, to: update)
    try bind(Self.noteSnippet(content), at: 3, to: update)
    try bind(updatedAt, at: 4, to: update)
    try bind(request.noteID, at: 5, to: update)
    try bind(operatorID, at: 6, to: update)
    try stepDone(update)
    guard changedRowCountUnlocked == 1 else {
      throw WorkspaceNoteMutationError.noteNotFound
    }
    try checkpointNoteUnlocked(id: request.noteID, source: "agent", force: edit.forceCheckpoint)
    return NoteEditingResponse(
      success: true, noteID: request.noteID, title: updatedTitle,
      revision: try noteForEditingUnlocked(id: request.noteID, operatorID: operatorID).revision, document: document
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
      SELECT title, content, CAST(COALESCE((SELECT revision FROM device_sync_revisions WHERE kind = 'note' AND resource_id = notes.id), 1) AS TEXT)
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
      // Synchronization clocks stay in the store; every write recomputes them.
      NoteSync.strip(try text(statement, column: 1)),
      try text(statement, column: 2)
    )
  }

  static func noteSnippet(_ content: String) -> String {
    let content = (try? NoteDocument.editableDocument(from: content).plainText) ?? "Unsupported document"
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

// MARK: - Async worker boundary

extension WorkspaceDatabase {
  public func pendingRemoteNoteEdits() async throws -> [PendingRemoteNoteEdit] {
    try await read { try $0.pendingRemoteNoteEdits() }
  }

  public func applyPendingRemoteNoteEdit(
    _ pending: PendingRemoteNoteEdit,
    envelope: RemoteNoteEditEnvelope,
    visibleAssistantContent: String
  ) async throws -> NoteEditingResponse {
    try await write { try $0.applyPendingRemoteNoteEdit(pending, envelope: envelope, visibleAssistantContent: visibleAssistantContent) }
  }

  public func dismissPendingRemoteNoteEdit(runID: String) async throws {
    try await write { try $0.dismissPendingRemoteNoteEdit(runID: runID) }
  }

  public func dismissTerminalRemoteNoteEdits() async throws {
    try await write { try $0.dismissTerminalRemoteNoteEdits() }
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
  ) async throws -> String {
    try await write { try $0.createNote(id: id, folderID: folderID, title: title, content: content, kind: kind, createdAt: createdAt, callerConversationID: callerConversationID, requestID: requestID) }
  }

  @discardableResult
  public func persistNoteDraft(
    id: String,
    title: String,
    content: String,
    updatedAt: Date = Date(),
    expectedRevision: String? = nil, operationID: String? = nil,
    baseContent: String? = nil, baseTitle: String? = nil
  ) async throws -> Bool {
    try await write { try $0.persistNoteDraft(id: id, title: title, content: content, updatedAt: updatedAt, expectedRevision: expectedRevision, operationID: operationID, baseContent: baseContent, baseTitle: baseTitle) }
  }

  public func applyArtifactStateEdit(noteID: String, edit: ArtifactStateEdit) async throws -> ArtifactStateWriteResult {
    try await write { try $0.applyArtifactStateEdit(noteID: noteID, edit: edit) }
  }

  public func artifactStateSnapshot(noteID: String) async throws -> ArtifactStateSnapshot {
    try await read { try $0.artifactStateSnapshot(noteID: noteID) }
  }

  public func readNoteForEditing(id: String, callerConversationID: String? = nil) async throws -> NoteEditingResponse {
    try await read { try $0.readNoteForEditing(id: id, callerConversationID: callerConversationID) }
  }

  public func applyNoteEdits(_ request: NoteEditingRequest, callerConversationID: String? = nil,
                             requestID: String? = nil) async throws -> NoteEditingResponse {
    try await write { try $0.applyNoteEdits(request, callerConversationID: callerConversationID, requestID: requestID) }
  }
}

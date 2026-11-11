import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Trusted application-only projection into an isolated execution database.
  /// The HTTP mutation API deliberately does not call this method: a projection
  /// may preserve registered linked documents and restore a stale local tombstone.
  func applyExecutionReplicaProjection(_ request: LibraryMutation, libraryID: String, workspaceID: String) throws -> LibraryMutationResult {
    try transaction {
      guard [libraryID, workspaceID, request.deviceID, request.resourceID].allSatisfy({ UUID(uuidString: $0) != nil }),
            request.deviceID == workspaceID, try libraryWorkspaceIDUnlocked() != libraryID else {
        throw LibraryAPIError(code: "wrong_replica", message: "Replica projection requires an isolated execution database and its owning library.")
      }
      try executeUnlocked("CREATE TABLE IF NOT EXISTS library_execution_replica_context (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), library_id TEXT NOT NULL, workspace_id TEXT NOT NULL)")
      let context = try prepareUnlocked("SELECT library_id, workspace_id FROM library_execution_replica_context WHERE singleton = 1")
      defer { sqlite3_finalize(context) }
      let code = sqlite3_step(context)
      if code == SQLITE_ROW {
        guard try text(context, column: 0) == libraryID, try text(context, column: 1) == workspaceID else {
          throw LibraryAPIError(code: "wrong_replica", message: "This execution database already projects a different library or workspace.")
        }
      } else if code == SQLITE_DONE {
        try toolsExecuteUnlocked("INSERT INTO library_execution_replica_context(singleton,library_id,workspace_id) VALUES(1,?,?)", [libraryID, workspaceID])
      } else { throw stepError() }
      let operatorID = try localMutationOperatorIDUnlocked()
      let now = Self.timestamp(Date())
      if request.kind == .createNote || request.kind == .updateNote {
        guard let title = request.title, let content = request.content,
              title.utf8.count <= 4_096, content.utf8.count <= LibraryProtocol.maximumNoteBytes else {
          throw LibraryAPIError(code: "invalid_replica", message: "The projected document exceeds its supported size.")
        }
        _ = try NoteDocument.editableDocument(from: content)
        if let folderID = request.folderID, try libraryFolderUnlocked(id: folderID) == nil {
          throw LibraryAPIError(code: "missing_folder", message: "Project the destination folder before its notes.")
        }
        let existing = try libraryNoteUnlocked(id: request.resourceID)
        guard (request.kind == .createNote && existing == nil) ||
                (request.kind == .updateNote && existing != nil && existing?.revision == request.expectedRevision) else {
          return .init(operationID: request.operationID, status: .conflict, note: existing, message: "The execution note changed during projection.")
        }
        if existing == nil, try libraryVersionUnlocked(kind: "note", id: request.resourceID) == nil {
          try toolsExecuteUnlocked("INSERT INTO notes(id,user_id,folder_id,title,content,snippet,position,created_at,updated_at) VALUES(?,?,?,?,?,?,0,?,?)",
            [request.resourceID, operatorID, request.folderID, title, content, Self.noteSnippet(content), now, now])
        } else {
          try checkpointNoteUnlocked(id: request.resourceID, source: "before-replica-projection", force: true)
          let updatedAt = try nextNoteUpdatedAtUnlocked(id: request.resourceID)
          try toolsExecuteUnlocked("UPDATE notes SET title=?,content=?,snippet=?,folder_id=?,deleted_at=NULL,updated_at=? WHERE id=? AND user_id=?",
            [title, content, Self.noteSnippet(content), request.folderID, updatedAt, request.resourceID, operatorID])
        }
        try checkpointNoteUnlocked(id: request.resourceID, source: "replica-projection", force: true)
        guard let note = try libraryNoteUnlocked(id: request.resourceID) else { throw WorkspaceDatabaseError.corruptRow }
        return .init(operationID: request.operationID, status: .accepted, note: note)
      }
      if request.kind == .createFolder, try libraryFolderUnlocked(id: request.resourceID) == nil {
        guard let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.utf8.count <= 4_096 else {
          throw LibraryAPIError(code: "invalid_replica", message: "The projected folder needs a valid name.")
        }
        guard let binding = request.folderExecution else {
          throw LibraryAPIError(code: "invalid_replica", message: "A projected folder must retain its execution workspace and directory.")
        }
        let location = WorkspaceFolderLocation(workspaceID: binding.workspaceID, rootPath: binding.rootPath, managed: false)
        try validateExecutionLocation(location)
        try toolsExecuteUnlocked("INSERT INTO folders(id,user_id,name,position,created_at,updated_at) VALUES(?,?,?,(SELECT COALESCE(MAX(position),-1)+1 FROM folders),?,?)",
          [request.resourceID, operatorID, title, now, now])
        try toolsExecuteUnlocked("INSERT INTO folder_execution_roots(folder_id,workspace_id,root_path,managed) VALUES(?,?,?,0)",
          [request.resourceID, binding.workspaceID, binding.rootPath])
        return .init(operationID: request.operationID, status: .accepted, folder: try libraryFolderUnlocked(id: request.resourceID))
      }
      if request.kind == .renameFolder || request.kind == .deleteFolder {
        guard let folder = try libraryFolderUnlocked(id: request.resourceID), request.expectedRevision == folder.revision else {
          return .init(operationID: request.operationID, status: .conflict, message: "The execution folder changed during projection.")
        }
        if request.kind == .deleteFolder {
          try toolsExecuteUnlocked("DELETE FROM folders WHERE id=? AND user_id=?", [request.resourceID, operatorID])
          return .init(operationID: request.operationID, status: .accepted)
        }
        guard let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title.utf8.count <= 4_096 else {
          throw LibraryAPIError(code: "invalid_replica", message: "The projected folder needs a valid name.")
        }
        try toolsExecuteUnlocked("UPDATE folders SET name=?,updated_at=? WHERE id=? AND user_id=?", [title, now, request.resourceID, operatorID])
        return .init(operationID: request.operationID, status: .accepted, folder: try libraryFolderUnlocked(id: request.resourceID))
      }
      if request.kind == .deleteNote {
        guard let note = try libraryNoteUnlocked(id: request.resourceID), request.expectedRevision == note.revision else {
          return .init(operationID: request.operationID, status: .conflict, message: "The execution note changed during projection.")
        }
        try checkpointNoteUnlocked(id: request.resourceID, source: "before-replica-delete", force: true)
        try toolsExecuteUnlocked("UPDATE notes SET deleted_at=?,updated_at=? WHERE id=? AND user_id=?", [now, now, request.resourceID, operatorID])
        return .init(operationID: request.operationID, status: .accepted)
      }
      return .init(operationID: request.operationID, status: .conflict, message: "The projected resource already exists.")
    }
  }
}

extension WorkspaceDatabase {
  public func applyExecutionReplicaProjection(_ request: LibraryMutation, libraryID: String, workspaceID: String) async throws -> LibraryMutationResult {
    try await write { try $0.applyExecutionReplicaProjection(request, libraryID: libraryID, workspaceID: workspaceID) }
  }
}

public struct ExecutionNativeHistory: Sendable {
  public let sequence: Int64
  public let id: String
  public let runID: String?
  public let data: Data
}

extension WorkspaceDatabaseConnection {
  /// Full native bytes for replication, without the UI history reader's preview
  /// truncation or its read-audit event (which would recursively archive itself).
  func executionNativeHistory(conversationID: String, after: Int64, limit: Int) throws -> [ExecutionNativeHistory] {
    try withLock {
      var result: [ExecutionNativeHistory] = []
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      try forEachHistoryRowUnlocked("""
        SELECT sequence,id,conversation_id,run_id,agent_id,harness,kind,payload,completeness,recorded_at,
          native_session_id,source_connection_id,source_id,native_record_id,native_revision_id,content_mode,text_content,projection_json
        FROM workspace_history_events WHERE conversation_id=? AND sequence>?
          AND kind NOT LIKE 'cli.%' AND kind!='native.federated.record'
        ORDER BY sequence LIMIT ?
        """, values: [conversationID, String(max(0, after)), String(min(64, max(1, limit)))], redactingCapabilities: true) { row in
        guard let object = row.objectValue, case .number(let sequence)? = object["sequence"],
              let id = object["id"]?.stringValue else { throw WorkspaceDatabaseError.corruptRow }
        result.append(.init(sequence: Int64(sequence), id: id, runID: object["run_id"]?.stringValue, data: try encoder.encode(row)))
      }
      return result
    }
  }
}

extension WorkspaceDatabase {
  public func executionNativeHistory(conversationID: String, after: Int64, limit: Int = 32) async throws -> [ExecutionNativeHistory] {
    try await read { try $0.executionNativeHistory(conversationID: conversationID, after: after, limit: limit) }
  }
}

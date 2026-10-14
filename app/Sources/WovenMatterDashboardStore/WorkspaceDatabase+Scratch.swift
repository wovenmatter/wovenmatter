import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  public func sessionScratchDirectory(id: String) throws -> WorkspaceFolderLocation? {
    try withLock {
      guard let row = try historyRowsUnlocked("SELECT workspace_id,root_path FROM session_scratch_directories WHERE session_id=?", values: [id]).first?.objectValue,
            let owner = row["workspace_id"]?.stringValue, let path = row["root_path"]?.stringValue else { return nil }
      return .init(workspaceID: owner, rootPath: path, managed: false)
    }
  }

  /// Reserve before touching the filesystem. A failed launch, renamed chat or restarted
  /// service keeps the same binding; deleting a chat never deletes its working files.
  public func reserveSessionScratchDirectory(id: String, workspaceID: String, workspaceRoot: String,
                                             firstMessage: String, date: Date = Date()) throws -> WorkspaceFolderLocation {
    try transaction {
      guard UUID(uuidString: id) != nil, !workspaceID.isEmpty,
            workspaceRoot.hasPrefix("/"), !workspaceRoot.contains("\0") else {
        throw WorkspaceToolError.invalid("A scratch chat needs a saved identity and execution workspace.")
      }
      if let saved = try sessionScratchDirectory(id: id) {
        guard saved.workspaceID == workspaceID,
              let base = try historyRowsUnlocked("SELECT workspace_root FROM session_scratch_directories WHERE session_id=?", values: [id]).first?.objectValue?["workspace_root"]?.stringValue,
              base == workspaceRoot else { throw WorkspaceToolError.invalid("This chat's scratch workspace is fixed.") }
        return saved
      }
      let root = URL(fileURLWithPath: workspaceRoot).appendingPathComponent("scratch", isDirectory: true)
      var path = root.appendingPathComponent(WorkspaceScratchDirectory.name(sessionID: id, firstMessage: firstMessage, date: date)).path
      if !(try historyRowsUnlocked("SELECT 1 FROM session_scratch_directories WHERE workspace_id=? AND root_path=?", values: [workspaceID,path])).isEmpty {
        path = root.appendingPathComponent(WorkspaceScratchDirectory.name(sessionID: id, firstMessage: firstMessage, date: date, fullID: true)).path
      }
      try toolsExecuteUnlocked("INSERT INTO session_scratch_directories(session_id,workspace_id,workspace_root,root_path) VALUES(?,?,?,?)", [id,workspaceID,workspaceRoot,path])
      return .init(workspaceID: workspaceID, rootPath: path, managed: false)
    }
  }

  public func bindSessionScratchDirectory(id: String) throws {
    try transaction {
      guard let scratch = try sessionScratchDirectory(id: id), let root = try sessionExecutionRoot(id: id),
            root.workspaceID == scratch.workspaceID else { throw WorkspaceToolError.invalid("This chat has no scratch directory reservation.") }
      if root.rootPath == scratch.rootPath { return }
      guard try canChooseSessionFolder(id: id),
            try historyRowsUnlocked("SELECT 1 FROM dashboard_conversations WHERE id=? AND folder_id IS NULL AND deleted_at IS NULL", values: [id]).count == 1,
            let base = try historyRowsUnlocked("SELECT workspace_root FROM session_scratch_directories WHERE session_id=?", values: [id]).first?.objectValue?["workspace_root"]?.stringValue,
            root.rootPath == base else { throw WorkspaceToolError.invalid("Only an Ungrouped draft can bind its scratch directory.") }
      try toolsExecuteUnlocked("UPDATE session_execution_roots SET root_path=? WHERE conversation_id=?", [scratch.rootPath,id])
    }
  }
}

extension WorkspaceDatabase {
  public func sessionScratchDirectory(id: String) async throws -> WorkspaceFolderLocation? {
    try await read { try $0.sessionScratchDirectory(id: id) }
  }
  public func reserveSessionScratchDirectory(id: String, workspaceID: String, workspaceRoot: String,
                                             firstMessage: String, date: Date = Date()) async throws -> WorkspaceFolderLocation {
    try await write { try $0.reserveSessionScratchDirectory(id: id, workspaceID: workspaceID, workspaceRoot: workspaceRoot, firstMessage: firstMessage, date: date) }
  }
  public func bindSessionScratchDirectory(id: String) async throws {
    try await write { try $0.bindSessionScratchDirectory(id: id) }
  }
}

import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// A chat this Mac created on a Linux host it added, through the host's
  /// server (`createSession`, already acknowledged). The host owns and runs
  /// it; this library keeps the same rows a chat on that host always had
  /// (its agent, folder, title, execution root and creation provenance), so
  /// folders, the calendar and agent tools see it as before, plus the
  /// execution owner that sends every message through the host's server. No
  /// native session is bound here, and nothing here launches one.
  @discardableResult
  public func createRemoteMemberSession(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    title: String,
    ownerDeviceID: UUID,
    providerID: String,
    conversationID: UUID,
    allowMissingCalendarFolder: Bool = false,
    executionRoot: SessionCreationRoot
  ) throws -> String {
    let workspaceID = remoteWorkspaceID.uuidString.lowercased()
    guard executionRoot.location.workspaceID == WorkspaceFolderLocation.remoteWorkspaceSourceID(remoteWorkspaceID) else {
      throw WorkspaceToolError.invalid("Create this chat in its owning execution workspace.")
    }
    return try transaction {
      guard let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted, workspace.kind == .linux else {
        throw federationError("unknown_workspace", "\(remoteWorkspaceName) is not in this library's workspaces yet. Reconnect it in Settings → Workspaces.")
      }
      let id = try createRemoteACPSessionUnlocked(runtimeKind: runtimeKind, remoteWorkspaceID: remoteWorkspaceID,
        remoteWorkspaceName: remoteWorkspaceName, title: title, ownerDeviceID: ownerDeviceID,
        requestedConversationID: conversationID, allowMissingCalendarFolder: allowMissingCalendarFolder)
      try saveSessionExecutionRootUnlocked(id: id, folderID: executionRoot.folderID,
        location: executionRoot.location, defaultPath: executionRoot.defaultPath)
      guard var conversation = try libraryConversationUnlocked(id: id) else { throw WorkspaceDatabaseError.corruptRow }
      conversation.providerID = providerID; conversation.routeID = workspace.id; conversation.runtimeKind = runtimeKind.rawValue
      conversation.workspaceID = workspace.id; conversation.libraryID = workspace.libraryID; conversation.activeRunID = nil
      let statement = try prepareUnlocked("INSERT INTO execution_conversations(id,workspace_id,conversation) VALUES (?,?,?)")
      defer { sqlite3_finalize(statement) }
      try bind(id, at: 1, to: statement); try bind(workspace.id, at: 2, to: statement)
      try bindJSON(conversation, at: 3, to: statement); try stepDone(statement)
      return id
    }
  }

}

extension WorkspaceDatabase {
  @discardableResult
  public func createRemoteMemberSession(runtimeKind: AgentRuntimeKind, remoteWorkspaceID: UUID, remoteWorkspaceName: String,
                                        title: String, ownerDeviceID: UUID, providerID: String, conversationID: UUID,
                                        allowMissingCalendarFolder: Bool = false, executionRoot: SessionCreationRoot) async throws -> String {
    try await write { try $0.createRemoteMemberSession(runtimeKind: runtimeKind, remoteWorkspaceID: remoteWorkspaceID,
      remoteWorkspaceName: remoteWorkspaceName, title: title, ownerDeviceID: ownerDeviceID, providerID: providerID,
      conversationID: conversationID, allowMissingCalendarFolder: allowMissingCalendarFolder, executionRoot: executionRoot) }
  }
}

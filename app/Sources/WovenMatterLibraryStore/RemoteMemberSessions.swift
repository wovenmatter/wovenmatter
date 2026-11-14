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

  /// Whether this conversation moved to its execution owner by adoption
  /// (a chat that ran over SSH before), as opposed to being created there.
  public func hasExecutionAdoption(conversationID: String) throws -> Bool {
    try withLock {
      try federationScalarUnlocked("SELECT COUNT(*) FROM execution_adoptions WHERE conversation_id=?", bindings: [conversationID]) != 0
    }
  }

  /// A chat that ran over SSH before cannot continue there: that path is gone.
  /// Its unsettled runs are interrupted so it can move to the host's server.
  /// Only chats without an execution owner are touched.
  public func interruptLegacyRemoteRuns(conversationID: String) throws {
    try transaction {
      guard try federationScalarUnlocked("""
        SELECT COUNT(*) FROM harness_sessions s WHERE s.conversation_id=? AND s.remote_workspace_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM execution_conversations x WHERE x.id=s.conversation_id)
        """, bindings: [conversationID]) != 0 else { return }
      try interruptLegacyRemoteRunsUnlocked(conversationID: conversationID)
    }
  }

  /// Settles a chat's unsettled SSH runs as interrupted, each together with
  /// its assistant message, so the history it shows and sends on keeps no
  /// running or uncertain reply. The run happened on the Linux host, not on
  /// this Mac; the update that removed the SSH path is what interrupted it.
  func interruptLegacyRemoteRunsUnlocked(conversationID: String) throws {
    let workspaceID = try libraryIDsUnlocked("""
      SELECT remote_workspace_id FROM harness_sessions WHERE conversation_id=? AND remote_workspace_id IS NOT NULL
      """, bindings: [conversationID]).first
    let name = try workspaceID.flatMap { try federationWorkspaceUnlocked($0)?.name }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    let detail = Self.legacyRemoteInterruption(host: name)
    let now = Self.timestamp(Date())
    let unsettled = "('running','queued','pending','cancelling','uncertain')"
    try toolsExecuteUnlocked("""
      UPDATE messages SET content=CASE WHEN content='' THEN ? ELSE content END,status='interrupted',updated_at=?
      WHERE role='assistant' AND id IN (SELECT assistant_message_id FROM runs
        WHERE conversation_id=? AND status IN \(unsettled))
      """, [detail, now, conversationID])
    try toolsExecuteUnlocked("""
      UPDATE runs SET status='interrupted',error=?,updated_at=?,completed_at=COALESCE(completed_at,?)
      WHERE conversation_id=? AND status IN \(unsettled)
      """, [detail, now, now, conversationID])
  }

  static func legacyRemoteInterruption(host: String?) -> String {
    "This run on \(host ?? "the Linux host") was interrupted when Woven Matter updated."
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
  public func hasExecutionAdoption(conversationID: String) async throws -> Bool {
    try await read { try $0.hasExecutionAdoption(conversationID: conversationID) }
  }
  public func interruptLegacyRemoteRuns(conversationID: String) async throws {
    try await write { try $0.interruptLegacyRemoteRuns(conversationID: conversationID) }
  }
}

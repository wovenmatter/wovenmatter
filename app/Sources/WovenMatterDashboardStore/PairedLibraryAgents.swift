import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabase {
  public func pairedAgentWorkspaces() async throws -> [UUID: CompanionExecutionWorkspace] {
    try await read { connection in
      let own = try connection.companionLibraryIdentityUnlocked().hostDeviceID
      let workspaces = try connection.companionExecutionWorkspaces()
      var result: [UUID: CompanionExecutionWorkspace] = [:]
      for row in try connection.historyRowsUnlocked("SELECT a.id,a.governing_plane,a.runtime_device_id,p.device_id FROM dashboard_agents a JOIN paired_agent_owners p ON p.id=a.id WHERE p.device_id<>? AND a.deleted_at IS NULL", values: [own]) {
        guard let fields = row.objectValue, let id = fields["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let owner = fields["device_id"]?.stringValue else { continue }
        let workspace: CompanionExecutionWorkspace?
        if fields["governing_plane"]?.stringValue == "remote_workspace", let remote = fields["runtime_device_id"]?.stringValue {
          workspace = workspaces.first { $0.id == remote.lowercased() && !$0.deleted }
        } else { workspace = workspaces.first { $0.kind == .mac && $0.ownerDeviceID == owner && !$0.deleted } }
        if let workspace { result[id] = workspace }
      }
      return result
    }
  }

  /// Acknowledged remote creation gets an immediate local presentation. It owns
  /// no runtime bindings and is replaced by the owner's ordinary shared rows.
  public func installPairedConversationPlaceholder(id: String, agentID: UUID, workspace: CompanionExecutionWorkspace, runtimeKind: String) async throws {
    try await write { connection in
      try connection.transaction {
        try connection.executeUnlocked("UPDATE paired_library_clock SET applying=1")
        let now = WorkspaceDatabaseConnection.timestamp(Date())
        try connection.toolsExecuteUnlocked("INSERT OR IGNORE INTO dashboard_conversations(id,user_id,agent_id,title,desktop_owned,created_at,updated_at) VALUES(?,?,?,'New conversation',1,?,?)",
          [id, try connection.localMutationOperatorIDUnlocked(), agentID.uuidString.lowercased(), now, now])
        if workspace.kind == .mac {
          try connection.toolsExecuteUnlocked("INSERT OR IGNORE INTO paired_conversation_owners VALUES(?,?)", [id, workspace.ownerDeviceID])
        }
        let value = CompanionConversation(id: id, title: "New conversation", providerID: "local:" + runtimeKind,
          routeID: "local:" + runtimeKind, runtimeKind: runtimeKind, libraryID: workspace.libraryID, workspaceID: workspace.id)
        let query = try connection.prepareUnlocked("INSERT OR IGNORE INTO companion_execution_conversations(id,workspace_id,conversation) VALUES(?,?,?)")
        defer { sqlite3_finalize(query) }
        try connection.bind(id, at: 1, to: query); try connection.bind(workspace.id, at: 2, to: query)
        try connection.bind(JSONEncoder().encode(value), at: 3, to: query); try connection.stepDone(query)
        try connection.executeUnlocked("UPDATE paired_library_clock SET applying=0")
      }
    }
  }
}

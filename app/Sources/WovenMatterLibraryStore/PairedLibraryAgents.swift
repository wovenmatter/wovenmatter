import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

/// Where each agent runs, from its owner record alone. An agent's
/// `execution_location` says only how its owner reaches it: another Mac's
/// local agent is remote from here.
public struct AgentPlacements: Equatable, Sendable {
  /// Agents whose owner record names this library's host.
  public var own: Set<UUID>
  /// Agents another member owns, each with the workspace that runs it: the
  /// Linux workspace it names, else its owner Mac's. An agent without an
  /// owner record, or whose workspace is not registered here yet, is in
  /// neither.
  public var workspaces: [UUID: ExecutionWorkspace]
  public init(own: Set<UUID> = [], workspaces: [UUID: ExecutionWorkspace] = [:]) { self.own = own; self.workspaces = workspaces }
}

extension ExecutionWorkspace {
  /// The registry row that stands for the Mac whose library host is `owner`.
  /// A Mac can have more than one: its Dev instances register beside it, and
  /// a live Dev build shares its library host. See `preferred(among:)`.
  public static func macWorkspace(ownedBy owner: String, in registry: [ExecutionWorkspace]) -> ExecutionWorkspace? {
    preferred(among: registry.filter { $0.kind == .mac && $0.ownerDeviceID == owner && !$0.deleted })
  }

  /// Of several rows for one machine, the one its agents, chats and folders
  /// belong to, the same wherever one is chosen. A row still listed in
  /// connections comes before one that is not (a stopped Dev instance), one
  /// with an address before one without, and at each step the production
  /// row before a Dev instance's: a live Dev build that quit without
  /// withdrawing keeps its address, and must not take the Mac's agents and
  /// folders from the row its user sees as that Mac. Then a row that is not
  /// copied history, then any; the registry's order breaks a tie.
  public static func preferred(among rows: [ExecutionWorkspace]) -> ExecutionWorkspace? {
    func rank(_ row: ExecutionWorkspace) -> Int {
      let development = row.developmentInstance == nil ? 0 : 1
      if row.isVisibleInConnections { return (row.endpoint != nil ? 0 : 2) + development }
      return row.retainedHistory != true ? 4 : 5
    }
    return rows.enumerated().min { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?.element
  }
}

extension WorkspaceDatabase {
  public func agentPlacements() async throws -> AgentPlacements {
    try await read { connection in
      let own = try connection.libraryIdentityUnlocked().hostDeviceID
      let workspaces = try connection.libraryExecutionWorkspaces()
      var result = AgentPlacements()
      for row in try connection.historyRowsUnlocked("SELECT a.id,a.execution_location,a.runtime_device_id,p.device_id FROM agents a JOIN agent_owners p ON p.id=a.id WHERE a.deleted_at IS NULL", values: []) {
        guard let fields = row.objectValue, let id = fields["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let owner = fields["device_id"]?.stringValue else { continue }
        if owner == own { result.own.insert(id); continue }
        let workspace: ExecutionWorkspace?
        if fields["execution_location"]?.stringValue == "remote", let remote = fields["runtime_device_id"]?.stringValue {
          workspace = workspaces.first { $0.id == remote.lowercased() && !$0.deleted }
        } else { workspace = ExecutionWorkspace.macWorkspace(ownedBy: owner, in: workspaces) }
        if let workspace { result.workspaces[id] = workspace }
      }
      return result
    }
  }

  public func pairedAgentWorkspaces() async throws -> [UUID: ExecutionWorkspace] { try await agentPlacements().workspaces }

  /// Acknowledged remote creation gets an immediate local presentation. It owns
  /// no runtime bindings and is replaced by the owner's ordinary shared rows.
  public func installPairedConversationPlaceholder(id: String, agentID: UUID, workspace: ExecutionWorkspace, runtimeKind: String) async throws {
    try await write { connection in
      try connection.transaction {
        try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=1")
        let now = WorkspaceDatabaseConnection.timestamp(Date())
        try connection.toolsExecuteUnlocked("INSERT OR IGNORE INTO conversations(id,agent_id,title,created_at,updated_at) VALUES(?,?,'New conversation',?,?)",
          [id, agentID.uuidString.lowercased(), now, now])
        if workspace.kind == .mac {
          try connection.toolsExecuteUnlocked("INSERT OR IGNORE INTO conversation_owners VALUES(?,?)", [id, workspace.ownerDeviceID])
        }
        let value = LibraryConversation(id: id, title: "New conversation", providerID: "local:" + runtimeKind,
          routeID: "local:" + runtimeKind, runtimeKind: runtimeKind, libraryID: workspace.libraryID, workspaceID: workspace.id)
        let query = try connection.prepareUnlocked("INSERT OR IGNORE INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,?)")
        defer { sqlite3_finalize(query) }
        try connection.bind(id, at: 1, to: query); try connection.bind(workspace.id, at: 2, to: query)
        try connection.bindJSON(value, at: 3, to: query); try connection.stepDone(query)
        try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=0")
      }
    }
  }
}

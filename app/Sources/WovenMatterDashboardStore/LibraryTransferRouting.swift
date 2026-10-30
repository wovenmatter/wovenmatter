import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  func retiredProjectionOwner(libraryID: String? = nil, workspaceID: String) throws -> String? {
    let query = try prepareUnlocked("SELECT owner_device_id FROM library_transfer_retired WHERE workspace_id=? AND (? IS NULL OR library_id=?)")
    defer { sqlite3_finalize(query) }; try bind(workspaceID, at: 1, to: query)
    try bindNullable(libraryID, at: 2, to: query); try bindNullable(libraryID, at: 3, to: query)
    if sqlite3_step(query) == SQLITE_ROW { return try text(query, column: 0) }; return nil
  }
  func retireLibraryAuthority(workspace: CompanionExecutionWorkspace) throws {
    try transaction {
      try companionExecuteUnlocked("INSERT OR REPLACE INTO library_transfer_retired VALUES(1,?,?,?)", values: [workspace.libraryID,workspace.id,workspace.ownerDeviceID])
      try companionExecuteUnlocked("INSERT OR IGNORE INTO companion_calendar_owners(event_id,device_id) SELECT id,? FROM dashboard_calendar_items WHERE json_extract(calendar_json,'$.task') IS NOT NULL", values: [workspace.ownerDeviceID])
      try executeUnlocked("INSERT OR IGNORE INTO companion_calendar_run_owners(event_id,device_id) SELECT event_id,device_id FROM companion_calendar_owners")
    }
  }
  func libraryTransferAliases() throws -> [CompanionLibraryRelocation] {
    try federationValuesUnlocked("SELECT payload FROM library_transfer_aliases ORDER BY library_id", as: CompanionLibraryRelocation.self)
  }
  func installLibraryTransferAlias(_ relocation: CompanionLibraryRelocation) throws {
    try transaction {
      let query = try prepareUnlocked("INSERT INTO library_transfer_aliases(library_id,payload) VALUES(?,?) ON CONFLICT(library_id) DO UPDATE SET payload=excluded.payload")
      defer { sqlite3_finalize(query) }; try bind(relocation.previousLibraryID, at: 1, to: query)
      try bind(JSONEncoder().encode(relocation), at: 2, to: query); try stepDone(query)
    }
  }
  /// Only the export copy is changed. Native session metadata and files remain
  /// on their owner; the new central gets full read history and an explicit route.
  func projectLibraryTransferOrigins() throws {
    try transaction {
      let identity = try companionLibraryIdentityUnlocked()
      guard let local = try companionExecutionWorkspaces().first(where: { $0.kind == .mac && $0.executionDeviceID == identity.hostDeviceID }) else {
        throw CompanionAPIError(code: "transfer_workspace", message: "Enable Apple device connections before transferring this database.")
      }
      var publishedLocal = local
      publishedLocal.capabilities.removeAll { $0 == "history.central.v1" }
      let workspaceUpdate = try prepareUnlocked("UPDATE companion_execution_workspaces SET payload=? WHERE id=?")
      defer { sqlite3_finalize(workspaceUpdate) }
      try bind(JSONEncoder().encode(publishedLocal), at: 1, to: workspaceUpdate); try bind(local.id, at: 2, to: workspaceUpdate); try stepDone(workspaceUpdate)
      for id in try companionIDsUnlocked("SELECT id FROM dashboard_conversations WHERE id NOT IN(SELECT id FROM companion_execution_conversations)", bindings: []) {
        guard var conversation = try companionConversationUnlocked(id: id) else { continue }
        if let route = conversation.routeID ?? conversation.providerID, !route.hasPrefix("local:") {
          // Native remote sessions must first be adopted by their actual owner.
          // Archived legacy records remain preserved by the full SQL snapshot.
          if try companionIDsUnlocked("SELECT id FROM dashboard_conversations WHERE id=? AND is_archived=0 AND deleted_at IS NULL", bindings: [id]).isEmpty == false {
            throw CompanionAPIError(code: "transfer_owner", message: "Reconnect the remote workspace and refresh its idle conversations before transferring the central database.")
          }
          continue
        }
        conversation.workspaceID = local.id; conversation.libraryID = identity.libraryID
        let insert = try prepareUnlocked("INSERT INTO companion_execution_conversations(id,workspace_id,deleted,conversation,transcript) VALUES(?,?,0,?,?)")
        defer { sqlite3_finalize(insert) }
        try bind(id, at: 1, to: insert); try bind(local.id, at: 2, to: insert)
        try bind(JSONEncoder().encode(conversation), at: 3, to: insert)
        try bind(JSONEncoder().encode(federationLegacyTranscriptUnlocked(id)), at: 4, to: insert); try stepDone(insert)
        for run in try companionIDsUnlocked("SELECT id FROM dashboard_runs WHERE conversation_id=?", bindings: [id]) {
          try companionExecuteUnlocked("INSERT OR IGNORE INTO companion_execution_runs VALUES(?,?,?)", values: [run, local.id, id])
        }
      }
      // A path that is local to the source must never become local to the target.
      let roots = try prepareUnlocked("UPDATE folder_execution_roots SET workspace_id=? WHERE workspace_id IN ('local',?,'device:'||(SELECT device_id FROM desktop_local_identity WHERE singleton=1))")
      defer { sqlite3_finalize(roots) }; try bind(local.id, at: 1, to: roots)
      try bind("device:" + identity.hostDeviceID, at: 2, to: roots); try stepDone(roots)
      // Source-owned schedules remain source-owned. Merely copying their rows
      // must never schedule a second execution on the new central Mac.
      try companionExecuteUnlocked("INSERT OR IGNORE INTO companion_calendar_owners(event_id,device_id) SELECT id,? FROM dashboard_calendar_items WHERE json_extract(calendar_json,'$.task') IS NOT NULL", values: [identity.hostDeviceID])
      try executeUnlocked("INSERT OR IGNORE INTO companion_calendar_run_owners(event_id,device_id) SELECT event_id,device_id FROM companion_calendar_owners")
      try companionExecuteUnlocked("UPDATE dashboard_calendar_items SET calendar_json=json_set(calendar_json,'$.task.configuration.workspaceID',?) WHERE json_extract(calendar_json,'$.task') IS NOT NULL AND json_extract(calendar_json,'$.task.configuration.workspaceID') IS NULL AND id IN(SELECT event_id FROM companion_calendar_owners WHERE device_id=?)", values: [local.id,identity.hostDeviceID])
    }
  }
}

extension WorkspaceDatabase {
  public func retireLibraryAuthority(workspace: CompanionExecutionWorkspace) async throws { try await transferWrite { try $0.retireLibraryAuthority(workspace: workspace) } }
  public func prepareReceivedLibraryAuthority() async throws {
    try await write { connection in
      try connection.transaction {
        let identity = try connection.companionLibraryIdentityUnlocked()
        try connection.companionExecuteUnlocked("UPDATE dashboard_calendar_items SET calendar_json=json_remove(calendar_json,'$.task.configuration.workspaceID') WHERE id IN(SELECT event_id FROM companion_calendar_owners WHERE device_id=?) AND json_extract(calendar_json,'$.task') IS NOT NULL", values: [identity.hostDeviceID])
        try connection.companionExecuteUnlocked("DELETE FROM companion_calendar_owners WHERE device_id=?", values: [identity.hostDeviceID])
        try connection.executeUnlocked("DELETE FROM library_transfer_retired")
        try connection.executeUnlocked("DELETE FROM companion_calendar_execution_context")
        if try connection.companionIDsUnlocked("SELECT name FROM sqlite_master WHERE type='table' AND name='companion_execution_replica_context'", bindings: []).isEmpty == false {
          try connection.executeUnlocked("DELETE FROM companion_execution_replica_context")
        }
      }
    }
  }
  public func libraryTransferAliases() async throws -> [CompanionLibraryRelocation] { try await read { try $0.libraryTransferAliases() } }
  public func installLibraryTransferAlias(_ relocation: CompanionLibraryRelocation) async throws { try await write { try $0.installLibraryTransferAlias(relocation) } }
  public func projectLibraryTransferOrigins() async throws { try await write { try $0.projectLibraryTransferOrigins() } }
}

/// Translate logical library identities at the library boundary. Execution
/// credentials keep the original owner's scope in executionLibraryID.
public enum LibraryTransferRouting {
  public static func request(_ request: CompanionHTTPRequest, from previous: String, to current: String) throws -> CompanionHTTPRequest {
    var headers = request.headers
    if headers["x-woven-workspace"] == previous { headers["x-woven-workspace"] = current }
    let body = request.body.isEmpty || request.target.contains("/mcp") ? request.body : try CompanionLibraryJSON.rewrite(request.body, from: previous, to: current)
    return .init(method: request.method, target: request.target, headers: headers, body: body)
  }
  public static func response(_ response: CompanionHTTPResponse, from current: String, to previous: String) throws -> CompanionHTTPResponse {
    guard !response.body.isEmpty, response.contentType.hasPrefix("application/json") else { return response }
    return .init(status: response.status, contentType: response.contentType, headers: response.headers,
                 body: try CompanionLibraryJSON.rewrite(response.body, from: current, to: previous))
  }
}

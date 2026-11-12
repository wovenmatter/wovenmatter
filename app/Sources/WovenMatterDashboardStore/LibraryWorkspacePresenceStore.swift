import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Temporary absence is a projection, not a destructive registry change. A
  /// running Dev that reconnects after network loss becomes visible again.
  public func libraryConnectionWorkspaces(activeDeviceIDs: Set<String>) throws -> [ExecutionWorkspace] {
    try withLock {
      let hostID = try libraryIdentityUnlocked().hostDeviceID
      return try federationValuesUnlocked("SELECT payload FROM device_execution_workspaces ORDER BY id", as: ExecutionWorkspace.self).map { stored in
        var value = stored
        if value.developmentInstance != nil, value.ownerDeviceID != hostID, !activeDeviceIDs.contains(value.ownerDeviceID) {
          value.endpoint = nil
        }
        return value
      }
    }
  }

  /// An explicit Dev quit withdraws its advertised routes, retaining identities
  /// and history so the same instance can register again on its next launch.
  public func withdrawDevelopmentWorkspaces(ownedBy deviceID: String) throws {
    let identity = try libraryIdentity()
    for var workspace in try libraryExecutionWorkspaces() where !workspace.deleted
        && workspace.ownerDeviceID == deviceID && workspace.kind == .mac && workspace.endpoint != nil {
      workspace.developmentInstance = workspace.developmentInstance ?? deviceID
      workspace.endpoint = nil
      _ = try registerExecutionWorkspace(.init(workspace: workspace, expectedRevision: workspace.revision), deviceID: identity.hostDeviceID)
    }
  }
}

extension WorkspaceDatabase {
  public func libraryConnectionWorkspaces(activeDeviceIDs: Set<String>) async throws -> [ExecutionWorkspace] {
    try await read { try $0.libraryConnectionWorkspaces(activeDeviceIDs: activeDeviceIDs) }
  }
  public func withdrawDevelopmentWorkspaces(ownedBy deviceID: String) async throws {
    try await write { try $0.withdrawDevelopmentWorkspaces(ownedBy: deviceID) }
  }
}

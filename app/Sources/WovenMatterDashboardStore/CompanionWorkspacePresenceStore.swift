import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Temporary absence is a projection, not a destructive registry change. A
  /// running Dev that reconnects after network loss becomes visible again.
  public func companionConnectionWorkspaces(activeDeviceIDs: Set<String>) throws -> [CompanionExecutionWorkspace] {
    try withLock {
      let hostID = try companionLibraryIdentityUnlocked().hostDeviceID
      return try federationValuesUnlocked("SELECT payload FROM companion_execution_workspaces ORDER BY id", as: CompanionExecutionWorkspace.self).map { stored in
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
    let identity = try companionLibraryIdentity()
    for var workspace in try companionExecutionWorkspaces() where !workspace.deleted
        && workspace.ownerDeviceID == deviceID && workspace.kind == .mac && workspace.endpoint != nil {
      workspace.developmentInstance = workspace.developmentInstance ?? deviceID
      workspace.endpoint = nil
      _ = try registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: workspace.revision), deviceID: identity.hostDeviceID)
    }
  }
}

extension WorkspaceDatabase {
  public func companionConnectionWorkspaces(activeDeviceIDs: Set<String>) async throws -> [CompanionExecutionWorkspace] {
    try await read { try $0.companionConnectionWorkspaces(activeDeviceIDs: activeDeviceIDs) }
  }
  public func withdrawDevelopmentWorkspaces(ownedBy deviceID: String) async throws {
    try await write { try $0.withdrawDevelopmentWorkspaces(ownedBy: deviceID) }
  }
}

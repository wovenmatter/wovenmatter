import Foundation
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Temporary absence is a projection, not a destructive registry change. A
  /// running Dev that reconnects after network loss becomes visible again.
  public func libraryConnectionWorkspaces(activeDeviceIDs: Set<String>) throws -> [ExecutionWorkspace] {
    try withLock {
      let hostID = try libraryIdentityUnlocked().hostDeviceID
      return try federationValuesUnlocked("SELECT payload FROM execution_workspaces ORDER BY id", as: ExecutionWorkspace.self).map { stored in
        var value = stored
        if value.developmentInstance != nil, value.ownerDeviceID != hostID, !activeDeviceIDs.contains(value.ownerDeviceID) {
          value.endpoint = nil
        }
        return value
      }
    }
  }
}

extension WorkspaceDatabase {
  public func libraryConnectionWorkspaces(activeDeviceIDs: Set<String>) async throws -> [ExecutionWorkspace] {
    try await read { try $0.libraryConnectionWorkspaces(activeDeviceIDs: activeDeviceIDs) }
  }}

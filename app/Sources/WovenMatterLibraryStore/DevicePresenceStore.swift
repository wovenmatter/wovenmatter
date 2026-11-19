import Foundation
import WovenMatterCore

extension ExecutionWorkspace {
  /// The registry as connections are listed: another device's Dev instance
  /// that is no longer active (`activeDeviceIDs`, the paired devices seen
  /// lately) has no address, so it is not `isVisibleInConnections`. A Dev
  /// instance that quit without withdrawing its row is hidden this way.
  /// Production rows are untouched, online or not, and so is every row of
  /// this library's own host. Settings, the sidebar and New Chat all list
  /// from this one projection. Temporary absence is a projection, not a
  /// destructive registry change: a running Dev that reconnects after network
  /// loss becomes visible again.
  public static func connections(_ registry: [ExecutionWorkspace], hostDeviceID: String?,
                                 activeDeviceIDs: Set<String>) -> [ExecutionWorkspace] {
    registry.map { stored in
      var value = stored
      if value.developmentInstance != nil, value.ownerDeviceID != hostDeviceID, !activeDeviceIDs.contains(value.ownerDeviceID) {
        value.endpoint = nil
      }
      return value
    }
  }
}

extension WorkspaceDatabaseConnection {
  public func libraryConnectionWorkspaces(activeDeviceIDs: Set<String>) throws -> [ExecutionWorkspace] {
    try withLock {
      let hostID = try libraryIdentityUnlocked().hostDeviceID
      return ExecutionWorkspace.connections(
        try federationValuesUnlocked("SELECT payload FROM execution_workspaces ORDER BY id", as: ExecutionWorkspace.self, skippingUnreadable: true),
        hostDeviceID: hostID, activeDeviceIDs: activeDeviceIDs)
    }
  }
}

extension WorkspaceDatabase {
  public func libraryConnectionWorkspaces(activeDeviceIDs: Set<String>) async throws -> [ExecutionWorkspace] {
    try await read { try $0.libraryConnectionWorkspaces(activeDeviceIDs: activeDeviceIDs) }
  }}

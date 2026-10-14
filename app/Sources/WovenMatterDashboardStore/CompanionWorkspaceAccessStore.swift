import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  public func companionWorkspaceAccessPolicies() throws -> [CompanionWorkspaceAccessPolicy] {
    try withLock {
      let statement = try prepareUnlocked("SELECT device_id,workspace_id,enabled FROM companion_workspace_access ORDER BY device_id,workspace_id")
      defer { sqlite3_finalize(statement) }
      var policies: [CompanionWorkspaceAccessPolicy] = []
      while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return policies }
        guard result == SQLITE_ROW else { throw stepError() }
        policies.append(.init(deviceID: try text(statement, column: 0), workspaceID: try text(statement, column: 1),
                              enabled: sqlite3_column_int(statement, 2) != 0))
      }
    }
  }

  /// Default access follows central pairing; an explicit deny survives restart,
  /// workspace re-registration and device re-pairing. Pairing authentication is
  /// checked separately by the host before any credential can be provisioned.
  public func companionWorkspaceAccessAllowed(deviceID: String, workspaceID: String) throws -> Bool {
    try withLock {
      guard federationID(deviceID), let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted else { return false }
      let statement = try prepareUnlocked("SELECT enabled FROM companion_workspace_access WHERE device_id=? AND workspace_id=?")
      defer { sqlite3_finalize(statement) }
      try bind(deviceID, at: 1, to: statement); try bind(workspaceID, at: 2, to: statement)
      switch sqlite3_step(statement) {
      case SQLITE_DONE: return true
      case SQLITE_ROW: return sqlite3_column_int(statement, 0) != 0
      default: throw stepError()
      }
    }
  }

  public func setCompanionWorkspaceAccess(deviceID: String, workspaceID: String, enabled: Bool, authorizedBy: String) throws {
    try transaction {
      let identity = try companionLibraryIdentityUnlocked()
      guard authorizedBy == identity.hostDeviceID else {
        throw federationError("wrong_owner", "Only the central Mac can change device execution access.")
      }
      guard federationID(deviceID), deviceID != identity.hostDeviceID,
            let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted else {
        throw federationError("invalid_workspace", "Choose a paired device and an available execution workspace.")
      }
      let statement = try prepareUnlocked("INSERT INTO companion_workspace_access(device_id,workspace_id,enabled) VALUES (?,?,?) ON CONFLICT(device_id,workspace_id) DO UPDATE SET enabled=excluded.enabled")
      defer { sqlite3_finalize(statement) }
      try bind(deviceID, at: 1, to: statement); try bind(workspaceID, at: 2, to: statement)
      sqlite3_bind_int(statement, 3, enabled ? 1 : 0); try stepDone(statement)
    }
  }
}

extension WorkspaceDatabase {
  public func companionWorkspaceAccessPolicies() async throws -> [CompanionWorkspaceAccessPolicy] {
    try await read { try $0.companionWorkspaceAccessPolicies() }
  }
  public func companionWorkspaceAccessAllowed(deviceID: String, workspaceID: String) async throws -> Bool {
    try await read { try $0.companionWorkspaceAccessAllowed(deviceID: deviceID, workspaceID: workspaceID) }
  }
  public func setCompanionWorkspaceAccess(deviceID: String, workspaceID: String, enabled: Bool, authorizedBy: String) async throws {
    try await write { try $0.setCompanionWorkspaceAccess(deviceID: deviceID, workspaceID: workspaceID, enabled: enabled, authorizedBy: authorizedBy) }
  }
}

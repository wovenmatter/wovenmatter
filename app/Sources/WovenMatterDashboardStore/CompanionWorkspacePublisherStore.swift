import CryptoKit
import Foundation
import Security
import SQLite3
import WovenMatterCore

public struct CompanionWorkspacePublisherPrincipal: Sendable {
  public let grantID: String
  public let libraryID: String
  public let workspaceID: String
  public let executionDeviceID: String
}
private struct WorkspacePublisherRecord: Codable {
  var grantID: String
  var workspaceID: String
  var libraryID: String
  var executionDeviceID: String
  var endpoint: URL
}
extension WorkspaceDatabaseConnection {
  public func issueCompanionWorkspacePublisher(workspaceID: String, endpoint: URL, deviceID: String) throws -> CompanionWorkspacePublisherGrant {
    try transaction {
      let identity = try companionLibraryIdentityUnlocked()
      guard deviceID == identity.hostDeviceID, CompanionPairingPayload.isValidEndpoint(endpoint),
            let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted,
            let executor = workspace.executionDeviceID, federationID(executor), workspace.kind == .linux else {
        throw federationError("wrong_owner", "Only the central host can issue a publisher for a registered Linux execution owner.")
      }
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw federationError("unavailable", "Unable to create a workspace publisher.") }
      let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
      let record = WorkspacePublisherRecord(grantID: UUID().uuidString.lowercased(), workspaceID: workspaceID,
        libraryID: identity.libraryID, executionDeviceID: executor, endpoint: endpoint)
      try companionExecuteUnlocked("DELETE FROM companion_workspace_publisher_aliases WHERE workspace_id=?", values: [workspaceID])
      let statement = try prepareUnlocked("INSERT INTO companion_workspace_publishers(workspace_id,digest,payload) VALUES (?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET digest=excluded.digest,payload=excluded.payload")
      defer { sqlite3_finalize(statement) }
      try bind(workspaceID, at: 1, to: statement); try bind(Data(SHA256.hash(data: Data(token.utf8))), at: 2, to: statement)
      try bind(JSONEncoder().encode(record), at: 3, to: statement); try stepDone(statement)
      return .init(grantID: record.grantID, libraryID: record.libraryID, workspaceID: workspaceID, executionDeviceID: executor, endpoint: endpoint, token: token)
    }
  }
  public func companionWorkspacePublisherMatches(workspaceID: String, grantID: String, endpoint: URL) throws -> Bool {
    try withLock {
      guard let record = try federationValuesUnlocked("SELECT payload FROM companion_workspace_publishers WHERE workspace_id=?", bindings: [workspaceID], as: WorkspacePublisherRecord.self).first,
            let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted else { return false }
      return record.grantID == grantID && record.endpoint == endpoint && record.executionDeviceID == workspace.executionDeviceID
    }
  }
  public func authenticateCompanionWorkspacePublisher(bearer: String) throws -> CompanionWorkspacePublisherPrincipal {
    try withLock {
      guard (32...256).contains(bearer.utf8.count) else { throw federationError("unauthorized", "Invalid workspace publisher.") }
      let statement = try prepareUnlocked("SELECT payload FROM companion_workspace_publishers WHERE digest=?1 UNION ALL SELECT payload FROM companion_workspace_publisher_aliases WHERE digest=?1")
      defer { sqlite3_finalize(statement) }
      try bind(Data(SHA256.hash(data: Data(bearer.utf8))), at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw federationError("unauthorized", "Invalid workspace publisher.") }
      let record = try JSONDecoder().decode(WorkspacePublisherRecord.self, from: blob(statement, column: 0))
      guard record.libraryID == (try companionWorkspaceIDUnlocked()), let workspace = try federationWorkspaceUnlocked(record.workspaceID),
            !workspace.deleted, workspace.kind == .linux, workspace.executionDeviceID == record.executionDeviceID else {
        throw federationError("unauthorized", "This workspace publisher is no longer authorized.")
      }
      return .init(grantID: record.grantID, libraryID: record.libraryID, workspaceID: record.workspaceID, executionDeviceID: record.executionDeviceID)
    }
  }
}
extension WorkspaceDatabase {
  public func issueCompanionWorkspacePublisher(workspaceID: String, endpoint: URL, deviceID: String) async throws -> CompanionWorkspacePublisherGrant {
    try await write { try $0.issueCompanionWorkspacePublisher(workspaceID: workspaceID, endpoint: endpoint, deviceID: deviceID) }
  }
  public func companionWorkspacePublisherMatches(workspaceID: String, grantID: String, endpoint: URL) async throws -> Bool {
    try await read { try $0.companionWorkspacePublisherMatches(workspaceID: workspaceID, grantID: grantID, endpoint: endpoint) }
  }
  public func authenticateCompanionWorkspacePublisher(bearer: String) async throws -> CompanionWorkspacePublisherPrincipal {
    try await read { try $0.authenticateCompanionWorkspacePublisher(bearer: bearer) }
  }
}

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

public struct LibraryWorkspacePublisherPrincipal: Sendable {
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
  public func issueLibraryWorkspacePublisher(workspaceID: String, endpoint: URL, deviceID: String) throws -> LibraryWorkspacePublisherGrant {
    try transaction {
      let identity = try libraryIdentityUnlocked()
      guard deviceID == identity.hostDeviceID, PairingPayload.isValidEndpoint(endpoint),
            let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted,
            let executor = workspace.executionDeviceID, federationID(executor), workspace.kind == .linux else {
        throw federationError("wrong_owner", "Only the central host can issue a publisher for a registered Linux execution owner.")
      }
      guard let token = GrantSecrets.randomToken() else { throw federationError("unavailable", "Unable to create a workspace publisher.") }
      let record = WorkspacePublisherRecord(grantID: UUID().uuidString.lowercased(), workspaceID: workspaceID,
        libraryID: identity.libraryID, executionDeviceID: executor, endpoint: endpoint)
      let statement = try prepareUnlocked("INSERT INTO library_workspace_publishers(workspace_id,digest,payload) VALUES (?,?,?) ON CONFLICT(workspace_id) DO UPDATE SET digest=excluded.digest,payload=excluded.payload")
      defer { sqlite3_finalize(statement) }
      try bind(workspaceID, at: 1, to: statement); try bind(Data(SHA256.hash(data: Data(token.utf8))), at: 2, to: statement)
      try bind(JSONEncoder().encode(record), at: 3, to: statement); try stepDone(statement)
      return .init(grantID: record.grantID, libraryID: record.libraryID, workspaceID: workspaceID, executionDeviceID: executor, endpoint: endpoint, token: token)
    }
  }
  public func libraryWorkspacePublisherMatches(workspaceID: String, grantID: String, endpoint: URL) throws -> Bool {
    try withLock {
      guard let record = try federationValuesUnlocked("SELECT payload FROM library_workspace_publishers WHERE workspace_id=?", bindings: [workspaceID], as: WorkspacePublisherRecord.self).first,
            let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted else { return false }
      return record.grantID == grantID && record.endpoint == endpoint && record.executionDeviceID == workspace.executionDeviceID
    }
  }
  public func authenticateLibraryWorkspacePublisher(bearer: String) throws -> LibraryWorkspacePublisherPrincipal {
    try withLock {
      guard (32...256).contains(bearer.utf8.count) else { throw federationError("unauthorized", "Invalid workspace publisher.") }
      let statement = try prepareUnlocked("SELECT payload FROM library_workspace_publishers WHERE digest=?")
      defer { sqlite3_finalize(statement) }
      try bind(Data(SHA256.hash(data: Data(bearer.utf8))), at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW else { throw federationError("unauthorized", "Invalid workspace publisher.") }
      let record = try JSONDecoder().decode(WorkspacePublisherRecord.self, from: blob(statement, column: 0))
      guard record.libraryID == (try libraryWorkspaceIDUnlocked()), let workspace = try federationWorkspaceUnlocked(record.workspaceID),
            !workspace.deleted, workspace.kind == .linux, workspace.executionDeviceID == record.executionDeviceID else {
        throw federationError("unauthorized", "This workspace publisher is no longer authorized.")
      }
      return .init(grantID: record.grantID, libraryID: record.libraryID, workspaceID: record.workspaceID, executionDeviceID: record.executionDeviceID)
    }
  }
}
extension WorkspaceDatabase {
  public func issueLibraryWorkspacePublisher(workspaceID: String, endpoint: URL, deviceID: String) async throws -> LibraryWorkspacePublisherGrant {
    try await write { try $0.issueLibraryWorkspacePublisher(workspaceID: workspaceID, endpoint: endpoint, deviceID: deviceID) }
  }
  public func libraryWorkspacePublisherMatches(workspaceID: String, grantID: String, endpoint: URL) async throws -> Bool {
    try await read { try $0.libraryWorkspacePublisherMatches(workspaceID: workspaceID, grantID: grantID, endpoint: endpoint) }
  }
  public func authenticateLibraryWorkspacePublisher(bearer: String) async throws -> LibraryWorkspacePublisherPrincipal {
    try await read { try $0.authenticateLibraryWorkspacePublisher(bearer: bearer) }
  }
}

import Foundation

/// A service publisher can submit only its own execution journal and explicitly
/// saved artifacts, and resolve exact retained-run associations for that workspace.
/// It is not a paired-device, command, inference, or general library read grant.
public struct LibraryWorkspacePublisherGrant: Codable, Equatable, Sendable {
  public var grantID: String
  public var libraryID: String
  public var workspaceID: String
  public var executionDeviceID: String
  public var endpoint: URL
  public var token: String
  public init(grantID: String, libraryID: String, workspaceID: String, executionDeviceID: String, endpoint: URL, token: String) {
    self.grantID = grantID; self.libraryID = libraryID; self.workspaceID = workspaceID
    self.executionDeviceID = executionDeviceID; self.endpoint = endpoint; self.token = token
  }
}
public struct LibraryWorkspacePublisherStatus: Codable, Equatable, Sendable {
  public var configured: Bool
  public var grantID: String?
  public var acknowledgedOriginSequence: Int64?
  public var pendingArtifacts: Int?
  public var journal: LibraryWorkspacePublicationLane?
  public var artifacts: LibraryWorkspacePublicationLane?
  public init(configured: Bool, grantID: String? = nil) { self.configured = configured; self.grantID = grantID }
}

public struct LibraryWorkspacePublicationLane: Codable, Equatable, Sendable {
  public var failureCount: Int
  public var nextAttemptAt: Int64
  public var lastSuccessAt: String?
  public var lastErrorCode: String?
}

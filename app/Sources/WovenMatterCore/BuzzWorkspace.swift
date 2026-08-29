import Foundation

/// A user-selected local Buzz workspace and its agent catalog.
public struct BuzzWorkspaceLink: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var displayName: String
  public var localWorkspaceURL: URL
  public var localAgentStoreURL: URL
  public var isEnabled: Bool
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    displayName: String,
    localWorkspaceURL: URL,
    localAgentStoreURL: URL,
    isEnabled: Bool = true,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.displayName = displayName
    self.localWorkspaceURL = localWorkspaceURL
    self.localAgentStoreURL = localAgentStoreURL
    self.isEnabled = isEnabled
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// A redacted, transient projection returned by local Buzz discovery.
public struct BuzzWorkspaceAgentCandidate: Codable, Equatable, Identifiable, Sendable {
  public let workspaceLinkID: UUID
  public let agentID: String
  public let handle: String
  public let displayName: String
  public let definitionID: String?
  public let harnessIdentifier: String
  public let runtimeKind: AgentRuntimeKind?

  public var id: String {
    "\(workspaceLinkID.uuidString.lowercased()):\(agentID)"
  }

  public init(
    workspaceLinkID: UUID,
    agentID: String,
    handle: String,
    displayName: String,
    definitionID: String? = nil,
    harnessIdentifier: String,
    runtimeKind: AgentRuntimeKind?
  ) {
    self.workspaceLinkID = workspaceLinkID
    self.agentID = agentID
    self.handle = handle
    self.displayName = displayName
    self.definitionID = definitionID
    self.harnessIdentifier = harnessIdentifier
    self.runtimeKind = runtimeKind
  }
}

/// The device-owned allowlist entry created only after the user selects a
/// discovered candidate. Snapshots keep missing or offline agents readable.
public struct BuzzWorkspaceAgentEnrollment: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let workspaceLinkID: UUID
  public let agentID: String
  public var handleSnapshot: String
  public var displayNameSnapshot: String
  public var harnessIdentifier: String
  public var runtimeKind: AgentRuntimeKind?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    workspaceLinkID: UUID,
    agentID: String,
    handleSnapshot: String,
    displayNameSnapshot: String,
    harnessIdentifier: String,
    runtimeKind: AgentRuntimeKind?,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.workspaceLinkID = workspaceLinkID
    self.agentID = agentID
    self.handleSnapshot = handleSnapshot
    self.displayNameSnapshot = displayNameSnapshot
    self.harnessIdentifier = harnessIdentifier
    self.runtimeKind = runtimeKind
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// Device-local Buzz state. Candidate discovery remains transient.
public struct BuzzWorkspaceSnapshot: Equatable, Sendable {
  public let links: [BuzzWorkspaceLink]
  public let enrollments: [BuzzWorkspaceAgentEnrollment]

  public init(
    links: [BuzzWorkspaceLink],
    enrollments: [BuzzWorkspaceAgentEnrollment]
  ) {
    self.links = links
    self.enrollments = enrollments
  }
}

import Foundation

public enum AgentExecutionLocation: String, Codable, CaseIterable, Hashable, Sendable {
  case local
  case remote
}

/// The product plane that governs an agent. This is intentionally independent
/// from the process/runtime kind and from where the row is being viewed.
public enum AgentGoverningPlane: String, Codable, CaseIterable, Hashable, Sendable {
  case wovenmatterMacOS = "wovenmatter_macos"
  case remoteWorkspace = "remote_workspace"
}

public enum DataAuthorityKind: String, Codable, CaseIterable, Hashable, Sendable {
  case deviceOwned = "device_owned"

  public var canonical: DataAuthorityKind { self }
}

public enum AgentBucket: String, Codable, CaseIterable, Hashable, Sendable {
  case localCLIAgents = "local_cli"
  case remoteWorkspaceAgents = "remote_workspace"

  public var label: String {
    switch self {
    case .localCLIAgents: "Local workspace agents"
    case .remoteWorkspaceAgents: "Remote workspaces"
    }
  }
}

public enum AgentRuntimeKind: String, Codable, CaseIterable, Hashable, Sendable {
  case openclaw
  case pi
  case codex
  case claudeCode = "claude_code"
  case grokBuild = "grok_build"
  case hermes
  case cursor
  case opencode

  public var displayName: String {
    switch self {
    case .openclaw: "OpenClaw"
    case .pi: "Pi"
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .grokBuild: "Grok Build"
    case .hermes: "Hermes"
    case .cursor: "Cursor"
    case .opencode: "OpenCode"
    }
  }
}

public enum AgentRuntimeStatus: String, Codable, Sendable {
  case provisioning
  case stopped
  case starting
  case ready
  case running
  case needsAuthentication = "needs_authentication"
  case offline
  case failed

}

public struct WorkspaceAgent: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let userID: String
  public var codename: String
  public var displayName: String
  public var iconKey: String
  public let executionLocation: AgentExecutionLocation
  public let governingPlane: AgentGoverningPlane
  public let authorityKind: DataAuthorityKind
  public let authorityDeviceID: UUID?
  public let runtimeKind: AgentRuntimeKind
  public var runtimeDeviceID: UUID?
  public var platformCodename: String?
  public var runtimeStatus: AgentRuntimeStatus
  public var runtimeVersion: String?
  public var imageDigest: String?
  public var revision: Int64
  public let createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: UUID = UUID(),
    userID: String,
    codename: String,
    displayName: String,
    iconKey: String,
    executionLocation: AgentExecutionLocation,
    governingPlane: AgentGoverningPlane = .wovenmatterMacOS,
    authorityKind: DataAuthorityKind = .deviceOwned,
    authorityDeviceID: UUID? = nil,
    runtimeKind: AgentRuntimeKind,
    runtimeDeviceID: UUID? = nil,
    platformCodename: String? = nil,
    runtimeStatus: AgentRuntimeStatus = .provisioning,
    runtimeVersion: String? = nil,
    imageDigest: String? = nil,
    revision: Int64 = 0,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.userID = userID
    self.codename = codename
    self.displayName = displayName
    self.iconKey = iconKey
    self.executionLocation = executionLocation
    self.governingPlane = governingPlane
    self.authorityKind = authorityKind.canonical
    self.authorityDeviceID = authorityDeviceID
    self.runtimeKind = runtimeKind
    self.runtimeDeviceID = runtimeDeviceID
    self.platformCodename = platformCodename
    self.runtimeStatus = runtimeStatus
    self.runtimeVersion = runtimeVersion
    self.imageDigest = imageDigest
    self.revision = revision
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  public var bucket: AgentBucket {
    switch governingPlane {
    case .wovenmatterMacOS: .localCLIAgents
    case .remoteWorkspace: .remoteWorkspaceAgents
    }
  }

}

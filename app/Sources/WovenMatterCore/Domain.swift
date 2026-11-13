import Foundation

public enum AgentExecutionLocation: String, Codable, CaseIterable, Hashable, Sendable {
  case local
  case remote
}

/// How the sidebar groups agents: this Mac's harnesses, or a remote workspace's.
public enum AgentBucket: CaseIterable, Hashable, Sendable {
  case localCLIAgents
  case remoteWorkspaceAgents

  public var label: String {
    switch self {
    case .localCLIAgents: "Local workspace agents"
    case .remoteWorkspaceAgents: "Remote workspaces"
    }
  }
}

public enum AgentRuntimeKind: String, Codable, CaseIterable, Hashable, Sendable {
  case defaultAgent = "default_agent"
  case codex
  case claudeCode = "claude_code"
  case grokBuild = "grok_build"
  case opencode

  public static let presentationOrder: [Self] = allCases

  public var presentationRank: Int {
    Self.presentationOrder.firstIndex(of: self) ?? Self.presentationOrder.count
  }

  public var displayName: String {
    switch self {
    case .defaultAgent: "Pi Durable"
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .grokBuild: "Grok Build"
    case .opencode: "OpenCode"
    }
  }

  /// The harness's native Full access mode: the product default for every new
  /// chat on every workspace unless the user saved a different default.
  public var fullAccessPermission: String? {
    switch self {
    case .codex: "agent-full-access"
    case .claudeCode, .grokBuild: "bypassPermissions"
    case .defaultAgent: "full"
    case .opencode: "allow"
    }
  }

  /// Presentation order for native permission modes: Full access first, then
  /// the harness's auto-approve modes, then its other modes. The ask-for-approval
  /// mode stays available but is listed last. Unknown modes keep native order.
  public func orderedPermissionOptions(_ options: [String]) -> [String] {
    func rank(_ id: String) -> Int {
      if id == fullAccessPermission { return 0 }
      switch (self, id) {
      case (.codex, "agent"), (.claudeCode, "auto"), (.claudeCode, "acceptEdits"),
           (.grokBuild, "auto"), (.grokBuild, "acceptEdits"):
        return 1
      case (.codex, "workspace-write"), (.claudeCode, "default"), (.grokBuild, "default"),
           (.opencode, "ask"), (.defaultAgent, "ask"):
        return 3
      default:
        return 2
      }
    }
    return options.enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
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
  public var codename: String
  public var displayName: String
  public var iconKey: String
  public let executionLocation: AgentExecutionLocation
  /// The Mac that created the agent: the one whose harness it is.
  public let ownerDeviceID: UUID?
  public let runtimeKind: AgentRuntimeKind
  public var runtimeDeviceID: UUID?
  public var platformCodename: String?
  public var runtimeStatus: AgentRuntimeStatus
  public var revision: Int64
  public let createdAt: Date
  public var updatedAt: Date
  public var deletedAt: Date?

  public init(
    id: UUID = UUID(),
    codename: String,
    displayName: String,
    iconKey: String,
    executionLocation: AgentExecutionLocation,
    ownerDeviceID: UUID? = nil,
    runtimeKind: AgentRuntimeKind,
    runtimeDeviceID: UUID? = nil,
    platformCodename: String? = nil,
    runtimeStatus: AgentRuntimeStatus = .provisioning,
    revision: Int64 = 0,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.codename = codename
    self.displayName = displayName
    self.iconKey = iconKey
    self.executionLocation = executionLocation
    self.ownerDeviceID = ownerDeviceID
    self.runtimeKind = runtimeKind
    self.runtimeDeviceID = runtimeDeviceID
    self.platformCodename = platformCodename
    self.runtimeStatus = runtimeStatus
    self.revision = revision
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }

  public var bucket: AgentBucket {
    switch executionLocation {
    case .local: .localCLIAgents
    case .remote: .remoteWorkspaceAgents
    }
  }

}

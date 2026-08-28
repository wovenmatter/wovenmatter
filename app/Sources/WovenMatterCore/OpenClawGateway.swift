import Foundation

public enum OpenClawGatewayLocation: String, Codable, CaseIterable, Hashable, Sendable {
  case buzzLocal = "buzz_local"
  case localAgentWorkspace = "local_agent_workspace"
  case remoteWorkspace = "remote_workspace"
}

public enum OpenClawGatewayAuthorization: String, Codable, Hashable, Sendable {
  case localService
  case remoteWorkspace
}

public enum OpenClawGatewayConnectionStatus: String, Codable, CaseIterable, Sendable {
  case notConnected = "not_connected"
  case connecting
  case reconnecting
  case unlinking
  case restarting
  case ready
  case unavailable

  public var label: String {
    switch self {
    case .notConnected: "Not connected"
    case .connecting: "Connecting"
    case .reconnecting: "Reconnecting"
    case .unlinking: "Unlinking"
    case .restarting: "Restarting"
    case .ready: "Ready"
    case .unavailable: "Unavailable"
    }
  }

}

public struct OpenClawGatewayEndpoint: Codable, Equatable, Sendable {
  public let url: URL
  public let authorization: OpenClawGatewayAuthorization

  public init(url: URL, authorization: OpenClawGatewayAuthorization) {
    self.url = url
    self.authorization = authorization
  }
}

/// A device-local routing override. Its presence is authoritative: callers
/// must fail visibly when this endpoint is unavailable and must never retry
/// the same turn through ACP.
public struct OpenClawGatewayLink: Codable, Equatable, Identifiable, Sendable {
  public let agentID: UUID
  public let location: OpenClawGatewayLocation
  public var endpoint: OpenClawGatewayEndpoint
  public var status: String
  public var openClawVersion: String?
  public var lastConnectedAt: Date?
  public var lastError: String?
  public let linkedAt: Date
  public var updatedAt: Date

  public var id: UUID { agentID }
  public var connectionStatus: OpenClawGatewayConnectionStatus {
    OpenClawGatewayConnectionStatus(rawValue: status) ?? .unavailable
  }

  public init(
    agentID: UUID,
    location: OpenClawGatewayLocation,
    endpoint: OpenClawGatewayEndpoint,
    status: String = OpenClawGatewayConnectionStatus.notConnected.rawValue,
    openClawVersion: String? = nil,
    lastConnectedAt: Date? = nil,
    lastError: String? = nil,
    linkedAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.agentID = agentID
    self.location = location
    self.endpoint = endpoint
    self.status = status
    self.openClawVersion = openClawVersion
    self.lastConnectedAt = lastConnectedAt
    self.lastError = lastError
    self.linkedAt = linkedAt
    self.updatedAt = updatedAt
  }
}

public struct OpenClawGatewayCapabilities: Codable, Equatable, Sendable {
  public struct AttachmentPolicy: Codable, Equatable, Sendable {
    public let maximumBytes: Int?
    public let maximumImageBytes: Int?

    public init(maximumBytes: Int? = nil, maximumImageBytes: Int? = nil) {
      self.maximumBytes = maximumBytes
      self.maximumImageBytes = maximumImageBytes
    }
  }

  public let applicationVersion: String?
  public let methods: Set<String>
  public let events: Set<String>
  public let maximumPayloadBytes: Int?
  public let attachmentPolicy: AttachmentPolicy?
  public let connectedAt: Date

  public init(
    applicationVersion: String? = nil,
    methods: Set<String>,
    events: Set<String>,
    maximumPayloadBytes: Int? = nil,
    attachmentPolicy: AttachmentPolicy? = nil,
    connectedAt: Date = Date()
  ) {
    self.applicationVersion = applicationVersion
    self.methods = methods
    self.events = events
    self.maximumPayloadBytes = maximumPayloadBytes
    self.attachmentPolicy = attachmentPolicy
    self.connectedAt = connectedAt
  }

  public func supports(_ method: String) -> Bool { methods.contains(method) }
}

public struct OpenClawSessionPreferences: Codable, Equatable, Sendable {
  public var model: String?
  public var thinkingLevel: String?

  public init(model: String? = nil, thinkingLevel: String? = nil) {
    self.model = model
    self.thinkingLevel = thinkingLevel
  }
}

public struct OpenClawHeartbeatConfiguration: Codable, Equatable, Sendable {
  public var isEnabled: Bool
  public var interval: String
  public var activeFrom: String
  public var activeUntil: String
  public var timezone: String
  public var prompt: String

  public init(
    isEnabled: Bool = false,
    interval: String = "30m",
    activeFrom: String = "09:00",
    activeUntil: String = "17:00",
    timezone: String = TimeZone.current.identifier,
    prompt: String = ""
  ) {
    self.isEnabled = isEnabled
    self.interval = interval
    self.activeFrom = activeFrom
    self.activeUntil = activeUntil
    self.timezone = timezone
    self.prompt = prompt
  }
}

public enum OpenClawCronArchiveState: String, Codable, Sendable {
  case active
  case deleted
}

public struct OpenClawCronJob: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let agentID: UUID
  public var name: String
  public var schedule: String
  public var enabled: Bool
  public var nativeSessionID: String?
  public var nativeSessionKey: String?
  public var archiveState: OpenClawCronArchiveState
  public var remotePayload: Data
  public var updatedAt: Date

  public init(
    id: String,
    agentID: UUID,
    name: String,
    schedule: String,
    enabled: Bool,
    nativeSessionID: String? = nil,
    nativeSessionKey: String? = nil,
    archiveState: OpenClawCronArchiveState = .active,
    remotePayload: Data,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.agentID = agentID
    self.name = name
    self.schedule = schedule
    self.enabled = enabled
    self.nativeSessionID = nativeSessionID
    self.nativeSessionKey = nativeSessionKey
    self.archiveState = archiveState
    self.remotePayload = remotePayload
    self.updatedAt = updatedAt
  }
}

public struct OpenClawCronRun: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let jobID: String
  public let agentID: UUID
  public var status: String
  public var output: String?
  public var nativeSessionID: String?
  public var nativeSessionKey: String?
  public var startedAt: Date?
  public var completedAt: Date?
  public var remotePayload: Data

  public init(
    id: String,
    jobID: String,
    agentID: UUID,
    status: String,
    output: String? = nil,
    nativeSessionID: String? = nil,
    nativeSessionKey: String? = nil,
    startedAt: Date? = nil,
    completedAt: Date? = nil,
    remotePayload: Data
  ) {
    self.id = id
    self.jobID = jobID
    self.agentID = agentID
    self.status = status
    self.output = output
    self.nativeSessionID = nativeSessionID
    self.nativeSessionKey = nativeSessionKey
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.remotePayload = remotePayload
  }
}

public enum OpenClawCronOrdering {
  public static func latestExecutionFirst(
    jobs: [OpenClawCronJob],
    runs: [OpenClawCronRun]
  ) -> [OpenClawCronJob] {
    let latestByJob = Dictionary(grouping: runs, by: { "\($0.agentID.uuidString):\($0.jobID)" })
      .mapValues { values in
        values.compactMap { $0.startedAt ?? $0.completedAt }.max()
      }
    return jobs.sorted { lhs, rhs in
      let left = latestByJob["\(lhs.agentID.uuidString):\(lhs.id)"] ?? nil
      let right = latestByJob["\(rhs.agentID.uuidString):\(rhs.id)"] ?? nil
      if left != right { return (left ?? .distantPast) > (right ?? .distantPast) }
      if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
      return lhs.id < rhs.id
    }
  }
}

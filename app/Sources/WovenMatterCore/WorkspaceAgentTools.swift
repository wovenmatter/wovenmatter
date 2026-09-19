import Foundation

public enum WorkspaceToolGroup: String, CaseIterable, Codable, Identifiable, Sendable {
  case notes, history, sessions, timers, usage, calendar, library
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .notes: "Notes"
    case .history: "Conversation history"
    case .sessions: "Session management"
    case .timers: "Timers"
    case .usage: "Usage data"
    case .calendar: "Calendar"
    case .library: "Library"
    }
  }
}

public enum WorkspaceCalendarAccess: String, CaseIterable, Codable, Sendable {
  case readOnly, full
  public var title: String { self == .full ? "Full access" : "Read only" }
}

public struct WorkspaceToolSettings: Codable, Equatable, Sendable {
  public var enabledByDefault: Set<WorkspaceToolGroup>
  public var calendarAccess: WorkspaceCalendarAccess
  public var maximumManagedSessions: Int
  public var maximumRunningSessions: Int

  public init(enabledByDefault: Set<WorkspaceToolGroup> = Set(WorkspaceToolGroup.allCases),
              calendarAccess: WorkspaceCalendarAccess = .full,
              maximumManagedSessions: Int = 4, maximumRunningSessions: Int = 16) {
    self.enabledByDefault = enabledByDefault
    self.calendarAccess = calendarAccess
    self.maximumManagedSessions = maximumManagedSessions
    self.maximumRunningSessions = maximumRunningSessions
  }

  public func validate() throws {
    guard (1...16).contains(maximumManagedSessions), (1...48).contains(maximumRunningSessions) else {
      throw WorkspaceToolError.invalid("Session limits must be within their allowed ranges.")
    }
  }
}

public struct WorkspaceSessionTools: Codable, Equatable, Sendable {
  public var enabled: Set<WorkspaceToolGroup>
  public init(enabled: Set<WorkspaceToolGroup> = Set(WorkspaceToolGroup.allCases)) {
    self.enabled = enabled
  }
}

public struct WorkspaceSessionRelationship: Codable, Equatable, Sendable {
  public var sessionID: String
  public var createdBy: String?
  public var coordinatorID: String?
  public var purpose: String?
  public var notificationsEnabled: Bool
  public init(sessionID: String, createdBy: String? = nil, coordinatorID: String? = nil,
              purpose: String? = nil, notificationsEnabled: Bool = true) {
    self.sessionID = sessionID
    self.createdBy = createdBy
    self.coordinatorID = coordinatorID
    self.purpose = purpose
    self.notificationsEnabled = notificationsEnabled
  }
}

public struct WorkspaceSessionTimer: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var sessionID: String
  public var instruction: String
  public var nextFireAt: Date
  public var intervalSeconds: TimeInterval?
  public var isPaused: Bool
  public var pendingDeliveryID: String?

  public init(id: String = UUID().uuidString.lowercased(), sessionID: String, instruction: String,
              nextFireAt: Date, intervalSeconds: TimeInterval? = nil, isPaused: Bool = false,
              pendingDeliveryID: String? = nil) {
    self.id = id
    self.sessionID = sessionID
    self.instruction = instruction
    self.nextFireAt = nextFireAt
    self.intervalSeconds = intervalSeconds
    self.isPaused = isPaused
    self.pendingDeliveryID = pendingDeliveryID
  }

  public func validate() throws {
    guard UUID(uuidString: id) != nil, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          instruction.utf8.count <= 65_536, nextFireAt.timeIntervalSince1970.isFinite,
          intervalSeconds.map({ $0.isFinite && $0 >= 1 && $0 <= 365 * 86_400 }) ?? true else {
      throw WorkspaceToolError.invalid("A timer needs an instruction, a valid date and a positive interval.")
    }
  }
}

public enum WorkspaceToolError: Error, LocalizedError, Equatable, Sendable {
  case disabled(WorkspaceToolGroup)
  case accessRequired(String)
  case coordinationConflict(String)
  case managedLimit(Int)
  case timerPauseConfirmation
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .disabled(let group): "\(group.title) is disabled for this session."
    case .accessRequired(let id): "Attach session \(id) or approve access in Woven Matter."
    case .coordinationConflict(let id): "This session is already coordinated by session \(id)."
    case .managedLimit(let limit): "This coordinator already manages the maximum of \(limit) sessions."
    case .timerPauseConfirmation: "Disabling timers will pause this session’s active timers."
    case .invalid(let message): message
    }
  }
}

public enum WorkspaceSessionDeliveryKind: String, Codable, Sendable {
  case message, created, timer, notification
}

public struct WorkspaceSessionDelivery: Codable, Identifiable, Sendable {
  public let id: String
  public let sourceID: String
  public let targetID: String
  public let text: String
  public let kind: WorkspaceSessionDeliveryKind
  public let status: String
  public let messageID: String?
  public let sourceTitle: String
  public let sourceHarness: String
  public let targetTitle: String
  public let targetHarness: String
  public let targetModel: String?
  public let purpose: String?
  public let createdAt: String
  public init(id: String, sourceID: String, targetID: String, text: String,
              kind: WorkspaceSessionDeliveryKind, status: String, messageID: String?,
              sourceTitle: String, sourceHarness: String, targetTitle: String, targetHarness: String,
              targetModel: String?, purpose: String?, createdAt: String) {
    self.id = id; self.sourceID = sourceID; self.targetID = targetID; self.text = text
    self.kind = kind; self.status = status; self.messageID = messageID
    self.sourceTitle = sourceTitle; self.sourceHarness = sourceHarness
    self.targetTitle = targetTitle; self.targetHarness = targetHarness
    self.targetModel = targetModel; self.purpose = purpose; self.createdAt = createdAt
  }
}

/// Main-actor owners hold a reservation across asynchronous launch preparation.
/// Running sessions and reservations are a union, never two counts of one session.
public struct WorkspaceSessionAdmission: Sendable {
  public enum Decision: Equatable, Sendable { case start, steer, atCapacity, preparing }
  private var preparing: Set<String> = []
  public init() {}
  public mutating func begin(_ id: String, running: Set<String>, limit: Int) -> Decision {
    guard !preparing.contains(id) else { return .preparing }
    if running.contains(id) { preparing.insert(id); return .steer }
    guard running.union(preparing).count < limit else { return .atCapacity }
    preparing.insert(id)
    return .start
  }
  public mutating func finish(_ id: String) { preparing.remove(id) }
}

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

/// Resolved once before creating a session. Retrying a request must not inherit
/// different choices merely because its source or General defaults changed.
public struct WorkspaceSessionCreationConfiguration: Codable, Equatable, Sendable {
  public var runtimeKind: AgentRuntimeKind
  public var workspaceID: UUID?
  public var folderID: String?
  public var title: String
  public var model: String?
  public var thinking: String?
  public var nativeWorkingDirectory: String?
  public var tools: WorkspaceSessionTools

  public init(runtimeKind: AgentRuntimeKind, workspaceID: UUID? = nil, folderID: String? = nil,
              title: String, model: String? = nil, thinking: String? = nil,
              nativeWorkingDirectory: String? = nil, tools: WorkspaceSessionTools = .init()) {
    self.runtimeKind = runtimeKind; self.workspaceID = workspaceID; self.folderID = folderID
    self.title = title; self.model = model; self.thinking = thinking
    self.nativeWorkingDirectory = nativeWorkingDirectory; self.tools = tools
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

/// A management intent is independent of its short-lived CLI connection.
/// Only the app's user controls may resolve a pending access request.
public struct WorkspaceCoordinationAccessRequest: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let sourceID: String
  public let targetID: String
  public let sourceTitle: String
  public let targetTitle: String
  public let purpose: String
  public let notifications: Bool
  public let state: String
  public let error: String?
  public init(id: String, sourceID: String, targetID: String, sourceTitle: String, targetTitle: String,
              purpose: String, notifications: Bool, state: String, error: String?) {
    self.id = id; self.sourceID = sourceID; self.targetID = targetID
    self.sourceTitle = sourceTitle; self.targetTitle = targetTitle; self.purpose = purpose
    self.notifications = notifications; self.state = state; self.error = error
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

/// The native editor keeps the exact persisted cadence while unrelated fields
/// change, including fractional and sub-minute intervals created by the CLI.
public struct WorkspaceSessionTimerDraft: Sendable {
  private let original: WorkspaceSessionTimer
  public var instruction: String
  public var nextFireAt: Date
  public var repeats: Bool
  public var intervalSeconds: TimeInterval

  public init(_ timer: WorkspaceSessionTimer) {
    original = timer
    instruction = timer.instruction
    nextFireAt = timer.nextFireAt
    repeats = timer.intervalSeconds != nil
    intervalSeconds = timer.intervalSeconds ?? 3_600
  }

  public func timer() throws -> WorkspaceSessionTimer {
    var value = original
    value.instruction = instruction
    value.nextFireAt = nextFireAt
    value.intervalSeconds = repeats ? intervalSeconds : nil
    try value.validate()
    return value
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
  public let sequence: Int64?
  public init(id: String, sourceID: String, targetID: String, text: String,
              kind: WorkspaceSessionDeliveryKind, status: String, messageID: String?,
              sourceTitle: String, sourceHarness: String, targetTitle: String, targetHarness: String,
              targetModel: String?, purpose: String?, createdAt: String, sequence: Int64? = nil) {
    self.id = id; self.sourceID = sourceID; self.targetID = targetID; self.text = text
    self.kind = kind; self.status = status; self.messageID = messageID
    self.sourceTitle = sourceTitle; self.sourceHarness = sourceHarness
    self.targetTitle = targetTitle; self.targetHarness = targetHarness
    self.targetModel = targetModel; self.purpose = purpose; self.createdAt = createdAt; self.sequence = sequence
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

public enum WorkspaceConversationTimelineItem: Identifiable, Sendable {
  case message(WorkspaceMessageRecord)
  case receipt(WorkspaceSessionDelivery)
  public var id: String {
    switch self {
    case .message(let value): value.id
    case .receipt(let value): "tool-receipt:" + value.id
    }
  }

  /// Preserve native message sequence; interleave outgoing actions by their
  /// persisted time instead of moving them to a separate conversation grouping.
  public static func weave(messages: [WorkspaceMessageRecord], receipts: [WorkspaceSessionDelivery], sessionID: String) -> [Self] {
    let outgoing = receipts.filter { $0.sourceID == sessionID && [.message, .created].contains($0.kind) }
      .sorted {
        if let left = $0.sequence, let right = $1.sequence { return left < right }
        return $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
      }
    var index = 0
    var items: [Self] = []
    for message in messages {
      while index < outgoing.count, outgoing[index].createdAt < message.createdAt {
        items.append(.receipt(outgoing[index])); index += 1
      }
      items.append(.message(message))
    }
    items += outgoing.dropFirst(index).map(Self.receipt)
    return items
  }
}

import Foundation

// The scheduler: scheduled tasks, calendar events, timers and wake-ups are
// all entries of one kind. An entry belongs to the machine whose server runs
// it, and only that server writes it; a request about another machine's
// entry is refused with `notOwner`, naming the owner, so the caller can send
// it there.

/// What a scheduler entry does when its time comes.
public enum ScheduleKind: String, Codable, Sendable, Hashable {
  /// Runs a prompt in a session of a chosen runtime and folder.
  case task
  /// A calendar event. It does not fire.
  case event
  /// Prompts the session that set it again after a delay.
  case timer
  /// Wakes the session that set it at a time, with a message.
  case wakeUp
}

/// How an entry repeats, counted from its first time in its time zone: a
/// 9am daily entry stays at 9am across daylight-saving changes, and Jan 31
/// monthly goes to Feb 28 then Mar 31.
public struct Recurrence: Codable, Sendable, Hashable {
  public enum Unit: String, Codable, Sendable, Hashable, CaseIterable {
    case minute, hour, day, week, month
  }

  public var unit: Unit
  public var interval: Int

  public init(unit: Unit, interval: Int = 1) {
    self.unit = unit
    self.interval = interval
  }
}

/// What a person or an agent sets on an entry.
public struct ScheduleDraft: Codable, Sendable, Hashable {
  /// The machine that runs it.
  public var machineID: String
  public var kind: ScheduleKind
  public var title: String
  public var details: String
  /// A task's prompt, a timer's instruction, a wake-up's message.
  public var prompt: String
  /// The session a timer or wake-up prompts. For a task, the session its
  /// runs go to; when nil, the first run starts one and later runs use it.
  public var sessionID: String?
  /// A task starts a new session for every run.
  public var newSessionEachRun: Bool
  /// A task's runtime, folder, working directory and choices. Nil choices
  /// are the runtime's defaults on that machine.
  public var runtime: RuntimeKind?
  public var folderID: String?
  public var directory: String?
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var startsAt: Date
  public var endsAt: Date?
  public var allDay: Bool
  /// The time zone its times repeat in.
  public var timeZone: String
  public var recurrence: Recurrence?
  /// Occurrences of a series that were deleted or detached, by index from 0.
  public var excluded: [Int]
  /// A task also shows on the calendar.
  public var showsOnCalendar: Bool
  public var enabled: Bool

  public init(machineID: String, kind: ScheduleKind, title: String, details: String = "", prompt: String = "",
              sessionID: String? = nil, newSessionEachRun: Bool = false, runtime: RuntimeKind? = nil,
              folderID: String? = nil, directory: String? = nil, model: String? = nil, thinking: String? = nil,
              permission: String? = nil, startsAt: Date, endsAt: Date? = nil, allDay: Bool = false,
              timeZone: String = TimeZone.current.identifier, recurrence: Recurrence? = nil, excluded: [Int] = [],
              showsOnCalendar: Bool = true, enabled: Bool = true) {
    self.machineID = machineID
    self.kind = kind
    self.title = title
    self.details = details
    self.prompt = prompt
    self.sessionID = sessionID
    self.newSessionEachRun = newSessionEachRun
    self.runtime = runtime
    self.folderID = folderID
    self.directory = directory
    self.model = model
    self.thinking = thinking
    self.permission = permission
    self.startsAt = startsAt
    self.endsAt = endsAt
    self.allDay = allDay
    self.timeZone = timeZone
    self.recurrence = recurrence
    self.excluded = excluded
    self.showsOnCalendar = showsOnCalendar
    self.enabled = enabled
  }
}

/// What the owning machine has fired of an entry. Only the owner knows it.
public struct ScheduleState: Codable, Sendable, Hashable {
  /// When it fires next; nil when it never will again.
  public var nextFireAt: Date?
  /// The occurrence it last fired, by its scheduled time.
  public var lastFiredAt: Date?
  /// The session its last run went to.
  public var lastSessionID: String?
  /// Why its last run failed.
  public var lastError: String?

  public init(nextFireAt: Date? = nil, lastFiredAt: Date? = nil, lastSessionID: String? = nil, lastError: String? = nil) {
    self.nextFireAt = nextFireAt
    self.lastFiredAt = lastFiredAt
    self.lastSessionID = lastSessionID
    self.lastError = lastError
  }
}

/// One entry of a machine's scheduler.
public struct ScheduleEntry: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var draft: ScheduleDraft
  /// The session that created it, or nil for the person.
  public var createdBy: String?
  public var createdAt: Date
  /// The session that last changed it, or nil for the person.
  public var editedBy: String?
  public var editedAt: Date?
  /// Filled in by the owner's server only.
  public var state: ScheduleState?

  public init(id: String, draft: ScheduleDraft, createdBy: String?, createdAt: Date, editedBy: String? = nil,
              editedAt: Date? = nil, state: ScheduleState? = nil) {
    self.id = id
    self.draft = draft
    self.createdBy = createdBy
    self.createdAt = createdAt
    self.editedBy = editedBy
    self.editedAt = editedAt
    self.state = state
  }

  public var machineID: String { draft.machineID }
  public var kind: ScheduleKind { draft.kind }
}

extension ScheduleDraft {
  /// The time of occurrence `index`, counted from 0, ignoring exclusions.
  public func occurrence(_ index: Int) -> Date? {
    guard index >= 0 else { return nil }
    guard let recurrence else { return index == 0 ? startsAt : nil }
    guard recurrence.interval >= 1, let zone = TimeZone(identifier: timeZone) else { return nil }
    let (offset, overflow) = index.multipliedReportingOverflow(by: recurrence.interval)
    guard !overflow, offset < Int(Int32.max) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let component: Calendar.Component = switch recurrence.unit {
    case .minute: .minute
    case .hour: .hour
    case .day: .day
    case .week: .weekOfYear
    case .month: .month
    }
    return calendar.date(byAdding: component, value: offset, to: startsAt)
  }

  /// The index of the last occurrence at or before `date`, ignoring exclusions.
  public func occurrenceIndex(onOrBefore date: Date) -> Int? {
    guard date >= startsAt else { return nil }
    guard recurrence != nil else { return 0 }
    var lower = 0, upper = 1
    while let next = occurrence(upper), next <= date {
      lower = upper
      guard upper <= Int.max / 2 else { return nil }
      upper *= 2
    }
    while upper - lower > 1 {
      let middle = lower + (upper - lower) / 2
      if let next = occurrence(middle), next <= date { lower = middle } else { upper = middle }
    }
    return lower
  }

  /// The first occurrence strictly after `date` that is not excluded.
  public func firstOccurrence(after date: Date) -> Date? {
    var index = occurrenceIndex(onOrBefore: date).map { $0 + 1 } ?? 0
    while excluded.contains(index) { index += 1 }
    return occurrence(index)
  }
}

// MARK: Requests

/// Every machine's entries, as this server's library holds them. Entries
/// this machine owns carry their `state`.
public struct ListSchedules: Request {
  public static let method = "schedules.list"
  public typealias Reply = [ScheduleEntry]
  public init() {}
}

/// Creates an entry (`id` nil) or replaces one's fields, on the machine that
/// owns it. An entry cannot move to another machine: delete it and create it
/// there.
public struct SaveSchedule: Request {
  public static let method = "schedules.save"
  public typealias Reply = ScheduleEntry
  public var id: String?
  public var draft: ScheduleDraft
  public init(id: String? = nil, draft: ScheduleDraft) {
    self.id = id
    self.draft = draft
  }
}

/// Deletes an entry, or with `occurrence` only that occurrence of a series,
/// on the machine that owns it.
public struct DeleteSchedule: Request {
  public static let method = "schedules.delete"
  public typealias Reply = Done
  public var id: String
  public var occurrence: Int?
  public init(id: String, occurrence: Int? = nil) {
    self.id = id
    self.occurrence = occurrence
  }
}

/// Sets or clears a session's goal, on the machine that owns the session.
/// A goal set while the session is idle starts a turn toward it.
public struct SetGoal: Request {
  public static let method = "sessions.goal"
  public typealias Reply = Session
  public var sessionID: String
  public var goal: String?
  public init(sessionID: String, goal: String?) {
    self.sessionID = sessionID
    self.goal = goal
  }
}

/// What sent a message that the server sent on the session's behalf.
public enum ItemSource: String, Codable, Sendable, Hashable {
  case goal, timer, wakeUp, scheduledTask
}

extension Notice.Kind {
  /// The agent said the session's goal is met.
  public static let goalMet = Notice.Kind(rawValue: "goalMet")
}

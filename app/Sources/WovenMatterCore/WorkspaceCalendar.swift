import Foundation

public struct WorkspaceCalendarRecurrence: Codable, Equatable, Sendable {
  public enum Unit: String, Codable, CaseIterable, Sendable {
    case day, week, month
    public var title: String { rawValue.capitalized + "s" }
    var component: Calendar.Component {
      switch self { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }
  }
  public var unit: Unit
  public var interval: Int
  public init(unit: Unit, interval: Int = 1) { self.unit = unit; self.interval = interval }
  public var label: String {
    if interval == 1 {
      switch unit { case .day: return "Daily"; case .week: return "Weekly"; case .month: return "Monthly" }
    }
    return "Every \(interval) \(unit.rawValue)s"
  }
}

public struct WorkspaceCalendarTask: Codable, Equatable, Sendable {
  public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case same, new
    public var title: String { self == .same ? "Same session" : "New session each time" }
  }
  public var prompt: String
  public var configuration: WorkspaceSessionCreationConfiguration
  public var sessionMode: SessionMode
  public init(prompt: String, configuration: WorkspaceSessionCreationConfiguration, sessionMode: SessionMode = .same) {
    self.prompt = prompt; self.configuration = configuration; self.sessionMode = sessionMode
  }
}

/// Attribution is snapshotted, so renaming or deleting a source session does not
/// erase who created or last edited an event.
public struct WorkspaceCalendarAuthor: Codable, Equatable, Sendable {
  public var sessionID: String?
  public var agent: String?
  public var sessionTitle: String?
  public init(sessionID: String? = nil, agent: String? = nil, sessionTitle: String? = nil) {
    self.sessionID = sessionID; self.agent = agent; self.sessionTitle = sessionTitle
  }
  public var label: String {
    guard sessionID != nil else { return "You" }
    let name = agent.flatMap(AgentRuntimeKind.init(rawValue:))?.displayName ?? agent ?? "Agent"
    return sessionTitle.map { "\(name) · \($0)" } ?? name
  }
}

public struct WorkspaceCalendarDetails: Codable, Equatable, Sendable {
  public var timeZoneID: String
  public var recurrence: WorkspaceCalendarRecurrence?
  public var task: WorkspaceCalendarTask?
  public var excludedOccurrences: Set<Int>
  public var createdBy: WorkspaceCalendarAuthor
  public var editedBy: WorkspaceCalendarAuthor?
  public var revision: Int
  public init(timeZoneID: String = TimeZone.current.identifier,
              recurrence: WorkspaceCalendarRecurrence? = nil, task: WorkspaceCalendarTask? = nil,
              excludedOccurrences: Set<Int> = [], createdBy: WorkspaceCalendarAuthor = .init(),
              editedBy: WorkspaceCalendarAuthor? = nil, revision: Int = 0) {
    self.timeZoneID = timeZoneID; self.recurrence = recurrence; self.task = task
    self.excludedOccurrences = excludedOccurrences; self.createdBy = createdBy
    self.editedBy = editedBy; self.revision = revision
  }
}

public struct WorkspaceCalendarDraft: Codable, Equatable, Sendable {
  public var title: String
  public var details: String
  public var startsAt: Date
  public var endsAt: Date?
  public var allDay: Bool
  public var timeZoneID: String
  public var recurrence: WorkspaceCalendarRecurrence?
  public var task: WorkspaceCalendarTask?

  public init(title: String = "", details: String = "", startsAt: Date, endsAt: Date? = nil,
              allDay: Bool = false, timeZoneID: String = TimeZone.current.identifier,
              recurrence: WorkspaceCalendarRecurrence? = nil, task: WorkspaceCalendarTask? = nil) {
    self.title = title; self.details = details; self.startsAt = startsAt; self.endsAt = endsAt
    self.allDay = allDay; self.timeZoneID = timeZoneID; self.recurrence = recurrence; self.task = task
  }

  public init(_ item: WorkspaceCalendarItemRecord) {
    self.init(title: item.title, details: item.details ?? "", startsAt: item.startDate ?? Date(),
      endsAt: item.endDate, allDay: item.allDay, timeZoneID: item.calendar.timeZoneID,
      recurrence: item.calendar.recurrence, task: item.calendar.task)
  }

  public func validated() throws -> Self {
    var value = self
    value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    value.details = details.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.title.isEmpty, value.title.utf8.count <= 4_096, details.utf8.count <= 65_536,
          startsAt.timeIntervalSince1970.isFinite,
          endsAt.map({ $0.timeIntervalSince1970.isFinite && $0 > startsAt }) ?? true,
          let zone = TimeZone(identifier: timeZoneID) else {
      throw WorkspaceToolError.invalid("Enter a title, a valid time zone, and an end after the start.")
    }
    if let recurrence, !(1...365).contains(recurrence.interval) {
      throw WorkspaceToolError.invalid("Repeat intervals must be between 1 and 365.")
    }
    if allDay {
      guard task == nil else { throw WorkspaceToolError.invalid("Choose a time for a scheduled task.") }
      var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
      value.startsAt = calendar.startOfDay(for: startsAt)
      let end = calendar.startOfDay(for: endsAt ?? startsAt)
      value.endsAt = end > value.startsAt ? end : calendar.date(byAdding: .day, value: 1, to: value.startsAt)
    }
    if var task {
      task.prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !task.prompt.isEmpty, task.prompt.utf8.count <= 65_536,
            task.configuration.nativeWorkingDirectory.map({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4_096 }) ?? true else {
        throw WorkspaceToolError.invalid("A scheduled task needs a prompt and an absolute working directory.")
      }
      task.configuration.title = value.title
      value.task = task
    }
    return value
  }

  /// Copying an occurrence always creates a new, independent event.
  public func copied(to day: Date, calendar: Calendar = .autoupdatingCurrent) -> Self {
    var value = self
    var copyCalendar = calendar
    var destination = day
    if allDay {
      copyCalendar.timeZone = TimeZone(identifier: timeZoneID) ?? calendar.timeZone
      destination = copyCalendar.date(from: calendar.dateComponents([.year, .month, .day], from: day)) ?? day
    }
    let days = copyCalendar.dateComponents([.day], from: copyCalendar.startOfDay(for: startsAt), to: copyCalendar.startOfDay(for: destination)).day ?? 0
    value.startsAt = copyCalendar.date(byAdding: .day, value: days, to: startsAt) ?? startsAt
    value.endsAt = endsAt.flatMap { copyCalendar.date(byAdding: .day, value: days, to: $0) }
    value.recurrence = nil
    return value
  }
}

public struct WorkspaceCalendarOccurrence: Identifiable, Equatable, Sendable {
  public let event: WorkspaceCalendarItemRecord
  public let index: Int
  public let startsAt: Date
  public let endsAt: Date?
  public init(event: WorkspaceCalendarItemRecord, index: Int, startsAt: Date, endsAt: Date?) {
    self.event = event; self.index = index; self.startsAt = startsAt; self.endsAt = endsAt
  }
  public var id: String { event.id + ":" + WorkspaceCalendarSchedule.timestamp(startsAt) }
  /// All-day entries retain their calendar dates when the viewer travels.
  /// Timed events keep their absolute instant and display in the viewer's zone.
  public func displayInterval(in calendar: Calendar) -> DateInterval {
    func displayDate(_ date: Date) -> Date {
      guard event.allDay else { return date }
      var source = Calendar(identifier: .gregorian)
      source.timeZone = TimeZone(identifier: event.calendar.timeZoneID) ?? .current
      return calendar.date(from: source.dateComponents([.year, .month, .day], from: date)) ?? date
    }
    let start = displayDate(startsAt)
    return .init(start: start, end: max(start.addingTimeInterval(1), endsAt.map(displayDate) ?? start.addingTimeInterval(1)))
  }
  public var draft: WorkspaceCalendarDraft {
    var result = WorkspaceCalendarDraft(event)
    result.startsAt = startsAt; result.endsAt = endsAt
    return result
  }
}

public struct WorkspaceCalendarRun: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var eventID: String
  public var occurrenceIndex: Int
  public var scheduledAt: Date
  public var sessionID: String
  public var task: WorkspaceCalendarTask
  public var status: String
  public var error: String?
  public var prepared: Bool
  public var title: String
  public var isPending: Bool { ["pending", "queued", "sending"].contains(status) }
  public init(id: String, eventID: String, occurrenceIndex: Int, scheduledAt: Date,
              sessionID: String, task: WorkspaceCalendarTask, status: String = "pending",
              error: String? = nil, prepared: Bool = false, title: String) {
    self.id = id; self.eventID = eventID; self.occurrenceIndex = occurrenceIndex; self.scheduledAt = scheduledAt
    self.sessionID = sessionID; self.task = task; self.status = status; self.error = error
    self.prepared = prepared; self.title = title
  }
  public var statusLabel: String {
    switch status {
    case "pending", "queued": error == nil ? "Waiting to run" : "Waiting to retry"
    case "sending": "Starting session"
    case "accepted": "Prompt sent"
    case "uncertain": "Check session before retrying"
    case "cancelled": "Cancelled"
    default: "Could not run"
    }
  }
}

/// Calendar arithmetic is anchored to the first date. Jan 31 -> Feb 28 -> Mar 31,
/// and a 9am daily task remains at 9am across daylight-saving transitions.
public enum WorkspaceCalendarSchedule {
  public static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  public static func date(index: Int, start: Date, recurrence: WorkspaceCalendarRecurrence?, timeZoneID: String) -> Date? {
    guard index >= 0 else { return nil }
    guard let recurrence else { return index == 0 ? start : nil }
    guard (1...365).contains(recurrence.interval), let zone = TimeZone(identifier: timeZoneID) else { return nil }
    let (offset, overflow) = index.multipliedReportingOverflow(by: recurrence.interval)
    guard !overflow else { return nil }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    return calendar.date(byAdding: recurrence.unit.component, value: offset, to: start)
  }

  public static func index(onOrBefore date: Date, start: Date, recurrence: WorkspaceCalendarRecurrence?, timeZoneID: String) -> Int? {
    guard date >= start else { return nil }
    guard recurrence != nil else { return 0 }
    var lower = 0, upper = 1
    while let next = self.date(index: upper, start: start, recurrence: recurrence, timeZoneID: timeZoneID), next <= date {
      lower = upper
      guard upper <= Int.max / 2 else { return nil }
      upper *= 2
    }
    while upper - lower > 1 {
      let middle = lower + (upper - lower) / 2
      if let next = self.date(index: middle, start: start, recurrence: recurrence, timeZoneID: timeZoneID), next <= date { lower = middle }
      else { upper = middle }
    }
    return lower
  }

  public static func occurrence(_ event: WorkspaceCalendarItemRecord, index: Int) -> WorkspaceCalendarOccurrence? {
    guard let start = event.startDate, !event.calendar.excludedOccurrences.contains(index),
          let date = date(index: index, start: start, recurrence: event.calendar.recurrence, timeZoneID: event.calendar.timeZoneID) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: event.calendar.timeZoneID) ?? .current
    let end = event.endDate.flatMap { end in
      calendar.date(byAdding: calendar.dateComponents([.day, .hour, .minute, .second], from: start, to: end), to: date)
    }
    return .init(event: event, index: index, startsAt: date, endsAt: end)
  }

  public static func occurrences(_ event: WorkspaceCalendarItemRecord, in range: DateInterval) -> [WorkspaceCalendarOccurrence] {
    guard let start = event.startDate, range.end >= start else { return [] }
    // Include events that started before the visible range but still overlap it.
    let duration = max(0, (event.endDate ?? start).timeIntervalSince(start)) + 86_400
    var index = self.index(onOrBefore: range.start.addingTimeInterval(-duration), start: start,
      recurrence: event.calendar.recurrence, timeZoneID: event.calendar.timeZoneID) ?? 0
    var result: [WorkspaceCalendarOccurrence] = []
    while let date = date(index: index, start: start, recurrence: event.calendar.recurrence, timeZoneID: event.calendar.timeZoneID), date < range.end {
      if let value = occurrence(event, index: index),
         (value.endsAt ?? value.startsAt.addingTimeInterval(1)) > range.start { result.append(value) }
      index += 1
    }
    return result
  }

  public static func next(_ event: WorkspaceCalendarItemRecord, after date: Date) -> Date? {
    guard let start = event.startDate else { return nil }
    var index = self.index(onOrBefore: date, start: start, recurrence: event.calendar.recurrence, timeZoneID: event.calendar.timeZoneID).map { $0 + 1 } ?? 0
    while event.calendar.excludedOccurrences.contains(index) { index += 1 }
    return self.date(index: index, start: start, recurrence: event.calendar.recurrence, timeZoneID: event.calendar.timeZoneID)
  }
}

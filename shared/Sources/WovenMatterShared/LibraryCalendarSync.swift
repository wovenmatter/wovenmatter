import Foundation

/// A series is synchronized, rather than the occurrences visible in one month.
/// Tombstones and exclusions remain available to replicas that reconnect later.
public struct LibraryCalendarRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String { event.id }
  public var event: LibraryCalendarEvent
  public var excludedOccurrences: Set<Int>
  public var ownerDeviceID: String?
  public var deleted: Bool
  public init(event: LibraryCalendarEvent, excludedOccurrences: Set<Int> = [], ownerDeviceID: String? = nil, deleted: Bool = false) {
    self.event = event; self.excludedOccurrences = excludedOccurrences; self.ownerDeviceID = ownerDeviceID; self.deleted = deleted
  }
}
public struct LibraryCalendarSnapshot: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var records: [LibraryCalendarRecord]
  public var runs: [LibraryCalendarRun]?
  public init(workspaceID: String, records: [LibraryCalendarRecord], runs: [LibraryCalendarRun]? = nil) { self.workspaceID = workspaceID; self.records = records; self.runs = runs }
}
public struct LibraryCalendarMutation: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var deviceID: String
  public var expectedRevision: Int?
  public var record: LibraryCalendarRecord
  public init(id: String = UUID().uuidString.lowercased(), deviceID: String, expectedRevision: Int?, record: LibraryCalendarRecord) {
    self.id = id; self.deviceID = deviceID; self.expectedRevision = expectedRevision; self.record = record
  }
}
public struct LibraryCalendarReceipt: Codable, Equatable, Sendable {
  public enum Status: String, Codable, Sendable { case accepted, conflict }
  public var mutationID: String
  public var status: Status
  public var record: LibraryCalendarRecord?
  public init(mutationID: String, status: Status, record: LibraryCalendarRecord?) {
    self.mutationID = mutationID; self.status = status; self.record = record
  }
}

/// Same anchored Gregorian arithmetic as desktop: Jan 31 -> Feb 28 -> Mar 31,
/// and local wall-clock times remain stable across daylight-saving transitions.
public enum LibraryCalendarSchedule {
  public static func date(_ draft: LibraryCalendarDraft, index: Int) -> Date? {
    guard index >= 0 else { return nil }
    guard let unit = draft.recurrenceUnit else { return index == 0 ? draft.startsAt : nil }
    guard (1...365).contains(draft.recurrenceInterval), let zone = TimeZone(identifier: draft.timeZoneID) else { return nil }
    let (offset, overflow) = index.multipliedReportingOverflow(by: draft.recurrenceInterval)
    guard !overflow else { return nil }
    let component: Calendar.Component
    switch unit { case "day": component = .day; case "week": component = .weekOfYear; case "month": component = .month; default: return nil }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    return calendar.date(byAdding: component, value: offset, to: draft.startsAt)
  }
  public static func index(_ draft: LibraryCalendarDraft, onOrBefore date: Date) -> Int? {
    guard date >= draft.startsAt else { return nil }
    guard draft.recurrenceUnit != nil else { return 0 }
    var lower = 0, upper = 1
    while let next = self.date(draft, index: upper), next <= date {
      lower = upper; guard upper <= Int.max / 2 else { return nil }; upper *= 2
    }
    while upper - lower > 1 {
      let middle = lower + (upper - lower) / 2
      if let next = self.date(draft, index: middle), next <= date { lower = middle } else { upper = middle }
    }
    return lower
  }
  public static func occurrence(_ record: LibraryCalendarRecord, index: Int) -> LibraryCalendarEvent? {
    guard !record.deleted, !record.excludedOccurrences.contains(index), let date = date(record.event.draft, index: index) else { return nil }
    var event = record.event; event.occurrence = index; event.startsAt = date
    return event
  }
  public static func normalized(_ draft: LibraryCalendarDraft) throws -> LibraryCalendarDraft {
    try validate(draft)
    var result = draft; result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
    result.details = result.details.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.task == nil { result.showsOnCalendar = true }
    else if var task = result.task { task.prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines); result.task = task }
    if result.allDay {
      var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: result.timeZoneID)!
      result.startsAt = calendar.startOfDay(for: result.startsAt)
      let end = calendar.startOfDay(for: result.endsAt ?? result.startsAt)
      result.endsAt = end > result.startsAt ? end : calendar.date(byAdding: .day, value: 1, to: result.startsAt)
    }
    return result
  }
  public static func validate(_ draft: LibraryCalendarDraft) throws {
    guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.title.utf8.count <= 4_096,
      draft.details.utf8.count <= 65_536, draft.startsAt.timeIntervalSince1970.isFinite,
      draft.endsAt.map({ $0.timeIntervalSince1970.isFinite && $0 > draft.startsAt }) ?? true,
      TimeZone(identifier: draft.timeZoneID) != nil, !draft.allDay || draft.task == nil,
      draft.recurrenceUnit == nil || ["day", "week", "month"].contains(draft.recurrenceUnit!),
      (1...365).contains(draft.recurrenceInterval),
      draft.task.map({ !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.prompt.utf8.count <= 65_536 }) ?? true
    else { throw LibraryCalendarError.invalid }
  }
}
public enum LibraryCalendarError: Error, LocalizedError {
  case invalid, conflict, missing, requestMismatch, wrongWorkspace, invalidReceipt
  public var errorDescription: String? {
    switch self {
    case .invalid: "The calendar event has invalid dates, recurrence, title, or task settings."
    case .conflict: "This calendar event changed. Reopen it or resolve its saved conflict before editing."
    case .missing: "The calendar event is no longer available."
    case .requestMismatch: "This calendar request ID was already used for a different operation."
    case .wrongWorkspace: "This calendar belongs to another central library. Local changes have been kept."
    case .invalidReceipt: "The server returned an invalid calendar acknowledgement. Local changes have been kept."
    }
  }
}

public struct LibraryCalendarRun: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var eventID: String
  public var eventRevision: Int
  public var ownerDeviceID: String
  public var occurrence: Int
  public var scheduledAt: Date
  public var sessionID: String
  public var task: ScheduledTask
  public var title: String
  public var status: String
  public var error: String?
  public var revision: Int?
  public init(id: String, eventID: String, eventRevision: Int, ownerDeviceID: String, occurrence: Int, scheduledAt: Date,
    sessionID: String, task: ScheduledTask, title: String, status: String, error: String? = nil) {
    self.id = id; self.eventID = eventID; self.eventRevision = eventRevision; self.ownerDeviceID = ownerDeviceID
    self.occurrence = occurrence; self.scheduledAt = scheduledAt; self.sessionID = sessionID; self.task = task
    self.title = title; self.status = status; self.error = error; self.revision = 0
  }
}

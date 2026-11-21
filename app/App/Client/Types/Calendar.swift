import Foundation

struct CalendarRecurrence: Codable, Hashable, Sendable {
    enum Unit: String, Codable, CaseIterable, Hashable, Sendable {
        case minute, hour, day, week, month

        /// The units the calendar sheet offers; agents may also repeat by minutes or hours.
        static let calendarCases: [Self] = [.day, .week, .month]

        var title: String { rawValue.capitalized + "s" }

        var component: Calendar.Component {
            switch self {
            case .minute: .minute
            case .hour: .hour
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    var unit: Unit
    var interval: Int

    init(unit: Unit, interval: Int = 1) {
        self.unit = unit
        self.interval = interval
    }

    var label: String {
        if interval == 1 {
            switch unit {
            case .minute: return "Every minute"
            case .hour: return "Hourly"
            case .day: return "Daily"
            case .week: return "Weekly"
            case .month: return "Monthly"
            }
        }
        return "Every \(interval) \(unit.rawValue)s"
    }
}

/// The session a scheduled task starts or continues. Nil settings mean the agent's default.
struct CalendarTaskConfiguration: Codable, Hashable, Sendable {
    var runtimeKind: AgentRuntimeKind
    var folderID: String?
    var title: String
    var model: String?
    var thinking: String?
    var permission: String?
    var workingDirectory: String?

    init(runtimeKind: AgentRuntimeKind, folderID: String? = nil, title: String, model: String? = nil,
         thinking: String? = nil, permission: String? = nil, workingDirectory: String? = nil) {
        self.runtimeKind = runtimeKind
        self.folderID = folderID
        self.title = title
        self.model = model
        self.thinking = thinking
        self.permission = permission
        self.workingDirectory = workingDirectory
    }
}

struct CalendarTask: Codable, Hashable, Sendable {
    enum SessionMode: String, Codable, CaseIterable, Hashable, Sendable {
        case same, new

        var title: String { self == .same ? "Same session" : "New session each time" }
    }

    var prompt: String
    var configuration: CalendarTaskConfiguration
    var sessionMode: SessionMode

    init(prompt: String, configuration: CalendarTaskConfiguration, sessionMode: SessionMode = .same) {
        self.prompt = prompt
        self.configuration = configuration
        self.sessionMode = sessionMode
    }
}

/// Who created or last edited an entry. A session's details are kept as they were.
struct CalendarAuthor: Hashable, Sendable {
    var sessionID: String?
    var runtimeKind: AgentRuntimeKind?
    var sessionTitle: String?

    var label: String {
        guard sessionID != nil else { return "You" }
        let name = runtimeKind?.displayName ?? "Agent"
        return sessionTitle.map { "\(name) · \($0)" } ?? name
    }
}

/// One entry in a machine's scheduler: an event, or a task that machine runs.
struct CalendarEntry: Identifiable, Hashable, Sendable {
    let id: String
    /// The machine whose scheduler holds the entry and runs its task.
    let machineID: String
    var title: String
    var details: String
    var startsAt: Date
    var endsAt: Date?
    var allDay: Bool
    var timeZoneID: String
    var recurrence: CalendarRecurrence?
    var task: CalendarTask?
    var showsOnCalendar: Bool
    var excludedOccurrences: Set<Int>
    var createdBy: CalendarAuthor
    var editedBy: CalendarAuthor?
    var editedAt: Date?
}

enum CalendarRunStatus: Hashable, Sendable {
    case waiting
    case starting
    case promptSent
    case running
    case completed
    case failed
    /// The send may or may not have reached the session.
    case uncertain
    case cancelled
}

/// One time a scheduled task ran, or is about to.
struct CalendarRun: Identifiable, Hashable, Sendable {
    let id: String
    let entryID: String
    let occurrenceIndex: Int
    let scheduledAt: Date
    let sessionID: String
    /// The task as it was when this run was scheduled.
    let task: CalendarTask
    var status: CalendarRunStatus
    var error: String?
    let title: String

    var statusLabel: String {
        switch status {
        case .waiting: error == nil ? "Waiting to run" : "Waiting to retry"
        case .starting: "Starting session"
        case .promptSent: "Prompt sent"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .uncertain: "Check session before retrying"
        case .cancelled: "Cancelled"
        }
    }
}

struct CalendarDraftError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// An entry being created or edited, or copied to the pasteboard.
struct CalendarDraft: Codable, Hashable, Sendable {
    var title: String
    var details: String
    var startsAt: Date
    var endsAt: Date?
    var allDay: Bool
    var timeZoneID: String
    var recurrence: CalendarRecurrence?
    var task: CalendarTask?
    var showsOnCalendar: Bool
    /// The machine that will hold the entry and run its task. Nil means this Mac.
    var machineID: String?

    init(title: String = "", details: String = "", startsAt: Date, endsAt: Date? = nil,
         allDay: Bool = false, timeZoneID: String = TimeZone.current.identifier,
         recurrence: CalendarRecurrence? = nil, task: CalendarTask? = nil,
         showsOnCalendar: Bool = true, machineID: String? = nil) {
        self.title = title
        self.details = details
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.allDay = allDay
        self.timeZoneID = timeZoneID
        self.recurrence = recurrence
        self.task = task
        self.showsOnCalendar = task == nil || showsOnCalendar
        self.machineID = machineID
    }

    init(_ entry: CalendarEntry) {
        self.init(title: entry.title, details: entry.details, startsAt: entry.startsAt, endsAt: entry.endsAt,
                  allDay: entry.allDay, timeZoneID: entry.timeZoneID, recurrence: entry.recurrence,
                  task: entry.task, showsOnCalendar: entry.showsOnCalendar, machineID: entry.machineID)
    }

    func validated() throws -> Self {
        var value = self
        if task == nil { value.showsOnCalendar = true }
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty, value.title.utf8.count <= 4_096, details.utf8.count <= 65_536,
              startsAt.timeIntervalSince1970.isFinite,
              endsAt.map({ $0.timeIntervalSince1970.isFinite && $0 > startsAt }) ?? true,
              let zone = TimeZone(identifier: timeZoneID) else {
            throw CalendarDraftError(message: "Enter a title, a valid time zone, and an end after the start.")
        }
        if let recurrence, !(1...365).contains(recurrence.interval) {
            throw CalendarDraftError(message: "Repeat intervals must be between 1 and 365.")
        }
        if allDay {
            guard task == nil else { throw CalendarDraftError(message: "Choose a time for a scheduled task.") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            value.startsAt = calendar.startOfDay(for: startsAt)
            let end = calendar.startOfDay(for: endsAt ?? startsAt)
            value.endsAt = end > value.startsAt ? end : calendar.date(byAdding: .day, value: 1, to: value.startsAt)
        }
        if var task {
            task.prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.prompt.isEmpty, task.prompt.utf8.count <= 65_536,
                  task.configuration.workingDirectory.map({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4_096 }) ?? true else {
                throw CalendarDraftError(message: "A scheduled task needs a prompt and an absolute working directory.")
            }
            task.configuration.title = value.title
            value.task = task
        }
        return value
    }

    /// All-day events name calendar dates, so changing their zone must not move
    /// them to the previous or following day. Timed events keep their instant.
    func changingTimeZone(to identifier: String) -> Self {
        var value = self
        value.timeZoneID = identifier
        guard allDay, let sourceZone = TimeZone(identifier: timeZoneID),
              let targetZone = TimeZone(identifier: identifier) else { return value }
        var source = Calendar(identifier: .gregorian)
        source.timeZone = sourceZone
        var target = Calendar(identifier: .gregorian)
        target.timeZone = targetZone
        func remap(_ date: Date) -> Date {
            target.date(from: source.dateComponents([.year, .month, .day], from: date)) ?? date
        }
        value.startsAt = remap(startsAt)
        value.endsAt = endsAt.map(remap)
        return value
    }

    /// Copying an occurrence always creates a new, independent event.
    func copied(to day: Date, calendar: Calendar = .autoupdatingCurrent) -> Self {
        var value = self
        var copyCalendar = calendar
        var destination = day
        if allDay {
            copyCalendar.timeZone = TimeZone(identifier: timeZoneID) ?? calendar.timeZone
            destination = copyCalendar.date(from: calendar.dateComponents([.year, .month, .day], from: day)) ?? day
        }
        let days = copyCalendar.dateComponents([.day], from: copyCalendar.startOfDay(for: startsAt),
                                               to: copyCalendar.startOfDay(for: destination)).day ?? 0
        value.startsAt = copyCalendar.date(byAdding: .day, value: days, to: startsAt) ?? startsAt
        value.endsAt = endsAt.flatMap { copyCalendar.date(byAdding: .day, value: days, to: $0) }
        value.recurrence = nil
        return value
    }
}

/// One visible occurrence of an entry, or a past run whose date left the schedule.
struct CalendarOccurrence: Identifiable, Hashable, Sendable {
    let entry: CalendarEntry
    let index: Int
    let startsAt: Date
    let endsAt: Date?
    /// A past send whose date no longer belongs to the current schedule.
    let recordedRun: CalendarRun?

    init(entry: CalendarEntry, index: Int, startsAt: Date, endsAt: Date?, recordedRun: CalendarRun? = nil) {
        self.entry = entry
        self.index = index
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.recordedRun = recordedRun
    }

    var title: String { recordedRun?.title ?? entry.title }
    var allDay: Bool { recordedRun == nil && entry.allDay }
    var recurrence: CalendarRecurrence? { recordedRun == nil ? entry.recurrence : nil }
    var id: String { entry.id + ":" + String(startsAt.timeIntervalSince1970) }

    /// All-day entries keep their calendar dates when the viewer travels.
    /// Timed events keep their instant and display in the viewer's zone.
    func displayInterval(in calendar: Calendar) -> DateInterval {
        func displayDate(_ date: Date) -> Date {
            guard allDay else { return date }
            var source = Calendar(identifier: .gregorian)
            source.timeZone = TimeZone(identifier: entry.timeZoneID) ?? .current
            return calendar.date(from: source.dateComponents([.year, .month, .day], from: date)) ?? date
        }
        let start = displayDate(startsAt)
        return .init(start: start, end: max(start.addingTimeInterval(1), endsAt.map(displayDate) ?? start.addingTimeInterval(1)))
    }

    var draft: CalendarDraft {
        var result = CalendarDraft(entry)
        result.startsAt = startsAt
        result.endsAt = endsAt
        if let recordedRun {
            result.title = recordedRun.title
            result.task = recordedRun.task
            result.allDay = false
            result.recurrence = nil
        }
        return result
    }
}

/// Expands entries into the occurrences a range shows. Arithmetic is anchored to
/// the first date: Jan 31 -> Feb 28 -> Mar 31, and a 9am daily task stays at 9am
/// across daylight-saving changes.
enum CalendarSchedule {
    static func date(index: Int, start: Date, recurrence: CalendarRecurrence?, timeZoneID: String) -> Date? {
        guard index >= 0 else { return nil }
        guard let recurrence else { return index == 0 ? start : nil }
        guard (1...365).contains(recurrence.interval), let zone = TimeZone(identifier: timeZoneID) else { return nil }
        let (offset, overflow) = index.multipliedReportingOverflow(by: recurrence.interval)
        guard !overflow else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(byAdding: recurrence.unit.component, value: offset, to: start)
    }

    static func index(onOrBefore date: Date, start: Date, recurrence: CalendarRecurrence?, timeZoneID: String) -> Int? {
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
            if let next = self.date(index: middle, start: start, recurrence: recurrence, timeZoneID: timeZoneID), next <= date {
                lower = middle
            } else {
                upper = middle
            }
        }
        return lower
    }

    static func occurrence(_ entry: CalendarEntry, index: Int) -> CalendarOccurrence? {
        guard !entry.excludedOccurrences.contains(index),
              let date = date(index: index, start: entry.startsAt, recurrence: entry.recurrence, timeZoneID: entry.timeZoneID)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: entry.timeZoneID) ?? .current
        let end = entry.endsAt.flatMap { end in
            calendar.date(byAdding: calendar.dateComponents([.day, .hour, .minute, .second], from: entry.startsAt, to: end), to: date)
        }
        return .init(entry: entry, index: index, startsAt: date, endsAt: end)
    }

    static func occurrences(_ entry: CalendarEntry, in range: DateInterval) -> [CalendarOccurrence] {
        let start = entry.startsAt
        guard range.end >= start else { return [] }
        // Include entries that started before the range but still overlap it.
        let duration = max(0, (entry.endsAt ?? start).timeIntervalSince(start)) + 86_400
        var index = self.index(onOrBefore: range.start.addingTimeInterval(-duration), start: start,
                               recurrence: entry.recurrence, timeZoneID: entry.timeZoneID) ?? 0
        var result: [CalendarOccurrence] = []
        while let date = date(index: index, start: start, recurrence: entry.recurrence, timeZoneID: entry.timeZoneID), date < range.end {
            if let value = occurrence(entry, index: index),
               (value.endsAt ?? value.startsAt.addingTimeInterval(1)) > range.start {
                result.append(value)
            }
            index += 1
        }
        return result
    }

    /// Past runs stay at their dates after a schedule edit, but never take the
    /// identity of a different live occurrence.
    static func visibleOccurrences(entries: [CalendarEntry], runs: [CalendarRun], in range: DateInterval) -> [CalendarOccurrence] {
        let expanded = DateInterval(start: range.start.addingTimeInterval(-86_400), end: range.end.addingTimeInterval(86_400))
        let visible = entries.filter { $0.task == nil || $0.showsOnCalendar }
        var result = visible.flatMap { occurrences($0, in: $0.allDay ? expanded : range) }
        var ids = Set(result.map(\.id))
        let entriesByID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for run in runs where run.status != .cancelled && run.scheduledAt >= range.start && run.scheduledAt < range.end {
            guard let entry = entriesByID[run.entryID] else { continue }
            let value = CalendarOccurrence(entry: entry, index: run.occurrenceIndex, startsAt: run.scheduledAt,
                                           endsAt: nil, recordedRun: run)
            if ids.insert(value.id).inserted { result.append(value) }
        }
        return result.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            return $0.startsAt == $1.startsAt ? $0.id < $1.id : $0.startsAt < $1.startsAt
        }
    }

    static func next(_ entry: CalendarEntry, after date: Date) -> Date? {
        var index = self.index(onOrBefore: date, start: entry.startsAt, recurrence: entry.recurrence,
                               timeZoneID: entry.timeZoneID).map { $0 + 1 } ?? 0
        while entry.excludedOccurrences.contains(index) { index += 1 }
        return self.date(index: index, start: entry.startsAt, recurrence: entry.recurrence, timeZoneID: entry.timeZoneID)
    }
}

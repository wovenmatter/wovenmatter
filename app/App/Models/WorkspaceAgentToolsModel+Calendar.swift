import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceAgentToolsModel {
    func calendar(_ command: WovenMatterToolCommand, callerID: String, requestID: String) async throws -> WovenMatterToolResponse {
        if command.action == "list" {
            return .init(result: try database.listAgentCalendar(callerID: callerID,
                since: command.options["since"].map(Self.date), until: command.options["until"].map(Self.date),
                after: Int64(command.integer("after", default: 0, range: 0...Int.max)),
                limit: command.integer("limit", default: 100, range: 1...200)))
        }
        if command.action == "read" || command.action == "occurrences" {
            let event = try database.calendarEvent(id: command.required("id", allowPositional: true), callerID: callerID)
            if command.action == "read" {
                return .init(result: .object(["event": try WovenMatterToolResponse.value(event).result ?? .null,
                    "runs": try WovenMatterToolResponse.value(database.calendarRuns().filter { $0.eventID == event.id }).result ?? .null]))
            }
            let since = try Self.date(command.required("since")), until = try Self.date(command.required("until"))
            guard until > since, until.timeIntervalSince(since) <= 366 * 86_400 else {
                throw WorkspaceToolError.invalid("Choose an occurrence window of at most one year.")
            }
            let values = WorkspaceCalendarSchedule.occurrences(event, in: .init(start: since, end: until))
            return .init(result: .array(values.map {
                .object(["eventID": .string(event.id), "occurrence": .number(Double($0.index)),
                    "startsAt": .string(WorkspaceCalendarSchedule.timestamp($0.startsAt)),
                    "endsAt": $0.endsAt.map { .string(WorkspaceCalendarSchedule.timestamp($0)) } ?? .null])
            }))
        }
        let input = String(decoding: try JSONEncoder().encode(command.operationArguments), as: UTF8.self)
        if let id = try database.replayCalendarRequest(callerID: callerID, requestID: requestID, input: input) {
            return .init(result: .object(["id": .string(id)]))
        }
        let creating = command.action == "create"
        let id = creating ? requestID : try command.required("id", allowPositional: true)
        let existing = creating ? nil : try database.calendarEvent(id: id, callerID: callerID)
        let revision = try command.options["revision"].map { _ in try command.integer("revision", default: 0, range: 0...Int.max) }
        let occurrence = try command.options["occurrence"].map { _ in try command.integer("occurrence", default: 0, range: 0...Int.max) }
        if command.action == "remove" {
            try database.deleteCalendarEvent(id: id, occurrence: occurrence, expectedRevision: revision,
                callerID: callerID, requestID: requestID, requestInput: input)
            return .init(result: .object(["id": .string(id)]))
        }
        var draft = try existing.map(WorkspaceCalendarDraft.init) ?? .init(startsAt: Self.date(command.required("starts-at")))
        if let occurrence, let existing {
            guard let value = WorkspaceCalendarSchedule.occurrence(existing, index: occurrence) else { throw WorkspaceToolError.invalid("Occurrence not found.") }
            draft = value.draft
        }
        if let title = command.options["title"] { draft.title = title }
        if let details = command.options["description"] { draft.details = details }
        if let date = command.options["starts-at"] {
            let next = try Self.date(date)
            draft.endsAt = draft.endsAt.map { $0.addingTimeInterval(next.timeIntervalSince(draft.startsAt)) }
            draft.startsAt = next
        }
        if let date = command.options["ends-at"] { draft.endsAt = try Self.date(date) }
        if command.options["all-day"] != nil { draft.allDay = true }
        if command.options["timed"] != nil { draft.allDay = false }
        if let zone = command.options["time-zone"] { draft.timeZoneID = zone }
        if let raw = command.options["repeat-unit"] {
            guard let unit = WorkspaceCalendarRecurrence.Unit(rawValue: raw) else { throw WorkspaceToolError.invalid("Repeat units are day, week, or month.") }
            draft.recurrence = .init(unit: unit, interval: try command.integer("repeat-interval", default: 1, range: 1...365))
        } else if command.options["repeat-interval"] != nil {
            guard draft.recurrence != nil else { throw WorkspaceToolError.invalid("Choose --repeat-unit with --repeat-interval.") }
            draft.recurrence?.interval = try command.integer("repeat-interval", default: 1, range: 1...365)
        }
        if command.options["no-repeat"] != nil { draft.recurrence = nil }
        if command.options["regular-event"] != nil { draft.task = nil }
        else if draft.task != nil || command.options["prompt"] != nil {
            guard let calendarTaskHandler else { throw WorkspaceToolError.invalid("Scheduled session creation is unavailable.") }
            draft.task = try await calendarTaskHandler(callerID, command, draft.task)
        }
        var targetID = id
        var create = creating
        var detach: Int?
        if command.action == "detach" {
            guard let occurrence else { throw WorkspaceToolError.invalid("Choose the --occurrence to detach.") }
            detach = occurrence; draft.recurrence = nil
        } else if command.action == "copy" {
            _ = try command.required("starts-at")
            targetID = requestID; create = true; draft.recurrence = nil
        } else if occurrence != nil { throw WorkspaceToolError.invalid("Use detach to change a single recurring occurrence, or update without --occurrence to change the series.") }
        let saved = try database.saveCalendarEvent(id: targetID, draft: draft, creating: create,
            expectedRevision: create ? nil : revision ?? existing?.calendar.revision, detaching: detach,
            callerID: callerID, requestID: requestID, requestInput: input)
        return .init(result: .object(["id": .string(saved)]))
    }
}

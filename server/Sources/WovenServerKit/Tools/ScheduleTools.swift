import Foundation
import WovenLibrary
import WovenProtocol

// The scheduler's and goals' entries in the one Woven tool catalog.
// Bots keep their own schedules in the bots' database, so these are not
// offered to them.

private func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
  .object(["type": .string("object"), "properties": .object(properties),
           "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
}

private func text(_ description: String) -> JSONValue {
  .object(["type": .string("string"), "description": .string(description)])
}

private func integer(_ description: String) -> JSONValue {
  .object(["type": .string("integer"), "description": .string(description)])
}

private func flag(_ description: String) -> JSONValue {
  .object(["type": .string("boolean"), "description": .string(description)])
}

private let repeatUnits = Recurrence.Unit.allCases.map(\.rawValue)

private let taskFields: [String: JSONValue] = [
  "title": text("A short title."),
  "prompt": text("What the agent is told on each run: everything it needs."),
  "startsAt": text("The first run, as ISO 8601 with a time zone offset, e.g. 2026-11-21T09:00:00-08:00."),
  "timeZone": text("The IANA time zone repeats keep to, e.g. America/Los_Angeles (default: the machine's)."),
  "repeatUnit": .object(["type": .string("string"), "enum": .array(repeatUnits.map(JSONValue.string)),
                         "description": .string("Repeat every `repeatInterval` of these; omit to run once.")]),
  "repeatInterval": integer("How many units between runs (default 1)."),
  "runtime": text("The runtime, as `list_places` names it (codex, claudeCode, grokBuild, openCode, piDurable)."),
  "folderID": text("Run in this folder; it decides the machine."),
  "machineID": text("Run on this machine when no folder is given; default this one."),
  "model": text("A model of that runtime; default its default."),
  "newSessionEachRun": flag("Start a new session for every run instead of continuing one."),
  "showOnCalendar": flag("Show it on the person's calendar (default true)."),
  "enabled": flag("Whether it runs (default true)."),
]

private func date(_ value: String?, _ key: String) throws -> Date? {
  guard let value else { return nil }
  let parser = ISO8601DateFormatter()
  if let date = parser.date(from: value) { return date }
  parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = parser.date(from: value) { return date }
  throw ToolFailure("`\(key)` is not an ISO 8601 time with an offset: \(value).")
}

private func recurrence(_ arguments: Arguments) throws -> Recurrence?? {
  guard let unit = arguments.optionalString("repeatUnit") else { return nil }
  if unit.isEmpty || unit == "none" { return .some(nil) }
  guard let value = Recurrence.Unit(rawValue: unit) else { throw ToolFailure("repeatUnit is one of \(repeatUnits.joined(separator: ", ")).") }
  return .some(Recurrence(unit: value, interval: arguments.int("repeatInterval") ?? 1))
}

/// A scheduler entry as a result shows it. `machineID` is given for another
/// machine's, and `nextFireAt` and `lastError` only for this machine's.
private let entryShape = Shape([
  "id": Field.string, "kind": Field.choice(["task", "event", "timer", "wakeUp"]), "title": Field.string,
  "startsAt": Field.string, "timeZone": Field.string, "repeatUnit": Field.string, "repeatInterval": Field.integer,
  "runtime": Field.string, "sessionID": Field.string, "newSessionEachRun": Field.boolean, "disabled": Field.boolean,
  "machineID": Field.string, "nextFireAt": Field.string, "lastError": Field.string, "prompt": Field.string,
], required: ["id"])

private let scheduleListing = Shape(["schedules": Field.list(entryShape)], required: ["schedules"])

/// What a new or changed scheduler entry returns: its id, and when it fires.
private let scheduleActionShape = Shape(["scheduleID": Field.string, "firesAt": Field.string], required: ["scheduleID"])
private let deletedShape = Shape(["scheduleID": Field.string], required: ["scheduleID"])

private func fields(_ entry: ScheduleEntry, here: String) -> JSONValue {
  let draft = entry.draft
  return entryShape([
    "id": .string(entry.id), "kind": .string(entry.kind.rawValue), "title": .text(draft.title), "startsAt": .time(draft.startsAt),
    "timeZone": .text(draft.timeZone), "repeatUnit": draft.recurrence.map { .string($0.unit.rawValue) },
    "repeatInterval": draft.recurrence.map { .count($0.interval) }, "runtime": draft.runtime.map { .string($0.rawValue) },
    "sessionID": draft.sessionID.map(JSONValue.string), "newSessionEachRun": .bool(draft.newSessionEachRun),
    "disabled": .bool(!draft.enabled), "machineID": entry.machineID == here ? nil : .string(entry.machineID),
    "nextFireAt": entry.state?.nextFireAt.map(JSONValue.time), "lastError": .text(entry.state?.lastError),
    "prompt": .text(String(draft.prompt.prefix(200))),
  ])
}

/// When an entry this machine saved fires next: its next time, else its start.
private func firesAt(_ entry: ScheduleEntry) -> JSONValue { .time(entry.state?.nextFireAt ?? entry.draft.startsAt) }

private extension ToolRequest {
  /// The calling session, which timers, wake-ups and goals are for.
  func callingSession() async throws -> Session {
    guard let sessionID = caller.sessionID, let session = try await tools.library.session(sessionID) else {
      throw ToolFailure("Only an agent session can use this.")
    }
    return session
  }
}

let scheduleTools: [WovenTool] = [
  WovenTool(
    name: "list_schedules",
    description: "The scheduler's entries on every machine: scheduled tasks, calendar events, timers and wake-ups, with id, kind, title, when, repeat, runtime and, for this machine's, when each fires next.",
    input: schema(["kind": .object(["type": .string("string"), "enum": .array(["task", "event", "timer", "wakeUp"].map(JSONValue.string)),
                                    "description": .string("Only this kind.")])]),
    output: scheduleListing.schema,
    readOnly: true,
    forBots: false,
    groups: [.calendar, .timers],
    run: { call in
      var entries = try await call.tools.library.schedules()
      if let kind = call.arguments.optionalString("kind") { entries = entries.filter { $0.kind.rawValue == kind } }
      let here = call.tools.machineID
      return scheduleListing.result(["schedules": .array(entries.prefix(200).map { fields($0, here: here) })])
    }),
  WovenTool(
    name: "create_scheduled_task",
    description: "Schedule a prompt to run in an agent session at a time, once or repeating; returns its `scheduleID`.\nEach run continues the task's session (or starts a new one with `newSessionEachRun`). It runs on the folder's machine, or `machineID`, even while no one has the app open.",
    input: schema(taskFields, required: ["title", "prompt", "startsAt", "runtime"]),
    output: scheduleActionShape.schema,
    forBots: false,
    groups: [.calendar],
    run: { call in
      let tools = call.tools
      let arguments = call.arguments
      var owner = arguments.optionalString("machineID") ?? tools.machineID
      if let folderID = arguments.optionalString("folderID") {
        guard let folder = try await tools.library.folder(folderID) else { throw ToolFailure("No folder \(folderID).") }
        owner = folder.machineID
      }
      if let forwarded = try await call.forward(to: owner) { return forwarded }
      let draft = ScheduleDraft(
        machineID: owner, kind: .task, title: try arguments.string("title"), prompt: try arguments.string("prompt"),
        newSessionEachRun: arguments.bool("newSessionEachRun") ?? false,
        runtime: RuntimeKind(rawValue: try arguments.string("runtime")), folderID: arguments.optionalString("folderID"),
        model: arguments.optionalString("model"), startsAt: try date(arguments.string("startsAt"), "startsAt")!,
        timeZone: arguments.optionalString("timeZone") ?? TimeZone.current.identifier,
        recurrence: try recurrence(arguments) ?? nil, showsOnCalendar: arguments.bool("showOnCalendar") ?? true,
        enabled: arguments.bool("enabled") ?? true)
      let entry = try await ScheduleBook.save(nil, draft, by: call.caller.sessionID, library: tools.library, sessions: tools.sessions)
      return scheduleActionShape.result(["scheduleID": .string(entry.id), "firesAt": firesAt(entry)])
    }),
  WovenTool(
    name: "change_scheduled_task",
    description: "Change a scheduled task: give its id and only the fields to change.\nIts machine cannot change; delete it and create it again instead.",
    input: schema(taskFields.filter { $0.key != "machineID" && $0.key != "folderID" }
      .merging(["scheduleID": text("The task, from `list_schedules`.")]) { first, _ in first }, required: ["scheduleID"]),
    output: scheduleActionShape.schema,
    forBots: false,
    groups: [.calendar],
    run: { call in
      let tools = call.tools
      let arguments = call.arguments
      let id = try arguments.string("scheduleID")
      guard let entry = try await tools.library.schedule(id), entry.kind == .task else { throw ToolFailure("No scheduled task \(id).") }
      if let forwarded = try await call.forward(to: entry.machineID) { return forwarded }
      var draft = entry.draft
      if let title = arguments.optionalString("title") { draft.title = title }
      if let prompt = arguments.optionalString("prompt") { draft.prompt = prompt }
      if let startsAt = try date(arguments.optionalString("startsAt"), "startsAt") { draft.startsAt = startsAt }
      if let timeZone = arguments.optionalString("timeZone") { draft.timeZone = timeZone }
      if let recurrence = try recurrence(arguments) { draft.recurrence = recurrence }
      if let runtime = arguments.optionalString("runtime") { draft.runtime = RuntimeKind(rawValue: runtime) }
      if let model = arguments.optionalString("model") { draft.model = model.isEmpty ? nil : model }
      if let each = arguments.bool("newSessionEachRun") { draft.newSessionEachRun = each }
      if let shown = arguments.bool("showOnCalendar") { draft.showsOnCalendar = shown }
      if let enabled = arguments.bool("enabled") { draft.enabled = enabled }
      let saved = try await ScheduleBook.save(id, draft, by: call.caller.sessionID, library: tools.library, sessions: tools.sessions)
      return scheduleActionShape.result(["scheduleID": .string(saved.id), "firesAt": firesAt(saved)])
    }),
  WovenTool(
    name: "delete_schedule",
    description: "Delete a scheduler entry (a scheduled task, event, timer or wake-up) by its id from `list_schedules`.\nSessions it already ran stay.",
    input: schema(["scheduleID": text("The entry.")], required: ["scheduleID"]),
    output: deletedShape.schema,
    forBots: false,
    groups: [.calendar, .timers],
    run: { call in
      let tools = call.tools
      let id = try call.arguments.string("scheduleID")
      guard let entry = try await tools.library.schedule(id) else { throw ToolFailure("No entry \(id).") }
      if let forwarded = try await call.forward(to: entry.machineID) { return forwarded }
      try await ScheduleBook.delete(id, occurrence: nil, library: tools.library)
      return deletedShape.result(["scheduleID": .string(id)])
    }),
  WovenTool(
    name: "set_timer",
    description: "Have this session prompted again after a delay, with an instruction to yourself; returns its `scheduleID`.\nRepeats when `repeatMinutes` is given. Cancel it with `delete_schedule`.",
    input: schema(["afterSeconds": integer("Seconds from now until it fires."), "instruction": text("What you will be told when it fires."),
                   "repeatMinutes": integer("Fire again every this many minutes."), "title": text("A short name for it.")],
                  required: ["afterSeconds", "instruction"]),
    output: scheduleActionShape.schema,
    forBots: false,
    groups: [.timers],
    run: { call in
      let tools = call.tools
      let session = try await call.callingSession()
      guard let seconds = call.arguments.int("afterSeconds"), seconds >= 0 else { throw ToolFailure("Give `afterSeconds`, 0 or more.") }
      let repeatMinutes = call.arguments.int("repeatMinutes")
      let draft = ScheduleDraft(machineID: session.machineID, kind: .timer, title: call.arguments.optionalString("title") ?? "Timer",
                                prompt: try call.arguments.string("instruction"), sessionID: session.id,
                                startsAt: Date().addingTimeInterval(TimeInterval(seconds)),
                                recurrence: repeatMinutes.map { Recurrence(unit: .minute, interval: max($0, 1)) },
                                showsOnCalendar: false)
      let entry = try await ScheduleBook.save(nil, draft, by: session.id, library: tools.library, sessions: tools.sessions)
      return scheduleActionShape.result(["scheduleID": .string(entry.id), "firesAt": .time(entry.draft.startsAt)])
    }),
  WovenTool(
    name: "set_wake_up",
    description: "Have this session woken at a time with a message to yourself, e.g. to check on something later; returns its `scheduleID`.\nCancel it with `delete_schedule`.",
    input: schema(["at": text("When, as ISO 8601 with a time zone offset."), "message": text("What you will be told then.")],
                  required: ["at", "message"]),
    output: scheduleActionShape.schema,
    forBots: false,
    groups: [.timers],
    run: { call in
      let tools = call.tools
      let session = try await call.callingSession()
      let at = try date(call.arguments.string("at"), "at")!
      let draft = ScheduleDraft(machineID: session.machineID, kind: .wakeUp, title: "Wake-up",
                                prompt: try call.arguments.string("message"), sessionID: session.id, startsAt: at,
                                showsOnCalendar: false)
      let entry = try await ScheduleBook.save(nil, draft, by: session.id, library: tools.library, sessions: tools.sessions)
      return scheduleActionShape.result(["scheduleID": .string(entry.id), "firesAt": .time(at)])
    }),
  WovenTool(
    name: "goal_met",
    description: "Say that this session's goal is met, with what shows it.\nThe goal is cleared and you are no longer asked to continue toward it. Only call it when the goal truly is met.",
    input: schema(["evidence": text("What shows the goal is met.")], required: ["evidence"]),
    output: goalShape.schema,
    forBots: false,
    run: { call in
      let session = try await call.callingSession()
      if let forwarded = try await call.forward(to: session.machineID) { return forwarded }
      try await call.tools.sessions.host(for: session.id).goalMet(try call.arguments.string("evidence"))
      return goalShape.result(["cleared": .bool(true)])
    }),
]

/// `goal_met`: the goal is cleared.
private let goalShape = Shape(["cleared": Field.boolean], required: ["cleared"])

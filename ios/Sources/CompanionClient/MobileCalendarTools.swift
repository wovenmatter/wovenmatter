import Foundation
import WovenMatterCompanion

extension MobileStore {
  public func executeCalendarTool(_ c: WovenMatterToolCommand, request: WovenMatterToolRequest, context: MobileToolContext) async throws -> WovenMatterToolResponse {
    try Task.checkCancellation()
    try context.authorize(c)
    let key = context.sessionID + ":" + request.requestID
    let signature = String(decoding: try JSONEncoder().encode(c.operationArguments), as: UTF8.self)
    if c.isMutation, c.action != "remove", let result = try await calendar.toolResult(requestID: key, arguments: signature) {
      if result.event.draft.task != nil, !context.enabled.contains(.sessions) { throw WorkspaceToolError.disabled(.sessions) }
      return .init(result: try MobileToolSupport.value(result), requestID: request.requestID)
    }
    let id = ["create", "list"].contains(c.action) ? request.requestID : try c.required("id", allowPositional: true)
    if c.action == "list" {
      // Listing series is distinct from expanding occurrences; no arbitrary date
      // window hides saved events from the agent.
      let records = await calendar.records()
      let from = try c.options["since"].map(MobileToolSupport.date), to = try c.options["until"].map(MobileToolSupport.date)
      let rows = records.filter { (from == nil || $0.event.draft.recurrenceUnit != nil || $0.event.startsAt >= from!) && (to == nil || $0.event.startsAt <= to!) }
      return .init(result: try MobileToolSupport.page(rows.map(MobileToolSupport.value), command: c), requestID: request.requestID)
    }
    if c.action == "remove" {
      try await calendar.delete(id: id, expectedRevision: c.integer("revision", default: -1, range: 0...Int.max),
        occurrence: try c.options["occurrence"].map { _ in try c.integer("occurrence", default: 0, range: 0...Int.max) }, requestID: context.sessionID + ":" + request.requestID)
      return .init(result: .object(["id": .string(id), "status": .string("removed")]), requestID: request.requestID)
    }
    let existing = await calendar.record(id: id)
    if c.action == "read" {
      guard let existing else { throw WorkspaceToolError.notFound("The calendar event is not saved on this device.") }
      return .init(result: try MobileToolSupport.value(existing), requestID: request.requestID)
    }
    if c.action == "occurrences" {
      guard let existing else { throw WorkspaceToolError.notFound("The calendar event is not saved on this device.") }
      let from = try MobileToolSupport.date(c.required("since")), to = try MobileToolSupport.date(c.required("until"))
      guard to > from, to.timeIntervalSince(from) <= 366 * 86_400 else { throw WorkspaceToolError.invalid("Use an occurrence window up to one year.") }
      var index = CompanionCalendarSchedule.index(existing.event.draft, onOrBefore: from) ?? 0
      var rows: [GatewayJSONValue] = []
      while let date = CompanionCalendarSchedule.date(existing.event.draft, index: index), date <= to {
        if date >= from, let event = CompanionCalendarSchedule.occurrence(existing, index: index) { rows.append(try MobileToolSupport.value(event)) }; index += 1
      }
      return .init(result: try MobileToolSupport.page(rows, command: c), requestID: request.requestID)
    }
    if c.action != "create", existing == nil { throw WorkspaceToolError.notFound("The calendar event is not saved on this device.") }
    var draft = existing?.event.draft ?? .init()
    if c.action == "detach" {
      let index = try c.integer("occurrence", default: -1, range: 0...Int.max)
      guard let occurrence = await calendar.occurrence(id: id, index: index) else { throw WorkspaceToolError.notFound("The calendar occurrence does not exist.") }
      let delta = occurrence.startsAt.timeIntervalSince(draft.startsAt)
      draft.startsAt = occurrence.startsAt; draft.endsAt = draft.endsAt?.addingTimeInterval(delta)
      draft.recurrenceUnit = nil; draft.recurrenceInterval = 1
    }
    if let value = c.options["title"] { draft.title = value }
    if let value = c.options["description"] { draft.details = value }
    if let value = c.options["starts-at"] {
      let start = try MobileToolSupport.date(value)
      if c.options["ends-at"] == nil { draft.endsAt = draft.endsAt?.addingTimeInterval(start.timeIntervalSince(draft.startsAt)) }
      draft.startsAt = start
    } else if c.action == "create" || c.action == "copy" { throw WorkspaceToolError.invalid("--starts-at is required.") }
    if let value = c.options["ends-at"] { draft.endsAt = try MobileToolSupport.date(value) }
    if let value = c.options["time-zone"] { draft.timeZoneID = value }
    if c.options["all-day"] != nil { draft.allDay = true }
    if c.options["timed"] != nil { draft.allDay = false }
    if c.options["no-repeat"] != nil { draft.recurrenceUnit = nil; draft.recurrenceInterval = 1 }
    if let value = c.options["repeat-unit"] { draft.recurrenceUnit = value }
    if c.options["repeat-interval"] != nil {
      guard draft.recurrenceUnit != nil else { throw WorkspaceToolError.invalid("Choose --repeat-unit with --repeat-interval.") }
      draft.recurrenceInterval = try c.integer("repeat-interval", default: 1, range: 1...365)
    }
    if c.options["regular-event"] != nil { draft.task = nil }
    let taskOptions = ["prompt", "harness", "model", "thinking", "workspace", "directory", "folder", "session-mode"]
    if taskOptions.contains(where: { c.options[$0] != nil }) {
      guard context.enabled.contains(.sessions) else { throw WorkspaceToolError.disabled(.sessions) }
      var task = draft.task ?? .init()
      if let prompt = c.options["prompt"] { task.prompt = prompt }
      if let runtime = c.options["harness"], !["default_agent", "pi-durable", "pi"].contains(runtime) { throw WorkspaceToolError.invalid("This device runs Pi Durable. Assign other harnesses on their execution workspace.") }
      if let workspace = c.options["workspace"], workspace != "local" && workspace != context.workspaceID { throw WorkspaceToolError.invalid("Device-owned tasks must run in this device workspace.") }
      if c.options["directory"] != nil { throw WorkspaceToolError.invalid("Choose the task's files in its device workspace; host filesystem paths are not available on iOS.") }
      if c.options["harness"] != nil || existing?.event.draft.task == nil { task.runtime = "default_agent" }
      if existing?.event.draft.task == nil { task.workspaceID = context.workspaceID }
      let nativeTools = context.nativeToolIDs ?? context.enabled.map { "wovenmatter_" + $0.rawValue }
      task.enabledTools = task.enabledTools.map { Set($0).intersection(nativeTools).sorted() } ?? nativeTools.sorted()
      if let model = c.options["model"] { task.model = model }
      if let thinking = c.options["thinking"] { task.thinking = thinking }
      if let folder = c.options["folder"] { task.folderID = folder == "all" ? nil : folder }
      if let mode = c.options["session-mode"] {
        guard ["same", "new"].contains(mode) else { throw WorkspaceToolError.invalid("Use --session-mode same or new.") }; task.newSessionEachTime = mode == "new"
      }
      draft.task = task
    }
    if ["copy", "detach"].contains(c.action) { draft.recurrenceUnit = nil; draft.recurrenceInterval = 1 }
    if var task = draft.task {
      guard context.enabled.contains(.sessions) else { throw WorkspaceToolError.disabled(.sessions) }
      let nativeTools = context.nativeToolIDs ?? context.enabled.map { "wovenmatter_" + $0.rawValue }
      task.enabledTools = task.enabledTools.map { Set($0).intersection(nativeTools).sorted() } ?? nativeTools.sorted()
      draft.task = task
    }
    draft = try await calendar.prepareToolDraft(requestID: key, arguments: signature, draft: draft)
    if let task = draft.task {
      let allowed = Set(context.nativeToolIDs ?? context.enabled.map { "wovenmatter_" + $0.rawValue })
      guard Set(task.enabledTools ?? []).isSubset(of: allowed) else { throw WorkspaceToolError.invalid("The caller's tool selection changed. Review the pending scheduled task before retrying it.") }
    }
    let record: CompanionCalendarRecord
    if c.action == "detach" {
      record = try await calendar.detach(id: id, expectedRevision: c.integer("revision", default: -1, range: 0...Int.max),
        occurrence: c.integer("occurrence", default: -1, range: 0...Int.max), draft: draft, requestID: key)
    } else {
      let creates = c.action == "create" || c.action == "copy"
      record = try await calendar.save(id: creates ? request.requestID : id,
        expectedRevision: creates ? nil : c.integer("revision", default: -1, range: 0...Int.max), draft: draft,
        ownerDeviceID: draft.task == nil ? nil : (existing?.event.draft.task != nil ? existing?.ownerDeviceID : state.deviceID), requestID: key)
    }
    return .init(result: try MobileToolSupport.value(record), requestID: request.requestID)
  }
}

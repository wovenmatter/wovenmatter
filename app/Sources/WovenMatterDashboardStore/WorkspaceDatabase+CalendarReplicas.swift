import Foundation
import WovenMatterCore

extension WorkspaceDatabase {
  public func companionCalendarSnapshot() async throws -> CompanionCalendarSnapshot { try await read { try $0.companionCalendarSnapshot() } }
  public func companionCalendarPublishRuns(_ runs: [CompanionCalendarRun], deviceID: String) async throws -> [String] {
    try await write { try $0.companionCalendarPublishRuns(runs, deviceID: deviceID) }
  }
  public func companionCalendarMutate(_ mutation: CompanionCalendarMutation, deviceID: String) async throws -> CompanionCalendarReceipt {
    try await write { try $0.companionCalendarMutate(mutation, deviceID: deviceID) }
  }
}
extension WorkspaceDatabaseConnection {
  func migrateCalendarReplicas() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS companion_calendar_execution_conflicts(event_id TEXT PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS companion_calendar_execution_context(singleton INTEGER PRIMARY KEY CHECK(singleton=1), library_id TEXT NOT NULL, workspace_id TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS companion_calendar_owners(event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, tools_json TEXT);
      CREATE TABLE IF NOT EXISTS companion_calendar_run_owners(event_id TEXT NOT NULL, device_id TEXT NOT NULL, PRIMARY KEY(event_id,device_id));
      CREATE TABLE IF NOT EXISTS companion_calendar_runs(id TEXT PRIMARY KEY, event_id TEXT NOT NULL, device_id TEXT NOT NULL, payload_json TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS companion_calendar_receipts(device_id TEXT NOT NULL, mutation_id TEXT NOT NULL,
        input_json TEXT NOT NULL, result_json TEXT NOT NULL, PRIMARY KEY(device_id,mutation_id));
      """)
    let columns = Set(try historyRowsUnlocked("PRAGMA table_info(companion_calendar_owners)", values: []).compactMap { $0.objectValue?["name"]?.stringValue })
    if !columns.contains("tools_json") { try executeUnlocked("ALTER TABLE companion_calendar_owners ADD COLUMN tools_json TEXT") }
    try executeUnlocked("INSERT OR IGNORE INTO companion_calendar_run_owners(event_id,device_id) SELECT event_id,device_id FROM companion_calendar_owners")
  }
  func companionCalendarSnapshot() throws -> CompanionCalendarSnapshot {
    let owners = try calendarReplicaOwners()
    var selectedTools: [String: [String]] = [:]
    for row in try historyRowsUnlocked("SELECT event_id,tools_json FROM companion_calendar_owners WHERE tools_json IS NOT NULL", values: []) {
      if let id = row.objectValue?["event_id"]?.stringValue, let json = row.objectValue?["tools_json"]?.stringValue {
        selectedTools[id] = try JSONDecoder().decode([String].self, from: Data(json.utf8))
      }
    }
    let deleted = Set(try historyRowsUnlocked("SELECT id FROM dashboard_calendar_items WHERE deleted_at IS NOT NULL", values: []).compactMap { $0.objectValue?["id"]?.stringValue })
    let runs = try historyRowsUnlocked("SELECT payload_json FROM companion_calendar_runs", values: []).compactMap { row -> CompanionCalendarRun? in
      guard let json = row.objectValue?["payload_json"]?.stringValue else { return nil }
      return try JSONDecoder().decode(CompanionCalendarRun.self, from: Data(json.utf8))
    }
    return .init(workspaceID: try companionWorkspaceID(), records: try calendarItemsUnlocked(includeDeleted: true).map {
      Self.calendarReplica($0, owner: owners[$0.id], deleted: deleted.contains($0.id), enabledTools: selectedTools[$0.id])
    }, runs: runs)
  }
  func replicaCalendarRuns() throws -> [WorkspaceCalendarRun] {
    try historyRowsUnlocked("SELECT payload_json FROM companion_calendar_runs", values: []).compactMap { row in
      guard let json = row.objectValue?["payload_json"]?.stringValue else { return nil }
      let run = try JSONDecoder().decode(CompanionCalendarRun.self, from: Data(json.utf8))
      guard let runtime = AgentRuntimeKind(rawValue: run.task.runtime) else { return nil }
      let task = WorkspaceCalendarTask(prompt: run.task.prompt, configuration: .init(runtimeKind: runtime,
        workspaceID: run.task.workspaceID.flatMap(UUID.init), folderID: run.task.folderID, title: run.title,
        model: run.task.model, thinking: run.task.thinking, permission: run.task.permission), sessionMode: run.task.newSessionEachTime ? .new : .same)
      return .init(id: run.id, eventID: run.eventID, occurrenceIndex: run.occurrence, scheduledAt: run.scheduledAt,
        sessionID: run.sessionID, task: task, status: run.status, error: run.error, title: run.title)
    }
  }
  func calendarReplicaOwners() throws -> [String: String] {
    Dictionary(uniqueKeysWithValues: try historyRowsUnlocked("SELECT event_id,device_id FROM companion_calendar_owners", values: []).compactMap {
      guard let id = $0.objectValue?["event_id"]?.stringValue, let device = $0.objectValue?["device_id"]?.stringValue else { return nil }
      return (id, device)
    })
  }
  func companionCalendarMutate(_ mutation: CompanionCalendarMutation, deviceID: String) throws -> CompanionCalendarReceipt {
    guard mutation.deviceID == deviceID, UUID(uuidString: mutation.id) != nil, UUID(uuidString: mutation.record.id) != nil,
      mutation.record.ownerDeviceID == nil || mutation.record.event.draft.task?.workspaceID == nil || mutation.record.event.draft.task?.workspaceID == mutation.record.ownerDeviceID,
      mutation.record.excludedOccurrences.allSatisfy({ $0 >= 0 }), mutation.record.excludedOccurrences.count <= 100_000 else { throw CompanionCalendarError.invalid }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let input = String(decoding: try encoder.encode(mutation), as: UTF8.self)
    return try transaction {
      if let existing = try historyRowsUnlocked("SELECT input_json,result_json FROM companion_calendar_receipts WHERE device_id=? AND mutation_id=?", values: [deviceID, mutation.id]).first?.objectValue {
        guard existing["input_json"]?.stringValue == input, let result = existing["result_json"]?.stringValue else { throw CompanionCalendarError.requestMismatch }
        return try JSONDecoder().decode(CompanionCalendarReceipt.self, from: Data(result.utf8))
      }
      let before = try companionCalendarSnapshot().records.first { $0.id == mutation.record.id }
      let result: CompanionCalendarReceipt
      if before?.event.revision != mutation.expectedRevision || before?.deleted == true ||
        (before?.event.draft.task != nil && mutation.record.event.draft.task != nil && before?.ownerDeviceID != mutation.record.ownerDeviceID) ||
        (before == nil && mutation.record.ownerDeviceID != nil && mutation.record.ownerDeviceID != deviceID) {
        result = .init(mutationID: mutation.id, status: .conflict, record: before)
      } else if mutation.record.deleted {
        if before != nil {
          try deleteCalendarEvent(id: mutation.record.id, expectedRevision: mutation.expectedRevision, _transaction: false)
        } else {
          // A create followed by an offline delete is retained as a tombstone.
          let native = try Self.nativeCalendarDraft(mutation.record.event.draft)
          _ = try saveCalendarEvent(id: mutation.record.id, draft: native, creating: true, _transaction: false)
          try deleteCalendarEvent(id: mutation.record.id, _transaction: false)
        }
        result = .init(mutationID: mutation.id, status: .accepted, record: try companionCalendarSnapshot().records.first { $0.id == mutation.record.id })
      } else {
        try CompanionCalendarSchedule.validate(mutation.record.event.draft)
        let native = try Self.nativeCalendarDraft(mutation.record.event.draft)
        _ = try saveCalendarEvent(id: mutation.record.id, draft: native, creating: before == nil, expectedRevision: mutation.expectedRevision, _transaction: false)
        guard let item = try calendarItemsUnlocked().first(where: { $0.id == mutation.record.id }) else { throw CompanionCalendarError.missing }
        var details = item.calendar; details.excludedOccurrences = mutation.record.excludedOccurrences
        try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET calendar_json=? WHERE id=?", [try toolsJSON(details), item.id])
        if let owner = mutation.record.ownerDeviceID {
          let tools = try mutation.record.event.draft.task?.enabledTools.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
          try toolsExecuteUnlocked("INSERT INTO companion_calendar_owners(event_id,device_id,tools_json) VALUES(?,?,?) ON CONFLICT(event_id) DO UPDATE SET device_id=excluded.device_id,tools_json=excluded.tools_json", [item.id, owner, tools])
          try toolsExecuteUnlocked("INSERT OR IGNORE INTO companion_calendar_run_owners(event_id,device_id) VALUES(?,?)", [item.id, owner])
        } else { try toolsExecuteUnlocked("DELETE FROM companion_calendar_owners WHERE event_id=?", [item.id]) }
        result = .init(mutationID: mutation.id, status: .accepted, record: try companionCalendarSnapshot().records.first { $0.id == item.id })
      }
      if result.status == .accepted, before == nil {
        // An event may run and then be converted or deleted entirely offline.
        // Its creator can still publish those immutable historical receipts.
        try toolsExecuteUnlocked("INSERT OR IGNORE INTO companion_calendar_run_owners(event_id,device_id) VALUES(?,?)", [mutation.record.id, deviceID])
      }
      try toolsExecuteUnlocked("INSERT INTO companion_calendar_receipts(device_id,mutation_id,input_json,result_json) VALUES(?,?,?,?)",
        [deviceID, mutation.id, input, String(decoding: try encoder.encode(result), as: UTF8.self)])
      return result
    }
  }
  func companionCalendarPublishRuns(_ runs: [CompanionCalendarRun], deviceID: String) throws -> [String] {
    guard runs.count <= 200 else { throw CompanionCalendarError.invalid }
    return try transaction {
      let permittedEvents = Set(try historyRowsUnlocked("SELECT event_id FROM companion_calendar_run_owners WHERE device_id=?", values: [deviceID]).compactMap { $0.objectValue?["event_id"]?.stringValue })
      for run in runs {
        guard run.ownerDeviceID == deviceID, permittedEvents.contains(run.eventID),
          UUID(uuidString: run.id) != nil, UUID(uuidString: run.sessionID) != nil,
          run.occurrence >= 0, run.scheduledAt.timeIntervalSince1970.isFinite,
          ["pending", "running", "completed", "failed", "cancelled", "accepted", "uncertain", "queued", "sending"].contains(run.status) else { throw CompanionCalendarError.invalid }
        if let json = try historyRowsUnlocked("SELECT payload_json FROM companion_calendar_runs WHERE id=?", values: [run.id]).first?.objectValue?["payload_json"]?.stringValue {
          var old = try JSONDecoder().decode(CompanionCalendarRun.self, from: Data(json.utf8))
          let previousRevision = old.revision ?? 0
          if previousRevision == (run.revision ?? 0), old != run { throw CompanionCalendarError.requestMismatch }
          old.status = run.status; old.error = run.error; old.revision = run.revision
          guard old == run else { throw CompanionCalendarError.requestMismatch }
          // A delayed network retry cannot regress a completed receipt to the
          // earlier running or pending status from the same device.
          if previousRevision > (run.revision ?? 0) { continue }
        }
        try toolsExecuteUnlocked("INSERT INTO companion_calendar_runs(id,event_id,device_id,payload_json) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload_json=excluded.payload_json",
          [run.id, run.eventID, deviceID, try toolsJSON(run)])
      }
      return runs.map(\.id)
    }
  }
  static func nativeCalendarDraft(_ value: CompanionCalendarDraft) throws -> WorkspaceCalendarDraft {
    var draft = WorkspaceCalendarDraft(title: value.title, details: value.details, startsAt: value.startsAt, endsAt: value.endsAt,
      allDay: value.allDay, timeZoneID: value.timeZoneID, showsOnCalendar: value.showsOnCalendar ?? true)
    if let unit = value.recurrenceUnit {
      guard let native = WorkspaceCalendarRecurrence.Unit(rawValue: unit) else { throw CompanionCalendarError.invalid }
      draft.recurrence = .init(unit: native, interval: value.recurrenceInterval)
    }
    if let task = value.task {
      guard let runtime = AgentRuntimeKind(rawValue: task.runtime), task.workspaceID == nil || UUID(uuidString: task.workspaceID!) != nil else { throw CompanionCalendarError.invalid }
      draft.task = .init(prompt: task.prompt, configuration: .init(runtimeKind: runtime, workspaceID: task.workspaceID.flatMap(UUID.init), folderID: task.folderID,
        title: value.title, model: task.model, thinking: task.thinking, permission: task.permission,
        tools: task.enabledTools.map { .init(enabled: Set($0.compactMap { WorkspaceToolGroup(rawValue: $0.replacingOccurrences(of: "wovenmatter_", with: "")) })) } ?? .init()), sessionMode: task.newSessionEachTime ? .new : .same)
    }
    return try draft.validated()
  }
  static func calendarReplica(_ item: WorkspaceCalendarItemRecord, owner: String?, deleted: Bool, enabledTools: [String]? = nil) -> CompanionCalendarRecord {
    let draft = WorkspaceCalendarDraft(item)
    return .init(event: .init(id: item.id, revision: item.calendar.revision, draft: .init(title: draft.title, details: draft.details,
      startsAt: draft.startsAt, endsAt: draft.endsAt, allDay: draft.allDay, timeZoneID: draft.timeZoneID,
      recurrenceUnit: draft.recurrence?.unit.rawValue, recurrenceInterval: draft.recurrence?.interval ?? 1,
      task: draft.task.map { task in .init(prompt: task.prompt, runtime: task.configuration.runtimeKind.rawValue,
        workspaceID: task.configuration.workspaceID?.uuidString.lowercased(), model: task.configuration.model, thinking: task.configuration.thinking,
        permission: task.configuration.permission, folderID: task.configuration.folderID, newSessionEachTime: task.sessionMode == .new, enabledTools: enabledTools) }, showsOnCalendar: draft.showsOnCalendar)),
      excludedOccurrences: item.calendar.excludedOccurrences, ownerDeviceID: owner, deleted: deleted)
  }
}

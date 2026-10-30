import Foundation
import WovenMatterCore

extension WorkspaceDatabase {
  public func projectExecutionCalendar(_ record: CompanionCalendarRecord, expectedRevision: Int?, libraryID: String, workspaceID: String) async throws -> CompanionCalendarRecord {
    try await write { try $0.projectExecutionCalendar(record, expectedRevision: expectedRevision, libraryID: libraryID, workspaceID: workspaceID) }
  }
  public func executionCalendarSnapshot(libraryID: String, workspaceID: String) async throws -> CompanionCalendarSnapshot {
    try await write { connection in
      try connection.transaction {
        try connection.bindExecutionCalendar(libraryID: libraryID, workspaceID: workspaceID)
        return try connection.executionCalendarSnapshot(workspaceID: workspaceID)
      }
    }
  }
  public func setExecutionCalendarConflicts(ids: Set<String>, libraryID: String, workspaceID: String) async throws {
    try await write { connection in
      try connection.transaction {
        try connection.bindExecutionCalendar(libraryID: libraryID, workspaceID: workspaceID)
        try connection.toolsExecuteUnlocked("DELETE FROM companion_calendar_execution_conflicts", [])
        for id in ids { try connection.toolsExecuteUnlocked("INSERT INTO companion_calendar_execution_conflicts(event_id) VALUES(?)", [id]) }
      }
    }
  }
  public func executionCalendarRuns(workspaceID: String) async throws -> [CompanionCalendarRun] {
    try await read { try $0.executionCalendarRuns(workspaceID: workspaceID) }
  }
}
extension WorkspaceDatabaseConnection {
  func calendarForeignExecutionEventIDs() throws -> Set<String> {
    let localID = try historyRowsUnlocked("SELECT workspace_id FROM companion_calendar_execution_context WHERE singleton=1", values: []).first?.objectValue?["workspace_id"]?.stringValue ?? companionLibraryIdentityUnlocked().hostDeviceID
    let conflicts = try historyRowsUnlocked("SELECT event_id FROM companion_calendar_execution_conflicts", values: []).compactMap { $0.objectValue?["event_id"]?.stringValue }
    return Set(try calendarReplicaOwners().filter { $0.value != localID }.map(\.key)).union(conflicts)
  }
  func bindExecutionCalendar(libraryID: String, workspaceID: String) throws {
    guard UUID(uuidString: workspaceID) != nil, !libraryID.isEmpty, workspaceID != (try companionWorkspaceID()), libraryID != (try companionWorkspaceID()) else { throw CompanionCalendarError.wrongWorkspace }
    if let context = try historyRowsUnlocked("SELECT library_id,workspace_id FROM companion_calendar_execution_context WHERE singleton=1", values: []).first?.objectValue {
      guard context["library_id"]?.stringValue == libraryID, context["workspace_id"]?.stringValue == workspaceID else { throw CompanionCalendarError.wrongWorkspace }
    } else { try toolsExecuteUnlocked("INSERT INTO companion_calendar_execution_context(singleton,library_id,workspace_id) VALUES(1,?,?)", [libraryID, workspaceID]) }
  }
  func executionCalendarSnapshot(workspaceID: String) throws -> CompanionCalendarSnapshot {
    var snapshot = try companionCalendarSnapshot()
    let native = Dictionary(uniqueKeysWithValues: try calendarItemsUnlocked(includeDeleted: true).map { ($0.id, $0) })
    for index in snapshot.records.indices {
      let record = snapshot.records[index]
      if record.ownerDeviceID == nil || record.ownerDeviceID == workspaceID,
        let tools = native[record.id]?.calendar.task?.configuration.tools {
        snapshot.records[index].event.draft.task?.enabledTools = tools.enabled.map { "wovenmatter_" + $0.rawValue }.sorted()
      }
    }
    return snapshot
  }
  func projectExecutionCalendar(_ record: CompanionCalendarRecord, expectedRevision: Int?, libraryID: String, workspaceID: String) throws -> CompanionCalendarRecord {
    return try transaction {
      try bindExecutionCalendar(libraryID: libraryID, workspaceID: workspaceID)
      let current = try executionCalendarSnapshot(workspaceID: workspaceID).records.first { $0.id == record.id }
      var desired = record
      let localOwner = record.ownerDeviceID == workspaceID
      // The native runtime executes this Mac's task as local; its replicated
      // identity still identifies the owning device on the central Mac.
      if localOwner, desired.event.draft.task?.workspaceID == workspaceID { desired.event.draft.task?.workspaceID = nil }
      desired.ownerDeviceID = record.event.draft.task == nil ? nil : record.ownerDeviceID ?? "central"
      desired.event.draft = try CompanionCalendarSchedule.normalized(desired.event.draft)
      desired.event.draft.showsOnCalendar = desired.event.draft.showsOnCalendar ?? true
      desired.event.draft.startsAt = Self.date(Self.timestamp(desired.event.draft.startsAt))!
      desired.event.draft.endsAt = desired.event.draft.endsAt.map { Self.date(Self.timestamp($0))! }
      desired.event.startsAt = Self.date(Self.timestamp(desired.event.startsAt))!
      if localOwner, desired.event.draft.task?.enabledTools == nil {
        desired.event.draft.task?.enabledTools = WorkspaceSessionTools().enabled.map { "wovenmatter_" + $0.rawValue }.sorted()
      }
      var normalizedCurrent = current, normalizedDesired = Optional(desired)
      normalizedCurrent?.event.revision = 0; normalizedDesired?.event.revision = 0
      if normalizedCurrent == normalizedDesired { return current! }
      guard current?.event.revision == expectedRevision else { throw CompanionCalendarError.conflict }
      if desired.deleted {
        if let current, !current.deleted { try deleteCalendarEvent(id: record.id, expectedRevision: current.event.revision, _transaction: false) }
        if current == nil {
          _ = try saveCalendarEvent(id: record.id, draft: Self.nativeCalendarDraft(desired.event.draft), creating: true, _transaction: false)
          try deleteCalendarEvent(id: record.id, _transaction: false)
        }
      } else {
        guard current?.deleted != true else { throw CompanionCalendarError.conflict }
        var draft = try Self.nativeCalendarDraft(desired.event.draft)
        if let existing = try calendarItemsUnlocked().first(where: { $0.id == record.id }), localOwner,
          let prior = existing.calendar.task?.configuration, var task = draft.task,
          prior.runtimeKind == task.configuration.runtimeKind, prior.workspaceID == task.configuration.workspaceID {
          // Shared calendar fields never erase a Mac runtime's workspace path,
          // permission defaults or selected Executor profiles.
          var configuration = prior
          configuration.title = task.configuration.title; configuration.model = task.configuration.model
          configuration.thinking = task.configuration.thinking; configuration.permission = task.configuration.permission
          configuration.folderID = task.configuration.folderID
          if desired.event.draft.task?.enabledTools != nil { configuration.tools.enabled.formIntersection(task.configuration.tools.enabled) }
          task.configuration = configuration; draft.task = task
        }
        _ = try saveCalendarEvent(id: record.id, draft: draft, creating: current == nil, expectedRevision: expectedRevision, _transaction: false)
        guard let saved = try calendarItemsUnlocked().first(where: { $0.id == record.id }) else { throw CompanionCalendarError.missing }
        var details = saved.calendar; details.excludedOccurrences = desired.excludedOccurrences
        try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET calendar_json=? WHERE id=?", [try toolsJSON(details), record.id])
      }
      let tools = try desired.event.draft.task?.enabledTools.map { try toolsJSON($0) }
      if let owner = desired.ownerDeviceID {
        try toolsExecuteUnlocked("INSERT INTO companion_calendar_owners(event_id,device_id,tools_json) VALUES(?,?,?) ON CONFLICT(event_id) DO UPDATE SET device_id=excluded.device_id,tools_json=excluded.tools_json", [record.id, owner, tools])
      } else { try toolsExecuteUnlocked("DELETE FROM companion_calendar_owners WHERE event_id=?", [record.id]) }
      guard let result = try executionCalendarSnapshot(workspaceID: workspaceID).records.first(where: { $0.id == record.id }) else { throw CompanionCalendarError.missing }
      return result
    }
  }
  func executionCalendarRuns(workspaceID: String) throws -> [CompanionCalendarRun] {
    let foreign = Set(try calendarReplicaOwners().filter { $0.value != workspaceID }.map(\.key))
    return try calendarRunsUnlocked().filter { !foreign.contains($0.eventID) }.map { run in
      let task = run.task.configuration
      return .init(id: run.id, eventID: run.eventID, eventRevision: 0, ownerDeviceID: workspaceID,
        occurrence: run.occurrenceIndex, scheduledAt: run.scheduledAt, sessionID: run.sessionID,
        task: .init(prompt: run.task.prompt, runtime: task.runtimeKind.rawValue, workspaceID: task.workspaceID?.uuidString.lowercased() ?? workspaceID,
          model: task.model, thinking: task.thinking, permission: task.permission, folderID: task.folderID,
          newSessionEachTime: run.task.sessionMode == .new, enabledTools: task.tools.enabled.map { "wovenmatter_" + $0.rawValue }.sorted()),
        title: run.title, status: run.status, error: run.error)
    }
  }
}

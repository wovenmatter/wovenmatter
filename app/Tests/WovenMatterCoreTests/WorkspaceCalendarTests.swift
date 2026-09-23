import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Calendar events, recurrence and scheduled sessions")
struct WorkspaceCalendarTests {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func fixture() throws -> (WorkspaceDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "wm-calendar-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite")), directory)
  }
  private func task(mode: WorkspaceCalendarTask.SessionMode = .same) -> WorkspaceCalendarTask {
    .init(prompt: "Review the project", configuration: .init(runtimeKind: .codex, title: "Review",
      model: "fixture-model", thinking: "high", permission: "read-only", nativeWorkingDirectory: "/tmp/project",
      tools: .init(enabled: [.notes, .calendar])), sessionMode: mode)
  }
  private func insert(_ db: WorkspaceDatabase, start: Date, repeatRule: WorkspaceCalendarRecurrence? = nil,
                      mode: WorkspaceCalendarTask.SessionMode = .same) throws -> String {
    try db.saveCalendarEvent(draft: .init(title: "Review", startsAt: start, timeZoneID: "America/New_York",
      recurrence: repeatRule, task: task(mode: mode)), creating: true, now: start)
  }
  private func accept(_ run: WorkspaceCalendarRun, in db: WorkspaceDatabase, now: Date) throws {
    if (try? db.localACPSession(conversationID: run.sessionID)) == nil {
      _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Temporary title", ownerDeviceID: UUID(),
        requestedConversationID: UUID(uuidString: run.sessionID))
    }
    _ = try db.prepareCalendarDelivery(runID: run.id, now: now)
    #expect(try db.claimToolDelivery(id: run.id, now: now) != nil)
    try db.setToolDeliveryStatus(id: run.id, status: "accepted")
    try db.settleCalendarRuns()
  }

  @Test func recurrencePreservesWallClockAndMonthAnchor() throws {
    let monthly = WorkspaceCalendarRecurrence(unit: .month)
    let start = date("2026-01-31T14:00:00Z")
    #expect(WorkspaceCalendarSchedule.date(index: 1, start: start, recurrence: monthly, timeZoneID: "America/New_York") == date("2026-02-28T14:00:00Z"))
    #expect(WorkspaceCalendarSchedule.date(index: 2, start: start, recurrence: monthly, timeZoneID: "America/New_York") == date("2026-03-31T13:00:00Z"))
    let daily = WorkspaceCalendarRecurrence(unit: .day)
    #expect(WorkspaceCalendarSchedule.date(index: 1, start: date("2026-03-07T14:00:00Z"), recurrence: daily, timeZoneID: "America/New_York") == date("2026-03-08T13:00:00Z"))
    #expect(WorkspaceCalendarSchedule.date(index: 1, start: date("2026-10-31T13:00:00Z"), recurrence: daily, timeZoneID: "America/New_York") == date("2026-11-01T14:00:00Z"))
    #expect(WorkspaceCalendarSchedule.date(index: 2, start: start, recurrence: .init(unit: .day, interval: 3), timeZoneID: "UTC") == start.addingTimeInterval(6 * 86_400))
  }

  @Test func allDayAndMultiDayEventsOverlapTheirVisibleDays() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let draft = WorkspaceCalendarDraft(title: "Trip", startsAt: date("2026-09-20T14:00:00Z"), endsAt: date("2026-09-23T14:00:00Z"),
      allDay: true, timeZoneID: "America/New_York")
    try db.saveCalendarEvent(draft: draft, creating: true)
    let event = try #require(db.calendarItems().first)
    #expect(event.startDate == date("2026-09-20T04:00:00Z"))
    #expect(event.endDate == date("2026-09-23T04:00:00Z"))
    let middle = DateInterval(start: date("2026-09-21T04:00:00Z"), end: date("2026-09-22T04:00:00Z"))
    #expect(WorkspaceCalendarSchedule.occurrences(event, in: middle).count == 1)
    let after = DateInterval(start: date("2026-09-23T04:00:00Z"), end: date("2026-09-24T04:00:00Z"))
    #expect(WorkspaceCalendarSchedule.occurrences(event, in: after).isEmpty)
    var viewer = Calendar(identifier: .gregorian); viewer.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let occurrence = try #require(WorkspaceCalendarSchedule.occurrence(event, index: 0))
    #expect(occurrence.displayInterval(in: viewer).start == date("2026-09-20T07:00:00Z"))
    let movedZone = occurrence.draft.changingTimeZone(to: "America/Los_Angeles")
    #expect(movedZone.startsAt == date("2026-09-20T07:00:00Z"))
    #expect(movedZone.endsAt == date("2026-09-23T07:00:00Z"))
    #expect(movedZone.changingTimeZone(to: "UTC").startsAt == date("2026-09-20T00:00:00Z"))
    #expect(occurrence.draft.copied(to: date("2026-09-25T07:00:00Z"), calendar: viewer).startsAt == date("2026-09-25T04:00:00Z"))
    var invalid = draft; invalid.task = task()
    #expect(throws: (any Error).self) { try invalid.validated() }
  }

  @Test func everyOverdueOneOffAndOneRecurringCatchUpSurviveReopen() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    for offset in 0..<5 { _ = try insert(db, start: start.addingTimeInterval(Double(offset) * 86_400)) }
    let series = try insert(db, start: start, repeatRule: .init(unit: .day))
    let now = date("2026-09-06T14:00:00Z")
    let runs = try db.dueCalendarRuns(now: now)
    #expect(runs.count == 6)
    #expect(runs.filter { $0.eventID == series }.count == 1)
    #expect(runs.first { $0.eventID == series }?.scheduledAt == date("2026-09-06T13:00:00Z"))
    let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    #expect(Set(try reopened.dueCalendarRuns(now: now).map(\.id)) == Set(runs.map(\.id)))
    for run in runs { try accept(run, in: reopened, now: now) }
    #expect(try reopened.dueCalendarRuns(now: now).isEmpty)
    #expect(try reopened.calendarRuns().allSatisfy { $0.status == "accepted" })
  }

  @Test func schedulingUsesTheSamePrecisionAsPersistedDates() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z").addingTimeInterval(0.123456)
    let id = try insert(db, start: start)
    let run = try #require(db.dueCalendarRuns(now: start.addingTimeInterval(1)).first)
    #expect(run.eventID == id)
  }

  @Test(arguments: [WorkspaceCalendarTask.SessionMode.same, .new])
  func recurringSessionChoiceIsDurable(mode: WorkspaceCalendarTask.SessionMode) throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try insert(db, start: start, repeatRule: .init(unit: .day), mode: mode)
    let first = try #require(db.dueCalendarRuns(now: start).first)
    try accept(first, in: db, now: start)
    let second = try #require(db.dueCalendarRuns(now: start.addingTimeInterval(86_400)).first)
    #expect((first.sessionID == second.sessionID) == (mode == .same))
    #expect(first.id != second.id)
    #expect(try db.toolSessionCreationConfiguration(targetID: second.sessionID)?.model == "fixture-model")
    #expect(try db.sessionTools(first.sessionID).enabled == [.notes, .calendar])
    #expect(try db.workspaceOverview().conversations.first { $0.id == first.sessionID }?.title == "Review")
  }

  @Test func detachingRetainsSettingsAndSuppressesOnlyOriginalOccurrence() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try insert(db, start: start, repeatRule: .init(unit: .day))
    let event = try #require(db.calendarItems().first)
    let occurrence = try #require(WorkspaceCalendarSchedule.occurrence(event, index: 2))
    var draft = occurrence.draft; draft.title = "Special review"; draft.task?.prompt = "Review the release"
    let detachedID = try db.saveCalendarEvent(id: id, draft: draft, creating: false, expectedRevision: 0,
      detaching: 2, now: start)
    let saved = try db.calendarItems()
    let series = try #require(saved.first { $0.id == id }), detached = try #require(saved.first { $0.id == detachedID })
    #expect(series.calendar.excludedOccurrences == [2])
    #expect(detached.calendar.recurrence == nil)
    #expect(detached.calendar.task?.configuration.model == "fixture-model")
    #expect(detached.calendar.task?.configuration.permission == "read-only")
    #expect(detached.calendar.task?.prompt == "Review the release")
    #expect(WorkspaceCalendarSchedule.occurrence(series, index: 2) == nil)
    #expect(WorkspaceCalendarSchedule.occurrence(series, index: 3) != nil)
    let due = try db.dueCalendarRuns(now: occurrence.startsAt)
    #expect(due.contains { $0.eventID == detachedID })
    #expect(!due.contains { $0.eventID == id && $0.scheduledAt == occurrence.startsAt })
  }

  @Test func attributionRevisionAndCopyHaveIndependentIdentity() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let caller = try db.createLocalACPSession(runtimeKind: .claudeCode, title: "Planning", ownerDeviceID: UUID())
    let start = date("2026-09-01T13:00:00Z")
    let id = try db.saveCalendarEvent(draft: .init(title: "Plan", startsAt: start, recurrence: .init(unit: .week)), creating: true, callerID: caller)
    let original = try db.calendarEvent(id: id, callerID: caller)
    #expect(original.calendar.createdBy.agent == "claude_code")
    #expect(original.calendar.createdBy.sessionTitle == "Planning")
    var draft = WorkspaceCalendarDraft(original); draft.details = "Updated by the user"
    try db.saveCalendarEvent(id: id, draft: draft, creating: false, expectedRevision: 0)
    let edited = try db.calendarEvent(id: id, callerID: caller)
    #expect(edited.calendar.createdBy == original.calendar.createdBy)
    #expect(edited.calendar.editedBy == WorkspaceCalendarAuthor())
    #expect(edited.calendar.revision == 1)
    #expect(throws: (any Error).self) { try db.saveCalendarEvent(id: id, draft: draft, creating: false, expectedRevision: 0) }
    let copied = draft.copied(to: start.addingTimeInterval(86_400))
    #expect(copied.recurrence == nil)
    let copiedID = try db.saveCalendarEvent(draft: copied, creating: true)
    #expect(copiedID != id)
    #expect(try db.calendarEvent(id: copiedID, callerID: caller).calendar.createdBy.sessionID == nil)
  }

  @Test func deletionAndEditsCancelPreparedDeliveriesWithoutDeletingSessions() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try insert(db, start: start)
    let run = try #require(db.dueCalendarRuns(now: start).first)
    _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try db.prepareCalendarDelivery(runID: run.id, now: start)
    try db.deleteCalendarEvent(id: id)
    #expect(try !db.isCalendarRunActive(run.id))
    #expect(try db.claimToolDelivery(id: run.id, now: start) == nil)
    #expect(try db.dueCalendarRuns(now: start).isEmpty)
    #expect(try db.workspaceOverview().conversations.contains { $0.id == run.sessionID })
    #expect(try db.dashboardRecordCounts().calendarItems == 0)
  }

  @Test func pendingNativeAcceptanceIsNeverAutomaticallySubmittedAgain() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try #require(db.dueCalendarRuns(now: start).first)
    _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try db.prepareCalendarDelivery(runID: run.id, now: start)
    _ = try db.claimToolDelivery(id: run.id, now: start)
    try db.markToolDeliveryTransportStarted(id: run.id)
    let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    try reopened.recoverToolDeliveries()
    #expect(try reopened.calendarRuns().first?.status == "uncertain")
    try reopened.settleCalendarRuns()
    #expect(try reopened.dueCalendarRuns(now: start).isEmpty)
    let next = try #require(reopened.dueCalendarRuns(now: start.addingTimeInterval(5 * 86_400)).first)
    #expect(next.id != run.id)
    #expect(next.scheduledAt == start.addingTimeInterval(5 * 86_400))
    #expect(try reopened.claimToolDelivery(id: run.id) == nil)
  }
}

extension WorkspaceCalendarTests {
  @Test func detachedAcceptedRunKeepsItsSessionEvenBeforeSettlement() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try #require(db.dueCalendarRuns(now: start).first)
    _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try db.prepareCalendarDelivery(runID: run.id, now: start)
    _ = try db.claimToolDelivery(id: run.id, now: start)
    try db.setToolDeliveryStatus(id: run.id, status: "accepted")
    let event = try #require(db.calendarItems().first)
    let detachedID = try db.saveCalendarEvent(id: id, draft: WorkspaceCalendarDraft(event), creating: false, detaching: 0, now: start)
    try db.settleCalendarRuns()
    let saved = try #require(db.calendarRuns().first)
    #expect(saved.eventID == detachedID && saved.sessionID == run.sessionID)
    #expect(try db.dueCalendarRuns(now: start).isEmpty)
  }

  @Test func restartAfterAcceptanceStillCatchesUpTheNextMissedOccurrence() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try #require(db.dueCalendarRuns(now: start).first)
    _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try db.prepareCalendarDelivery(runID: run.id, now: start)
    _ = try db.claimToolDelivery(id: run.id, now: start)
    try db.setToolDeliveryStatus(id: run.id, status: "accepted")
    let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let now = start.addingTimeInterval(5 * 86_400)
    try reopened.settleCalendarRuns()
    let next = try #require(reopened.dueCalendarRuns(now: now).first)
    #expect(next.scheduledAt == now && next.id != run.id)
    try accept(next, in: reopened, now: now)
    #expect(try reopened.dueCalendarRuns(now: now).isEmpty)
  }

  @Test @MainActor func runtimeWaitsForCapacityAndBusySessionsAndRechecksAfterPreparation() async throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let deletedID = try insert(db, start: start)
    let busyID = try insert(db, start: start)
    let healthyID = try insert(db, start: start)
    let runs = try db.dueCalendarRuns(now: start)
    let busySession = try #require(runs.first { $0.eventID == busyID }?.sessionID)
    var prepared: [String] = [], delivered: [String] = []
    var busy = true
    func prepare(_ run: WorkspaceCalendarRun) throws {
      prepared.append(run.eventID)
      _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
      if run.eventID == deletedID { try db.deleteCalendarEvent(id: deletedID, now: start) }
    }
    func dispatch(_ delivery: WorkspaceSessionDelivery) throws {
      delivered.append(delivery.targetID)
      _ = try db.claimToolDelivery(id: delivery.id, now: start)
      try db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    }
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { _ in false }, hasCapacity: { false }, prepare: prepare, dispatch: dispatch)
    #expect(prepared.isEmpty && delivered.isEmpty)
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { busy && $0 == busySession }, hasCapacity: { true }, prepare: prepare, dispatch: dispatch)
    #expect(Set(prepared) == [deletedID, healthyID])
    #expect(delivered.count == 1)
    #expect(try db.calendarRuns().first { $0.eventID == deletedID }?.status == "cancelled")
    busy = false
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { busy && $0 == busySession }, hasCapacity: { true }, prepare: { run in
      try prepare(run)
      busy = true // User starts a turn during the awaited native setup.
    }, dispatch: dispatch)
    #expect(delivered.count == 1)
    busy = false
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { _ in false }, hasCapacity: { true }, prepare: { _ in }, dispatch: dispatch)
    #expect(delivered.count == 2 && delivered.contains(busySession))
  }

  @Test @MainActor func runtimePreparationFailureDoesNotBlockOtherEventsAndRetriesWithStableIdentity() async throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let failedID = try insert(db, start: start)
    _ = try insert(db, start: start)
    let original = try #require(db.dueCalendarRuns(now: start).first { $0.eventID == failedID })
    func create(_ run: WorkspaceCalendarRun) throws {
      _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    }
    func dispatch(_ delivery: WorkspaceSessionDelivery) throws {
      _ = try db.claimToolDelivery(id: delivery.id, now: start.addingTimeInterval(31))
      try db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    }
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { _ in false }, hasCapacity: { true }, prepare: { run in
      if run.eventID == failedID { throw WorkspaceToolError.invalid("Workspace offline") }
      try create(run)
    }, dispatch: dispatch)
    #expect(try db.calendarRuns().filter { $0.status == "accepted" }.count == 1)
    #expect(try db.dueCalendarRuns(now: start.addingTimeInterval(29)).isEmpty)
    let retry = try #require(db.dueCalendarRuns(now: start.addingTimeInterval(31)).first)
    #expect(retry.id == original.id && retry.sessionID == original.sessionID)
    #expect(retry.error == "Workspace offline")
    try await CalendarTaskRunner.tick(database: db, now: start.addingTimeInterval(31), isRunning: { _ in false }, hasCapacity: { true }, prepare: create, dispatch: dispatch)
    #expect(try db.calendarRuns().allSatisfy { $0.status == "accepted" })
  }
}

extension WorkspaceCalendarTests {
  @Test @MainActor func busyBacklogDoesNotStarveReadyTasks() async throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    for _ in 0..<20 { _ = try insert(db, start: start) }
    let readyID = try insert(db, start: start.addingTimeInterval(1))
    let now = start.addingTimeInterval(2)
    let runs = try db.dueCalendarRuns(now: now)
    let busy = Set(runs.filter { $0.eventID != readyID }.map(\.sessionID))
    var delivered: [String] = []
    try await CalendarTaskRunner.tick(database: db, now: now, isRunning: { busy.contains($0) }, hasCapacity: { true }, prepare: { run in
      _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Ready", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    }, dispatch: { delivery in
      delivered.append(delivery.id)
      _ = try db.claimToolDelivery(id: delivery.id, now: now)
      try db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    })
    #expect(delivered == runs.filter { $0.eventID == readyID }.map(\.id))
  }

  @Test @MainActor func queuedRetryReappliesSettingsAndHonorsTransportBackoff() async throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try insert(db, start: start)
    let run = try #require(db.dueCalendarRuns(now: start).first)
    _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try db.prepareCalendarDelivery(runID: run.id, now: start)
    _ = try db.claimToolDelivery(id: run.id, now: start)
    try db.failToolDeliveryAttempt(id: run.id, now: start)
    #expect(try db.dueCalendarRuns(now: start.addingTimeInterval(29)).isEmpty)
    try db.setSessionTools(.init(enabled: []), sessionID: run.sessionID)
    var preparations = 0
    let now = start.addingTimeInterval(31)
    try await CalendarTaskRunner.tick(database: db, now: now, isRunning: { _ in false }, hasCapacity: { true }, prepare: { retry in
      preparations += 1
      #expect(retry.id == run.id && retry.sessionID == run.sessionID)
      try db.setSessionTools(retry.task.configuration.tools, sessionID: retry.sessionID)
    }, dispatch: { delivery in
      #expect(try db.sessionTools(delivery.targetID).enabled == [.notes, .calendar])
      _ = try db.claimToolDelivery(id: delivery.id, now: now)
      try db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    })
    #expect(preparations == 1)
    #expect(try db.calendarRuns().first?.status == "accepted")
  }

  @Test func invalidOccurrenceRemovalAndDeletedIDReuseDoNotMutateEvents() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try insert(db, start: start)
    #expect(throws: (any Error).self) { try db.deleteCalendarEvent(id: id, occurrence: 2) }
    let event = try #require(db.calendarItems().first)
    #expect(event.id == id)
    try db.deleteCalendarEvent(id: id)
    #expect(throws: (any Error).self) {
      try db.saveCalendarEvent(id: id, draft: WorkspaceCalendarDraft(event), creating: true)
    }
    #expect(try db.calendarItems().isEmpty)
  }

  @Test func pastRunsRemainDistinctFromChangedOccurrencesAndKeepTheirSavedSettings() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try #require(db.dueCalendarRuns(now: start).first)
    try accept(run, in: db, now: start)
    var draft = WorkspaceCalendarDraft(try #require(db.calendarItems().first))
    draft.title = "New schedule"; draft.startsAt = start.addingTimeInterval(3_600)
    draft.task?.prompt = "New instructions"
    try db.saveCalendarEvent(id: id, draft: draft, creating: false, now: start.addingTimeInterval(3_601))
    let entries = WorkspaceCalendarSchedule.visibleOccurrences(events: try db.calendarItems(), runs: try db.calendarRuns(),
      in: .init(start: start.addingTimeInterval(-1), end: start.addingTimeInterval(86_400)))
    #expect(entries.count == 2)
    let past = try #require(entries.first { $0.recordedRun != nil })
    #expect(past.title == "Review" && past.draft.task?.prompt == "Review the project")
    #expect(past.recordedRun?.sessionID == run.sessionID)
    let current = try #require(entries.first { $0.recordedRun == nil })
    #expect(current.title == "New schedule" && current.draft.task?.prompt == "New instructions")
    // Detaching the live occurrence does not steal an earlier run's session link.
    let detached = try db.saveCalendarEvent(id: id, draft: current.draft, creating: false, detaching: current.index,
      now: start.addingTimeInterval(3_601))
    #expect(try db.calendarRuns().first?.eventID == id)
    #expect(detached != id)
  }
}

extension WorkspaceCalendarTests {
  @Test func deletingCompletedOccurrenceHidesItsEntryAndPreservesExecutionHistory() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try #require(db.dueCalendarRuns(now: start).first)
    try accept(run, in: db, now: start)
    try db.deleteCalendarEvent(id: id, occurrence: 0)
    let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let entries = WorkspaceCalendarSchedule.visibleOccurrences(events: try reopened.calendarItems(), runs: try reopened.calendarRuns(),
      in: .init(start: start.addingTimeInterval(-1), end: start.addingTimeInterval(1)))
    #expect(entries.isEmpty)
    #expect(try reopened.calendarRunsUnlocked(eventID: id).first?.status == "accepted")
    #expect(try reopened.toolDelivery(id: run.id)?.status == "accepted")
    #expect(try reopened.workspaceOverview().conversations.contains { $0.id == run.sessionID })
    #expect(try reopened.dueCalendarRuns(now: start).isEmpty)
    #expect(try reopened.dueCalendarRuns(now: start.addingTimeInterval(86_400)).count == 1)
  }

  @Test func calendarBacklogDoesNotDisplaceOtherDeliveryKinds() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try insert(db, start: start)
    let run = try #require(db.dueCalendarRuns(now: start).first)
    _ = try db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try db.prepareCalendarDelivery(runID: run.id, now: start)
    let source = try db.createLocalACPSession(runtimeKind: .codex, title: "Sender", ownerDeviceID: UUID())
    let delivery = try db.reserveToolDelivery(sourceID: source, targetID: run.sessionID, text: "Regular message", requestID: UUID().uuidString.lowercased())
    #expect(try db.sessionDeliveries(queuedOnly: true, limit: 1, includeCalendar: false).map(\.id) == [delivery.id])
  }

  @Test func legacyEventsMigrateWithoutLosingContentOrAgentAttribution() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let caller = try db.createLocalACPSession(runtimeKind: .codex, title: "Planner", ownerDeviceID: UUID())
    let start = date("2026-09-01T13:00:00Z")
    let id = try db.saveAgentCalendar(callerID: caller, creating: true, title: "Legacy event", details: "Preserve this description",
      startsAt: start, endsAt: start.addingTimeInterval(3_600), allDay: false)
    // Recreate the pre-feature schema around an existing native event.
    try db.transaction {
      try db.executeUnlocked("""
        DROP TABLE workspace_calendar_runs;
        DROP TABLE workspace_calendar_sessions;
        DROP INDEX workspace_calendar_due;
        ALTER TABLE dashboard_calendar_items DROP COLUMN calendar_json;
        ALTER TABLE dashboard_calendar_items DROP COLUMN next_fire_at;
        ALTER TABLE dashboard_calendar_items DROP COLUMN task_session_id;
        ALTER TABLE dashboard_calendar_items DROP COLUMN deleted_at;
        """)
    }
    let migrated = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let event = try #require(migrated.calendarItems().first)
    #expect(event.id == id && event.title == "Legacy event" && event.details == "Preserve this description")
    #expect(event.startDate == start && event.endDate == start.addingTimeInterval(3_600))
    #expect(event.calendar.createdBy.sessionID == caller && event.calendar.createdBy.agent == "codex")
    #expect(event.calendar.task == nil && event.calendar.recurrence == nil)
    #expect(try migrated.dueCalendarRuns(now: start.addingTimeInterval(86_400)).isEmpty)
    let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    #expect(try reopened.calendarItems().first == event)
  }
}

extension WorkspaceCalendarTests {
  @Test func replacingCancelledSlotUsesTheNewOccurrenceIdentity() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try insert(db, start: start, repeatRule: .init(unit: .day))
    let cancelled = try #require(db.dueCalendarRuns(now: start).first)
    try db.deleteCalendarEvent(id: id, occurrence: 0)
    var draft = WorkspaceCalendarDraft(try #require(db.calendarItems().first))
    draft.startsAt = start.addingTimeInterval(-86_400)
    try db.saveCalendarEvent(id: id, draft: draft, creating: false, now: start)
    let replacement = try #require(db.dueCalendarRuns(now: start).first)
    #expect(replacement.id != cancelled.id)
    #expect(replacement.scheduledAt == cancelled.scheduledAt)
    #expect(replacement.occurrenceIndex == 1)
    #expect(try db.calendarRuns().first?.id == replacement.id)
    try accept(replacement, in: db, now: start)
    #expect(try db.dueCalendarRuns(now: start).isEmpty)
  }
}

extension WorkspaceCalendarTests {
  @Test func editingAnUncreatedRecurringSessionUpdatesItsInsertionSettings() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try insert(db, start: start, repeatRule: .init(unit: .day))
    let original = try #require(db.dueCalendarRuns(now: start).first)
    let folder = try db.createFolder(name: "Updated destination")
    var draft = WorkspaceCalendarDraft(try #require(db.calendarItems().first))
    draft.title = "Updated task"
    draft.task?.configuration.folderID = folder
    draft.task?.configuration.tools = .init(enabled: [.notes])
    try db.saveCalendarEvent(id: id, draft: draft, creating: false, now: start)
    let replacement = try #require(db.dueCalendarRuns(now: start).first)
    #expect(replacement.sessionID == original.sessionID && replacement.id != original.id)
    try accept(replacement, in: db, now: start)
    let session = try #require(db.workspaceOverview().conversations.first { $0.id == replacement.sessionID })
    #expect(session.folderID == folder && session.title == "Updated task")
    #expect(try db.sessionTools(session.id).enabled == [.notes])
  }
}

extension WorkspaceCalendarTests {
  @Test func legacyCalendarVisibilityDefaultsToVisible() throws {
    func legacy<T: Encodable>(_ value: T) throws -> Data {
      var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
      object.removeValue(forKey: "showsOnCalendar")
      return try JSONSerialization.data(withJSONObject: object)
    }
    let details = WorkspaceCalendarDetails(task: task())
    #expect(try JSONDecoder().decode(WorkspaceCalendarDetails.self, from: legacy(details)).showsOnCalendar)
    let draft = WorkspaceCalendarDraft(title: "Old task", startsAt: date("2026-09-01T13:00:00Z"), task: task())
    #expect(try JSONDecoder().decode(WorkspaceCalendarDraft.self, from: legacy(draft)).showsOnCalendar)
    var ordinary = draft; ordinary.task = nil; ordinary.showsOnCalendar = false
    #expect(try ordinary.validated().showsOnCalendar)
  }

  @Test func standaloneTasksPersistRunAndReuseSessionsWithoutCalendarEntries() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try db.saveCalendarEvent(draft: .init(title: "Background review", startsAt: start, timeZoneID: "UTC",
      recurrence: .init(unit: .day), task: task(), showsOnCalendar: false), creating: true, now: start)
    let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let event = try #require(reopened.calendarItems().first)
    #expect(!event.calendar.showsOnCalendar)
    #expect(!WorkspaceCalendarDraft(event).copied(to: start.addingTimeInterval(86_400)).showsOnCalendar)
    let first = try #require(reopened.dueCalendarRuns(now: start).first)
    try accept(first, in: reopened, now: start)
    let nextDay = start.addingTimeInterval(86_400)
    let second = try #require(reopened.dueCalendarRuns(now: nextDay).first)
    #expect(second.sessionID == first.sessionID)
    #expect(second.task.configuration == first.task.configuration)
    let range = DateInterval(start: start.addingTimeInterval(-1), end: nextDay.addingTimeInterval(1))
    #expect(WorkspaceCalendarSchedule.visibleOccurrences(events: try reopened.calendarItems(),
      runs: try reopened.calendarRuns(), in: range).isEmpty)
    var draft = WorkspaceCalendarDraft(event)
    draft.showsOnCalendar = true
    try reopened.saveCalendarEvent(id: id, draft: draft, creating: false, now: nextDay)
    #expect(!WorkspaceCalendarSchedule.visibleOccurrences(events: try reopened.calendarItems(),
      runs: try reopened.calendarRuns(), in: range).isEmpty)
    #expect(try reopened.calendarRuns().contains { $0.id == first.id && $0.status == "accepted" })
    #expect(try reopened.dueCalendarRuns(now: nextDay).map(\.id) == [second.id])
    #expect(try reopened.isCalendarRunActive(second.id))
  }

  @Test func detachedStandaloneOccurrenceRetainsVisibilityAndCanMoveToCalendar() throws {
    let (db, directory) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try db.saveCalendarEvent(draft: .init(title: "Review", startsAt: start, timeZoneID: "UTC",
      recurrence: .init(unit: .day), task: task(), showsOnCalendar: false), creating: true, now: start)
    let event = try #require(db.calendarItems().first)
    let occurrence = try #require(WorkspaceCalendarSchedule.occurrence(event, index: 1))
    let detachedID = try db.saveCalendarEvent(id: id, draft: occurrence.draft, creating: false, detaching: 1, now: start)
    let detached = try #require(db.calendarItems().first { $0.id == detachedID })
    #expect(!detached.calendar.showsOnCalendar && detached.calendar.recurrence == nil)
    var draft = WorkspaceCalendarDraft(detached); draft.showsOnCalendar = true
    try db.saveCalendarEvent(id: detachedID, draft: draft, creating: false, now: start)
    let entries = WorkspaceCalendarSchedule.visibleOccurrences(events: try db.calendarItems(), runs: [],
      in: .init(start: start, end: start.addingTimeInterval(3 * 86_400)))
    #expect(entries.map(\.event.id) == [detachedID])
    #expect(try db.dueCalendarRuns(now: start).contains { $0.eventID == id })
  }
}

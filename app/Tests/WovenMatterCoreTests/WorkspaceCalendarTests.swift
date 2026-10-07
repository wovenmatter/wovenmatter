import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Calendar events, recurrence and scheduled sessions")
struct WorkspaceCalendarTests {
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func fixture() async throws -> (WorkspaceDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "wm-calendar-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite")), directory)
  }
  private func task(mode: WorkspaceCalendarTask.SessionMode = .same) -> WorkspaceCalendarTask {
    .init(prompt: "Review the project", configuration: .init(runtimeKind: .codex, title: "Review",
      model: "fixture-model", thinking: "high", permission: "read-only", nativeWorkingDirectory: "/tmp/project",
      tools: .init(enabled: [.notes, .calendar])), sessionMode: mode)
  }
  private func insert(_ db: WorkspaceDatabase, start: Date, repeatRule: WorkspaceCalendarRecurrence? = nil,
                      mode: WorkspaceCalendarTask.SessionMode = .same) async throws -> String {
    try await db.saveCalendarEvent(draft: .init(title: "Review", startsAt: start, timeZoneID: "America/New_York",
      recurrence: repeatRule, task: task(mode: mode)), creating: true, now: start)
  }
  private func accept(_ run: WorkspaceCalendarRun, in db: WorkspaceDatabase, now: Date) async throws {
    if (try? await db.localACPSession(conversationID: run.sessionID)) == nil {
      _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Temporary title", ownerDeviceID: UUID(),
        requestedConversationID: UUID(uuidString: run.sessionID))
    }
    _ = try await db.prepareCalendarDelivery(runID: run.id, now: now)
    #expect(try await db.claimToolDelivery(id: run.id, now: now) != nil)
    try await db.setToolDeliveryStatus(id: run.id, status: "accepted")
    try await db.settleCalendarRuns()
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

  @Test func allDayAndMultiDayEventsOverlapTheirVisibleDays() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let draft = WorkspaceCalendarDraft(title: "Trip", startsAt: date("2026-09-20T14:00:00Z"), endsAt: date("2026-09-23T14:00:00Z"),
      allDay: true, timeZoneID: "America/New_York")
    try await db.saveCalendarEvent(draft: draft, creating: true)
    let event = try await #require(db.calendarItems().first)
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

  @Test func everyOverdueOneOffAndOneRecurringCatchUpSurviveReopen() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    for offset in 0..<5 { _ = try await insert(db, start: start.addingTimeInterval(Double(offset) * 86_400)) }
    let series = try await insert(db, start: start, repeatRule: .init(unit: .day))
    let now = date("2026-09-06T14:00:00Z")
    let runs = try await db.dueCalendarRuns(now: now)
    #expect(runs.count == 6)
    #expect(runs.filter { $0.eventID == series }.count == 1)
    #expect(runs.first { $0.eventID == series }?.scheduledAt == date("2026-09-06T13:00:00Z"))
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    #expect(Set(try await reopened.dueCalendarRuns(now: now).map(\.id)) == Set(runs.map(\.id)))
    for run in runs { try await accept(run, in: reopened, now: now) }
    #expect(try await reopened.dueCalendarRuns(now: now).isEmpty)
    #expect(try await reopened.calendarRuns().allSatisfy { $0.status == "accepted" })
  }

  @Test func schedulingUsesTheSamePrecisionAsPersistedDates() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z").addingTimeInterval(0.123456)
    let id = try await insert(db, start: start)
    let run = try await #require(db.dueCalendarRuns(now: start.addingTimeInterval(1)).first)
    #expect(run.eventID == id)
  }

  @Test(arguments: [WorkspaceCalendarTask.SessionMode.same, .new])
  func recurringSessionChoiceIsDurable(mode: WorkspaceCalendarTask.SessionMode) async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try await insert(db, start: start, repeatRule: .init(unit: .day), mode: mode)
    let first = try await #require(db.dueCalendarRuns(now: start).first)
    try await accept(first, in: db, now: start)
    #expect(try await db.workspaceOverview().conversations.first { $0.id == first.sessionID }?.isScheduledTask == true)
    #expect(try await db.workspaceOverview().conversations.first { $0.id == first.sessionID }?.title == "Scheduled: Review")
    try await db.mutateConversation(id: first.sessionID, mutation: .rename("My review"))
    let second = try await #require(db.dueCalendarRuns(now: start.addingTimeInterval(86_400)).first)
    #expect((first.sessionID == second.sessionID) == (mode == .same))
    #expect(first.id != second.id)
    try await accept(second, in: db, now: start.addingTimeInterval(86_400))
    #expect(try await db.toolSessionCreationConfiguration(targetID: second.sessionID)?.model == "fixture-model")
    #expect(try await db.sessionTools(first.sessionID).enabled == [.notes, .calendar])
    #expect(try await db.workspaceOverview().conversations.first { $0.id == first.sessionID }?.title == "My review")
  }

  @Test func detachingRetainsSettingsAndSuppressesOnlyOriginalOccurrence() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(db, start: start, repeatRule: .init(unit: .day))
    let event = try await #require(db.calendarItems().first)
    let occurrence = try #require(WorkspaceCalendarSchedule.occurrence(event, index: 2))
    var draft = occurrence.draft; draft.title = "Special review"; draft.task?.prompt = "Review the release"
    let detachedID = try await db.saveCalendarEvent(id: id, draft: draft, creating: false, expectedRevision: 0,
      detaching: 2, now: start)
    let saved = try await db.calendarItems()
    let series = try #require(saved.first { $0.id == id }), detached = try #require(saved.first { $0.id == detachedID })
    #expect(series.calendar.excludedOccurrences == [2])
    #expect(detached.calendar.recurrence == nil)
    #expect(detached.calendar.task?.configuration.model == "fixture-model")
    #expect(detached.calendar.task?.configuration.permission == "read-only")
    #expect(detached.calendar.task?.prompt == "Review the release")
    #expect(WorkspaceCalendarSchedule.occurrence(series, index: 2) == nil)
    #expect(WorkspaceCalendarSchedule.occurrence(series, index: 3) != nil)
    let due = try await db.dueCalendarRuns(now: occurrence.startsAt)
    #expect(due.contains { $0.eventID == detachedID })
    #expect(!due.contains { $0.eventID == id && $0.scheduledAt == occurrence.startsAt })
  }

  @Test func attributionRevisionAndCopyHaveIndependentIdentity() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let caller = try await db.createLocalACPSession(runtimeKind: .claudeCode, title: "Planning", ownerDeviceID: UUID())
    let start = date("2026-09-01T13:00:00Z")
    let id = try await db.saveCalendarEvent(draft: .init(title: "Plan", startsAt: start, recurrence: .init(unit: .week)), creating: true, callerID: caller)
    let original = try await db.calendarEvent(id: id, callerID: caller)
    #expect(original.calendar.createdBy.agent == "claude_code")
    #expect(original.calendar.createdBy.sessionTitle == "Planning")
    var draft = WorkspaceCalendarDraft(original); draft.details = "Updated by the user"
    try await db.saveCalendarEvent(id: id, draft: draft, creating: false, expectedRevision: 0)
    let edited = try await db.calendarEvent(id: id, callerID: caller)
    #expect(edited.calendar.createdBy == original.calendar.createdBy)
    #expect(edited.calendar.editedBy == WorkspaceCalendarAuthor())
    #expect(edited.calendar.revision == 1)
    await #expect(throws: (any Error).self) { try await db.saveCalendarEvent(id: id, draft: draft, creating: false, expectedRevision: 0) }
    let copied = draft.copied(to: start.addingTimeInterval(86_400))
    #expect(copied.recurrence == nil)
    let copiedID = try await db.saveCalendarEvent(draft: copied, creating: true)
    #expect(copiedID != id)
    #expect(try await db.calendarEvent(id: copiedID, callerID: caller).calendar.createdBy.sessionID == nil)
  }

  @Test func deletionAndEditsCancelPreparedDeliveriesWithoutDeletingSessions() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(db, start: start)
    let run = try await #require(db.dueCalendarRuns(now: start).first)
    _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try await db.prepareCalendarDelivery(runID: run.id, now: start)
    try await db.deleteCalendarEvent(id: id)
    #expect(try await !db.isCalendarRunActive(run.id))
    #expect(try await db.claimToolDelivery(id: run.id, now: start) == nil)
    #expect(try await db.dueCalendarRuns(now: start).isEmpty)
    #expect(try await db.workspaceOverview().conversations.contains { $0.id == run.sessionID })
    #expect(try await db.dashboardRecordCounts().calendarItems == 0)
  }

  @Test(arguments: [false, true])
  func restartNeverResubmitsAcceptedOrUncertainOccurrence(uncertain: Bool) async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try await insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try await #require(db.dueCalendarRuns(now: start).first)
    _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try await db.prepareCalendarDelivery(runID: run.id, now: start)
    _ = try await db.claimToolDelivery(id: run.id, now: start)
    if uncertain {
      try await db.markToolDeliveryTransportStarted(id: run.id)
    } else {
      try await db.setToolDeliveryStatus(id: run.id, status: "accepted")
    }
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    if uncertain {
      try await reopened.recoverToolDeliveries()
      #expect(try await reopened.calendarRuns().first?.status == "uncertain")
    }
    try await reopened.settleCalendarRuns()
    #expect(try await reopened.dueCalendarRuns(now: start).isEmpty)
    let next = try await #require(reopened.dueCalendarRuns(now: start.addingTimeInterval(5 * 86_400)).first)
    #expect(next.id != run.id)
    #expect(next.scheduledAt == start.addingTimeInterval(5 * 86_400))
    #expect(try await reopened.claimToolDelivery(id: run.id) == nil)
    try await accept(next, in: reopened, now: next.scheduledAt)
    #expect(try await reopened.dueCalendarRuns(now: next.scheduledAt).isEmpty)
  }
}

extension WorkspaceCalendarTests {
  @Test func detachedAcceptedRunKeepsItsSessionEvenBeforeSettlement() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try await #require(db.dueCalendarRuns(now: start).first)
    _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try await db.prepareCalendarDelivery(runID: run.id, now: start)
    _ = try await db.claimToolDelivery(id: run.id, now: start)
    try await db.setToolDeliveryStatus(id: run.id, status: "accepted")
    let event = try await #require(db.calendarItems().first)
    let detachedID = try await db.saveCalendarEvent(id: id, draft: WorkspaceCalendarDraft(event), creating: false, detaching: 0, now: start)
    try await db.settleCalendarRuns()
    let saved = try await #require(db.calendarRuns().first)
    #expect(saved.eventID == detachedID && saved.sessionID == run.sessionID)
    #expect(try await db.dueCalendarRuns(now: start).isEmpty)
  }

  @Test @MainActor func runtimeWaitsForCapacityAndBusySessionsAndRechecksAfterPreparation() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let deletedID = try await insert(db, start: start)
    let busyID = try await insert(db, start: start)
    let healthyID = try await insert(db, start: start)
    let runs = try await db.dueCalendarRuns(now: start)
    let busySession = try #require(runs.first { $0.eventID == busyID }?.sessionID)
    var prepared: [String] = [], delivered: [String] = []
    var busy = true
    func prepare(_ run: WorkspaceCalendarRun) async throws {
      prepared.append(run.eventID)
      _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
      if run.eventID == deletedID { try await db.deleteCalendarEvent(id: deletedID, now: start) }
    }
    func dispatch(_ delivery: WorkspaceSessionDelivery) async throws {
      delivered.append(delivery.targetID)
      _ = try await db.claimToolDelivery(id: delivery.id, now: start)
      try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    }
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { _ in false }, hasCapacity: { false }, prepare: prepare, dispatch: dispatch)
    #expect(prepared.isEmpty && delivered.isEmpty)
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { busy && $0 == busySession }, hasCapacity: { true }, prepare: prepare, dispatch: dispatch)
    #expect(Set(prepared) == [deletedID, healthyID])
    #expect(delivered.count == 1)
    #expect(try await db.calendarRuns().first { $0.eventID == deletedID }?.status == "cancelled")
    busy = false
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { busy && $0 == busySession }, hasCapacity: { true }, prepare: { run in
      try await prepare(run)
      busy = true // User starts a turn during the awaited native setup.
    }, dispatch: dispatch)
    #expect(delivered.count == 1)
    busy = false
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { _ in false }, hasCapacity: { true }, prepare: { _ in }, dispatch: dispatch)
    #expect(delivered.count == 2 && delivered.contains(busySession))
  }

  @Test(arguments: [WorkspaceCalendarTask.SessionMode.same, .new])
  @MainActor func stopDuringPreparationCancelsOnlySelectedOccurrence(mode: WorkspaceCalendarTask.SessionMode) async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let selectedID = try await insert(db, start: start, repeatRule: .init(unit: .day), mode: mode)
    let otherID = try await insert(db, start: start.addingTimeInterval(1))
    let now = start.addingTimeInterval(2)
    let runs = try await db.dueCalendarRuns(now: now)
    let selected = try #require(runs.first { $0.eventID == selectedID })
    let other = try #require(runs.first { $0.eventID == otherID })
    _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Selected", ownerDeviceID: UUID(),
      requestedConversationID: UUID(uuidString: selected.sessionID))
    let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
    let (resume, resumeSignal) = AsyncStream<Void>.makeStream()
    defer { resumeSignal.finish() }
    var admission = WorkspaceSessionAdmission()
    var registered: [String: AgentDispatchFence] = [:]
    var released: [String] = []
    var delivered: [String] = []
    let pass = Task { @MainActor in
      defer { enteredSignal.finish() }
      try await CalendarTaskRunner.tick(database: db, now: now,
        isRunning: { _ in false }, hasCapacity: { true },
        beginPreparation: { run in
          #expect(admission.begin(run.sessionID, running: [], limit: 16) == .start)
          let fence = AgentDispatchFence()
          registered[run.sessionID] = fence
          return fence
        }, finishPreparation: { run in
          admission.finish(run.sessionID)
          released.append(run.id)
        }, finishAttempt: { run, fence in
          #expect(registered[run.sessionID] === fence)
          registered[run.sessionID] = nil
        }, prepare: { run, fence in
          if run.id == selected.id {
            enteredSignal.yield(())
            var iterator = resume.makeAsyncIterator()
            _ = await iterator.next()
            // Real native preparation can resume without checking Stop itself;
            // the runner must still fence the following database/dispatch work.
          } else {
            _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Other", ownerDeviceID: UUID(),
              requestedConversationID: UUID(uuidString: run.sessionID))
          }
        }, dispatch: { delivery, fence in
          #expect(registered[delivery.targetID] === fence)
          // Preparation releases the shared reservation before normal dispatch.
          #expect(admission.begin(delivery.targetID, running: [], limit: 16) == .start)
          defer { admission.finish(delivery.targetID) }
          try fence.claimDispatch()
          delivered.append(delivery.id)
          _ = try await db.claimToolDelivery(id: delivery.id, now: now)
          try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
        })
    }
    var enteredIterator = entered.makeAsyncIterator()
    _ = await enteredIterator.next()
    let stopped = try #require(registered[selected.sessionID])
    #expect(admission.begin(selected.sessionID, running: [], limit: 16) == .preparing)
    #expect(stopped.cancel())
    resumeSignal.yield(())
    try await pass.value
    #expect(delivered == [other.id])
    #expect(Set(released) == Set(runs.map(\.id)) && released.count == runs.count)
    #expect(registered.isEmpty)
    #expect(admission.begin(selected.sessionID, running: [], limit: 16) == .start)
    admission.finish(selected.sessionID)
    #expect(try await db.calendarRuns().first { $0.id == selected.id }?.status == "cancelled")
    #expect(try await db.toolDelivery(id: selected.id) == nil)
    // Stop consumes this occurrence, not the recurring schedule or a new session.
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    #expect(try await reopened.dueCalendarRuns(now: now).isEmpty)
    let next = try await #require(reopened.dueCalendarRuns(now: start.addingTimeInterval(86_400)).first)
    #expect(next.eventID == selectedID && next.id != selected.id)
    #expect((next.sessionID == selected.sessionID) == (mode == .same))
    var nextDelivered = false
    try await CalendarTaskRunner.tick(database: reopened, now: start.addingTimeInterval(86_400),
      isRunning: { _ in false }, hasCapacity: { true }, prepare: { run in
        if mode == .new {
          _ = try await reopened.createLocalACPSession(runtimeKind: .codex, title: "Next", ownerDeviceID: UUID(),
            requestedConversationID: UUID(uuidString: run.sessionID))
        }
      }, dispatch: { delivery in
        nextDelivered = true
        _ = try await reopened.claimToolDelivery(id: delivery.id, now: start.addingTimeInterval(86_400))
        try await reopened.setToolDeliveryStatus(id: delivery.id, status: "accepted")
      })
    #expect(nextDelivered)
  }

  @Test func cancellationBeforeDispatchSettlesPreparedOccurrenceButPreservesStartedTransport() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try await insert(db, start: start)
    _ = try await insert(db, start: start.addingTimeInterval(1))
    let now = start.addingTimeInterval(2)
    let runs = try await db.dueCalendarRuns(now: now)
    #expect(runs.count == 2)
    for (index, run) in runs.enumerated() {
      _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(),
        requestedConversationID: UUID(uuidString: run.sessionID))
      _ = try await db.prepareCalendarDelivery(runID: run.id, now: now)
      _ = try await db.claimToolDelivery(id: run.id, now: now)
      if index == 1 { try await db.markToolDeliveryTransportStarted(id: run.id) }
      try await db.cancelCalendarRunBeforeDispatch(run.id)
    }
    #expect(try await db.calendarRuns().first { $0.id == runs[0].id }?.status == "cancelled")
    #expect(try await db.toolDelivery(id: runs[0].id)?.status == "cancelled")
    #expect(try await db.toolDelivery(id: runs[1].id)?.status == "sending")
    let remaining = try await db.dueCalendarRuns(now: now)
    #expect(!remaining.contains { $0.id == runs[0].id })
    #expect(remaining.allSatisfy { $0.id == runs[1].id })
  }

  @Test @MainActor func runtimePreparationFailureDoesNotBlockOtherEventsAndRetriesWithStableIdentity() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let failedID = try await insert(db, start: start)
    _ = try await insert(db, start: start)
    let original = try await #require(db.dueCalendarRuns(now: start).first { $0.eventID == failedID })
    func create(_ run: WorkspaceCalendarRun) async throws {
      _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    }
    func dispatch(_ delivery: WorkspaceSessionDelivery) async throws {
      _ = try await db.claimToolDelivery(id: delivery.id, now: start.addingTimeInterval(31))
      try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    }
    try await CalendarTaskRunner.tick(database: db, now: start, isRunning: { _ in false }, hasCapacity: { true }, prepare: { run in
      if run.eventID == failedID { throw WorkspaceToolError.invalid("Workspace offline") }
      try await create(run)
    }, dispatch: dispatch)
    #expect(try await db.calendarRuns().filter { $0.status == "accepted" }.count == 1)
    #expect(try await db.dueCalendarRuns(now: start.addingTimeInterval(29)).isEmpty)
    let retry = try await #require(db.dueCalendarRuns(now: start.addingTimeInterval(31)).first)
    #expect(retry.id == original.id && retry.sessionID == original.sessionID)
    #expect(retry.error == "Workspace offline")
    try await CalendarTaskRunner.tick(database: db, now: start.addingTimeInterval(31), isRunning: { _ in false }, hasCapacity: { true }, prepare: create, dispatch: dispatch)
    #expect(try await db.calendarRuns().allSatisfy { $0.status == "accepted" })
  }
}

extension WorkspaceCalendarTests {
  @Test @MainActor func busyBacklogDoesNotStarveReadyTasks() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    for _ in 0..<20 { _ = try await insert(db, start: start) }
    let readyID = try await insert(db, start: start.addingTimeInterval(1))
    let now = start.addingTimeInterval(2)
    let runs = try await db.dueCalendarRuns(now: now)
    let busy = Set(runs.filter { $0.eventID != readyID }.map(\.sessionID))
    var delivered: [String] = []
    try await CalendarTaskRunner.tick(database: db, now: now, isRunning: { busy.contains($0) }, hasCapacity: { true }, prepare: { run in
      _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Ready", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    }, dispatch: { delivery in
      delivered.append(delivery.id)
      _ = try await db.claimToolDelivery(id: delivery.id, now: now)
      try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    })
    #expect(delivered == runs.filter { $0.eventID == readyID }.map(\.id))
  }

  @Test @MainActor func queuedRetryReappliesSettingsAndHonorsTransportBackoff() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try await insert(db, start: start)
    let run = try await #require(db.dueCalendarRuns(now: start).first)
    _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try await db.prepareCalendarDelivery(runID: run.id, now: start)
    _ = try await db.claimToolDelivery(id: run.id, now: start)
    try await db.failToolDeliveryAttempt(id: run.id, now: start)
    #expect(try await db.dueCalendarRuns(now: start.addingTimeInterval(29)).isEmpty)
    try await db.setSessionTools(.init(enabled: []), sessionID: run.sessionID)
    var preparations = 0
    let now = start.addingTimeInterval(31)
    try await CalendarTaskRunner.tick(database: db, now: now, isRunning: { _ in false }, hasCapacity: { true }, prepare: { retry in
      preparations += 1
      #expect(retry.id == run.id && retry.sessionID == run.sessionID)
      try await db.setSessionTools(retry.task.configuration.tools, sessionID: retry.sessionID)
    }, dispatch: { delivery in
      #expect(try await db.sessionTools(delivery.targetID).enabled == [.notes, .calendar])
      _ = try await db.claimToolDelivery(id: delivery.id, now: now)
      try await db.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    })
    #expect(preparations == 1)
    #expect(try await db.calendarRuns().first?.status == "accepted")
  }

  @Test func invalidOccurrenceRemovalAndDeletedIDReuseDoNotMutateEvents() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(db, start: start)
    await #expect(throws: (any Error).self) { try await db.deleteCalendarEvent(id: id, occurrence: 2) }
    let event = try await #require(db.calendarItems().first)
    #expect(event.id == id)
    try await db.deleteCalendarEvent(id: id)
    await #expect(throws: (any Error).self) {
      try await db.saveCalendarEvent(id: id, draft: WorkspaceCalendarDraft(event), creating: true)
    }
    #expect(try await db.calendarItems().isEmpty)
  }

  @Test func pastRunsRemainDistinctFromChangedOccurrencesAndKeepTheirSavedSettings() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try await #require(db.dueCalendarRuns(now: start).first)
    try await accept(run, in: db, now: start)
    var draft = WorkspaceCalendarDraft(try await #require(db.calendarItems().first))
    draft.title = "New schedule"; draft.startsAt = start.addingTimeInterval(3_600)
    draft.task?.prompt = "New instructions"
    try await db.saveCalendarEvent(id: id, draft: draft, creating: false, now: start.addingTimeInterval(3_601))
    let entries = WorkspaceCalendarSchedule.visibleOccurrences(events: try await db.calendarItems(), runs: try await db.calendarRuns(),
      in: .init(start: start.addingTimeInterval(-1), end: start.addingTimeInterval(86_400)))
    #expect(entries.count == 2)
    let past = try #require(entries.first { $0.recordedRun != nil })
    #expect(past.title == "Review" && past.draft.task?.prompt == "Review the project")
    #expect(past.recordedRun?.sessionID == run.sessionID)
    let current = try #require(entries.first { $0.recordedRun == nil })
    #expect(current.title == "New schedule" && current.draft.task?.prompt == "New instructions")
    // Detaching the live occurrence does not steal an earlier run's session link.
    let detached = try await db.saveCalendarEvent(id: id, draft: current.draft, creating: false, detaching: current.index,
      now: start.addingTimeInterval(3_601))
    #expect(try await db.calendarRuns().first?.eventID == id)
    #expect(detached != id)
  }
}

extension WorkspaceCalendarTests {
  @Test func deletingCompletedOccurrenceHidesItsEntryAndPreservesExecutionHistory() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(db, start: start, repeatRule: .init(unit: .day))
    let run = try await #require(db.dueCalendarRuns(now: start).first)
    try await accept(run, in: db, now: start)
    try await db.deleteCalendarEvent(id: id, occurrence: 0)
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let entries = WorkspaceCalendarSchedule.visibleOccurrences(events: try await reopened.calendarItems(), runs: try await reopened.calendarRuns(),
      in: .init(start: start.addingTimeInterval(-1), end: start.addingTimeInterval(1)))
    #expect(entries.isEmpty)
    #expect(try await reopened.read { try $0.calendarRunsUnlocked(eventID: id).first?.status } == "accepted")
    #expect(try await reopened.toolDelivery(id: run.id)?.status == "accepted")
    #expect(try await reopened.workspaceOverview().conversations.contains { $0.id == run.sessionID })
    #expect(try await reopened.dueCalendarRuns(now: start).isEmpty)
    #expect(try await reopened.dueCalendarRuns(now: start.addingTimeInterval(86_400)).count == 1)
  }

  @Test func calendarBacklogDoesNotDisplaceOtherDeliveryKinds() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    _ = try await insert(db, start: start)
    let run = try await #require(db.dueCalendarRuns(now: start).first)
    _ = try await db.createLocalACPSession(runtimeKind: .codex, title: "Task", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
    _ = try await db.prepareCalendarDelivery(runID: run.id, now: start)
    let source = try await db.createLocalACPSession(runtimeKind: .codex, title: "Sender", ownerDeviceID: UUID())
    let delivery = try await db.reserveToolDelivery(sourceID: source, targetID: run.sessionID, text: "Regular message", requestID: UUID().uuidString.lowercased())
    #expect(try await db.sessionDeliveries(queuedOnly: true, limit: 1, includeCalendar: false).map(\.id) == [delivery.id])
  }

  @Test func legacyEventsMigrateWithoutLosingContentOrAgentAttribution() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let caller = try await db.createLocalACPSession(runtimeKind: .codex, title: "Planner", ownerDeviceID: UUID())
    let start = date("2026-09-01T13:00:00Z")
    let id = try await db.saveAgentCalendar(callerID: caller, creating: true, title: "Legacy event", details: "Preserve this description",
      startsAt: start, endsAt: start.addingTimeInterval(3_600), allDay: false)
    // Recreate the pre-feature schema around an existing native event.
    try await db.write { connection in try connection.transaction {
      try connection.executeUnlocked("""
        DROP TABLE workspace_calendar_runs;
        DROP TABLE workspace_calendar_sessions;
        DROP INDEX workspace_calendar_due;
        ALTER TABLE dashboard_calendar_items DROP COLUMN calendar_json;
        ALTER TABLE dashboard_calendar_items DROP COLUMN next_fire_at;
        ALTER TABLE dashboard_calendar_items DROP COLUMN task_session_id;
        ALTER TABLE dashboard_calendar_items DROP COLUMN deleted_at;
        """)
     } }
    let migrated = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let event = try await #require(migrated.calendarItems().first)
    #expect(event.id == id && event.title == "Legacy event" && event.details == "Preserve this description")
    #expect(event.startDate == start && event.endDate == start.addingTimeInterval(3_600))
    #expect(event.calendar.createdBy.sessionID == caller && event.calendar.createdBy.agent == "codex")
    #expect(event.calendar.task == nil && event.calendar.recurrence == nil)
    #expect(try await migrated.dueCalendarRuns(now: start.addingTimeInterval(86_400)).isEmpty)
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    #expect(try await reopened.calendarItems().first == event)
  }
}

extension WorkspaceCalendarTests {
  @Test func replacingCancelledSlotUsesTheNewOccurrenceIdentity() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(db, start: start, repeatRule: .init(unit: .day))
    let cancelled = try await #require(db.dueCalendarRuns(now: start).first)
    try await db.deleteCalendarEvent(id: id, occurrence: 0)
    var draft = WorkspaceCalendarDraft(try await #require(db.calendarItems().first))
    draft.startsAt = start.addingTimeInterval(-86_400)
    try await db.saveCalendarEvent(id: id, draft: draft, creating: false, now: start)
    let replacement = try await #require(db.dueCalendarRuns(now: start).first)
    #expect(replacement.id != cancelled.id)
    #expect(replacement.scheduledAt == cancelled.scheduledAt)
    #expect(replacement.occurrenceIndex == 1)
    #expect(try await db.calendarRuns().first?.id == replacement.id)
    try await accept(replacement, in: db, now: start)
    #expect(try await db.dueCalendarRuns(now: start).isEmpty)
  }
}

extension WorkspaceCalendarTests {
  @Test(arguments: [Set<String>(), Set(["saved:profile"])])
  func scheduledExecutorAppsKeepTheirSavedScope(profiles: Set<String>) async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    var scheduled = task()
    scheduled.configuration.tools = .init(enabled: [.executor], executorProfiles: profiles)
    _ = try await db.saveCalendarEvent(draft: .init(title: "Saved scope", startsAt: start, timeZoneID: "UTC", task: scheduled), creating: true, now: start)
    var settings = try await db.toolSettings()
    var executor = ExecutorConfiguration(); executor.defaultProfiles = ["later:profile"]
    settings.executor = executor
    try await db.saveToolSettings(settings)
    let run = try await #require(db.dueCalendarRuns(now: start).first)
    try await accept(run, in: db, now: start)
    #expect(try await db.sessionTools(run.sessionID).executorProfiles == profiles)
  }

  @Test func editingAnUncreatedRecurringSessionUpdatesItsInsertionSettings() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(db, start: start, repeatRule: .init(unit: .day))
    let original = try await #require(db.dueCalendarRuns(now: start).first)
    let folder = try await db.createFolder(name: "Updated destination")
    var draft = WorkspaceCalendarDraft(try await #require(db.calendarItems().first))
    draft.title = "Updated task"
    draft.task?.configuration.folderID = folder
    draft.task?.configuration.tools = .init(enabled: [.notes])
    try await db.saveCalendarEvent(id: id, draft: draft, creating: false, now: start)
    let replacement = try await #require(db.dueCalendarRuns(now: start).first)
    #expect(replacement.sessionID == original.sessionID && replacement.id != original.id)
    try await accept(replacement, in: db, now: start)
    let session = try await #require(db.workspaceOverview().conversations.first { $0.id == replacement.sessionID })
    #expect(session.folderID == folder && session.title == "Scheduled: Updated task")
    #expect(try await db.sessionTools(session.id).enabled == [.notes])
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

  @Test func standaloneTasksPersistRunAndReuseSessionsWithoutCalendarEntries() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await db.saveCalendarEvent(draft: .init(title: "Background review", startsAt: start, timeZoneID: "UTC",
      recurrence: .init(unit: .day), task: task(), showsOnCalendar: false), creating: true, now: start)
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let event = try await #require(reopened.calendarItems().first)
    #expect(!event.calendar.showsOnCalendar)
    #expect(!WorkspaceCalendarDraft(event).copied(to: start.addingTimeInterval(86_400)).showsOnCalendar)
    let first = try await #require(reopened.dueCalendarRuns(now: start).first)
    try await accept(first, in: reopened, now: start)
    let nextDay = start.addingTimeInterval(86_400)
    let second = try await #require(reopened.dueCalendarRuns(now: nextDay).first)
    #expect(second.sessionID == first.sessionID)
    #expect(second.task.configuration == first.task.configuration)
    let range = DateInterval(start: start.addingTimeInterval(-1), end: nextDay.addingTimeInterval(1))
    #expect(WorkspaceCalendarSchedule.visibleOccurrences(events: try await reopened.calendarItems(),
      runs: try await reopened.calendarRuns(), in: range).isEmpty)
    var draft = WorkspaceCalendarDraft(event)
    draft.showsOnCalendar = true
    try await reopened.saveCalendarEvent(id: id, draft: draft, creating: false, now: nextDay)
    #expect(!WorkspaceCalendarSchedule.visibleOccurrences(events: try await reopened.calendarItems(),
      runs: try await reopened.calendarRuns(), in: range).isEmpty)
    #expect(try await reopened.calendarRuns().contains { $0.id == first.id && $0.status == "accepted" })
    #expect(try await reopened.dueCalendarRuns(now: nextDay).map(\.id) == [second.id])
    #expect(try await reopened.isCalendarRunActive(second.id))
  }

  @Test func detachedStandaloneOccurrenceRetainsVisibilityAndCanMoveToCalendar() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await db.saveCalendarEvent(draft: .init(title: "Review", startsAt: start, timeZoneID: "UTC",
      recurrence: .init(unit: .day), task: task(), showsOnCalendar: false), creating: true, now: start)
    let event = try await #require(db.calendarItems().first)
    let occurrence = try #require(WorkspaceCalendarSchedule.occurrence(event, index: 1))
    let detachedID = try await db.saveCalendarEvent(id: id, draft: occurrence.draft, creating: false, detaching: 1, now: start)
    let detached = try await #require(db.calendarItems().first { $0.id == detachedID })
    #expect(!detached.calendar.showsOnCalendar && detached.calendar.recurrence == nil)
    var draft = WorkspaceCalendarDraft(detached); draft.showsOnCalendar = true
    try await db.saveCalendarEvent(id: detachedID, draft: draft, creating: false, now: start)
    let entries = WorkspaceCalendarSchedule.visibleOccurrences(events: try await db.calendarItems(), runs: [],
      in: .init(start: start, end: start.addingTimeInterval(3 * 86_400)))
    #expect(entries.map(\.event.id) == [detachedID])
    #expect(try await db.dueCalendarRuns(now: start).contains { $0.eventID == id })
  }
}

extension WorkspaceCalendarTests {
  @Test func remoteOwnershipSurvivesRestartAndBlocksPendingDelivery() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = UUID(), start = date("2026-09-22T12:00:00Z")
    var remoteTask = task(); remoteTask.configuration.workspaceID = workspace
    let id = try await db.saveCalendarEvent(draft: .init(title: "Remote",startsAt: start,task: remoteTask),creating: true,now:start)
    let run = try await #require(db.dueCalendarRuns(now:start).first)
    try await db.setRemoteCalendarExecutionOwnership(workspaceID:workspace,state:.pending)
    #expect(try await db.dueCalendarRuns(now:start).isEmpty)
    #expect(try await !db.isCalendarRunActive(run.id))
    let snapshot = try await #require(db.remoteCalendarExecutionSnapshot(workspaceID:workspace).first)
    #expect(snapshot.event.id == id)
    #expect(snapshot.runs.isEmpty)
    var moved = WorkspaceCalendarDraft(snapshot.event)
    moved.task?.configuration.workspaceID = nil
    await #expect(throws: (any Error).self) {
      try await db.saveCalendarEvent(id:id,draft:moved,creating:false)
    }
    let reopened = try await WorkspaceDatabase(url:directory.appending(path:"workspace.sqlite"))
    #expect(try await reopened.remoteCalendarExecutionOwnership(workspaceID:workspace) == .pending)
    #expect(try await reopened.dueCalendarRuns(now:start).isEmpty)
    try await reopened.setRemoteCalendarExecutionOwnership(workspaceID:workspace,state:.remote)
    try await reopened.deleteCalendarEvent(id:id)
    #expect(try await reopened.remoteCalendarExecutionSnapshot(workspaceID:workspace).isEmpty)
  }

  @Test func remoteReceiptSurvivesDeletedFolderAndReplayAfterReopen() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = UUID(), owner = UUID(), start = date("2026-09-22T12:00:00Z")
    let folder = try await db.createFolder(name: "Remote results")
    var remoteTask = task(); remoteTask.configuration.workspaceID = workspace
    remoteTask.configuration.folderID = folder
    let eventID = try await db.saveCalendarEvent(draft: .init(title: "Remote", startsAt: start, task: remoteTask), creating: true, now: start)
    // Replace a reservation cancelled during ownership transfer.
    _ = try await db.dueCalendarRuns(now: start)
    try await db.setRemoteCalendarExecutionOwnership(workspaceID: workspace, state: .pending)
    let run = WorkspaceCalendarRun(id: UUID().uuidString.lowercased(), eventID: eventID, occurrenceIndex: 0, scheduledAt: start,
      sessionID: UUID().uuidString.lowercased(), task: remoteTask, status: "accepted", title: "Remote")
    try await db.importRemoteCalendarRun(run, workspaceID: workspace, eventRevision: 0)
    try await db.deleteFolder(id: folder)
    // The fallback belongs to completed-result import, not new execution.
    await #expect(throws: WorkspaceNoteMutationError.folderNotFound) {
      try await db.createRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: workspace,
        remoteWorkspaceName: "Fixture", title: "Remote", ownerDeviceID: owner,
        requestedConversationID: UUID(uuidString: run.sessionID))
    }
    let updates = try JSONDecoder().decode([GatewayJSONValue].self, from: Data(#"[{"sessionUpdate":"agent_thought_chunk","content":{"text":"Check it."}},{"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"Read file","status":"completed"},{"sessionUpdate":"agent_message_chunk","content":{"text":"Done."}}]"#.utf8))
    func importTranscript(_ database: WorkspaceDatabase) async throws {
      try await database.importRemoteCalendarTranscript(receiptID: "deleted-folder-receipt", run: run,
        workspaceID: workspace, workspaceName: "Fixture", ownerDeviceID: owner,
        nativeSessionID: "native-deleted-folder", updates: updates, error: nil, completedAt: start.addingTimeInterval(5))
    }
    try await importTranscript(db)
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    try await reopened.importRemoteCalendarRun(run, workspaceID: workspace, eventRevision: 0)
    try await importTranscript(reopened)
    let runs = try await reopened.calendarRuns()
    #expect(runs.count == 1 && runs.first?.id == run.id && runs.first?.status == "accepted")
    let session = try await #require(reopened.workspaceOverview().conversations.first { $0.id == run.sessionID })
    #expect(session.folderID == nil)
    #expect(session.title == "Scheduled: " + remoteTask.configuration.title)
    #expect(try await reopened.localACPSession(conversationID: run.sessionID).acpSessionID == "native-deleted-folder")
    #expect(try await reopened.calendarRuns().first?.task.configuration.folderID == folder)
    let savedConfiguration = try #require(await reopened.read { connection in
      try connection.historyRowsUnlocked("SELECT configuration_json FROM workspace_calendar_sessions WHERE id=?", values: [run.sessionID])
        .first?.objectValue?["configuration_json"]?.stringValue
    })
    #expect(try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(savedConfiguration.utf8)).folderID == folder)
    let counts = try await reopened.read { connection in
      try connection.historyRowsUnlocked("SELECT (SELECT count(*) FROM dashboard_messages WHERE conversation_id=?) AS messages, (SELECT count(*) FROM workspace_calendar_remote_receipts WHERE id=?) AS receipts",
        values: [run.sessionID, "deleted-folder-receipt"]).first?.objectValue
    }
    #expect(counts?["messages"]?.intValue == 2)
    #expect(counts?["receipts"]?.intValue == 1)
    let activities = try await reopened.read { connection in
      try connection.historyRowsUnlocked("SELECT id FROM dashboard_run_events WHERE conversation_id=?", values: [run.sessionID])
    }
    #expect(activities.count == 2)
    #expect(try await reopened.dueCalendarRuns(now: start.addingTimeInterval(100)).isEmpty)
  }
}


extension WorkspaceCalendarTests {
  @Test func remoteDisableRestoresCheckpointBeforeReleasingFence() async throws {
    let (db,directory) = try await fixture(); defer { try? FileManager.default.removeItem(at:directory) }
    let workspace = UUID(),start = date("2026-09-22T12:00:00Z")
    var remoteTask = task(); remoteTask.configuration.workspaceID = workspace
    let id = try await db.saveCalendarEvent(draft:.init(title:"Remote",startsAt:start,timeZoneID:"UTC",recurrence:.init(unit:.day),task:remoteTask),creating:true,now:start)
    try await db.setRemoteCalendarExecutionOwnership(workspaceID:workspace,state:.pending)
    try await db.setRemoteCalendarExecutionOwnership(workspaceID:workspace,state:.remote)
    let checkpoint = RemoteTaskGatewaySchedule(id:id,title:"Remote",startsAt:start,timeZoneID:"UTC",recurrence:.init(unit:.day),revision:0,
      nextFireAt:start.addingTimeInterval(86_400),taskSessionID:UUID().uuidString.lowercased(),task:remoteTask)
    try await db.restoreRemoteCalendarExecutionCheckpoint(workspaceID:workspace,schedules:[checkpoint])
    #expect(try await db.dueCalendarRuns(now:start).isEmpty)
    try await db.setRemoteCalendarExecutionOwnership(workspaceID:workspace,state:.local)
    #expect(try await db.dueCalendarRuns(now:start).isEmpty)
    let run = try await #require(db.dueCalendarRuns(now:start.addingTimeInterval(86_400)).first)
    #expect(run.sessionID == checkpoint.taskSessionID)
  }
}

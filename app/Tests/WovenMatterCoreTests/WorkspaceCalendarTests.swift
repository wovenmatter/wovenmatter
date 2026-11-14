import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterLibraryStore

@Suite("Calendar events, recurrence and scheduled sessions")
struct WorkspaceCalendarTests {

  @Test func remoteDisableRestoresCheckpointBeforeReleasingFence() async throws {
    let (db, persistence) = try await fixture(); defer { persistence.remove() }
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

  /// A task's schedule is the state of the Mac that runs it
  /// (`calendar_schedules`), not part of the shared calendar item. Running
  /// the task leaves the shared item as it was, so an edit made on another
  /// Mac meanwhile is not competing with a newer version and applies; the
  /// owner then schedules the edited task as it would its own edit.
  @Test func runningATaskLeavesTheSharedItemAloneAndAnotherMacsEditReschedulesIt() async throws {
    let (owner, a) = try await fixture(), (other, b) = try await fixture(); defer { a.remove(); b.remove() }
    let ownerID = try await owner.libraryIdentity().hostDeviceID, otherID = try await other.libraryIdentity().hostDeviceID
    func send(_ source: WorkspaceDatabase, _ id: String, to target: WorkspaceDatabase) async throws {
      var cursor = try await target.peerSyncCursors(id).pulled
      for _ in 0..<1000 {
        let page = try await source.pairedLibraryPage(after: cursor)
        try await target.receivePairedLibrary(page, from: id)
        cursor = page.cursor
        if !page.hasMore { return }
      }
    }
    func itemVersions(_ database: WorkspaceDatabase) async throws -> [JSONValue] {
      try await database.read { try $0.historyRowsUnlocked("SELECT origin,clock FROM peer_sync_versions WHERE table_name='calendar_items' ORDER BY cursor", values: []) }
    }
    let start = date("2026-09-01T13:00:00Z")
    let id = try await insert(owner, start: start, repeatRule: .init(unit: .day))
    try await send(owner, ownerID, to: other)
    #expect(try await other.dueCalendarRuns(now: start).isEmpty)

    // The other Mac renames the task and moves it an hour later while the owner runs it.
    var draft = WorkspaceCalendarDraft(try await #require(other.calendarItems().first))
    draft.title = "Renamed elsewhere"; draft.startsAt = start.addingTimeInterval(3_600)
    try await other.saveCalendarEvent(id: id, draft: draft, creating: false, now: start.addingTimeInterval(60))
    let before = try await itemVersions(owner)
    let run = try await #require(owner.dueCalendarRuns(now: start).first)
    try await accept(run, in: owner, now: start)
    #expect(try await owner.dueCalendarRuns(now: start.addingTimeInterval(30)).isEmpty)
    #expect(try await itemVersions(owner) == before)

    // The edit applies, and the owner fires the series at its new time, in its session.
    try await send(other, otherID, to: owner)
    #expect(try await owner.calendarItems().first?.title == "Renamed elsewhere")
    #expect(try await owner.dueCalendarRuns(now: start.addingTimeInterval(120)).isEmpty)
    let next = try await #require(owner.dueCalendarRuns(now: start.addingTimeInterval(3_600)).first)
    #expect(next.scheduledAt == start.addingTimeInterval(3_600) && next.title == "Renamed elsewhere")
    #expect(next.sessionID == run.sessionID)
    try await send(owner, ownerID, to: other)
    #expect(try await other.calendarItems().first?.title == "Renamed elsewhere")
    #expect(try await other.dueCalendarRuns(now: start.addingTimeInterval(3_600)).isEmpty)
  }

  /// An edit that does not change when or where a task runs (a new title, a
  /// removed occurrence) leaves the owner's schedule where it is, also when
  /// it arrives from another Mac right as the next occurrence falls due.
  @Test func anEditThatLeavesTheScheduleAloneDoesNotMoveIt() async throws {
    let (owner, a) = try await fixture(), (other, b) = try await fixture(); defer { a.remove(); b.remove() }
    let ownerID = try await owner.libraryIdentity().hostDeviceID, otherID = try await other.libraryIdentity().hostDeviceID
    func send(_ source: WorkspaceDatabase, _ id: String, to target: WorkspaceDatabase) async throws {
      var cursor = try await target.peerSyncCursors(id).pulled
      for _ in 0..<1000 {
        let page = try await source.pairedLibraryPage(after: cursor)
        try await target.receivePairedLibrary(page, from: id)
        cursor = page.cursor
        if !page.hasMore { return }
      }
    }
    let start = date("2026-09-01T13:00:00Z"), day: TimeInterval = 86_400
    let id = try await insert(owner, start: start, repeatRule: .init(unit: .day))
    let first = try await #require(owner.dueCalendarRuns(now: start).first)
    try await accept(first, in: owner, now: start)
    try await send(owner, ownerID, to: other)
    var draft = WorkspaceCalendarDraft(try await #require(other.calendarItems().first)); draft.title = "Renamed only"
    try await other.saveCalendarEvent(id: id, draft: draft, creating: false, now: start.addingTimeInterval(60))
    try await other.deleteCalendarEvent(id: id, occurrence: 3, now: start.addingTimeInterval(61))
    try await send(other, otherID, to: owner)
    // The occurrence a day later is due exactly now: it fires, once, and is not passed over.
    let next = try await #require(owner.dueCalendarRuns(now: start.addingTimeInterval(day)).first)
    #expect(next.scheduledAt == start.addingTimeInterval(day) && next.title == "Renamed only" && next.sessionID == first.sessionID)
  }

  /// A Mac that hands a workspace's tasks to its Linux host publishes every
  /// task of that workspace, also one another Mac created, with the time it
  /// next fires.
  @Test func aTaskAnotherMacCreatedIsPublishedToTheDelegatedHostWithItsNextFire() async throws {
    let (publisher, a) = try await fixture(), (author, b) = try await fixture(); defer { a.remove(); b.remove() }
    let authorID = try await author.libraryIdentity().hostDeviceID
    let workspace = UUID(), start = date("2026-09-22T12:00:00Z")
    var remoteTask = task(); remoteTask.configuration.workspaceID = workspace
    let id = try await author.saveCalendarEvent(draft: .init(title: "Remote", startsAt: start, timeZoneID: "UTC", recurrence: .init(unit: .day), task: remoteTask), creating: true, now: start)
    try await publisher.setRemoteCalendarExecutionOwnership(workspaceID: workspace, state: .pending)
    try await publisher.setRemoteCalendarExecutionOwnership(workspaceID: workspace, state: .remote)
    var cursor: Int64 = 0
    for _ in 0..<1000 {
      let page = try await author.pairedLibraryPage(after: cursor)
      try await publisher.receivePairedLibrary(page, from: authorID)
      cursor = page.cursor
      if !page.hasMore { break }
    }
    let exported = try await #require(publisher.remoteCalendarExecutionSnapshot(workspaceID: workspace).first { $0.event.id == id })
    #expect(exported.nextFireAt == start)
    // The publisher hands it to the host; it does not run it itself.
    #expect(try await publisher.dueCalendarRuns(now: start).isEmpty)
  }

  @Test func allDayAndMultiDayEventsOverlapTheirVisibleDays() async throws {
    let (db, persistence) = try await fixture(); defer { persistence.remove() }
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

  @Test func pastRunsRemainDistinctFromChangedOccurrencesAndKeepTheirSavedSettings() async throws {
    let (db, persistence) = try await fixture(); defer { persistence.remove() }
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

  @Test func remoteReceiptSurvivesDeletedFolderAndReplayAfterReopen() async throws {
    let (db, persistence) = try await fixture(); defer { persistence.remove() }
    let workspace = UUID(), owner = UUID(), start = date("2026-09-22T12:00:00Z")
    let folder = try await db.createFixtureFolder(name: "Remote results")
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
      try await db.createFixtureRemoteACPSession(runtimeKind: .codex, remoteWorkspaceID: workspace,
        remoteWorkspaceName: "Fixture", title: "Remote", ownerDeviceID: owner,
        requestedConversationID: UUID(uuidString: run.sessionID))
    }
    let updates = try JSONDecoder().decode([JSONValue].self, from: Data(#"[{"sessionUpdate":"agent_thought_chunk","content":{"text":"Check it."}},{"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"Read file","status":"completed"},{"sessionUpdate":"agent_message_chunk","content":{"text":"Done."}}]"#.utf8))
    func importTranscript(_ database: WorkspaceDatabase) async throws {
      try await database.importRemoteCalendarTranscript(receiptID: "deleted-folder-receipt", run: run,
        workspaceID: workspace, workspaceName: "Fixture", ownerDeviceID: owner,
        nativeSessionID: "native-deleted-folder", updates: updates, error: nil, completedAt: start.addingTimeInterval(5))
    }
    try await importTranscript(db)
    let reopened = try await persistence.openDatabase()
    try await reopened.importRemoteCalendarRun(run, workspaceID: workspace, eventRevision: 0)
    try await importTranscript(reopened)
    let runs = try await reopened.calendarRuns()
    #expect(runs.count == 1 && runs.first?.id == run.id && runs.first?.status == "accepted")
    let session = try await #require(reopened.workspaceOverview().conversations.first { $0.id == run.sessionID })
    #expect(session.folderID == nil)
    #expect(session.title == "Scheduled: " + remoteTask.configuration.title)
    #expect(try await reopened.localACPSession(conversationID: run.sessionID).nativeSessionID == "native-deleted-folder")
    #expect(try await reopened.calendarRuns().first?.task.configuration.folderID == folder)
    let savedConfiguration = try #require(await reopened.read { connection in
      try connection.historyRowsUnlocked("SELECT configuration_json FROM calendar_task_sessions WHERE id=?", values: [run.sessionID])
        .first?.objectValue?["configuration_json"]?.stringValue
    })
    #expect(try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(savedConfiguration.utf8)).folderID == folder)
    let counts = try await reopened.read { connection in
      try connection.historyRowsUnlocked("SELECT (SELECT count(*) FROM messages WHERE conversation_id=?) AS messages, (SELECT count(*) FROM calendar_remote_receipts WHERE id=?) AS receipts",
        values: [run.sessionID, "deleted-folder-receipt"]).first?.objectValue
    }
    #expect(counts?["messages"]?.intValue == 2)
    #expect(counts?["receipts"]?.intValue == 1)
    let activities = try await reopened.read { connection in
      try connection.historyRowsUnlocked("SELECT id FROM run_activities WHERE conversation_id=?", values: [run.sessionID])
    }
    #expect(activities.count == 2)
    #expect(try await reopened.dueCalendarRuns(now: start.addingTimeInterval(100)).isEmpty)
  }

  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  private func fixture() async throws -> (WorkspaceDatabase, PersistenceFixture) {
    let persistence = try PersistenceFixture()
    return (try await persistence.openDatabase(), persistence)
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
      _ = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Temporary title", ownerDeviceID: UUID(),
        requestedConversationID: UUID(uuidString: run.sessionID))
    }
    _ = try await db.prepareCalendarDelivery(runID: run.id, now: now)
    #expect(try await db.claimToolDelivery(id: run.id, now: now) != nil)
    try await db.setToolDeliveryStatus(id: run.id, status: "accepted")
    try await db.settleCalendarRuns()
  }

}

extension WorkspaceCalendarTests {

  @Test(arguments: [WorkspaceCalendarTask.SessionMode.same, .new])
  @MainActor func stopDuringPreparationCancelsOnlySelectedOccurrence(mode: WorkspaceCalendarTask.SessionMode) async throws {
    let (db, persistence) = try await fixture(); defer { persistence.remove() }
    let start = date("2026-09-01T13:00:00Z")
    let selectedID = try await insert(db, start: start, repeatRule: .init(unit: .day), mode: mode)
    let otherID = try await insert(db, start: start.addingTimeInterval(1))
    let now = start.addingTimeInterval(2)
    let runs = try await db.dueCalendarRuns(now: now)
    let selected = try #require(runs.first { $0.eventID == selectedID })
    let other = try #require(runs.first { $0.eventID == otherID })
    _ = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Selected", ownerDeviceID: UUID(),
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
            _ = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Other", ownerDeviceID: UUID(),
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
    let reopened = try await persistence.openDatabase()
    #expect(try await reopened.dueCalendarRuns(now: now).isEmpty)
    let next = try await #require(reopened.dueCalendarRuns(now: start.addingTimeInterval(86_400)).first)
    #expect(next.eventID == selectedID && next.id != selected.id)
    #expect((next.sessionID == selected.sessionID) == (mode == .same))
    var nextDelivered = false
    try await CalendarTaskRunner.tick(database: reopened, now: start.addingTimeInterval(86_400),
      isRunning: { _ in false }, hasCapacity: { true }, prepare: { run in
        if mode == .new {
          _ = try await reopened.createFixtureLocalACPSession(runtimeKind: .codex, title: "Next", ownerDeviceID: UUID(),
            requestedConversationID: UUID(uuidString: run.sessionID))
        }
      }, dispatch: { delivery in
        nextDelivered = true
        _ = try await reopened.claimToolDelivery(id: delivery.id, now: start.addingTimeInterval(86_400))
        try await reopened.setToolDeliveryStatus(id: delivery.id, status: "accepted")
      })
    #expect(nextDelivered)
  }

}

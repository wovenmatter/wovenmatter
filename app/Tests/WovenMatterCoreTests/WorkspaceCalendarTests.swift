import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Calendar events, recurrence and scheduled sessions")
struct WorkspaceCalendarTests {

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

  @Test func remoteReceiptSurvivesDeletedFolderAndReplayAfterReopen() async throws {
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
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
    let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
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
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
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

extension WorkspaceCalendarTests {
}

extension WorkspaceCalendarTests {

}

extension WorkspaceCalendarTests {
}

extension WorkspaceCalendarTests {

}

extension WorkspaceCalendarTests {

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

}

extension WorkspaceCalendarTests {
}

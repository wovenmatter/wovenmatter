import XCTest
import WovenMatterCompanion
@testable import CompanionClient

final class MobileCalendarStoreTests: XCTestCase, @unchecked Sendable {
  private let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  private func fixture() throws -> (MobileCalendarStore, URL) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-" + UUID().uuidString).appendingPathComponent("calendar.json")
    return (try MobileCalendarStore(file: file, deviceID: device), file)
  }
  private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
  func testOfflineCreateEditDeleteAndRequestReplaySurviveRestart() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let draft = CompanionCalendarDraft(title: "Appointment", startsAt: date("2026-10-12T13:00:00Z"), timeZoneID: "UTC")
    let id = UUID().uuidString.lowercased()
    let created = try await store.save(id: id, expectedRevision: nil, draft: draft, requestID: "create")
    var edit = draft; edit.title = "Changed"
    let changed = try await store.save(id: id, expectedRevision: created.event.revision, draft: edit)
    let replay = try await store.save(id: id, expectedRevision: nil, draft: draft, requestID: "create")
    XCTAssertEqual(replay, created)
    let restarted = try MobileCalendarStore(file: file, deviceID: device)
    let records = await restarted.records(); XCTAssertEqual(records.first, changed)
    try await restarted.delete(id: id, expectedRevision: changed.event.revision, requestID: "remove")
    try await restarted.delete(id: id, expectedRevision: changed.event.revision, requestID: "remove")
    let remaining = await restarted.records(); XCTAssertTrue(remaining.isEmpty)
    let pending = try await restarted.nextMutation(); XCTAssertTrue(pending?.record.deleted == true)
  }
  func testLostAcknowledgementPreservesSubmittedPayloadAndRebasesLaterEdit() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let record = try await store.save(expectedRevision: nil, draft: .init(title: "First"))
    let submittedValue = try await store.nextMutation(); let submitted = try XCTUnwrap(submittedValue)
    var draft = record.event.draft; draft.title = "Second"
    _ = try await store.save(id: record.id, expectedRevision: record.event.revision, draft: draft)
    let restarted = try MobileCalendarStore(file: file, deviceID: device)
    let retried = try await restarted.nextMutation(); XCTAssertEqual(retried, submitted)
    var canonical = record; canonical.event.revision = 5
    try await restarted.acknowledge(.init(mutationID: submitted.id, status: .accepted, record: canonical))
    let second = try await restarted.nextMutation()
    XCTAssertEqual(second?.expectedRevision, 5); XCTAssertEqual(second?.record.event.draft.title, "Second")
  }
  func testConcurrentCentralEditPreservesBothVersionsAndOtherEventsStillSync() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let record = try await store.save(expectedRevision: nil, draft: .init(title: "Local"))
    let sentValue = try await store.nextMutation(); let sent = try XCTUnwrap(sentValue)
    var remote = record; remote.event.draft.title = "Central"; remote.event.revision = 2
    try await store.acknowledge(.init(mutationID: sent.id, status: .conflict, record: remote))
    _ = try await store.save(expectedRevision: nil, draft: .init(title: "Other"))
    let next = try await store.nextMutation(); XCTAssertEqual(next?.record.event.draft.title, "Other")
    let conflict = await store.conflicts()[record.id]
    XCTAssertEqual(conflict?.local.event.draft.title, "Local"); XCTAssertEqual(conflict?.remote?.event.draft.title, "Central")
    try await store.resolveConflict(id: record.id, keepLocal: true)
    let rebased = try await store.nextMutation(); XCTAssertEqual(rebased?.record.event.draft.title, "Other")
  }
  func testTombstonesAndExcludedOccurrencesReachOfflineReplica() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let start = date("2026-10-12T13:00:00Z")
    var remote = CompanionCalendarRecord(event: .init(id: UUID().uuidString.lowercased(), revision: 3, draft: .init(title: "Daily", startsAt: start, timeZoneID: "UTC", recurrenceUnit: "day")), excludedOccurrences: [1])
    try await store.apply(.init(workspaceID: "mac", records: [remote]))
    let events = try await store.events(from: start, to: start.addingTimeInterval(3 * 86_400)); XCTAssertEqual(events.map(\.occurrence), [0, 2])
    remote.deleted = true
    try await store.apply(.init(workspaceID: "mac", records: [remote]))
    let remaining = await store.records(); XCTAssertTrue(remaining.isEmpty)
    do { try await store.apply(.init(workspaceID: "other", records: [])); XCTFail("Changed library") } catch { }
  }
  func testAssignedDeviceMissedTasksCoalesceAndNeverRunTwiceAfterRestart() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let start = date("2026-10-01T13:00:00Z"), now = date("2026-10-12T14:00:00Z")
    _ = try await store.save(expectedRevision: nil, draft: .init(title: "One off", startsAt: start, timeZoneID: "UTC", task: .init(prompt: "Review")), ownerDeviceID: device)
    _ = try await store.save(expectedRevision: nil, draft: .init(title: "Repeat", startsAt: start, timeZoneID: "UTC", recurrenceUnit: "day", task: .init(prompt: "Review")), ownerDeviceID: device)
    _ = try await store.save(expectedRevision: nil, draft: .init(title: "Mac", startsAt: start, task: .init(prompt: "Review")))
    let foreign = try await store.dueRuns(deviceID: "other", now: now); XCTAssertTrue(foreign.isEmpty)
    let runs = try await store.dueRuns(deviceID: device, now: now)
    XCTAssertEqual(runs.count, 2); XCTAssertEqual(runs.first { $0.title == "Repeat" }?.occurrence, 11)
    let reopened = try MobileCalendarStore(file: file, deviceID: device)
    let replay = try await reopened.dueRuns(deviceID: device, now: now); XCTAssertEqual(Set(replay.map(\.id)), Set(runs.map(\.id)))
    for run in runs { _ = try await reopened.beginRun(run.id); try await reopened.updateRun(run.id, status: "completed") }
    let none = try await reopened.dueRuns(deviceID: device, now: now); XCTAssertTrue(none.isEmpty)
    let next = try await reopened.dueRuns(deviceID: device, now: now.addingTimeInterval(86_400)); XCTAssertEqual(next.count, 1)
    XCTAssertEqual(next.first?.sessionID, runs.first { $0.title == "Repeat" }?.sessionID)
  }
  func testEditingAndDeletingTaskInvalidateReservedDispatch() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let event = try await store.save(expectedRevision: nil, draft: .init(title: "Task", startsAt: Date(timeIntervalSince1970: 100), task: .init(prompt: "Before")), ownerDeviceID: device)
    let values = try await store.dueRuns(deviceID: device); let run = try XCTUnwrap(values.first)
    var draft = event.event.draft; draft.task?.prompt = "After"
    let edited = try await store.save(id: event.id, expectedRevision: event.event.revision, draft: draft, ownerDeviceID: device)
    do { _ = try await store.beginRun(run.id); XCTFail("Stale prompt admitted") } catch { }
    let updated = try await store.dueRuns(deviceID: device); XCTAssertEqual(updated.first?.task.prompt, "After")
    try await store.delete(id: event.id, expectedRevision: edited.event.revision)
    let empty = try await store.dueRuns(deviceID: device); XCTAssertTrue(empty.isEmpty)
  }
  func testMonthAndDSTUseAnchoredWallClockArithmetic() throws {
    let draft = CompanionCalendarDraft(title: "Month", startsAt: date("2026-01-31T14:00:00Z"), timeZoneID: "America/New_York", recurrenceUnit: "month")
    XCTAssertEqual(CompanionCalendarSchedule.date(draft, index: 1), date("2026-02-28T14:00:00Z"))
    XCTAssertEqual(CompanionCalendarSchedule.date(draft, index: 2), date("2026-03-31T13:00:00Z"))
  }
  func testFrozenToolDraftSurvivesRetryWithoutRepeatingSideEffects() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let draft = try await store.prepareToolDraft(requestID: "request", arguments: "update 1", draft: .init(title: "Original"))
    let reopened = try MobileCalendarStore(file: file, deviceID: device)
    let frozen = try await reopened.prepareToolDraft(requestID: "request", arguments: "update 1", draft: .init(title: "Changed"))
    XCTAssertEqual(frozen, draft)
    do { _ = try await reopened.prepareToolDraft(requestID: "request", arguments: "update 2", draft: draft); XCTFail("Mismatched retry") } catch { }
  }
  func testClaimRecoveryFencesEditedEventAndTerminalRunsCannotRestart() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let event = try await store.save(expectedRevision: nil, draft: .init(title: "Task", startsAt: Date(timeIntervalSince1970: 100), task: .init(prompt: "Before")), ownerDeviceID: device)
    let due = try await store.dueRuns(deviceID: device); let run = try XCTUnwrap(due.first)
    _ = try await store.beginRun(run.id)
    let reopened = try MobileCalendarStore(file: file, deviceID: device)
    let recovered = try await reopened.recoverRun(run.id); XCTAssertEqual(recovered?.id, run.id)
    try await reopened.delete(id: event.id, expectedRevision: event.event.revision)
    let cancelled = try await reopened.recoverRun(run.id); XCTAssertNil(cancelled)
    let saved = await reopened.runs().first; XCTAssertEqual(saved?.status, "cancelled")
    do { try await reopened.updateRun(run.id, status: "pending"); XCTFail("Terminal claim replay") } catch { }
  }
  func testRunReceiptRestorationDoesNotRepeatCompletedOneTimeTask() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let record = CompanionCalendarRecord(event: .init(id: UUID().uuidString.lowercased(), revision: 0,
      draft: .init(title: "Task", startsAt: Date(timeIntervalSince1970: 100), task: .init(prompt: "Once"))), ownerDeviceID: device)
    let run = CompanionCalendarRun(id: UUID().uuidString.lowercased(), eventID: record.id, eventRevision: 0, ownerDeviceID: device,
      occurrence: 0, scheduledAt: record.event.startsAt, sessionID: UUID().uuidString.lowercased(), task: record.event.draft.task!, title: "Task", status: "completed")
    try await store.apply(.init(workspaceID: "mac", records: [record], runs: [run]))
    let due = try await store.dueRuns(deviceID: device); XCTAssertTrue(due.isEmpty)
  }
  func testDetachedCopyWaitsForParentExclusionAndConflictsTogether() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let original = CompanionCalendarRecord(event: .init(id: UUID().uuidString.lowercased(), revision: 0,
      draft: .init(title: "Series", startsAt: Date(), recurrenceUnit: "day")))
    try await store.apply(.init(workspaceID: "mac", records: [original]))
    let child = try await store.detach(id: original.id, expectedRevision: 0, occurrence: 1, draft: .init(title: "Exception"))
    let pending = try await store.nextMutation(); XCTAssertEqual(pending?.record.id, original.id)
    try await store.acknowledge(.init(mutationID: pending!.id, status: .conflict, record: original))
    let blocked = try await store.nextMutation(); XCTAssertNil(blocked)
    try await store.resolveConflict(id: original.id, keepLocal: false)
    let childConflict = await store.conflicts()[child.id]; XCTAssertEqual(childConflict?.local.id, child.id)
    let noUpload = try await store.nextMutation(); XCTAssertNil(noUpload)
  }

}

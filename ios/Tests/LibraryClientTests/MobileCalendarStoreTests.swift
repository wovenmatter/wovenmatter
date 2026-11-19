import XCTest
import WovenMatterShared
@testable import LibraryClient

final class MobileCalendarStoreTests: XCTestCase, @unchecked Sendable {
  private let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  private func fixture() throws -> (MobileCalendarStore, URL) {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-" + UUID().uuidString).appendingPathComponent("calendar.json")
    return (try MobileCalendarStore(file: file, deviceID: device), file)
  }
  private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
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
  func testDetachedCopyWaitsForParentExclusionAndConflictsTogether() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let original = LibraryCalendarRecord(event: .init(id: UUID().uuidString.lowercased(), revision: 0,
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

  /// A task this phone owns, accepted by the library.
  private func phoneTask(_ store: MobileCalendarStore, startsAt: Date, recurring: Bool) async throws -> LibraryCalendarRecord {
    let draft = LibraryCalendarDraft(title: "Digest", startsAt: startsAt, recurrenceUnit: recurring ? "day" : nil,
      task: .init(prompt: "Summarize", runtime: "default_agent", workspaceID: device))
    let saved = try await store.save(expectedRevision: nil, draft: draft, ownerDeviceID: device)
    let upload = try await XCTUnwrapAsync(try await store.nextMutation())
    var accepted = saved; accepted.event.revision = 0
    try await store.acknowledge(.init(mutationID: upload.id, status: .accepted, record: accepted))
    return try await XCTUnwrapAsync(await store.record(id: saved.id))
  }
  private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }
  private func runOnPhone(_ store: MobileCalendarStore, now: Date) async throws -> LibraryCalendarRun {
    let due = try await store.dueRuns(deviceID: device, now: now)
    let run = try XCTUnwrap(due.first)
    _ = try await store.beginRun(run.id); try await store.updateRun(run.id, status: "completed")
    return run
  }

  func testPhoneTaskMovesToAMacAsOneReplacementThatSurvivesReopen() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let owned = try await phoneTask(store, startsAt: date("2026-01-01T09:00:00Z"), recurring: true)
    let ran = try await runOnPhone(store, now: date("2026-01-03T10:00:00Z"))
    var draft = owned.event.draft
    draft.task?.workspaceID = nil; draft.task?.runtime = "codex"
    let replacement = try await store.reassign(id: owned.id, expectedRevision: owned.event.revision, draft: draft, requestID: "move-1")
    XCTAssertNotEqual(replacement.id, owned.id)
    XCTAssertNil(replacement.ownerDeviceID, "The replacement belongs to a Mac, not this phone")
    XCTAssertEqual(replacement.excludedOccurrences, [ran.occurrence], "Work this phone already ran is not repeated")
    let again = try await store.reassign(id: owned.id, expectedRevision: owned.event.revision, draft: draft, requestID: "move-1")
    XCTAssertEqual(again, replacement, "A retried request returns the same replacement")
    let tasks = await store.scheduledTasks()
    XCTAssertEqual(tasks.map(\.event.id), [replacement.id])
    XCTAssertEqual(tasks.first?.workspaceName, "Mac")

    // The retirement uploads first; the replacement waits until it is accepted.
    let retirement = try await XCTUnwrapAsync(try await store.nextMutation())
    XCTAssertEqual(retirement.record.id, owned.id); XCTAssertTrue(retirement.record.deleted)
    let stillRetirement = try await store.nextMutation()
    XCTAssertEqual(stillRetirement?.id, retirement.id)
    try await store.acknowledge(.init(mutationID: retirement.id, status: .accepted, record: retirement.record))
    let creation = try await XCTUnwrapAsync(try await store.nextMutation())
    XCTAssertEqual(creation.record.id, replacement.id); XCTAssertNil(creation.record.ownerDeviceID)

    let reopened = try MobileCalendarStore(file: file, deviceID: device)
    let reopenedTasks = await reopened.scheduledTasks()
    XCTAssertEqual(reopenedTasks.map(\.event.id), [replacement.id])
    let pending = await reopened.pendingCount()
    XCTAssertEqual(pending, 1)
    let phoneRuns = try await reopened.dueRuns(deviceID: device, now: date("2026-02-01T10:00:00Z"))
    XCTAssertTrue(phoneRuns.isEmpty, "Neither copy is scheduled on the phone")
    // The ownership fence still refuses in-place takeovers.
    do { _ = try await reopened.save(id: replacement.id, expectedRevision: replacement.event.revision, draft: draft, ownerDeviceID: device); XCTFail("Owner changed in place") }
    catch LibraryCalendarError.conflict {}
  }

  func testPhoneTaskMovesToLinuxWithoutRepeatingARunAndConflictsKeepOneCopy() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let linux = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let owned = try await phoneTask(store, startsAt: date("2026-01-01T09:00:00Z"), recurring: false)
    _ = try await runOnPhone(store, now: date("2026-01-01T09:05:00Z"))
    var draft = owned.event.draft
    draft.task?.workspaceID = linux
    do { _ = try await store.reassign(id: owned.id, expectedRevision: owned.event.revision, draft: draft); XCTFail("A completed one-time task would run again") }
    catch MobileCalendarReassignmentError.alreadyRan {}
    let unchanged = await store.record(id: owned.id)
    XCTAssertEqual(unchanged, owned)
    let nothingQueued = await store.pendingCount()
    XCTAssertEqual(nothingQueued, 0)

    draft.startsAt = date("2026-12-01T09:00:00Z")
    let replacement = try await store.reassign(id: owned.id, expectedRevision: owned.event.revision, draft: draft)
    XCTAssertEqual(replacement.event.draft.task?.workspaceID, linux)
    XCTAssertNil(replacement.ownerDeviceID)
    do { _ = try await store.reassign(id: replacement.id, expectedRevision: 0, draft: draft); XCTFail("Only phone-owned tasks are replaced") }
    catch LibraryCalendarError.conflict {}

    // If the library refuses the retirement, the replacement is held for an explicit decision instead of uploading.
    let retirement = try await XCTUnwrapAsync(try await store.nextMutation())
    try await store.acknowledge(.init(mutationID: retirement.id, status: .conflict, record: owned))
    let blocked = try await store.nextMutation()
    XCTAssertNil(blocked)
    try await store.resolveConflict(id: owned.id, keepLocal: false)
    let held = await store.conflicts()[replacement.id]
    XCTAssertEqual(held?.local.id, replacement.id)
    let noUpload = try await store.nextMutation()
    XCTAssertNil(noUpload, "The replacement never uploads beside a schedule that was not retired")
  }

  /// A pending reservation never started, so moving the task neither rejects it
  /// as already run nor skips its occurrence; the phone's claim is cancelled.
  /// A running or finished claim still fences the replacement.
  func testPendingReservationMovesWithTheTaskWhileStartedWorkStaysFenced() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let once = try await phoneTask(store, startsAt: date("2026-01-01T09:00:00Z"), recurring: false)
    let reserved = try await XCTUnwrapAsync(try await store.dueRuns(deviceID: device, now: date("2026-01-01T09:01:00Z")).first)
    var draft = once.event.draft; draft.task?.workspaceID = nil; draft.task?.runtime = "codex"
    let movedOnce = try await store.reassign(id: once.id, expectedRevision: once.event.revision, draft: draft)
    XCTAssertEqual(movedOnce.event.draft.startsAt, once.event.draft.startsAt, "The never-run time moves unchanged")
    let cancelled = await store.runs().first { $0.id == reserved.id }
    XCTAssertEqual(cancelled?.status, "cancelled")

    let (dailyStore, second) = try fixture(); defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
    let daily = try await phoneTask(dailyStore, startsAt: date("2026-02-01T09:00:00Z"), recurring: true)
    let finished = try await runOnPhone(dailyStore, now: date("2026-02-02T10:00:00Z"))
    let pending = try await XCTUnwrapAsync(try await dailyStore.dueRuns(deviceID: device, now: date("2026-02-04T10:00:00Z")).first)
    XCTAssertNotEqual(pending.occurrence, finished.occurrence)
    var dailyDraft = daily.event.draft; dailyDraft.task?.workspaceID = nil; dailyDraft.task?.runtime = "codex"
    let current = try await XCTUnwrapAsync(await dailyStore.record(id: daily.id))
    let movedDaily = try await dailyStore.reassign(id: daily.id, expectedRevision: current.event.revision, draft: dailyDraft)
    XCTAssertEqual(movedDaily.excludedOccurrences, [finished.occurrence], "Only work that started is excluded")

    // A running claim's outcome may be unknown, so a one-time task stays fenced.
    let (third, thirdFile) = try fixture(); defer { try? FileManager.default.removeItem(at: thirdFile.deletingLastPathComponent()) }
    let started = try await phoneTask(third, startsAt: date("2026-03-01T09:00:00Z"), recurring: false)
    let claim = try await XCTUnwrapAsync(try await third.dueRuns(deviceID: device, now: date("2026-03-01T09:01:00Z")).first)
    _ = try await third.beginRun(claim.id)
    var startedDraft = started.event.draft; startedDraft.task?.workspaceID = nil; startedDraft.task?.runtime = "codex"
    do { _ = try await third.reassign(id: started.id, expectedRevision: started.event.revision, draft: startedDraft); XCTFail("Running work would repeat") }
    catch MobileCalendarReassignmentError.alreadyRan {}
  }

  /// Occurrences the user deleted stay deleted after the move, mapped by date
  /// into the replacement's recurrence.
  func testMovedRecurringTaskKeepsUserDeletedOccurrences() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let owned = try await phoneTask(store, startsAt: date("2026-01-01T09:00:00Z"), recurring: true)
    try await store.delete(id: owned.id, expectedRevision: owned.event.revision, occurrence: 10)
    let current = try await XCTUnwrapAsync(await store.record(id: owned.id))
    XCTAssertEqual(current.excludedOccurrences, [10])
    var same = current.event.draft; same.task?.workspaceID = nil; same.task?.runtime = "codex"
    let moved = try await store.reassign(id: owned.id, expectedRevision: current.event.revision, draft: same)
    XCTAssertEqual(moved.excludedOccurrences, [10], "The deleted future occurrence does not return")

    // A replacement starting later maps the same date to its own index.
    let (otherStore, second) = try fixture(); defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
    let other = try await phoneTask(otherStore, startsAt: date("2026-01-01T09:00:00Z"), recurring: true)
    try await otherStore.delete(id: other.id, expectedRevision: other.event.revision, occurrence: 10)
    let otherCurrent = try await XCTUnwrapAsync(await otherStore.record(id: other.id))
    var later = otherCurrent.event.draft; later.task?.workspaceID = nil; later.task?.runtime = "codex"
    later.startsAt = date("2026-01-05T09:00:00Z")
    let shifted = try await otherStore.reassign(id: other.id, expectedRevision: otherCurrent.event.revision, draft: later)
    XCTAssertEqual(shifted.excludedOccurrences, [6], "January 11 is index 6 of a schedule starting January 5")
    XCTAssertNil(LibraryCalendarSchedule.occurrence(shifted, index: 6))
  }
}

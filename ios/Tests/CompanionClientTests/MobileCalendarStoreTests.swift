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

  private func legacyPhoneTask(_ store: MobileCalendarStore, startsAt: Date, recurring: Bool) async throws -> CompanionCalendarRecord {
    // Earlier builds assigned tasks to the phone itself, which no longer runs schedules.
    let draft = CompanionCalendarDraft(title: "Digest", startsAt: startsAt, recurrenceUnit: recurring ? "day" : nil,
      task: .init(prompt: "Summarize", runtime: "pi", workspaceID: device))
    let saved = try await store.save(expectedRevision: nil, draft: draft, ownerDeviceID: device)
    let upload = try await XCTUnwrapAsync(try await store.nextMutation())
    var accepted = saved; accepted.event.revision = 0
    try await store.acknowledge(.init(mutationID: upload.id, status: .accepted, record: accepted))
    return try await XCTUnwrapAsync(await store.record(id: saved.id))
  }
  private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }
  private func runOnPhone(_ store: MobileCalendarStore, now: Date) async throws -> MobileCalendarRun {
    let due = try await store.dueRuns(deviceID: device, now: now)
    let run = try XCTUnwrap(due.first)
    _ = try await store.beginRun(run.id); try await store.updateRun(run.id, status: "completed")
    return run
  }

  func testPhoneTaskMovesToCentralAsOneReplacementThatSurvivesReopen() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let legacy = try await legacyPhoneTask(store, startsAt: date("2026-01-01T09:00:00Z"), recurring: true)
    let ran = try await runOnPhone(store, now: date("2026-01-03T10:00:00Z"))
    var draft = legacy.event.draft
    draft.task?.workspaceID = nil; draft.task?.runtime = "codex"
    let replacement = try await store.reassign(id: legacy.id, expectedRevision: legacy.event.revision, draft: draft, requestID: "move-1")
    XCTAssertNotEqual(replacement.id, legacy.id)
    XCTAssertNil(replacement.ownerDeviceID, "The replacement belongs to the central Mac, not this phone")
    XCTAssertEqual(replacement.excludedOccurrences, [ran.occurrence], "Work this phone already ran is not repeated")
    let again = try await store.reassign(id: legacy.id, expectedRevision: legacy.event.revision, draft: draft, requestID: "move-1")
    XCTAssertEqual(again, replacement, "A retried request returns the same replacement")
    let tasks = await store.scheduledTasks()
    XCTAssertEqual(tasks.map(\.event.id), [replacement.id])
    XCTAssertEqual(tasks.first?.workspaceName, "Central Mac")

    // The retirement uploads first; the replacement waits until it is accepted.
    let retirement = try await XCTUnwrapAsync(try await store.nextMutation())
    XCTAssertEqual(retirement.record.id, legacy.id); XCTAssertTrue(retirement.record.deleted)
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
    catch CompanionCalendarError.conflict {}
  }

  func testPhoneTaskMovesToLinuxWithoutRepeatingARunAndConflictsKeepOneCopy() async throws {
    let (store, file) = try fixture(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let linux = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let legacy = try await legacyPhoneTask(store, startsAt: date("2026-01-01T09:00:00Z"), recurring: false)
    _ = try await runOnPhone(store, now: date("2026-01-01T09:05:00Z"))
    var draft = legacy.event.draft
    draft.task?.workspaceID = linux
    do { _ = try await store.reassign(id: legacy.id, expectedRevision: legacy.event.revision, draft: draft); XCTFail("A completed one-time task would run again") }
    catch MobileCalendarReassignmentError.alreadyRan {}
    let unchanged = await store.record(id: legacy.id)
    XCTAssertEqual(unchanged, legacy)
    let nothingQueued = await store.pendingCount()
    XCTAssertEqual(nothingQueued, 0)

    draft.startsAt = date("2026-12-01T09:00:00Z")
    let replacement = try await store.reassign(id: legacy.id, expectedRevision: legacy.event.revision, draft: draft)
    XCTAssertEqual(replacement.event.draft.task?.workspaceID, linux)
    XCTAssertNil(replacement.ownerDeviceID)
    do { _ = try await store.reassign(id: replacement.id, expectedRevision: 0, draft: draft); XCTFail("Only phone-owned tasks are replaced") }
    catch CompanionCalendarError.conflict {}

    // If central refuses the retirement, the replacement is held for an explicit decision instead of uploading.
    let retirement = try await XCTUnwrapAsync(try await store.nextMutation())
    try await store.acknowledge(.init(mutationID: retirement.id, status: .conflict, record: legacy))
    let blocked = try await store.nextMutation()
    XCTAssertNil(blocked)
    try await store.resolveConflict(id: legacy.id, keepLocal: false)
    let held = await store.conflicts()[replacement.id]
    XCTAssertEqual(held?.local.id, replacement.id)
    let noUpload = try await store.nextMutation()
    XCTAssertNil(noUpload, "The replacement never uploads beside a schedule that was not retired")
  }
}

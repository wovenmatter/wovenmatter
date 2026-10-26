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

}

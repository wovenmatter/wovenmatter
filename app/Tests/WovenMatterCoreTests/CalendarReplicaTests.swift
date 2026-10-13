import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Calendar replicas and execution ownership")
struct CalendarReplicaTests {
  let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  private func fixture() async throws -> (WorkspaceDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-replica-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite")), directory)
  }
  private func mutation(owner: Bool = false) -> CompanionCalendarMutation {
    .init(deviceID: device, expectedRevision: nil, record: .init(event: .init(id: UUID().uuidString.lowercased(), revision: 0,
      draft: .init(title: "From iPhone", startsAt: Date(timeIntervalSince1970: 100), timeZoneID: "UTC",
        task: owner ? .init(prompt: "Run here") : nil)), ownerDeviceID: owner ? device : nil))
  }
  @Test func executionDenialBlocksScheduledWorkButPreservesEventsAndDeviceTasks() async throws {
    let (database, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try await database.companionLibraryIdentity()
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
      ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Central Mac", executionDeviceID: identity.hostDeviceID)
    _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
    try await database.setCompanionWorkspaceAccess(deviceID: device, workspaceID: workspace.id, enabled: false, authorizedBy: identity.hostDeviceID)
    let event = mutation()
    let saved = try await database.companionCalendarMutate(event, deviceID: device)
    #expect(saved.status == .accepted)
    var central = mutation(); central.record.event.draft.task = .init(prompt: "Run on central")
    await #expect(throws: CompanionAPIError.self) { try await database.companionCalendarMutate(central, deviceID: device) }
    var converted = try #require(saved.record); converted.event.draft.task = .init(prompt: "Convert event to central task")
    await #expect(throws: CompanionAPIError.self) {
      try await database.companionCalendarMutate(.init(deviceID: device, expectedRevision: converted.event.revision, record: converted), deviceID: device)
    }
    #expect(try await database.companionCalendarMutate(event, deviceID: device) == saved)
    #expect(try await database.companionCalendarMutate(mutation(owner: true), deviceID: device).status == .accepted)
    #expect(try await database.companionCalendarSnapshot().records.count == 2)
    #expect(try await database.dueCalendarRuns().isEmpty)
  }

  @Test func lostReceiptAndRestartCreateExactlyOneEvent() async throws {
    let (database, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let request = mutation()
    let first = try await database.companionCalendarMutate(request, deviceID: device)
    #expect(first.status == .accepted)
    let reopened = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    #expect(try await reopened.companionCalendarMutate(request, deviceID: device) == first)
    #expect(try await reopened.calendarItems().count == 1)
    var invalid = request; invalid.record.event.draft.title = "Different"
    await #expect(throws: (any Error).self) { try await reopened.companionCalendarMutate(invalid, deviceID: device) }
  }
  @Test func nativeEditConflictsWithOfflineMutationWithoutDataLoss() async throws {
    let (database, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let request = mutation()
    let base = try await #require(database.companionCalendarMutate(request, deviceID: device).record)
    let native = try await #require(database.calendarItems().first)
    var draft = WorkspaceCalendarDraft(native); draft.title = "Mac edit"
    _ = try await database.saveCalendarEvent(id: native.id, draft: draft, creating: false, expectedRevision: native.calendar.revision)
    var local = base; local.event.draft.title = "Phone edit"
    let conflict = try await database.companionCalendarMutate(.init(deviceID: device, expectedRevision: base.event.revision, record: local), deviceID: device)
    #expect(conflict.status == .conflict); #expect(conflict.record?.event.draft.title == "Mac edit")
    #expect(try await database.calendarItems().first?.title == "Mac edit")
  }
  @Test func centralRunnerCannotClaimClientOwnedTasksAndRunReceiptsRemainOwned() async throws {
    let (database, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    var request = mutation(owner: true); request.record.event.draft.task?.enabledTools = ["wovenmatter_calendar"]
    let receipt = try await database.companionCalendarMutate(request, deviceID: device)
    #expect(receipt.status == .accepted)
    #expect(try await database.dueCalendarRuns().isEmpty)
    let snapshot = try await database.companionCalendarSnapshot()
    #expect(snapshot.records.first?.ownerDeviceID == device)
    #expect(snapshot.records.first?.event.draft.task?.enabledTools == ["wovenmatter_calendar"])
    var run = CompanionCalendarRun(id: UUID().uuidString.lowercased(), eventID: request.record.id, eventRevision: 0,
      ownerDeviceID: device, occurrence: 0, scheduledAt: request.record.event.draft.startsAt, sessionID: UUID().uuidString.lowercased(),
      task: request.record.event.draft.task!, title: "From iPhone", status: "completed")
    run.revision = 2
    #expect(try await database.companionCalendarPublishRuns([run], deviceID: device) == [run.id])
    #expect(try await database.companionCalendarPublishRuns([run], deviceID: device) == [run.id])
    var stale = run; stale.status = "pending"; stale.revision = 0
    #expect(try await database.companionCalendarPublishRuns([stale], deviceID: device) == [run.id])
    #expect(try await database.companionCalendarSnapshot().runs == [run])
    #expect(try await database.calendarRuns().first?.statusLabel == "Completed")
    await #expect(throws: (any Error).self) { try await database.companionCalendarPublishRuns([run], deviceID: "other") }
  }
  @Test func deletionTombstoneSurvivesLostReceiptAndPreventsResurrection() async throws {
    let (database, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let request = mutation(); var record = try await #require(database.companionCalendarMutate(request, deviceID: device).record)
    record.deleted = true
    let deletion = CompanionCalendarMutation(deviceID: device, expectedRevision: record.event.revision, record: record)
    let receipt = try await database.companionCalendarMutate(deletion, deviceID: device)
    #expect(receipt.record?.deleted == true)
    #expect(try await database.companionCalendarMutate(deletion, deviceID: device) == receipt)
    #expect(try await database.calendarItems().isEmpty)
    #expect(try await database.companionCalendarSnapshot().records.first?.deleted == true)
    var resurrect = request; resurrect.id = UUID().uuidString.lowercased()
    #expect(try await database.companionCalendarMutate(resurrect, deviceID: device).status == .conflict)
  }
  @Test func completedOfflineRunStillSyncsAfterEventWasDeletedBeforeFirstConnection() async throws {
    let (database, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    var request = mutation(owner: true); request.record.deleted = true
    let receipt = try await database.companionCalendarMutate(request, deviceID: device)
    #expect(receipt.record?.deleted == true)
    let run = CompanionCalendarRun(id: UUID().uuidString.lowercased(), eventID: request.record.id, eventRevision: 0,
      ownerDeviceID: device, occurrence: 0, scheduledAt: request.record.event.startsAt, sessionID: UUID().uuidString.lowercased(),
      task: request.record.event.draft.task!, title: "From iPhone", status: "completed")
    #expect(try await database.companionCalendarPublishRuns([run], deviceID: device) == [run.id])
    #expect(try await database.companionCalendarSnapshot().runs == [run])
    #expect(try await database.dueCalendarRuns().isEmpty)
  }

}

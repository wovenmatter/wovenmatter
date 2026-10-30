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

  @Test func pairingSharesScheduledExecutionAndMigrationRemovesLegacyRestrictions() async throws {
    let (database, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try await database.companionLibraryIdentity()
    let workspace = try await database.registerCompanionExecutionWorkspace(.init(workspace: .init(
      id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
      kind: .mac, name: "Central Mac", executionDeviceID: identity.hostDeviceID)), deviceID: identity.hostDeviceID)
    let device = device
    try await database.write { connection in
      try connection.executeUnlocked("CREATE TABLE companion_workspace_access(device_id TEXT,workspace_id TEXT,enabled INTEGER)")
      try connection.companionExecuteUnlocked("INSERT INTO companion_workspace_access VALUES (?,?,0)", values: [device, workspace.id])
    }
    var request = mutation()
    request.record.event.draft.task = .init(prompt: "Shared central task")
    #expect(try await database.companionCalendarMutate(request, deviceID: device).status == .accepted)
    try await database.write { connection in
      try connection.createCompanionFederationSchemaUnlocked()
      let remaining = try connection.companionIDsUnlocked("SELECT name FROM sqlite_master WHERE name='companion_workspace_access'", bindings: [])
      #expect(remaining.isEmpty)
    }
    #expect(try await database.companionLibraryIdentity() == identity)
    #expect(try await database.companionExecutionWorkspaces() == [workspace])
    #expect(try await database.companionCalendarSnapshot().records.count == 1)
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

}

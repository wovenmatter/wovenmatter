import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Calendar replicas and execution ownership")
struct CalendarReplicaTests {

  let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  private func fixture() async throws -> (WorkspaceDatabase, PersistenceFixture) {
    let persistence = try PersistenceFixture()
    return (try await persistence.openDatabase(), persistence)
  }
  private func mutation(owner: Bool = false) -> LibraryCalendarMutation {
    .init(deviceID: device, expectedRevision: nil, record: .init(event: .init(id: UUID().uuidString.lowercased(), revision: 0,
      draft: .init(title: "From iPhone", startsAt: Date(timeIntervalSince1970: 100), timeZoneID: "UTC",
        task: owner ? .init(prompt: "Run here") : nil)), ownerDeviceID: owner ? device : nil))
  }

  @Test func pairingSharesScheduledExecutionAndMigrationRemovesLegacyRestrictions() async throws {
    let (database, directory) = try await fixture(); defer { directory.remove() }
    let identity = try await database.libraryIdentity()
    let workspace = try await database.registerExecutionWorkspace(.init(workspace: .init(
      id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
      kind: .mac, name: "Central Mac", executionDeviceID: identity.hostDeviceID)), deviceID: identity.hostDeviceID)
    let device = device
    try await database.write { connection in
      try connection.executeUnlocked("CREATE TABLE companion_workspace_access(device_id TEXT,workspace_id TEXT,enabled INTEGER)")
      try connection.toolsExecuteUnlocked("INSERT INTO companion_workspace_access VALUES (?,?,0)", [device, workspace.id])
    }
    var request = mutation()
    request.record.event.draft.task = .init(prompt: "Shared central task")
    #expect(try await database.libraryCalendarMutate(request, deviceID: device).status == .accepted)
    try await database.write { connection in
      try connection.createFederationSchemaUnlocked()
      let remaining = try connection.libraryIDsUnlocked("SELECT name FROM sqlite_master WHERE name='companion_workspace_access'", bindings: [])
      #expect(remaining.isEmpty)
    }
    #expect(try await database.libraryIdentity() == identity)
    #expect(try await database.libraryExecutionWorkspaces() == [workspace])
    #expect(try await database.libraryCalendarSnapshot().records.count == 1)
  }

  @Test func centralRunnerCannotClaimClientOwnedTasksAndRunReceiptsRemainOwned() async throws {
    let (database, persistence) = try await fixture(); defer { persistence.remove() }
    var request = mutation(owner: true); request.record.event.draft.task?.enabledTools = ["wovenmatter_calendar"]
    let receipt = try await database.libraryCalendarMutate(request, deviceID: device)
    #expect(receipt.status == .accepted)
    #expect(try await database.dueCalendarRuns().isEmpty)
    let snapshot = try await database.libraryCalendarSnapshot()
    #expect(snapshot.records.first?.ownerDeviceID == device)
    #expect(snapshot.records.first?.event.draft.task?.enabledTools == ["wovenmatter_calendar"])
    var run = LibraryCalendarRun(id: UUID().uuidString.lowercased(), eventID: request.record.id, eventRevision: 0,
      ownerDeviceID: device, occurrence: 0, scheduledAt: request.record.event.draft.startsAt, sessionID: UUID().uuidString.lowercased(),
      task: request.record.event.draft.task!, title: "From iPhone", status: "completed")
    run.revision = 2
    #expect(try await database.libraryCalendarPublishRuns([run], deviceID: device) == [run.id])
    #expect(try await database.libraryCalendarPublishRuns([run], deviceID: device) == [run.id])
    var stale = run; stale.status = "pending"; stale.revision = 0
    #expect(try await database.libraryCalendarPublishRuns([stale], deviceID: device) == [run.id])
    #expect(try await database.libraryCalendarSnapshot().runs == [run])
    #expect(try await database.calendarRuns().first?.statusLabel == "Completed")
    await #expect(throws: (any Error).self) { try await database.libraryCalendarPublishRuns([run], deviceID: "other") }
  }

}

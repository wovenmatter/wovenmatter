import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Durable coordinator notifications")
struct WorkspaceCoordinationEventTests {
  private func fixture() async throws -> (WorkspaceDatabase, PersistenceFixture, String, String) {
    let persistence = try PersistenceFixture()
    let db = try await persistence.openDatabase()
    let a = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
    let b = try await db.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Worker", ownerDeviceID: UUID())
    return (db, persistence, a, b)
  }

  @Test func mutedEventsDoNotReplayAndReacquisitionInvalidatesOldClaim() async throws {
    let (db, persistence, a, b) = try await fixture()
    defer { persistence.remove() }
    try await db.coordinateFixtureSession(sourceID: a, targetID: b, purpose: "Work", notifications: false)
    let run = try await db.beginLocalACPRun(conversationID: b, input: .init(text: "Fails"))
    try await db.completeLocalACPRun(runID: run.runID, error: "Fixture failure")
    #expect(try await db.collectCoordinationTurnNotifications().isEmpty)
    try await db.setCoordinationNotifications(sourceID: a, targetID: b, enabled: true)
    #expect(try await db.collectCoordinationTurnNotifications().isEmpty)
    let pending = try #require(try await db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true))
    #expect(pending.text == "Session “Worker” (\(b)): blocked (permission).")
    #expect(try await db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true) == nil)
    _ = try await db.claimToolDelivery(id: pending.id)
    try await db.endCoordination(targetID: b, sourceID: a)
    await #expect(throws: (any Error).self) { try await db.validateClaimedToolDelivery(id: pending.id) }
    try await db.coordinateFixtureSession(sourceID: a, targetID: b, purpose: "Different assignment")
    await #expect(throws: (any Error).self) { try await db.validateClaimedToolDelivery(id: pending.id) }
    let new = try await db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true)
    #expect(new != nil && new?.id != pending.id)
  }

  @Test func nativeAuthBlockNotifiesOnceAndCannotFinishItsParent() async throws {
    let (db, persistence, lead, worker) = try await fixture()
    defer { persistence.remove() }
    try await db.coordinateFixtureSession(sourceID: lead, targetID: worker, purpose: "Work")
    let run = try await db.beginLocalACPRun(conversationID: worker, input: .init(text: "Work"))
    try await db.recordProgramStatus(.init(state: .blocked, id: "children/1", kind: .auth), runID: run.runID)
    let first = try await db.collectCoordinationTurnNotifications()
    #expect(first.count == 1 && first.first?.text.contains("blocked (auth)") == true)
    #expect(try await db.collectCoordinationTurnNotifications().isEmpty)
    try await db.recordProgramStatus(.init(state: .done, id: "children/1"), runID: run.runID)
    #expect(try await db.collectCoordinationTurnNotifications().isEmpty)
    #expect(try await db.workspaceOverview().conversations.first { $0.id == worker }?.programStatus?.status?.state == .working)
    try await db.completeLocalACPRun(runID: run.runID)
    #expect(try await db.collectCoordinationTurnNotifications().first?.text.contains("done.") == true)
  }
}

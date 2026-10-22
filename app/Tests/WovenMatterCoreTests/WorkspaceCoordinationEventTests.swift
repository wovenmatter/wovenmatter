import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Durable coordinator notifications")
struct WorkspaceCoordinationEventTests {
  private func fixture() async throws -> (WorkspaceDatabase, URL, String, String) {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let a = try await db.createLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
    let b = try await db.createLocalACPSession(runtimeKind: .claudeCode, title: "Worker", ownerDeviceID: UUID())
    return (db, dir, a, b)
  }

  @Test func completionIsDeliveredOnceAcrossConcurrentPollsAndReopenWithoutEndingAssignment() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = try await db.beginLocalACPRun(conversationID: b, content: "Old work", createdAt: Date().addingTimeInterval(-20))
    try await db.completeLocalACPRun(runID: old.runID, completedAt: Date().addingTimeInterval(-10))
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Review")
    #expect(try await db.collectCoordinationTurnNotifications().isEmpty)
    let run = try await db.beginLocalACPRun(conversationID: b, content: "New work")
    #expect(try await db.collectCoordinationTurnNotifications().isEmpty)
    try await db.completeLocalACPRun(runID: run.runID)
    let deliveries = try await withThrowingTaskGroup(of: [WorkspaceSessionDelivery].self) { group in
      for _ in 0..<4 { group.addTask { try await db.collectCoordinationTurnNotifications() } }
      var values: [WorkspaceSessionDelivery] = []
      for try await value in group { values += value }
      return values
    }
    #expect(deliveries.count == 1)
    let delivery = try #require(deliveries.first)
    #expect(delivery.sourceID == b && delivery.targetID == a && delivery.kind == .notification)
    #expect(delivery.text == "Session “Worker” (\(b)): done. Run: \(run.runID).")
    #expect(try await db.sessionRelationship(b).coordinatorID == a)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try await reopened.collectCoordinationTurnNotifications().isEmpty)
    #expect(try await reopened.claimToolDelivery(id: delivery.id)?.id == delivery.id)
    try await reopened.validateClaimedToolDelivery(id: delivery.id)
  }

  @Test func mutedEventsDoNotReplayAndReacquisitionInvalidatesOldClaim() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Work", notifications: false)
    let run = try await db.beginLocalACPRun(conversationID: b, content: "Fails")
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
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Different assignment")
    await #expect(throws: (any Error).self) { try await db.validateClaimedToolDelivery(id: pending.id) }
    let new = try await db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true)
    #expect(new != nil && new?.id != pending.id)
  }

  @Test func nativeAuthBlockNotifiesOnceAndCannotFinishItsParent() async throws {
    let (db, dir, lead, worker) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.beginCoordination(sourceID: lead, targetID: worker, purpose: "Work")
    let run = try await db.beginLocalACPRun(conversationID: worker, content: "Work")
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

extension WorkspaceCoordinationEventTests {
}

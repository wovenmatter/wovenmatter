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
    let b = try await db.createLocalACPSession(runtimeKind: .pi, title: "Worker", ownerDeviceID: UUID())
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
    #expect(delivery.text.contains("Finished a turn") && delivery.text.contains("assignment remains managed"))
    #expect(try await db.sessionRelationship(b).coordinatorID == a)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try await reopened.collectCoordinationTurnNotifications().isEmpty)
    #expect(try await reopened.claimToolDelivery(id: delivery.id)?.id == delivery.id)
    try await reopened.validateClaimedToolDelivery(id: delivery.id)
  }

  @Test func notificationOnlyTurnIsSilentButWorkSteeredIntoItNotifies() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let parent = try await db.createLocalACPSession(runtimeKind: .claudeCode, title: "Lead", ownerDeviceID: UUID())
    try await db.beginCoordination(sourceID: parent, targetID: a, purpose: "Coordinate")
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Work")
    let first = try await db.recordCoordinationNeedsInput(sessionID: b, requestID: "question-1", requiresUserApproval: true)
    let notification = try #require(first)
    _ = try await db.claimToolDelivery(id: notification.id)
    let notifiedTurn = try await db.beginLocalACPRun(conversationID: a, input: .init(text: notification.text, historyDeliveryID: notification.id))
    try await db.completeLocalACPRun(runID: notifiedTurn.runID)
    #expect(try await db.collectCoordinationTurnNotifications().isEmpty)
    let second = try #require(try await db.recordCoordinationNeedsInput(sessionID: b, requestID: "question-2", requiresUserApproval: true))
    _ = try await db.claimToolDelivery(id: second.id)
    let mixedTurn = try await db.beginLocalACPRun(conversationID: a, input: .init(text: second.text, historyDeliveryID: second.id))
    _ = try await db.beginLocalACPSteeringTurn(runID: mixedTurn.runID, content: "Also finish this review")
    try await db.completeLocalACPRun(runID: mixedTurn.runID)
    let deliveries = try await db.collectCoordinationTurnNotifications()
    #expect(deliveries.count == 1)
    #expect(deliveries.first?.targetID == parent)
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
    #expect(pending.text.contains("user must answer"))
    #expect(try await db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true) == nil)
    _ = try await db.claimToolDelivery(id: pending.id)
    try await db.endCoordination(targetID: b, sourceID: a)
    await #expect(throws: (any Error).self) { try await db.validateClaimedToolDelivery(id: pending.id) }
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Different assignment")
    await #expect(throws: (any Error).self) { try await db.validateClaimedToolDelivery(id: pending.id) }
    let new = try await db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true)
    #expect(new != nil && new?.id != pending.id)
  }

  @Test func transcriptWeavesOutgoingReceiptsWithoutReorderingNativeMessages() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = try await db.beginLocalACPRun(conversationID: a, content: "Start", createdAt: Date().addingTimeInterval(-30))
    try await db.completeLocalACPRun(runID: first.runID)
    let outgoing = try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Work", requestID: UUID().uuidString, kind: .created, purpose: "Investigate")
    _ = try await db.reserveToolDelivery(sourceID: b, targetID: a, text: "Reply", requestID: UUID().uuidString)
    _ = try await db.beginLocalACPRun(conversationID: a, content: "Next", createdAt: Date().addingTimeInterval(30))
    let messages = try await db.conversationContent(id: a).messages
    let timeline = WorkspaceConversationTimelineItem.weave(messages: messages, receipts: try await db.sessionDeliveries(sessionID: a), sessionID: a)
    let messageIDs = timeline.compactMap { if case .message(let value) = $0 { value.id } else { nil as String? } }
    #expect(messageIDs == messages.map(\.id))
    #expect(timeline.count == messages.count + 1)
    #expect(timeline.contains { $0.id == "tool-receipt:" + outgoing.id })
    #expect(timeline.last?.id == messages.last?.id)
  }

  @Test func receiptPagesAndRefreshKeepEarlierActivityAndExcludeIncomingUpdates() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    for index in 0..<7 {
      _ = try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Instruction \(index)", requestID: UUID().uuidString)
    }
    let incoming = try await db.reserveToolDelivery(sourceID: b, targetID: a, text: "Incoming", requestID: UUID().uuidString)
    let first = try await db.sessionDeliveries(sessionID: a, limit: 3, outgoingOnly: true)
    let next = try await db.sessionDeliveries(sessionID: a, limit: 3, beforeID: first.last?.id, outgoingOnly: true)
    let last = try await db.sessionDeliveries(sessionID: a, limit: 3, beforeID: next.last?.id, outgoingOnly: true)
    #expect(first.count == 3 && next.count == 3 && last.count == 1)
    #expect(Set((first + next + last).map(\.id)).count == 7)
    let oldest = try #require(last.last)
    try await db.setToolDeliveryStatus(id: oldest.id, status: "cancelled")
    let added = try await db.reserveToolDelivery(sourceID: a, targetID: b, text: "Latest", requestID: UUID().uuidString)
    let refreshed = try await db.sessionActivityWindow(sessionID: a, throughID: oldest.id)
    #expect(refreshed.count == 8)
    #expect(refreshed.first?.id == added.id)
    #expect(refreshed.last?.status == "cancelled")
    #expect(refreshed.allSatisfy { $0.sourceID == a })
    _ = try await db.claimToolDelivery(id: incoming.id)
    try await db.markToolDeliveryTransportStarted(id: incoming.id, targetID: a, nativeCommand: "review")
    try await db.setToolDeliveryStatus(id: incoming.id, status: "accepted")
    let activityPage = try await db.sessionDeliveries(sessionID: a, limit: 2, activityOnly: true)
    #expect(activityPage.map(\.id) == [added.id, incoming.id])
    let previousActivity = try await db.sessionDeliveries(sessionID: a, limit: 3, beforeID: incoming.id, activityOnly: true)
    #expect(previousActivity.count == 3 && previousActivity.allSatisfy { $0.sourceID == a })
    let incomingWindow = try await db.sessionActivityWindow(sessionID: a, throughID: incoming.id)
    #expect(incomingWindow.map(\.id) == activityPage.map(\.id))
    let unrelated = try await db.createLocalACPSession(runtimeKind: .codex, title: "Other", ownerDeviceID: UUID())
    await #expect(throws: (any Error).self) {
      _ = try await db.sessionDeliveries(sessionID: unrelated, beforeID: oldest.id)
    }
  }

  @Test func failedTurnNamesFailureAndDisabledCoordinatorCannotBeWoken() async throws {
    let (db, dir, a, b) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try await db.beginCoordination(sourceID: a, targetID: b, purpose: "Work")
    let run = try await db.beginLocalACPRun(conversationID: b, content: "Fail")
    try await db.completeLocalACPRun(runID: run.runID, error: "Could not apply change")
    let failure = try #require(try await db.collectCoordinationTurnNotifications().first)
    #expect(failure.text.contains("failed") && failure.text.contains("Could not apply change"))
    try await db.setSessionTools(.init(enabled: []), sessionID: a)
    #expect(try await db.claimToolDelivery(id: failure.id) == nil)
    #expect(try await db.toolDelivery(id: failure.id)?.status == "cancelled")
  }
}

extension WorkspaceCoordinationEventTests {
  @Test(arguments: [false, true])
  func tombstonedCoordinatorCannotBlockUnrelatedNotificationsAndTimers(inputFirst: Bool) async throws {
    let (db, dir, deletedCoordinator, worker) = try await fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let liveCoordinator = try await db.createLocalACPSession(runtimeKind: .codex, title: "Live coordinator", ownerDeviceID: UUID())
    let liveWorker = try await db.createLocalACPSession(runtimeKind: .pi, title: "Live worker", ownerDeviceID: UUID())
    try await db.beginCoordination(sourceID: deletedCoordinator, targetID: worker, purpose: "Stale")
    try await db.beginCoordination(sourceID: liveCoordinator, targetID: liveWorker, purpose: "Live")
    let stale = try await db.beginLocalACPRun(conversationID: worker, content: "Stale coordinator")
    let live = try await db.beginLocalACPRun(conversationID: liveWorker, content: "Live coordinator")
    try await db.completeLocalACPRun(runID: stale.runID)
    try await db.completeLocalACPRun(runID: live.runID)
    let timer = WorkspaceSessionTimer(sessionID: liveWorker, instruction: "Due", nextFireAt: .distantPast)
    try await db.saveSessionTimer(timer, callerID: liveWorker)
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at=? WHERE id=?", ["2026-09-19T00:00:00Z", deletedCoordinator])
     } }
    if inputFirst {
      #expect(try await db.recordCoordinationNeedsInput(sessionID: worker, requestID: "stale-permission", requiresUserApproval: true) == nil)
    }
    let notifications = try await db.collectCoordinationTurnNotifications()
    #expect(notifications.count == 1 && notifications.first?.targetID == liveCoordinator)
    #expect(try await db.sessionRelationship(worker).coordinatorID == nil)
    #expect(try await db.sessionRelationship(liveWorker).coordinatorID == liveCoordinator)
    let due = try await #require(db.dueSessionTimers().first { $0.id == timer.id })
    let deliveryID = try #require(due.pendingDeliveryID)
    _ = try await db.reserveToolDelivery(sourceID: liveWorker, targetID: liveWorker, text: due.instruction, requestID: deliveryID, kind: .timer)
    #expect(try await db.claimToolDelivery(id: deliveryID) != nil)
    let reopened = try await WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try await reopened.collectCoordinationTurnNotifications().isEmpty)
    #expect(try await reopened.recordCoordinationNeedsInput(sessionID: worker, requestID: "stale-again", requiresUserApproval: true) == nil)
  }
}

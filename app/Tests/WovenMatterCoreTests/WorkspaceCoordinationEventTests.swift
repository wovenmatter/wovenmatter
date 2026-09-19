import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("Durable coordinator notifications")
struct WorkspaceCoordinationEventTests {
  private func fixture() throws -> (WorkspaceDatabase, URL, String, String) {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    let a = try db.createLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
    let b = try db.createLocalACPSession(runtimeKind: .pi, title: "Worker", ownerDeviceID: UUID())
    return (db, dir, a, b)
  }

  @Test func completionIsDeliveredOnceAcrossConcurrentPollsAndReopenWithoutEndingAssignment() async throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let old = try db.beginLocalACPRun(conversationID: b, content: "Old work", createdAt: Date().addingTimeInterval(-20))
    try db.completeLocalACPRun(runID: old.runID, completedAt: Date().addingTimeInterval(-10))
    try db.beginCoordination(sourceID: a, targetID: b, purpose: "Review")
    #expect(try db.collectCoordinationTurnNotifications().isEmpty)
    let run = try db.beginLocalACPRun(conversationID: b, content: "New work")
    #expect(try db.collectCoordinationTurnNotifications().isEmpty)
    try db.completeLocalACPRun(runID: run.runID)
    let deliveries = try await withThrowingTaskGroup(of: [WorkspaceSessionDelivery].self) { group in
      for _ in 0..<4 { group.addTask { try db.collectCoordinationTurnNotifications() } }
      var values: [WorkspaceSessionDelivery] = []
      for try await value in group { values += value }
      return values
    }
    #expect(deliveries.count == 1)
    let delivery = try #require(deliveries.first)
    #expect(delivery.sourceID == b && delivery.targetID == a && delivery.kind == .notification)
    #expect(delivery.text.contains("Finished a turn") && delivery.text.contains("assignment remains managed"))
    #expect(try db.sessionRelationship(b).coordinatorID == a)
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try reopened.collectCoordinationTurnNotifications().isEmpty)
    #expect(try reopened.claimToolDelivery(id: delivery.id)?.id == delivery.id)
    try reopened.validateClaimedToolDelivery(id: delivery.id)
  }

  @Test func notificationOnlyTurnIsSilentButWorkSteeredIntoItNotifies() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let parent = try db.createLocalACPSession(runtimeKind: .claudeCode, title: "Lead", ownerDeviceID: UUID())
    try db.beginCoordination(sourceID: parent, targetID: a, purpose: "Coordinate")
    try db.beginCoordination(sourceID: a, targetID: b, purpose: "Work")
    let first = try db.recordCoordinationNeedsInput(sessionID: b, requestID: "question-1", requiresUserApproval: true)
    let notification = try #require(first)
    _ = try db.claimToolDelivery(id: notification.id)
    let notifiedTurn = try db.beginLocalACPRun(conversationID: a, input: .init(text: notification.text, historyDeliveryID: notification.id))
    try db.completeLocalACPRun(runID: notifiedTurn.runID)
    #expect(try db.collectCoordinationTurnNotifications().isEmpty)
    let second = try #require(try db.recordCoordinationNeedsInput(sessionID: b, requestID: "question-2", requiresUserApproval: true))
    _ = try db.claimToolDelivery(id: second.id)
    let mixedTurn = try db.beginLocalACPRun(conversationID: a, input: .init(text: second.text, historyDeliveryID: second.id))
    _ = try db.beginLocalACPSteeringTurn(runID: mixedTurn.runID, content: "Also finish this review")
    try db.completeLocalACPRun(runID: mixedTurn.runID)
    let deliveries = try db.collectCoordinationTurnNotifications()
    #expect(deliveries.count == 1)
    #expect(deliveries.first?.targetID == parent)
  }

  @Test func mutedEventsDoNotReplayAndReacquisitionInvalidatesOldClaim() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try db.beginCoordination(sourceID: a, targetID: b, purpose: "Work", notifications: false)
    let run = try db.beginLocalACPRun(conversationID: b, content: "Fails")
    try db.completeLocalACPRun(runID: run.runID, error: "Fixture failure")
    #expect(try db.collectCoordinationTurnNotifications().isEmpty)
    try db.setCoordinationNotifications(sourceID: a, targetID: b, enabled: true)
    #expect(try db.collectCoordinationTurnNotifications().isEmpty)
    let pending = try #require(try db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true))
    #expect(pending.text.contains("user must answer"))
    #expect(try db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true) == nil)
    _ = try db.claimToolDelivery(id: pending.id)
    try db.endCoordination(targetID: b, sourceID: a)
    #expect(throws: (any Error).self) { try db.validateClaimedToolDelivery(id: pending.id) }
    try db.beginCoordination(sourceID: a, targetID: b, purpose: "Different assignment")
    #expect(throws: (any Error).self) { try db.validateClaimedToolDelivery(id: pending.id) }
    let new = try db.recordCoordinationNeedsInput(sessionID: b, requestID: "permission-1", requiresUserApproval: true)
    #expect(new != nil && new?.id != pending.id)
  }

  @Test func transcriptWeavesOutgoingReceiptsWithoutReorderingNativeMessages() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = try db.beginLocalACPRun(conversationID: a, content: "Start", createdAt: Date().addingTimeInterval(-30))
    try db.completeLocalACPRun(runID: first.runID)
    let outgoing = try db.reserveToolDelivery(sourceID: a, targetID: b, text: "Work", requestID: UUID().uuidString, kind: .created, purpose: "Investigate")
    _ = try db.reserveToolDelivery(sourceID: b, targetID: a, text: "Reply", requestID: UUID().uuidString)
    _ = try db.beginLocalACPRun(conversationID: a, content: "Next", createdAt: Date().addingTimeInterval(30))
    let messages = try db.conversationContent(id: a).messages
    let timeline = WorkspaceConversationTimelineItem.weave(messages: messages, receipts: try db.sessionDeliveries(sessionID: a), sessionID: a)
    let messageIDs = timeline.compactMap { if case .message(let value) = $0 { value.id } else { nil as String? } }
    #expect(messageIDs == messages.map(\.id))
    #expect(timeline.count == messages.count + 1)
    #expect(timeline.contains { $0.id == "tool-receipt:" + outgoing.id })
    #expect(timeline.last?.id == messages.last?.id)
  }

  @Test func receiptPagesAndRefreshKeepEarlierActivityAndExcludeIncomingUpdates() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    for index in 0..<7 {
      _ = try db.reserveToolDelivery(sourceID: a, targetID: b, text: "Instruction \(index)", requestID: UUID().uuidString)
    }
    _ = try db.reserveToolDelivery(sourceID: b, targetID: a, text: "Incoming", requestID: UUID().uuidString)
    let first = try db.sessionDeliveries(sessionID: a, limit: 3, outgoingOnly: true)
    let next = try db.sessionDeliveries(sessionID: a, limit: 3, beforeID: first.last?.id, outgoingOnly: true)
    let last = try db.sessionDeliveries(sessionID: a, limit: 3, beforeID: next.last?.id, outgoingOnly: true)
    #expect(first.count == 3 && next.count == 3 && last.count == 1)
    #expect(Set((first + next + last).map(\.id)).count == 7)
    let oldest = try #require(last.last)
    try db.setToolDeliveryStatus(id: oldest.id, status: "cancelled")
    let added = try db.reserveToolDelivery(sourceID: a, targetID: b, text: "Latest", requestID: UUID().uuidString)
    let refreshed = try db.outgoingDeliveryWindow(sessionID: a, throughID: oldest.id)
    #expect(refreshed.count == 8)
    #expect(refreshed.first?.id == added.id)
    #expect(refreshed.last?.status == "cancelled")
    #expect(refreshed.allSatisfy { $0.sourceID == a })
    let unrelated = try db.createLocalACPSession(runtimeKind: .codex, title: "Other", ownerDeviceID: UUID())
    #expect(throws: (any Error).self) {
      _ = try db.sessionDeliveries(sessionID: unrelated, beforeID: oldest.id)
    }
  }

  @Test func failedTurnNamesFailureAndDisabledCoordinatorCannotBeWoken() throws {
    let (db, dir, a, b) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try db.beginCoordination(sourceID: a, targetID: b, purpose: "Work")
    let run = try db.beginLocalACPRun(conversationID: b, content: "Fail")
    try db.completeLocalACPRun(runID: run.runID, error: "Could not apply change")
    let failure = try #require(try db.collectCoordinationTurnNotifications().first)
    #expect(failure.text.contains("failed") && failure.text.contains("Could not apply change"))
    try db.setSessionTools(.init(enabled: []), sessionID: a)
    #expect(try db.claimToolDelivery(id: failure.id) == nil)
    #expect(try db.toolDelivery(id: failure.id)?.status == "cancelled")
  }
}

extension WorkspaceCoordinationEventTests {
  @Test(arguments: [false, true])
  func tombstonedCoordinatorCannotBlockUnrelatedNotificationsAndTimers(inputFirst: Bool) throws {
    let (db, dir, deletedCoordinator, worker) = try fixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let liveCoordinator = try db.createLocalACPSession(runtimeKind: .codex, title: "Live coordinator", ownerDeviceID: UUID())
    let liveWorker = try db.createLocalACPSession(runtimeKind: .pi, title: "Live worker", ownerDeviceID: UUID())
    try db.beginCoordination(sourceID: deletedCoordinator, targetID: worker, purpose: "Stale")
    try db.beginCoordination(sourceID: liveCoordinator, targetID: liveWorker, purpose: "Live")
    let stale = try db.beginLocalACPRun(conversationID: worker, content: "Stale coordinator")
    let live = try db.beginLocalACPRun(conversationID: liveWorker, content: "Live coordinator")
    try db.completeLocalACPRun(runID: stale.runID)
    try db.completeLocalACPRun(runID: live.runID)
    let timer = WorkspaceSessionTimer(sessionID: liveWorker, instruction: "Due", nextFireAt: .distantPast)
    try db.saveSessionTimer(timer)
    try db.transaction {
      try db.toolsExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at=? WHERE id=?", ["2026-09-19T00:00:00Z", deletedCoordinator])
    }
    if inputFirst {
      #expect(try db.recordCoordinationNeedsInput(sessionID: worker, requestID: "stale-permission", requiresUserApproval: true) == nil)
    }
    let notifications = try db.collectCoordinationTurnNotifications()
    #expect(notifications.count == 1 && notifications.first?.targetID == liveCoordinator)
    #expect(try db.sessionRelationship(worker).coordinatorID == nil)
    #expect(try db.sessionRelationship(liveWorker).coordinatorID == liveCoordinator)
    let due = try #require(db.dueSessionTimers().first { $0.id == timer.id })
    let deliveryID = try #require(due.pendingDeliveryID)
    _ = try db.reserveToolDelivery(sourceID: liveWorker, targetID: liveWorker, text: due.instruction, requestID: deliveryID, kind: .timer)
    #expect(try db.claimToolDelivery(id: deliveryID) != nil)
    let reopened = try WorkspaceDatabase(url: dir.appending(path: "workspace.sqlite"))
    #expect(try reopened.collectCoordinationTurnNotifications().isEmpty)
    #expect(try reopened.recordCoordinationNeedsInput(sessionID: worker, requestID: "stale-again", requiresUserApproval: true) == nil)
  }
}

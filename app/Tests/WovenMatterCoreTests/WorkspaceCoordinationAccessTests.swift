import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Session management access requests")
struct WorkspaceCoordinationAccessTests {
  private func fixture() async throws -> (WorkspaceDatabase, URL, String, String) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let source = try await database.createLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
    let target = try await database.createLocalACPSession(runtimeKind: .pi, title: "Worker", ownerDeviceID: UUID())
    try await database.setSessionTools(.init(enabled: [.sessions]), sessionID: source)
    return (database, directory, source, target)
  }

  @Test func concurrentRetriesShareOneSheetAndApprovalDoesNotDependOnCLIConnection() async throws {
    let (db, directory, source, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID().uuidString
    try await withThrowingTaskGroup(of: WorkspaceCoordinationAccessRequest.self) { group in
      for _ in 0..<4 {
        group.addTask { try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: id) }
      }
      for try await result in group { #expect(result.state == "pending") }
    }
    #expect(try await db.pendingCoordinationAccessRequests().count == 1)
    await #expect(throws: WorkspaceToolError.accessRequired(target)) { try await db.requireTranscriptAccess(sourceID: source, targetID: target) }
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    #expect(try await reopened.resolveCoordinationAccess(requestID: id, allowed: true).state == "accepted")
    #expect(try await reopened.sessionRelationship(target).coordinatorID == source)
    try await reopened.requireTranscriptAccess(sourceID: source, targetID: target)
    try await reopened.endCoordination(targetID: target)
    #expect(try await reopened.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: id).state == "accepted")
    #expect(try await reopened.sessionRelationship(target).coordinatorID == nil)
    await #expect(throws: WorkspaceToolError.accessRequired(target)) { try await reopened.requireTranscriptAccess(sourceID: source, targetID: target) }
    await #expect(throws: (any Error).self) {
      _ = try await reopened.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Changed intent", requestID: id)
    }
  }

  @Test func cancellationAndShutdownCannotLaterGrantAccess() async throws {
    let (db, directory, source, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let denied = try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    #expect(try await db.resolveCoordinationAccess(requestID: denied.id, allowed: false).state == "rejected")
    #expect(try await db.resolveCoordinationAccess(requestID: denied.id, allowed: true).state == "rejected")
    let pending = try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    try await db.cancelPendingCoordinationAccess()
    #expect(try await db.resolveCoordinationAccess(requestID: pending.id, allowed: true).state == "cancelled")
    #expect(try await db.pendingCoordinationAccessRequests().isEmpty)
    #expect(try await db.sessionRelationship(target).coordinatorID == nil)
  }

  @Test func approvalRechecksCompetingCoordinatorAndRevokedCapability() async throws {
    let (db, directory, source, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pending = try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    let other = try await db.createLocalACPSession(runtimeKind: .claudeCode, title: "Other", ownerDeviceID: UUID())
    try await db.beginCoordination(sourceID: other, targetID: target, purpose: "Already managing")
    let conflict = try await db.resolveCoordinationAccess(requestID: pending.id, allowed: true)
    #expect(conflict.state == "failed")
    #expect(conflict.error?.contains(other) == true)
    #expect(try await db.sessionRelationship(target).coordinatorID == other)
    try await db.endCoordination(targetID: target)
    let revoked = try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    try await db.setSessionTools(.init(enabled: []), sessionID: source)
    #expect(try await db.resolveCoordinationAccess(requestID: revoked.id, allowed: true).state == "failed")
    #expect(try await db.sessionRelationship(target).coordinatorID == nil)
  }

  @Test func historyAndAttachmentsStartWithoutAnApprovalSheet() async throws {
    let (db, directory, source, target) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await db.attachConversationReference(sourceID: source, targetID: target)
    let first = try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Attached", requestID: UUID().uuidString)
    #expect(first.state == "accepted")
    #expect(try await db.pendingCoordinationAccessRequests().isEmpty)
    try await db.endCoordination(targetID: target)
    try await db.removeConversationReference(sourceID: source, targetID: target)
    try await db.setSessionTools(.init(enabled: [.sessions, .history]), sessionID: source)
    #expect(try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "History", requestID: UUID().uuidString).state == "accepted")
    #expect(try await db.pendingCoordinationAccessRequests().isEmpty)
  }
}

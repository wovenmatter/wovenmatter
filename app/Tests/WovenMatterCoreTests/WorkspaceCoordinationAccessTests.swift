import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Session management access requests")
struct WorkspaceCoordinationAccessTests {
  private func fixture() throws -> (WorkspaceDatabase, URL, String, String) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let source = try database.createLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
    let target = try database.createLocalACPSession(runtimeKind: .pi, title: "Worker", ownerDeviceID: UUID())
    try database.setSessionTools(.init(enabled: [.sessions]), sessionID: source)
    return (database, directory, source, target)
  }

  @Test func concurrentRetriesShareOneSheetAndApprovalDoesNotDependOnCLIConnection() async throws {
    let (db, directory, source, target) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID().uuidString
    try await withThrowingTaskGroup(of: WorkspaceCoordinationAccessRequest.self) { group in
      for _ in 0..<4 {
        group.addTask { try db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: id) }
      }
      for try await result in group { #expect(result.state == "pending") }
    }
    #expect(try db.pendingCoordinationAccessRequests().count == 1)
    #expect(throws: WorkspaceToolError.accessRequired(target)) { try db.requireTranscriptAccess(sourceID: source, targetID: target) }
    let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    #expect(try reopened.resolveCoordinationAccess(requestID: id, allowed: true).state == "accepted")
    #expect(try reopened.sessionRelationship(target).coordinatorID == source)
    try reopened.requireTranscriptAccess(sourceID: source, targetID: target)
    try reopened.endCoordination(targetID: target)
    #expect(try reopened.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: id).state == "accepted")
    #expect(try reopened.sessionRelationship(target).coordinatorID == nil)
    #expect(throws: WorkspaceToolError.accessRequired(target)) { try reopened.requireTranscriptAccess(sourceID: source, targetID: target) }
    #expect(throws: (any Error).self) {
      _ = try reopened.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Changed intent", requestID: id)
    }
  }

  @Test func cancellationAndShutdownCannotLaterGrantAccess() throws {
    let (db, directory, source, target) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let denied = try db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    #expect(try db.resolveCoordinationAccess(requestID: denied.id, allowed: false).state == "rejected")
    #expect(try db.resolveCoordinationAccess(requestID: denied.id, allowed: true).state == "rejected")
    let pending = try db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    try db.cancelPendingCoordinationAccess()
    #expect(try db.resolveCoordinationAccess(requestID: pending.id, allowed: true).state == "cancelled")
    #expect(try db.pendingCoordinationAccessRequests().isEmpty)
    #expect(try db.sessionRelationship(target).coordinatorID == nil)
  }

  @Test func approvalRechecksCompetingCoordinatorAndRevokedCapability() throws {
    let (db, directory, source, target) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pending = try db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    let other = try db.createLocalACPSession(runtimeKind: .claudeCode, title: "Other", ownerDeviceID: UUID())
    try db.beginCoordination(sourceID: other, targetID: target, purpose: "Already managing")
    let conflict = try db.resolveCoordinationAccess(requestID: pending.id, allowed: true)
    #expect(conflict.state == "failed")
    #expect(conflict.error?.contains(other) == true)
    #expect(try db.sessionRelationship(target).coordinatorID == other)
    try db.endCoordination(targetID: target)
    let revoked = try db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    try db.setSessionTools(.init(enabled: []), sessionID: source)
    #expect(try db.resolveCoordinationAccess(requestID: revoked.id, allowed: true).state == "failed")
    #expect(try db.sessionRelationship(target).coordinatorID == nil)
  }

  @Test func historyAndAttachmentsStartWithoutAnApprovalSheet() throws {
    let (db, directory, source, target) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try db.attachConversationReference(sourceID: source, targetID: target)
    let first = try db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Attached", requestID: UUID().uuidString)
    #expect(first.state == "accepted")
    #expect(try db.pendingCoordinationAccessRequests().isEmpty)
    try db.endCoordination(targetID: target)
    try db.removeConversationReference(sourceID: source, targetID: target)
    try db.setSessionTools(.init(enabled: [.sessions, .history]), sessionID: source)
    #expect(try db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "History", requestID: UUID().uuidString).state == "accepted")
    #expect(try db.pendingCoordinationAccessRequests().isEmpty)
  }
}

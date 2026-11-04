import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Session management access requests")
struct WorkspaceCoordinationAccessTests {

  @Test func cancellationAndShutdownCannotLaterGrantAccess() async throws {
    let (db, persistence, source, target) = try await fixture()
    defer { persistence.remove() }
    let denied = try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    #expect(try await db.resolveCoordinationAccess(requestID: denied.id, allowed: false).state == "rejected")
    #expect(try await db.resolveCoordinationAccess(requestID: denied.id, allowed: true).state == "rejected")
    let pending = try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    try await db.cancelPendingCoordinationAccess()
    #expect(try await db.resolveCoordinationAccess(requestID: pending.id, allowed: true).state == "cancelled")
    #expect(try await db.pendingCoordinationAccessRequests().isEmpty)
    #expect(try await db.sessionRelationship(target).coordinatorID == nil)
  }

  private func fixture() async throws -> (WorkspaceDatabase, PersistenceFixture, String, String) {
    let persistence = try PersistenceFixture()
    let database = try await persistence.openDatabase()
    let source = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
    let target = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Worker", ownerDeviceID: UUID())
    try await database.setSessionTools(.init(enabled: [.sessions]), sessionID: source)
    return (database, persistence, source, target)
  }

  @Test func concurrentRetriesShareOneSheetAndApprovalDoesNotDependOnCLIConnection() async throws {
    let (db, persistence, source, target) = try await fixture()
    defer { persistence.remove() }
    let id = UUID().uuidString
    try await withThrowingTaskGroup(of: WorkspaceCoordinationAccessRequest.self) { group in
      for _ in 0..<4 {
        group.addTask { try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: id) }
      }
      for try await result in group { #expect(result.state == "pending") }
    }
    #expect(try await db.pendingCoordinationAccessRequests().count == 1)
    await #expect(throws: WorkspaceToolError.accessRequired(target)) { try await db.read { try $0.requireTranscriptAccessUnlocked(sourceID: source, targetID: target) } }
    let reopened = try await persistence.openDatabase()
    #expect(try await reopened.resolveCoordinationAccess(requestID: id, allowed: true).state == "accepted")
    #expect(try await reopened.sessionRelationship(target).coordinatorID == source)
    try await reopened.read { try $0.requireTranscriptAccessUnlocked(sourceID: source, targetID: target) }
    try await reopened.endCoordination(targetID: target)
    #expect(try await reopened.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: id).state == "accepted")
    #expect(try await reopened.sessionRelationship(target).coordinatorID == nil)
    await #expect(throws: WorkspaceToolError.accessRequired(target)) { try await reopened.read { try $0.requireTranscriptAccessUnlocked(sourceID: source, targetID: target) } }
    await #expect(throws: (any Error).self) {
      _ = try await reopened.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Changed intent", requestID: id)
    }
  }

  @Test func approvalRechecksCompetingCoordinatorAndRevokedCapability() async throws {
    let (db, persistence, source, target) = try await fixture()
    defer { persistence.remove() }
    let pending = try await db.requestCoordinationAccess(sourceID: source, targetID: target, purpose: "Monitor", requestID: UUID().uuidString)
    let other = try await db.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Other", ownerDeviceID: UUID())
    try await db.coordinateFixtureSession(sourceID: other, targetID: target, purpose: "Already managing")
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

}

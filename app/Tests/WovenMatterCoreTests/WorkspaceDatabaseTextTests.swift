import WorkspaceFixtures
import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("SQLite text fidelity")
struct WorkspaceDatabaseTextTests {
  @Test func deliveryRetryPreservesTextAfterNULAcrossConnections() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "workspace.sqlite")
    let database = try await WorkspaceDatabase(url: url)
    let owner = UUID()
    try await database.bindDeviceOwnership(ownerDeviceID: owner)
    let source = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Source", ownerDeviceID: owner)
    let target = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Target", ownerDeviceID: owner)
    let requestID = UUID().uuidString
    let body = "First\0second 🪡"
    let purpose = "Purpose\0suffix"
    let original = try await database.reserveToolDelivery(sourceID: source, targetID: target,
      text: body, requestID: requestID, purpose: purpose)
    let reopened = try await WorkspaceDatabase(url: url)
    let replay = try await reopened.reserveToolDelivery(sourceID: source, targetID: target,
      text: body, requestID: requestID, purpose: purpose)
    #expect(original.id == replay.id)
    #expect(replay.text == body)
    #expect(replay.purpose == purpose)
    #expect(try await reopened.sessionDeliveries(sessionID: source).count == 1)
  }
}

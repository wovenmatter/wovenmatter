import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Session creation cancellation cleanup")
struct WorkspaceSessionCreationCancellationTests {
  @Test func cancelledSetupReleasesFanoutSlotAndPreservesRetryIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let owner = UUID()
    try await database.bindDeviceOwnership(ownerDeviceID: owner)
    let source = try await database.createLocalACPSession(runtimeKind: .codex, title: "Source", ownerDeviceID: owner)
    try await database.saveToolSettings(.init(maximumManagedSessions: 1))
    let requestID = UUID().uuidString.lowercased()
    let arguments = ["sessions", "create", "--title", "Reserved"]
    let reserved = try await database.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: arguments, purpose: "Fixture", managed: true)
    let cleanup = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await database.failToolSessionCreation(requestID: requestID)
    }
    try await cleanup.value
    let otherID = UUID().uuidString.lowercased()
    _ = try await database.reserveToolSessionCreation(sourceID: source, requestID: otherID,
      arguments: ["sessions", "create", "--title", "Another"], purpose: "Fixture", managed: true)
    try await database.failToolSessionCreation(requestID: otherID)
    let replay = try await database.reserveToolSessionCreation(sourceID: source, requestID: requestID,
      arguments: arguments, purpose: "Fixture", managed: true)
    #expect(replay.objectValue?["target_id"] == reserved.objectValue?["target_id"])
    #expect(replay.objectValue?["status"]?.stringValue == "planned")
  }
}

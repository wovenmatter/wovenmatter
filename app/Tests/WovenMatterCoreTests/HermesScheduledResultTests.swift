import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

struct HermesScheduledResultTests {
  @Test func repeatedResultsAndRouteChangesDoNotDuplicateDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "workspace.sqlite")
    let db = try await WorkspaceDatabase(url: url)
    let owner = UUID()
    let existing = try await db.createLocalACPSession(
      runtimeKind: .hermes, title: "Updates", ownerDeviceID: owner)
    let agent = try await #require(db.dashboardAgents().first { $0.runtimeKind == .hermes })
    try await db.setHermesResultRoute(agentID: agent.id, jobID: "job", destination: "new")
    let first = try #require(
      try await db.collectHermesResult(
        agentID: agent.id, jobID: "job", runID: "run1", title: "Report", output: "Identical output",
        ownerDeviceID: owner))
    #expect(try await db.conversationContent(id: first).messages.map(\.content) == ["Identical output"])
    try await db.setHermesResultRoute(agentID: agent.id, jobID: "job", destination: existing)
    let reopened = try await WorkspaceDatabase(url: url)
    #expect(
      try await reopened.collectHermesResult(
        agentID: agent.id, jobID: "job", runID: "run1", title: "Report", output: "Identical output",
        ownerDeviceID: owner) == nil)
    #expect(
      try await reopened.collectHermesResult(
        agentID: agent.id, jobID: "job", runID: "run2", title: "Report", output: "Identical output",
        ownerDeviceID: owner) == existing)
    #expect(try await reopened.conversationContent(id: existing).messages.count == 1)
  }

  @Test func destinationCannotCrossRemoteWorkspaces() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let owner = UUID()
    let workspace = UUID()
    let local = try await db.createLocalACPSession(
      runtimeKind: .hermes, title: "Local", ownerDeviceID: owner)
    _ = try await db.createRemoteACPSession(
      runtimeKind: .hermes, remoteWorkspaceID: workspace, remoteWorkspaceName: "Remote",
      title: "Remote", ownerDeviceID: owner)
    let agent = try await #require(
      db.dashboardAgents().first { $0.runtimeKind == .hermes && $0.runtimeDeviceID == workspace })
    await #expect(throws: (any Error).self) {
      try await db.setHermesResultRoute(agentID: agent.id, jobID: "job", destination: local)
    }
    try await db.setHermesResultRoute(agentID: agent.id, jobID: "job", destination: "new")
    let result = try #require(
      try await db.collectHermesResult(
        agentID: agent.id, jobID: "job", runID: "run", title: "Remote report",
        output: "Full output", ownerDeviceID: owner, remoteWorkspaceID: workspace,
        remoteWorkspaceName: "Remote"))
    #expect(
      try await db.workspaceOverview().conversations.first { $0.id == result }?.remoteWorkspaceID
        == workspace)
  }
}

import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

struct HermesScheduledResultTests {
  @Test func repeatedResultsAndRouteChangesDoNotDuplicateDelivery() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "workspace.sqlite")
    let db = try WorkspaceDatabase(url: url)
    let owner = UUID()
    let existing = try db.createLocalACPSession(
      runtimeKind: .hermes, title: "Updates", ownerDeviceID: owner)
    let agent = try #require(db.dashboardAgents().first { $0.runtimeKind == .hermes })
    try db.setHermesResultRoute(agentID: agent.id, jobID: "job", destination: "new")
    let first = try #require(
      try db.collectHermesResult(
        agentID: agent.id, jobID: "job", runID: "run1", title: "Report", output: "Identical output",
        ownerDeviceID: owner))
    #expect(try db.conversationContent(id: first).messages.map(\.content) == ["Identical output"])
    try db.setHermesResultRoute(agentID: agent.id, jobID: "job", destination: existing)
    let reopened = try WorkspaceDatabase(url: url)
    #expect(
      try reopened.collectHermesResult(
        agentID: agent.id, jobID: "job", runID: "run1", title: "Report", output: "Identical output",
        ownerDeviceID: owner) == nil)
    #expect(
      try reopened.collectHermesResult(
        agentID: agent.id, jobID: "job", runID: "run2", title: "Report", output: "Identical output",
        ownerDeviceID: owner) == existing)
    #expect(try reopened.conversationContent(id: existing).messages.count == 1)
  }

  @Test func destinationCannotCrossRemoteWorkspaces() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let owner = UUID()
    let workspace = UUID()
    let local = try db.createLocalACPSession(
      runtimeKind: .hermes, title: "Local", ownerDeviceID: owner)
    _ = try db.createRemoteACPSession(
      runtimeKind: .hermes, remoteWorkspaceID: workspace, remoteWorkspaceName: "Remote",
      title: "Remote", ownerDeviceID: owner)
    let agent = try #require(
      db.dashboardAgents().first { $0.runtimeKind == .hermes && $0.runtimeDeviceID == workspace })
    #expect(throws: (any Error).self) {
      try db.setHermesResultRoute(agentID: agent.id, jobID: "job", destination: local)
    }
    try db.setHermesResultRoute(agentID: agent.id, jobID: "job", destination: "new")
    let result = try #require(
      try db.collectHermesResult(
        agentID: agent.id, jobID: "job", runID: "run", title: "Remote report",
        output: "Full output", ownerDeviceID: owner, remoteWorkspaceID: workspace,
        remoteWorkspaceName: "Remote"))
    #expect(
      try db.workspaceOverview().conversations.first { $0.id == result }?.remoteWorkspaceID
        == workspace)
  }
}

import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("OSC 7501 program status")
struct ProgramStatusTests {

  @Test(arguments: [AgentRuntimeKind.defaultAgent, .codex, .claudeCode, .grokBuild])
  func coordinatorBindsReportsAndDecisionLifetimes(kind: AgentRuntimeKind) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let session = try await database.createLocalACPSession(runtimeKind: kind, title: "Worker", ownerDeviceID: UUID())
    let identity = ProgramStatusRunIdentity()
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
      LocalACPSessionDriver(initializeSession: { _, _, _, _ in .init(sessionID: "native", loadedExistingSession: false) },
        prompt: { _, event, permission, interaction in
          try await event?(.sessionIdentity("native"))
          try await event?(.programStatus(.init(state: .done, id: "foreign"), runID: "other-run"))
          try await event?(.programStatus(.init(state: .working, message: "Working"), runID: await identity.value))
          _ = await permission?(.init(title: "Approve", options: []))
          _ = await interaction?(.secret(prompt: "Credential"))
          return .endTurn
        }, configuration: { .empty }, setConfiguration: { _, _ in .empty }, cancel: {}, shutdown: {},
        setRunID: { await identity.set($0) })
    })
    _ = try await coordinator.accept(conversationID: session, content: "Work",
      launch: .init(runtimeKind: kind, executableURL: URL(filePath: "/fixture"), arguments: []),
      workspace: .init(rootURL: directory),
      onPermission: { _ in
        let status = try? await database.workspaceOverview().conversations.first { $0.id == session }?.programStatus?.status
        #expect(status?.state == .blocked && status?.kind == .permission)
        return "allow_once"
      }, onInteraction: { _ in
        let status = try? await database.workspaceOverview().conversations.first { $0.id == session }?.programStatus?.status
        #expect(status?.state == .blocked && status?.kind == .auth)
        return .cancelled
      })
    for _ in 0..<200 {
      if try await database.workspaceOverview().conversations.first(where: { $0.id == session })?.programStatus?.status?.state == .done { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let final = try await database.workspaceOverview().conversations.first { $0.id == session }?.programStatus
    #expect(final?.status?.state == .done && final?.records.contains { $0.id == "foreign" } == false)
    await coordinator.shutdown()
  }


  @Test(arguments: ["limited", "self", "history", "attachment", "managed"])
  func statusDetailsFollowTranscriptGrants(access: String) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let owner = UUID()
    let caller = try await database.createLocalACPSession(runtimeKind: .defaultAgent, title: "Caller", ownerDeviceID: owner)
    let target = access == "self" ? caller : try await database.createLocalACPSession(runtimeKind: .defaultAgent, title: "Target", ownerDeviceID: owner)
    try await database.setSessionTools(.init(enabled: access == "history" ? [.sessions, .history] : [.sessions]), sessionID: caller)
    if access == "attachment" { try await database.attachConversationReference(sourceID: caller, targetID: target) }
    if access == "managed" { try await database.recordSessionOrigin(sourceID: caller, targetID: target, purpose: "Fixture") }
    let run = try await database.beginLocalACPRun(conversationID: target, content: "Private prompt")
    try await database.recordProgramStatus(.init(state: .blocked, id: "children/1", kind: .auth, title: "Private title", message: "Private wait"), runID: run.runID)
    func snapshot() async throws -> ProgramStatusSnapshot {
      let result = try await database.queryAgentHistory(.init(command: "conversations", id: target), callerID: caller)
      let value = try #require(result.objectValue?["rows"]?.arrayValue?.first?.objectValue?["programStatus"])
      return try JSONDecoder().decode(ProgramStatusSnapshot.self, from: JSONEncoder().encode(value))
    }
    var status = try await snapshot()
    #expect(status.status?.kind == .auth && status.records.first?.id == "children/1")
    #expect(status.runID == (access == "limited" ? nil : run.runID))
    #expect(status.status?.title == (access == "limited" ? nil : "Private title"))
    #expect(status.status?.message == (access == "limited" ? nil : "Private wait"))
    #expect(status.records.first?.title == (access == "limited" ? nil : "Private title"))
    #expect(status.records.first?.message == (access == "limited" ? nil : "Private wait"))
    try await database.completeLocalACPRun(runID: run.runID, error: "Private diagnostic")
    status = try await snapshot()
    #expect(status.status?.state == .error)
    #expect(status.status?.message == (access == "limited" ? nil : "Private diagnostic"))
  }

}

private actor ProgramStatusRunIdentity {
  private(set) var value: String?
  func set(_ value: String) { self.value = value }
}

import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("OSC 7501 program status")
struct ProgramStatusTests {
  @Test func receivedReportsStillRefreshLRUAndAttentionOrder() {
    var records = ProgramStatusRecords()
    let first = ProgramStatus(state: .blocked, id: "children/first", kind: .auth)
    records.apply(first)
    records.apply(.init(state: .blocked, id: "children/second", kind: .permission))
    let refreshed = records.apply(first)
    #expect(refreshed && records.records.last == first)
    let projected = ProgramStatusSnapshot.run(id: "run", executionStatus: "running", error: nil, app: nil, reports: records.records)
    #expect(projected.status?.kind == .auth)
    for index in 0..<255 { records.apply(.init(state: .done, id: "other/\(index)")) }
    #expect(records.records.contains(first) && !records.records.contains { $0.id == "children/second" })
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

  @Test(arguments: [AgentRuntimeKind.defaultAgent, .pi])
  func failedAdvisoryPersistenceCannotFailNativeSettlement(kind: AgentRuntimeKind) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let session = try await database.createLocalACPSession(runtimeKind: kind, title: "Worker", ownerDeviceID: UUID())
    try await database.write { connection in
      try connection.toolsExecuteUnlocked("CREATE TRIGGER reject_advisory BEFORE INSERT ON desktop_program_status BEGIN SELECT RAISE(FAIL,'Fixture advisory failure'); END", [])
    }
    let coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
      LocalACPSessionDriver(initializeSession: { _, _, _, _ in .init(sessionID: "native", loadedExistingSession: false) },
        prompt: { _, event, _, _ in
          try await event?(.sessionIdentity("native"))
          try await event?(.programStatus(.init(state: .working), runID: nil))
          try await event?(.assistantChunk("Native result"))
          return .endTurn
        }, configuration: { .empty }, setConfiguration: { _, _ in .empty }, cancel: {}, shutdown: {})
    })
    _ = try await coordinator.accept(conversationID: session, content: "Work",
      launch: .init(runtimeKind: kind, executableURL: URL(filePath: "/fixture"), arguments: []),
      workspace: .init(rootURL: directory, repositoriesURL: directory))
    for _ in 0..<200 {
      if try await database.conversationContent(id: session).runs.first?.status != "running" { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let content = try await database.conversationContent(id: session)
    #expect(content.runs.first?.status == "completed")
    #expect(content.messages.contains { $0.role == "assistant" && $0.content == "Native result" })
    await coordinator.shutdown()
  }

  @Test(arguments: [("working", "cancelling", "Working (cancelling)"), ("idle", "cancelled", "Idle (cancelled)"),
    ("cancelling", "", "Working (cancelling)"), ("stopped", "", "Idle (cancelled)"), ("blocked", "", "Blocked")])
  func cancellationLabelsPreserveWorkflowFeedback(state: String, execution: String, label: String) throws {
    var json: [String: String] = ["id": "child", "state": state]
    if !execution.isEmpty { json["executionStatus"] = execution }
    let child = try JSONDecoder().decode(AgentRunSubagent.self, from: JSONEncoder().encode(json))
    #expect(child.statusLabel == label)
  }

  @Test func replacementHierarchyAndLimits() throws {
    var records = ProgramStatusRecords()
    let accepted = records.apply(.init(state: .blocked, id: "children/1", kind: .permission, progress: 20, title: "Build", message: "Approval"))
    #expect(accepted)
    records.apply(.init(state: .working, id: "children/1"))
    #expect(records.records.first?.kind == nil && records.records.first?.message == nil && records.records.first?.progress == nil)
    records.apply(.init(state: .done, id: "children/1/test"))
    records.apply(.init(state: .working, id: "children/10"))
    records.apply(.init(state: .clear, id: "children/1"))
    #expect(records.records.map(\.id) == ["children/10"])
    let badID = records.apply(.init(state: .error, id: "bad//id"))
    let unsafe = records.apply(.init(state: .error, message: "unsafe\u{1b}"))
    let oversize = records.apply(.init(state: .working, title: String(repeating: "x", count: 193)))
    #expect(!badID && !unsafe && !oversize)
    for index in 0..<300 { records.apply(.init(state: .done, id: "child/\(index)")) }
    #expect(records.records.count == 256 && records.records.first?.id == "child/44")
    records.apply(.init(state: .clear))
    #expect(records.records.isEmpty)
  }

  @Test func nativeOutcomeFencesProvisionalReports() {
    let reports: [ProgramStatus] = [.init(state: .done), .init(state: .blocked, id: "children/1", kind: .auth)]
    let active = ProgramStatusSnapshot.run(id: "r", executionStatus: "running", error: nil, app: "pi-durable", reports: reports)
    #expect(active.status?.state == .blocked && active.status?.kind == .auth)
    #expect(ProgramStatusSnapshot.run(id: "r", executionStatus: "running", error: nil, app: nil, reports: [.init(state: .done)]).status?.state == .working)
    let settled = ProgramStatusSnapshot.run(id: "r", executionStatus: "completed", error: nil, app: nil, reports: reports)
    #expect(settled.status?.state == .done && settled.records.allSatisfy { !$0.isActive })
    #expect(ProgramStatusSnapshot.run(id: "r", executionStatus: "uncertain", error: nil, app: nil, reports: reports).status == nil)
    #expect(ProgramStatusSnapshot.run(id: "r", executionStatus: "cancelled", error: nil, app: nil, reports: reports).status?.state == .idle)
    let endpoint = "/private/tmp/wmtools-" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 32) + ".sock"
    let failed = ProgramStatusSnapshot.run(id: "r", executionStatus: "failed", error: "Cannot reach " + endpoint, app: nil, reports: [])
    #expect(failed.status?.message == "Cannot reach [Woven Matter session tool endpoint]")
  }

  @Test func optionalFieldsAreForwardCompatibleAndAppInherits() throws {
    let report = try JSONDecoder().decode(ProgramStatus.self, from: Data(#"{"state":"blocked","kind":"future","progress":"unknown","app":"bad app"}"#.utf8))
    #expect(report.validated?.kind == nil && report.validated?.progress == nil && report.validated?.app == nil)
    var records = ProgramStatusRecords()
    records.apply(.init(state: .working, app: "pi-durable"))
    records.apply(.init(state: .working, id: "children", app: "worker"))
    records.apply(.init(state: .done, id: "children/1"))
    #expect(records.resolvedRecords.last?.app == "worker")
    records.apply(.init(state: .working, id: "children"))
    #expect(records.resolvedRecords.first { $0.id == "children/1" }?.app == "pi-durable")
  }

  @Test(arguments: AgentRuntimeKind.allCases.filter { $0 != .opencode })
  func persistenceIsBoundToActiveRunAcrossHarnesses(kind: AgentRuntimeKind) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "workspace.sqlite")
    let database = try await WorkspaceDatabase(url: url)
    let session = try await database.createLocalACPSession(runtimeKind: kind, title: "Worker", ownerDeviceID: UUID())
    try await database.setSessionTools(.init(enabled: [.sessions]), sessionID: session)
    let run = try await database.beginLocalACPRun(conversationID: session, content: "Work")
    try await database.recordProgramStatus(.init(state: .working, message: "Compacting context"), runID: run.runID)
    try await database.recordProgramStatus(.init(state: .blocked, kind: .permission), runID: run.runID, source: "decision")
    let reopened = try await WorkspaceDatabase(url: url)
    var status = try await reopened.workspaceOverview().conversations.first { $0.id == session }?.programStatus
    #expect(status?.status?.state == .blocked && status?.status?.kind == .permission)
    #expect(status?.records.filter { $0.id == nil }.count == 1)
    let response = try await database.queryAgentHistory(.init(command: "conversations", id: session), callerID: session)
    let projected = response.objectValue?["rows"]?.arrayValue?.first?.objectValue
    #expect(projected?["status"]?.stringValue == "blocked" && projected?["executionStatus"]?.stringValue == "running")
    try await database.recordProgramStatus(.init(state: .clear), runID: run.runID, source: "decision")
    status = try await database.workspaceOverview().conversations.first { $0.id == session }?.programStatus
    #expect(status?.status?.state == .working && status?.status?.message == "Compacting context")
    try await database.completeLocalACPRun(runID: run.runID)
    try await database.recordProgramStatus(.init(state: .blocked, kind: .auth), runID: run.runID)
    let next = try await database.beginLocalACPRun(conversationID: session, content: "Next")
    try await database.recordProgramStatus(.init(state: .error), runID: run.runID)
    status = try await database.workspaceOverview().conversations.first { $0.id == session }?.programStatus
    #expect(status?.runID == next.runID && status?.status?.state == .working && status?.records.isEmpty == true)
    try await database.cancelLocalACPRun(runID: next.runID)
    status = try await database.workspaceOverview().conversations.first { $0.id == session }?.programStatus
    #expect(status?.status?.state == .idle && status?.executionStatus == "cancelled")
  }

  @Test func openCodeUsesNativeSessionBoundaryAndDecisions() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let id = try await database.createLocalACPSession(runtimeKind: .opencode, title: "Worker", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.active = true
    snapshot.messages = [["id": "msg_a", "type": "assistant", "time": ["created": .number(1000), "completed": .number(2000)], "content": .array([])]]
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: id)
    func status() async throws -> ProgramStatus? {
      try await database.workspaceOverview().conversations.first { $0.id == id }?.programStatus?.status
    }
    #expect(try await status()?.state == .working)
    snapshot.permissions = [["id": "permission"]]
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: id)
    #expect(try await status()?.kind == .permission)
    snapshot.permissions = []; snapshot.forms = [["id": "question"]]
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: id)
    #expect(try await status()?.kind == .question)
    snapshot.forms = []; snapshot.active = false
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: id)
    #expect(try await status()?.state == .done)
    try await database.write { connection in
      try connection.toolsExecuteUnlocked("UPDATE desktop_opencode_sessions SET snapshot_json=? WHERE conversation_id=?", ["{invalid", id])
    }
    #expect(try await status()?.state == .done)
  }

  @Test(arguments: [AgentRuntimeKind.defaultAgent, .codex, .claudeCode, .pi, .cursor, .grokBuild, .hermes, .openclaw])
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
      workspace: .init(rootURL: directory, repositoriesURL: directory),
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
}

private actor ProgramStatusRunIdentity {
  private(set) var value: String?
  func set(_ value: String) { self.value = value }
}

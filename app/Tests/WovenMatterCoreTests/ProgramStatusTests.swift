import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

@Suite("OSC 7501 program status")
struct ProgramStatusTests {
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

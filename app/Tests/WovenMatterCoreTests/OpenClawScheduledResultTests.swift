import Foundation
import SQLite3
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

struct OpenClawScheduledResultTests {
  @Test func presentationWindowsKeepPerJobHistoryAndLeaveDeliveryHistoryUnbounded() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await DashboardStore(supportDirectory: root)
    let db = store.database
    _ = try await db.createLocalACPSession(runtimeKind: .openclaw, title: "Seed", ownerDeviceID: UUID())
    let agentID = try #require(await db.dashboardAgents().first).id
    let jobs = ["frequent", "quiet"].map {
      OpenClawCronJob(id: $0, agentID: agentID, name: $0, schedule: "daily", enabled: true, remotePayload: Data())
    }
    var runs = (0..<55).map {
      OpenClawCronRun(id: "run-\($0)", jobID: "frequent", agentID: agentID, status: "ok", output: "Output \($0)",
        startedAt: Date(timeIntervalSince1970: Double($0 + 100)), remotePayload: Data())
    }
    runs.append(OpenClawCronRun(id: "quiet-run", jobID: "quiet", agentID: agentID, status: "ok",
      completedAt: Date(timeIntervalSince1970: 1), remotePayload: Data()))
    try await db.replaceOpenClawCronSnapshot(agentID: agentID, jobs: jobs, runs: runs)
    let initial = try await store.openClawCronPresentation(limits: [:])
    let key = DashboardStore.openClawCronHistoryKey(agentID: agentID, jobID: "frequent")
    #expect(initial.runs.filter { $0.jobID == "frequent" }.count == 50)
    #expect(initial.runs.contains { $0.id == "quiet-run" })
    #expect(initial.hasOlder == [key])
    let expanded = try await store.openClawCronPresentation(limits: [key: 100])
    #expect(expanded.runs.count == 56)
    #expect(expanded.hasOlder.isEmpty)
    #expect(try await db.openClawCronRuns(agentID: agentID).count == 56)
    #expect(try await db.openClawCronRuns(agentID: agentID, jobID: "frequent", limit: 1).first?.id == "run-54")
  }

  @Test func retainedResultsSurviveSummaryRefreshAndDeliverOnceAcrossRestartAndDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "results.sqlite")
    let db = try await WorkspaceDatabase(url: url)
    _ = try await db.createLocalACPSession(runtimeKind: .openclaw, title: "Seed", ownerDeviceID: UUID())
    let agentID = try await #require(db.dashboardAgents().first).id
    let run = OpenClawCronRun(id: "native-run", jobID: "deleted-job", agentID: agentID,
      status: "ok", output: "Native summary", nativeSessionID: "session-1",
      nativeSessionKey: "agent:main:cron:deleted-job:run:session-1", remotePayload: Data("{}".utf8))
    let fullOutput = String(repeating: "Full report 🌲\n", count: 1000)
    try await db.retainOpenClawResult(run, title: "Daily report", output: fullOutput)
    try await db.replaceOpenClawCronSnapshot(agentID: agentID, jobs: [], runs: [run])
    #expect(try await db.openClawCronRuns(agentID: agentID).first?.output == fullOutput)
    #expect(try await db.openClawCronJobs(agentID: agentID).first?.archiveState == .deleted)
    try await db.setOpenClawResultRoute(agentID: agentID, jobID: run.jobID, destination: "new")
    let collected = try await db.collectOpenClawResult(run, title: "Daily report", output: fullOutput, destination: "new")
    let conversationID = try #require(collected)
    #expect(try await db.workspaceOverview().conversations.first { $0.id == conversationID }?.unread == true)
    let reopened = try await WorkspaceDatabase(url: url)
    #expect(try await reopened.workspaceOverview().conversations.first { $0.id == conversationID }?.openClawSessionKey
      == reopened.openClawGatewaySession(conversationID: conversationID).sessionKey)
    #expect(try await reopened.collectOpenClawResult(run, title: "Daily report", output: fullOutput, destination: "new") == nil)
    #expect(try await reopened.conversationContent(id: conversationID).messages.count == 1)
    try await reopened.synchronizeOpenClawHistory(conversationID: conversationID,
      history: OpenClawGatewayHistory(payload: .object(["messages": .array([])])))
    #expect(try await reopened.conversationContent(id: conversationID).messages.count == 1)
    var connection: OpaquePointer?
    #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    #expect(sqlite3_exec(connection, "DELETE FROM dashboard_messages; DELETE FROM dashboard_conversations;", nil, nil, nil) == SQLITE_OK)
    #expect(try await reopened.collectOpenClawResult(run, title: "Daily report", output: fullOutput, destination: "new") == nil)
    #expect(try await reopened.collectedOpenClawResultIDs(agentID: agentID, jobID: run.jobID) == [run.id])
  }

  @Test func routeChangesAreRecheckedAndUnavailableDestinationsNeverAcknowledgeResults() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appending(path: "results.sqlite"))
    let seed = try await db.createLocalACPSession(runtimeKind: .openclaw, title: "Inbox", ownerDeviceID: UUID())
    let agentID = try await #require(db.dashboardAgents().first).id
    try await db.attachOpenClawGatewaySession(conversationID: seed, agentID: agentID, sessionKey: "agent:main:inbox")
    let unrelated = try await db.createLocalACPSession(runtimeKind: .codex, title: "Unrelated", ownerDeviceID: UUID())
    let snapshot = try await db.workspaceOverview()
    #expect(snapshot.conversations.first { $0.id == seed }?.openClawSessionKey == "agent:main:inbox")
    #expect(snapshot.conversations.first { $0.id == unrelated }?.openClawSessionKey == nil)
    let run = OpenClawCronRun(id: "run-1", jobID: "job-1", agentID: agentID, status: "error", remotePayload: Data())
    await #expect(throws: (any Error).self) {
      try await db.setOpenClawResultRoute(agentID: agentID, jobID: run.jobID, destination: "missing")
    }
    try await db.setOpenClawResultRoute(agentID: agentID, jobID: run.jobID, destination: seed)
    #expect(try await db.collectOpenClawResult(run, title: "Failure", output: "Failed", destination: "new") == nil)
    #expect(try await db.collectedOpenClawResultIDs(agentID: agentID, jobID: run.jobID).isEmpty)
    #expect(try await db.collectOpenClawResult(run, title: "Failure", output: "Failed", destination: seed) == seed)
    #expect(try await db.conversationContent(id: seed).messages.count == 1)
  }
}

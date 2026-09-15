import Foundation
import SQLite3
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

struct OpenClawScheduledResultTests {
  @Test func retainedResultsSurviveSummaryRefreshAndDeliverOnceAcrossRestartAndDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "results.sqlite")
    let db = try WorkspaceDatabase(url: url)
    _ = try db.createLocalACPSession(runtimeKind: .openclaw, title: "Seed", ownerDeviceID: UUID())
    let agentID = try #require(db.dashboardAgents().first).id
    let run = OpenClawCronRun(id: "native-run", jobID: "deleted-job", agentID: agentID,
      status: "ok", output: "Native summary", nativeSessionID: "session-1",
      nativeSessionKey: "agent:main:cron:deleted-job:run:session-1", remotePayload: Data("{}".utf8))
    let fullOutput = String(repeating: "Full report 🌲\n", count: 1000)
    try db.retainOpenClawResult(run, title: "Daily report", output: fullOutput)
    try db.replaceOpenClawCronSnapshot(agentID: agentID, jobs: [], runs: [run])
    #expect(try db.openClawCronRuns(agentID: agentID).first?.output == fullOutput)
    #expect(try db.openClawCronJobs(agentID: agentID).first?.archiveState == .deleted)
    try db.setOpenClawResultRoute(agentID: agentID, jobID: run.jobID, destination: "new")
    let collected = try db.collectOpenClawResult(run, title: "Daily report", output: fullOutput, destination: "new")
    let conversationID = try #require(collected)
    #expect(try db.workspaceOverview().conversations.first { $0.id == conversationID }?.unread == true)
    let reopened = try WorkspaceDatabase(url: url)
    #expect(try reopened.collectOpenClawResult(run, title: "Daily report", output: fullOutput, destination: "new") == nil)
    #expect(try reopened.conversationContent(id: conversationID).messages.count == 1)
    try reopened.synchronizeOpenClawHistory(conversationID: conversationID,
      history: OpenClawGatewayHistory(payload: .object(["messages": .array([])])))
    #expect(try reopened.conversationContent(id: conversationID).messages.count == 1)
    var connection: OpaquePointer?
    #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    #expect(sqlite3_exec(connection, "DELETE FROM dashboard_messages; DELETE FROM dashboard_conversations;", nil, nil, nil) == SQLITE_OK)
    #expect(try reopened.collectOpenClawResult(run, title: "Daily report", output: fullOutput, destination: "new") == nil)
    #expect(try reopened.collectedOpenClawResultIDs(agentID: agentID, jobID: run.jobID) == [run.id])
  }

  @Test func routeChangesAreRecheckedAndUnavailableDestinationsNeverAcknowledgeResults() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try WorkspaceDatabase(url: directory.appending(path: "results.sqlite"))
    let seed = try db.createLocalACPSession(runtimeKind: .openclaw, title: "Inbox", ownerDeviceID: UUID())
    let agentID = try #require(db.dashboardAgents().first).id
    try db.attachOpenClawGatewaySession(conversationID: seed, agentID: agentID, sessionKey: "agent:main:inbox")
    let run = OpenClawCronRun(id: "run-1", jobID: "job-1", agentID: agentID, status: "error", remotePayload: Data())
    #expect(throws: (any Error).self) {
      try db.setOpenClawResultRoute(agentID: agentID, jobID: run.jobID, destination: "missing")
    }
    try db.setOpenClawResultRoute(agentID: agentID, jobID: run.jobID, destination: seed)
    #expect(try db.collectOpenClawResult(run, title: "Failure", output: "Failed", destination: "new") == nil)
    #expect(try db.collectedOpenClawResultIDs(agentID: agentID, jobID: run.jobID).isEmpty)
    #expect(try db.collectOpenClawResult(run, title: "Failure", output: "Failed", destination: seed) == seed)
    #expect(try db.conversationContent(id: seed).messages.count == 1)
  }
}

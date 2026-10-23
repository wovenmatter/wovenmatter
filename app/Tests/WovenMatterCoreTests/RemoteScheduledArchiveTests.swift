import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

@Suite("Remote scheduled native archive")
struct RemoteScheduledArchiveTests {
  private func fixture(runtimeKind: AgentRuntimeKind = .defaultAgent) async throws -> (WorkspaceDatabase, URL, UUID, WorkspaceCalendarRun) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "wm-scheduled-archive-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let workspaceID = UUID()
    let task = WorkspaceCalendarTask(prompt: "Review the project", configuration: .init(
      runtimeKind: runtimeKind, workspaceID: workspaceID, title: "Review", permission: "full", nativeWorkingDirectory: "/workspace/project"))
    let run = WorkspaceCalendarRun(id: UUID().uuidString.lowercased(), eventID: UUID().uuidString.lowercased(),
      occurrenceIndex: 0, scheduledAt: Date(timeIntervalSince1970: 1_795_000_000),
      sessionID: UUID().uuidString.lowercased(), task: task, status: "accepted", title: "Review")
    return (database, directory, workspaceID, run)
  }

  private func value(_ json: String) throws -> GatewayJSONValue {
    try JSONDecoder().decode(GatewayJSONValue.self, from: Data(json.utf8))
  }

  private func nativeUpdate(sessionID: String, id: String = "commit:1:0", text: String = "Native tool result",
      runID: String? = nil) throws -> GatewayJSONValue {
    try nativeUpdate(sessionID: sessionID, records: [.init(id: id, revision: "1", runID: runID, kind: "tool.result",
      payload: #"{"type":"tool.result","content":[{"type":"image","mimeType":"image/png","data":"fixture"}],"details":{"exitCode":0}}"#,
      contentMode: "snapshot", text: text)])
  }

  private func nativeUpdate(sessionID: String, records: [WorkspaceNativeRunRecord]) throws -> GatewayJSONValue {
    let batch = WorkspaceNativeRunRecordBatch(sourceID: "builtin-pi-durable:fixture-store",
      nativeSessionID: sessionID, records: records)
    return .object(["sessionUpdate": .string("woven_native_record"),
      "recordBatch": try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(batch))])
  }

  private func importResult(_ database: WorkspaceDatabase, workspaceID: UUID, run: WorkspaceCalendarRun,
      updates: [GatewayJSONValue], nativeSessionID: String? = "native-session", receiptID: String = "receipt",
      updateOffset: Int = 0, complete: Bool = true) async throws {
    try await database.importRemoteCalendarTranscript(receiptID: receiptID, run: run,
      workspaceID: workspaceID, workspaceName: "Fixture", ownerDeviceID: UUID(),
      nativeSessionID: nativeSessionID, updates: updates, error: nil,
      completedAt: run.scheduledAt.addingTimeInterval(10), updateOffset: updateOffset, complete: complete)
  }

  @Test func foreignNativeSessionRollsBackAndReceiptCannotMoveAcrossRoutes() async throws {
    let (database, directory, workspaceID, run) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    await #expect(throws: (any Error).self) {
      try await importResult(database, workspaceID: workspaceID, run: run,
        updates: [try nativeUpdate(sessionID: "foreign-session")])
    }
    #expect(try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT id FROM workspace_calendar_remote_receipts", values: []).isEmpty
    })
    #expect(try await database.workspaceOverview().conversations.isEmpty)
    let update = try value(#"{"sessionUpdate":"context_compacted","summary":"Saved result"}"#)
    try await importResult(database, workspaceID: workspaceID, run: run, updates: [update], nativeSessionID: nil)
    try await importResult(database, workspaceID: workspaceID, run: run, updates: [update])
    let records = try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT native_session_id FROM workspace_history_events WHERE conversation_id=? AND source_id=?",
        values: [run.sessionID, "remote:" + workspaceID.uuidString.lowercased() + ":calendar"])
    }
    #expect(records.count == 1)
    #expect(records.first?.objectValue?["native_session_id"]?.stringValue == run.sessionID)
    await #expect(throws: (any Error).self) {
      try await importResult(database, workspaceID: workspaceID, run: run, updates: [update], nativeSessionID: "foreign")
    }
    var other = run
    other.sessionID = UUID().uuidString.lowercased()
    await #expect(throws: (any Error).self) {
      try await importResult(database, workspaceID: workspaceID, run: other, updates: [])
    }
    #expect(try await database.conversationContent(id: run.sessionID).messages.count == 2)
  }

}

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
      runtimeKind: runtimeKind, workspaceID: workspaceID, title: "Review", permission: "full"))
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

  @Test(arguments: [false, true])
  func scheduledCursorPreservesNativeMergeClearAndIgnoresMalformedOrChildUpdates(clear: Bool) async throws {
    let (database, directory, workspaceID, run) = try await fixture(runtimeKind: .cursor)
    defer { try? FileManager.default.removeItem(at: directory) }
    func update(_ payload: String, native: String = "native-session") throws -> GatewayJSONValue {
      try value("""
        {"sessionUpdate":"woven_cursor_todos","nativeSessionID":"\(native)","payload":\(payload)}
        """)
    }
    var updates = [
      try update(#"{"sessionId":"native-session","toolCallId":"first","merge":false,"todos":[{"id":"a","content":"Same label","status":"pending"},{"id":"b","content":"Same label","status":"pending"}]}"#),
      try update(#"{"sessionId":"native-session","toolCallId":"next","merge":true,"todos":[{"id":"a","title":"Same label","status":"inProgress"},{"id":"c","content":"New","status":"canceled"}]}"#),
      try update(#"{"sessionId":"native-session","toolCallId":"noop","merge":true,"todos":[]}"#),
      try update(#"{"sessionId":"child","toolCallId":"child","merge":false,"todos":[]}"#),
      try update(#"{"sessionId":"native-session","toolCallId":"foreign","merge":false,"todos":[]}"#, native: "foreign"),
      try update(#"{"sessionId":"native-session","toolCallId":"bad","merge":false,"todos":[{"id":"bad"}]}"#),
      try update(#"{"sessionId":"native-session","toolCallId":"duplicate","merge":false,"todos":[{"id":"a","content":"x"},{"id":"a","content":"y"}]}"#)
    ]
    if clear { updates.append(try update(#"{"sessionId":"native-session","toolCallId":"clear","merge":false,"todos":[]}"#)) }
    try await importResult(database, workspaceID: workspaceID, run: run, updates: Array(updates.prefix(2)), complete: false)
    try await importResult(database, workspaceID: workspaceID, run: run, updates: Array(updates.dropFirst(2)), updateOffset: 2)
    let page = try await database.conversationHistoryPage(id: run.sessionID, limit: 20)
    let plan = try #require(page.activities.first?.activity)
    #expect(page.activities.count == 1)
    #expect(plan.id == "cursor-todos")
    #expect(plan.planEntries.map(\.nativeID) == (clear ? [] : ["a", "b", "c"]))
    #expect(plan.planEntries.map(\.status) == (clear ? [] : ["in_progress", "pending", "cancelled"]))
    #expect(plan.planOperation == (clear ? "clear" : "merge"))
    assertSummaryParity(try await database.conversationHistoryPage(id: run.sessionID, limit: 20, compactActivities: true), page)
    let archive = try await database.read { try $0.historyRowsUnlocked(
      "SELECT payload FROM workspace_history_events WHERE conversation_id=? AND kind='native.acp.woven_cursor_todos' ORDER BY sequence", values: [run.sessionID]) }
    #expect(archive.count == updates.count)
  }

  @Test(arguments: [false, true])
  func scheduledHermesUsesCanonicalSuccessfulWriteResults(clear: Bool) async throws {
    let (database, directory, workspaceID, run) = try await fixture(runtimeKind: .hermes)
    defer { try? FileManager.default.removeItem(at: directory) }
    func update(_ payload: String, native: String = "native-session") throws -> GatewayJSONValue {
      try value("""
        {"sessionUpdate":"woven_hermes_tool_complete","nativeSessionID":"\(native)","payload":\(payload)}
        """)
    }
    var updates = [
      try update(#"{"name":"todo_list","args":{"todos":[{"id":"a","status":"completed"}],"merge":true},"result":{"revision":2,"todos":[{"id":"a","content":"Same label","status":"completed"},{"id":"b","content":"Same label","status":"pending"}]}}"#),
      try update(#"{"name":"todo","args":{},"result":{"revision":3,"todos":[]}}"#),
      try update(#"{"name":"todo","args":{"todos":[]},"result":{"revision":4,"todos":[],"error":"failed"}}"#),
      try update(#"{"name":"todo","args":{"todos":[]},"result":{"revision":5,"todos":[{"id":"bad"}]}}"#),
      try update(#"{"name":"todo","args":{"todos":[]},"result":{"revision":6,"todos":[]}}"#, native: "child"),
      try update(#"{"name":"todo","args":{"todos":[]},"result":{"revision":1,"todos":[]}}"#)
    ]
    if clear { updates.append(try update(#"{"name":"todo","args":{"todos":[]},"result":{"revision":7,"todos":[]}}"#)) }
    for _ in 0..<2 { try await importResult(database, workspaceID: workspaceID, run: run, updates: updates) }
    let page = try await database.conversationHistoryPage(id: run.sessionID, limit: 20)
    let plan = try #require(page.activities.first?.activity)
    #expect(page.activities.count == 1)
    #expect(plan.id == "hermes-checklist")
    #expect(plan.planOperation == (clear ? "clear" : "replace"))
    #expect(plan.planEntries.map(\.nativeID) == (clear ? [] : ["a", "b"]))
    #expect(plan.planEntries.map(\.status) == (clear ? [] : ["completed", "pending"]))
    assertSummaryParity(try await database.conversationHistoryPage(id: run.sessionID, limit: 20, compactActivities: true), page)
    let archive = try await database.read { try $0.historyRowsUnlocked(
      "SELECT payload FROM workspace_history_events WHERE conversation_id=? AND kind='native.acp.woven_hermes_tool_complete' ORDER BY sequence", values: [run.sessionID]) }
    #expect(archive.count == updates.count)
  }

  @Test func completeNativeAndUnknownRecordsSurviveReplayWithoutRepeatingMessages() async throws {
    let (database, directory, workspaceID, run) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let answer = try value(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done."}}"#)
    let compaction = try value(#"{"sessionUpdate":"context_compacted","summary":"Retained summary","unknownNativeField":{"image":{"uri":"native://artifact/1"}}}"#)
    let updates = [answer, compaction, try nativeUpdate(sessionID: "native-session", runID: run.id)]
    try await importResult(database, workspaceID: workspaceID, run: run, updates: updates)
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    try await importResult(reopened, workspaceID: workspaceID, run: run,
      updates: updates + [try nativeUpdate(sessionID: "native-session", id: "commit:2:0", text: "Late native summary", runID: run.id)])
    let archive = try await reopened.read { connection in
      try connection.historyRowsUnlocked("""
        SELECT source_id,native_record_id,run_id,payload,text_content FROM workspace_history_events
        WHERE conversation_id=? AND kind LIKE 'native.%' ORDER BY sequence
        """, values: [run.sessionID])
    }
    #expect(archive.count == 4)
    #expect(archive.allSatisfy { $0.objectValue?["run_id"]?.stringValue == run.id })
    #expect(archive.contains { $0.objectValue?["payload"]?.stringValue?.contains("unknownNativeField") == true })
    #expect(archive.contains { $0.objectValue?["text_content"]?.stringValue == "Late native summary" })
    #expect(archive.filter { $0.objectValue?["native_record_id"]?.stringValue == "commit:1:0" }.count == 1)
    #expect(archive.contains { $0.objectValue?["source_id"]?.stringValue == "remote:" + workspaceID.uuidString.lowercased() + ":builtin-pi-durable:fixture-store" })
    #expect(try await reopened.conversationContent(id: run.sessionID).messages.count == 2)
    let search = try await reopened.queryAgentHistory(.init(command: "search", search: "Late native summary"), callerID: run.sessionID)
    #expect(search.objectValue?["rows"]?.arrayValue?.count == 1)
  }

  @Test func boundedPagesReplayExactlyAndPublishOneCompleteReplyInOrdinalOrder() async throws {
    let (database, directory, workspaceID, run) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let updates: [GatewayJSONValue] = [try nativeUpdate(sessionID: "native-session", runID: run.id)] + (0..<12).map { index in
      .object(["sessionUpdate": .string("agent_message_chunk"),
        "content": .object(["type": .string("text"), "text": .string("\(index) ")])])
    }
    for offset in [0, 5] {
      let page = Array(updates[offset..<min(offset + 5, updates.count)])
      for _ in 0..<2 {
        try await importResult(database, workspaceID: workspaceID, run: run,
          updates: page, updateOffset: offset, complete: false)
      }
    }
    let pending = try await database.conversationContent(id: run.sessionID)
    #expect(pending.messages.isEmpty && pending.runs.isEmpty)
    let before = try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT id,native_record_id FROM workspace_history_events WHERE conversation_id=? AND run_id=? AND kind LIKE 'native.%' ORDER BY sequence",
        values: [run.sessionID, run.id])
    }
    #expect(before.count == 10)
    #expect(try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT id FROM workspace_calendar_remote_receipts", values: []).isEmpty
    })
    for _ in 0..<2 {
      try await importResult(database, workspaceID: workspaceID, run: run,
        updates: Array(updates[10...]), updateOffset: 10)
    }
    let content = try await database.conversationContent(id: run.sessionID)
    #expect(content.messages.count == 2 && content.runs.count == 1)
    #expect(content.messages.first { $0.role == "assistant" }?.content == (0..<12).map { "\($0) " }.joined())
    let after = try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT id,native_record_id FROM workspace_history_events WHERE conversation_id=? AND run_id=? AND kind LIKE 'native.%' ORDER BY sequence",
        values: [run.sessionID, run.id])
    }
    #expect(after.count == 13)
    #expect(Array(after.prefix(10)) == before)
    #expect(after.contains { $0.objectValue?["native_record_id"]?.stringValue == "receipt:receipt:update:11" })
    #expect(after.filter { $0.objectValue?["native_record_id"]?.stringValue == "commit:1:0" }.count == 1)
  }

  @Test func recurringSnapshotsRetainUnknownHistoryAndExplicitRunOwnership() async throws {
    let (database, directory, workspaceID, firstRun) = try await fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    var secondRun = firstRun
    secondRun.id = UUID().uuidString.lowercased()
    secondRun.occurrenceIndex = 1
    secondRun.scheduledAt = firstRun.scheduledAt.addingTimeInterval(60)
    let historical = WorkspaceNativeRunRecord(id: "historical", kind: "message", payload: #"{"text":"Earlier native history"}"#, contentMode: "snapshot")
    var first = WorkspaceNativeRunRecord(id: "first", runID: firstRun.id, kind: "message", payload: #"{"text":"First result"}"#, contentMode: "snapshot")
    let second = WorkspaceNativeRunRecord(id: "second", runID: secondRun.id, kind: "message", payload: #"{"text":"Second result"}"#, contentMode: "snapshot")
    let firstSnapshot = try nativeUpdate(sessionID: "native-session", records: [historical, first])
    // Later full native exports cannot identify which prior Woven run emitted
    // each record. A previously known association still remains authoritative.
    first.runID = nil
    let secondSnapshot = try nativeUpdate(sessionID: "native-session", records: [historical, first, second])
    for (run, snapshot, receipt) in [(firstRun, firstSnapshot, "first"), (secondRun, secondSnapshot, "second")] {
      for _ in 0..<2 {
        try await importResult(database, workspaceID: workspaceID, run: run,
          updates: [snapshot], receiptID: receipt, complete: false)
        try await importResult(database, workspaceID: workspaceID, run: run,
          updates: [], receiptID: receipt, updateOffset: 1)
      }
    }
    let records = try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT native_record_id,run_id FROM workspace_history_events WHERE conversation_id=? AND source_id=? ORDER BY sequence",
        values: [firstRun.sessionID, "remote:" + workspaceID.uuidString.lowercased() + ":builtin-pi-durable:fixture-store"])
    }
    #expect(records.count == 3)
    #expect(records[0].objectValue?["native_record_id"]?.stringValue == "historical")
    #expect(records[0].objectValue?["run_id"]?.stringValue == nil)
    #expect(records[1].objectValue?["run_id"]?.stringValue == firstRun.id)
    #expect(records[2].objectValue?["run_id"]?.stringValue == secondRun.id)
    let content = try await database.conversationContent(id: firstRun.sessionID)
    #expect(content.messages.count == 4 && content.runs.count == 2)
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

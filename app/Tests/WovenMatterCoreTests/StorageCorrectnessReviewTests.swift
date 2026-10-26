import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Storage correctness review", .serialized)
struct StorageCorrectnessReviewTests {



  @Test(arguments: [false, true])
  func hermesPersistedChecklistRemainReadable(clear: Bool) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.databaseURL)
    let todos: HermesValue = .array([["id": "a", "content": "Same label", "status": "completed"],
      ["id": "b", "content": "Same label", "status": "pending"]])
    let args: HermesValue = ["todos": .array([["id": "a", "status": "completed"]]), "merge": .bool(true)]
    let result: HermesValue = ["revision": .number(2), "todos": clear ? .array([]) : todos]
    let plan = try #require(HermesSessionArchive.checklistUpdate(["name": "todo_list", "args": args, "result": result]))
    #expect(HermesSessionArchive.checklistUpdate(["name": "todo_list", "args": args,
      "result": ["revision": .number(3), "todos": .array([["id": "invalid"]])]]) == nil)
    let rows: [HermesValue] = [["id": .number(1), "role": "assistant", "content": "Retained Hermes work"],
      ["id": .number(2), "role": "tool", "tool_call_id": "old-todo", "content": .string(result.json)]]
    // Seed the rows an older build already saved; no retired runtime is created or resumed.
    let conversation = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "History", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Retained history")
    try await db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: plan)
    try await db.completeLocalACPRun(runID: run.runID)
    for row in rows {
      try await db.recordHistory(.init(conversationID: conversation, harness: "hermes", kind: "import.message", payload: row.json, completeness: "native-export"))
    }
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET runtime_kind='hermes',acp_session_id=? WHERE conversation_id=?", ["hermes-import:L3RtcC9maXh0dXJl:parent",conversation])
      // Historical sessions carry the retirement marker created by import or
      // the execution-ownership migration, with no executable workspace root.
      try connection.toolsExecuteUnlocked("INSERT INTO retained_execution_history(conversation_id) VALUES(?)", [conversation])
      try connection.toolsExecuteUnlocked("DELETE FROM session_execution_roots WHERE conversation_id=?", [conversation])
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_archived=1 WHERE id=?", [conversation])
    } }
    let reopened = try await WorkspaceDatabase(url: fixture.databaseURL)
    let full = try await reopened.conversationHistoryPage(id: conversation, limit: 20)
    let retained = try #require(full.activities.first { $0.activity.kind == .plan }?.activity)
    #expect(retained.planOperation == (clear ? "clear" : "replace"))
    #expect(retained.planEntries.map(\.nativeID) == (clear ? [] : ["a", "b"]))
    assertSummaryParity(try await reopened.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true), full)
    let captures = try await reopened.read { try $0.historyRowsUnlocked(
      "SELECT payload FROM workspace_history_events WHERE conversation_id=? AND kind='import.message' ORDER BY sequence", values: [conversation]) }
    #expect(captures.compactMap { $0.objectValue?["payload"]?.stringValue } == rows.map(\.json))
    #expect(String(decoding: try await reopened.conversationExport(id: conversation, format: .fullRun), as: UTF8.self).contains("Retained Hermes work"))
    await #expect(throws: (any Error).self) { try await reopened.lockSessionFolder(id: conversation) }
  }
}

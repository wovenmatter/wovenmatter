import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Storage correctness review", .serialized)
struct StorageCorrectnessReviewTests {
  /// Libraries written by older builds can still hold sessions of harnesses
  /// Woven no longer runs. Those rows have no `AgentRuntimeKind`; they must open
  /// as plain read-only transcripts and never fail the session list.
  @Test(arguments: ["openclaw", "hermes", "cursor", "pi"])
  func retiredHarnessSessionRemainsReadable(retired: String) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let plan = AgentRunActivity(id: "checklist", kind: .plan, phase: "update", title: "Plan",
      planEntries: [.init(content: "Same label", status: "completed", nativeID: "a"),
        .init(content: "Same label", status: "pending", nativeID: "b")],
      planKind: "checklist", planOperation: "replace")
    let rows: [OpenCodeValue] = [["id": .number(1), "role": "assistant", "content": "Retained archived work"]]
    let liveTask = String(decoding: try JSONEncoder().encode(WorkspaceCalendarTask(prompt: "Summarize",
      configuration: .init(runtimeKind: .codex, title: "Scheduled task"))), as: UTF8.self)
    #expect(liveTask.contains(#""runtimeKind":"codex""#))
    // Seed the rows an older build already saved; no retired runtime is created or resumed.
    let conversation = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "History", ownerDeviceID: UUID())
    let live = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Live", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, input: .init(text: "Retained history"))
    try await db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: plan)
    try await db.completeLocalACPRun(runID: run.runID)
    for row in rows {
      try await db.recordHistory(.init(conversationID: conversation, harness: retired, kind: "import.message", payload: row.json, completeness: "native-export"))
    }
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET runtime_kind=?,acp_session_id='retired-session' WHERE conversation_id=?", [retired, conversation])
      try connection.toolsExecuteUnlocked("UPDATE dashboard_agents SET runtime_kind=? WHERE id=(SELECT agent_id FROM dashboard_conversations WHERE id=?)", [retired, conversation])
      // Historical sessions carry the retirement marker created by import or
      // the execution-ownership migration, with no executable workspace root.
      try connection.toolsExecuteUnlocked("INSERT INTO retained_execution_history(conversation_id) VALUES(?)", [conversation])
      try connection.toolsExecuteUnlocked("DELETE FROM session_execution_roots WHERE conversation_id=?", [conversation])
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_archived=1 WHERE id=?", [conversation])
      // A scheduled run an older build kept for that harness, beside a live one.
      try connection.toolsExecuteUnlocked("INSERT INTO dashboard_calendar_items(id,calendar_json) VALUES('retired-event','{}')", [])
      for (id, kind) in [("retired-run", retired), ("live-run", "codex")] {
        try connection.toolsExecuteUnlocked("""
          INSERT INTO workspace_calendar_runs(id,event_id,scheduled_at,occurrence_index,session_id,task_json,title,status,coalesced_through)
          VALUES(?,'retired-event',?,0,?,?,'Scheduled task','completed',0)
          """, [id, id == "live-run" ? "2026-01-02T00:00:00Z" : "2026-01-01T00:00:00Z", id == "live-run" ? live : conversation, liveTask.replacingOccurrences(of: #""runtimeKind":"codex""#, with: #""runtimeKind":"\#(kind)""#)])
      }
    } }
    let reopened = try await fixture.openDatabase()
    #expect(try await reopened.calendarRuns().map(\.id) == ["live-run"])
    await #expect(throws: LocalACPSessionDatabaseError.sessionNotFound) {
      try await reopened.localACPSession(conversationID: conversation)
    }
    #expect(try await reopened.localACPSession(conversationID: live).runtimeKind == .codex)
    let agents = try await reopened.read { try $0.dashboardAgents() }
    #expect(!agents.isEmpty && agents.allSatisfy { $0.runtimeKind == .codex })
    let overview = try await reopened.read { try $0.workspaceOverview() }
    #expect(Set(overview.conversations.map(\.id)).isSuperset(of: [conversation, live]))
    let full = try await reopened.conversationHistoryPage(id: conversation, limit: 20)
    let retained = try #require(full.activities.first { $0.activity.kind == .plan }?.activity)
    #expect(retained.planEntries.map(\.nativeID) == ["a", "b"])
    assertSummaryParity(try await reopened.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true), full)
    let captures = try await reopened.read { try $0.historyRowsUnlocked(
      "SELECT payload FROM workspace_history_events WHERE conversation_id=? AND kind='import.message' ORDER BY sequence", values: [conversation]) }
    #expect(captures.compactMap { $0.objectValue?["payload"]?.stringValue } == rows.map(\.json))
    #expect(String(decoding: try await reopened.conversationExport(id: conversation, format: .fullRun), as: UTF8.self).contains("Retained archived work"))
    await #expect(throws: (any Error).self) { try await reopened.lockSessionFolder(id: conversation) }
  }

  /// A library from before OpenClaw's removal still has the gateway's tables
  /// and triggers. Opening it drops them; its chats stay plain transcripts.
  @Test func retiredOpenClawTablesDropWithoutLosingTranscripts() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let conversation = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Gateway chat", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, input: .init(text: "Kept gateway prompt"))
    try await db.completeLocalACPRun(runID: run.runID)
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("""
        CREATE TABLE desktop_openclaw_gateway_sessions(conversation_id TEXT PRIMARY KEY, agent_id TEXT NOT NULL,
          session_key TEXT NOT NULL, model TEXT, thinking_level TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
        """, [])
      try connection.toolsExecuteUnlocked("CREATE TABLE desktop_openclaw_import_activity(conversation_id TEXT PRIMARY KEY, imported_at TEXT NOT NULL)", [])
      try connection.toolsExecuteUnlocked("""
        CREATE TABLE desktop_openclaw_run_inputs(conversation_id TEXT NOT NULL, local_run_id TEXT NOT NULL, remote_run_id TEXT NOT NULL,
          user_message_id TEXT NOT NULL, assistant_message_id TEXT NOT NULL, PRIMARY KEY (conversation_id, remote_run_id))
        """, [])
      try connection.toolsExecuteUnlocked("CREATE INDEX desktop_openclaw_gateway_sessions_agent ON desktop_openclaw_gateway_sessions(agent_id, updated_at DESC)", [])
      try connection.toolsExecuteUnlocked("""
        CREATE TRIGGER desktop_openclaw_run_inputs_delete AFTER DELETE ON dashboard_conversations BEGIN
          DELETE FROM desktop_openclaw_run_inputs WHERE conversation_id = OLD.id; END
        """, [])
      try connection.toolsExecuteUnlocked("""
        CREATE TRIGGER history_openclaw_import AFTER INSERT ON desktop_openclaw_gateway_sessions BEGIN
          UPDATE workspace_history_events SET conversation_id=new.conversation_id WHERE conversation_id IS NULL; END
        """, [])
      // An older execution-stream locality check looked the gateway table up.
      try connection.toolsExecuteUnlocked("""
        CREATE TRIGGER legacy_gateway_locality AFTER UPDATE ON dashboard_conversations
        WHEN NOT EXISTS (SELECT 1 FROM desktop_openclaw_gateway_sessions g WHERE g.conversation_id = NEW.id) BEGIN SELECT 1; END
        """, [])
      try connection.toolsExecuteUnlocked("DELETE FROM desktop_local_acp_sessions WHERE conversation_id=?", [conversation])
      try connection.toolsExecuteUnlocked("""
        INSERT INTO desktop_openclaw_gateway_sessions VALUES(?,'eddie','agent:eddie:main',NULL,NULL,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')
        """, [conversation])
      try connection.toolsExecuteUnlocked("INSERT INTO desktop_openclaw_import_activity VALUES(?,'2026-01-02T00:00:00Z')", [conversation])
      try connection.toolsExecuteUnlocked("INSERT INTO desktop_openclaw_run_inputs VALUES(?,?,'remote',?,?)", [conversation, run.runID, run.userMessageID, run.assistantMessageID])
    } }
    let reopened = try await fixture.openDatabase()
    let leftovers = try await reopened.read { try $0.historyRowsUnlocked(
      "SELECT name FROM sqlite_master WHERE instr(name,'openclaw') > 0 OR instr(COALESCE(sql,''),'desktop_openclaw_') > 0 OR name='legacy_gateway_locality'", values: []) }
    #expect(leftovers.isEmpty, "\(leftovers)")
    let overview = try await reopened.read { try $0.workspaceOverview() }
    let listed = try #require(overview.conversations.first { $0.id == conversation })
    #expect(listed.localRuntimeKind == nil && listed.importedAt == "2026-01-02T00:00:00Z")
    let page = try await reopened.conversationHistoryPage(id: conversation, limit: 20)
    #expect(page.messages.contains { $0.content == "Kept gateway prompt" })
    // No remaining trigger reaches a dropped table.
    try await reopened.mutateConversation(id: conversation, mutation: .rename("Renamed gateway chat"))
  }
}

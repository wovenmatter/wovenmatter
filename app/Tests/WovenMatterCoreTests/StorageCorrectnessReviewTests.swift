import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Storage correctness review", .serialized)
struct StorageCorrectnessReviewTests {
  @Test(arguments: [false, true])
  func identicalOpenCodeSnapshotRestoresActivitiesAndDelta(markerAlreadyRemoved: Bool) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await db.createLocalACPSession(runtimeKind: .opencode, title: "Restore",
      ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "native"))
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.messages = [["id": "reply", "type": "assistant",
      "time": ["created": .number(1000), "completed": .number(2000)], "content": .array([
        ["id": "tool", "type": "tool", "name": "read", "state": ["status": "completed", "output": "unchanged"]],
        ["id": "answer", "type": "text", "text": "Done"]
      ])]]
    try await db.saveOpenCodeSnapshot(snapshot, conversationID: conversation)
    let before = try await db.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    #expect(before.activities.count == 2)
    let captured = try await db.conversationHistoryPage(id: conversation, limit: 20)
    try await db.saveOpenCodeSnapshot(OpenCodeSessionSnapshot(), conversationID: conversation)
    let hidden = try await db.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: before.activityRevision, knownActivityRunIDs: before.runs.map(\.id))
    #expect(hidden.messages.isEmpty && hidden.activities.isEmpty)
    #expect(Set(hidden.removedActivityIDs) == Set(before.activities.map(\.id)))
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    // JSONEncoder key order can vary even for identical activities. Disable the
    // update trigger to deterministically exercise payload-independent restoration.
    try sql.execute("DROP TRIGGER activity_index_event_update")
    if markerAlreadyRemoved { try sql.execute("DELETE FROM desktop_opencode_hidden_messages") }
    try await db.saveOpenCodeSnapshot(snapshot, conversationID: conversation)
    let restored = try await db.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: hidden.activityRevision, knownActivityRunIDs: before.runs.map(\.id))
    #expect(restored.activities.map(\.id) == before.activities.map(\.id))
    #expect(restored.removedActivityIDs.isEmpty)
    #expect(try #require(restored.activityRevision) > #require(hidden.activityRevision))
    #expect(try await db.conversationHistoryPage(id: conversation, limit: 20).activities == captured.activities)
    #expect(try await db.openCodeSnapshot(conversationID: conversation)?.messages == snapshot.messages)
    let reopened = try await WorkspaceDatabase(url: fixture.databaseURL, readOnlyProjection: true)
    assertSummaryParity(try await reopened.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true),
      try await reopened.conversationHistoryPage(id: conversation, limit: 20))
  }

  @Test func versionOneTriggersAreReplacedOnceAndChronologyChangesProduceDeltas() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await db.createLocalACPSession(runtimeKind: .codex, title: "Upgrade", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Fixture")
    try await db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: .init(id: "tool", kind: .tool, content: "kept"))
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    try sql.execute("""
      INSERT INTO dashboard_run_trace_events(id,conversation_id,run_id,seq,event_type,is_visible,content,raw_event_json,created_at)
      VALUES('visible','\(conversation)','\(run.runID)',1,'reasoning',1,'kept','{}','2026-01-01'),
        ('hidden','\(conversation)','\(run.runID)',2,'reasoning',0,'hidden','{}','2026-01-01');
      DELETE FROM desktop_activity_index_schema;
      INSERT INTO desktop_activity_index_schema VALUES(1);
      DROP TRIGGER activity_index_event_update;
      DROP TRIGGER activity_index_trace_update;
      CREATE TRIGGER activity_index_event_update AFTER UPDATE ON dashboard_run_events
        WHEN old.content IS NOT new.content BEGIN SELECT 1; END;
      CREATE TRIGGER activity_index_trace_update AFTER UPDATE ON dashboard_run_trace_events
        WHEN old.content IS NOT new.content BEGIN SELECT 1; END;
      """)
    let before = try await db.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    // Simulate a missed correction under the old trigger before opening the upgrade.
    try sql.execute("UPDATE dashboard_run_events SET created_at='2026-01-02' WHERE run_id='\(run.runID)'")
    let upgraded = try await WorkspaceDatabase(url: fixture.databaseURL)
    let migrated = try await upgraded.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: before.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(Set(migrated.activities.map(\.id)) == Set(before.activities.map(\.id)))
    #expect(migrated.activities.first { $0.activity.id == "tool" }?.createdAt == "2026-01-02")
    #expect(migrated.removedActivityIDs == ["trace-hidden"])
    #expect(try sql.scalar("SELECT count(*) FROM desktop_activity_index WHERE summary IS NOT NULL") == 0)
    #expect(try sql.scalar("SELECT MAX(version) FROM desktop_activity_index_schema") == 2)
    try sql.execute("""
      UPDATE dashboard_run_events SET created_at='2026-01-03' WHERE run_id='\(run.runID)';
      UPDATE dashboard_run_trace_events SET seq=9 WHERE id='visible';
      """)
    let delta = try await upgraded.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: migrated.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(delta.activities.count == 2)
    #expect(delta.activities.first { $0.id == "trace-visible" }?.sequence == 9)
    #expect(delta.activities.first { $0.activity.id == "tool" }?.createdAt == "2026-01-03")
    let reopened = try await WorkspaceDatabase(url: fixture.databaseURL)
    let unchanged = try await reopened.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: delta.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(unchanged.activities.isEmpty && unchanged.removedActivityIDs.isEmpty)
    #expect(unchanged.activityRevision == delta.activityRevision)
    #expect(try sql.scalar("SELECT count(*) FROM dashboard_run_trace_events") == 2)
  }

  @Test func traceSequenceBeatsRecordIDAndSurvivesCompactReadAndCorrection() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await db.createLocalACPSession(runtimeKind: .codex, title: "Trace", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Fixture")
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    try sql.execute("""
      INSERT INTO dashboard_run_trace_events(id,conversation_id,run_id,seq,event_type,event_name,is_visible,content,raw_event_json,created_at)
      VALUES('z','\(conversation)','\(run.runID)',1,'reasoning','reasoning.delta',1,'first ','{"data":{"itemId":"thought"}}','2026-01-01'),
        ('a','\(conversation)','\(run.runID)',2,'reasoning','reasoning.delta',1,'second','{"data":{"itemId":"thought"}}','2026-01-01');
      """)
    let full = try await db.conversationHistoryPage(id: conversation, limit: 20)
    let compact = try await db.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    assertSummaryParity(compact, full)
    #expect(full.activities.map(\.id) == ["trace-z", "trace-a"])
    #expect(full.activities.map(\.sequence) == [1, 2])
    #expect(try await db.conversationActivityDetails(conversationID: conversation, runID: run.runID, activityID: "thought")?.content == "first second")
    try sql.execute("UPDATE dashboard_run_trace_events SET seq=0 WHERE id='a'")
    let delta = try await db.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: compact.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(delta.activities.map(\.id) == ["trace-a"])
    #expect(delta.activities.first?.sequence == 0)
    #expect(try await db.conversationHistoryPage(id: conversation, limit: 20).activities.map(\.id) == ["trace-a", "trace-z"])
  }

  @Test(arguments: [false, true])
  func hermesArchiveDTOAndPersistedChecklistRemainReadable(clear: Bool) async throws {
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
    let archived = HermesSessionImport(identity: HermesSessionArchive.identity(home: "/tmp/fixture", storedID: "parent", imported: true),
      title: "History", createdAt: Date(), messages: rows)
    // Seed the rows an older build already saved; no retired runtime is created or resumed.
    let conversation = try await db.createLocalACPSession(runtimeKind: .codex, title: "History", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Retained history")
    try await db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: plan)
    try await db.completeLocalACPRun(runID: run.runID)
    try await db.recordNativeRunRecords(archived.nativeArchiveBatch(), conversationID: conversation, harness: "hermes")
    for row in rows {
      try await db.recordHistory(.init(conversationID: conversation, harness: "hermes", kind: "import.message", payload: row.json, completeness: "native-export"))
    }
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET runtime_kind='hermes',acp_session_id=? WHERE conversation_id=?", [archived.identity,conversation])
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

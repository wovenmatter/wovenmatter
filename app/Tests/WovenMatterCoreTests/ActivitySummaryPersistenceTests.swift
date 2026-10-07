import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Compact activity persistence", .serialized)
struct ActivitySummaryPersistenceTests {
  @Test("cached summaries preserve canonical text, ordering, merged state, and disclosure details")
  func summaryAndFullHistoryParity() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex,
      title: "Parity", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Inspect")
    let commentary = String(repeating: "Checking café 🧵.\n", count: 80)
    let answer = "```swift\nlet café = 1\n```\n"
    let large = String(repeating: "large output 🧵\n", count: 4_096)
    let changes = [AgentRunFileChange(path: "fixture.swift", oldText: "old\n",
      newText: large, unifiedDiff: "@@ -1 +1 @@\n-old\n+new\n")]
    let entries = [AgentRunPlanEntry(content: "Inspect", status: "completed"),
      AgentRunPlanEntry(content: "Verify", priority: "high", status: "in_progress")]
    let children = try #require(AgentRunActivity.builtInSubagentSnapshot(rawPayloadJSON:
      #"{"subagents":[{"id":"child","name":"Reviewer","state":"running","history":[{"id":"child-plan","kind":"plan","content":"Child only"}]}]}"#))
    try await database.appendLocalACPAssistantChunk(runID: run.runID, chunk: commentary)
    try await database.recordAssistantStreamBoundary(runID: run.runID)
    for activity in [
      AgentRunActivity(id: "tool", kind: .tool, title: large, detail: large, status: "running",
        toolName: "read_file", content: large, rawInputJSON: #"{"path":"fixture.swift"}"#,
        rawOutputJSON: large, rawPayloadJSON: #"{"native":"kept"}"#),
      AgentRunActivity(id: "thought", kind: .thought, content: "first ", contentIsDelta: true),
      AgentRunActivity(id: "plan", kind: .plan, content: large, planEntries: entries),
      AgentRunActivity(id: "change", kind: .fileChange, content: large,
        locations: [.init(path: "fixture.swift", line: 1)], changes: changes), children
    ] { try await database.upsertDeviceOwnedRunActivity(runID: run.runID, activity: activity) }
    try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "tool", kind: .tool, status: "completed"))
    try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "thought", kind: .thought, content: "second", contentIsDelta: true))
    try await database.appendLocalACPAssistantChunk(runID: run.runID, chunk: answer)
    try await database.recordAssistantStreamBoundary(runID: run.runID, finalSegment: true)
    try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "late", kind: .thought, content: "Late reasoning"))
    let full = try await database.conversationHistoryPage(id: conversation, limit: 20)
    let compact = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    assertSummaryParity(compact, full)
    #expect(compact.activityReadMetrics.fullRowsDecoded == 0)
    #expect(compact.activityReadMetrics.summaryRows == full.activities.count)
    let tool = try #require(compact.activities.first { $0.activity.id == "tool" }?.activity)
    #expect(tool.status == "completed")
    #expect(tool.content == String(large.prefix(280)))
    #expect(tool.title == String(large.prefix(280)))
    #expect(tool.detail == String(large.prefix(280)))
    #expect(tool.detailsAvailable == true)
    #expect(compact.activities.first { $0.activity.id == "thought" }?.activity.content == "first second")
    #expect(compact.activities.first { $0.activity.id == "plan" }?.activity.planEntries == entries)
    #expect(compact.activities.first { $0.activity.id == "plan" }?.activity.content == large)
    #expect(compact.activities.first { $0.activity.id == "change" }?.activity.changes
      == [.init(path: "fixture.swift", newText: "", additionCount: 1, deletionCount: 1)])
    #expect(compact.activities.first { $0.activity.id == "change" }?.activity.content == String(large.prefix(280)))
    let childSummary = try #require(compact.activities.first { $0.activity.id == children.id }?.activity)
    #expect(childSummary.subagents == nil && childSummary.detailsAvailable == true)
    #expect(compact.activities.filter { $0.activity.kind == .plan }.count == 1)
    let reply = try #require(compact.messages.first { $0.id == run.assistantMessageID })
    let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
      activities: compact.activities.map(\.activity))
    #expect(projection.body == answer)
    #expect(projection.commentary.map(\.content) == [commentary])
    for record in full.activities {
      #expect(try await database.conversationActivityDetails(conversationID: conversation,
        runID: run.runID, activityID: record.activity.id) == record.activity)
    }
    let reopened = try await WorkspaceDatabase(url: fixture.databaseURL, readOnlyProjection: true)
    #expect(try await reopened.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true) == compact)
  }

  @Test("an unchanged cursor decodes nothing; one large changed item never reloads its siblings",
    arguments: [false, true])
  func oneChangedLargeOutput(directSQL: Bool) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex,
      title: "Large outputs", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Inspect")
    let large = String(repeating: "fixture output\n", count: 16_384)
    for index in 0..<8 {
      try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
        activity: .init(id: "tool-\(index)", kind: .tool, content: large, rawOutputJSON: large))
    }
    let before = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    let cursor = try #require(before.activityRevision)
    let unchanged = try await database.conversationHistoryPage(id: conversation, limit: 20,
      compactActivities: true, activityCursor: cursor, knownActivityRunIDs: [run.runID])
    #expect(unchanged.activitiesAreDelta)
    #expect(unchanged.activities.isEmpty && unchanged.removedActivityIDs.isEmpty)
    #expect(unchanged.activityRevision == cursor)
    #expect(unchanged.activityReadMetrics == .init())
    let changed = AgentRunActivity(id: "tool-3", kind: .tool, status: "completed",
      content: "changed\n" + large, rawOutputJSON: large + "tail")
    if directSQL {
      let sql = try PersistenceSQL(url: fixture.databaseURL)
      try sql.execute("UPDATE dashboard_run_events SET content='\(try encodedSQL(changed))' WHERE id='\(run.runID):activity:tool-3'")
    } else {
      try await database.upsertDeviceOwnedRunActivity(runID: run.runID, activity: changed)
    }
    let delta = try await database.conversationHistoryPage(id: conversation, limit: 20,
      compactActivities: true, activityCursor: cursor, knownActivityRunIDs: [run.runID])
    #expect(delta.activities.map(\.activity.id) == ["tool-3"])
    #expect(try #require(delta.activityRevision) > cursor)
    #expect(delta.activities.first?.activity.detailVersion != before.activities.first { $0.activity.id == "tool-3" }?.activity.detailVersion)
    #expect(delta.activityReadMetrics == .init(summaryRows: directSQL ? 0 : 1, fullRowsDecoded: directSQL ? 1 : 0))
    #expect(delta.activities.first?.activity.content == String(("changed\n" + large).prefix(280)))
    #expect(try await database.conversationActivityDetails(conversationID: conversation,
      runID: run.runID, activityID: "tool-3") == changed)
    let next = try await database.conversationHistoryPage(id: conversation, limit: 20,
      compactActivities: true, activityCursor: delta.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(next.activities.isEmpty && next.activityReadMetrics == .init())
  }

  @Test("direct reconciliation SQL updates, deletes, and hides traces through the same delta contract")
  func directReconciliationAndTombstones() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .openclaw,
      title: "Reconcile", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Inspect")
    for id in ["keep", "obsolete"] {
      try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
        activity: .init(id: id, kind: .tool, content: "old", rawOutputJSON: "old detail"))
    }
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    try sql.execute("""
      INSERT INTO dashboard_run_trace_events(id,conversation_id,run_id,event_type,is_visible,content,created_at)
      VALUES('visible','\(conversation)','\(run.runID)','reasoning',1,'trace thought','2026-01-01');
      """)
    let before = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    try await database.completeLocalACPRun(runID: run.runID)
    let replacement = AgentRunActivity(id: "keep", kind: .tool, status: "failed", content: "corrected", rawOutputJSON: "new detail")
    try sql.execute("""
      BEGIN;
      UPDATE dashboard_run_events SET content='\(try encodedSQL(replacement))' WHERE id='\(run.runID):activity:keep';
      DELETE FROM dashboard_run_events WHERE id='\(run.runID):activity:obsolete';
      UPDATE dashboard_run_trace_events SET is_visible=0 WHERE id='visible';
      COMMIT;
      """)
    let delta = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: before.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(delta.activities.map(\.activity.id) == ["keep"])
    #expect(Set(delta.removedActivityIDs) == ["\(run.runID):activity:obsolete", "trace-visible"])
    #expect(delta.activityReadMetrics.fullRowsDecoded == 1)
    let current = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    #expect(applying(delta, to: before.activities) == current.activities)
    assertSummaryParity(current, try await database.conversationHistoryPage(id: conversation, limit: 20))
    #expect(try await database.conversationActivityDetails(conversationID: conversation,
      runID: run.runID, activityID: "obsolete") == nil)
    // A previously hidden legacy row can become visible again, with a fresh revision.
    try sql.execute("UPDATE dashboard_run_trace_events SET is_visible=1,content='repaired trace' WHERE id='visible'")
    let visible = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: delta.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(visible.activities.map(\.id) == ["trace-visible"])
    #expect(visible.activities.first?.activity.content == "repaired trace")
    #expect(visible.removedActivityIDs.isEmpty)
  }

  @Test("OpenCode replacement reorders parts and empty snapshots remove obsolete activity", arguments: [false, true])
  func openCodeReplacementAndEmptyParts(emptyMessages: Bool) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .opencode,
      title: "Snapshot", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "native"))
    let first: OpenCodeValue = ["id": "first", "type": "text", "text": "Checking\n"]
    let last: OpenCodeValue = ["id": "last", "type": "text", "text": "Answer\n"]
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.messages = [["id": "reply", "type": "assistant",
      "time": ["created": .number(1000), "completed": .number(2000)], "content": .array([first,
        ["id": "tool", "type": "tool", "name": "read", "state": ["status": "completed", "output": "old"]], last])]]
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: conversation)
    let initial = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    let known = initial.runs.map(\.id)
    snapshot.messages[0]["content"] = .array([last, first])
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: conversation)
    let replacement = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: initial.activityRevision, knownActivityRunIDs: known)
    #expect(replacement.activities.map(\.activity.id) == ["reply:last", "reply:first"])
    #expect(Set(replacement.removedActivityIDs) == Set(initial.activities.filter { $0.activity.kind == .tool }.map(\.id)))
    let replaced = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    #expect(applying(replacement, to: initial.activities) == replaced.activities)
    assertSummaryParity(replaced, try await database.conversationHistoryPage(id: conversation, limit: 20))
    if emptyMessages { snapshot.mergeMessages([], replace: true) }
    else { snapshot.messages[0]["content"] = .array([]) }
    try await database.saveOpenCodeSnapshot(snapshot, conversationID: conversation)
    let empty = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: replacement.activityRevision, knownActivityRunIDs: known)
    #expect(empty.activities.isEmpty)
    #expect(Set(empty.removedActivityIDs) == Set(replaced.activities.map(\.id)))
    #expect(applying(empty, to: replaced.activities).isEmpty)
    if emptyMessages { #expect(empty.messages.isEmpty) }
    else { #expect(empty.messages.first?.content == "") }
    #expect(empty.activityReadMetrics == .init())
    let reopened = try await WorkspaceDatabase(url: fixture.databaseURL, readOnlyProjection: true)
    #expect(try await reopened.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true).activities.isEmpty)
  }

  @Test("Gateway failure after activity writes rolls back text, traces, summaries, and cursor")
  func gatewayTransactionRollback() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .openclaw,
      title: "Rollback", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Inspect")
    try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "existing", kind: .tool, content: "kept"))
    let before = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    // Fail only after the projection has already claimed its trace, appended
    // canonical text, and inserted a commentary boundary in this transaction.
    try sql.execute("""
      CREATE TRIGGER fixture_abort_activity BEFORE INSERT ON dashboard_run_events
      WHEN new.id='\(run.runID):activity:reject' BEGIN SELECT RAISE(ABORT,'fixture rollback'); END;
      """)
    await #expect(throws: WorkspaceDatabaseError.self) {
      try await database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
        eventName: "agent", sequence: 1, eventType: "assistant_delta", eventPhase: "update", toolName: nil,
        content: "lost", rawEventJSON: #"{"fixture":true}"#, assistantMessageID: run.assistantMessageID,
        assistantMutation: .append("lost"), streamBoundary: true,
        activity: .init(id: "reject", kind: .tool, content: "lost"))
    }
    #expect(try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true) == before)
    #expect(try await database.deviceOwnedGatewayTraceEvents(runID: run.runID).isEmpty)
    let delta = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: before.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(delta.activities.isEmpty && delta.removedActivityIDs.isEmpty)
    #expect(delta.activityRevision == before.activityRevision)
    try sql.execute("DROP TRIGGER fixture_abort_activity")
    #expect(try await database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", sequence: 1, eventType: "assistant_delta", eventPhase: "update", toolName: nil,
      content: "kept", rawEventJSON: #"{"fixture":true}"#, assistantMessageID: run.assistantMessageID,
      assistantMutation: .append("kept"), streamBoundary: true,
      activity: .init(id: "reject", kind: .tool, content: "kept")) == .applied)
    let committed = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: before.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(Set(committed.activities.map(\.activity.kind)) == [.assistant, .tool])
    #expect(committed.messages.first { $0.id == run.assistantMessageID }?.content == "kept")
    #expect(try #require(committed.activityRevision) > #require(before.activityRevision))
  }

  @Test("historical metadata backfills once and read-only frontends preserve legacy fallback across reopen")
  func historicalBackfillAndReadOnlyFrontend() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex,
      title: "Historical", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Inspect")
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    // Model the pre-index schema, retaining the real event/archive schema and writers.
    for source in ["event", "trace"] {
      for operation in ["insert", "update", "delete"] {
        try sql.execute("DROP TRIGGER activity_index_\(source)_\(operation)")
      }
    }
    try sql.execute("DROP TABLE desktop_activity_index; DROP TABLE desktop_activity_revision; DROP TABLE desktop_activity_index_schema;")
    let native = AgentRunActivity(id: "native", kind: .tool, status: "completed", content: String(repeating: "é🧵", count: 1_000),
      position: 2, rawOutputJSON: "complete native output")
    try sql.execute("""
      INSERT INTO dashboard_run_events(id,conversation_id,run_id,event_type,content,created_at) VALUES
        ('native-record','\(conversation)','\(run.runID)','tool','\(try encodedSQL(native))','2026-01-02'),
        ('legacy-record','\(conversation)','\(run.runID)','progress','undecodable {legacy','2026-01-01');
      INSERT INTO dashboard_run_trace_events(id,conversation_id,run_id,event_type,is_visible,content,raw_event_json,created_at) VALUES
        ('legacy-trace','\(conversation)','\(run.runID)','reasoning',1,'historical thought','{}','2026-01-03'),
        ('hidden','\(conversation)','\(run.runID)','reasoning',0,'never display','{}','2026-01-03'),
        ('assistant-delta','\(conversation)','\(run.runID)','assistant_delta',1,'canonical only','{}','2026-01-03');
      """)
    let full = try await database.conversationHistoryPage(id: conversation, limit: 20)
    let backend = try await WorkspaceDatabase(url: fixture.databaseURL)
    #expect(try sql.scalar("SELECT count(*) FROM desktop_activity_index WHERE summary IS NOT NULL") == 0)
    let frontend = try await WorkspaceDatabase(url: fixture.databaseURL, readOnlyProjection: true)
    let compact = try await frontend.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    assertSummaryParity(compact, full)
    #expect(compact.activities.map(\.id) == ["native-record", "legacy-record", "trace-legacy-trace"])
    #expect(compact.activities.first { $0.id == "legacy-record" }?.activity.content == "undecodable {legacy")
    #expect(compact.activityReadMetrics == .init(fullRowsDecoded: 3))
    #expect(compact.activityRevision == 0)
    #expect(try sql.scalar("SELECT count(*) FROM desktop_activity_index WHERE summary IS NOT NULL") == 0)
    #expect(try await frontend.conversationActivityDetails(conversationID: conversation,
      runID: run.runID, activityID: "native") == native)
    await #expect(throws: WorkspaceDatabaseError.readOnlyProjection) {
      try await frontend.upsertDeviceOwnedRunActivity(runID: run.runID, activity: .init(id: "denied", kind: .tool))
    }
    let reopened = try await WorkspaceDatabase(url: fixture.databaseURL)
    #expect(try await reopened.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true) == compact)
    let unchanged = try await frontend.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: compact.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(unchanged.activities.isEmpty && unchanged.activityReadMetrics == .init())
    try await backend.upsertDeviceOwnedRunActivity(runID: run.runID, activity: .init(id: "new", kind: .thought, content: "live"))
    let live = try await frontend.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: compact.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(live.activities.map(\.activity.id) == ["new"])
    #expect(live.activityReadMetrics == .init(summaryRows: 1))
  }

  @Test("paging hydrates newly seen runs and refreshes known runs outside the latest message page")
  func paginationAndKnownRunCorrections() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex,
      title: "Pages", ownerDeviceID: UUID())
    var runIDs: [String] = []
    for index in 0..<3 {
      let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Turn \(index)",
        createdAt: Date(timeIntervalSince1970: Double(1_700_000_000 + index * 10)))
      runIDs.append(run.runID)
      try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
        activity: .init(id: "tool", kind: .tool, content: "turn \(index)"))
      try await database.completeLocalACPRun(runID: run.runID)
    }
    let latest = try await database.conversationHistoryPage(id: conversation, limit: 2, compactActivities: true)
    #expect(latest.runs.map(\.id) == [runIDs[2]])
    #expect(latest.hasOlderMessages)
    let older = try await database.conversationHistoryPage(id: conversation, before: latest.oldestMessageCursor,
      limit: 2, compactActivities: true, activityCursor: latest.activityRevision, knownActivityRunIDs: [runIDs[2]])
    #expect(older.runs.map(\.id) == [runIDs[1]])
    #expect(older.activities.map(\.runID) == [runIDs[1]])
    #expect(older.activityRevision == latest.activityRevision)
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    try sql.execute("DELETE FROM dashboard_run_events WHERE run_id='\(runIDs[1])'")
    let delta = try await database.conversationHistoryPage(id: conversation, limit: 2, compactActivities: true,
      activityCursor: older.activityRevision, knownActivityRunIDs: [runIDs[1], runIDs[2]])
    #expect(delta.activities.isEmpty)
    #expect(delta.removedActivityIDs == ["\(runIDs[1]):activity:tool"])
    #expect(delta.activityReadMetrics == .init())
  }

  @Test("a direct chronology correction invalidates the displayed record even when its payload is unchanged")
  func metadataOnlyCorrection() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex,
      title: "Chronology", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Inspect")
    try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "tool", kind: .tool, content: "unchanged"))
    let before = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    try sql.execute("UPDATE dashboard_run_events SET created_at='2026-01-01T00:00:00.000Z' WHERE run_id='\(run.runID)'")
    let delta = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: before.activityRevision, knownActivityRunIDs: [run.runID])
    let current = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    #expect(current.activities.first?.createdAt == "2026-01-01T00:00:00.000Z")
    #expect(applying(delta, to: before.activities) == current.activities)
  }

  @Test("deleting the final message and activity still delivers tombstones to a frontend with a known run")
  func emptyPageTombstones() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex,
      title: "Empty page", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Inspect")
    try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "tool", kind: .tool, content: "removed"))
    let before = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    try sql.execute("""
      BEGIN;
      DELETE FROM dashboard_run_events WHERE run_id='\(run.runID)';
      DELETE FROM dashboard_messages WHERE conversation_id='\(conversation)';
      COMMIT;
      """)
    let delta = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true,
      activityCursor: before.activityRevision, knownActivityRunIDs: [run.runID])
    #expect(delta.messages.isEmpty && delta.activities.isEmpty)
    #expect(delta.removedActivityIDs == before.activities.map(\.id))
    #expect(delta.activityRevision != nil)
    #expect(applying(delta, to: before.activities).isEmpty)
  }

  @Test("truncated title or detail alone still advertises the full disclosure", arguments: [false, true])
  func truncatedMetadataOffersDetails(titleOnly: Bool) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex,
      title: "Disclosure", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Inspect")
    let long = String(repeating: "Important context. ", count: 100)
    let activity = AgentRunActivity(id: "context", kind: .activity,
      title: titleOnly ? long : nil, detail: titleOnly ? nil : long)
    try await database.upsertDeviceOwnedRunActivity(runID: run.runID, activity: activity)
    let page = try await database.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    let summary = try #require(page.activities.first?.activity)
    #expect((titleOnly ? summary.title : summary.detail) == String(long.prefix(280)))
    #expect(summary.detailsAvailable == true)
    #expect(try await database.conversationActivityDetails(conversationID: conversation,
      runID: run.runID, activityID: activity.id) == activity)
  }
}

/// Compare persisted public page contracts, with explicit checks above for the
/// fields that summaries must preserve rather than deriving every expectation
/// from presentationSummary itself.
func assertSummaryParity(_ compact: WorkspaceConversationHistoryPage, _ full: WorkspaceConversationHistoryPage,
  sourceLocation: SourceLocation = #_sourceLocation) {
  #expect(compact.messages == full.messages, sourceLocation: sourceLocation)
  #expect(compact.runs == full.runs, sourceLocation: sourceLocation)
  #expect(compact.attachments == full.attachments && compact.references == full.references, sourceLocation: sourceLocation)
  #expect(compact.hasOlderMessages == full.hasOlderMessages, sourceLocation: sourceLocation)
  #expect(compact.activities.map(\.id) == full.activities.map(\.id), sourceLocation: sourceLocation)
  for (summary, record) in zip(compact.activities, full.activities) {
    #expect(summary.runID == record.runID && summary.conversationID == record.conversationID, sourceLocation: sourceLocation)
    #expect(summary.createdAt == record.createdAt && summary.sequence == record.sequence, sourceLocation: sourceLocation)
    #expect(summary.activity == record.activity.presentationSummary(version: summary.activity.detailVersion), sourceLocation: sourceLocation)
    #expect(summary.activity.rawInputJSON == nil && summary.activity.rawOutputJSON == nil
      && summary.activity.rawPayloadJSON == nil && summary.activity.subagents == nil, sourceLocation: sourceLocation)
  }
}

private func encodedSQL(_ activity: AgentRunActivity) throws -> String {
  String(decoding: try JSONEncoder().encode(activity), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
}

private func applying(_ delta: WorkspaceConversationHistoryPage, to records: [WorkspaceRunActivityRecord]) -> [WorkspaceRunActivityRecord] {
  var current = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
  for id in delta.removedActivityIDs { current.removeValue(forKey: id) }
  for record in delta.activities { current[record.id] = record }
  return current.values.sorted(by: WorkspaceRunActivityRecord.precedes)
}

import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Compact activity persistence", .serialized)
struct ActivitySummaryPersistenceTests {

  @Test("direct reconciliation SQL updates, deletes, and hides traces through the same delta contract")
  func directReconciliationAndTombstones() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createFixtureLocalACPSession(runtimeKind: .codex,
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
    let conversation = try await database.createFixtureLocalACPSession(runtimeKind: .opencode,
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

  @Test("cached summaries preserve canonical text, ordering, merged state, and disclosure details")
  func summaryAndFullHistoryParity() async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createFixtureLocalACPSession(runtimeKind: .codex,
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

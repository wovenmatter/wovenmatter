import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@Suite("Compact file change summaries")
struct FileChangeSummaryTests {
  @Test("legacy file changes decode without counts and compact without losing identities")
  func legacyCodableAndRecompaction() throws {
    let json = #"{"path":"src/café.swift","oldText":"keep\nold\nend","newText":"keep\nnew\nadded\nend"}"#
    let change = try JSONDecoder().decode(AgentRunFileChange.self, from: Data(json.utf8))
    #expect(change.additionCount == nil && change.deletionCount == nil)
    let activity = AgentRunActivity(id: "edit", kind: .fileChange, changes: [change])
    let summary = activity.presentationSummary(version: 7)
    let file = try #require(summary.changes.first)
    #expect(file.path == "src/café.swift")
    #expect(file.additionCount == 2 && file.deletionCount == 1)
    #expect(file.additions == 2 && file.deletions == 1)
    #expect(file.oldText == nil && file.newText.isEmpty && file.unifiedDiff == nil)
    #expect(summary.detailsAvailable == true && summary.detailVersion == 7)
    #expect(summary.presentationSummary() == summary)
    let decoded = try JSONDecoder().decode(AgentRunActivity.self, from: JSONEncoder().encode(summary))
    #expect(decoded.presentationSummary(version: 8).changes == summary.changes)
    #expect(decoded.presentationSummary(version: 8).detailVersion == 8)
    // Projection never mutates the canonical value or adds metadata to it.
    #expect(activity.changes == [change])
    let rawJSON = String(decoding: try JSONEncoder().encode(change), as: UTF8.self)
    #expect(!rawJSON.contains("additionCount") && !rawJSON.contains("deletionCount"))
  }

  @Test("large full-text and supplied unified diffs produce bounded count-only summaries",
    arguments: [false, true])
  func largeFileSummary(suppliedDiff: Bool) throws {
    let shared = (0..<16_384).map { "unchanged line \($0): café 🧵" }.joined(separator: "\n")
    let old = shared + "\nold line"
    let new = shared + "\nnew line\nextra line"
    let diff = "--- a/large.swift\n+++ b/large.swift\n@@ -16385 +16385,2 @@\n-old line\n+new line\n+extra line\n"
    let activity = AgentRunActivity(id: "large", kind: .fileChange, content: new,
      changes: [.init(path: "large.swift", oldText: old, newText: new,
        unifiedDiff: suppliedDiff ? diff : nil)])
    let summary = activity.presentationSummary()
    let file = try #require(summary.changes.first)
    #expect(file.additionCount == 2 && file.deletionCount == 1)
    #expect(file.oldText == nil && file.newText.isEmpty && file.unifiedDiff == nil)
    #expect(summary.content == String(new.prefix(280)))
    #expect(try JSONEncoder().encode(summary).count < 1_024)
    #expect(try JSONEncoder().encode(activity).count > 1_000_000)
    #expect(summary.presentationSummary() == summary)
    #expect(activity.changes.first?.oldText == old && activity.changes.first?.newText == new)
  }

  @Test("stored count metadata survives re-compaction without requiring diff bodies")
  func materializedCounts() {
    let summary = AgentRunActivity(id: "counts", kind: .tool,
      changes: [.init(path: "removed.txt", newText: "", additionCount: 0, deletionCount: 42),
        .init(path: "added.txt", newText: "", additionCount: 17, deletionCount: 0)])
      .presentationSummary()
    #expect(summary.changes.map(\.additions) == [0, 17])
    #expect(summary.changes.map(\.deletions) == [42, 0])
    #expect(summary.presentationSummary().changes == summary.changes)
  }

  @Test("current, legacy cached, and uncached rows compact on read while scoped details stay complete",
    arguments: ["current", "legacy", "uncached"])
  func persistedFileDetails(cache: String) async throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try await WorkspaceDatabase(url: fixture.databaseURL)
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex,
      title: "File summaries", ownerDeviceID: UUID())
    let firstRun = try await database.beginLocalACPRun(conversationID: conversation, content: "First")
    let first = AgentRunActivity(id: "edit", kind: .fileChange, changes: [
      .init(path: "shared.swift", oldText: "before", newText: "first")
    ])
    try await database.upsertDeviceOwnedRunActivity(runID: firstRun.runID, activity: first)
    try await database.completeLocalACPRun(runID: firstRun.runID)
    let secondRun = try await database.beginLocalACPRun(conversationID: conversation, content: "Second")
    let complete = String(repeating: "full file content 🧵\n", count: 16_384)
    let second = AgentRunActivity(id: "edit", kind: .fileChange, changes: [
      .init(path: "sibling.swift", oldText: "sibling before", newText: "sibling after"),
      .init(path: "shared.swift", oldText: "first", newText: complete,
        unifiedDiff: "@@ -1 +1,2 @@\n-first\n+second\n+extra\n")
    ])
    try await database.upsertDeviceOwnedRunActivity(runID: secondRun.runID, activity: second)
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    try sql.execute("CREATE TEMP TABLE original_file_events AS SELECT id,content FROM dashboard_run_events")
    if cache == "legacy" {
      // Previous summary JSON kept full changes and had no count metadata.
      try sql.execute("""
        UPDATE desktop_activity_index SET summary=(
          SELECT content FROM dashboard_run_events WHERE id=desktop_activity_index.id);
        """)
    } else if cache == "uncached" {
      try sql.execute("UPDATE desktop_activity_index SET summary=NULL")
    }
    let frontend = try await WorkspaceDatabase(url: fixture.databaseURL, readOnlyProjection: true)
    let page = try await frontend.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true)
    let projected = try #require(page.activities.first { $0.runID == secondRun.runID }?.activity)
    #expect(projected.changes.map(\.path) == ["sibling.swift", "shared.swift"])
    #expect(projected.changes.map(\.additions) == [1, 2])
    #expect(projected.changes.map(\.deletions) == [1, 1])
    #expect(projected.changes.allSatisfy { $0.oldText == nil && $0.newText.isEmpty && $0.unifiedDiff == nil })
    #expect(projected.detailsAvailable == true && projected.detailVersion != nil)
    #expect(page.activityReadMetrics.fullRowsDecoded == (cache == "uncached" ? 2 : 0))
    #expect(try await frontend.conversationHistoryPage(id: conversation, limit: 20, compactActivities: true) == page)
    #expect(try await frontend.conversationActivityDetails(conversationID: conversation,
      runID: firstRun.runID, activityID: "edit") == first)
    let detail = try #require(try await frontend.conversationActivityDetails(conversationID: conversation,
      runID: secondRun.runID, activityID: "edit"))
    #expect(detail == second)
    #expect(detail.changes.first { $0.path == "shared.swift" }?.newText == complete)
    #expect(try await frontend.conversationActivityDetails(conversationID: "wrong-conversation",
      runID: secondRun.runID, activityID: "edit") == nil)
    #expect(try sql.scalar("""
      SELECT count(*) FROM dashboard_run_events e JOIN original_file_events o ON e.id=o.id
      WHERE CAST(e.content AS BLOB) != CAST(o.content AS BLOB)
      """) == 0)

    let updated = AgentRunActivity(id: "edit", kind: .fileChange,
      changes: [.init(path: "shared.swift", oldText: "second", newText: "latest\nextra\nline")])
    try await database.upsertDeviceOwnedRunActivity(runID: secondRun.runID, activity: updated)
    let delta = try await frontend.conversationHistoryPage(id: conversation, limit: 20,
      compactActivities: true, activityCursor: page.activityRevision,
      knownActivityRunIDs: [firstRun.runID, secondRun.runID])
    let revised = try #require(delta.activities.first?.activity)
    #expect(delta.activities.count == 1)
    #expect(revised.detailVersion != projected.detailVersion)
    #expect(revised.changes.first?.additionCount == 3 && revised.changes.first?.deletionCount == 1)
    #expect(try await frontend.conversationActivityDetails(conversationID: conversation,
      runID: secondRun.runID, activityID: revised.id) == updated)
  }
}

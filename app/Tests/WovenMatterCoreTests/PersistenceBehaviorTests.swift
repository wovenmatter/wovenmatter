import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Persistence behavior", .serialized)
struct PersistenceBehaviorTests {
  @Test("adding history indexes preserves page contents and tie ordering after reopen")
  func historyIndexesPreservePage() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try WorkspaceDatabase(url: fixture.databaseURL)
    let conversationID = try database.createLocalACPSession(
      runtimeKind: .codex, title: "History", ownerDeviceID: UUID()
    )
    let run = try database.beginLocalACPRun(conversationID: conversationID, content: "Hello")
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    let indexes = [
      "desktop_cache_attachments_message_created_id",
      "desktop_cache_references_message_created_id",
      "desktop_cache_events_run_created_id",
      "desktop_cache_visible_traces_run_created_id",
    ]
    for index in indexes { try sql.execute("DROP INDEX \(index)") }
    for (table, parent) in [
      ("dashboard_message_attachments", "message_id"),
      ("dashboard_message_references", "message_id"),
      ("dashboard_run_events", "run_id"),
      ("dashboard_run_trace_events", "run_id"),
    ] {
      try sql.execute("""
        WITH RECURSIVE numbers(n) AS (
          SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 1000
        ) INSERT INTO \(table) (id, \(parent), created_at)
        SELECT 'unrelated-' || n, 'other-' || n, '2026-01-01T00:00:00.000Z' FROM numbers;
        """)
    }
    // Insert the larger ID first: index creation must preserve explicit ID tie order.
    for suffix in ["b", "a"] {
      try sql.execute("""
        INSERT INTO dashboard_message_attachments
          (id, conversation_id, message_id, file_name, created_at)
        VALUES ('attachment-\(suffix)', '\(conversationID)', '\(run.userMessageID)',
          'file-\(suffix)', '2026-01-01T00:00:00.000Z');
        INSERT INTO dashboard_message_references
          (id, conversation_id, message_id, resource_id, title_snapshot, created_at)
        VALUES ('reference-\(suffix)', '\(conversationID)', '\(run.userMessageID)',
          'note-\(suffix)', 'Note \(suffix)', '2026-01-01T00:00:00.000Z');
        INSERT INTO dashboard_run_events
          (id, conversation_id, run_id, event_type, content, created_at)
        VALUES ('event-\(suffix)', '\(conversationID)', '\(run.runID)',
          'progress', 'Progress \(suffix)', '2026-01-01T00:00:00.000Z');
        INSERT INTO dashboard_run_trace_events
          (id, conversation_id, run_id, event_type, is_visible, created_at)
        VALUES ('trace-\(suffix)', '\(conversationID)', '\(run.runID)',
          'progress', 1, '2026-01-01T00:00:00.000Z');
        """)
    }
    try sql.execute("""
      INSERT INTO dashboard_run_trace_events
        (id, conversation_id, run_id, event_type, is_visible, created_at)
      VALUES ('invisible', '\(conversationID)', '\(run.runID)', 'progress', 0, ''),
        ('text-delta', '\(conversationID)', '\(run.runID)', 'assistant_delta', 1, '');
      """)
    let before = try database.conversationHistoryPage(id: conversationID, limit: 2)
    #expect(before.messages.count == 2)
    #expect(before.runs.map(\.id) == [run.runID])
    #expect(before.attachments.map(\.id) == ["attachment-a", "attachment-b"])
    #expect(before.references.map(\.id) == ["reference-a", "reference-b"])
    #expect(before.activities.map(\.id) == ["event-a", "event-b", "trace-trace-a", "trace-trace-b"])
    let reopened = try WorkspaceDatabase(url: fixture.databaseURL)
    let after = try reopened.conversationHistoryPage(id: conversationID, limit: 2)
    #expect(after == before)
    for index in indexes {
      #expect(try sql.scalar("SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = '\(index)'") == 1)
    }
    let reopenedAgain = try WorkspaceDatabase(url: fixture.databaseURL)
    #expect(try reopenedAgain.conversationHistoryPage(id: conversationID, limit: 2) == before)
  }

  @Test("deterministic agent identity and timestamp parsing survive reopen")
  func agentIdentity() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let database = try WorkspaceDatabase(url: fixture.databaseURL)
    let owner = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
    let remote = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
    let date = Date(timeIntervalSince1970: 1_700_000_000.125)
    _ = try database.createLocalACPSession(
      runtimeKind: .codex, title: "Local", ownerDeviceID: owner, createdAt: date
    )
    let remoteID = try database.ensureRemoteHarnessAgent(
      runtimeKind: .codex, remoteWorkspaceID: remote, remoteWorkspaceName: "Remote",
      ownerDeviceID: owner, updatedAt: date
    )
    #expect(remoteID.uuidString.lowercased() == "1f3691b1-c027-56fd-999f-9eed2130cd6a")
    let reopened = try WorkspaceDatabase(url: fixture.databaseURL)
    let agents = try reopened.dashboardAgents()
    #expect(Set(agents.map { $0.id.uuidString.lowercased() }) == [
      "5711c18c-4ab6-50f2-893f-e3d31837e15b", "1f3691b1-c027-56fd-999f-9eed2130cd6a",
    ])
    #expect(agents.allSatisfy { $0.createdAt == date })
    let sql = try PersistenceSQL(url: fixture.databaseURL)
    try sql.execute("UPDATE dashboard_agents SET updated_at = '2023-11-14T22:13:20Z'")
    #expect(try reopened.dashboardAgents().allSatisfy {
      $0.updatedAt == Date(timeIntervalSince1970: 1_700_000_000)
    })
  }

  @Test("attachment staging rejects oversized files and preserves content deduplication")
  func attachmentStaging() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.remove() }
    let store = try MessageAttachmentStore(supportDirectory: fixture.directory)
    let oversized = fixture.directory.appending(path: "large.bin")
    try Data().write(to: oversized)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(AgentMessageAttachmentLimits.maximumFileBytes + 1))
    try handle.close()
    #expect(throws: AgentMessageAttachmentError.fileTooLarge(
      name: "large.bin", maximumBytes: AgentMessageAttachmentLimits.maximumFileBytes
    )) { try store.stage(fileURL: oversized, mimeType: "application/octet-stream") }
    let content = Data("Same content 🧶".utf8)
    let first = fixture.directory.appending(path: "first.txt")
    let second = fixture.directory.appending(path: "second.txt")
    try content.write(to: first)
    try content.write(to: second)
    let a = try store.stage(fileURL: first, mimeType: "text/plain")
    let b = try store.stage(fileURL: second, mimeType: "text/plain")
    #expect(a.contentHash == b.contentHash)
    #expect(a.localURL == b.localURL)
    #expect(a.fileName == "first.txt" && b.fileName == "second.txt")
    #expect(try Data(contentsOf: a.localURL) == content)
  }

  @Test("JSON rows beyond the display limit still determine existing column width")
  func jsonWidth() throws {
    var rows = Array(repeating: [1], count: DatabaseLinkedData.maximumRows)
    rows.append([1, 2, 3])
    let table = try DatabaseLinkedData.load(
      data: JSONEncoder().encode(rows), fileExtension: "json", preference: .json,
      sqliteQuery: nil
    )
    #expect(table.columns == ["A", "B", "C"])
    #expect(table.rows.count == DatabaseLinkedData.maximumRows)
    #expect(table.rows.allSatisfy { $0 == ["1", "", ""] })
  }
}

private struct PersistenceFixture {
  let directory: URL
  var databaseURL: URL { directory.appending(path: "workspace.sqlite") }

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "persistence-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class PersistenceSQL {
  private let connection: OpaquePointer

  init(url: URL) throws {
    var pointer: OpaquePointer?
    let code = sqlite3_open(url.path, &pointer)
    guard code == SQLITE_OK, let pointer else {
      if let pointer { sqlite3_close(pointer) }
      throw WorkspaceDatabaseError.open("Synthetic database failed to open")
    }
    connection = pointer
  }

  deinit { sqlite3_close(connection) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
      throw WorkspaceDatabaseError.execute(String(cString: sqlite3_errmsg(connection)))
    }
  }

  func scalar(_ sql: String) throws -> Int {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw WorkspaceDatabaseError.prepare(String(cString: sqlite3_errmsg(connection)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw WorkspaceDatabaseError.step(String(cString: sqlite3_errmsg(connection)))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }
}

import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite("Usage history import batches")
struct UsageHistoryImportTests {
  private static let now = Date()

  private actor Recorder {
    var entries: [(covered: UsageTimeRange?, sessions: Set<String>)] = []
    func add(_ covered: UsageTimeRange?, _ snapshot: UsageAnalyticsSnapshot?) {
      entries.append((covered, Set((snapshot?.samples ?? []).map(\.sessionID))))
    }
  }

  private func writeTranscript(home: URL, session: String, daysAgo: Double) throws {
    let directory = home.appending(path: ".claude/projects/\(session)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let date = Self.now.addingTimeInterval(-daysAgo * 86_400)
    let line = try JSONSerialization.data(withJSONObject: [
      "type": "assistant",
      "timestamp": ISO8601DateFormatter().string(from: date),
      "sessionId": session,
      "message": [
        "id": "message-\(session)",
        "model": "claude-test",
        "usage": ["input_tokens": 10, "output_tokens": 5],
      ],
    ])
    let file = directory.appending(path: "\(session).jsonl")
    try (line + Data("\n".utf8)).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
  }

  private func withHistory(_ body: (LocalUsageService) async throws -> Void) async throws {
    try await withHistory { service, _ in try await body(service) }
  }

  private func withHistory(_ body: (LocalUsageService, URL) async throws -> Void) async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "usage-batches-\(UUID())")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    for (session, days) in [("day", 0.5), ("week", 3), ("month", 20), ("quarter", 60), ("old", 200)] {
      try writeTranscript(home: home, session: session, daysAgo: days)
    }
    // Its own import lane, so tests running alongside can't fill it.
    try await body(LocalUsageService(
      homeDirectory: home,
      fileManager: .default,
      credentialStore: UsageNoCredentials(recordsAccess: true),
      usageDatabaseURL: home.appending(path: "usage.sqlite"),
      sharedConnectionRevision: { 0 },
      importPreparationWorker: DatabaseWorker(label: "usage.import.batches.fixture", capacity: 8)
    ), home.appending(path: "usage.sqlite"))
  }

  /// Runs one statement on the usage index and returns its first column, row by row.
  private func index(_ database: URL, _ sql: String) throws -> [String] {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let connection else {
      throw CocoaError(.fileReadUnknown)
    }
    defer { sqlite3_close(connection) }
    sqlite3_busy_timeout(connection, 5_000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CocoaError(.fileReadUnknown) }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return values }
      guard code == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
      values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
    }
  }

  /// An earlier build stored every source's fingerprint with a label in
  /// front. Such a source is read once more at the next daily walk of every
  /// file, and reading it again replaces its events, so nothing is counted
  /// twice.
  @Test("a source an earlier build indexed is read once more and counted once")
  func anEarlierFingerprintReindexesWithoutCountingTwice() async throws {
    try await withHistory { service, database in
      let first = try await service.analyticsSnapshot(range: .allTime, refreshReason: .startup, now: Self.now)
      #expect(first.samples.count == 5)
      let stored = try index(database, "SELECT fingerprint FROM usage_sources ORDER BY source_id")
      #expect(stored.count == 5)
      #expect(stored.allSatisfy { !$0.contains("usage-index") })
      let events = try index(database, "SELECT event_id FROM usage_events ORDER BY event_id")

      _ = try index(database, "UPDATE usage_sources SET fingerprint='usage-index-v4:' || fingerprint")
      // A refresh the same day reads only files that changed; the next day's reads them all.
      _ = try await service.analyticsSnapshot(range: .allTime, refreshReason: .manual, now: Self.now)
      #expect(try index(database, "SELECT fingerprint FROM usage_sources ORDER BY source_id") != stored)
      let again = try await service.analyticsSnapshot(range: .allTime, refreshReason: .manual, now: Self.now.addingTimeInterval(25 * 60 * 60))
      #expect(again.samples.count == 5)
      #expect(again.samples.map(\.tokens.totalTokens).reduce(0, +) == first.samples.map(\.tokens.totalTokens).reduce(0, +))
      #expect(try index(database, "SELECT fingerprint FROM usage_sources ORDER BY source_id") == stored)
      #expect(try index(database, "SELECT event_id FROM usage_events ORDER BY event_id") == events)
    }
  }

  @Test("the first import publishes newest usage first, widening to the whole history")
  func batchesWiden() async throws {
    try await withHistory { service in
      let recorder = Recorder()
      let final = try await service.analyticsSnapshot(range: .allTime, refreshReason: .startup, now: Self.now) { progress, snapshot in
        await recorder.add(progress.covered, snapshot)
      }
      let entries = await recorder.entries
      #expect(entries.map(\.covered) == [nil, .last24Hours, .last7Days, .last30Days, .last90Days])
      #expect(entries.map(\.sessions) == [
        [], ["day"], ["day", "week"], ["day", "week", "month"], ["day", "week", "month", "quarter"],
      ])
      #expect(Set(final.samples.map(\.sessionID)) == ["day", "week", "month", "quarter", "old"])
    }
  }

  @Test("after the first import, a refresh reads in one pass and reports no batches")
  func laterRefreshIsOnePass() async throws {
    try await withHistory { service in
      _ = try await service.analyticsSnapshot(range: .allTime, refreshReason: .startup, now: Self.now)
      let recorder = Recorder()
      let again = try await service.analyticsSnapshot(range: .allTime, refreshReason: .manual, now: Self.now) { progress, snapshot in
        await recorder.add(progress.covered, snapshot)
      }
      #expect(await recorder.entries.isEmpty)
      #expect(again.samples.count == 5)
    }
  }

  @Test("a range counts as complete once its batch has been read")
  func coverage() {
    let now = Date(timeIntervalSince1970: 1_793_910_600)
    let week = UsageHistoryImportProgress(covered: .last7Days)
    #expect(week.covers(.last24Hours, now: now))
    #expect(week.covers(.yesterday, now: now))
    #expect(week.covers(.last7Days, now: now))
    #expect(!week.covers(.last30Days, now: now))
    #expect(!week.covers(.allTime, now: now))
    #expect(!UsageHistoryImportProgress(covered: nil).covers(.today, now: now))
  }
}

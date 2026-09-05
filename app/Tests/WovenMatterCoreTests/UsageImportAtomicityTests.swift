import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage import atomicity")
struct UsageImportAtomicityTests {
  private let now = Date(timeIntervalSince1970: 1_780_000_000)

  @Test("A caught source insertion failure rolls back its deletion and partial inserts")
  func sourceSavepoint() throws {
    let fixture = try UsageSQLFixture()
    let store = try UsageStore(databaseURL: fixture.indexURL)
    try replace(store, source: "failed", fingerprint: "original", events: [sample("original")])
    try fixture.execute(at: fixture.indexURL, sql: """
      CREATE TRIGGER reject_usage BEFORE INSERT ON usage_events
      WHEN NEW.source_event_id = 'reject'
      BEGIN SELECT RAISE(ABORT, 'injected insertion failure'); END;
      """)
    try store.performTransaction {
      #expect(throws: UsageStoreError.self) {
        try replace(store, source: "failed", fingerprint: "changed", events: [sample("partial"), sample("reject")], transactional: false)
      }
      try replace(store, source: "good", fingerprint: "new", events: [sample("good")], transactional: false)
    }
    #expect(try store.source("failed")?.fingerprint == "original")
    #expect(try store.samples(in: interval, sourceID: "failed").map(\.sourceEventID) == ["original"])
    #expect(try store.samples(in: interval, sourceID: "good").map(\.sourceEventID) == ["good"])
  }

  @Test("An SQLite transaction rollback cannot leave later source writes autocommitted")
  func transactionInvalidation() throws {
    let fixture = try UsageSQLFixture()
    let store = try UsageStore(databaseURL: fixture.indexURL)
    try replace(store, source: "failed", fingerprint: "original", events: [sample("original")])
    try fixture.execute(at: fixture.indexURL, sql: """
      CREATE TRIGGER rollback_usage BEFORE INSERT ON usage_events
      WHEN NEW.source_event_id = 'reject'
      BEGIN SELECT RAISE(ROLLBACK, 'injected transaction failure'); END;
      """)
    var outerFailed = false
    do {
      try store.performTransaction {
        #expect(throws: UsageStoreError.self) {
          try replace(store, source: "failed", fingerprint: "changed", events: [sample("partial"), sample("reject")], transactional: false)
        }
        #expect(throws: UsageStoreError.self) {
          try replace(store, source: "later", fingerprint: "must-not-commit", events: [sample("later")], transactional: false)
        }
      }
    } catch is UsageStoreError {
      outerFailed = true
    }
    #expect(outerFailed)
    #expect(try store.samples(in: interval).map(\.sourceEventID) == ["original"])
    #expect(try store.source("later") == nil)
    // The store remains usable after the outer transaction finishes rollback.
    try replace(store, source: "recovery", fingerprint: "recovery", events: [sample("recovery")])
    #expect(try store.source("recovery")?.fingerprint == "recovery")
  }

  @Test("OpenCode step errors retain indexed history and report partial coverage")
  func readerStepFailure() async throws {
    let fixture = try UsageSQLFixture()
    let sourceURL = fixture.url.appending(path: ".local/share/opencode/opencode.db")
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let timestamp = Int64(now.addingTimeInterval(-1).timeIntervalSince1970 * 1_000)
    try fixture.execute(at: sourceURL, sql: """
      CREATE TABLE message(id TEXT, data TEXT, time_created INTEGER);
      CREATE TABLE session(id TEXT, directory TEXT);
      CREATE TABLE raw_part(id TEXT, session_id TEXT, message_id TEXT, data TEXT);
      CREATE VIEW part AS SELECT id, session_id, message_id,
        CASE WHEN id = 'broken' THEN json_extract('invalid json', '$') ELSE data END AS data
        FROM raw_part;
      INSERT INTO message VALUES('message', '{"providerID":"opencode-go","modelID":"gpt-5.4","time":{"created":\(timestamp)}}', \(timestamp));
      INSERT INTO raw_part VALUES('original', 'session', 'message', '{"type":"step-finish","tokens":{"input":8,"output":3},"cost":0.01}');
      """)
    let service = LocalUsageService(homeDirectory: fixture.url, usageDatabaseURL: fixture.indexURL)
    let initial = try await service.analyticsSnapshot(range: .last24Hours, enabledProviders: [.openCodeGo], allowCredentialAccess: false, now: now)
    #expect(initial.samples.count == 1)
    let store = try UsageStore(databaseURL: fixture.indexURL)
    let originalFingerprint = try store.source("opencode:database")?.fingerprint
    try fixture.execute(at: sourceURL, sql: "INSERT INTO raw_part VALUES('broken', 'session', 'message', '{}');")
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: sourceURL.path)
    let failed = try await service.analyticsSnapshot(range: .last24Hours, enabledProviders: [.openCodeGo], allowCredentialAccess: false, now: now.addingTimeInterval(1))
    #expect(failed.samples == initial.samples)
    #expect(failed.sources.first { $0.id == "opencode" }?.status == .partial)
    #expect(try store.source("opencode:database")?.fingerprint == originalFingerprint)
  }

  @Test("Metadata and cursor step failures throw instead of resembling missing rows")
  func lookupStepErrors() throws {
    let fixture = try UsageSQLFixture()
    let store = try UsageStore(databaseURL: fixture.indexURL)
    #expect(try store.metadataDate("fixture") == nil)
    #expect(try store.runtimeSyncState(endpoint: "fixture") == nil)
    try fixture.execute(at: fixture.indexURL, sql: """
      DROP TABLE usage_metadata;
      CREATE VIEW usage_metadata AS SELECT 'fixture' AS key, json_extract('invalid', '$') AS value;
      DROP TABLE usage_runtime_cursors;
      CREATE VIEW usage_runtime_cursors AS SELECT 'fixture' AS endpoint,
        json_extract('invalid', '$') AS source_id, '0' AS cursor, 0 AS synced_at,
        'available' AS status, '' AS detail;
      """)
    #expect(throws: UsageStoreError.self) { try store.metadataDate("fixture") }
    #expect(throws: UsageStoreError.self) { try store.runtimeSyncState(endpoint: "fixture") }
  }

  private var interval: DateInterval { DateInterval(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(1)) }

  private func sample(_ id: String) -> UsageSample {
    UsageSample(id: id, provider: .codex, timestamp: now, sessionID: "session", accountLabel: "fixture",
      model: "gpt-5.4", harness: "Codex", application: "test", tokens: UsageTokenCounts(inputTokens: 3))
  }

  private func replace(_ store: UsageStore, source: String, fingerprint: String, events: [UsageSample], transactional: Bool = true) throws {
    try store.replace(sourceID: source, sourceName: source, location: "fixture", provider: .codex,
      harness: "Codex", fingerprint: fingerprint, samples: events, importedAt: now, transactional: transactional)
  }
}

private final class UsageSQLFixture: @unchecked Sendable {
  let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  var indexURL: URL { url.appending(path: "usage.sqlite") }
  init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
  deinit { try? FileManager.default.removeItem(at: url) }

  func execute(at url: URL, sql: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
      if let connection { sqlite3_close(connection) }
      throw UsageStoreError.open("fixture")
    }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
      throw UsageStoreError.step(String(cString: sqlite3_errmsg(connection)))
    }
  }
}

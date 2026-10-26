import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage import atomicity")
struct UsageImportAtomicityTests {

  @Test("A full import lane reports failed coverage and retries without claiming an empty index")
  func importCapacityAndFixtureIsolation() async throws {
    let fixture = try UsageSQLFixture()
    _ = try fixture.openCodeSource(now: now)
    let preparation = DatabaseWorker(label: "usage.import.capacity.fixture", capacity: 1)
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocked = Task { try await preparation.perform { _ in
      entered.continuation.yield(())
      release.wait()
    } }
    for await _ in entered.stream { break }
    let service = fixture.service(preparationWorker: preparation)
    let full = try await service.analyticsSnapshot(range: .last24Hours, now: now)
    #expect(preparation.metrics.rejected == 1)
    #expect(full.samples.isEmpty)
    #expect(full.sources.first { $0.id == "wovenmatter:index" }?.status == .failed)
    let store = try UsageStore(databaseURL: fixture.indexURL)
    #expect(try store.source("opencode:database") == nil)
    #expect(try store.metadataDate("usage.local-indexed-after") == nil)
    #expect(try store.metadataDate("usage.local-import-at") == nil)

    // An unrelated fixture owns its lane and cannot inherit this admission failure.
    let isolated = try UsageSQLFixture()
    _ = try isolated.openCodeSource(now: now)
    let independent = try await isolated.service().analyticsSnapshot(range: .last24Hours, now: now)
    #expect(independent.samples.count == 1)

    release.signal()
    try await blocked.value
    let recovered = try await service.analyticsSnapshot(range: .last24Hours, now: now)
    #expect(recovered.samples.count == 1)
    #expect(!recovered.sources.contains { $0.id == "wovenmatter:index" })
    #expect(try store.source("opencode:database") != nil)
    #expect(try store.metadataDate("usage.local-import-at") == now)
  }

  private let now = Date(timeIntervalSince1970: 1_780_000_000)

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

  func service(sharedAccounts: Bool = false, revision: @escaping @Sendable () -> UInt64 = { 0 },
    preparationWorker: DatabaseWorker? = nil) -> LocalUsageService {
    LocalUsageService(homeDirectory: url, fileManager: .default,
      credentialStore: UsageImportNoCredentials(), usageDatabaseURL: indexURL,
      usesSharedConnections: sharedAccounts, sharedConnectionRevision: revision,
      importPreparationWorker: preparationWorker ?? DatabaseWorker(label: "usage.import.fixture", capacity: 4))
  }

  func openCodeSource(now: Date) throws -> URL {
    let sourceURL = url.appending(path: ".local/share/opencode/opencode.db")
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let timestamp = Int64(now.addingTimeInterval(-1).timeIntervalSince1970 * 1_000)
    try execute(at: sourceURL, sql: """
      CREATE TABLE message(id TEXT, data TEXT, time_created INTEGER);
      CREATE TABLE session(id TEXT, directory TEXT);
      CREATE TABLE raw_part(id TEXT, session_id TEXT, message_id TEXT, data TEXT);
      CREATE VIEW part AS SELECT id, session_id, message_id,
        CASE WHEN id = 'broken' THEN json_extract('invalid json', '$') ELSE data END AS data
        FROM raw_part;
      INSERT INTO message VALUES('message', '{"providerID":"opencode-go","modelID":"gpt-5.4","time":{"created":\(timestamp)}}', \(timestamp));
      INSERT INTO raw_part VALUES('original', 'session', 'message', '{"type":"step-finish","tokens":{"input":8,"output":3},"cost":0.01}');
      """)
    return sourceURL
  }

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

private struct UsageImportNoCredentials: UsageCredentialStoring {
  private func unexpectedAccess() { Issue.record("SQLite import fixtures must not access credentials") }
  func hasOpenRouterAPIKey() throws -> Bool { unexpectedAccess(); return false }
  func authorizeOpenRouterAPIKey() throws -> String? { unexpectedAccess(); return nil }
  func loadOpenRouterAPIKey() throws -> String? { unexpectedAccess(); return nil }
  func saveOpenRouterAPIKey(_ key: String) throws { unexpectedAccess() }
  func deleteOpenRouterAPIKey() throws { unexpectedAccess() }
}

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
    let sourceURL = try fixture.openCodeSource(now: now)
    // This fixture imports only its own SQLite files. The production initializer
    // watches the app-wide account revision, including mock credential changes
    // made by other tests, even when credential reads are disabled.
    let service = fixture.service()
    let initial = try await service.analyticsSnapshot(range: .last24Hours, enabledProviders: [.openCodeGo], allowCredentialAccess: false, now: now)
    try #require(initial.samples.count == 1, "Initial import coverage: \(initial.sources)")
    let store = try UsageStore(databaseURL: fixture.indexURL)
    let originalFingerprint = try #require(try store.source("opencode:database")).fingerprint
    let originalCoverage = try #require(try store.metadataDate("usage.local-indexed-after"))
    let originalImportDate = try #require(try store.metadataDate("usage.local-import-at"))
    try fixture.execute(at: sourceURL, sql: "INSERT INTO raw_part VALUES('broken', 'session', 'message', '{}');")
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(10)], ofItemAtPath: sourceURL.path)
    let failed = try await service.analyticsSnapshot(range: .last7Days, enabledProviders: [.openCodeGo], allowCredentialAccess: false, now: now.addingTimeInterval(1))
    #expect(failed.samples == initial.samples)
    #expect(failed.sources.first { $0.id == "opencode" }?.status == .partial)
    #expect(try store.source("opencode:database")?.fingerprint == originalFingerprint)
    // A failed wider scan cannot claim coverage or defer its retry.
    #expect(try store.metadataDate("usage.local-indexed-after") == originalCoverage)
    #expect(try store.metadataDate("usage.local-import-at") == originalImportDate)
  }

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
    let full = try await service.analyticsSnapshot(range: .last24Hours, enabledProviders: [.openCodeGo],
      allowCredentialAccess: false, now: now)
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
    let independent = try await isolated.service().analyticsSnapshot(range: .last24Hours,
      enabledProviders: [.openCodeGo], allowCredentialAccess: false, now: now)
    #expect(independent.samples.count == 1)

    release.signal()
    try await blocked.value
    let recovered = try await service.analyticsSnapshot(range: .last24Hours, enabledProviders: [.openCodeGo],
      allowCredentialAccess: false, now: now)
    #expect(recovered.samples.count == 1)
    #expect(!recovered.sources.contains { $0.id == "wovenmatter:index" })
    #expect(try store.source("opencode:database") != nil)
    #expect(try store.metadataDate("usage.local-import-at") == now)
  }

  @Test("Only shared-account analytics observe account revision changes", arguments: [false, true])
  func analyticsRevisionOwnership(sharedAccounts: Bool) async throws {
    final class ChangingRevision: @unchecked Sendable {
      private let lock = NSLock()
      private var value: UInt64 = 0
      func read() -> UInt64 { lock.withLock { value += 1; return value } }
      var reads: UInt64 { lock.withLock { value } }
    }
    let fixture = try UsageSQLFixture()
    let revision = ChangingRevision()
    // Advancing on each read deterministically represents another account
    // mutation between capture and validation, without process-global changes.
    let service = fixture.service(sharedAccounts: sharedAccounts, revision: { revision.read() })
    if sharedAccounts {
      await #expect(throws: CancellationError.self) {
        try await service.analyticsSnapshot(range: .last24Hours, enabledProviders: [.openCodeGo],
          allowCredentialAccess: false, now: now)
      }
      #expect(revision.reads > 1)
    } else {
      let result = try await service.analyticsSnapshot(range: .last24Hours, enabledProviders: [.openCodeGo],
        allowCredentialAccess: false, now: now)
      #expect(result.samples.isEmpty)
      #expect(revision.reads == 1) // Initialization only; local imports have no account ownership.
    }
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

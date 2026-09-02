import Foundation
import SQLite3
import WovenMatterCore

struct UsageStoredSource: Equatable, Sendable {
  let id: String
  let fingerprint: String
  let importedAt: Date
  let indexedAfter: Date?
}

struct UsageSourceStatistics: Equatable, Sendable {
  let sessions: Int
  let events: Int
  let importedAt: Date?
}

struct UsageRuntimeSyncState: Equatable, Sendable {
  let sourceID: String
  let endpoint: String
  let cursor: String
  let syncedAt: Date
  let status: UsageSourceStatus
  let detail: String
}

enum UsageStoreError: LocalizedError {
  case open(String)
  case statement(String)
  case step(String)

  var errorDescription: String? {
    switch self {
    case .open(let detail): "Usage database could not be opened: \(detail)"
    case .statement(let detail): "Usage database query could not be prepared: \(detail)"
    case .step(let detail): "Usage database operation failed: \(detail)"
    }
  }
}

/// Woven Matter's durable, normalized usage index. Provider and harness stores
/// remain provenance; this database is the query surface and local history.
final class UsageStore: @unchecked Sendable {
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private var connection: OpaquePointer?

  init(databaseURL: URL) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) }
        ?? "SQLite did not allocate a connection"
      if let database { sqlite3_close(database) }
      throw UsageStoreError.open(message)
    }
    connection = database
    do {
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA foreign_keys = ON")
      try execute("PRAGMA busy_timeout = 5000")
      try migrate()
    } catch {
      sqlite3_close(database)
      connection = nil
      throw error
    }
  }

  deinit {
    if let connection { sqlite3_close(connection) }
  }

  func source(_ id: String) throws -> UsageStoredSource? {
    let statement = try prepare("""
      SELECT fingerprint, imported_at, indexed_after
      FROM usage_sources
      WHERE source_id = ?
      """)
    defer { sqlite3_finalize(statement) }
    bind(id, to: 1, in: statement)
    switch sqlite3_step(statement) {
    case SQLITE_DONE:
      return nil
    case SQLITE_ROW:
      return UsageStoredSource(
        id: id,
        fingerprint: text(statement, 0),
        importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
        indexedAfter: optionalDouble(statement, 2).map(Date.init(timeIntervalSince1970:))
      )
    default:
      throw stepError()
    }
  }

  func runtimeSyncState(endpoint: String) throws -> UsageRuntimeSyncState? {
    let statement = try prepare("""
      SELECT source_id, cursor, synced_at, status, detail
      FROM usage_runtime_cursors
      WHERE endpoint = ?
      """)
    defer { sqlite3_finalize(statement) }
    bind(endpoint, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return UsageRuntimeSyncState(
      sourceID: text(statement, 0),
      endpoint: endpoint,
      cursor: text(statement, 1),
      syncedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      status: UsageSourceStatus(rawValue: text(statement, 3)) ?? .failed,
      detail: text(statement, 4)
    )
  }

  /// Atomically applies a replay page and advances its cursor. Replayed pages
  /// and corrected events are safe: the producer's stable event ID is the
  /// source-scoped idempotency key.
  func ingest(
    page: UsageIngestionPage,
    endpoint: String,
    importedAt: Date
  ) throws {
    let priorCursor = try runtimeSyncState(endpoint: endpoint)?.cursor
    try page.validate(after: priorCursor)
    try execute("BEGIN IMMEDIATE")
    do {
      let source = try prepare("""
        INSERT INTO usage_sources (
          source_id, source_name, source_location, provider, harness,
          fingerprint, imported_at, source_kind, installation_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_id) DO UPDATE SET
          source_name = excluded.source_name,
          source_location = excluded.source_location,
          fingerprint = excluded.fingerprint,
          imported_at = excluded.imported_at,
          source_kind = excluded.source_kind,
          installation_id = excluded.installation_id
        """)
      defer { sqlite3_finalize(source) }
      bind(page.source.id, to: 1, in: source)
      bind(page.source.displayName, to: 2, in: source)
      bind(page.source.location, to: 3, in: source)
      bind(ProviderKind.unknown.rawValue, to: 4, in: source)
      bind(nil, to: 5, in: source)
      bind("cursor:\(page.nextCursor)", to: 6, in: source)
      sqlite3_bind_double(source, 7, importedAt.timeIntervalSince1970)
      bind(page.source.kind.rawValue, to: 8, in: source)
      bind(page.source.installationID, to: 9, in: source)
      try stepDone(source)

      let insertion = try prepare("""
        INSERT INTO usage_events (
          event_id, source_id, source_event_id, dedupe_key,
          provider, billing_provider, billing_route, account_label,
          model_raw, model_canonical, model_family, model_publisher,
          model_identity_confidence, timestamp, session_id,
          reasoning_level, harness, application, agent, workspace,
          request_count, input_tokens, cached_input_tokens, cache_creation_tokens,
          output_tokens, reasoning_tokens, reported_total_tokens,
          cost_usd, attribution_confidence, granularity, imported_at
        ) VALUES (
          ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
        ON CONFLICT(event_id) DO UPDATE SET
          dedupe_key = excluded.dedupe_key,
          provider = excluded.provider,
          billing_provider = excluded.billing_provider,
          billing_route = excluded.billing_route,
          account_label = excluded.account_label,
          model_raw = excluded.model_raw,
          model_canonical = excluded.model_canonical,
          model_family = excluded.model_family,
          model_publisher = excluded.model_publisher,
          model_identity_confidence = excluded.model_identity_confidence,
          timestamp = excluded.timestamp,
          session_id = excluded.session_id,
          reasoning_level = excluded.reasoning_level,
          harness = excluded.harness,
          application = excluded.application,
          agent = excluded.agent,
          workspace = excluded.workspace,
          request_count = excluded.request_count,
          input_tokens = excluded.input_tokens,
          cached_input_tokens = excluded.cached_input_tokens,
          cache_creation_tokens = excluded.cache_creation_tokens,
          output_tokens = excluded.output_tokens,
          reasoning_tokens = excluded.reasoning_tokens,
          reported_total_tokens = excluded.reported_total_tokens,
          cost_usd = excluded.cost_usd,
          attribution_confidence = excluded.attribution_confidence,
          granularity = excluded.granularity,
          imported_at = excluded.imported_at
        """)
      defer { sqlite3_finalize(insertion) }
      for event in page.events {
        let sample = event.sample(sourceID: page.source.id)
        sqlite3_reset(insertion)
        sqlite3_clear_bindings(insertion)
        bind(sample.id, to: 1, in: insertion)
        bind(page.source.id, to: 2, in: insertion)
        bind(sample.sourceEventID, to: 3, in: insertion)
        bind(sample.dedupeKey, to: 4, in: insertion)
        bind(sample.provider.rawValue, to: 5, in: insertion)
        bind(sample.billingProvider, to: 6, in: insertion)
        bind(sample.billingRoute, to: 7, in: insertion)
        bind(sample.accountLabel, to: 8, in: insertion)
        bind(sample.model, to: 9, in: insertion)
        bind(sample.canonicalModel, to: 10, in: insertion)
        bind(sample.modelFamily, to: 11, in: insertion)
        bind(sample.modelPublisher, to: 12, in: insertion)
        bind(sample.modelIdentityConfidence.rawValue, to: 13, in: insertion)
        sqlite3_bind_double(insertion, 14, sample.timestamp.timeIntervalSince1970)
        bind(sample.sessionID, to: 15, in: insertion)
        bind(sample.reasoningLevel, to: 16, in: insertion)
        bind(sample.harness, to: 17, in: insertion)
        bind(sample.application, to: 18, in: insertion)
        bind(sample.agent, to: 19, in: insertion)
        bind(sample.workspace, to: 20, in: insertion)
        sqlite3_bind_int64(insertion, 21, Int64(sample.requestCount))
        sqlite3_bind_int64(insertion, 22, sample.tokens.inputTokens)
        sqlite3_bind_int64(insertion, 23, sample.tokens.cachedInputTokens)
        sqlite3_bind_int64(insertion, 24, sample.tokens.cacheCreationTokens)
        sqlite3_bind_int64(insertion, 25, sample.tokens.outputTokens)
        sqlite3_bind_int64(insertion, 26, sample.tokens.reasoningTokens)
        if let total = sample.tokens.reportedTotalTokens {
          sqlite3_bind_int64(insertion, 27, total)
        } else {
          sqlite3_bind_null(insertion, 27)
        }
        if let cost = sample.costUSD {
          sqlite3_bind_double(insertion, 28, cost)
        } else {
          sqlite3_bind_null(insertion, 28)
        }
        bind(sample.attributionConfidence.rawValue, to: 29, in: insertion)
        bind(sample.granularity.rawValue, to: 30, in: insertion)
        sqlite3_bind_double(insertion, 31, importedAt.timeIntervalSince1970)
        try stepDone(insertion)
      }

      try setRuntimeSyncState(
        sourceID: page.source.id,
        endpoint: endpoint,
        cursor: page.nextCursor,
        syncedAt: importedAt,
        status: page.hasMore ? .partial : .available,
        detail: page.hasMore
          ? "Backfill is still in progress after cursor \(page.nextCursor)."
          : "Synchronized through cursor \(page.nextCursor)."
      )
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func replace(
    sourceID: String,
    sourceName: String,
    location: String,
    provider: ProviderKind,
    harness: String?,
    fingerprint: String,
    samples: [UsageSample],
    importedAt: Date,
    indexedAfter: Date? = nil,
    transactional: Bool = true
  ) throws {
    if transactional { try execute("BEGIN IMMEDIATE") }
    do {
      let source = try prepare("""
        INSERT INTO usage_sources (
          source_id, source_name, source_location, provider, harness,
          fingerprint, imported_at, indexed_after
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(source_id) DO UPDATE SET
          source_name = excluded.source_name,
          source_location = excluded.source_location,
          provider = excluded.provider,
          harness = excluded.harness,
          fingerprint = excluded.fingerprint,
          imported_at = excluded.imported_at,
          indexed_after = excluded.indexed_after
        """)
      defer { sqlite3_finalize(source) }
      bind(sourceID, to: 1, in: source)
      bind(sourceName, to: 2, in: source)
      bind(location, to: 3, in: source)
      bind(provider.rawValue, to: 4, in: source)
      bind(harness, to: 5, in: source)
      bind(fingerprint, to: 6, in: source)
      sqlite3_bind_double(source, 7, importedAt.timeIntervalSince1970)
      if let indexedAfter {
        sqlite3_bind_double(source, 8, indexedAfter.timeIntervalSince1970)
      } else {
        sqlite3_bind_null(source, 8)
      }
      try stepDone(source)

      let deletion = try prepare("DELETE FROM usage_events WHERE source_id = ?")
      defer { sqlite3_finalize(deletion) }
      bind(sourceID, to: 1, in: deletion)
      try stepDone(deletion)

      let insertion = try prepare("""
        INSERT INTO usage_events (
          event_id, source_id, source_event_id, dedupe_key,
          provider, billing_provider, billing_route, account_label,
          model_raw, model_canonical, model_family, model_publisher,
          model_identity_confidence, timestamp, session_id,
          reasoning_level, harness, application, agent, workspace,
          request_count, input_tokens, cached_input_tokens, cache_creation_tokens,
          output_tokens, reasoning_tokens, reported_total_tokens,
          cost_usd, attribution_confidence, granularity, imported_at
        ) VALUES (
          ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
        """)
      defer { sqlite3_finalize(insertion) }
      for sample in samples {
        sqlite3_reset(insertion)
        sqlite3_clear_bindings(insertion)
        bind("\(sourceID):\(sample.sourceEventID)", to: 1, in: insertion)
        bind(sourceID, to: 2, in: insertion)
        bind(sample.sourceEventID, to: 3, in: insertion)
        bind(sample.dedupeKey, to: 4, in: insertion)
        bind(sample.provider.rawValue, to: 5, in: insertion)
        bind(sample.billingProvider, to: 6, in: insertion)
        bind(sample.billingRoute, to: 7, in: insertion)
        bind(sample.accountLabel, to: 8, in: insertion)
        bind(sample.model, to: 9, in: insertion)
        bind(sample.canonicalModel, to: 10, in: insertion)
        bind(sample.modelFamily, to: 11, in: insertion)
        bind(sample.modelPublisher, to: 12, in: insertion)
        bind(sample.modelIdentityConfidence.rawValue, to: 13, in: insertion)
        sqlite3_bind_double(insertion, 14, sample.timestamp.timeIntervalSince1970)
        bind(sample.sessionID, to: 15, in: insertion)
        bind(sample.reasoningLevel, to: 16, in: insertion)
        bind(sample.harness, to: 17, in: insertion)
        bind(sample.application, to: 18, in: insertion)
        bind(sample.agent, to: 19, in: insertion)
        bind(sample.workspace, to: 20, in: insertion)
        sqlite3_bind_int64(insertion, 21, Int64(sample.requestCount))
        sqlite3_bind_int64(insertion, 22, sample.tokens.inputTokens)
        sqlite3_bind_int64(insertion, 23, sample.tokens.cachedInputTokens)
        sqlite3_bind_int64(insertion, 24, sample.tokens.cacheCreationTokens)
        sqlite3_bind_int64(insertion, 25, sample.tokens.outputTokens)
        sqlite3_bind_int64(insertion, 26, sample.tokens.reasoningTokens)
        if let total = sample.tokens.reportedTotalTokens {
          sqlite3_bind_int64(insertion, 27, total)
        } else {
          sqlite3_bind_null(insertion, 27)
        }
        if let cost = sample.costUSD {
          sqlite3_bind_double(insertion, 28, cost)
        } else {
          sqlite3_bind_null(insertion, 28)
        }
        bind(sample.attributionConfidence.rawValue, to: 29, in: insertion)
        bind(sample.granularity.rawValue, to: 30, in: insertion)
        sqlite3_bind_double(insertion, 31, importedAt.timeIntervalSince1970)
        try stepDone(insertion)
      }
      if transactional { try execute("COMMIT") }
    } catch {
      if transactional { try? execute("ROLLBACK") }
      throw error
    }
  }

  func performTransaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func samples(in interval: DateInterval) throws -> [UsageSample] {
    let statement = try prepare("""
      SELECT
        event_id, source_id, source_event_id, dedupe_key,
        provider, billing_provider, billing_route, account_label,
        model_raw, timestamp, session_id, reasoning_level,
        harness, application, agent, workspace,
        request_count, input_tokens, cached_input_tokens, cache_creation_tokens,
        output_tokens, reasoning_tokens, reported_total_tokens,
        cost_usd, attribution_confidence, granularity
      FROM usage_events
      WHERE timestamp >= ? AND timestamp < ?
      ORDER BY timestamp, event_id
      """)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
    sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970.nextUp)
    var result: [UsageSample] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return result
      case SQLITE_ROW:
        let provider = ProviderKind(rawValue: text(statement, 4)) ?? .unknown
        let tokens = UsageTokenCounts(
          inputTokens: sqlite3_column_int64(statement, 17),
          cachedInputTokens: sqlite3_column_int64(statement, 18),
          cacheCreationTokens: sqlite3_column_int64(statement, 19),
          outputTokens: sqlite3_column_int64(statement, 20),
          reasoningTokens: sqlite3_column_int64(statement, 21),
          reportedTotalTokens: optionalInt64(statement, 22)
        )
        result.append(UsageSample(
          id: text(statement, 0),
          provider: provider,
          timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
          sessionID: text(statement, 10),
          accountLabel: text(statement, 7),
          model: text(statement, 8),
          billingProvider: text(statement, 5),
          billingRoute: text(statement, 6),
          reasoningLevel: optionalText(statement, 11),
          harness: text(statement, 12),
          application: text(statement, 13),
          agent: optionalText(statement, 14),
          workspace: optionalText(statement, 15),
          tokens: tokens,
          requestCount: Int(sqlite3_column_int64(statement, 16)),
          costUSD: optionalDouble(statement, 23),
          attributionConfidence: UsageAttributionConfidence(
            rawValue: text(statement, 24)
          ) ?? .unknown,
          granularity: UsageGranularity(rawValue: text(statement, 25))
            ?? .modelCall,
          sourceID: text(statement, 1),
          sourceEventID: text(statement, 2),
          dedupeKey: optionalText(statement, 3)
        ))
      default:
        throw stepError()
      }
    }
  }

  func statistics(sourceID: String, in interval: DateInterval) throws -> UsageSourceStatistics {
    let statement = try prepare("""
      SELECT COUNT(DISTINCT session_id), COUNT(*),
             (SELECT imported_at FROM usage_sources WHERE source_id = ?)
      FROM usage_events
      WHERE source_id = ? AND timestamp >= ? AND timestamp < ?
      """)
    defer { sqlite3_finalize(statement) }
    bind(sourceID, to: 1, in: statement)
    bind(sourceID, to: 2, in: statement)
    sqlite3_bind_double(statement, 3, interval.start.timeIntervalSince1970)
    sqlite3_bind_double(statement, 4, interval.end.timeIntervalSince1970.nextUp)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return UsageSourceStatistics(
      sessions: Int(sqlite3_column_int64(statement, 0)),
      events: Int(sqlite3_column_int64(statement, 1)),
      importedAt: optionalDouble(statement, 2).map(Date.init(timeIntervalSince1970:))
    )
  }

  func statistics(sourceIDPrefix: String, in interval: DateInterval) throws -> UsageSourceStatistics {
    let statement = try prepare("""
      SELECT COUNT(DISTINCT source_id || ':' || session_id), COUNT(*),
             MAX(imported_at)
      FROM usage_events
      WHERE source_id LIKE ? ESCAPE '\\' AND timestamp >= ? AND timestamp < ?
      """)
    defer { sqlite3_finalize(statement) }
    let escapedPrefix = sourceIDPrefix
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "%", with: "\\%")
      .replacingOccurrences(of: "_", with: "\\_")
    bind(escapedPrefix + "%", to: 1, in: statement)
    sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
    sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970.nextUp)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return UsageSourceStatistics(
      sessions: Int(sqlite3_column_int64(statement, 0)),
      events: Int(sqlite3_column_int64(statement, 1)),
      importedAt: optionalDouble(statement, 2).map {
        Date(timeIntervalSince1970: $0)
      }
    )
  }

  func metadataDate(_ key: String) throws -> Date? {
    let statement = try prepare("SELECT value FROM usage_metadata WHERE key = ?")
    defer { sqlite3_finalize(statement) }
    bind(key, to: 1, in: statement)
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = Double(text(statement, 0)) else { return nil }
    return Date(timeIntervalSince1970: value)
  }

  func setMetadataDate(_ value: Date, for key: String) throws {
    let statement = try prepare("""
      INSERT INTO usage_metadata (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      """)
    defer { sqlite3_finalize(statement) }
    bind(key, to: 1, in: statement)
    bind(String(value.timeIntervalSince1970), to: 2, in: statement)
    try stepDone(statement)
  }

  func usageLimitAccounts(providers: Set<ProviderKind>) throws -> [UsageLimitAccount] {
    guard !providers.isEmpty else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let statement = try prepare("""
      SELECT provider, snapshot_json
      FROM usage_limit_snapshots
      ORDER BY provider
      """)
    defer { sqlite3_finalize(statement) }
    var accounts: [UsageLimitAccount] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return accounts
      case SQLITE_ROW:
        guard let provider = ProviderKind(rawValue: text(statement, 0)),
              providers.contains(provider),
              let data = text(statement, 1).data(using: .utf8),
              let account = try? decoder.decode(UsageLimitAccount.self, from: data)
        else { continue }
        accounts.append(account)
      default:
        throw stepError()
      }
    }
  }

  func saveUsageLimitAccounts(_ accounts: [UsageLimitAccount], storedAt: Date) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let statement = try prepare("""
      INSERT INTO usage_limit_snapshots (
        provider, snapshot_json, observed_at, stored_at
      ) VALUES (?, ?, ?, ?)
      ON CONFLICT(provider) DO UPDATE SET
        snapshot_json = excluded.snapshot_json,
        observed_at = excluded.observed_at,
        stored_at = excluded.stored_at
      """)
    defer { sqlite3_finalize(statement) }
    for account in accounts where account.status == .available {
      let data = try encoder.encode(account)
      guard let json = String(data: data, encoding: .utf8) else { continue }
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bind(account.provider.rawValue, to: 1, in: statement)
      bind(json, to: 2, in: statement)
      sqlite3_bind_double(statement, 3, account.observedAt.timeIntervalSince1970)
      sqlite3_bind_double(statement, 4, storedAt.timeIntervalSince1970)
      try stepDone(statement)
    }
  }

  func prune(before cutoff: Date) throws {
    let statement = try prepare("DELETE FROM usage_events WHERE timestamp < ?")
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
    try stepDone(statement)
  }

  private func setRuntimeSyncState(
    sourceID: String,
    endpoint: String,
    cursor: String,
    syncedAt: Date,
    status: UsageSourceStatus,
    detail: String
  ) throws {
    let statement = try prepare("""
      INSERT INTO usage_runtime_cursors (
        endpoint, source_id, cursor, synced_at, status, detail
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(endpoint) DO UPDATE SET
        source_id = excluded.source_id,
        cursor = excluded.cursor,
        synced_at = excluded.synced_at,
        status = excluded.status,
        detail = excluded.detail
      """)
    defer { sqlite3_finalize(statement) }
    bind(endpoint, to: 1, in: statement)
    bind(sourceID, to: 2, in: statement)
    bind(cursor, to: 3, in: statement)
    sqlite3_bind_double(statement, 4, syncedAt.timeIntervalSince1970)
    bind(status.rawValue, to: 5, in: statement)
    bind(detail, to: 6, in: statement)
    try stepDone(statement)
  }

  private func migrate() throws {
    try execute("""
      CREATE TABLE IF NOT EXISTS usage_sources (
        source_id TEXT PRIMARY KEY,
        source_name TEXT NOT NULL,
        source_location TEXT NOT NULL,
        provider TEXT NOT NULL,
        harness TEXT,
        fingerprint TEXT NOT NULL,
        imported_at REAL NOT NULL
      );
      CREATE TABLE IF NOT EXISTS usage_events (
        event_id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL REFERENCES usage_sources(source_id) ON DELETE CASCADE,
        source_event_id TEXT NOT NULL,
        dedupe_key TEXT,
        provider TEXT NOT NULL,
        billing_provider TEXT NOT NULL,
        billing_route TEXT NOT NULL,
        account_label TEXT NOT NULL,
        model_raw TEXT NOT NULL,
        model_canonical TEXT NOT NULL,
        model_family TEXT NOT NULL,
        model_publisher TEXT NOT NULL,
        model_identity_confidence TEXT NOT NULL,
        timestamp REAL NOT NULL,
        session_id TEXT NOT NULL,
        reasoning_level TEXT,
        harness TEXT NOT NULL,
        application TEXT NOT NULL,
        agent TEXT,
        workspace TEXT,
        request_count INTEGER NOT NULL DEFAULT 1,
        input_tokens INTEGER NOT NULL,
        cached_input_tokens INTEGER NOT NULL,
        cache_creation_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        reasoning_tokens INTEGER NOT NULL,
        reported_total_tokens INTEGER,
        cost_usd REAL,
        attribution_confidence TEXT NOT NULL,
        granularity TEXT NOT NULL,
        imported_at REAL NOT NULL,
        UNIQUE(source_id, source_event_id)
      );
      CREATE INDEX IF NOT EXISTS usage_events_timestamp_idx
        ON usage_events(timestamp, event_id);
      CREATE INDEX IF NOT EXISTS usage_events_source_idx
        ON usage_events(source_id, timestamp);
      CREATE INDEX IF NOT EXISTS usage_events_model_idx
        ON usage_events(model_family, timestamp);
      CREATE INDEX IF NOT EXISTS usage_events_route_idx
        ON usage_events(billing_route, timestamp);
      CREATE INDEX IF NOT EXISTS usage_events_harness_idx
        ON usage_events(harness, timestamp);
      CREATE INDEX IF NOT EXISTS usage_events_dedupe_idx
        ON usage_events(dedupe_key) WHERE dedupe_key IS NOT NULL;
      CREATE TABLE IF NOT EXISTS usage_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS usage_runtime_cursors (
        endpoint TEXT PRIMARY KEY,
        source_id TEXT NOT NULL,
        cursor TEXT NOT NULL,
        synced_at REAL NOT NULL,
        status TEXT NOT NULL,
        detail TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS usage_limit_snapshots (
        provider TEXT PRIMARY KEY,
        snapshot_json TEXT NOT NULL,
        observed_at REAL NOT NULL,
        stored_at REAL NOT NULL
      );
      """)
    try ensureColumn(
      table: "usage_events",
      column: "request_count",
      definition: "INTEGER NOT NULL DEFAULT 1"
    )
    try ensureColumn(
      table: "usage_sources",
      column: "source_kind",
      definition: "TEXT NOT NULL DEFAULT 'local-history'"
    )
    try ensureColumn(
      table: "usage_sources",
      column: "installation_id",
      definition: "TEXT"
    )
    try ensureColumn(
      table: "usage_sources",
      column: "indexed_after",
      definition: "REAL"
    )
    // Existing v1 indexes predate the explicit coverage watermark. Seed them
    // from their oldest retained event before any shorter refresh can replace
    // that source. Sources with no events remain nil and will be reparsed.
    try execute("""
      UPDATE usage_sources
      SET indexed_after = (
        SELECT MIN(timestamp)
        FROM usage_events
        WHERE usage_events.source_id = usage_sources.source_id
      )
      WHERE indexed_after IS NULL
        AND EXISTS (
          SELECT 1
          FROM usage_events
          WHERE usage_events.source_id = usage_sources.source_id
        )
      """)
  }

  private func ensureColumn(table: String, column: String, definition: String) throws {
    let statement = try prepare("PRAGMA table_info(\(table))")
    var found = false
    while sqlite3_step(statement) == SQLITE_ROW {
      if text(statement, 1) == column { found = true }
    }
    sqlite3_finalize(statement)
    if found { return }
    try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
  }

  private func execute(_ sql: String) throws {
    guard let connection else { throw UsageStoreError.open("connection closed") }
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(connection, sql, nil, nil, &error) == SQLITE_OK else {
      let detail = error.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(connection))
      sqlite3_free(error)
      throw UsageStoreError.step(detail)
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let connection else { throw UsageStoreError.open("connection closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw UsageStoreError.statement(String(cString: sqlite3_errmsg(connection)))
    }
    return statement
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
  }

  private func stepError() -> UsageStoreError {
    guard let connection else { return .step("connection closed") }
    return .step(String(cString: sqlite3_errmsg(connection)))
  }

  private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
    guard let value else {
      sqlite3_bind_null(statement, index)
      return
    }
    sqlite3_bind_text(statement, index, value, -1, Self.transient)
  }

  private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
  }

  private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return text(statement, index)
  }

  private func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, index)
  }

  private func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
  }
}

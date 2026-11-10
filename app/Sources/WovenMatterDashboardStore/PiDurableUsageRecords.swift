import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

/// Usage from Pi Durable entries: the default agent on Macs and Linux hosts, the
/// bots runtime, and iPhones and iPads. Only token counts and model names leave
/// an entry; prompts and replies are never read into a sample.
enum PiDurableUsageRecords {
  static let format = "pi-durable.entry.v1"
  static let harness = AgentRuntimeKind.defaultAgent.displayName

  /// Where an entry's replies are counted.
  struct Session: Sendable {
    let id: String
    var agent: String?
    var workspace: String?
    var sourceID: String
  }

  /// Samples for one session's entries (`{id, conversationId, model: [messages]}`).
  /// A later revision of an entry replaces an earlier one. A reply's identity is its
  /// session, time, model and token total, so the same reply read from a migrated
  /// store and from its retained backup is one record.
  static func samples(entries: [Data], session: Session) -> [UsageSample] {
    var byMessage: [String: UsageSample] = [:]
    for data in entries {
      guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      byMessage.merge(samples(entry: root, session: session)) { _, newer in newer }
    }
    return byMessage.values.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
  }

  private static func samples(entry root: [String: Any], session: Session) -> [String: UsageSample] {
    guard let entry = integer(root["id"]), let conversation = integer(root["conversationId"]),
          let messages = root["model"] as? [[String: Any]] else { return [:] }
    var result: [String: UsageSample] = [:]
    for (index, message) in messages.enumerated() {
      guard message["role"] as? String == "assistant",
            let usage = message["usage"] as? [String: Any],
            let milliseconds = (message["timestamp"] as? NSNumber)?.doubleValue, milliseconds.isFinite else { continue }
      let tokens = UsageTokenCounts(
        inputTokens: count(usage["input"]),
        cachedInputTokens: count(usage["cacheRead"]),
        cacheCreationTokens: count(usage["cacheWrite"]),
        outputTokens: count(usage["output"]),
        reasoningTokens: min(count(usage["output"]), count(usage["reasoning"])),
        reportedTotalTokens: usage["totalTokens"] == nil ? nil : count(usage["totalTokens"])
      )
      guard tokens.totalTokens > 0 else { continue }
      let model = (message["model"] as? String)?.nilIfEmpty ?? "Unknown model"
      let route = LocalUsageTranscriptParser.billingRoute(message["provider"] as? String ?? "Unknown")
      let identity = "\(session.id):\(Int64(milliseconds)):\(model):\(tokens.totalTokens)"
      result["\(conversation):\(entry):\(index)"] = UsageSample(
        id: "pi-durable:" + identity,
        provider: route.provider,
        timestamp: Date(timeIntervalSince1970: milliseconds / 1_000),
        sessionID: session.id,
        accountLabel: "Unknown",
        model: model,
        billingProvider: route.billingProvider,
        billingRoute: route.billingRoute,
        harness: harness,
        application: "Woven Matter",
        agent: session.agent,
        workspace: session.workspace,
        tokens: tokens,
        sourceID: session.sourceID,
        sourceEventID: identity,
        dedupeKey: "pi-durable:" + identity
      )
    }
    return result
  }

  /// A reply from the default agent's pre-Pi Durable session files, given the shared
  /// reply identity and the Pi Durable harness.
  static func adopting(_ sample: UsageSample) -> UsageSample {
    let milliseconds = Int64((sample.timestamp.timeIntervalSince1970 * 1_000).rounded())
    let identity = "\(sample.sessionID):\(milliseconds):\(sample.model):\(sample.tokens.totalTokens)"
    return UsageSample(
      id: "pi-durable:" + identity, provider: sample.provider, timestamp: sample.timestamp,
      sessionID: sample.sessionID, accountLabel: sample.accountLabel, model: sample.model,
      billingProvider: sample.billingProvider, billingRoute: sample.billingRoute,
      reasoningLevel: sample.reasoningLevel, harness: harness, application: "Woven Matter",
      workspace: sample.workspace, tokens: sample.tokens, costUSD: sample.costUSD,
      sourceID: sample.sourceID, sourceEventID: identity, dedupeKey: "pi-durable:" + identity
    )
  }

  /// iPhone and iPad records already synced to this Mac.
  static func records(from stored: [CompanionStoredNativeRecord]) -> [UsageDeviceRecord] {
    Dictionary(grouping: stored, by: \.conversationID).flatMap { conversation, records in
      samples(entries: records.map(\.data), session: .init(id: conversation, sourceID: "pi-durable"))
    }
    .map(UsageDeviceRecord.init(sample:))
    .sorted { $0.timestamp < $1.timestamp }
  }

  /// Entries of the default agent's session files from before its SQLite store:
  /// `durable/<session>/native/main.jsonl`, one commit of writes per line. A session
  /// that later moved into SQLite keeps this file as a backup, which the shared
  /// reply identity keeps from counting twice.
  static func legacyEntries(in url: URL, check: () throws -> Void) throws -> [Data] {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
    var entries: [Data] = []
    for line in data.split(separator: 0x0A) where line.range(of: Data("\"usage\"".utf8)) != nil {
      try check()
      guard let commit = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
            let writes = commit["writes"] as? [[String: Any]] else { continue }
      for write in writes where write["type"] as? String == "entry" {
        if let value = write["value"], let encoded = try? JSONSerialization.data(withJSONObject: value) {
          entries.append(encoded)
        }
      }
    }
    return entries
  }

  private static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber else { return nil }
    return number.int64Value
  }

  private static func count(_ value: Any?) -> Int64 {
    guard let number = value as? NSNumber, number.int64Value >= 0 else { return 0 }
    return number.int64Value
  }
}

/// Reads Pi Durable stores from a SQLite database without writing to it: the
/// default agent's `wm_pi_<store>_` namespaces (`wm_pi_runtime_stores`) and the bots
/// runtime's `pibot_<bot>_` namespaces (`pibot_bots`).
struct PiDurableUsageDatabase {
  let databaseURL: URL
  let sourceID: String

  /// One Pi Durable session (a default agent session, or one bot and its threads).
  struct Store: Sendable, Equatable {
    let prefix: String
    let session: String
    let agent: String?
    var isBot: Bool { prefix.hasPrefix("pibot_") }
  }

  func stores(check: @escaping @Sendable () throws -> Void = {}) throws -> [Store] {
    try open(check: check) { database in
      var stores: [Store] = []
      if try hasTable("wm_pi_runtime_stores", in: database) {
        for row in try rows("SELECT session_id, schema_prefix FROM wm_pi_runtime_stores", in: database, columns: 2) {
          guard let session = row[0], let prefix = row[1] else { continue }
          stores.append(.init(prefix: prefix, session: session, agent: nil))
        }
      }
      if try hasTable("pibot_bots", in: database) {
        // A deleted bot's usage still happened; its tables stay until it is purged.
        for row in try rows("SELECT id, name, schema_prefix FROM pibot_bots", in: database, columns: 3) {
          guard let bot = row[0], let prefix = row[2] else { continue }
          stores.append(.init(prefix: prefix, session: "bot:" + bot, agent: row[1]))
        }
      }
      return stores.filter { Self.isSafePrefix($0.prefix) }
    }
  }

  func samples(store: Store, cutoff: Date, now: Date, check: @escaping @Sendable () throws -> Void = {}) throws -> [UsageSample] {
    guard Self.isSafePrefix(store.prefix) else { return [] }
    return try open(check: check) { database in
      let table = store.prefix + "entries"
      guard try hasTable(table, in: database) else { return [] }
      let entries = try rows("""
        SELECT conversation_id, record FROM "\(table)" WHERE instr(record, '"usage"') > 0 ORDER BY id
        """, in: database, columns: 2)
      // A bot's main channel and each thread are their own sessions.
      let conversations = store.isBot ? Dictionary(grouping: entries, by: { $0[0] ?? "" }) : ["": entries]
      return conversations.flatMap { conversation, records in
        PiDurableUsageRecords.samples(
          entries: records.compactMap { $0[1].map { Data($0.utf8) } },
          session: .init(id: store.isBot ? store.session + ":" + conversation : store.session, agent: store.agent, sourceID: sourceID)
        )
      }.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
    }
  }

  private func open<T>(check: @escaping @Sendable () throws -> Void, _ body: (OpaquePointer) throws -> T) throws -> T {
    try check()
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw PiDurableUsageDatabaseError.openFailed
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 500)
    let cancellation = UsageSourceQueryCancellation(check)
    cancellation.install(on: database)
    defer { cancellation.remove(from: database) }
    return try body(database)
  }

  /// Table names are interpolated, so only the runtimes' own prefix shapes are read.
  static func isSafePrefix(_ prefix: String) -> Bool {
    prefix.wholeMatch(of: /(wm_pi|pibot)_[0-9a-f]{32}_/) != nil
  }

  private func hasTable(_ name: String, in database: OpaquePointer) throws -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw PiDurableUsageDatabaseError.queryFailed }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    switch sqlite3_step(statement) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: throw PiDurableUsageDatabaseError.queryFailed
    }
  }

  private func rows(_ sql: String, in database: OpaquePointer, columns: Int32) throws -> [[String?]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw PiDurableUsageDatabaseError.queryFailed
    }
    defer { sqlite3_finalize(statement) }
    var result: [[String?]] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return result }
      guard status == SQLITE_ROW else { throw PiDurableUsageDatabaseError.queryFailed }
      result.append((0..<columns).map { column in sqlite3_column_text(statement, column).map { String(cString: $0) } })
    }
  }
}

private enum PiDurableUsageDatabaseError: Error {
  case openFailed
  case queryFailed
}

public extension UsageDeviceEndpoint {
  /// Usage from an iPhone or iPad, read from records already on this Mac.
  static func piDurableHistory(identity: UsageDeviceIdentity, database: WorkspaceDatabase) -> Self {
    .init(identity: identity, alwaysFull: true) { request in
      let stored = try await database.companionNativeRecords(
        workspaceID: identity.id,
        format: PiDurableUsageRecords.format
      )
      return .paged(PiDurableUsageRecords.records(from: stored), request: request)
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

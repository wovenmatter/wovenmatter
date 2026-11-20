import Foundation
import WovenProtocol

// Usage records and dictation history. Reads are summed in SQL so a reply
// covers every machine without carrying every record.

/// One model response found in a harness's own history: counts only.
public struct UsageEntry: Sendable, Hashable {
  /// The harness's own identifier for the response, prefixed by the harness.
  public var id: String
  public var runtime: RuntimeKind
  /// The harness's own session identifier the response belongs to.
  public var nativeSession: String
  /// The history itself says Woven Matter made it.
  public var woven: Bool
  public var model: String
  public var at: Date
  public var input: Int64
  public var output: Int64
  public var cacheRead: Int64
  public var cacheWrite: Int64
  /// In US dollars, when the harness recorded it.
  public var cost: Double

  public init(id: String, runtime: RuntimeKind, nativeSession: String, woven: Bool = false, model: String, at: Date,
              input: Int64, output: Int64, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, cost: Double = 0) {
    self.id = id
    self.runtime = runtime
    self.nativeSession = nativeSession
    self.woven = woven
    self.model = model
    self.at = at
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.cost = cost
  }
}

/// How far one harness history file has been read.
public struct UsageSource: Sendable, Hashable {
  public var id: String
  public var offset: Int64
  public var size: Int64
  public var modified: Int64
  public var identity: String
  /// The reader's state where it stopped, as JSON.
  public var state: String

  public init(id: String, offset: Int64 = 0, size: Int64 = 0, modified: Int64 = 0, identity: String = "", state: String = "") {
    self.id = id
    self.offset = offset
    self.size = size
    self.modified = modified
    self.identity = identity
    self.state = state
  }
}

extension Library {
  /// Usage from `start` up to `end`, summed per machine, session, runtime,
  /// model and period of `periodSeconds`, with the range's totals. This
  /// machine's usage from an hour not yet over is included.
  public func usage(from start: Date, to end: Date, periodSeconds: Int) async throws -> UsageReport {
    let period = Int64(max(periodSeconds, 60)) * 1000
    let machine = machineID
    let range: [SQLValue] = [.text(machine), .integer(Self.millis(start)), .integer(Self.millis(end))]
    return try await read { db in
      let records = """
        WITH records AS (
          SELECT machine_id, session_id, native_session, woven, runtime, model, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, cost, requests, recorded_at
          FROM usage_records WHERE deleted = 0
          UNION ALL
          SELECT ?1, n.session_id, p.native_session, MAX(p.woven, n.session_id IS NOT NULL), p.runtime, p.model,
            p.input_tokens, p.output_tokens, p.cache_read_tokens, p.cache_write_tokens, p.cost, p.requests, p.recorded_at
          FROM usage_pending p LEFT JOIN native_sessions n ON n.runtime = p.runtime AND n.handle = p.native_session)
        """
      let sums = """
        SUM(input_tokens) AS input, SUM(output_tokens) AS output, SUM(cache_read_tokens) AS cache_read,
        SUM(cache_write_tokens) AS cache_write, SUM(cost) AS cost, SUM(requests) AS requests
        """
      let inRange = "recorded_at >= ?2 AND recorded_at < ?3"
      let groups = try db.query("""
        \(records)
        SELECT (recorded_at / \(period)) * \(period) AS period, MAX(recorded_at) AS latest, machine_id, session_id,
          native_session, woven, runtime, model, \(sums)
        FROM records WHERE \(inRange)
        GROUP BY period, machine_id, session_id, native_session, woven, runtime, model ORDER BY period, latest
        """, range).map { row in
        UsageGroup(period: row.date("period"), latest: row.date("latest"), machineID: row.text("machine_id") ?? "",
                   sessionID: row.text("session_id"), nativeSessionID: row.text("native_session"), inWoven: row.bool("woven"),
                   runtime: RuntimeKind(rawValue: row.text("runtime") ?? ""), model: row.text("model") ?? "",
                   amounts: Self.amounts(row))
      }
      let total = try db.query("""
        \(records)
        SELECT \(sums), COUNT(DISTINCT COALESCE(session_id, runtime || ':' || native_session)) AS sessions
        FROM records WHERE \(inRange)
        """, range).first
      var newest: [String: Date] = [:]
      for row in try db.query("\(records) SELECT machine_id, MAX(recorded_at) AS newest FROM records GROUP BY machine_id",
                              [.text(machine)]) {
        newest[row.text("machine_id") ?? ""] = row.date("newest")
      }
      return UsageReport(groups: groups, totals: total.map(Self.amounts) ?? UsageAmounts(),
                         sessions: Int(total?.integer("sessions") ?? 0), newestByMachine: newest)
    }
  }

  private static func amounts(_ row: Row) -> UsageAmounts {
    let cost: Double = switch row["cost"] {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: 0
    }
    return UsageAmounts(input: row.integer("input") ?? 0, output: row.integer("output") ?? 0,
                        cacheRead: row.integer("cache_read") ?? 0, cacheWrite: row.integer("cache_write") ?? 0,
                        cost: cost, requests: Int(row.integer("requests") ?? 0))
  }

  // MARK: Harness histories

  /// Every harness history file this machine has read, by source identifier.
  public func usageSources() async throws -> [String: UsageSource] {
    try await read { db in
      var sources: [String: UsageSource] = [:]
      for row in try db.query("SELECT * FROM usage_sources") {
        let id = row.text("id") ?? ""
        sources[id] = UsageSource(id: id, offset: row.integer("offset") ?? 0, size: row.integer("size") ?? 0,
                                  modified: row.integer("modified") ?? 0, identity: row.text("identity") ?? "",
                                  state: row.text("state") ?? "")
      }
      return sources
    }
  }

  /// Saves what one read of a harness history found and how far it read, in
  /// one transaction. A response already counted is skipped. Returns how
  /// many responses were new.
  @discardableResult
  public func saveUsage(_ entries: [UsageEntry], source: UsageSource) async throws -> Int {
    try await write { writer in
      let db = writer.db
      let now = Writer.now()
      var added = 0
      for entry in entries {
        guard try db.query("SELECT 1 FROM usage_seen WHERE id = ?", [.text(entry.id)]).isEmpty else { continue }
        try db.run("INSERT INTO usage_seen (id, seen_at) VALUES (?, ?)", [.text(entry.id), .integer(now)])
        let at = Self.millis(entry.at)
        let hour = at / 3_600_000 * 3_600_000
        let key = Self.digest(of: Data([entry.runtime.rawValue, entry.nativeSession, entry.model, String(hour),
                                        entry.woven ? "1" : "0"].joined(separator: "\n").utf8))
        try db.run("""
          INSERT INTO usage_pending (id, runtime, native_session, woven, model, hour, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, cost, requests, recorded_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
          ON CONFLICT (id) DO UPDATE SET input_tokens = input_tokens + excluded.input_tokens,
            output_tokens = output_tokens + excluded.output_tokens,
            cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
            cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens,
            cost = cost + excluded.cost, requests = requests + 1, recorded_at = MAX(recorded_at, excluded.recorded_at)
          """, [.text(key), .text(entry.runtime.rawValue), .text(entry.nativeSession), .integer(entry.woven ? 1 : 0),
                .text(entry.model), .integer(hour), .integer(entry.input), .integer(entry.output),
                .integer(entry.cacheRead), .integer(entry.cacheWrite), .real(entry.cost), .integer(at)])
        added += 1
      }
      try db.run("""
        INSERT INTO usage_sources (id, offset, size, modified, identity, state) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET offset = excluded.offset, size = excluded.size, modified = excluded.modified,
          identity = excluded.identity, state = excluded.state
        """, [.text(source.id), .integer(source.offset), .integer(source.size), .integer(source.modified),
              .text(source.identity), .text(source.state)])
      return added
    }
  }

  /// Moves the usage of every hour that ended before `now`, less a few
  /// minutes for late writes, into synced records, naming the Woven Matter
  /// session each was when this machine ran it. Usage that arrives for an
  /// hour already moved becomes another record. Returns the records written.
  @discardableResult
  public func flushUsage(now: Date = Date()) async throws -> Int {
    let closedBefore = Self.millis(now) - 3_600_000 - 5 * 60_000
    return try await write { writer in
      let db = writer.db
      var written = 0
      for row in try db.query("""
        SELECT p.*, n.session_id AS woven_session FROM usage_pending p
        LEFT JOIN native_sessions n ON n.runtime = p.runtime AND n.handle = p.native_session
        WHERE p.hour <= ?
        """, [.integer(closedBefore)]) {
        let key = row.text("id") ?? ""
        var ordinal = 0
        var id: String { Self.digest(of: Data("\(writer.machineID)\n\(key)\n\(ordinal)".utf8)) }
        while try writer.row("usage_records", id) != nil { ordinal += 1 }
        let session = row.text("woven_session")
        try writer.put("usage_records", id: id, [
          "machine_id": .text(writer.machineID), "session_id": session.map(SQLValue.text) ?? .null,
          "native_session": row["native_session"], "woven": .integer(row.bool("woven") || session != nil ? 1 : 0),
          "runtime": row["runtime"], "model": row["model"], "input_tokens": row["input_tokens"],
          "output_tokens": row["output_tokens"], "cache_read_tokens": row["cache_read_tokens"],
          "cache_write_tokens": row["cache_write_tokens"], "cost": row["cost"], "requests": row["requests"],
          "recorded_at": row["recorded_at"],
        ])
        try db.run("DELETE FROM usage_pending WHERE id = ?", [.text(key)])
        written += 1
      }
      try db.run("DELETE FROM usage_seen WHERE seen_at < ?", [.integer(Writer.now() - 60 * 86_400_000)])
      return written
    }
  }

  // MARK: Dictation history

  /// Saves a dictation made on this machine. A retried save of the same `id`
  /// changes nothing.
  public func saveDictation(id: String, text: String, recordedAt: Date) async throws {
    try await write { writer in
      guard try writer.row("dictation_history", id) == nil else { return }
      try writer.put("dictation_history", id: id, [
        "machine_id": .text(writer.machineID), "text": .text(text), "recorded_at": .integer(Self.millis(recordedAt)),
      ])
    }
  }

  /// Dictations from every machine, newest first.
  public func dictations(limit: Int, offset: Int) async throws -> [Dictation] {
    try await read { db in
      try db.query("""
        SELECT id, machine_id, text, recorded_at FROM dictation_history WHERE deleted = 0
        ORDER BY recorded_at DESC, id LIMIT ? OFFSET ?
        """, [.integer(Int64(max(limit, 0))), .integer(Int64(max(offset, 0)))]).map { row in
        Dictation(id: row.text("id") ?? "", machineID: row.text("machine_id") ?? "", text: row.text("text") ?? "",
                  recordedAt: row.date("recorded_at"))
      }
    }
  }
}

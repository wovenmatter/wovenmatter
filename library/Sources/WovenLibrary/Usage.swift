import Foundation
import WovenProtocol

// Usage and dictation history. Reads are summed in SQL so a reply covers
// every machine without carrying every record.

extension RuntimeKind {
  /// The harness keeps its own history, and its usage is counted only from
  /// there, inside Woven Matter or not, into `usage_hours`. A turn Woven
  /// Matter runs with it writes no usage record of its own.
  public var usageFromHistory: Bool { Self.keepingHistory.contains(self) }

  static let keepingHistory: [RuntimeKind] = [.codex, .claudeCode, .grokBuild, .openCode, .piCLI]
}

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
  /// The model calls it stands for: one, unless the harness records a turn's
  /// calls together.
  public var requests: Int64
  /// The history records here, under this identifier, a response it records
  /// under another: wherever else this identifier is seen, it counts nothing.
  public var restates: Bool

  public init(id: String, runtime: RuntimeKind, nativeSession: String, woven: Bool = false, model: String, at: Date,
              input: Int64, output: Int64, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, cost: Double = 0, requests: Int64 = 1,
              restates: Bool = false) {
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
    self.requests = requests
    self.restates = restates
  }
}

/// How far one harness history has been read.
public struct UsageSource: Sendable, Hashable {
  public var id: String
  public var offset: Int64
  public var size: Int64
  public var modified: Int64
  public var identity: String
  /// A digest of what lies just before `offset`, checked before reading on
  /// from there. Empty when the position is not to be trusted.
  public var boundary: String
  /// The reader's state where it stopped, as JSON.
  public var state: String
  /// Reads begun in a row that never finished: the process ended during them.
  public var interrupted: Int64
  /// When the history was last set aside because it could not be read, in
  /// ms; 0 when it was read.
  public var passedOver: Int64

  public init(id: String, offset: Int64 = 0, size: Int64 = 0, modified: Int64 = 0, identity: String = "", boundary: String = "",
              state: String = "", interrupted: Int64 = 0, passedOver: Int64 = 0) {
    self.id = id
    self.offset = offset
    self.size = size
    self.modified = modified
    self.identity = identity
    self.boundary = boundary
    self.state = state
    self.interrupted = interrupted
    self.passedOver = passedOver
  }
}

/// What one save of harness history usage changed.
public struct UsageSaved: Sendable, Equatable {
  /// Responses not counted before.
  public var added = 0
  /// Synced `usage_hours` rows written.
  public var records = 0
}

extension Library {
  /// Usage from `start` up to `end`, summed per machine, session, runtime,
  /// model and period of `periodSeconds`, with the range's totals. With a
  /// time zone and a period of a day, the periods are that zone's calendar
  /// days.
  public func usage(from start: Date, to end: Date, periodSeconds: Int, timeZone: TimeZone? = nil) async throws -> UsageReport {
    let seconds = min(max(periodSeconds, 60), 366 * 86_400)
    let calendar: Calendar? = timeZone.flatMap { zone in
      guard seconds == 86_400 else { return nil }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = zone
      return calendar
    }
    // Local days are folded from quarter-hour groups of the rows. A row of
    // usage read from a history sums a UTC hour and falls where its newest
    // response does, so days are exact where the zone's offset is whole hours.
    let period = Int64(calendar == nil ? seconds : 900) * 1000
    let range: [SQLValue] = [.integer(Self.millis(start)), .integer(Self.millis(end))]
    let history = Self.historyRuntimes
    return try await read { db in
      let records = """
        WITH records AS (
          SELECT machine_id, session_id, native_session, woven, runtime, model, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, cost, requests, recorded_at
          FROM usage_hours WHERE deleted = 0 AND requests > 0
          UNION ALL
          SELECT machine_id, session_id, native_session, woven, runtime, model, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, cost, requests, recorded_at
          FROM usage_records WHERE deleted = 0 AND runtime NOT IN (\(history)))
        """
      let sums = """
        SUM(input_tokens) AS input, SUM(output_tokens) AS output, SUM(cache_read_tokens) AS cache_read,
        SUM(cache_write_tokens) AS cache_write, SUM(cost) AS cost, SUM(requests) AS requests
        """
      let inRange = "recorded_at >= ?1 AND recorded_at < ?2"
      var groups = try db.query("""
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
      if let calendar { groups = Self.days(groups, calendar) }
      let total = try db.query("""
        \(records)
        SELECT \(sums), COUNT(DISTINCT COALESCE(session_id, runtime || ':' || native_session)) AS sessions
        FROM records WHERE \(inRange)
        """, range).first
      var newest: [String: Date] = [:]
      for row in try db.query("\(records) SELECT machine_id, MAX(recorded_at) AS newest FROM records GROUP BY machine_id") {
        newest[row.text("machine_id") ?? ""] = row.date("newest")
      }
      return UsageReport(groups: groups, totals: total.map(Self.amounts) ?? UsageAmounts(),
                         sessions: Int(total?.integer("sessions") ?? 0), newestByMachine: newest)
    }
  }

  /// The runtimes counted from their histories, as an SQL list.
  private static let historyRuntimes = RuntimeKind.keepingHistory
    .map { "'" + $0.rawValue.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")

  /// Quarter-hour groups folded into the calendar's days, each starting at
  /// its day's start, in the order of the day and then of the newest record.
  private static func days(_ groups: [UsageGroup], _ calendar: Calendar) -> [UsageGroup] {
    struct Key: Hashable {
      let day: Date, machineID: String, sessionID: String?, nativeSessionID: String?, inWoven: Bool
      let runtime: RuntimeKind, model: String
    }
    var order: [Key] = []
    var folded: [Key: UsageGroup] = [:]
    for group in groups {
      let day = calendar.startOfDay(for: group.period)
      let key = Key(day: day, machineID: group.machineID, sessionID: group.sessionID, nativeSessionID: group.nativeSessionID,
                    inWoven: group.inWoven, runtime: group.runtime, model: group.model)
      guard var sum = folded[key] else {
        var first = group
        first.period = day
        folded[key] = first
        order.append(key)
        continue
      }
      sum.latest = max(sum.latest, group.latest)
      sum.amounts.input += group.amounts.input
      sum.amounts.output += group.amounts.output
      sum.amounts.cacheRead += group.amounts.cacheRead
      sum.amounts.cacheWrite += group.amounts.cacheWrite
      sum.amounts.cost += group.amounts.cost
      sum.amounts.requests += group.amounts.requests
      folded[key] = sum
    }
    return order.compactMap { folded[$0] }.sorted { ($0.period, $0.latest) < ($1.period, $1.latest) }
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

  /// Every harness history this machine has read, by source identifier.
  public func usageSources() async throws -> [String: UsageSource] {
    try await read { db in
      var sources: [String: UsageSource] = [:]
      for row in try db.query("SELECT * FROM usage_sources") {
        let id = row.text("id") ?? ""
        sources[id] = UsageSource(id: id, offset: row.integer("offset") ?? 0, size: row.integer("size") ?? 0,
                                  modified: row.integer("modified") ?? 0, identity: row.text("identity") ?? "",
                                  boundary: row.text("boundary") ?? "", state: row.text("state") ?? "",
                                  interrupted: row.integer("interrupted") ?? 0, passedOver: row.integer("passed_over") ?? 0)
      }
      return sources
    }
  }

  /// The most one count of a response may be: no response comes near a
  /// trillion tokens, and sums of such counts stay far from overflowing.
  public static let maximumUsageCount: Int64 = 1_000_000_000_000

  /// Saves what one read of a harness history found and how far it read,
  /// and publishes the hours it changed, in one transaction. A response
  /// seen again takes the session, model, time and label of its earliest
  /// observation (a copy is made after what it copies), and the amounts of
  /// its fullest (more tokens, or as many with more requests or cost), so a
  /// streamed message's final counts win and a copied response stays where
  /// it was made, in whatever order the histories are read.
  @discardableResult
  public func saveUsage(_ entries: [UsageEntry], source: UsageSource) async throws -> UsageSaved {
    try await write { writer in
      let db = writer.db
      var saved = UsageSaved()
      var touched = Set<UsageHour>()
      for entry in entries {
        let amounts = [entry.input, entry.output, entry.cacheRead, entry.cacheWrite].map { min(max($0, 0), Self.maximumUsageCount) }
        let cost = entry.cost.isFinite ? min(max(entry.cost, 0), 1e9) : 0
        let at = Self.millis(entry.at)
        let requests = min(max(entry.requests, 0), 1_000_000)
        if let row = try db.query("SELECT * FROM usage_responses WHERE id = ?", [.text(entry.id)]).first {
          if row.bool("restated") { continue }
          if entry.restates {
            try db.run("UPDATE usage_responses SET restated = 1 WHERE id = ?", [.text(entry.id)])
            touched.insert(UsageHour(row))
            continue
          }
          let stored = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"].map { row.integer($0) ?? 0 }
          let storedCost: Double = if case .real(let value) = row["cost"] { value } else { Double(row.integer("cost") ?? 0) }
          let storedRequests = row.integer("requests") ?? 0
          let fuller = (amounts.reduce(0, +), requests, cost) > (stored.reduce(0, +), storedRequests, storedCost)
          let earlier = at < row.integer("at") ?? .max
          guard fuller || earlier else { continue }
          if fuller {
            try db.run("""
              UPDATE usage_responses SET input_tokens = ?, output_tokens = ?, cache_read_tokens = ?, cache_write_tokens = ?,
                cost = ?, requests = ? WHERE id = ?
              """, amounts.map(SQLValue.integer) + [.real(cost), .integer(requests), .text(entry.id)])
          }
          if earlier {
            try db.run("UPDATE usage_responses SET native_session = ?, woven = ?, model = ?, at = ? WHERE id = ?",
                       [.text(entry.nativeSession), .integer(entry.woven ? 1 : 0), .text(entry.model), .integer(at), .text(entry.id)])
            touched.insert(UsageHour(runtime: row.text("runtime") ?? "", nativeSession: entry.nativeSession, model: entry.model,
                                     hour: Self.hour(of: at), woven: entry.woven))
          }
          touched.insert(UsageHour(row))
          continue
        }
        try db.run("""
          INSERT INTO usage_responses (id, runtime, native_session, woven, model, at, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, cost, requests, restated) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """, [.text(entry.id), .text(entry.runtime.rawValue), .text(entry.nativeSession), .integer(entry.woven ? 1 : 0),
                .text(entry.model), .integer(at)] + amounts.map(SQLValue.integer)
                + [.real(cost), .integer(requests), .integer(entry.restates ? 1 : 0)])
        if entry.restates { continue }
        touched.insert(UsageHour(runtime: entry.runtime.rawValue, nativeSession: entry.nativeSession, model: entry.model,
                                 hour: Self.hour(of: at), woven: entry.woven))
        saved.added += 1
      }
      try db.run("""
        INSERT INTO usage_sources (id, offset, size, modified, identity, boundary, state, interrupted, passed_over)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (id) DO UPDATE SET offset = excluded.offset, size = excluded.size, modified = excluded.modified,
          identity = excluded.identity, boundary = excluded.boundary, state = excluded.state,
          interrupted = excluded.interrupted, passed_over = excluded.passed_over
        """, [.text(source.id), .integer(source.offset), .integer(source.size), .integer(source.modified),
              .text(source.identity), .text(source.boundary), .text(source.state), .integer(source.interrupted),
              .integer(source.passedOver)])
      for hour in touched.sorted(by: { $0.order.lexicographicallyPrecedes($1.order) }) where try Self.publish(hour, writer) {
        saved.records += 1
      }
      return saved
    }
  }

  static func hour(of millis: Int64) -> Int64 {
    let hour: Int64 = 3_600_000
    return millis >= 0 ? millis / hour * hour : -((-millis + hour - 1) / hour * hour)
  }

  /// Publishes every hour of one harness session again, for when the Woven
  /// Matter session it belongs to changes.
  static func publishSession(runtime: RuntimeKind, nativeSession: String, _ writer: Writer) throws {
    let hours = try writer.db.query("""
      SELECT DISTINCT model, woven, at / 3600000 * 3600000 AS hour FROM usage_responses WHERE runtime = ? AND native_session = ?
      """, [.text(runtime.rawValue), .text(nativeSession)]).map { row in
      UsageHour(runtime: runtime.rawValue, nativeSession: nativeSession, model: row.text("model") ?? "",
                hour: row.integer("hour") ?? 0, woven: row.bool("woven"))
    }
    for hour in hours { _ = try publish(hour, writer) }
  }

  /// Writes the synced row of one group from the ledger, unless it already
  /// holds exactly that. Returns whether it wrote.
  private static func publish(_ group: UsageHour, _ writer: Writer) throws -> Bool {
    let db = writer.db
    guard let sums = try db.query("""
      SELECT SUM(input_tokens) AS input, SUM(output_tokens) AS output, SUM(cache_read_tokens) AS cache_read,
        SUM(cache_write_tokens) AS cache_write, SUM(cost) AS cost, SUM(requests) AS requests, MAX(at) AS latest
      FROM usage_responses WHERE runtime = ? AND native_session = ? AND model = ? AND woven = ? AND at >= ? AND at < ?
        AND restated = 0
      """, [.text(group.runtime), .text(group.nativeSession), .text(group.model), .integer(group.woven ? 1 : 0),
            .integer(group.hour), .integer(group.hour + 3_600_000)]).first else { return false }
    // A group whose responses all moved to an earlier observation's group,
    // or were found to restate others, is kept with nothing in it.
    let empty = sums["latest"] == .null
    // Several Woven Matter sessions can name one harness session; the first by identifier is it.
    let session = try db.query("SELECT MIN(session_id) AS id FROM native_sessions WHERE runtime = ? AND handle = ?",
                               [.text(group.runtime), .text(group.nativeSession)]).first?.text("id")
    let cost: Double = switch sums["cost"] {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: 0
    }
    let values: [String: SQLValue] = [
      "machine_id": .text(writer.machineID), "session_id": session.map(SQLValue.text) ?? .null,
      "native_session": .text(group.nativeSession), "woven": .integer(group.woven || session != nil ? 1 : 0),
      "runtime": .text(group.runtime), "model": .text(group.model), "hour": .integer(group.hour),
      "input_tokens": empty ? .integer(0) : sums["input"], "output_tokens": empty ? .integer(0) : sums["output"],
      "cache_read_tokens": empty ? .integer(0) : sums["cache_read"], "cache_write_tokens": empty ? .integer(0) : sums["cache_write"],
      "cost": .real(cost), "requests": empty ? .integer(0) : sums["requests"],
      "recorded_at": empty ? .integer(group.hour) : sums["latest"],
    ]
    let id = group.id(machine: writer.machineID)
    if empty, try writer.row("usage_hours", id) == nil { return false }
    if let current = try writer.row("usage_hours", id), values.allSatisfy({ current[$0.key] == $0.value }) { return false }
    try writer.put("usage_hours", id: id, values)
    return true
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

/// One synced usage row's group: a harness session's usage with one model in
/// one hour, made in Woven Matter by the history's own word or not.
struct UsageHour: Hashable {
  let runtime: String
  let nativeSession: String
  let model: String
  let hour: Int64
  let woven: Bool

  init(runtime: String, nativeSession: String, model: String, hour: Int64, woven: Bool) {
    self.runtime = runtime
    self.nativeSession = nativeSession
    self.model = model
    self.hour = hour
    self.woven = woven
  }

  /// The group of a `usage_responses` row.
  init(_ row: Row) {
    self.init(runtime: row.text("runtime") ?? "", nativeSession: row.text("native_session") ?? "", model: row.text("model") ?? "",
              hour: Library.hour(of: row.integer("at") ?? 0), woven: row.bool("woven"))
  }

  var order: [String] { [runtime, nativeSession, model, String(hour), woven ? "1" : "0"] }

  /// The row's identifier: a digest of the machine and the group, each part
  /// given with its length so no two groups encode alike.
  func id(machine: String) -> String {
    let parts = [machine] + order
    return Library.digest(of: Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8))
  }
}

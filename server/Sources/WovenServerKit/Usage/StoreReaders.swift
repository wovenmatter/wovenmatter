import Foundation
import WovenLibrary
import WovenProtocol

// Pi Durable and the bots keep their conversations in Pi Durable's SQLite
// storage: Pi Durable one table set per session (`s<session>_`), the bots
// one per bot (`bot_<bot>_`, listed in `bot_bots`). Each set's `entries`
// hold the model's messages, every assistant message with its usage; the
// `pi.usage` document of each conversation sums every model call, also
// those no entry keeps (Pi Durable's compaction summaries). The bots keep
// the calls they make outside a conversation (titles, memory, compaction)
// in `bot_usage`.

/// Which store a read is of.
enum PiStoreKind: Sendable {
  case piDurable
  case bots

  var runtime: RuntimeKind {
    switch self {
    case .piDurable: .piDurable
    case .bots: .bots
    }
  }
}

/// How far one store has been read: per table set, the last entry with a
/// digest of it, which must still be there, and the revision of each
/// conversation's `pi.usage` document last reconciled; and the last
/// `bot_usage` row.
struct PiStorePlace: Codable, Sendable, Equatable {
  struct Entry: Codable, Sendable, Equatable {
    var id: Int64
    var digest: String
  }

  var entries: [String: Entry] = [:]
  var documents: [String: [String: Int64]] = [:]
  var usage: Int64 = 0
}

enum PiStoreReader {
  /// The responses in `database` after `place`, at most about `limit` rows
  /// of it, all read at one moment; the place reached, and whether more is
  /// left.
  static func read(_ database: ReadOnlyDatabase, kind: PiStoreKind, after place: PiStorePlace, limit: Int = 2000) throws
    -> (entries: [UsageEntry], place: PiStorePlace, more: Bool) {
    try database.snapshot {
      var place = place
      var found: [UsageEntry] = []
      var budget = max(limit, 1)
      let sets = try tableSets(database, kind: kind)
      for set in sets {
        guard budget > 0 else { return (found, place, true) }
        let tables = try Set(database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE ?1 ESCAPE '\\'",
                                            [.text(set.prefix.replacingOccurrences(of: "_", with: "\\_") + "%")])
          .compactMap { $0.text("name") })
        guard tables.contains(set.prefix + "entries") else { continue }
        let entries = quoted(set.prefix + "entries")
        var start = place.entries[set.prefix]
        // A place whose entry is gone or differs is in a store that was replaced.
        if let known = start, try digest(database, entries, known.id) != known.digest {
          start = nil
          place.documents[set.prefix] = nil
        }
        let resolve = try resolver(database, set: set, tables: tables)
        let page = try database.query("""
          SELECT e.id, e.conversation_id, m.key AS message,
            json_extract(m.value, '$.provider') AS provider, json_extract(m.value, '$.model') AS model,
            json_extract(m.value, '$.timestamp') AS at, json_extract(m.value, '$.responseId') AS response,
            json_extract(m.value, '$.usage.input') AS input, json_extract(m.value, '$.usage.output') AS output,
            json_extract(m.value, '$.usage.cacheRead') AS cache_read, json_extract(m.value, '$.usage.cacheWrite') AS cache_write,
            json_extract(m.value, '$.usage.cost.total') AS cost
          FROM (SELECT id, conversation_id, record FROM \(entries) WHERE id > ?1 ORDER BY id LIMIT ?2) e
          LEFT JOIN json_each(e.record, '$.model') m
            ON json_type(e.record, '$.model') = 'array' AND json_extract(m.value, '$.role') = 'assistant'
              AND json_type(m.value, '$.usage') = 'object'
          ORDER BY e.id, m.key
          """, [.integer(start?.id ?? 0), .integer(Int64(budget))])
        var last: Int64?
        var read = Set<Int64>()
        for row in page {
          guard let id = row.integer("id") else { continue }
          last = id
          read.insert(id)
          guard let message = row.integer("message"), let at = HistoryReader.date(row.integer("at").map(Double.init)) else { continue }
          let response = row.text("response").flatMap { $0.isEmpty ? nil : $0 } ?? "\(set.name):\(id):\(message)"
          if let entry = entry(id: "\(kind.runtime.rawValue):\(response)", kind: kind,
                               session: resolve(row.integer("conversation_id") ?? 0), model: modelName(row.text("provider"), row.text("model")),
                               at: at, amounts: amounts(row)) {
            found.append(entry)
          }
        }
        budget -= read.count
        if let last { place.entries[set.prefix] = PiStorePlace.Entry(id: last, digest: try digest(database, entries, last) ?? "") }
        if tables.contains(set.prefix + "documents"), tables.contains(set.prefix + "document_revisions") {
          found += try remainders(database, set: set, kind: kind, resolve: resolve, place: &place)
        }
        // A full page may have more after it.
        if read.count >= max(limit, 1) || budget <= 0 { return (found, place, true) }
      }
      if kind == .bots, try !database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'bot_usage'").isEmpty {
        var resolvers: [String: (Int64) -> String] = [:]
        for set in sets { if let bot = set.bot { resolvers[bot] = try resolver(database, set: set, tables: []) } }
        let rows = try database.query("SELECT * FROM bot_usage WHERE id > ?1 ORDER BY id LIMIT ?2",
                                      [.integer(place.usage), .integer(Int64(budget))])
        for row in rows {
          guard let id = row.integer("id") else { continue }
          place.usage = max(place.usage, id)
          guard let at = HistoryReader.date(row.integer("created_at").map(Double.init)) else { continue }
          let bot = row.text("bot_id") ?? "", conversation = row.integer("conversation_id") ?? 0
          // A Forum room's own calls have no bot.
          let session = bot.isEmpty ? "forum/\(conversation)" : resolvers[bot]?(conversation) ?? "\(bot)/\(conversation)"
          let call = row.text("call_id").flatMap { $0.isEmpty ? nil : $0 } ?? "\(id)"
          if let entry = entry(id: "bots:call:\(call)", kind: kind, session: session, model: modelName(row.text("provider"), row.text("model")),
                               at: at, amounts: amounts(row)) {
            found.append(entry)
          }
        }
        if rows.count >= budget { return (found, place, true) }
      }
      return (found, place, false)
    }
  }

  private static func digest(_ database: ReadOnlyDatabase, _ entries: String, _ id: Int64) throws -> String? {
    try database.query("SELECT record FROM \(entries) WHERE id = ?1", [.integer(id)]).first
      .map { Library.digest(of: Data(($0.text("record") ?? "").utf8)) }
  }

  /// One table set of a store: its prefix, a short name for identifiers,
  /// the bot it is, and the harness session a root conversation's usage is
  /// filed under.
  struct TableSet {
    let prefix: String
    let name: String
    let bot: String?
    let session: (Int64) -> String
  }

  private static func tableSets(_ database: ReadOnlyDatabase, kind: PiStoreKind) throws -> [TableSet] {
    switch kind {
    case .piDurable:
      // `s` and the session's identifier without dashes; the session is that identifier.
      return try database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 's%\\_entries' ESCAPE '\\'")
        .compactMap { $0.text("name") }.sorted().compactMap { table in
          let prefix = String(table.dropLast("entries".count))
          let hex = prefix.dropFirst().dropLast()
          guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
          var rest = Substring(hex)
          let session = [8, 4, 4, 4, 12].map { length -> String in
            defer { rest = rest.dropFirst(length) }
            return String(rest.prefix(length))
          }.joined(separator: "-").lowercased()
          return TableSet(prefix: prefix, name: String(prefix.dropLast()), bot: nil, session: { _ in session })
        }
    case .bots:
      guard try !database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'bot_bots'").isEmpty else { return [] }
      let seats = try database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'bot_forum_seat_conversations'").isEmpty
        ? [] : database.query("SELECT bot_id, conversation_id, room_id FROM bot_forum_seat_conversations")
      var rooms: [String: [Int64: Int64]] = [:]
      for seat in seats {
        rooms[seat.text("bot_id") ?? "", default: [:]][seat.integer("conversation_id") ?? 0] = seat.integer("room_id") ?? 0
      }
      return try database.query("SELECT id, schema_prefix FROM bot_bots ORDER BY id").compactMap { row in
        guard let bot = row.text("id"), let prefix = row.text("schema_prefix") else { return nil }
        let seatsOf = rooms[bot] ?? [:]
        // A bot's seat in a Forum room is filed under the room; its chats under the bot's own.
        return TableSet(prefix: prefix, name: String(prefix.dropLast()), bot: bot, session: { root in
          seatsOf[root].map { "forum/\($0)" } ?? "\(bot)/\(root)"
        })
      }
    }
  }

  /// The harness session a conversation's usage is filed under: that of the
  /// conversation it counts under, a sub-agent's being its owner's, up to
  /// one no conversation or task owns.
  private static func resolver(_ database: ReadOnlyDatabase, set: TableSet, tables known: Set<String>) throws -> (Int64) -> String {
    let tables = known.isEmpty
      ? try Set(database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?1, ?2)",
                               [.text(set.prefix + "conversations"), .text(set.prefix + "tasks")]).compactMap { $0.text("name") })
      : known
    var owners: [Int64: Int64] = [:]
    if tables.contains(set.prefix + "conversations") {
      var tasks: [Int64: Int64] = [:]
      if tables.contains(set.prefix + "tasks") {
        for row in try database.query("SELECT id, conversation_id FROM \(quoted(set.prefix + "tasks"))") {
          if let id = row.integer("id"), let conversation = row.integer("conversation_id") { tasks[id] = conversation }
        }
      }
      for row in try database.query("SELECT id, owner_conversation_id, owner_task_id FROM \(quoted(set.prefix + "conversations"))") {
        guard let id = row.integer("id") else { continue }
        if let owner = row.integer("owner_conversation_id") { owners[id] = owner }
        else if let task = row.integer("owner_task_id"), let owner = tasks[task] { owners[id] = owner }
      }
    }
    return { conversation in
      var current = conversation
      var seen: Set<Int64> = [current]
      while let owner = owners[current], seen.insert(owner).inserted { current = owner }
      return set.session(current)
    }
  }

  /// What each changed `pi.usage` document of a table set sums beyond its
  /// conversation's assistant entries, per model, tokens and cost: the
  /// calls no entry keeps (compaction summaries). One response per
  /// conversation and model, dated at the conversation's newest compaction
  /// summary (else its newest response); it grows as more such calls are
  /// made.
  private static func remainders(_ database: ReadOnlyDatabase, set: TableSet, kind: PiStoreKind, resolve: (Int64) -> String,
                                 place: inout PiStorePlace) throws -> [UsageEntry] {
    let documents = quoted(set.prefix + "documents"), revisions = quoted(set.prefix + "document_revisions")
    let entries = quoted(set.prefix + "entries")
    let docs = try database.query("""
      SELECT d.id, d.owner_id AS conversation, r.seq, r.content FROM \(documents) d JOIN \(revisions) r ON r.document_id = d.id
      WHERE d.kind = '"pi.usage"' AND d.scope_kind = 'conversation'
        AND r.seq = (SELECT MAX(seq) FROM \(revisions) WHERE document_id = d.id)
      """)
    var seen = place.documents[set.prefix] ?? [:]
    var found: [UsageEntry] = []
    for doc in docs {
      guard let id = doc.integer("id"), let seq = doc.integer("seq"), let conversation = doc.integer("conversation") else { continue }
      guard seen["\(id)"] != seq else { continue }
      seen["\(id)"] = seq
      guard let content = (try? JSONSerialization.jsonObject(with: Data((doc.text("content") ?? "").utf8))) as? [String: Any],
            let models = content["models"] as? [String: Any] else { continue }
      var counted: [String: [Double]] = [:]
      var newest: Double?
      for row in try database.query("""
        SELECT json_extract(m.value, '$.provider') AS provider, json_extract(m.value, '$.model') AS model,
          MAX(json_extract(m.value, '$.timestamp')) AS at,
          TOTAL(json_extract(m.value, '$.usage.input')) AS input, TOTAL(json_extract(m.value, '$.usage.output')) AS output,
          TOTAL(json_extract(m.value, '$.usage.cacheRead')) AS cache_read, TOTAL(json_extract(m.value, '$.usage.cacheWrite')) AS cache_write,
          TOTAL(json_extract(m.value, '$.usage.cost.total')) AS cost
        FROM \(entries) e, json_each(e.record, '$.model') m
        WHERE e.conversation_id = ?1 AND json_type(e.record, '$.model') = 'array' AND json_extract(m.value, '$.role') = 'assistant'
        GROUP BY 1, 2
        """, [.integer(conversation)]) {
        counted[modelName(row.text("provider"), row.text("model"))] =
          ["input", "output", "cache_read", "cache_write", "cost"].map { real(row[$0]) }
        if let at = row.integer("at") { newest = max(newest ?? 0, Double(at)) }
      }
      let compacted = try database.query("""
        SELECT MAX(json_extract(record, '$.model[0].timestamp')) AS at FROM \(entries)
        WHERE conversation_id = ?1 AND json_extract(record, '$.kind') = 'pi.compaction'
        """, [.integer(conversation)]).first?.integer("at").map(Double.init)
      guard let at = (compacted ?? newest).flatMap({ HistoryReader.date($0) }) else { continue }
      for (model, value) in models.sorted(by: { $0.key < $1.key }) {
        guard let total = value as? [String: Any] else { continue }
        let sums = counted[model] ?? [0, 0, 0, 0, 0]
        let cost = HistoryReader.amount((total["cost"] as? [String: Any])?["total"]) ?? 0
        let totals = ["input", "output", "cacheRead", "cacheWrite"].map { Double(HistoryReader.count(total[$0])) } + [cost]
        let rest = zip(totals, sums).map { max(0, $0 - $1) }
        guard rest.prefix(4).contains(where: { $0 >= 1 }) else { continue }
        let amounts = rest.prefix(4).map { Int64($0.rounded()) }
        if let entry = entry(id: "\(kind.runtime.rawValue):\(set.name):\(conversation):calls:\(model)", kind: kind,
                             session: resolve(conversation), model: model, at: at,
                             amounts: (amounts[0], amounts[1], amounts[2], amounts[3], rest[4])) {
          found.append(entry)
        }
      }
    }
    place.documents[set.prefix] = seen
    return found
  }

  private static func amounts(_ row: Row) -> (Int64, Int64, Int64, Int64, Double) {
    (HistoryReader.count(row.integer("input")), HistoryReader.count(row.integer("output")),
     HistoryReader.count(row.integer("cache_read")), HistoryReader.count(row.integer("cache_write")), max(0, real(row["cost"])))
  }

  private static func entry(id: String, kind: PiStoreKind, session: String, model: String, at: Date,
                            amounts: (input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double)) -> UsageEntry? {
    let entry = UsageEntry(id: id, runtime: kind.runtime, nativeSession: session, woven: true, model: model, at: at,
                           input: amounts.input, output: amounts.output, cacheRead: amounts.cacheRead,
                           cacheWrite: amounts.cacheWrite, cost: amounts.cost.isFinite ? amounts.cost : 0)
    return entry.input + entry.output + entry.cacheRead + entry.cacheWrite > 0 || entry.cost > 0 ? entry : nil
  }

  /// `provider/model`, as the Pi CLI reader names them.
  private static func modelName(_ provider: String?, _ model: String?) -> String {
    [provider, model].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: "/")
  }

  private static func real(_ value: SQLValue) -> Double {
    switch value {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: 0
    }
  }

  private static func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

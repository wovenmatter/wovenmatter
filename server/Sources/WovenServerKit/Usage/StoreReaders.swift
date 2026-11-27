import Foundation
import WovenLibrary
import WovenProtocol

// Pi Durable and the bots keep their conversations in Pi Durable's SQLite
// storage: Pi Durable one table set per session (`s<session>_`), the bots
// one per bot (`bot_<bot>_`, listed in `bot_bots`). Each set's `entries`
// hold the model's messages, every assistant message with its usage; the
// `pi.usage` document of each conversation sums every model call, also
// those no entry keeps (compaction's summaries). The bots keep the calls
// they make outside a conversation (titles, memory) in `bot_usage`.

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

/// How far one store has been read: per table set, the last entry and a
/// digest of it, which must still be there; and the last `bot_usage` row.
struct PiStorePlace: Codable, Sendable, Equatable {
  struct Entry: Codable, Sendable, Equatable {
    var id: Int64
    var digest: String
  }

  var entries: [String: Entry] = [:]
  var usage: Int64 = 0
}

enum PiStoreReader {
  /// The responses in `database` after `place`, leaving out those before
  /// `since`, and the place reached.
  static func read(_ database: ReadOnlyDatabase, kind: PiStoreKind, after place: PiStorePlace, since: Date? = nil) throws
    -> (entries: [UsageEntry], place: PiStorePlace) {
    var place = place
    var found: [UsageEntry] = []
    for set in try tableSets(database, kind: kind) {
      let tables = try Set(database.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE ?1 ESCAPE '\\'",
                                          [.text(set.prefix.replacingOccurrences(of: "_", with: "\\_") + "%")])
        .compactMap { $0.text("name") })
      guard tables.contains(set.prefix + "entries") else { continue }
      var start = place.entries[set.prefix]
      // A place whose entry is gone or differs is in a store that was replaced.
      if let known = start,
         try database.query("SELECT record FROM \(quoted(set.prefix + "entries")) WHERE id = ?1", [.integer(known.id)])
           .first.map({ Library.digest(of: Data(($0.text("record") ?? "").utf8)) }) != known.digest {
        start = nil
      }
      let roots = try conversationRoots(database, prefix: set.prefix, tables: tables)
      let session = { (conversation: Int64) in set.session(roots(conversation)) }
      var last = start
      for row in try database.query("SELECT id, conversation_id, record FROM \(quoted(set.prefix + "entries")) WHERE id > ?1 ORDER BY id",
                                    [.integer(start?.id ?? 0)]) {
        guard let id = row.integer("id"), let body = row.text("record") else { continue }
        last = PiStorePlace.Entry(id: id, digest: Library.digest(of: Data(body.utf8)))
        guard let record = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let messages = record["model"] as? [Any] else { continue }
        for (index, value) in messages.enumerated() {
          guard let message = value as? [String: Any], message["role"] as? String == "assistant",
                let usage = message["usage"] as? [String: Any], let at = HistoryReader.date(message["timestamp"]) else { continue }
          let response = text(message["responseId"]) ?? "\(set.name):\(id):\(index)"
          if let entry = Self.entry(id: "\(kind.runtime.rawValue):\(response)", kind: kind,
                                    session: session(row.integer("conversation_id") ?? 0),
                                    model: modelName(message["provider"], message["model"]), at: at, usage: usage) {
            found.append(entry)
          }
        }
      }
      if let last { place.entries[set.prefix] = last }
      if tables.contains(set.prefix + "documents"), tables.contains(set.prefix + "document_revisions") {
        found += try aggregates(database, set: set, kind: kind, session: session)
      }
    }
    if kind == .bots, try !database.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'bot_usage'").isEmpty {
      let rows = try database.query("SELECT * FROM bot_usage WHERE id > ?1 ORDER BY id", [.integer(place.usage)])
      for row in rows {
        guard let id = row.integer("id"), let at = HistoryReader.date(row.integer("created_at").map(Double.init)) else { continue }
        place.usage = max(place.usage, id)
        let bot = row.text("bot_id") ?? "", conversation = row.integer("conversation_id") ?? 0
        let usage: [String: Any] = [
          "input": row.integer("input") ?? 0, "output": row.integer("output") ?? 0, "cacheRead": row.integer("cache_read") ?? 0,
          "cacheWrite": row.integer("cache_write") ?? 0, "cost": ["total": Self.real(row["cost"])],
        ]
        let response = row.text("response_id").flatMap { $0.isEmpty ? nil : $0 } ?? "usage:\(id)"
        if let entry = Self.entry(id: "bots:\(response)", kind: kind, session: bot.isEmpty ? "forum/\(conversation)" : "\(bot)/\(conversation)",
                                  model: modelName(row.text("provider"), row.text("model")), at: at, usage: usage) {
          found.append(entry)
        }
      }
    }
    if let since { found.removeAll { $0.at < since } }
    return (found, place)
  }

  /// One table set of a store: its prefix, a short name for identifiers,
  /// and the harness session a conversation's usage is filed under.
  struct TableSet {
    let prefix: String
    let name: String
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
          let parts = [8, 4, 4, 4, 12].reduce(into: (parts: [String](), rest: Substring(hex))) { result, length in
            result.parts.append(String(result.rest.prefix(length)))
            result.rest = result.rest.dropFirst(length)
          }.parts
          let session = parts.joined(separator: "-").lowercased()
          return TableSet(prefix: prefix, name: String(prefix.dropLast()), session: { _ in session })
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
        return TableSet(prefix: prefix, name: String(prefix.dropLast()), session: { root in
          seatsOf[root].map { "forum/\($0)" } ?? "\(bot)/\(root)"
        })
      }
    }
  }

  /// The conversation a conversation's usage counts under: a sub-agent's,
  /// its owner's, up to one no conversation or task owns.
  private static func conversationRoots(_ database: ReadOnlyDatabase, prefix: String, tables: Set<String>)
    throws -> (Int64) -> Int64 {
    guard tables.contains(prefix + "conversations") else { return { $0 } }
    var owners: [Int64: Int64] = [:]
    var tasks: [Int64: Int64] = [:]
    if tables.contains(prefix + "tasks") {
      for row in try database.query("SELECT id, conversation_id FROM \(quoted(prefix + "tasks"))") {
        if let id = row.integer("id"), let conversation = row.integer("conversation_id") { tasks[id] = conversation }
      }
    }
    for row in try database.query("SELECT id, owner_conversation_id, owner_task_id FROM \(quoted(prefix + "conversations"))") {
      guard let id = row.integer("id") else { continue }
      if let owner = row.integer("owner_conversation_id") { owners[id] = owner }
      else if let task = row.integer("owner_task_id"), let owner = tasks[task] { owners[id] = owner }
    }
    return { conversation in
      var current = conversation
      var seen: Set<Int64> = [current]
      while let owner = owners[current], seen.insert(owner).inserted { current = owner }
      return current
    }
  }

  /// What each conversation's `pi.usage` document sums beyond its assistant
  /// entries, per model: the calls no entry keeps. Counted as one response
  /// per conversation and model, at the time of the conversation's newest
  /// entry; it grows as more such calls are made.
  private static func aggregates(_ database: ReadOnlyDatabase, set: TableSet, kind: PiStoreKind,
                                 session: (Int64) -> String) throws -> [UsageEntry] {
    let documents = quoted(set.prefix + "documents"), revisions = quoted(set.prefix + "document_revisions")
    let entries = quoted(set.prefix + "entries")
    let docs = try database.query("""
      SELECT d.owner_id AS conversation, r.content FROM \(documents) d JOIN \(revisions) r ON r.document_id = d.id
      WHERE d.kind = '"pi.usage"' AND d.scope_kind = 'conversation'
        AND r.seq = (SELECT MAX(seq) FROM \(revisions) WHERE document_id = d.id)
      """)
    guard !docs.isEmpty else { return [] }
    var counted: [String: [Int64]] = [:]
    var newest: [Int64: Double] = [:]
    for row in try database.query("""
      SELECT e.conversation_id AS conversation, json_extract(m.value, '$.provider') AS provider,
        json_extract(m.value, '$.model') AS model, MAX(json_extract(m.value, '$.timestamp')) AS at,
        SUM(json_extract(m.value, '$.usage.input')) AS input, SUM(json_extract(m.value, '$.usage.output')) AS output,
        SUM(json_extract(m.value, '$.usage.cacheRead')) AS cache_read, SUM(json_extract(m.value, '$.usage.cacheWrite')) AS cache_write
      FROM \(entries) e, json_each(e.record, '$.model') m
      WHERE json_valid(e.record) AND json_type(e.record, '$.model') = 'array' AND json_extract(m.value, '$.role') = 'assistant'
      GROUP BY 1, 2, 3
      """) {
      let conversation = row.integer("conversation") ?? 0
      counted["\(conversation)\n" + modelName(row.text("provider"), row.text("model"))] =
        ["input", "output", "cache_read", "cache_write"].map { row.integer($0) ?? 0 }
      if let at = row.integer("at") { newest[conversation] = max(newest[conversation] ?? 0, Double(at)) }
    }
    var found: [UsageEntry] = []
    for doc in docs {
      guard let conversation = doc.integer("conversation"), let at = newest[conversation].flatMap({ HistoryReader.date($0) }),
            let content = (try? JSONSerialization.jsonObject(with: Data((doc.text("content") ?? "").utf8))) as? [String: Any],
            let models = content["models"] as? [String: Any] else { continue }
      for (model, value) in models.sorted(by: { $0.key < $1.key }) {
        guard let total = value as? [String: Any] else { continue }
        let entries = counted["\(conversation)\n\(model)"] ?? [0, 0, 0, 0]
        let rest = zip(["input", "output", "cacheRead", "cacheWrite"].map { HistoryReader.count(total[$0]) }, entries).map { max(0, $0 - $1) }
        guard rest.contains(where: { $0 > 0 }) else { continue }
        let usage: [String: Any] = ["input": rest[0], "output": rest[1], "cacheRead": rest[2], "cacheWrite": rest[3]]
        if let entry = Self.entry(id: "\(kind.runtime.rawValue):\(set.name):\(conversation):calls:\(model)", kind: kind,
                                  session: session(conversation), model: model, at: at, usage: usage) {
          found.append(entry)
        }
      }
    }
    return found
  }

  private static func entry(id: String, kind: PiStoreKind, session: String, model: String, at: Date, usage: [String: Any]) -> UsageEntry? {
    let cost = HistoryReader.amount((usage["cost"] as? [String: Any])?["total"]) ?? 0
    let entry = UsageEntry(id: id, runtime: kind.runtime, nativeSession: session, woven: true, model: model, at: at,
                           input: HistoryReader.count(usage["input"]), output: HistoryReader.count(usage["output"]),
                           cacheRead: HistoryReader.count(usage["cacheRead"]), cacheWrite: HistoryReader.count(usage["cacheWrite"]),
                           cost: cost)
    return entry.input + entry.output + entry.cacheRead + entry.cacheWrite > 0 || cost > 0 ? entry : nil
  }

  /// `provider/model`, as the Pi CLI reader names them.
  private static func modelName(_ provider: Any?, _ model: Any?) -> String {
    [text(provider), text(model)].compactMap { $0 }.joined(separator: "/")
  }

  private static func text(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
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

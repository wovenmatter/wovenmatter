import Foundation
import WovenLibrary
import WovenProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Readers of each harness's own history, in the format the installed CLI
// writes. A reader takes whole lines and keeps what it needs between reads
// in its state, which is saved with the read position. Only counts, model
// names, times and the harnesses' own identifiers leave a line.

/// What a line reader keeps between reads of one file.
struct ReaderState: Codable, Sendable {
  var session: String?
  /// The session usage is counted under: a spawned agent's parent.
  var owner: String?
  var woven = false
  var model: String?
  var provider: String?
  /// Codex: the last cumulative count of the file's `token_count` events.
  var total: [Int64]?
  /// Codex: the turn the rollout's latest `turn_context` names.
  var turn: String?
  /// Codex: the usage of this turn's newest `token_usage_record`s no
  /// `token_count` has restated yet, at most `unpairedLimit`.
  var unpaired: [[Int64]]?
}

enum HistoryKind: Sendable, Equatable {
  /// A Codex rollout, `~/.codex/sessions/…/rollout-….jsonl`, perhaps compressed.
  case codex
  /// A Claude Code transcript. `session` is the file's own session for a
  /// session's file, nil for an agent's file under `subagents/`.
  case claude(session: String?)
  /// A Grok Build session's `updates.jsonl`, with its session folder's name.
  case grok(session: String, summary: URL)
  /// A Pi CLI session file.
  case pi

  var runtime: RuntimeKind {
    switch self {
    case .codex: .codex
    case .claude: .claudeCode
    case .grok: .grokBuild
    case .pi: .piCLI
    }
  }

  /// A line can only count if it holds one of these.
  var markers: [[UInt8]] {
    switch self {
    case .codex: [#""token_usage_record""#, #""token_count""#, #""session_meta""#, #""turn_context""#, #""task_started""#,
                  #""turn_started""#].map { Array($0.utf8) }
    case .claude: [Array(#""usage""#.utf8)]
    case .grok: [Array(#""usage""#.utf8), Array(#"Usage""#.utf8)]
    case .pi: [#""usage""#, #""session""#, #""model_change""#].map { Array($0.utf8) }
    }
  }
}

enum HistoryReader {
  /// The responses one line records, updating `state`.
  static func entries(_ line: UnsafeRawBufferPointer, kind: HistoryKind, state: inout ReaderState) -> [UsageEntry] {
    guard kind.markers.contains(where: { contains(line, $0) }),
          let root = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return [] }
    switch kind {
    case .codex: return codex(root, &state)
    case .claude(let session): return claude(root, session: session).map { [$0] } ?? []
    case .grok(let session, _): return grok(root, session: session, &state)
    case .pi: return pi(root, &state)
    }
  }

  // MARK: Codex

  /// `session_meta` names the thread, who started it (`originator`) and the
  /// thread that spawned it; `turn_context` the model. A
  /// `token_usage_record` is one response, by its own identifier. Older
  /// releases record a response only as a `token_count` event, with its
  /// usage (`last_token_usage`) and the thread's running total; newer ones
  /// write both, so a `token_count` restating a record counts nothing. A
  /// forked thread's copies of its parent's records keep the parent's
  /// `thread_id` and are left out, as are the copied events that restate
  /// them.
  private static func codex(_ root: [String: Any], _ state: inout ReaderState) -> [UsageEntry] {
    guard let payload = root["payload"] as? [String: Any] else { return [] }
    switch root["type"] as? String {
    case "session_meta":
      guard state.session == nil, let id = text(payload["id"]) else { return [] }
      state.session = id
      state.woven = text(payload["originator"]) == "Woven Matter"
      let spawn = ((payload["source"] as? [String: Any])?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
      state.owner = text(spawn?["parent_thread_id"]) ?? id
      return []
    case "turn_context":
      state.model = text(payload["model"]) ?? state.model
      codexTurn(text(payload["turn_id"]), &state)
      return []
    case "token_usage_record":
      guard let usage = payload["usage"] as? [String: Any], !usage.isEmpty else { return [] }
      var unpaired = state.unpaired ?? []
      unpaired.append(codexVector(usage))
      state.unpaired = Array(unpaired.suffix(unpairedLimit))
      guard let response = text(payload["response_id"]), let at = date(root["timestamp"]) else { return [] }
      let thread = text(payload["thread_id"])
      if let thread, let session = state.session, thread != session { return [] }
      return [codexEntry(id: "codex:" + response, nativeSession: state.owner ?? thread ?? "", usage: codexVector(usage),
                         at: at, state)]
    case "event_msg":
      // A turn starts: a record of the last one is restated within it or not
      // at all. The start's own identifier may be made up for a copy, so it
      // does not name the turn.
      if ["task_started", "turn_started"].contains(payload["type"] as? String) {
        state.unpaired = nil
        return []
      }
      guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
            let last = info["last_token_usage"] as? [String: Any], !last.isEmpty else { return [] }
      let usage = codexVector(last)
      let total = (info["total_token_usage"] as? [String: Any]).flatMap { $0.isEmpty ? nil : codexVector($0) }
      let first = state.total == nil
      if let total {
        // The same running total again: the event is repeated, not a response.
        if total == state.total { return [] }
        state.total = total
      }
      var restates = false
      if let index = state.unpaired?.firstIndex(of: usage) {
        state.unpaired?.remove(at: index)
        restates = true
      }
      // A file's first total that is more than its own usage carries what the
      // thread it was forked, resumed or spawned from used; that event
      // restates the other thread's last response, counted in its history.
      if !restates, first, let total, total != usage { return [] }
      guard usage.prefix(5).contains(where: { $0 > 0 }), let stamp = root["timestamp"], let at = date(stamp) else { return [] }
      // Known by its usage and running total, which a copy of it in a forked
      // thread's history keeps although its time is that of the copy. Where
      // the running total is the usage itself (a thread's first response),
      // two threads can share both, so the turn its `turn_context` names is
      // added, and the identifier without it is saved as counting nothing,
      // for a copy that kept no turn. One that restates a record is saved as
      // such, so a copy of it elsewhere counts nothing either.
      let plain = [usage.map(String.init).joined(separator: ","), total.map { $0.map(String.init).joined(separator: ",") } ?? "\(stamp)"]
      func id(_ key: [String]) -> String { "codex:counted:" + Library.digest(of: Data(key.joined(separator: "\n").utf8)).prefix(32) }
      let session = state.owner ?? state.session ?? ""
      var entries: [UsageEntry] = []
      var entry = codexEntry(id: id(plain), nativeSession: session, usage: usage, at: at, state)
      if let total, total == usage, let turn = state.turn {
        var copy = entry
        copy.restates = true
        entries.append(copy)
        entry.id = id(plain + [turn])
      }
      entry.restates = restates
      return entries + [entry]
    default:
      return []
    }
  }

  static let unpairedLimit = 64

  /// A new turn: a record of the last one is restated within it or not at all.
  private static func codexTurn(_ turn: String?, _ state: inout ReaderState) {
    guard let turn, turn != state.turn else { return }
    state.turn = turn
    state.unpaired = nil
  }

  /// A Codex usage object as its six counts: input (cached and written
  /// included), cached input, cache written, output (reasoning included),
  /// reasoning and total.
  private static func codexVector(_ usage: [String: Any]) -> [Int64] {
    ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens",
     "total_tokens"].map { integer(usage[$0]) }
  }

  private static func codexEntry(id: String, nativeSession: String, usage: [Int64], at: Date, _ state: ReaderState) -> UsageEntry {
    UsageEntry(id: id, runtime: .codex, nativeSession: nativeSession, woven: state.woven, model: state.model ?? "", at: at,
               input: max(0, usage[0] - usage[1] - usage[2]), output: usage[3], cacheRead: usage[1], cacheWrite: usage[2])
  }

  // MARK: Claude Code

  /// Each `assistant` line carries its message's usage; a message split over
  /// several lines repeats it, and its id counts it once. A session's file
  /// that copied another session's messages (a resume or fork) keeps their
  /// `sessionId`, so they are left out.
  private static func claude(_ root: [String: Any], session: String?) -> UsageEntry? {
    guard root["type"] as? String == "assistant", let message = root["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any], let id = text(message["id"]),
          let model = text(message["model"]), model != "<synthetic>",
          let owner = text(root["sessionId"]), let at = date(root["timestamp"]) else { return nil }
    if let session, owner != session { return nil }
    let entry = UsageEntry(id: "claude:" + id, runtime: .claudeCode, nativeSession: owner, model: model, at: at,
                           input: integer(usage["input_tokens"]), output: integer(usage["output_tokens"]),
                           cacheRead: integer(usage["cache_read_input_tokens"]),
                           cacheWrite: integer(usage["cache_creation_input_tokens"]), cost: number(root["costUSD"]) ?? 0)
    return entry.input + entry.output + entry.cacheRead + entry.cacheWrite > 0 ? entry : nil
  }

  // MARK: Grok Build

  /// A turn's usage arrives as an ACP update whose `usage` (or, per model,
  /// `modelUsage`) holds token counts, the model calls they took and the
  /// cost in ticks of 10⁻¹⁰ dollars. A turn's own call count is given to
  /// its model only when it used one; without counts per model each model
  /// counts one call. Lines copied from another session keep
  /// that session's event ids.
  private static func grok(_ root: [String: Any], session: String, _ state: inout ReaderState) -> [UsageEntry] {
    guard let params = root["params"] as? [String: Any], let update = params["update"] as? [String: Any] else { return [] }
    if let model = text(update["modelId"] ?? update["model"]) { state.model = model }
    guard let usage = update["usage"] as? [String: Any] else { return [] }
    let event = text((params["_meta"] as? [String: Any])?["eventId"] ?? (update["_meta"] as? [String: Any])?["eventId"])
    if let event, !event.hasPrefix(session + "-") { return [] }
    let turn = event ?? text(update["promptId"] ?? update["prompt_id"]) ?? ""
    guard !turn.isEmpty else { return [] }
    guard let at = date(root["timestamp_us"], unit: 1_000_000) ?? date(root["timestamp"]) else { return [] }
    let perModel = (usage["modelUsage"] ?? update["modelUsage"]) as? [String: Any]
    let counts: [(String, [String: Any])] = if let perModel, !perModel.isEmpty {
      perModel.compactMap { model, value in (value as? [String: Any]).map { (model, $0) } }
    } else {
      [(state.model ?? "", usage)]
    }
    return counts.compactMap { model, values in
      let cached = integer(values["cachedReadTokens"] ?? values["cacheReadTokens"])
      let written = integer(values["cacheCreationTokens"])
      let entry = UsageEntry(id: "grok:\(turn):\(model)", runtime: .grokBuild, nativeSession: session, model: model, at: at,
                             input: max(0, integer(values["inputTokens"]) - cached - written),
                             output: integer(values["outputTokens"]), cacheRead: cached, cacheWrite: written,
                             cost: (number(values["costUsdTicks"]) ?? 0) / 10_000_000_000,
                             requests: max(1, integer(values["modelCalls"] ?? (counts.count == 1 ? usage["modelCalls"] : nil))))
      return entry.input + entry.output + entry.cacheRead + entry.cacheWrite > 0 ? entry : nil
    }
  }

  // MARK: Pi CLI

  /// A `session` line names the session, `model_change` the model; each
  /// assistant `message`, `usage` entry (such as a cache warm) and
  /// `compaction` carries its own usage. A response keeps its provider's id
  /// in a branched session's copy, so it counts once.
  private static func pi(_ root: [String: Any], _ state: inout ReaderState) -> [UsageEntry] {
    switch root["type"] as? String {
    case "session":
      state.session = text(root["id"]) ?? state.session
      return []
    case "model_change":
      state.model = text(root["modelId"]) ?? state.model
      state.provider = text(root["provider"]) ?? state.provider
      return []
    case "message", "usage", "compaction":
      let message = root["message"] as? [String: Any]
      if root["type"] as? String == "message", message?["role"] as? String != "assistant" { return [] }
      guard let usage = (message?["usage"] ?? root["usage"]) as? [String: Any], let session = state.session,
            let entryID = text(root["id"]), let at = date(root["timestamp"]) else { return [] }
      let model = text(message?["model"] ?? root["model"]) ?? state.model ?? ""
      let provider = text(message?["provider"] ?? root["provider"]) ?? state.provider
      let response = text(message?["responseId"])
      let entry = UsageEntry(id: "pi:" + (response ?? "\(session):\(entryID)"), runtime: .piCLI, nativeSession: session,
                             model: provider.map { "\($0)/\(model)" } ?? model, at: at,
                             input: integer(usage["input"]), output: integer(usage["output"]),
                             cacheRead: integer(usage["cacheRead"]), cacheWrite: integer(usage["cacheWrite"]),
                             cost: number((usage["cost"] as? [String: Any])?["total"]) ?? 0)
      return entry.input + entry.output + entry.cacheRead + entry.cacheWrite > 0 ? [entry] : []
    default:
      return []
    }
  }

  // MARK: OpenCode

  /// OpenCode 2's database: each finished assistant message of
  /// `session_message` holds its tokens, cost and model. Reasoning tokens are
  /// billed as output. A sub-agent's session counts under its parent.
  /// The page of messages after `cursor`, up to and with `through` when given.
  static func openCode(_ database: ReadOnlyDatabase, after cursor: (time: Int64, id: String), through: (time: Int64, id: String)? = nil,
                       limit: Int) throws -> (entries: [UsageEntry], cursor: (time: Int64, id: String), rows: Int) {
    let end = through ?? (.max, "")
    let rows = try database.query("""
      SELECT m.id, m.time_updated, m.data, COALESCE(s.parent_id, m.session_id) AS owner FROM session_message m
      LEFT JOIN session_v2 s ON s.id = m.session_id
      WHERE m.type = 'assistant' AND (m.time_updated > ?1 OR (m.time_updated = ?1 AND m.id > ?2))
        AND (?5 = 0 OR m.time_updated < ?3 OR (m.time_updated = ?3 AND m.id <= ?4))
      ORDER BY m.time_updated, m.id LIMIT ?6
      """, [.integer(cursor.time), .text(cursor.id), .integer(end.time), .text(end.id), .integer(through == nil ? 0 : 1),
            .integer(Int64(limit))])
    var next = cursor
    var entries: [UsageEntry] = []
    for row in rows {
      guard let id = row.text("id") else { continue }
      next = (row.integer("time_updated") ?? next.time, id)
      guard let body = row.text("data"),
            let data = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
            let tokens = data["tokens"] as? [String: Any],
            let completed = date((data["time"] as? [String: Any])?["completed"]) else { continue }
      let model = data["model"] as? [String: Any]
      let cache = tokens["cache"] as? [String: Any]
      let name = [text(model?["providerID"]), text(model?["id"])].compactMap { $0 }.joined(separator: "/")
      let entry = UsageEntry(id: "opencode:" + id, runtime: .openCode, nativeSession: row.text("owner") ?? "", model: name,
                             at: completed, input: integer(tokens["input"]),
                             output: integer(tokens["output"]) + integer(tokens["reasoning"]),
                             cacheRead: integer(cache?["read"]), cacheWrite: integer(cache?["write"]),
                             cost: number(data["cost"]) ?? 0)
      if entry.input + entry.output + entry.cacheRead + entry.cacheWrite > 0 { entries.append(entry) }
    }
    return (entries, next, rows.count)
  }

  /// The message is still in the database.
  static func openCodeHas(_ database: ReadOnlyDatabase, message: String) throws -> Bool {
    try !database.query("SELECT 1 FROM session_message WHERE id = ?1", [.text(message)]).isEmpty
  }

  // MARK: Values

  static func contains(_ line: UnsafeRawBufferPointer, _ marker: [UInt8]) -> Bool {
    guard line.count >= marker.count, let first = marker.first, let base = line.baseAddress else { return false }
    var index = 0
    let last = line.count - marker.count
    while index <= last {
      guard let found = memchr(base + index, Int32(first), last - index + 1) else { return false }
      let at = base.distance(to: UnsafeRawPointer(found))
      if memcmp(base + at, marker, marker.count) == 0 { return true }
      index = at + 1
    }
    return false
  }

  private static func text(_ value: Any?) -> String? {
    guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  /// The most one count may be.
  static let maximumCount = Library.maximumUsageCount

  /// A count as a reader of another format takes it.
  static func count(_ value: Any?) -> Int64 { integer(value) }
  /// An amount, such as a cost, as a reader of another format takes it.
  static func amount(_ value: Any?) -> Double? { number(value) }

  private static func integer(_ value: Any?) -> Int64 {
    guard let value = number(value) else { return 0 }
    return Int64(min(value, Double(maximumCount)))
  }

  /// A JSON number, however Foundation on this platform hands it over.
  private static func number(_ value: Any?) -> Double? {
    let result: Double? = switch value {
    case let value as Int: Double(value)
    case let value as Int64: Double(value)
    case let value as Double: value
    case let value as NSNumber: value.doubleValue
    default: nil
    }
    guard let result, result.isFinite, result >= 0 else { return nil }
    return result
  }

  /// The times a history can hold: from 2000 up to 2100. Anything else is
  /// not a time.
  private static let plausible = Date(timeIntervalSince1970: 946_684_800)...Date(timeIntervalSince1970: 4_102_444_800)

  /// An ISO 8601 time, or a number of seconds, milliseconds, microseconds or
  /// nanoseconds since 1970: `unit` per second when given, else told apart by
  /// size. A value that is no plausible time is none.
  static func date(_ value: Any?, unit: Double? = nil) -> Date? {
    let parsed: Date?
    if let raw = number(value) {
      let divisor = unit ?? (raw >= 1e17 ? 1e9 : raw >= 1e14 ? 1e6 : raw >= 1e11 ? 1e3 : 1)
      parsed = Date(timeIntervalSince1970: raw / divisor)
    } else if let text = value as? String {
      parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
        ?? (try? Date.ISO8601FormatStyle().parse(text))
    } else {
      parsed = nil
    }
    guard let parsed, plausible.contains(parsed) else { return nil }
    return parsed
  }
}

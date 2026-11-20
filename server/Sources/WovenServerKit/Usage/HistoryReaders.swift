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
    case .codex: [#""token_usage_record""#, #""session_meta""#, #""turn_context""#].map { Array($0.utf8) }
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
  /// thread that spawned it; `turn_context` the model; each
  /// `token_usage_record` one response. A forked thread's copies of its
  /// parent's records keep the parent's `thread_id` and are left out.
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
      return []
    case "token_usage_record":
      guard let response = text(payload["response_id"]), let usage = payload["usage"] as? [String: Any],
            let at = date(root["timestamp"]) else { return [] }
      let thread = text(payload["thread_id"])
      if let thread, let session = state.session, thread != session { return [] }
      let cached = integer(usage["cached_input_tokens"]), written = integer(usage["cache_write_input_tokens"])
      return [UsageEntry(id: "codex:" + response, runtime: .codex, nativeSession: state.owner ?? thread ?? "",
                         woven: state.woven, model: state.model ?? "", at: at,
                         input: max(0, integer(usage["input_tokens"]) - cached - written), output: integer(usage["output_tokens"]),
                         cacheRead: cached, cacheWrite: written)]
    default:
      return []
    }
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
  /// `modelUsage`) holds token counts and the cost in ticks of 10⁻¹⁰ dollars.
  /// Lines copied from another session keep that session's event ids.
  private static func grok(_ root: [String: Any], session: String, _ state: inout ReaderState) -> [UsageEntry] {
    guard let params = root["params"] as? [String: Any], let update = params["update"] as? [String: Any] else { return [] }
    if let model = text(update["modelId"] ?? update["model"]) { state.model = model }
    guard let usage = update["usage"] as? [String: Any] else { return [] }
    let event = text((params["_meta"] as? [String: Any])?["eventId"] ?? (update["_meta"] as? [String: Any])?["eventId"])
    if let event, !event.hasPrefix(session + "-") { return [] }
    let turn = event ?? text(update["promptId"] ?? update["prompt_id"]) ?? ""
    guard !turn.isEmpty else { return [] }
    let at = number(root["timestamp_us"]).map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? date(root["timestamp"]) ?? Date()
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
                             cost: (number(values["costUsdTicks"]) ?? 0) / 10_000_000_000)
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
  static func openCode(_ database: ReadOnlyDatabase, after cursor: (time: Int64, id: String), limit: Int)
    throws -> (entries: [UsageEntry], cursor: (time: Int64, id: String), rows: Int) {
    let rows = try database.query("""
      SELECT m.id, m.time_updated, m.data, COALESCE(s.parent_id, m.session_id) AS owner FROM session_message m
      LEFT JOIN session_v2 s ON s.id = m.session_id
      WHERE m.type = 'assistant' AND (m.time_updated > ?1 OR (m.time_updated = ?1 AND m.id > ?2))
      ORDER BY m.time_updated, m.id LIMIT ?3
      """, [.integer(cursor.time), .text(cursor.id), .integer(Int64(limit))])
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

  private static func integer(_ value: Any?) -> Int64 {
    guard let value = number(value) else { return 0 }
    return Int64(value)
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

  /// An ISO 8601 time, or seconds or milliseconds since 1970.
  static func date(_ value: Any?) -> Date? {
    if let raw = number(value) {
      return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }
    guard let text = value as? String else { return nil }
    if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return parsed }
    return try? Date.ISO8601FormatStyle().parse(text)
  }
}

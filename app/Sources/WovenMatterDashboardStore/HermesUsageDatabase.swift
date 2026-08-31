import Foundation
import SQLite3
import WovenMatterCore

struct HermesUsageDatabase {
  let databaseURL: URL

  func samples(cutoff: Date, now: Date) throws -> [UsageSample] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
      if let database { sqlite3_close(database) }
      throw HermesUsageDatabaseError.openFailed
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 500)

    let sql = """
      SELECT u.session_id, u.model, u.billing_provider, u.billing_base_url,
             u.billing_mode, u.task, u.api_call_count, u.input_tokens,
             u.output_tokens, u.cache_read_tokens, u.cache_write_tokens,
             u.reasoning_tokens, u.estimated_cost_usd, u.actual_cost_usd,
             u.first_seen, u.last_seen, s.source, s.cwd
      FROM session_model_usage u
      LEFT JOIN sessions s ON s.id = u.session_id
      WHERE COALESCE(u.last_seen, u.first_seen, s.ended_at, s.started_at) >= ?
        AND COALESCE(u.last_seen, u.first_seen, s.ended_at, s.started_at) <= ?
      ORDER BY COALESCE(u.last_seen, u.first_seen, s.ended_at, s.started_at)
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { throw HermesUsageDatabaseError.queryFailed }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
    sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)

    var result: [UsageSample] = []
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_DONE:
        return result
      case SQLITE_ROW:
        guard let sessionID = text(statement, 0),
              let model = text(statement, 1) else { continue }
        let rawProvider = text(statement, 2) ?? ""
        let route = billingRoute(rawProvider, baseURL: text(statement, 3))
        let billingMode = text(statement, 4)
        let task = text(statement, 5)
        let timestampValue = sqlite3_column_double(statement, 15) > 0
          ? sqlite3_column_double(statement, 15)
          : sqlite3_column_double(statement, 14)
        guard timestampValue > 0 else { continue }
        let tokens = UsageTokenCounts(
          inputTokens: sqlite3_column_int64(statement, 7),
          cachedInputTokens: sqlite3_column_int64(statement, 9),
          cacheCreationTokens: sqlite3_column_int64(statement, 10),
          outputTokens: sqlite3_column_int64(statement, 8),
          reasoningTokens: sqlite3_column_int64(statement, 11)
        )
        guard tokens.totalTokens > 0 else { continue }
        let actualCost = sqlite3_column_double(statement, 13)
        let cost = actualCost > 0 ? actualCost : nil
        let sourceEventID = [
          sessionID,
          model,
          rawProvider,
          text(statement, 3) ?? "",
          billingMode ?? "",
          task ?? "",
        ].joined(separator: ":")
        result.append(UsageSample(
          id: "hermes:\(sourceEventID)",
          provider: route.provider,
          timestamp: Date(timeIntervalSince1970: timestampValue),
          sessionID: sessionID,
          accountLabel: "Unknown",
          model: model,
          billingProvider: route.billingProvider,
          billingRoute: route.billingRoute,
          harness: "Hermes",
          application: text(statement, 16) ?? "Hermes",
          agent: task,
          workspace: text(statement, 17).map {
            URL(fileURLWithPath: $0).lastPathComponent
          },
          tokens: tokens,
          requestCount: max(1, Int(sqlite3_column_int64(statement, 6))),
          costUSD: cost,
          attributionConfidence: .aggregate,
          granularity: .sessionAggregate,
          sourceEventID: sourceEventID
        ))
      default:
        throw HermesUsageDatabaseError.queryFailed
      }
    }
  }

  private func billingRoute(
    _ rawProvider: String,
    baseURL: String?
  ) -> (provider: ProviderKind, billingProvider: String, billingRoute: String) {
    let value = rawProvider.lowercased()
    if value.contains("openai-codex") || baseURL?.contains("/codex") == true {
      return (.codex, "OpenAI", "Codex subscription")
    }
    if value.contains("openrouter") || baseURL?.contains("openrouter.ai") == true {
      return (.openRouter, "OpenRouter", "OpenRouter API")
    }
    if value == "openai" || baseURL?.contains("api.openai.com") == true {
      return (.unknown, "OpenAI", "OpenAI API")
    }
    if value.contains("anthropic") || value.contains("claude") {
      return (.claude, "Anthropic", "Claude account")
    }
    if value.contains("xai") || value.contains("x-ai") || value.contains("grok") {
      return (.grok, "xAI", "Grok account")
    }
    if value.contains("opencode") {
      return (.openCodeGo, "OpenCode Go", "OpenCode Go subscription")
    }
    let label = rawProvider.isEmpty ? "Unknown" : rawProvider
    return (.unknown, label, label)
  }

  private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    let result = String(cString: value)
    return result.isEmpty ? nil : result
  }
}

private enum HermesUsageDatabaseError: Error {
  case openFailed
  case queryFailed
}

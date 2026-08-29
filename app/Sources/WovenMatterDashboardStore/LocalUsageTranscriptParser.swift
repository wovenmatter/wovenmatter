import Foundation
import WovenMatterCore

struct ParsedUsageSample: Codable {
  let sample: UsageSample
  let dedupeKey: String?
}

struct CodexUsageScanState {
  var model = ""
  var reasoningLevel: String?
  var sessionID = ""
  var application = "Codex CLI"
  var workspace: String?
  var lastUsageSignature: String?
  var sawSessionMetadata = false
  var suppressingForkCopies = false
  var forkCopyAnchor: Date?
}

struct HarnessUsageScanState {
  var sessionID = ""
  var model = ""
  var provider = ""
  var reasoningLevel: String?
  var workspace: String?
}

enum LocalUsageTranscriptParser {
  static let forkCopyMaximumGap: TimeInterval = 1

  static func parseClaude(line: String, lineNumber: Int) -> ParsedUsageSample? {
    guard line.contains("\"usage\"") else { return nil }
    guard let root = object(line), string(root["type"]) == "assistant",
          let message = dictionary(root["message"]),
          let usage = dictionary(message["usage"]),
          let timestamp = date(root["timestamp"]),
          let model = string(message["model"]), !model.isEmpty else { return nil }

    let messageID = string(message["id"])
    let requestID = string(root["requestId"] ?? root["request_id"])
    let dedupeKey: String? = if messageID == nil && requestID == nil {
      nil
    } else {
      "\(messageID ?? ""):\(requestID ?? "")"
    }
    let sessionID = string(root["sessionId"] ?? root["session_id"]) ?? ""
    let identity = dedupeKey ?? "\(sessionID):\(lineNumber):\(timestamp.timeIntervalSince1970)"
    let workspace = string(root["cwd"]).map(lastPathComponent)
    let application = string(root["entrypoint"])?.nilIfEmpty ?? "Claude Code"
    let tokens = UsageTokenCounts(
      inputTokens: integer(usage["input_tokens"]),
      cachedInputTokens: integer(usage["cache_read_input_tokens"]),
      cacheCreationTokens: integer(usage["cache_creation_input_tokens"]),
      outputTokens: integer(usage["output_tokens"])
    )
    guard tokens.totalTokens > 0 else { return nil }

    return ParsedUsageSample(
      sample: UsageSample(
        id: "claude:\(identity)",
        provider: .claude,
        timestamp: timestamp,
        sessionID: sessionID,
        accountLabel: "Unknown",
        model: model,
        billingProvider: "Anthropic",
        billingRoute: "Claude account",
        reasoningLevel: string(root["effort"]),
        harness: "Claude Code",
        application: application,
        agent: string(root["userType"]),
        workspace: workspace,
        tokens: tokens,
        costUSD: number(root["costUSD"] ?? root["cost_usd"]),
        sourceEventID: "\(identity)",
        dedupeKey: dedupeKey
      ),
      dedupeKey: dedupeKey
    )
  }

  static func parseCodex(
    line: String,
    lineNumber: Int,
    state: inout CodexUsageScanState
  ) -> ParsedUsageSample? {
    guard line.contains("\"token_count\"")
            || line.contains("\"turn_context\"")
            || line.contains("\"session_meta\"") else { return nil }
    guard let root = object(line), let payload = dictionary(root["payload"]) else { return nil }
    let type = string(root["type"])

    if type == "session_meta" {
      guard !state.sawSessionMetadata else { return nil }
      state.sawSessionMetadata = true
      state.sessionID = string(payload["id"] ?? payload["session_id"]) ?? state.sessionID
      state.workspace = string(payload["cwd"]).map(lastPathComponent)
      state.application = string(payload["originator"])
        ?? string(payload["source"])
        ?? "Codex CLI"
      if isForkedCodexSession(payload), let timestamp = date(root["timestamp"] ?? payload["timestamp"]) {
        state.suppressingForkCopies = true
        state.forkCopyAnchor = timestamp
      }
      return nil
    }

    if type == "turn_context" {
      state.model = string(payload["model"]) ?? state.model
      state.reasoningLevel = string(payload["effort"] ?? payload["reasoning_effort"])
        ?? state.reasoningLevel
      // Repeated token_count notifications inside a turn share a signature,
      // but two distinct turns can legitimately consume identical counts.
      state.lastUsageSignature = nil
      return nil
    }

    guard string(payload["type"]) == "token_count",
          let info = dictionary(payload["info"]),
          let usage = dictionary(info["last_token_usage"] ?? info["lastTokenUsage"]),
          let timestamp = date(root["timestamp"]),
          !state.model.isEmpty else { return nil }

    let signature = canonicalSignature(usage)
    guard signature != state.lastUsageSignature else { return nil }
    state.lastUsageSignature = signature

    if state.suppressingForkCopies, let anchor = state.forkCopyAnchor {
      if timestamp.timeIntervalSince(anchor) < forkCopyMaximumGap {
        state.forkCopyAnchor = timestamp
        return nil
      }
      state.suppressingForkCopies = false
    }

    let reportedInput = integer(usage["input_tokens"])
    let cachedInput = integer(usage["cached_input_tokens"])
    let cacheCreation = integer(usage["cache_write_input_tokens"])
    let output = integer(usage["output_tokens"])
    let tokens = UsageTokenCounts(
      inputTokens: max(0, reportedInput - cachedInput - cacheCreation),
      cachedInputTokens: cachedInput,
      cacheCreationTokens: cacheCreation,
      outputTokens: output,
      reasoningTokens: min(output, integer(usage["reasoning_output_tokens"])),
      reportedTotalTokens: integer(usage["total_tokens"]).positiveValue
    )
    guard tokens.totalTokens > 0 else { return nil }
    let sessionID = state.sessionID

    return ParsedUsageSample(
      sample: UsageSample(
        id: "codex:\(sessionID):\(lineNumber):\(timestamp.timeIntervalSince1970)",
        provider: .codex,
        timestamp: timestamp,
        sessionID: sessionID,
        accountLabel: "Unknown",
        model: state.model,
        billingProvider: "OpenAI",
        billingRoute: "Codex subscription",
        reasoningLevel: state.reasoningLevel,
        harness: "Codex",
        application: state.application,
        workspace: state.workspace,
        tokens: tokens,
        sourceEventID: "\(sessionID):\(lineNumber):\(timestamp.timeIntervalSince1970)"
      ),
      dedupeKey: nil
    )
  }

  static func parseGrok(
    line: String,
    lineNumber: Int,
    summary: [String: Any]
  ) -> [ParsedUsageSample] {
    guard line.contains("\"usage\"") else { return [] }
    guard let root = object(line),
          let params = dictionary(root["params"]),
          let update = dictionary(params["update"]),
          let usage = dictionary(update["usage"]),
          let timestamp = date(root["timestamp"]) else { return [] }

    let sessionID = string(params["sessionId"] ?? params["session_id"])
      ?? string(dictionary(summary["info"])?["id"])
      ?? ""
    let promptID = string(update["prompt_id"] ?? update["promptId"]) ?? "line-\(lineNumber)"
    let fallbackModel = string(summary["current_model_id"]) ?? "Unknown Grok model"
    let modelUsage = dictionary(usage["modelUsage"] ?? usage["model_usage"])
    let entries: [(String, [String: Any])] = if let modelUsage, !modelUsage.isEmpty {
      modelUsage.compactMap { key, value in dictionary(value).map { (key, $0) } }
    } else {
      [(fallbackModel, usage)]
    }

    return entries.compactMap { model, modelTotals in
      let reportedInput = integer(modelTotals["inputTokens"] ?? modelTotals["input_tokens"])
      let cached = integer(modelTotals["cachedReadTokens"] ?? modelTotals["cached_read_tokens"])
      let created = integer(modelTotals["cacheCreationTokens"] ?? modelTotals["cache_creation_tokens"])
      let output = integer(modelTotals["outputTokens"] ?? modelTotals["output_tokens"])
      let tokens = UsageTokenCounts(
        inputTokens: max(0, reportedInput - cached - created),
        cachedInputTokens: cached,
        cacheCreationTokens: created,
        outputTokens: output,
        reasoningTokens: min(output, integer(modelTotals["reasoningTokens"] ?? modelTotals["reasoning_tokens"])),
        reportedTotalTokens: integer(modelTotals["totalTokens"] ?? modelTotals["total_tokens"]).positiveValue
      )
      guard tokens.totalTokens > 0 else { return nil }
      let costTicks = number(modelTotals["costUsdTicks"] ?? modelTotals["cost_usd_ticks"])
      let cost = costTicks.map { $0 / 1_000_000_000 }
      return ParsedUsageSample(
        sample: UsageSample(
          id: "grok:\(sessionID):\(promptID):\(model):\(timestamp.timeIntervalSince1970)",
          provider: .grok,
          timestamp: timestamp,
          sessionID: sessionID,
          accountLabel: "Unknown",
          model: model,
          billingProvider: "xAI",
          billingRoute: "Grok account",
          reasoningLevel: string(summary["reasoning_effort"]),
          harness: "Grok Build",
          application: "Grok CLI",
          agent: string(summary["agent_name"]),
          workspace: string(dictionary(summary["info"])?["cwd"]).map(lastPathComponent),
          tokens: tokens,
          costUSD: cost,
          sourceEventID: "\(sessionID):\(promptID):\(model):\(timestamp.timeIntervalSince1970)",
          dedupeKey: "\(sessionID):\(promptID):\(model):\(timestamp.timeIntervalSince1970)"
        ),
        dedupeKey: "\(sessionID):\(promptID):\(model):\(timestamp.timeIntervalSince1970)"
      )
    }
  }

  static func parseOpenCode(
    partID: String,
    sessionID: String,
    messageJSON: String,
    partJSON: String,
    workspace: String?
  ) -> UsageSample? {
    guard let message = object(messageJSON), let part = object(partJSON),
          string(part["type"]) == "step-finish",
          let tokenObject = dictionary(part["tokens"]),
          let timestamp = date(dictionary(message["time"])?["completed"]
            ?? dictionary(message["time"])?["created"]) else { return nil }
    let providerIdentifier = string(message["providerID"] ?? message["provider_id"])
      ?? "Unknown"
    let route = billingRoute(providerIdentifier)
    let cache = dictionary(tokenObject["cache"])
    let tokens = UsageTokenCounts(
      inputTokens: integer(tokenObject["input"]),
      cachedInputTokens: integer(cache?["read"]),
      cacheCreationTokens: integer(cache?["write"]),
      outputTokens: integer(tokenObject["output"]),
      reasoningTokens: integer(tokenObject["reasoning"]),
      reportedTotalTokens: integer(tokenObject["total"]).positiveValue
    )
    guard tokens.totalTokens > 0 else { return nil }
    return UsageSample(
      id: "opencode:\(partID)",
      provider: route.provider,
      timestamp: timestamp,
      sessionID: sessionID,
      accountLabel: "Unknown",
      model: string(message["modelID"] ?? message["model_id"]) ?? "Unknown model",
      billingProvider: route.billingProvider,
      billingRoute: route.billingRoute,
      reasoningLevel: string(message["variant"]),
      harness: "OpenCode",
      application: "OpenCode",
      agent: string(message["agent"] ?? message["mode"]),
      workspace: workspace.map(lastPathComponent),
      tokens: tokens,
      costUSD: number(part["cost"]),
      sourceEventID: partID
    )
  }

  static func parseHarness(
    line: String,
    lineNumber: Int,
    harness: String,
    state: inout HarnessUsageScanState
  ) -> ParsedUsageSample? {
    guard let root = object(line), let type = string(root["type"]) else { return nil }

    if type == "session" {
      state.sessionID = string(root["id"] ?? root["session_id"]) ?? state.sessionID
      state.workspace = string(root["cwd"]).map(lastPathComponent) ?? state.workspace
      return nil
    }
    if type == "model_change" {
      state.model = string(root["modelId"] ?? root["model_id"] ?? root["model"])
        ?? state.model
      state.provider = string(root["provider"] ?? root["providerId"] ?? root["provider_id"])
        ?? state.provider
      return nil
    }
    if type == "thinking_level_change" {
      state.reasoningLevel = string(root["thinkingLevel"] ?? root["thinking_level"])
        ?? state.reasoningLevel
      return nil
    }
    guard type == "message", let message = dictionary(root["message"]),
          string(message["role"]) == "assistant",
          let usage = dictionary(message["usage"]),
          let timestamp = date(root["timestamp"] ?? message["timestamp"]) else { return nil }

    let model = string(message["model"] ?? message["modelId"] ?? message["model_id"])
      ?? state.model
    guard !model.isEmpty else { return nil }
    let providerIdentifier = string(
      message["provider"] ?? message["providerId"] ?? message["provider_id"]
    ) ?? state.provider
    let route = billingRoute(providerIdentifier)
    let tokens = UsageTokenCounts(
      inputTokens: integer(usage["input"] ?? usage["input_tokens"]),
      cachedInputTokens: integer(
        usage["cacheRead"] ?? usage["cache_read"] ?? usage["cached_input_tokens"]
      ),
      cacheCreationTokens: integer(
        usage["cacheWrite"] ?? usage["cache_write"] ?? usage["cache_creation_input_tokens"]
      ),
      outputTokens: integer(usage["output"] ?? usage["output_tokens"]),
      reasoningTokens: integer(usage["reasoning"] ?? usage["reasoning_tokens"]),
      reportedTotalTokens: integer(usage["totalTokens"] ?? usage["total_tokens"]).positiveValue
    )
    guard tokens.totalTokens > 0 else { return nil }

    let sessionID = state.sessionID.nilIfEmpty
      ?? string(root["sessionId"] ?? root["session_id"])
      ?? "Unknown"
    let responseID = string(message["responseId"] ?? message["response_id"])
      ?? string(message["id"] ?? root["id"])
    let identity = responseID
      ?? "\(sessionID):\(lineNumber):\(timestamp.timeIntervalSince1970)"
    let cost = dictionary(usage["cost"]).flatMap { number($0["total"]) }
      ?? number(usage["cost"] ?? usage["cost_usd"])
    return ParsedUsageSample(
      sample: UsageSample(
        id: "\(harness.lowercased()):\(identity)",
        provider: route.provider,
        timestamp: timestamp,
        sessionID: sessionID,
        accountLabel: "Unknown",
        model: model,
        billingProvider: route.billingProvider,
        billingRoute: route.billingRoute,
        reasoningLevel: string(message["thinkingLevel"] ?? message["thinking_level"])
          ?? state.reasoningLevel,
        harness: harness,
        application: harness,
        workspace: state.workspace,
        tokens: tokens,
        costUSD: cost,
        sourceEventID: identity,
        dedupeKey: responseID.map { "\(providerIdentifier):\($0)" }
      ),
      dedupeKey: responseID.map { "\(providerIdentifier):\($0)" }
    )
  }

  static func object(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  static func string(_ value: Any?) -> String? {
    (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  static func integer(_ value: Any?) -> Int64 {
    if let number = value as? NSNumber { return max(0, number.int64Value) }
    if let text = value as? String, let number = Int64(text) { return max(0, number) }
    return 0
  }

  static func number(_ value: Any?) -> Double? {
    let result: Double?
    if let number = value as? NSNumber { result = number.doubleValue }
    else if let text = value as? String { result = Double(text) }
    else { result = nil }
    return result.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }

  static func date(_ value: Any?) -> Date? {
    if let number = value as? NSNumber {
      let raw = number.doubleValue
      return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }
    guard let text = value as? String else { return nil }
    if let raw = Double(text) {
      return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }
    if let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
      return parsed
    }
    return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(text)
  }

  private static func isForkedCodexSession(_ payload: [String: Any]) -> Bool {
    if string(payload["forked_from_id"]) != nil { return true }
    guard let source = dictionary(payload["source"]),
          let subagent = dictionary(source["subagent"]),
          let spawn = dictionary(subagent["thread_spawn"]) else { return false }
    return string(spawn["parent_thread_id"]) != nil
  }

  private static func canonicalSignature(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
      return String(describing: object)
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func lastPathComponent(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent.nilIfEmpty ?? path
  }

  private static func billingRoute(
    _ rawProvider: String
  ) -> (provider: ProviderKind, billingProvider: String, billingRoute: String) {
    let provider = rawProvider.lowercased()
    if provider.contains("openai-codex") || provider == "codex" {
      return (.codex, "OpenAI", "Codex subscription")
    }
    if provider.contains("openrouter") {
      return (.openRouter, "OpenRouter", "OpenRouter API")
    }
    if provider == "openai" || provider.contains("openai-api") {
      return (.unknown, "OpenAI", "OpenAI API")
    }
    if provider.contains("anthropic") || provider.contains("claude") {
      return (.claude, "Anthropic", "Claude account")
    }
    if provider.contains("xai") || provider.contains("x-ai") || provider.contains("grok") {
      return (.grok, "xAI", "Grok account")
    }
    if provider.contains("cursor") {
      return (.cursor, "Cursor", "Cursor subscription")
    }
    if provider.contains("opencode") {
      return (.openCodeGo, "OpenCode Go", "OpenCode Go subscription")
    }
    let label = rawProvider.nilIfEmpty ?? "Unknown"
    return (.unknown, label, label)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Int64 {
  var positiveValue: Int64? { self > 0 ? self : nil }
}

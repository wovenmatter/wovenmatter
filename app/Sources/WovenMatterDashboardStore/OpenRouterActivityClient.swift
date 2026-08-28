import Foundation
import WovenMatterCore

struct OpenRouterActivityResult: Sendable {
  let samplesByUTCDate: [String: [UsageSample]]
  let detail: String
}

enum OpenRouterActivityError: LocalizedError {
  case managementKeyRequired
  case invalidResponse
  case responseTooLarge

  var errorDescription: String? {
    switch self {
    case .managementKeyRequired:
      "The stored OpenRouter credential cannot read account activity. A management key is required for the official Activity API."
    case .invalidResponse:
      "OpenRouter returned an invalid Activity API response."
    case .responseTooLarge:
      "OpenRouter returned more activity data than Woven Matter can safely import at once."
    }
  }
}

enum OpenRouterActivityClient {
  static func fetch(apiKey: String) async throws -> OpenRouterActivityResult {
    guard let url = URL(string: "https://openrouter.ai/api/v1/activity") else {
      throw OpenRouterActivityError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await BoundedHTTPResponse.data(
        for: request,
        using: .shared,
        maximumBytes: 16 * 1_024 * 1_024
      )
    } catch let error as BoundedHTTPError {
      if case .responseTooLarge = error {
        throw OpenRouterActivityError.responseTooLarge
      }
      throw error
    }
    guard let http = response as? HTTPURLResponse else {
      throw OpenRouterActivityError.invalidResponse
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw OpenRouterActivityError.managementKeyRequired
    }
    guard (200..<300).contains(http.statusCode) else {
      throw OpenRouterActivityError.invalidResponse
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw OpenRouterActivityError.invalidResponse
    }
    let rows = activityRows(root)
    var result: [String: [UsageSample]] = [:]
    for (index, row) in rows.enumerated() {
      guard let dateString = string(row["date"]),
            let timestamp = utcMidday(dateString) else { continue }
      let rawModel = string(row["model_permaslug"] ?? row["modelPermaslug"])
        ?? string(row["model"])
        ?? "Unknown model"
      let cached = integer(
        row["cache_read_tokens"] ?? row["cacheReadTokens"] ?? row["cached_tokens"]
      )
      let cacheWrite = integer(row["cache_write_tokens"] ?? row["cacheWriteTokens"])
      let reportedInput = integer(row["prompt_tokens"] ?? row["promptTokens"])
      let tokens = UsageTokenCounts(
        inputTokens: max(0, reportedInput - cached - cacheWrite),
        cachedInputTokens: cached,
        cacheCreationTokens: cacheWrite,
        outputTokens: integer(row["completion_tokens"] ?? row["completionTokens"]),
        reasoningTokens: integer(row["reasoning_tokens"] ?? row["reasoningTokens"])
      )
      guard tokens.totalTokens > 0 else { continue }
      let providerName = string(row["provider_name"] ?? row["providerName"])
        ?? "OpenRouter"
      let keyLabel = string(
        row["api_key_name"] ?? row["apiKeyName"] ?? row["key_name"]
      ) ?? "Unknown"
      let endpoint = string(row["endpoint_name"] ?? row["endpointName"])
      let identity = [
        dateString,
        rawModel,
        providerName,
        string(row["api_key_hash"] ?? row["apiKeyHash"]) ?? keyLabel,
        endpoint ?? "",
        String(index),
      ].joined(separator: ":")
      result[dateString, default: []].append(UsageSample(
        id: "openrouter-activity:\(identity)",
        provider: .openRouter,
        timestamp: timestamp,
        sessionID: "openrouter:\(dateString)",
        accountLabel: keyLabel,
        model: rawModel,
        billingProvider: providerName,
        billingRoute: "OpenRouter API",
        harness: "Unknown",
        application: endpoint ?? "OpenRouter API",
        tokens: tokens,
        requestCount: max(1, Int(integer(row["requests"] ?? row["request_count"]))),
        costUSD: number(row["usage"] ?? row["cost"] ?? row["cost_usd"]),
        attributionConfidence: .aggregate,
        granularity: .dailyAggregate,
        sourceEventID: identity
      ))
    }
    return OpenRouterActivityResult(
      samplesByUTCDate: result,
      detail: "Official OpenRouter activity imported at completed UTC-day granularity. Local harness records are reconciled against these totals to avoid double counting."
    )
  }

  private static func activityRows(_ root: [String: Any]) -> [[String: Any]] {
    if let rows = root["data"] as? [[String: Any]] { return rows }
    if let data = root["data"] as? [String: Any] {
      return data["activity"] as? [[String: Any]]
        ?? data["rows"] as? [[String: Any]]
        ?? []
    }
    return root["activity"] as? [[String: Any]] ?? []
  }

  private static func utcMidday(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)?.addingTimeInterval(12 * 60 * 60)
  }

  private static func string(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func integer(_ value: Any?) -> Int64 {
    if let value = value as? NSNumber { return max(0, value.int64Value) }
    if let value = value as? String, let number = Int64(value) { return max(0, number) }
    return 0
  }

  private static func number(_ value: Any?) -> Double? {
    let result: Double?
    if let value = value as? NSNumber { result = value.doubleValue }
    else if let value = value as? String { result = Double(value) }
    else { result = nil }
    return result.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }
}

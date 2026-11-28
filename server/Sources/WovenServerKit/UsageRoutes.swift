import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import WovenLibrary
import WovenProtocol

/// Usage totals and dictation history from the library, provider limits from
/// this machine's own sign-ins, and the list-price table.
func registerUsage(_ router: inout Router, library: Library, secrets: Secrets) {
  let prices = PriceTable()

  router.on(ReadUsage.self) { request, _ in
    guard request.end > request.start else { throw ProtocolError(.badRequest, "The range ends before it starts.") }
    var zone: TimeZone?
    if let identifier = request.timeZone {
      guard let named = TimeZone(identifier: identifier) else { throw ProtocolError(.badRequest, "Unknown time zone \(identifier).") }
      zone = named
    }
    return try await library.usage(from: request.start, to: request.end, periodSeconds: request.periodSeconds, timeZone: zone)
  }
  router.on(ReadUsageLimits.self) { _, _ in
    await ProviderLimits.read(secrets: secrets)
  }
  router.on(ReadModelPrices.self) { request, _ in
    try await prices.read(refresh: request.refresh)
  }
  router.on(SaveDictation.self) { request, _ in
    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.id.isEmpty, !text.isEmpty else { throw ProtocolError(.badRequest, "A dictation needs an id and text.") }
    try await library.saveDictation(id: request.id, text: text, recordedAt: request.recordedAt)
    return Done()
  }
  router.on(ListDictations.self) { request, _ in
    try await library.dictations(limit: min(request.limit, 500), offset: request.offset)
  }
}

private func fetchJSON(_ url: URL, bearer: String? = nil, headers: [String: String] = [:]) async throws -> JSONValue {
  var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
  if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
  for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
  let (data, response) = try await URLSession.shared.data(for: request)
  let status = (response as? HTTPURLResponse)?.statusCode ?? 0
  guard status == 200 else {
    throw RuntimeError.failed(status == 401 || status == 403 ? "The provider refused the sign-in. Sign in again."
                              : "The provider answered HTTP \(status).")
  }
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

// MARK: Limits

/// Live limits of the accounts this machine already holds: its ChatGPT
/// subscription sign-in and the synced OpenRouter key. Nothing is stored and
/// nothing signs in anew.
enum ProviderLimits {
  static func read(secrets: Secrets) async -> [UsageLimit] {
    var limits: [UsageLimit] = []
    if let credential = try? await secrets.subscription("openai-codex"), let access = credential["access"]?.string {
      limits.append(await codex(access: access, accountID: credential["accountId"]?.string))
    }
    if let key = (try? await secrets.apiKeys())?["openrouter"], !key.isEmpty {
      limits.append(await openRouter(key: key))
    }
    return limits
  }

  private static func codex(access: String, accountID: String?) async -> UsageLimit {
    do {
      let object = try await fetchJSON(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, bearer: access,
                                       headers: accountID.map { ["ChatGPT-Account-Id": $0] } ?? [:])
      var windows: [UsageLimit.Window] = []
      func add(_ raw: JSONValue?, label: (Int?) -> String) {
        guard let raw, let used = raw["used_percent"]?.double else { return }
        let minutes = raw["limit_window_seconds"]?.int.map { $0 / 60 }
        let reset = raw["reset_at"]?.double.map { Date(timeIntervalSince1970: $0) }
        windows.append(UsageLimit.Window(label: label(minutes), usedPercent: used, windowMinutes: minutes, resetsAt: reset))
      }
      let rate = object["rate_limit"]
      add(rate?["primary_window"]) { $0 == 7 * 24 * 60 ? "Weekly" : "Five-hour" }
      add(rate?["secondary_window"]) { _ in "Weekly" }
      return UsageLimit(provider: "openai-codex", accountLabel: object["plan_type"]?.string.map { "ChatGPT \($0.capitalized)" } ?? "ChatGPT",
                        windows: windows)
    } catch {
      return UsageLimit(provider: "openai-codex", accountLabel: "ChatGPT", error: "\(error)")
    }
  }

  private static func openRouter(key: String) async -> UsageLimit {
    do {
      let data = try await fetchJSON(URL(string: "https://openrouter.ai/api/v1/key")!, bearer: key)["data"]
      let limit = data?["limit"]?.double
      let spent = data?["usage"]?.double
      var windows: [UsageLimit.Window] = []
      if let limit, limit > 0, let remaining = data?["limit_remaining"]?.double {
        windows.append(UsageLimit.Window(label: "API key cap", usedPercent: min(100, max(0, (limit - remaining) / limit * 100)),
                                         windowMinutes: nil, resetsAt: nil))
      }
      return UsageLimit(provider: "openrouter", accountLabel: data?["label"]?.string ?? "OpenRouter", windows: windows,
                        spent: spent, limit: limit)
    } catch {
      return UsageLimit(provider: "openrouter", accountLabel: "OpenRouter", error: "\(error)")
    }
  }
}

// MARK: Prices

/// LiteLLM's public model price list, downloaded at most once a day.
private final class PriceTable: Sendable {
  private static let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
  private let cached = Mutex<ModelPrices?>(nil)

  func read(refresh: Bool) async throws -> ModelPrices {
    if !refresh, let table = cached.withLock({ $0 }), Date().timeIntervalSince(table.fetchedAt) < 24 * 60 * 60 { return table }
    guard case .object(let models) = try await fetchJSON(Self.url) else { throw RuntimeError.failed("The price list was not JSON.") }
    var prices: [String: ModelPrice] = [:]
    for (name, entry) in models {
      guard let input = entry["input_cost_per_token"]?.double, let output = entry["output_cost_per_token"]?.double else { continue }
      prices[name.lowercased()] = ModelPrice(input: input, output: output,
                                             cacheRead: entry["cache_read_input_token_cost"]?.double ?? input,
                                             cacheWrite: entry["cache_creation_input_token_cost"]?.double ?? input)
    }
    let table = ModelPrices(prices: prices, fetchedAt: Date())
    cached.withLock { $0 = table }
    return table
  }
}

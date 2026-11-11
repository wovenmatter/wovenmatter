import Foundation

/// USD per token for one model at public API list prices.
public struct UsageTokenRate: Codable, Equatable, Sendable {
  public let input: Double
  public let output: Double
  public let cacheRead: Double
  public let cacheWrite: Double

  public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
  }
}

public enum UsageRateTableError: Error, Equatable {
  case invalidDocument
}

/// What usage would cost at API list prices. This is an estimate for comparison,
/// never a bill. Direct spend stays on `UsageSample.directCostUSD`.
public struct UsageCostEstimate: Equatable, Sendable {
  public var input = 0.0
  public var cacheRead = 0.0
  public var cacheWrite = 0.0
  public var output = 0.0
  /// A provider-reported cost for a model without a list price cannot be split by token type.
  public var reported = 0.0
  public var cacheSavings = 0.0
  public var pricedTokens: Int64 = 0
  public var unpricedTokens: Int64 = 0

  public init() {}

  public var total: Double { input + cacheRead + cacheWrite + output + reported }
  public var hasPrice: Bool { pricedTokens > 0 || total > 0 }

  /// The share of tokens left out of the estimate because no price is known.
  public var unpricedShare: Double {
    let tokens = Double(pricedTokens) + Double(unpricedTokens)
    return tokens > 0 ? Double(unpricedTokens) / tokens : 0
  }

  public static func + (lhs: Self, rhs: Self) -> Self {
    var sum = lhs
    sum.input += rhs.input
    sum.cacheRead += rhs.cacheRead
    sum.cacheWrite += rhs.cacheWrite
    sum.output += rhs.output
    sum.reported += rhs.reported
    sum.cacheSavings += rhs.cacheSavings
    let (priced, pricedOverflow) = sum.pricedTokens.addingReportingOverflow(rhs.pricedTokens)
    sum.pricedTokens = pricedOverflow ? .max : priced
    let (unpriced, unpricedOverflow) = sum.unpricedTokens.addingReportingOverflow(rhs.unpricedTokens)
    sum.unpricedTokens = unpricedOverflow ? .max : unpriced
    return sum
  }
}

/// Model prices keyed by lowercased model identifier.
public struct UsageRateTable: Codable, Equatable, Sendable {
  public let rates: [String: UsageTokenRate]

  public init(rates: [String: UsageTokenRate]) {
    self.rates = rates
  }

  // A model maker's own price beats a cloud's or reseller's for a bare model name.
  private static let firstPartyPrefixes: Set<String> = [
    "anthropic", "deepseek", "gemini", "meta", "mistral", "openai", "xai",
  ]

  // Synthetic messages are unbilled, and bare tier names do not identify a generation.
  private static let unpriceableModels: Set<String> = [
    "<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable",
  ]

  /// Reads LiteLLM's public price document. It is untrusted data, so entries
  /// missing finite, non-negative input and output rates are dropped rather than
  /// understating cost, and a document with no usable entries is rejected.
  public static func parseLiteLLM(_ data: Data) throws -> Self {
    guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw UsageRateTableError.invalidDocument
    }
    var rates: [String: UsageTokenRate] = [:]
    for (name, value) in document where name != "sample_spec" {
      guard let entry = value as? [String: Any],
            let input = rate(entry["input_cost_per_token"]),
            let output = rate(entry["output_cost_per_token"]) else { continue }
      let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !key.isEmpty else { continue }
      rates[key] = UsageTokenRate(
        input: input,
        output: output,
        cacheRead: rate(entry["cache_read_input_token_cost"]) ?? input,
        cacheWrite: rate(entry["cache_creation_input_token_cost"]) ?? input
      )
    }
    guard !rates.isEmpty else { throw UsageRateTableError.invalidDocument }
    return Self(rates: addingBareNameAliases(to: rates))
  }

  private static func rate(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
          // A JSON boolean bridges to NSNumber but is not a price.
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let rate = number.doubleValue
    return rate.isFinite && rate >= 0 ? rate : nil
  }

  private static func addingBareNameAliases(
    to rates: [String: UsageTokenRate]
  ) -> [String: UsageTokenRate] {
    var candidates: [String: (rate: UsageTokenRate?, isFirstParty: Bool)] = [:]
    // Sorted so a conflict resolves the same way for any dictionary order.
    for key in rates.keys.sorted() {
      guard let slash = key.lastIndex(of: "/"), let rate = rates[key] else { continue }
      let alias = String(key[key.index(after: slash)...])
      guard !alias.isEmpty, rates[alias] == nil else { continue }
      let prefix = key.split(separator: "/").first.map(String.init) ?? ""
      let isFirstParty = firstPartyPrefixes.contains(prefix)
      guard let held = candidates[alias] else {
        candidates[alias] = (rate, isFirstParty)
        continue
      }
      if isFirstParty, !held.isFirstParty {
        candidates[alias] = (rate, true)
      } else if isFirstParty == held.isFirstParty, held.rate != rate {
        // Sellers at the same rank disagree, so the bare name has no single price.
        candidates[alias] = (nil, held.isFirstParty)
      }
    }
    var result = rates
    for (alias, candidate) in candidates {
      if let rate = candidate.rate { result[alias] = rate }
    }
    return result
  }

  /// Unknown models return nil rather than a guess, so they show as unpriced.
  public func rate(forModel model: String) -> UsageTokenRate? {
    var key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Bracketed context variants such as [1m] are priced at the base tier.
    if let bracket = key.firstIndex(of: "[") { key = String(key[..<bracket]) }
    let bare = key.split(separator: "/").last.map(String.init) ?? key
    guard !bare.isEmpty, !Self.unpriceableModels.contains(bare) else { return nil }
    if let rate = rates[key] ?? rates[bare] { return rate }
    let routed = bare.hasPrefix("cursor-") ? String(bare.dropFirst("cursor-".count)) : bare
    if let rate = rates[routed] { return rate }
    let undated = routed.replacingOccurrences(
      of: #"-\d{8}$"#,
      with: "",
      options: .regularExpression
    )
    return rates[undated] ?? rates[undated.replacingOccurrences(of: ".", with: "-")]
  }

  /// Prefers a cost the provider reported, then list prices. Reasoning tokens are
  /// part of output tokens, so they are not charged a second time.
  public func estimate(_ sample: UsageSample) -> UsageCostEstimate {
    estimate(sample, rate: rate(forModel: sample.model))
  }

  public func estimate(_ samples: some Sequence<UsageSample>) -> UsageCostEstimate {
    var rateByModel: [String: UsageTokenRate?] = [:]
    var total = UsageCostEstimate()
    for sample in samples {
      let rate: UsageTokenRate?
      if let known = rateByModel[sample.model] {
        rate = known
      } else {
        rate = self.rate(forModel: sample.model)
        rateByModel[sample.model] = rate
      }
      total = total + estimate(sample, rate: rate)
    }
    return total
  }

  private func estimate(_ sample: UsageSample, rate: UsageTokenRate?) -> UsageCostEstimate {
    var estimate = UsageCostEstimate()
    let tokens = sample.tokens
    // A cost of zero means no charge on this plan, not that the model has no list price.
    let reported = sample.costUSD.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    guard let rate else {
      if let reported {
        estimate.reported = reported
        estimate.pricedTokens = tokens.totalTokens
      } else {
        estimate.unpricedTokens = tokens.totalTokens
      }
      return estimate
    }
    let input = Double(tokens.inputTokens) * rate.input
    let cacheRead = Double(tokens.cachedInputTokens) * rate.cacheRead
    let cacheWrite = Double(tokens.cacheCreationTokens) * rate.cacheWrite
    let output = Double(tokens.outputTokens) * rate.output
    let list = input + cacheRead + cacheWrite + output
    estimate.pricedTokens = tokens.totalTokens
    if let reported, list <= 0 {
      estimate.reported = reported
      return estimate
    }
    let scale = reported.map { $0 / list } ?? 1
    estimate.input = input * scale
    estimate.cacheRead = cacheRead * scale
    estimate.cacheWrite = cacheWrite * scale
    estimate.output = output * scale
    estimate.cacheSavings = Double(tokens.cachedInputTokens) * max(0, rate.input - rate.cacheRead) * scale
    return estimate
  }
}

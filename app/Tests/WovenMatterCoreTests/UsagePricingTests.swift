import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite("Usage API estimates")
struct UsagePricingTests {
  private static let document = Data(#"""
  {
    "sample_spec": { "input_cost_per_token": 0.0, "output_cost_per_token": 0.0 },
    "gpt-test": {
      "input_cost_per_token": 0.000005,
      "output_cost_per_token": 0.00003,
      "cache_read_input_token_cost": 0.0000005
    },
    "claude-test-1-2": {
      "input_cost_per_token": 0.000005,
      "output_cost_per_token": 0.000025,
      "cache_read_input_token_cost": 0.0000005,
      "cache_creation_input_token_cost": 0.00000625
    },
    "no-output": { "input_cost_per_token": 0.000001 },
    "bad-rate": { "input_cost_per_token": -1, "output_cost_per_token": 1 },
    "bool-rate": { "input_cost_per_token": true, "output_cost_per_token": 1 },
    "bedrock/shared-model": { "input_cost_per_token": 0.000009, "output_cost_per_token": 0.000009 },
    "openai/shared-model": { "input_cost_per_token": 0.000002, "output_cost_per_token": 0.000002 },
    "azure/split-model": { "input_cost_per_token": 0.000001, "output_cost_per_token": 0.000001 },
    "vertex/split-model": { "input_cost_per_token": 0.000003, "output_cost_per_token": 0.000003 }
  }
  """#.utf8)

  @Test("parsing keeps only complete prices and fills missing cache rates")
  func parsing() throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    #expect(table.rates["sample_spec"] == nil)
    #expect(table.rates["no-output"] == nil)
    #expect(table.rates["bad-rate"] == nil)
    #expect(table.rates["bool-rate"] == nil)
    // A missing cache-write rate falls back to the input rate.
    #expect(table.rates["gpt-test"]?.cacheWrite == 0.000005)
    #expect(table.rates["gpt-test"]?.cacheRead == 0.0000005)
  }

  @Test("a document with no usable prices is rejected", arguments: ["{}", "[]", "not json", #"{"a":{}}"#])
  func rejection(document: String) {
    #expect(throws: UsageRateTableError.invalidDocument) {
      try UsageRateTable.parseLiteLLM(Data(document.utf8))
    }
  }

  @Test("bare names prefer the model maker and skip disagreeing sellers")
  func aliases() throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    #expect(table.rate(forModel: "shared-model")?.input == 0.000002)
    #expect(table.rate(forModel: "split-model") == nil)
  }

  @Test(
    "transcript model names resolve to a price",
    arguments: [
      "gpt-test", "GPT-Test", "openai/gpt-test", "cursor-gpt-test", "gpt-test[1m]",
      "claude-test-1-2-20260101", "anthropic/claude-test-1.2",
    ]
  )
  func lookup(model: String) throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    #expect(table.rate(forModel: model) != nil)
  }

  @Test("unknown and ambiguous models stay unpriced", arguments: ["opus", "synthetic", "<synthetic>", "no-such-model", ""])
  func unpriced(model: String) throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    #expect(table.rate(forModel: model) == nil)
  }

  @Test("list prices apply per token type without charging reasoning twice")
  func listPrice() throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    let estimate = table.estimate(sample(
      model: "claude-test-1-2",
      tokens: UsageTokenCounts(
        inputTokens: 1_000_000,
        cachedInputTokens: 1_000_000,
        cacheCreationTokens: 1_000_000,
        outputTokens: 1_000_000,
        reasoningTokens: 500_000
      )
    ))
    #expect(abs(estimate.input - 5) < 0.000_001)
    #expect(abs(estimate.cacheRead - 0.5) < 0.000_001)
    #expect(abs(estimate.cacheWrite - 6.25) < 0.000_001)
    #expect(abs(estimate.output - 25) < 0.000_001)
    #expect(abs(estimate.total - 36.75) < 0.000_001)
    #expect(abs(estimate.cacheSavings - 4.5) < 0.000_001)
    #expect(estimate.unpricedTokens == 0)
  }

  @Test("a reported cost beats list prices and keeps the token-type split")
  func reportedCost() throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    let estimate = table.estimate(sample(
      model: "gpt-test",
      tokens: UsageTokenCounts(inputTokens: 1_000_000, outputTokens: 1_000_000),
      costUSD: 70
    ))
    #expect(abs(estimate.total - 70) < 0.000_001)
    #expect(abs(estimate.output / estimate.input - 6) < 0.000_001)
  }

  @Test("a reported cost of zero means no charge, not a zero list price")
  func zeroReportedCost() throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    let tokens = UsageTokenCounts(inputTokens: 1_000_000)
    let listed = table.estimate(sample(model: "gpt-test", tokens: tokens))
    #expect(listed.total > 0)
    #expect(table.estimate(sample(model: "gpt-test", tokens: tokens, costUSD: 0)).total == listed.total)
    #expect(table.estimate(sample(model: "no-such-model", tokens: tokens, costUSD: 0)).unpricedTokens == tokens.totalTokens)
  }

  @Test("a reported cost without a list price stays unsplit")
  func reportedOnly() throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    let estimate = table.estimate(sample(
      model: "no-such-model",
      tokens: UsageTokenCounts(inputTokens: 10),
      costUSD: 1.5
    ))
    #expect(estimate.reported == 1.5)
    #expect(estimate.total == 1.5)
    #expect(estimate.unpricedTokens == 0)
  }

  @Test("unpriced usage is counted, never treated as free")
  func unpricedUsage() throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    let estimate = table.estimate([
      sample(model: "no-such-model", tokens: UsageTokenCounts(inputTokens: 300)),
      sample(model: "gpt-test", tokens: UsageTokenCounts(inputTokens: 100)),
    ])
    #expect(estimate.unpricedTokens == 300)
    #expect(estimate.pricedTokens == 100)
    #expect(estimate.unpricedShare == 0.75)
    #expect(table.estimate(sample(model: "no-such-model", tokens: UsageTokenCounts(inputTokens: 1))).hasPrice == false)
  }

  @Test("the estimate leaves direct spend reporting unchanged")
  func directSpendUnchanged() throws {
    let table = try UsageRateTable.parseLiteLLM(Self.document)
    let subscription = sample(
      model: "gpt-test",
      tokens: UsageTokenCounts(inputTokens: 100),
      provider: .codex,
      costUSD: 9
    )
    #expect(subscription.directCostUSD == nil)
    #expect(table.estimate(subscription).total == 9)
    #expect(UsageAnalyticsSummary(samples: [subscription]).costUSD == nil)
  }

  @Test("saved prices are reused while fresh and survive a failed download")
  func priceService() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "usage-prices-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appending(path: "nested/prices.json")
    let downloads = DownloadCounter()
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))

    let service = UsagePriceService(
      cacheURL: cacheURL,
      download: { try await downloads.next() },
      now: { clock.now }
    )
    let first = try await service.prices()
    #expect(first.table.rate(forModel: "gpt-test") != nil)
    _ = try await service.prices()
    #expect(await downloads.count == 1)

    // A new launch reads the saved file instead of downloading.
    let restarted = UsagePriceService(
      cacheURL: cacheURL,
      download: { try await downloads.next() },
      now: { clock.now }
    )
    #expect(try await restarted.prices() == first)
    #expect(await downloads.count == 1)

    // Once stale, a failed download keeps the older prices.
    clock.now = clock.now.addingTimeInterval(25 * 60 * 60)
    await downloads.setFailing()
    #expect(try await restarted.prices() == first)
    #expect(await downloads.count == 2)

    // With nothing saved, the failure reaches the caller.
    try FileManager.default.removeItem(at: cacheURL)
    let empty = UsagePriceService(
      cacheURL: cacheURL,
      download: { try await downloads.next() },
      now: { clock.now }
    )
    await #expect(throws: URLError.self) { try await empty.prices() }
  }

  private func sample(
    model: String,
    tokens: UsageTokenCounts,
    provider: ProviderKind = .claude,
    costUSD: Double? = nil
  ) -> UsageSample {
    UsageSample(
      id: UUID().uuidString,
      provider: provider,
      timestamp: Date(timeIntervalSince1970: 1_800_000_000),
      sessionID: "session",
      accountLabel: "Account",
      model: model,
      harness: "Test",
      application: "Test",
      tokens: tokens,
      costUSD: costUSD
    )
  }

  private actor DownloadCounter {
    private(set) var count = 0
    private var isFailing = false

    func setFailing() { isFailing = true }

    func next() throws -> Data {
      count += 1
      if isFailing { throw URLError(.notConnectedToInternet) }
      return UsagePricingTests.document
    }
  }

  private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
  }
}

import Foundation
import Testing
import WovenMatterCore

@Suite("Usage cost reporting")
struct UsageCostTests {
  @Test("only direct OpenRouter and OpenCode Go spend is exposed")
  func directSpendOnly() {
    let samples = [
      sample(provider: .codex, costUSD: 11),
      sample(provider: .claude, costUSD: 12),
      sample(provider: .grok, costUSD: 13),
      sample(provider: .cursor, costUSD: 14),
      sample(provider: .unknown, costUSD: 15),
      sample(provider: .openRouter, costUSD: 2.50),
      sample(provider: .openCodeGo, costUSD: 3.25),
    ]

    #expect(samples.prefix(5).allSatisfy { $0.directCostUSD == nil })
    #expect(samples[5].directCostUSD == 2.50)
    #expect(samples[6].directCostUSD == 3.25)
    #expect(UsageAnalyticsSummary(samples: samples).costUSD == 5.75)
  }

  private func sample(provider: ProviderKind, costUSD: Double) -> UsageSample {
    UsageSample(
      id: provider.rawValue,
      provider: provider,
      timestamp: Date(timeIntervalSince1970: 1_800_000_000),
      sessionID: provider.rawValue,
      accountLabel: provider.displayName,
      model: "test-model",
      harness: "Test",
      application: "Test",
      tokens: UsageTokenCounts(inputTokens: 1),
      costUSD: costUSD
    )
  }
}

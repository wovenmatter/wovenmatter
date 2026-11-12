import Foundation
import Testing
import WovenMatterCore

@Suite("Usage display compaction")
struct UsageAnalyticsCompactionTests {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }()
  // Noon in New York, so a few hours either way stays on the same day.
  private static let noon = Date(timeIntervalSince1970: 1_793_894_400)

  @Test("calls in one session, model and day combine without changing any total")
  func combinesCalls() {
    let samples = (0..<500).map { index in
      sample(
        id: "\(index)",
        secondsAfterNoon: index,
        tokens: UsageTokenCounts(
          inputTokens: 10,
          cachedInputTokens: 20,
          cacheCreationTokens: 3,
          outputTokens: 5,
          reasoningTokens: 2
        ),
        requestCount: 2
      )
    }
    let compact = compacted(samples)
    #expect(compact.samples.count == 1)
    let before = UsageAnalyticsSummary(samples: samples)
    let after = UsageAnalyticsSummary(samples: compact.samples)
    #expect(after.tokens.totalTokens == before.tokens.totalTokens)
    #expect(after.tokens.cachedInputTokens == before.tokens.cachedInputTokens)
    #expect(after.tokens.reasoningTokens == before.tokens.reasoningTokens)
    #expect(after.requests == 1_000)
    #expect(after.sessions == before.sessions)
    #expect(compact.samples.first?.timestamp == samples.last?.timestamp)
  }

  @Test(
    "anything the page filters or attributes by stays separate",
    arguments: [
      sample(id: "b", session: "other"),
      sample(id: "b", provider: .claude),
      sample(id: "b", model: "other-model"),
      sample(id: "b", route: "other-route"),
      sample(id: "b", account: "other-account"),
      sample(id: "b", reasoning: "High"),
      sample(id: "b", harness: "other-harness"),
      sample(id: "b", application: "other-app"),
      sample(id: "b", agent: "other-agent"),
      sample(id: "b", workspace: "other-workspace"),
      sample(id: "b", source: "other-source"),
    ]
  )
  func keepsDimensionsApart(other: UsageSample) {
    #expect(compacted([sample(id: "a"), other]).samples.count == 2)
  }

  @Test("each period the graph draws stays separate")
  func keepsPeriodsApart() {
    let samples = [
      sample(id: "a", secondsAfterNoon: 0),
      sample(id: "b", secondsAfterNoon: 60),
      sample(id: "c", secondsAfterNoon: 2 * 3_600),
      sample(id: "d", secondsAfterNoon: 24 * 3_600),
    ]
    #expect(compacted(samples, range: .last30Days).samples.count == 2)
    #expect(compacted(samples, range: .last24Hours).samples.count == 3)
  }

  @Test("reported costs add up and never spread to calls without one")
  func keepsCostsSeparate() {
    let compact = compacted([
      sample(id: "a", costUSD: 1.5, provider: .openRouter),
      sample(id: "b", costUSD: 2, provider: .openRouter),
      sample(id: "c", provider: .openRouter),
    ])
    #expect(compact.samples.count == 2)
    #expect(UsageAnalyticsSummary(samples: compact.samples).costUSD == 3.5)
    #expect(compact.samples.contains { $0.costUSD == nil })
  }

  @Test("a lone call, the range and the sources pass through untouched")
  func preservesTheRest() {
    let lone = sample(id: "a")
    let source = UsageSourceCoverage(
      provider: .codex,
      status: .available,
      location: "here",
      discoveredSessions: 1,
      attributedSamples: 1,
      detail: "detail"
    )
    let snapshot = UsageAnalyticsSnapshot(
      range: .last90Days,
      generatedAt: Self.noon,
      samples: [lone],
      sources: [source]
    )
    #expect(snapshot.compactedForDisplay(calendar: Self.calendar) == snapshot)
  }

  private func compacted(
    _ samples: [UsageSample],
    range: UsageTimeRange = .last30Days
  ) -> UsageAnalyticsSnapshot {
    UsageAnalyticsSnapshot(range: range, generatedAt: Self.noon, samples: samples, sources: [])
      .compactedForDisplay(calendar: Self.calendar)
  }

  private func sample(
    id: String,
    secondsAfterNoon: Int = 0,
    tokens: UsageTokenCounts = UsageTokenCounts(inputTokens: 1),
    requestCount: Int = 1,
    costUSD: Double? = nil,
    provider: ProviderKind = .codex
  ) -> UsageSample {
    Self.sample(
      id: id,
      secondsAfterNoon: secondsAfterNoon,
      tokens: tokens,
      requestCount: requestCount,
      costUSD: costUSD,
      provider: provider
    )
  }

  private static func sample(
    id: String,
    session: String = "session",
    secondsAfterNoon: Int = 0,
    tokens: UsageTokenCounts = UsageTokenCounts(inputTokens: 1),
    requestCount: Int = 1,
    costUSD: Double? = nil,
    provider: ProviderKind = .codex,
    model: String = "model",
    route: String = "route",
    account: String = "account",
    reasoning: String? = nil,
    harness: String = "harness",
    application: String = "app",
    agent: String? = nil,
    workspace: String? = nil,
    source: String = "source"
  ) -> UsageSample {
    UsageSample(
      id: id,
      provider: provider,
      timestamp: noon.addingTimeInterval(TimeInterval(secondsAfterNoon)),
      sessionID: session,
      accountLabel: account,
      model: model,
      billingRoute: route,
      reasoningLevel: reasoning,
      harness: harness,
      application: application,
      agent: agent,
      workspace: workspace,
      tokens: tokens,
      requestCount: requestCount,
      costUSD: costUSD,
      sourceID: source
    )
  }
}

import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

@Suite("Usage page presentation")
struct UsagePresentationTests {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
  }()
  // 2026-11-05 15:30 in New York.
  private static let now = Date(timeIntervalSince1970: 1_793_910_600)

  @Test("every period appears, including ones with no usage")
  func zeroFilledDays() {
    let data = UsageChartData.build(
      samples: [sample(.codex, daysAgo: 0, tokens: 10), sample(.codex, daysAgo: 6, tokens: 20)],
      range: .last7Days,
      now: Self.now,
      calendar: Self.calendar,
      value: tokenTotal
    )
    #expect(data.columns.count == 8)
    #expect(data.columns.first?.total == 0)
    #expect(data.columns.last?.values[.codex] == 10)
    #expect(data.columns.map(\.total).reduce(0, +) == 30)
    #expect(!data.usesHourlyBuckets)
  }

  @Test("short ranges use hours and yesterday stops before today")
  func hourlyBuckets() {
    let data = UsageChartData.build(
      samples: [],
      range: .yesterday,
      now: Self.now,
      calendar: Self.calendar,
      value: tokenTotal
    )
    #expect(data.usesHourlyBuckets)
    #expect(data.columns.count == 24)
    #expect(data.isEmpty)
  }

  @Test("all time starts at the first record and runs to today")
  func allTime() {
    let data = UsageChartData.build(
      samples: [sample(.codex, daysAgo: 200, tokens: 7), sample(.codex, daysAgo: 0, tokens: 3)],
      range: .allTime,
      now: Self.now,
      calendar: Self.calendar,
      value: tokenTotal
    )
    #expect(data.columns.count == 201)
    #expect(data.columns.first?.values[.codex] == 7)
    #expect(data.columns.last?.values[.codex] == 3)
    #expect(!data.usesHourlyBuckets)
    let empty = UsageChartData.build(
      samples: [],
      range: .allTime,
      now: Self.now,
      calendar: Self.calendar,
      value: tokenTotal
    )
    #expect(empty.columns.count == 1)
  }

  @Test("a stray timestamp stays in the total without stretching the axis")
  func strayTimestamp() {
    let data = UsageChartData.build(
      samples: [sample(.claude, daysAgo: 400, tokens: 5)],
      range: .last7Days,
      now: Self.now,
      calendar: Self.calendar,
      value: tokenTotal
    )
    #expect(data.columns.count == 8)
    #expect(data.columns.first?.values[.claude] == 5)
  }

  @Test("provider order is fixed, so filtering never repaints the others")
  func providerOrder() {
    let data = UsageChartData.build(
      samples: [sample(.openRouter, daysAgo: 0, tokens: 500), sample(.codex, daysAgo: 0, tokens: 1)],
      range: .last7Days,
      now: Self.now,
      calendar: Self.calendar,
      value: tokenTotal
    )
    #expect(data.providers == [.codex, .openRouter])
    #expect(data.providersByTotal == [.openRouter, .codex])
  }

  @Test("stacked bars scale to the day's total and lines to the tallest series")
  func peaks() {
    let data = UsageChartData.build(
      samples: [sample(.codex, daysAgo: 0, tokens: 30), sample(.claude, daysAgo: 0, tokens: 40)],
      range: .last7Days,
      now: Self.now,
      calendar: Self.calendar,
      value: tokenTotal
    )
    #expect(data.peak(for: .lines) == 40)
    #expect(data.peak(for: .bars) == 70)
  }

  @Test("axis scales use round steps above the peak")
  func niceScale() {
    let scale = UsageChartScale.nice(peak: 2_140_000)
    #expect(scale.maximum == 3_000_000)
    #expect(scale.ticks == [0, 1_000_000, 2_000_000, 3_000_000])
    #expect(UsageChartScale.nice(peak: 0).ticks == [0])
    #expect(UsageChartScale.nice(peak: 0).maximum > 0)
  }

  @Test("a bad old timestamp keeps its total without stretching All time across decades")
  func allTimeIgnoresImplausibleStart() {
    let stray = sample(.codex, daysAgo: Int(Self.now.timeIntervalSince1970 / 86_400), tokens: 5)
    let data = UsageChartData.build(
      samples: [stray, sample(.codex, daysAgo: 0, tokens: 7)],
      range: .allTime,
      now: Self.now,
      calendar: Self.calendar
    ) { group in Double(group.reduce(.zero) { $0 + $1.tokens }.totalTokens) }
    #expect(data.columns.first.map { $0.start.timeIntervalSince1970 > 1_500_000_000 } == true)
    #expect(data.columns.reduce(0) { $0 + $1.total } == 12)
  }

  @Test("filters narrow samples, and hidden providers can still report their totals")
  func filters() {
    let codex = sample(.codex, daysAgo: 0, tokens: 1)
    let claude = sample(.claude, daysAgo: 0, tokens: 1)
    var filters = UsageAnalyticsFilters()
    #expect(!filters.isActive)
    filters.hiddenProviders = [.claude]
    #expect(filters.isActive)
    #expect(filters.matches(codex))
    #expect(!filters.matches(claude))
    #expect(filters.matches(claude, ignoringProviders: true))
    filters.clear()
    filters.search = "  CLAUDE  "
    #expect(filters.matches(claude))
    #expect(!filters.matches(codex))
    filters.clear()
    // Billing has no dropdown, so search is how to find a route.
    let routed = UsageSample(
      id: "routed",
      provider: .codex,
      timestamp: Self.now,
      sessionID: "session",
      accountLabel: "Account",
      model: "model",
      billingRoute: "API key",
      harness: "Codex",
      application: "Test",
      tokens: UsageTokenCounts(inputTokens: 1)
    )
    filters.search = "api key"
    #expect(filters.matches(routed))
    #expect(!filters.matches(codex))
    filters.clear()
    filters.reasoning = UsageAnalyticsFilters.reasoningNotReported
    #expect(filters.matches(codex))
  }

  @Test("a hidden device drops out of the report but can still show its own total")
  func deviceFilter() {
    let local = sample(.codex, daysAgo: 0, tokens: 1)
    let remote = UsageSample(
      id: "remote", provider: .codex, timestamp: Self.now, sessionID: "s", accountLabel: "A", model: "m",
      harness: "h", application: "a", tokens: UsageTokenCounts(inputTokens: 1),
      sourceID: UsageDeviceSource.sourceID(deviceID: "host-1")
    )
    var filters = UsageAnalyticsFilters()
    filters.hiddenDevices = ["host-1"]
    #expect(filters.isActive)
    #expect(filters.matches(local))
    #expect(!filters.matches(remote))
    #expect(filters.matches(remote, ignoringDevices: true))
    filters.clear()
    #expect(filters.hiddenDevices.isEmpty)
    let rows = UsageSessionRow.rows(from: [remote, local], deviceNames: ["host-1": "Build host"])
    #expect(rows.contains { $0.attribution.hasPrefix("Build host") })
    #expect(rows.filter { $0.deviceName == nil }.count == 1)
  }

  @Test("the pace mark follows the share of the window still to come")
  func pace() {
    func window(minutes: Int?, resetsIn: TimeInterval?) -> ProviderQuotaWindow {
      ProviderQuotaWindow(
        id: "w",
        label: "Window",
        usedPercent: 10,
        usageKnown: true,
        windowMinutes: minutes,
        resetsAt: resetsIn.map { Self.now.addingTimeInterval($0) }
      )
    }
    #expect(UsageLimitPace.remainingFraction(of: window(minutes: 60, resetsIn: 900), now: Self.now) == 0.25)
    #expect(UsageLimitPace.remainingFraction(of: window(minutes: nil, resetsIn: 900), now: Self.now) == nil)
    #expect(UsageLimitPace.remainingFraction(of: window(minutes: 60, resetsIn: nil), now: Self.now) == nil)
    // Outside the window there is no honest pace to show.
    #expect(UsageLimitPace.remainingFraction(of: window(minutes: 60, resetsIn: -1), now: Self.now) == nil)
    #expect(UsageLimitPace.remainingFraction(of: window(minutes: 60, resetsIn: 7_200), now: Self.now) == nil)
  }

  @Test("reset text is short and exact when close")
  func resetText() {
    func text(_ seconds: TimeInterval) -> String {
      UsageFormat.resetText(Self.now.addingTimeInterval(seconds), now: Self.now)
    }
    #expect(text(-5) == "Resets soon")
    #expect(text(14 * 60) == "Resets in 14m")
    #expect(text(2 * 3_600 + 14 * 60) == "Resets in 2h 14m")
    #expect(text(3 * 3_600) == "Resets in 3h")
  }

  @Test("each model takes the color of the provider carrying most of its tokens")
  func modelProvider() {
    let rollup = UsageModelRollup(
      family: "Shared",
      samples: [sample(.openRouter, daysAgo: 0, tokens: 90), sample(.openCodeGo, daysAgo: 0, tokens: 10)]
    )
    #expect(rollup.provider == .openRouter)
  }

  private func tokenTotal(_ group: [UsageSample]) -> Double {
    Double(group.reduce(.zero) { $0 + $1.tokens }.totalTokens)
  }

  private func sample(_ provider: ProviderKind, daysAgo: Int, tokens: Int64) -> UsageSample {
    UsageSample(
      id: UUID().uuidString,
      provider: provider,
      timestamp: Self.now.addingTimeInterval(-Double(daysAgo) * 86_400),
      sessionID: "session",
      accountLabel: "Account",
      model: "model",
      harness: provider.displayName,
      application: "Test",
      tokens: UsageTokenCounts(inputTokens: tokens)
    )
  }
}

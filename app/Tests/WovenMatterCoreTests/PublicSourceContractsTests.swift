import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite("Public source contracts", .serialized)
struct PublicSourceContractsTests {

  @Test("enabling one usage account does not probe the others")
  func scopedUsageAccountEnablement() async {
    let accounts = await ProviderLimitCollector.collect(
      enabledProviders: [.openCodeGo],
      sharedCredentials: [:],
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(accounts.map(\.provider) == [.openCodeGo])
  }


  @Test("account preferences filter limits but never device analytics")
  func accountPreferencesOnlyFilterLimits() async throws {
    let directory = try TemporaryDirectory(prefix: "wovenmatter-usage-filtering")
    defer { directory.remove() }
    let databaseURL = directory.url.appending(path: "workspace.sqlite")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try UsageStore(databaseURL: databaseURL)
    try store.replace(
      sourceID: "fixture:providers",
      sourceName: "Fixture",
      location: "Fixture",
      provider: .unknown,
      harness: "Fixture",
      fingerprint: "fixture",
      samples: [
        usageSample(provider: .codex, timestamp: now.addingTimeInterval(-60)),
        usageSample(provider: .claude, timestamp: now.addingTimeInterval(-30)),
      ],
      importedAt: now
    )

    let sourceAccess = UsageSourceAccessRecorder()
    let credentials = RecordingUsageCredentialStore()
    let service = LocalUsageService(
      homeDirectory: directory.url,
      fileManager: RecordingUsageFileManager(recorder: sourceAccess),
      credentialStore: credentials,
      usageDatabaseURL: databaseURL,
      sharedConnectionRevision: { 0 }
    )
    let snapshot = try await service.snapshot(
      range: .last30Days,
      refreshLimits: false,
      refreshReason: .rangeChanged,
      enabledProviders: [.claude],
      allowCredentialAccess: true,
      now: now
    )

    #expect(snapshot.analytics.samples.map(\.provider) == [.codex, .claude])
    #expect(snapshot.analytics.sources.contains { $0.provider == .codex })
    #expect(snapshot.limits.map(\.provider) == [.claude])
    #expect(credentials.readCount == 0)
    for suffix in ["/.codex/sessions", "/.claude/projects", "/.grok/sessions", "/.local/share/opencode/opencode.db"] {
      #expect(sourceAccess.providerSourceChecks.contains { $0.hasSuffix(suffix) })
    }
  }


  @Test("usage providers default disabled and persist exact choices")
  func usageProviderPreferences() throws {
    let suiteName = "wovenmatter-usage-provider-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = UsageProviderPreferences(defaults: defaults)

    #expect(preferences.enabledProviders.isEmpty)

    preferences.save([.codex, .openCodeGo])
    #expect(
      UsageProviderPreferences(defaults: defaults).enabledProviders
        == [.codex, .openCodeGo]
    )

    preferences.save([])
    #expect(UsageProviderPreferences(defaults: defaults).enabledProviders.isEmpty)
  }

  @Test("provider response fixtures preserve distinct quota semantics")
  func providerResponseFixtures() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fiveHourCodex = ProviderLimitCollector.mapCodexUsage([
      "plan_type": "plus",
      "rate_limit": [
        "primary_window": ["used_percent": 25, "reset_at": 1_800_001_000, "limit_window_seconds": 18_000],
        "secondary_window": ["used_percent": 40, "reset_at": 1_800_002_000, "limit_window_seconds": 604_800],
      ],
      "additional_rate_limits": [[
        "limit_name": "Spark",
        "rate_limit": [
          "primary_window": ["used_percent": 9, "reset_at": 1_800_003_000],
          "secondary_window": ["used_percent": 11, "reset_at": 1_800_004_000],
        ],
      ]],
      "credits": ["balance": 12.5],
    ], now: now)
    #expect(fiveHourCodex.quotaWindows.map(\.label) == [
      "Five-hour", "Weekly", "Spark", "Spark weekly",
    ])
    #expect(fiveHourCodex.quotaWindows.map(\.id) == [
      "five-hour", "weekly", "additional-0-primary", "additional-0-secondary",
    ])
    #expect(Set(fiveHourCodex.quotaWindows.map(\.id)).count == fiveHourCodex.quotaWindows.count)
    #expect(fiveHourCodex.balance?.amountMicros == 12_500_000)

    let weeklyCodex = ProviderLimitCollector.mapCodexUsage([
      "plan_type": "pro",
      "rateLimit": [
        "primaryWindow": [
          "usedPercent": 63,
          "resetAt": 1_800_345_600,
          "windowDurationMins": 10_080,
        ],
      ],
    ], now: now)
    #expect(weeklyCodex.quotaWindows.map(\.label) == ["Weekly"])
    #expect(weeklyCodex.quotaWindows.map(\.id) == ["five-hour"])
    #expect(weeklyCodex.quotaWindows.first?.usedPercent == 63)
    #expect(weeklyCodex.quotaWindows.first?.windowMinutes == 10_080)
    let claude = ProviderLimitCollector.mapClaudeUsage([
      "five_hour": ["utilization": 12.5, "resets_at": "2027-01-15T08:00:00Z"],
      "seven_day": ["utilization": 33.0],
      "seven_day_sonnet": ["utilization": 44.0],
      "seven_day_opus": ["utilization": 55.0],
      "cowork": ["utilization": 5.0],
      "limits": [[
        "percent": 18.0,
        "is_active": true,
        "scope": ["model": ["display_name": "Fable"]],
      ]],
      "extra_usage": [
        "is_enabled": true,
        "used_credits": 500,
        "monthly_limit": 2_000,
        "currency": "USD",
      ],
    ], now: now)
    #expect(claude.quotaWindows.map(\.label) == [
      "Five-hour", "Weekly", "Sonnet weekly", "Opus weekly", "Routines weekly", "Fable weekly",
    ])
    #expect(claude.providerBudget?.usedMicros == 5_000_000)

    let grok = ProviderLimitCollector.mapGrokProxy([
      "config": [
        "creditUsagePercent": 35,
        "onDemandUsed": 7.0,
        "onDemandCap": 20.0,
        "subscriptionTier": "SuperGrok",
        "currentPeriod": ["end": "2027-01-15T08:00:00Z"],
      ],
    ], accountLabel: "fixture@example.com", now: now)
    #expect(grok.quotaWindows.first?.usedPercent == 35)
    #expect(grok.quotaWindows.first?.resetsAt != nil)
    #expect(grok.details.first?.value == "SuperGrok")

    let openCode = ProviderLimitCollector.mapOpenCodeGoUsage([
      "usage": [
        "rolling": ["usagePercent": 10, "resetInSec": 300],
        "weekly": ["usagePercent": 20, "resetInSec": 600],
        "monthly": ["usagePercent": 30, "resetInSec": 900],
      ],
      "balance": 4.25,
    ], now: now)
    #expect(openCode.quotaWindows.map(\.label) == ["Rolling five-hour", "Weekly", "Monthly"])
    #expect(openCode.balance?.amountMicros == 4_250_000)

    let openRouter = ProviderLimitCollector.mapOpenRouter(
      keyObject: ["data": [
        "limit": 100.0,
        "limit_remaining": 70.0,
        "usage": 99.0,
        "usage_daily": 1.0,
        "usage_weekly": 4.0,
        "usage_monthly": 8.0,
        "limit_reset": "monthly",
        "rate_limit": ["requests": 200, "interval": "10s"],
      ]],
      creditsObject: ["data": ["total_credits": 50.0, "total_usage": 20.0]],
      now: now
    )
    #expect(openRouter.providerBudget?.usedMicros == 30_000_000)
    #expect(openRouter.balance?.amountMicros == 30_000_000)
    #expect(openRouter.details.contains { $0.label == "Rate limit" })
  }


}

private func usageSample(
  provider: ProviderKind,
  timestamp: Date
) -> UsageSample {
  UsageSample(
    id: provider.rawValue,
    provider: provider,
    timestamp: timestamp,
    sessionID: provider.rawValue,
    accountLabel: provider.displayName,
    model: "fixture-model",
    harness: "Fixture",
    application: "Fixture",
    tokens: UsageTokenCounts(inputTokens: 1),
    sourceID: "fixture:providers",
    sourceEventID: provider.rawValue
  )
}

private final class RecordingUsageCredentialStore:
  UsageCredentialStoring, @unchecked Sendable
{
  private let lock = NSLock()
  private var reads = 0

  var readCount: Int { lock.withLock { reads } }

  func hasOpenRouterAPIKey() throws -> Bool {
    lock.withLock { reads += 1 }
    return true
  }

  func authorizeOpenRouterAPIKey() throws -> String? {
    lock.withLock { reads += 1 }
    return "fixture"
  }

  func saveOpenRouterAPIKey(_: String) throws {}
  func deleteOpenRouterAPIKey() throws {}
}

private final class UsageSourceAccessRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var checkedPaths: [String] = []

  var providerSourceChecks: [String] {
    let providerFragments = [
      "/.codex/", "/.claude/", "/.grok/", "/.cursor/",
      "/.local/share/opencode/", "/.pi/",
    ]
    return lock.withLock {
      checkedPaths.filter { path in
        providerFragments.contains { path.contains($0) }
      }
    }
  }

  func record(_ path: String) {
    lock.withLock { checkedPaths.append(path) }
  }
}

private final class RecordingUsageFileManager: FileManager {
  private let recorder: UsageSourceAccessRecorder

  init(recorder: UsageSourceAccessRecorder) {
    self.recorder = recorder
    super.init()
  }

  override func fileExists(atPath path: String) -> Bool {
    recorder.record(path)
    return super.fileExists(atPath: path)
  }
}

private struct TemporaryDirectory {
  let url: URL

  init(prefix: String) throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: url) }
}

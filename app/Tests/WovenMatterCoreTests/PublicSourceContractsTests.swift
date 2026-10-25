import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Public source contracts", .serialized)
struct PublicSourceContractsTests {

  @Test("enabling one usage account does not probe the others")
  func scopedUsageAccountEnablement() async throws {
    let directory = try TemporaryDirectory(prefix: "wovenmatter-usage-consent")
    defer { directory.remove() }
    let accounts = await ProviderLimitCollector.collect(
      homeDirectory: directory.url,
      openRouterAPIKey: nil,
      enabledProviders: [.openCodeGo],
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(accounts.map(\.provider) == [.openCodeGo])
  }


  @Test("Codex workspace catalog exposes distinct metadata without credentials")
  func codexWorkspaceCatalog() throws {
    try #require(ProcessInfo.processInfo.environment["CODEX_HOME"] == nil,
      "Run tests with CODEX_HOME unset so fixtures cannot read inherited credentials.")
    let directory = try TemporaryDirectory(prefix: "wovenmatter-codex-workspaces")
    defer { directory.remove() }
    let support = directory.url.appending(
      path: "Library/Application Support/CodexBar",
      directoryHint: .isDirectory
    )
    let homes = support.appending(path: "managed-codex-homes", directoryHint: .isDirectory)
    let personalHome = homes.appending(path: "personal", directoryHint: .isDirectory)
    let businessHome = homes.appending(path: "business", directoryHint: .isDirectory)
    let liveHome = directory.url.appending(path: ".codex", directoryHint: .isDirectory)
    for url in [personalHome, businessHome, liveHome] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try writeJSON([
      "tokens": ["account_id": "workspace-personal", "access_token": "not-read"],
    ], to: personalHome.appending(path: "auth.json"))
    try writeJSON([
      "tokens": ["account_id": "workspace-business", "access_token": "not-read"],
    ], to: businessHome.appending(path: "auth.json"))
    try writeJSON([
      "tokens": ["account_id": "workspace-personal", "access_token": "not-read"],
    ], to: liveHome.appending(path: "auth.json"))
    try writeJSON([
      "version": 3,
      "accounts": [
        [
          "id": UUID().uuidString,
          "email": "same@example.com",
          "workspaceLabel": "Personal",
          "workspaceAccountID": "workspace-personal",
          "managedHomePath": personalHome.path,
        ],
        [
          "id": UUID().uuidString,
          "email": "same@example.com",
          "workspaceLabel": "Example Business",
          "workspaceAccountID": "workspace-business",
          "managedHomePath": businessHome.path,
        ],
      ],
    ], to: support.appending(path: "managed-codex-accounts.json"))

    let sources = ProviderLimitCollector.codexWorkspaceSources(homeDirectory: directory.url)
    #expect(sources.map(\.workspace.name) == ["Personal", "Example Business"])
    #expect(sources.map(\.workspace.email) == ["same@example.com", "same@example.com"])
    #expect(sources.first?.isLive == true)
    #expect(ProviderLimitCollector.resolveCodexWorkspaceSource(
      sources,
      selectedID: "workspace-business"
    )?.workspace.name == "Example Business")
    let selected = ProviderLimitCollector.resolveCodexWorkspaceSource(
      sources,
      selectedID: "workspace-business"
    )
    #expect(ProviderLimitCollector.codexEnvironmentOverrides(
      for: selected
    ) == ["CODEX_HOME": businessHome.path])
    #expect(ProviderLimitCollector.codexManagedWorkspaceHomeDirectory(
      homeDirectory: directory.url,
      workspaceID: "workspace-personal"
    ) == personalHome)
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
      usageDatabaseURL: databaseURL
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

    let workspacePreferences = CodexUsageWorkspacePreferences(defaults: defaults)
    #expect(workspacePreferences.selectedWorkspaceID == nil)
    workspacePreferences.save(selectedWorkspaceID: "workspace-business")
    #expect(CodexUsageWorkspacePreferences(
      defaults: defaults
    ).selectedWorkspaceID == "workspace-business")
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
    let scopedCodex = ProviderLimitCollector.scopedCodexAccount(
      fiveHourCodex,
      workspace: CodexUsageWorkspace(
        id: "workspace-business",
        name: "Example Business",
        email: "same@example.com"
      ),
      showsWorkspaceIdentity: true
    )
    #expect(scopedCodex.accountScopeID == "workspace-business")
    #expect(scopedCodex.accountLabel == "Example Business — same@example.com")
    #expect(scopedCodex.quotaWindows == fiveHourCodex.quotaWindows)

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

  @Test("device analytics discovers local sources with no enabled accounts or credential reads")
  func analyticsDiscoversSourcesWithoutAccounts() async throws {
    let directory = try TemporaryDirectory(prefix: "wovenmatter-usage-disabled")
    defer { directory.remove() }
    let sourceAccess = UsageSourceAccessRecorder()
    let credentials = RecordingUsageCredentialStore()
    let service = LocalUsageService(
      homeDirectory: directory.url,
      fileManager: RecordingUsageFileManager(recorder: sourceAccess),
      credentialStore: credentials,
      usageDatabaseURL: directory.url.appending(path: "workspace.sqlite")
    )

    let snapshot = try await service.snapshot(
      range: .last30Days,
      refreshLimits: true,
      refreshReason: .manual,
      enabledProviders: [],
      allowCredentialAccess: true,
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(snapshot.analytics.samples.isEmpty)
    #expect(snapshot.analytics.sources.allSatisfy { $0.status == .notFound })
    #expect(snapshot.limits.isEmpty)
    #expect(credentials.readCount == 0)
    #expect(!sourceAccess.providerSourceChecks.isEmpty)
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

  func authorizeOpenRouterAPIKey() throws -> String? { try loadOpenRouterAPIKey() }

  func loadOpenRouterAPIKey() throws -> String? {
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
      "/.local/share/opencode/", "/.pi/", "/.openclaw/", "/.hermes/",
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

private func writeJSON(_ object: Any, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    .write(to: url, options: [.atomic])
}

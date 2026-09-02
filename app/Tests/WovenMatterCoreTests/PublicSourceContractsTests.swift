import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Public source contracts", .serialized)
struct PublicSourceContractsTests {
  @Test("usage gateway supports only the approved account providers")
  func usageGatewayProviders() {
    #expect(ProviderKind.supportedAccounts == [
      .codex,
      .claude,
      .grok,
      .cursor,
      .openCodeGo,
      .openRouter,
    ])
  }

  @Test("disabled usage accounts are absent and never probed")
  func passiveUsageAccounts() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let accounts = await ProviderLimitCollector.collect(
      homeDirectory: FileManager.default.temporaryDirectory,
      openRouterAPIKey: nil,
      enabledProviders: [],
      now: now
    )

    #expect(accounts.isEmpty)
  }

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

  @Test("usage providers default to enabled and persist exact choices")
  func usageProviderPreferences() throws {
    let suiteName = "wovenmatter-usage-provider-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = UsageProviderPreferences(defaults: defaults)

    #expect(preferences.enabledProviders == Set(ProviderKind.supportedAccounts))

    preferences.save([.codex, .openCodeGo])
    #expect(
      UsageProviderPreferences(defaults: defaults).enabledProviders
        == [.codex, .openCodeGo]
    )

    preferences.save([])
    #expect(UsageProviderPreferences(defaults: defaults).enabledProviders.isEmpty)
  }

  @Test("disabled providers are filtered from analytics and limits")
  func disabledProvidersAreFiltered() async throws {
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
    let snapshot = await service.snapshot(
      range: .last30Days,
      refreshLimits: false,
      refreshReason: .rangeChanged,
      enabledProviders: [.claude],
      allowCredentialAccess: true,
      now: now
    )

    #expect(snapshot.analytics.samples.map(\.provider) == [.claude])
    #expect(snapshot.analytics.sources.allSatisfy { $0.provider != .codex })
    #expect(snapshot.limits.map(\.provider) == [.claude])
    #expect(credentials.readCount == 0)
    #expect(sourceAccess.providerSourceChecks.allSatisfy { path in
      !path.contains("/.codex/")
        && !path.contains("/.grok/")
        && !path.contains("/.cursor/")
        && !path.contains("/.local/share/opencode/")
    })
  }

  @Test("disabled providers do not scan local sources or read credentials")
  func disabledProvidersDoNotAccessSources() async throws {
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

    let snapshot = await service.snapshot(
      range: .last30Days,
      refreshLimits: true,
      refreshReason: .manual,
      enabledProviders: [],
      allowCredentialAccess: true,
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(snapshot.analytics.samples.isEmpty)
    #expect(snapshot.analytics.sources.isEmpty)
    #expect(snapshot.limits.isEmpty)
    #expect(credentials.readCount == 0)
    #expect(sourceAccess.providerSourceChecks.isEmpty)
  }

  @Test("provider dashboards use consumer account destinations")
  func providerDashboardDestinations() {
    #expect(ProviderDashboardURL.codex?.absoluteString == "https://chatgpt.com/codex/settings/usage")
    #expect(ProviderDashboardURL.claude?.absoluteString == "https://claude.ai/settings/usage")
    #expect(ProviderDashboardURL.grok?.absoluteString == "https://grok.com/?_s=usage")
    #expect(ProviderDashboardURL.cursor?.absoluteString == "https://cursor.com/dashboard?tab=usage")
    #expect(ProviderDashboardURL.openCodeGo?.absoluteString == "https://opencode.ai/auth")
    #expect(ProviderDashboardURL.openRouter?.absoluteString == "https://openrouter.ai/settings/credits")
  }

  @Test("the bundled catalog is complete and executable")
  func harnessCatalog() throws {
    let document = try HarnessCatalog.loadBundled()

    #expect(document.schemaVersion == 4)
    #expect(document.harnesses.map(\.id) == [
      .codex, .claudeCode, .grokBuild, .hermes,
      .cursor, .opencode, .pi, .openclaw,
    ])
    #expect(document.harnesses.allSatisfy { harness in
      !harness.capabilities.isEmpty
        && harness.install.source.scheme == "https"
        && !harness.authentication.statusCommands.isEmpty
        && !harness.authentication.methods.isEmpty
        && (harness.adapterPackage != nil || harness.transportCheckCommand != nil)
    })
    #expect(document.harnesses.filter { $0.adapterPackage != nil }.allSatisfy {
      guard let version = $0.minimumAdapterVersion else { return false }
      let parts = version.split(separator: ".", omittingEmptySubsequences: false)
      return parts.count == 3
        && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    })
    #expect(document.harnesses.filter {
      $0.install.kind == "npm-global"
    }.allSatisfy {
      guard let package = $0.install.package,
            let separator = package.lastIndex(of: "@"),
            separator != package.startIndex else { return false }
      let version = package[package.index(after: separator)...]
      let parts = version.split(separator: ".", omittingEmptySubsequences: false)
      return parts.count == 3
        && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    })
  }

  @Test("local records and remote session identity survive reopen")
  func databasePersistence() throws {
    let directory = try TemporaryDirectory(prefix: "wovenmatter-database")
    defer { directory.remove() }
    let databaseURL = directory.url.appending(path: "workspace.sqlite")
    let workspaceID = UUID()
    let ownerDeviceID = UUID()
    let folderID: String
    let noteID: String
    let conversationID: String

    do {
      let database = try WorkspaceDatabase(url: databaseURL)
      folderID = try database.createFolder(name: "Research")
      noteID = try database.createNote(
        folderID: folderID,
        title: "Durable note",
        content: "Remember this"
      )
      conversationID = try database.createRemoteACPSession(
        runtimeKind: .codex,
        remoteWorkspaceID: workspaceID,
        remoteWorkspaceName: "Remote",
        title: "Remote notes",
        ownerDeviceID: ownerDeviceID
      )
    }

    let reopened = try WorkspaceDatabase(url: databaseURL)
    let overview = try reopened.workspaceOverview()
    #expect(overview.folders.map(\.id) == [folderID])
    #expect(overview.notes.map(\.id) == [noteID])
    #expect(try reopened.localACPSession(
      conversationID: conversationID
    ).remoteWorkspaceID == workspaceID)
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

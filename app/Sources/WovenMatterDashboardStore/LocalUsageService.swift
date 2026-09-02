import Darwin
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

public enum UsageRefreshReason: Equatable, Sendable {
  case startup
  case viewAppeared
  case rangeChanged
  case manual
  case runCompleted
  case periodic
  case credentialChanged
}

public enum UsageKeychainInteraction: String, Equatable, Sendable {
  case noninteractive
  case oneShotExplicit

  public static func resolve(
    refreshReason: UsageRefreshReason,
    disclosureAcknowledged: Bool,
    explicitUserAction: Bool
  ) -> Self {
    guard refreshReason == .credentialChanged,
          disclosureAcknowledged,
          explicitUserAction else { return .noninteractive }
    return .oneShotExplicit
  }

  var allowsInteraction: Bool { self == .oneShotExplicit }
}

public struct CodexUsageWorkspace: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let email: String

  public init(id: String, name: String, email: String) {
    self.id = id
    self.name = name
    self.email = email
  }

  public var selectionLabel: String { "\(name) — \(email)" }
}

public struct CodexUsageWorkspacePreferences {
  private static let selectedWorkspaceKey =
    "wovenmatter.usage.codex.selected-workspace"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var selectedWorkspaceID: String? {
    defaults.string(forKey: Self.selectedWorkspaceKey)
  }

  public func save(selectedWorkspaceID: String) {
    defaults.set(selectedWorkspaceID, forKey: Self.selectedWorkspaceKey)
  }
}

public struct LocalUsageLimitsSnapshot: Equatable, Sendable {
  public let accounts: [UsageLimitAccount]
  public let hasOpenRouterCredential: Bool
  public let codexWorkspaces: [CodexUsageWorkspace]
  public let selectedCodexWorkspaceID: String?

  public init(
    accounts: [UsageLimitAccount],
    hasOpenRouterCredential: Bool,
    codexWorkspaces: [CodexUsageWorkspace] = [],
    selectedCodexWorkspaceID: String? = nil
  ) {
    self.accounts = accounts
    self.hasOpenRouterCredential = hasOpenRouterCredential
    self.codexWorkspaces = codexWorkspaces
    self.selectedCodexWorkspaceID = selectedCodexWorkspaceID
  }
}

public actor LocalUsageService {
  private struct ImportOutcome: Sendable {
    let discoveredFiles: Int
    let failures: Int

    static let empty = ImportOutcome(discoveredFiles: 0, failures: 0)
  }

  private static let parserVersion = "usage-index-v3"
  private static let retention: TimeInterval = 120 * 24 * 60 * 60
  private static let localRefreshInterval: TimeInterval = 5 * 60
  private static let viewRefreshInterval: TimeInterval = 60
  private static let remoteRefreshInterval: TimeInterval = 15 * 60

  private let homeDirectory: URL
  private let fileManager: FileManager
  private let credentialStore: any UsageCredentialStoring
  private let databaseURL: URL
  private var usageStore: UsageStore?
  private var usageStoreFailure: String?
  private var cachedLimits: (
    date: Date,
    providers: Set<ProviderKind>,
    codexWorkspaceID: String?,
    accounts: [UsageLimitAccount]
  )?
  private var importOutcomes: [String: ImportOutcome] = [:]
  private var openRouterStatus: UsageSourceStatus = .unavailable
  private var openRouterDetail = "Add an OpenRouter management key to import official account activity."
  private var cursorAccountStatus: UsageSourceStatus = .unavailable
  private var cursorAccountDetail = "Cursor account usage has not been checked yet."

  public init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    credentialService: String = WovenMatterKeychainService.current + ".usage",
    usageDatabaseURL: URL? = nil
  ) {
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    credentialStore = UsageCredentialStore(service: credentialService)
    databaseURL = usageDatabaseURL ?? homeDirectory.appending(
      path: "Library/Application Support/Woven Matter/workspace.sqlite"
    )
  }

  init(
    homeDirectory: URL,
    fileManager: FileManager,
    credentialStore: any UsageCredentialStoring,
    usageDatabaseURL: URL
  ) {
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    self.credentialStore = credentialStore
    databaseURL = usageDatabaseURL
  }

  public func snapshot(
    range: UsageTimeRange,
    refreshLimits: Bool = false,
    refreshReason: UsageRefreshReason = .manual,
    enabledProviders: Set<ProviderKind> = Set(ProviderKind.supportedAccounts),
    allowCredentialAccess: Bool = true,
    now: Date = Date()
  ) async -> LocalUsageSnapshot {
    let analytics = await analyticsSnapshot(
      range: range,
      refreshReason: refreshReason,
      enabledProviders: enabledProviders,
      allowCredentialAccess: allowCredentialAccess,
      now: now
    )
    let limits = await limitsSnapshot(
      refresh: refreshLimits,
      refreshReason: refreshReason,
      enabledProviders: enabledProviders,
      allowCredentialAccess: allowCredentialAccess,
      now: now
    )
    return LocalUsageSnapshot(
      analytics: analytics,
      limits: limits.accounts,
      hasOpenRouterCredential: limits.hasOpenRouterCredential
    )
  }

  public nonisolated static func placeholderLimits(
    enabledProviders: Set<ProviderKind> = [],
    now: Date = Date()
  ) -> [UsageLimitAccount] {
    ProviderLimitCollector.placeholderAccounts(
      enabledProviders: enabledProviders,
      now: now
    )
  }

  public func codexWorkspaceHomeDirectory(workspaceID: String) -> URL? {
    ProviderLimitCollector.codexManagedWorkspaceHomeDirectory(
      homeDirectory: homeDirectory,
      workspaceID: workspaceID
    )
  }

  public func limitsSnapshot(
    refresh: Bool,
    refreshReason: UsageRefreshReason = .manual,
    enabledProviders: Set<ProviderKind> = [],
    allowCredentialAccess: Bool = true,
    keychainInteraction: UsageKeychainInteraction = .noninteractive,
    selectedCodexWorkspaceID: String? = nil,
    now: Date = Date()
  ) async -> LocalUsageLimitsSnapshot {
    let codexSources = enabledProviders.contains(.codex)
      ? ProviderLimitCollector.codexWorkspaceSources(homeDirectory: homeDirectory)
      : []
    let selectedCodexSource = ProviderLimitCollector.resolveCodexWorkspaceSource(
      codexSources,
      selectedID: selectedCodexWorkspaceID
    )
    let resolvedCodexWorkspaceID = selectedCodexSource?.workspace.id
    let accounts: [UsageLimitAccount]
    let persistent = (try? openUsageStore()?.usageLimitAccounts(
      providers: enabledProviders,
      accountScopes: resolvedCodexWorkspaceID.map { [.codex: $0] } ?? [:]
    )) ?? []
    let persistentByProvider = Dictionary(
      uniqueKeysWithValues: persistent.map { ($0.provider, $0) }
    )
    let mayReuseFreshLimits = refreshReason != .manual
      && refreshReason != .credentialChanged
    if let cachedLimits,
       cachedLimits.providers == enabledProviders,
       cachedLimits.codexWorkspaceID == resolvedCodexWorkspaceID,
       (!refresh || (mayReuseFreshLimits
         && now.timeIntervalSince(cachedLimits.date) < 60)) {
      accounts = cachedLimits.accounts
    } else if refresh {
      let openRouterAPIKey = allowCredentialAccess
        && enabledProviders.contains(.openRouter)
        ? (try? credentialStore.loadOpenRouterAPIKey())
        : nil
      let refreshed = await ProviderLimitCollector.collect(
        homeDirectory: homeDirectory,
        openRouterAPIKey: openRouterAPIKey,
        enabledProviders: enabledProviders,
        keychainInteraction: keychainInteraction,
        codexWorkspaceSource: selectedCodexSource,
        codexWorkspaceCount: codexSources.count,
        now: now
      )
      accounts = refreshed.map { account in
        guard account.status == .failed || account.status == .unavailable,
              let prior = persistentByProvider[account.provider]
        else { return account }
        return prior.retainingLastGood(after: account)
      }
      try? openUsageStore()?.saveUsageLimitAccounts(accounts, storedAt: now)
      cachedLimits = (now, enabledProviders, resolvedCodexWorkspaceID, accounts)
    } else {
      let placeholders = ProviderLimitCollector.placeholderAccounts(
        enabledProviders: enabledProviders,
        now: now
      )
      accounts = placeholders.map { placeholder in
        persistentByProvider[placeholder.provider]?.stale()
          ?? placeholder
      }
    }
    return LocalUsageLimitsSnapshot(
      accounts: accounts,
      hasOpenRouterCredential: allowCredentialAccess
        && enabledProviders.contains(.openRouter)
        && (try? credentialStore.hasOpenRouterAPIKey()) == true,
      codexWorkspaces: codexSources.map(\.workspace),
      selectedCodexWorkspaceID: resolvedCodexWorkspaceID
    )
  }

  public func analyticsSnapshot(
    range: UsageTimeRange,
    refreshReason: UsageRefreshReason = .manual,
    enabledProviders: Set<ProviderKind> = Set(ProviderKind.supportedAccounts),
    allowCredentialAccess: Bool = true,
    now: Date = Date()
  ) async -> UsageAnalyticsSnapshot {
    let interval = range.interval(relativeTo: now)
    guard let store = openUsageStore() else {
      return UsageAnalyticsSnapshot(
        range: range,
        generatedAt: now,
        samples: [],
        sources: [UsageSourceCoverage(
          id: "wovenmatter:index",
          sourceName: "Woven Matter usage index",
          provider: .unknown,
          status: .failed,
          location: abbreviated(databaseURL),
          discoveredSessions: 0,
          attributedSamples: 0,
          detail: usageStoreFailure ?? "The persistent usage index could not be opened."
        )]
      )
    }

    let requestedImportCutoff = max(
      now.addingTimeInterval(-Self.retention),
      interval.start.addingTimeInterval(-36 * 60 * 60)
    )
    if shouldImportLocal(
      store: store,
      reason: refreshReason,
      requestedCutoff: requestedImportCutoff,
      now: now
    ) {
      if importLocalSources(
        store: store,
        cutoff: requestedImportCutoff,
        enabledProviders: enabledProviders,
        now: now
      ) {
        try? store.setMetadataDate(now, for: "usage.local-import-at")
        let previousCutoff = try? store.metadataDate("usage.local-indexed-after")
        try? store.setMetadataDate(
          min(previousCutoff ?? requestedImportCutoff, requestedImportCutoff),
          for: "usage.local-indexed-after"
        )
        try? store.prune(before: now.addingTimeInterval(-Self.retention))
      }
    }
    if enabledProviders.contains(.openRouter),
       allowCredentialAccess,
       shouldImportOpenRouter(store: store, reason: refreshReason, now: now) {
      await importOpenRouterActivity(store: store, now: now)
      try? store.setMetadataDate(now, for: "usage.openrouter-attempt-at")
    }
    if enabledProviders.contains(.cursor),
       shouldImportCursorAccount(store: store, reason: refreshReason, now: now) {
      await importCursorAccountActivity(
        store: store,
        cutoff: now.addingTimeInterval(-Self.retention),
        now: now
      )
      try? store.setMetadataDate(now, for: "usage.cursor-attempt-at")
    }
    let storedSamples = ((try? store.samples(in: interval)) ?? []).filter {
      enabledProviders.contains($0.provider)
    }
    let samples = Self.reconcileOpenRouter(
      deduplicated(storedSamples)
    ).sorted { lhs, rhs in
      lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp < rhs.timestamp
    }
    return UsageAnalyticsSnapshot(
      range: range,
      generatedAt: now,
      samples: samples,
      sources: coverage(
        store: store,
        interval: interval,
        enabledProviders: enabledProviders,
        allowCredentialAccess: allowCredentialAccess
      )
    )
  }

  public func saveOpenRouterAPIKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw LocalUsageServiceError.emptyCredential }
    try credentialStore.saveOpenRouterAPIKey(key)
    cachedLimits = nil
    openRouterStatus = .unavailable
    openRouterDetail = "The new credential has not been checked yet."
  }

  public func deleteOpenRouterAPIKey() throws {
    try credentialStore.deleteOpenRouterAPIKey()
    cachedLimits = nil
    openRouterStatus = .unavailable
    openRouterDetail = "Add an OpenRouter management key to import official account activity."
  }

  private func openUsageStore() -> UsageStore? {
    if let usageStore { return usageStore }
    if usageStoreFailure != nil { return nil }
    do {
      try fileManager.createDirectory(
        at: databaseURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let store = try UsageStore(databaseURL: databaseURL)
      usageStore = store
      return store
    } catch {
      usageStoreFailure = error.localizedDescription
      return nil
    }
  }

  private func shouldImportLocal(
    store: UsageStore,
    reason: UsageRefreshReason,
    requestedCutoff: Date,
    now: Date
  ) -> Bool {
    let lastImport = try? store.metadataDate("usage.local-import-at")
    let indexedAfter = try? store.metadataDate("usage.local-indexed-after")
    if indexedAfter == nil || (indexedAfter ?? .distantFuture) > requestedCutoff {
      return true
    }
    switch reason {
    case .rangeChanged:
      return lastImport == nil
    case .viewAppeared:
      return lastImport.map { now.timeIntervalSince($0) >= Self.viewRefreshInterval } ?? true
    case .periodic:
      return lastImport.map { now.timeIntervalSince($0) >= Self.localRefreshInterval } ?? true
    case .startup, .manual, .runCompleted, .credentialChanged:
      return true
    }
  }

  private func shouldImportOpenRouter(
    store: UsageStore,
    reason: UsageRefreshReason,
    now: Date
  ) -> Bool {
    guard (try? credentialStore.hasOpenRouterAPIKey()) == true else { return false }
    let lastAttempt = try? store.metadataDate("usage.openrouter-attempt-at")
    switch reason {
    case .rangeChanged, .runCompleted:
      return false
    case .manual, .credentialChanged:
      return true
    case .startup, .viewAppeared, .periodic:
      return lastAttempt.map { now.timeIntervalSince($0) >= Self.remoteRefreshInterval } ?? true
    }
  }

  private func shouldImportCursorAccount(
    store: UsageStore,
    reason: UsageRefreshReason,
    now: Date
  ) -> Bool {
    let lastAttempt = try? store.metadataDate("usage.cursor-attempt-at")
    switch reason {
    case .rangeChanged, .runCompleted:
      return false
    case .manual, .credentialChanged:
      return true
    case .startup, .viewAppeared, .periodic:
      return lastAttempt.map { now.timeIntervalSince($0) >= Self.remoteRefreshInterval } ?? true
    }
  }

  private func importCursorAccountActivity(
    store: UsageStore,
    cutoff: Date,
    now: Date
  ) async {
    do {
      let activity = try await CursorAccountClient(homeDirectory: homeDirectory)
        .activity(since: cutoff, until: now)
      let retainedInterval = DateInterval(
        start: now.addingTimeInterval(-Self.retention),
        end: now
      )
      let retained = ((try? store.samples(in: retainedInterval)) ?? [])
        .filter { $0.sourceID == "cursor:account" }
      var samplesByEvent = Dictionary(
        uniqueKeysWithValues: retained.map { ($0.sourceEventID, $0) }
      )
      for sample in activity.samples {
        samplesByEvent[sample.sourceEventID] = sample
      }
      try store.replace(
        sourceID: "cursor:account",
        sourceName: "Cursor account activity",
        location: "Cursor Usage API",
        provider: .cursor,
        harness: "Cursor",
        fingerprint: "cursor-account:\(now.timeIntervalSince1970)",
        samples: Array(samplesByEvent.values),
        importedAt: now
      )
      cursorAccountStatus = .available
      cursorAccountDetail = "Account-wide usage from Cursor's dashboard API, authenticated by Cursor.app's local sign-in."
    } catch CursorAccountClientError.notSignedIn {
      cursorAccountStatus = .unavailable
      cursorAccountDetail = "Sign in to Cursor.app to import account-wide usage from all devices."
    } catch {
      cursorAccountStatus = .partial
      cursorAccountDetail = "Cursor account refresh failed: \(error.localizedDescription) Persisted history remains available."
    }
  }

  private func importLocalSources(
    store: UsageStore,
    cutoff: Date,
    enabledProviders: Set<ProviderKind>,
    now: Date
  ) -> Bool {
    do {
      try store.performTransaction {
        importLocalSourcesWithinTransaction(
          store: store,
          cutoff: cutoff,
          enabledProviders: enabledProviders,
          now: now
        )
      }
      importOutcomes.removeValue(forKey: "wovenmatter:index")
      return true
    } catch {
      importOutcomes["wovenmatter:index"] = ImportOutcome(
        discoveredFiles: 0,
        failures: 1
      )
      return false
    }
  }

  private func importLocalSourcesWithinTransaction(
    store: UsageStore,
    cutoff retentionCutoff: Date,
    enabledProviders: Set<ProviderKind>,
    now: Date
  ) {
    let providerFilterSignature = enabledProviders
      .map(\.rawValue)
      .sorted()
      .joined(separator: ",")

    if enabledProviders.contains(.codex) {
      let codexRoot = homeDirectory.appending(path: ".codex/sessions", directoryHint: .isDirectory)
      importOutcomes["codex:file:"] = importTranscriptFiles(
        root: codexRoot,
        prefix: "codex:file:",
        sourceName: "Codex rollout",
        provider: .codex,
        harness: "Codex",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { url in
        var state = CodexUsageScanState()
        var records: [ParsedUsageSample] = []
        let usageMarker = Data("\"token_count\"".utf8)
        let contextMarker = Data("\"turn_context\"".utf8)
        let metadataMarker = Data("\"session_meta\"".utf8)
        try self.forEachLineData(in: url) { data, lineNumber in
          guard data.range(of: usageMarker) != nil
                  || data.range(of: contextMarker) != nil
                  || data.range(of: metadataMarker) != nil else { return }
          if let sample = LocalUsageTranscriptParser.parseCodex(
            line: String(decoding: data, as: UTF8.self),
            lineNumber: lineNumber,
            state: &state
          ) {
            records.append(sample)
          }
        }
        return records.map(\.sample)
      }
    }

    if enabledProviders.contains(.claude) {
      let claudeRoot = homeDirectory.appending(path: ".claude/projects", directoryHint: .isDirectory)
      importOutcomes["claude:file:"] = importTranscriptFiles(
        root: claudeRoot,
        prefix: "claude:file:",
        sourceName: "Claude transcript",
        provider: .claude,
        harness: "Claude Code",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { url in
        var records: [UsageSample] = []
        try self.forEachLineData(in: url) { data, lineNumber in
          guard data.range(of: Data("\"usage\"".utf8)) != nil else { return }
          if let parsed = LocalUsageTranscriptParser.parseClaude(
            line: String(decoding: data, as: UTF8.self),
            lineNumber: lineNumber
          ) {
            records.append(parsed.sample)
          }
        }
        return records
      }
    }

    if !enabledProviders.isEmpty {
      let piRoot = homeDirectory.appending(path: ".pi/agent/sessions", directoryHint: .isDirectory)
      importOutcomes["pi:file:"] = importHarnessFiles(
        root: piRoot,
        prefix: "pi:file:",
        harness: "Pi",
        enabledProviders: enabledProviders,
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      )

      let openClawRoot = homeDirectory.appending(
        path: ".openclaw/agents",
        directoryHint: .isDirectory
      )
      importOutcomes["openclaw:file:"] = importHarnessFiles(
        root: openClawRoot,
        prefix: "openclaw:file:",
        harness: "OpenClaw",
        enabledProviders: enabledProviders,
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { url in
        url.path.contains("/sessions/")
          && url.lastPathComponent.hasSuffix(".jsonl")
          && !url.lastPathComponent.hasSuffix(".trajectory.jsonl")
      }

      let hermesDatabase = homeDirectory.appending(path: ".hermes/state.db")
      importOutcomes["hermes:database"] = importDatabase(
        databaseURL: hermesDatabase,
        sourceID: "hermes:database",
        sourceName: "Hermes usage ledger",
        provider: .unknown,
        harness: "Hermes",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { indexedAfter in
        try HermesUsageDatabase(databaseURL: hermesDatabase)
          .samples(cutoff: indexedAfter, now: now)
          .filter { enabledProviders.contains($0.provider) }
      }
    }

    if enabledProviders.contains(.grok) {
      let grokRoot = homeDirectory.appending(path: ".grok/sessions", directoryHint: .isDirectory)
      importOutcomes["grok:file:"] = importGrok(
        root: grokRoot,
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      )
    }

    if enabledProviders.contains(.openCodeGo) {
      let openCodeDatabase = homeDirectory.appending(path: ".local/share/opencode/opencode.db")
      importOutcomes["opencode:database"] = importDatabase(
        databaseURL: openCodeDatabase,
        sourceID: "opencode:database",
        sourceName: "OpenCode history",
        provider: .openCodeGo,
        harness: "OpenCode",
        providerFilterSignature: providerFilterSignature,
        store: store,
        cutoff: retentionCutoff,
        now: now
      ) { indexedAfter in
        try OpenCodeUsageDatabase(databaseURL: openCodeDatabase)
          .samples(cutoff: indexedAfter, now: now)
          .filter { $0.provider == .openCodeGo }
      }
    }
  }

  private func importTranscriptFiles(
    root: URL,
    prefix: String,
    sourceName: String,
    provider: ProviderKind,
    harness: String,
    providerFilterSignature: String,
    store: UsageStore,
    cutoff: Date,
    now: Date,
    predicate: (URL) -> Bool = { $0.pathExtension == "jsonl" },
    fingerprint: ((URL) throws -> String)? = nil,
    parser: (URL) throws -> [UsageSample]
  ) -> ImportOutcome {
    guard fileManager.fileExists(atPath: root.path) else { return .empty }
    let files = files(root: root, cutoff: cutoff, predicate: predicate)
    var failures = 0
    for file in files {
      do {
        let currentFingerprint: String
        if let fingerprint {
          currentFingerprint = try fingerprint(file) + ":" + providerFilterSignature
        } else {
          currentFingerprint = try fileFingerprint(file) + ":" + providerFilterSignature
        }
        let sourceID = prefix + file.path
        let stored = try store.source(sourceID)
        let indexedAfter = min(stored?.indexedAfter ?? cutoff, cutoff)
        guard stored?.fingerprint != currentFingerprint
                || stored?.indexedAfter == nil
                || (stored?.indexedAfter ?? .distantFuture) > cutoff else { continue }
        let samples = try parser(file).filter {
          $0.timestamp >= indexedAfter && $0.timestamp <= now
        }
        try store.replace(
          sourceID: sourceID,
          sourceName: sourceName,
          location: abbreviated(file),
          provider: provider,
          harness: harness,
          fingerprint: currentFingerprint,
          samples: uniqueSourceEvents(samples),
          importedAt: now,
          indexedAfter: indexedAfter,
          transactional: false
        )
      } catch {
        failures += 1
      }
    }
    return ImportOutcome(discoveredFiles: files.count, failures: failures)
  }

  private func importHarnessFiles(
    root: URL,
    prefix: String,
    harness: String,
    enabledProviders: Set<ProviderKind>,
    providerFilterSignature: String,
    store: UsageStore,
    cutoff: Date,
    now: Date,
    predicate: (URL) -> Bool = { $0.pathExtension == "jsonl" }
  ) -> ImportOutcome {
    importTranscriptFiles(
      root: root,
      prefix: prefix,
      sourceName: "\(harness) session",
      provider: .unknown,
      harness: harness,
      providerFilterSignature: providerFilterSignature,
      store: store,
      cutoff: cutoff,
      now: now,
      predicate: predicate
    ) { url in
      var state = HarnessUsageScanState()
      var records: [UsageSample] = []
      let usageMarker = Data("\"usage\"".utf8)
      let modelMarker = Data("\"model_change\"".utf8)
      let thinkingMarker = Data("\"thinking_level_change\"".utf8)
      let sessionMarker = Data("\"session\"".utf8)
      try self.forEachLineData(in: url) { data, lineNumber in
        guard data.range(of: usageMarker) != nil
                || data.range(of: modelMarker) != nil
                || data.range(of: thinkingMarker) != nil
                || data.range(of: sessionMarker) != nil else { return }
        if let parsed = LocalUsageTranscriptParser.parseHarness(
          line: String(decoding: data, as: UTF8.self),
          lineNumber: lineNumber,
          harness: harness,
          state: &state
        ) {
          records.append(parsed.sample)
        }
      }
      return records.filter { enabledProviders.contains($0.provider) }
    }
  }

  private func importGrok(
    root: URL,
    providerFilterSignature: String,
    store: UsageStore,
    cutoff: Date,
    now: Date
  ) -> ImportOutcome {
    importTranscriptFiles(
      root: root,
      prefix: "grok:file:",
      sourceName: "Grok session",
      provider: .grok,
      harness: "Grok Build",
      providerFilterSignature: providerFilterSignature,
      store: store,
      cutoff: cutoff,
      now: now,
      predicate: { $0.lastPathComponent == "updates.jsonl" },
      fingerprint: { try self.grokFingerprint($0) }
    ) { url in
      let summaryURL = url.deletingLastPathComponent().appending(path: "summary.json")
      let summary: [String: Any]
      if let data = try? Data(contentsOf: summaryURL),
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        summary = object
      } else {
        summary = [:]
      }
      var records: [UsageSample] = []
      try self.forEachLineData(in: url) { data, lineNumber in
        guard data.range(of: Data("\"usage\"".utf8)) != nil else { return }
        records += LocalUsageTranscriptParser.parseGrok(
          line: String(decoding: data, as: UTF8.self),
          lineNumber: lineNumber,
          summary: summary
        ).map(\.sample)
      }
      return records
    }
  }

  private func importDatabase(
    databaseURL: URL,
    sourceID: String,
    sourceName: String,
    provider: ProviderKind,
    harness: String,
    providerFilterSignature: String,
    store: UsageStore,
    cutoff: Date,
    now: Date,
    reader: (Date) throws -> [UsageSample]
  ) -> ImportOutcome {
    guard fileManager.fileExists(atPath: databaseURL.path) else { return .empty }
    do {
      let fingerprint = try databaseFingerprint(databaseURL) + ":" + providerFilterSignature
      let stored = try store.source(sourceID)
      let indexedAfter = min(stored?.indexedAfter ?? cutoff, cutoff)
      if stored?.fingerprint != fingerprint
          || stored?.indexedAfter == nil
          || (stored?.indexedAfter ?? .distantFuture) > cutoff {
        let samples = try reader(indexedAfter).filter {
          $0.timestamp >= indexedAfter && $0.timestamp <= now
        }
        try store.replace(
          sourceID: sourceID,
          sourceName: sourceName,
          location: abbreviated(databaseURL),
          provider: provider,
          harness: harness,
          fingerprint: fingerprint,
          samples: uniqueSourceEvents(samples),
          importedAt: now,
          indexedAfter: indexedAfter,
          transactional: false
        )
      }
      return ImportOutcome(discoveredFiles: 1, failures: 0)
    } catch {
      return ImportOutcome(discoveredFiles: 1, failures: 1)
    }
  }

  private func importOpenRouterActivity(store: UsageStore, now: Date) async {
    let storedKey = (try? credentialStore.loadOpenRouterAPIKey()) ?? nil
    guard let key = storedKey else {
      openRouterStatus = .unavailable
      openRouterDetail = "Add an OpenRouter management key to import official account activity."
      return
    }
    do {
      let activity = try await OpenRouterActivityClient.fetch(apiKey: key)
      for (date, samples) in activity.samplesByUTCDate {
        try store.replace(
          sourceID: "openrouter:activity:\(date)",
          sourceName: "OpenRouter activity",
          location: "OpenRouter Activity API",
          provider: .openRouter,
          harness: nil,
          fingerprint: "\(Self.parserVersion):\(now.timeIntervalSince1970)",
          samples: uniqueSourceEvents(samples),
          importedAt: now
        )
      }
      openRouterStatus = .available
      openRouterDetail = activity.detail
    } catch {
      openRouterStatus = error is OpenRouterActivityError ? .partial : .failed
      openRouterDetail = error.localizedDescription
    }
  }

  private func coverage(
    store: UsageStore,
    interval: DateInterval,
    enabledProviders: Set<ProviderKind>,
    allowCredentialAccess: Bool
  ) -> [UsageSourceCoverage] {
    var sources: [UsageSourceCoverage] = []
    if enabledProviders.contains(.codex) { sources.append(sourceCoverage(
      id: "codex",
      prefix: "codex:file:",
      sourceName: "Codex",
      provider: .codex,
      harness: "Codex",
      location: homeDirectory.appending(path: ".codex/sessions"),
      store: store,
      interval: interval,
      detail: "Exact rollout token deltas with model and reasoning metadata; fork-copy and repeated-delta suppression is applied."
    )) }
    if enabledProviders.contains(.claude) { sources.append(sourceCoverage(
      id: "claude",
      prefix: "claude:file:",
      sourceName: "Claude Code",
      provider: .claude,
      harness: "Claude Code",
      location: homeDirectory.appending(path: ".claude/projects"),
      store: store,
      interval: interval,
      detail: "Exact assistant-message token usage, globally deduplicated across resumed transcript copies."
    )) }
    if enabledProviders.contains(.grok) { sources.append(sourceCoverage(
      id: "grok",
      prefix: "grok:file:",
      sourceName: "Grok CLI",
      provider: .grok,
      harness: "Grok Build",
      location: homeDirectory.appending(path: ".grok/sessions"),
      store: store,
      interval: interval,
      detail: "Per-turn, per-model token usage from Grok session updates."
    )) }
    if enabledProviders.contains(.openCodeGo) { sources.append(sourceCoverage(
      id: "opencode",
      prefix: "opencode:database",
      sourceName: "OpenCode",
      provider: .openCodeGo,
      harness: "OpenCode",
      location: homeDirectory.appending(path: ".local/share/opencode/opencode.db"),
      store: store,
      interval: interval,
      detail: "Exact step-finish usage from OpenCode SQLite, including OpenCode Go and other identifiable billing routes."
    )) }
    if !enabledProviders.isEmpty { sources.append(sourceCoverage(
      id: "pi",
      prefix: "pi:file:",
      sourceName: "Pi",
      provider: .unknown,
      harness: "Pi",
      location: homeDirectory.appending(path: ".pi/agent/sessions"),
      store: store,
      interval: interval,
      detail: "Exact assistant-call tokens with model, provider route, cache, reasoning, and thinking-level metadata."
    ))
    sources.append(sourceCoverage(
      id: "openclaw",
      prefix: "openclaw:file:",
      sourceName: "OpenClaw",
      provider: .unknown,
      harness: "OpenClaw",
      location: homeDirectory.appending(path: ".openclaw/agents"),
      store: store,
      interval: interval,
      detail: "Exact assistant-call tokens from active local OpenClaw session histories; trajectory and reset copies are excluded."
    ))
    var hermes = sourceCoverage(
      id: "hermes",
      prefix: "hermes:database",
      sourceName: "Hermes",
      provider: .unknown,
      harness: "Hermes",
      location: homeDirectory.appending(path: ".hermes/state.db"),
      store: store,
      interval: interval,
      detail: "Per-session, per-model ledger totals. Historical tokens are assigned to the row's last-seen time because Hermes does not retain call-level timestamps."
    )
    if hermes.status == .available {
      hermes = UsageSourceCoverage(
        id: hermes.id,
        sourceName: hermes.sourceName,
        provider: hermes.provider,
        harness: hermes.harness,
        status: .partial,
        location: hermes.location,
        discoveredSessions: hermes.discoveredSessions,
        attributedSamples: hermes.attributedSamples,
        detail: hermes.detail
      )
    }
    sources.append(hermes) }
    if enabledProviders.contains(.cursor) {
      sources.append(cursorCoverage(store: store, interval: interval))
    }

    if enabledProviders.contains(.openRouter) {
      let openRouterStats = try? store.statistics(
        sourceIDPrefix: "openrouter:activity:",
        in: interval
      )
      let hasCredential = allowCredentialAccess
        && (try? credentialStore.hasOpenRouterAPIKey()) == true
      let remoteStatus: UsageSourceStatus = if !hasCredential {
        openRouterStats?.events ?? 0 > 0 ? .partial : .unavailable
      } else {
        openRouterStatus
      }
      let remoteDetail = if !hasCredential, (openRouterStats?.events ?? 0) > 0 {
        "Previously imported OpenRouter activity remains in the persistent index, but no credential is stored for refresh."
      } else {
        openRouterDetail
      }
      sources.append(UsageSourceCoverage(
        id: "openrouter",
        sourceName: "OpenRouter",
        provider: .openRouter,
        status: remoteStatus,
        location: "OpenRouter Activity API",
        discoveredSessions: openRouterStats?.sessions ?? 0,
        attributedSamples: openRouterStats?.events ?? 0,
        detail: remoteDetail
      ))
    }
    if !enabledProviders.isEmpty,
       (importOutcomes["wovenmatter:index"]?.failures ?? 0) > 0 {
      sources.append(UsageSourceCoverage(
        id: "wovenmatter:index",
        sourceName: "Woven Matter usage index",
        provider: .unknown,
        status: .failed,
        location: abbreviated(databaseURL),
        discoveredSessions: 0,
        attributedSamples: 0,
        detail: "The latest normalized usage import transaction failed. Previously indexed history remains available and the next refresh will retry."
      ))
    }
    return sources
  }

  private func sourceCoverage(
    id: String,
    prefix: String,
    sourceName: String,
    provider: ProviderKind,
    harness: String,
    location: URL,
    store: UsageStore,
    interval: DateInterval,
    detail: String
  ) -> UsageSourceCoverage {
    let outcome = importOutcomes[prefix] ?? .empty
    let stats = try? store.statistics(sourceIDPrefix: prefix, in: interval)
    let exists = fileManager.fileExists(atPath: location.path)
    let status: UsageSourceStatus
    if outcome.failures > 0 {
      status = .partial
    } else if exists {
      status = .available
    } else if (stats?.events ?? 0) > 0 {
      status = .partial
    } else {
      status = .notFound
    }
    var completeDetail = detail
    if outcome.failures > 0 {
      completeDetail += " \(outcome.failures) changed, locked, or unreadable source(s) failed during the latest import."
    } else if !exists, (stats?.events ?? 0) > 0 {
      completeDetail += " The source is not currently present, so this is persisted history only."
    } else if !exists {
      completeDetail = "No local \(sourceName) usage source was found."
    }
    return UsageSourceCoverage(
      id: id,
      sourceName: sourceName,
      provider: provider,
      harness: harness,
      status: status,
      location: abbreviated(location),
      discoveredSessions: stats?.sessions ?? 0,
      attributedSamples: stats?.events ?? 0,
      detail: completeDetail
    )
  }

  private func cursorCoverage(
    store: UsageStore,
    interval: DateInterval
  ) -> UsageSourceCoverage {
    let acpRoot = homeDirectory.appending(path: ".cursor/acp-sessions")
    let transcriptRoot = homeDirectory.appending(path: ".cursor/projects")
    let acpSessions = files(
      root: acpRoot,
      cutoff: interval.start,
      predicate: { $0.lastPathComponent == "meta.json" }
    ).count
    let transcripts = files(
      root: transcriptRoot,
      cutoff: interval.start,
      predicate: { $0.pathExtension == "jsonl" && $0.path.contains("/agent-transcripts/") }
    ).count
    let stats = try? store.statistics(sourceID: "cursor:account", in: interval)
    let discovered = max(max(acpSessions, transcripts), stats?.sessions ?? 0)
    let found = fileManager.fileExists(atPath: acpRoot.path)
      || fileManager.fileExists(atPath: transcriptRoot.path)
    return UsageSourceCoverage(
      id: "cursor",
      sourceName: "Cursor",
      provider: .cursor,
      harness: "Cursor",
      status: cursorAccountStatus == .available
        ? .available
        : ((stats?.events ?? 0) > 0 || found ? .partial : cursorAccountStatus),
      location: "Cursor Usage API and local Cursor session metadata",
      discoveredSessions: discovered,
      attributedSamples: stats?.events ?? 0,
      detail: cursorAccountDetail + (found
        ? " Local Cursor sessions are also discoverable, but only the account API supplies their token totals and models."
        : "")
    )
  }

  private func deduplicated(_ samples: [UsageSample]) -> [UsageSample] {
    var seenEvents: Set<String> = []
    let uniqueEvents = samples.filter { seenEvents.insert($0.id).inserted }
    let keyed = Dictionary(grouping: uniqueEvents.filter { $0.dedupeKey != nil }) {
      "\($0.provider.rawValue):\($0.dedupeKey ?? "")"
    }
    let winners = Set(keyed.values.compactMap { group in
      group.max { lhs, rhs in Self.dedupeRank(lhs) < Self.dedupeRank(rhs) }?.id
    })
    let exact = uniqueEvents.filter { sample in
      sample.dedupeKey == nil || winners.contains(sample.id)
    }
    return Self.suppressWovenMatterEchoes(exact)
  }

  /// ACP prompt results make native Woven turns visible immediately.
  /// Provider/runtime histories can later report the same settled call with
  /// richer provenance but a different request ID. Pair exact token/model
  /// observations one-to-one so a fast path never becomes a second total.
  static func suppressWovenMatterEchoes(_ samples: [UsageSample]) -> [UsageSample] {
    let isImmediate: (UsageSample) -> Bool = {
      $0.sourceID == "wovenmatter:local"
    }
    let echoes = samples.filter(isImmediate)
      .sorted { $0.timestamp < $1.timestamp }
    let provenance = samples.filter { !isImmediate($0) }
    var claimed: Set<String> = []
    var suppressed: Set<String> = []
    for echo in echoes {
      let echoModel = echo.canonicalModel
      let match = provenance
        .filter { candidate in
          guard !claimed.contains(candidate.id),
                echo.tokens == candidate.tokens,
                abs(echo.timestamp.timeIntervalSince(candidate.timestamp)) <= 10 * 60,
                echo.provider == .unknown || echo.provider == candidate.provider else {
            return false
          }
          let sameSession = echo.sessionID == candidate.sessionID
          let cursorAccountCall = echo.provider == .cursor
            && candidate.sourceID == "cursor:account"
          guard sameSession || cursorAccountCall else { return false }
          let candidateModel = candidate.canonicalModel
          return echoModel == "Unknown model"
            || candidateModel == "Unknown model"
            || echoModel == candidateModel
        }
        .min {
          abs(echo.timestamp.timeIntervalSince($0.timestamp))
            < abs(echo.timestamp.timeIntervalSince($1.timestamp))
        }
      if let match {
        claimed.insert(match.id)
        suppressed.insert(echo.id)
      }
    }
    return samples.filter { !suppressed.contains($0.id) }
  }

  private static func dedupeRank(_ sample: UsageSample) -> Int {
    let confidence = switch sample.attributionConfidence {
    case .exact: 30
    case .derived: 20
    case .aggregate: 10
    case .unknown: 0
    }
    let granularity = switch sample.granularity {
    case .modelCall: 5
    case .turn: 4
    case .sessionAggregate: 3
    case .dailyAggregate: 2
    case .refreshDelta: 1
    }
    let native = sample.application == "Woven Matter" ? 1 : 0
    return confidence + granularity + native
  }

  static func reconcileOpenRouter(_ samples: [UsageSample]) -> [UsageSample] {
    let remote = samples.filter {
      $0.provider == .openRouter && $0.granularity == .dailyAggregate
    }
    guard !remote.isEmpty else { return samples }
    let local = samples.filter {
      $0.provider == .openRouter && $0.granularity != .dailyAggregate
    }
    let passthrough = samples.filter {
      !($0.provider == .openRouter && $0.granularity == .dailyAggregate)
    }
    let remoteGroups = Dictionary(grouping: remote, by: reconciliationKey)
    let localGroups = Dictionary(grouping: local, by: reconciliationKey)
    var result = passthrough
    for (key, aggregates) in remoteGroups {
      let aggregateTokens = aggregates.reduce(.zero) { $0 + $1.tokens }
      let exactSamples = localGroups[key] ?? []
      let exactTokens = exactSamples.reduce(.zero) { $0 + $1.tokens }
      let remainingTotal = max(0, aggregateTokens.totalTokens - exactTokens.totalTokens)
      guard remainingTotal > 0, let first = aggregates.first else { continue }
      let remaining = UsageTokenCounts(
        inputTokens: max(0, aggregateTokens.inputTokens - exactTokens.inputTokens),
        cachedInputTokens: max(
          0,
          aggregateTokens.cachedInputTokens - exactTokens.cachedInputTokens
        ),
        cacheCreationTokens: max(
          0,
          aggregateTokens.cacheCreationTokens - exactTokens.cacheCreationTokens
        ),
        outputTokens: max(0, aggregateTokens.outputTokens - exactTokens.outputTokens),
        reasoningTokens: max(
          0,
          aggregateTokens.reasoningTokens - exactTokens.reasoningTokens
        ),
        reportedTotalTokens: remainingTotal
      )
      let aggregateRequests = aggregates.reduce(0) { $0 + $1.requestCount }
      let exactRequests = exactSamples.reduce(0) { $0 + $1.requestCount }
      let costs = aggregates.compactMap(\.costUSD)
      let localCosts = exactSamples.compactMap(\.costUSD)
      let remainingCost: Double? = if costs.isEmpty {
        nil
      } else {
        max(0, costs.reduce(0, +) - localCosts.reduce(0, +))
      }
      result.append(UsageSample(
        id: "openrouter-residual:\(key)",
        provider: .openRouter,
        timestamp: first.timestamp,
        sessionID: first.sessionID,
        accountLabel: Set(aggregates.map(\.accountLabel)).count == 1
          ? first.accountLabel
          : "Unknown",
        model: first.model,
        billingProvider: Set(aggregates.map(\.billingProvider)).count == 1
          ? first.billingProvider
          : "OpenRouter",
        billingRoute: "OpenRouter API",
        harness: "Unknown",
        application: "OpenRouter Activity API",
        tokens: remaining,
        requestCount: max(1, aggregateRequests - exactRequests),
        costUSD: remainingCost,
        attributionConfidence: .derived,
        granularity: .dailyAggregate,
        sourceID: first.sourceID,
        sourceEventID: "residual:\(key)"
      ))
    }
    return result
  }

  private static func reconciliationKey(_ sample: UsageSample) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents([.year, .month, .day], from: sample.timestamp)
    return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0):\(sample.modelFamily):\(sample.billingRoute)"
  }

  private func uniqueSourceEvents(_ samples: [UsageSample]) -> [UsageSample] {
    var seen: Set<String> = []
    return samples.filter { seen.insert($0.sourceEventID).inserted }
  }

  private func fileFingerprint(_ url: URL) throws -> String {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return [
      Self.parserVersion,
      String(values.fileSize ?? 0),
      String(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
    ].joined(separator: ":")
  }

  private func databaseFingerprint(_ url: URL) throws -> String {
    var values = [try fileFingerprint(url)]
    for suffix in ["-wal", "-shm"] {
      let sidecar = URL(fileURLWithPath: url.path + suffix)
      if fileManager.fileExists(atPath: sidecar.path) {
        values.append(try fileFingerprint(sidecar))
      }
    }
    return values.joined(separator: "|")
  }

  private func grokFingerprint(_ updatesURL: URL) throws -> String {
    var values = [try fileFingerprint(updatesURL)]
    let summaryURL = updatesURL.deletingLastPathComponent().appending(path: "summary.json")
    if fileManager.fileExists(atPath: summaryURL.path) {
      values.append(try fileFingerprint(summaryURL))
    }
    return values.joined(separator: "|")
  }

  private func files(
    root: URL,
    cutoff: Date,
    predicate: (URL) -> Bool
  ) -> [URL] {
    guard fileManager.fileExists(atPath: root.path) else { return [] }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    var result: [URL] = []
    for case let url as URL in enumerator where predicate(url) {
      guard let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
      result.append(url)
    }
    return result.sorted { $0.path < $1.path }
  }

  private func forEachLineData(
    in url: URL,
    body: (Data.SubSequence, Int) throws -> Void
  ) throws {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
    try data.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
      var start = 0
      var lineNumber = 0
      while start < rawBuffer.count {
        let remaining = rawBuffer.count - start
        let newlinePointer = Darwin.memchr(base.advanced(by: start), 0x0A, remaining)
        let end: Int
        if let newlinePointer {
          end = base.distance(to: newlinePointer.assumingMemoryBound(to: UInt8.self))
        } else {
          end = rawBuffer.count
        }
        lineNumber += 1
        try body(data[start..<end], lineNumber)
        guard end < rawBuffer.count else { return }
        start = end + 1
      }
    }
  }

  private func abbreviated(_ url: URL) -> String {
    let home = homeDirectory.path
    return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
  }
}

public enum LocalUsageServiceError: LocalizedError {
  case emptyCredential

  public var errorDescription: String? {
    switch self {
    case .emptyCredential: "Enter an OpenRouter API key before saving."
    }
  }
}

private struct OpenCodeUsageDatabase {
  let databaseURL: URL

  func samples(cutoff: Date, now: Date) throws -> [UsageSample] {
    var database: OpaquePointer?
    let status = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
    guard status == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw OpenCodeUsageDatabaseError.openFailed
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 500)

    let sql = """
      SELECT p.id, p.session_id, m.data, p.data, s.directory
      FROM part p
      JOIN message m ON m.id = p.message_id
      LEFT JOIN session s ON s.id = p.session_id
      WHERE json_valid(p.data)
        AND json_valid(m.data)
        AND json_extract(p.data, '$.type') = 'step-finish'
        AND COALESCE(json_extract(m.data, '$.time.completed'),
                     json_extract(m.data, '$.time.created'), m.time_created) >= ?
        AND COALESCE(json_extract(m.data, '$.time.completed'),
                     json_extract(m.data, '$.time.created'), m.time_created) <= ?
      ORDER BY m.time_created ASC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { throw OpenCodeUsageDatabaseError.queryFailed }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970 * 1_000))
    sqlite3_bind_int64(statement, 2, Int64(now.timeIntervalSince1970 * 1_000))

    var samples: [UsageSample] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let partID = text(statement, column: 0),
            let sessionID = text(statement, column: 1),
            let messageJSON = text(statement, column: 2),
            let partJSON = text(statement, column: 3) else { continue }
      if let sample = LocalUsageTranscriptParser.parseOpenCode(
        partID: partID,
        sessionID: sessionID,
        messageJSON: messageJSON,
        partJSON: partJSON,
        workspace: text(statement, column: 4)
      ) {
        samples.append(sample)
      }
    }
    return samples
  }

  private func text(_ statement: OpaquePointer, column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
  }
}

private enum OpenCodeUsageDatabaseError: Error {
  case openFailed
  case queryFailed
}

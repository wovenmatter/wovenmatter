import Darwin
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

public enum UsageRefreshReason: String, Codable, Equatable, Sendable {
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

public struct CodexUsageWorkspace: Codable, Equatable, Identifiable, Sendable {
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

/// A display selection for Usage; it never changes inference account preferences.
public struct UsageConnectionChoice: Codable, Equatable, Identifiable, Sendable {
  public let provider: ProviderKind
  public let connectionID: String
  public let accountID: String
  public let label: String
  public let preferred: Bool
  public var id: String { connectionID + ":" + accountID }

  public static func connectionTypes(for provider: ProviderKind) -> [(String, String)] {
    switch provider {
    case .codex: [("openai-codex", "ChatGPT"), ("openai", "API key")]
    case .claude: [("claude-subscription", "Claude"), ("anthropic", "API key")]
    case .grok: [("xai", "Grok"), ("xai-api", "API key")]
    case .openRouter: [("openrouter", "API key")]
    case .openCodeGo: [("opencode-go", "API key")]
    case .cursor: [("cursor", "Cursor")]
    case .unknown: []
    }
  }

  public static func resolve(_ choices: [Self], selectedID: String?) -> Self? {
    choices.first { $0.id == selectedID } ?? choices.first { $0.preferred } ?? choices.first
  }
}

public struct LocalUsageLimitsSnapshot: Equatable, Sendable {
  public let accounts: [UsageLimitAccount]
  public let hasOpenRouterCredential: Bool
  public let codexWorkspaces: [CodexUsageWorkspace]
  public let selectedCodexWorkspaceID: String?
  public let connectionChoices: [UsageConnectionChoice]
  public let selectedConnections: [String: String]

  public init(
    accounts: [UsageLimitAccount],
    hasOpenRouterCredential: Bool,
    codexWorkspaces: [CodexUsageWorkspace] = [],
    selectedCodexWorkspaceID: String? = nil,
    connectionChoices: [UsageConnectionChoice] = [],
    selectedConnections: [String: String] = [:]
  ) {
    self.accounts = accounts
    self.hasOpenRouterCredential = hasOpenRouterCredential
    self.codexWorkspaces = codexWorkspaces
    self.selectedCodexWorkspaceID = selectedCodexWorkspaceID
    self.connectionChoices = connectionChoices
    self.selectedConnections = selectedConnections
  }
}

struct UsageLimitsRequest: Sendable {
  let homeDirectory: URL
  let allowCredentialAccess: Bool
  let openRouterAPIKey: String?
  let enabledProviders: Set<ProviderKind>
  let keychainInteraction: UsageKeychainInteraction
  let interactiveProvider: ProviderKind?
  let codexWorkspaceSource: CodexWorkspaceSource?
  let codexWorkspaceCount: Int
  let now: Date
  var selectedConnections: [ProviderKind: UsageConnectionChoice] = [:]

  func collect(sharedCredentials: [String: DefaultAgentCredential]? = nil,
               claudeStatus: BuiltInClaudeSignIn.Status? = nil) async -> [UsageLimitAccount] {
    await ProviderLimitCollector.collect(
      homeDirectory: homeDirectory,
      openRouterAPIKey: openRouterAPIKey,
      enabledProviders: enabledProviders,
      keychainInteraction: keychainInteraction,
      interactiveProvider: interactiveProvider,
      codexWorkspaceSource: codexWorkspaceSource,
      codexWorkspaceCount: codexWorkspaceCount,
      sharedCredentials: sharedCredentials,
      selectedConnections: selectedConnections,
      claudeStatus: claudeStatus,
      now: now
    )
  }
}

public actor LocalUsageService {
  private typealias ImportOutcome = UsageTranscriptImporter.Outcome

  private static let parserVersion = "usage-index-v3"
  private static let retention: TimeInterval = 120 * 24 * 60 * 60
  private static let localRefreshInterval: TimeInterval = 5 * 60
  private static let viewRefreshInterval: TimeInterval = 60
  private static let remoteRefreshInterval: TimeInterval = 15 * 60

  private let homeDirectory: URL
  private let fileManager: FileManager
  private let credentialStore: any UsageCredentialStoring
  private let databaseURL: URL
  private let usesSharedConnections: Bool
  private let limitCollector: @Sendable (UsageLimitsRequest) async -> [UsageLimitAccount]
  private let openRouterActivityFetcher: @Sendable (String) async throws -> OpenRouterActivityResult
  private var limitsGeneration = UUID()
  private var analyticsGeneration = UUID()
  private var usageStore: AsyncUsageStore?
  private var usageStoreOpening: Task<AsyncUsageStore, any Error>?
  private var usageStoreFailure: String?
  private var cachedLimits: (
    date: Date,
    providers: Set<ProviderKind>,
    codexWorkspaceID: String?,
    connectionRevision: UInt64,
    selectedConnections: [String: String],
    accounts: [UsageLimitAccount]
  )?
  private var importOutcomes: [String: ImportOutcome] = [:]
  // A successful read or explicit save authorizes this app session. Do not ask
  // Keychain again during the refresh triggered by a one-time Allow response.
  private var openRouterAPIKey: String?
  private var openRouterCredentialRevision = DefaultAgentSupport.revision
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
    usesSharedConnections = true
    limitCollector = { request in
      var credentials = request.allowCredentialAccess ? ((try? await ProviderAccountCoordinator.shared.appCredentials()) ?? [:]) : [:]
      if request.allowCredentialAccess {
        for choice in request.selectedConnections.values {
          if let credential = try? ProviderConnectionAccounts.credential(choice.accountID, provider: choice.connectionID, scope: "global") {
            credentials[choice.connectionID] = credential.borrowing()
          } else {
            credentials.removeValue(forKey: choice.connectionID)
          }
        }
      }
      let claudeStatus = request.allowCredentialAccess && request.enabledProviders.contains(.claude)
        ? try? await BuiltInClaudeSignIn.status(profile: credentials["claude-subscription"]?.accountId) : nil
      return await request.collect(sharedCredentials: credentials, claudeStatus: claudeStatus)
    }
    openRouterActivityFetcher = { try await OpenRouterActivityClient.fetch(apiKey: $0) }
    databaseURL = usageDatabaseURL ?? homeDirectory.appending(
      path: "Library/Application Support/Woven Matter/workspace.sqlite"
    )
  }

  init(
    homeDirectory: URL,
    fileManager: FileManager,
    credentialStore: any UsageCredentialStoring,
    usageDatabaseURL: URL,
    usesSharedConnections: Bool = false,
    limitCollector: @escaping @Sendable (UsageLimitsRequest) async -> [UsageLimitAccount] = {
      await $0.collect()
    },
    openRouterActivityFetcher: @escaping @Sendable (String) async throws -> OpenRouterActivityResult = {
      try await OpenRouterActivityClient.fetch(apiKey: $0)
    }
  ) {
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    self.credentialStore = credentialStore
    self.usesSharedConnections = usesSharedConnections
    self.limitCollector = limitCollector
    self.openRouterActivityFetcher = openRouterActivityFetcher
    databaseURL = usageDatabaseURL
  }

  public func snapshot(
    range: UsageTimeRange,
    refreshLimits: Bool = false,
    refreshReason: UsageRefreshReason = .manual,
    enabledProviders: Set<ProviderKind> = Set(ProviderKind.supportedAccounts),
    allowCredentialAccess: Bool = true,
    now: Date = Date()
  ) async throws -> LocalUsageSnapshot {
    let analytics = try await analyticsSnapshot(
      range: range,
      refreshReason: refreshReason,
      enabledProviders: enabledProviders,
      allowCredentialAccess: allowCredentialAccess,
      now: now
    )
    let analyticsID = analyticsGeneration
    let limits = try await limitsSnapshot(
      refresh: refreshLimits,
      refreshReason: refreshReason,
      enabledProviders: enabledProviders,
      allowCredentialAccess: allowCredentialAccess,
      now: now
    )
    guard isCurrentAnalytics(analyticsID) else { throw CancellationError() }
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
    interactiveProvider: ProviderKind? = nil,
    selectedCodexWorkspaceID: String? = nil,
    selectedConnections: [String: String] = [:],
    now: Date = Date()
  ) async throws -> LocalUsageLimitsSnapshot {
    try Task.checkCancellation()
    var connectionChoices: [UsageConnectionChoice] = []
    if usesSharedConnections && allowCredentialAccess {
      for provider in ProviderKind.supportedAccounts where enabledProviders.contains(provider) {
        for (type, title) in UsageConnectionChoice.connectionTypes(for: provider) {
          for account in (try? ProviderConnectionAccounts.list(provider: type, scope: "global")) ?? [] {
            connectionChoices.append(UsageConnectionChoice(provider: provider, connectionID: type,
              accountID: account.id, label: "\(title) · \(account.label)", preferred: account.isSelected))
          }
        }
      }
    }
    var resolvedConnections: [ProviderKind: UsageConnectionChoice] = [:]
    for provider in enabledProviders {
      resolvedConnections[provider] = UsageConnectionChoice.resolve(
        connectionChoices.filter { $0.provider == provider }, selectedID: selectedConnections[provider.rawValue])
    }
    let selectionIDs = Dictionary(uniqueKeysWithValues: resolvedConnections.map { ($0.key.rawValue, $0.value.id) })
    let connectionRevision = DefaultAgentSupport.revision
    let generation = UUID()
    limitsGeneration = generation
    let codexSources = !usesSharedConnections && enabledProviders.contains(.codex)
      ? ProviderLimitCollector.codexWorkspaceSources(homeDirectory: homeDirectory)
      : []
    let selectedCodexSource = ProviderLimitCollector.resolveCodexWorkspaceSource(
      codexSources,
      selectedID: selectedCodexWorkspaceID
    )
    let resolvedCodexWorkspaceID = selectedCodexSource?.workspace.id
    let accounts: [UsageLimitAccount]
    let mayReuseFreshLimits = refreshReason != .manual
      && refreshReason != .credentialChanged
    if let cachedLimits,
       cachedLimits.providers == enabledProviders,
       cachedLimits.selectedConnections == selectionIDs,
       (!usesSharedConnections || cachedLimits.connectionRevision == connectionRevision),
       cachedLimits.codexWorkspaceID == resolvedCodexWorkspaceID,
       (!refresh || (mayReuseFreshLimits
         && now.timeIntervalSince(cachedLimits.date) < 60)) {
      accounts = cachedLimits.accounts
    } else {
      // Shared account switches must never inherit a previous account or harness
      // snapshot. Their live limits are cheap to re-fetch; keep only this session
      // cache, fenced by the shared connection revision.
      let sharedProviders: Set<ProviderKind> = usesSharedConnections ? Set(ProviderKind.supportedAccounts) : []
      let persistent = (try? await openUsageStore()?.usageLimitAccounts(
        providers: enabledProviders.subtracting(sharedProviders),
        accountScopes: resolvedCodexWorkspaceID.map { [.codex: $0] } ?? [:]
      )) ?? []
      let persistentByProvider = Dictionary(
        uniqueKeysWithValues: persistent.map { ($0.provider, $0) }
      )
      if refresh {
        var openRouterAPIKey: String?
        var credentialError: String?
        if allowCredentialAccess && enabledProviders.contains(.openRouter) {
          do {
            openRouterAPIKey = try loadOpenRouterAPIKey()
          } catch {
            credentialError = error.localizedDescription
          }
        }
        let refreshed = await limitCollector(UsageLimitsRequest(
          homeDirectory: homeDirectory,
          allowCredentialAccess: allowCredentialAccess,
          openRouterAPIKey: openRouterAPIKey,
          enabledProviders: enabledProviders,
          keychainInteraction: keychainInteraction,
          interactiveProvider: interactiveProvider,
          codexWorkspaceSource: selectedCodexSource,
          codexWorkspaceCount: codexSources.count,
          now: now,
          selectedConnections: resolvedConnections
        ))
        guard limitsGeneration == generation, !Task.isCancelled,
              !usesSharedConnections || connectionRevision == DefaultAgentSupport.revision else {
          throw CancellationError()
        }
        accounts = refreshed.map { refreshedAccount in
          let account: UsageLimitAccount
          if refreshedAccount.provider == .openRouter, let credentialError {
            account = UsageLimitAccount(
              provider: .openRouter,
              accountLabel: refreshedAccount.accountLabel,
              status: .unavailable,
              source: "Mac Keychain",
              detail: credentialError,
              observedAt: now
            )
          } else {
            account = refreshedAccount
          }
          guard account.status == .failed || account.status == .unavailable,
                let prior = persistentByProvider[account.provider]
          else { return account }
          return prior.retainingLastGood(after: account)
        }
        try? await openUsageStore()?.saveUsageLimitAccounts(accounts, storedAt: now)
        cachedLimits = (now, enabledProviders, resolvedCodexWorkspaceID, connectionRevision, selectionIDs, accounts)
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
    }
    return LocalUsageLimitsSnapshot(
      accounts: accounts,
      hasOpenRouterCredential: allowCredentialAccess
        && enabledProviders.contains(.openRouter)
        && (openRouterAPIKey != nil || (try? credentialStore.hasOpenRouterAPIKey()) == true),
      codexWorkspaces: codexSources.map(\.workspace),
      selectedCodexWorkspaceID: resolvedCodexWorkspaceID,
      connectionChoices: connectionChoices,
      selectedConnections: selectionIDs
    )
  }

  public func analyticsSnapshot(
    range: UsageTimeRange,
    refreshReason: UsageRefreshReason = .manual,
    enabledProviders: Set<ProviderKind> = Set(ProviderKind.supportedAccounts),
    allowCredentialAccess: Bool = true,
    now: Date = Date()
  ) async throws -> UsageAnalyticsSnapshot {
    try Task.checkCancellation()
    let generation = UUID()
    analyticsGeneration = generation
    let interval = range.interval(relativeTo: now)
    guard let store = await openUsageStore() else {
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

    guard isCurrentAnalytics(generation) else { throw CancellationError() }
    let requestedImportCutoff = max(
      now.addingTimeInterval(-Self.retention),
      interval.start.addingTimeInterval(-36 * 60 * 60)
    )
    if await shouldImportLocal(
      store: store,
      reason: refreshReason,
      requestedCutoff: requestedImportCutoff,
      now: now
    ) {
      guard isCurrentAnalytics(generation) else { throw CancellationError() }
      if await importLocalSources(
        store: store,
        cutoff: requestedImportCutoff,
        enabledProviders: enabledProviders,
        now: now
      ) {
        guard isCurrentAnalytics(generation) else { throw CancellationError() }
        try? await store.setMetadataDate(now, for: "usage.local-import-at")
        let previousCutoff = try? await store.metadataDate("usage.local-indexed-after")
        try? await store.setMetadataDate(
          min(previousCutoff ?? requestedImportCutoff, requestedImportCutoff),
          for: "usage.local-indexed-after"
        )
        try? await store.prune(before: now.addingTimeInterval(-Self.retention))
      }
    }
    if enabledProviders.contains(.openRouter),
       allowCredentialAccess,
       await shouldImportOpenRouter(store: store, reason: refreshReason, now: now) {
      await importOpenRouterActivity(store: store, generation: generation, now: now)
      guard isCurrentAnalytics(generation) else { throw CancellationError() }
      try? await store.setMetadataDate(now, for: "usage.openrouter-attempt-at")
    }
    if enabledProviders.contains(.cursor),
       await shouldImportCursorAccount(store: store, reason: refreshReason, now: now) {
      await importCursorAccountActivity(
        store: store,
        cutoff: now.addingTimeInterval(-Self.retention),
        generation: generation,
        now: now
      )
      guard isCurrentAnalytics(generation) else { throw CancellationError() }
      try? await store.setMetadataDate(now, for: "usage.cursor-attempt-at")
    }
    guard isCurrentAnalytics(generation) else { throw CancellationError() }
    let storedSamples = ((try? await store.samples(in: interval)) ?? []).filter {
      enabledProviders.contains($0.provider)
    }
    let samples = Self.reconcileOpenRouter(
      deduplicated(storedSamples)
    ).sorted { lhs, rhs in
      lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp < rhs.timestamp
    }
    return await UsageAnalyticsSnapshot(
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
    openRouterAPIKey = key
    limitsGeneration = UUID()
    analyticsGeneration = UUID()
    cachedLimits = nil
    openRouterStatus = .unavailable
    openRouterDetail = "The new credential has not been checked yet."
  }

  /// Agent reads use only the existing index. They never refresh a provider,
  /// inspect credentials, ingest transcripts or change usage preferences.
  public func recordedSamples(from start: Date, to end: Date, limit: Int = 101, offset: Int = 0) async throws -> [UsageSample] {
    guard start <= end, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
          (1...201).contains(limit), offset >= 0 else { throw WorkspaceToolError.invalid("Invalid usage range or pagination.") }
    guard let store = await openUsageStore() else {
      throw WorkspaceToolError.invalid(usageStoreFailure ?? "The recorded usage index is unavailable.")
    }
    return try await store.samples(in: DateInterval(start: start, end: end), limit: limit, offset: offset)
  }

  public func deleteOpenRouterAPIKey() throws {
    try credentialStore.deleteOpenRouterAPIKey()
    openRouterAPIKey = nil
    limitsGeneration = UUID()
    analyticsGeneration = UUID()
    cachedLimits = nil
    openRouterStatus = .unavailable
    openRouterDetail = "Add an OpenRouter management key to import official account activity."
  }

  /// Explicit saved-credential recovery. Never launches Claude or a sign-in flow.
  public func authorizeClaudeCredentialAccess() throws {
    try ProviderLimitCollector.authorizeClaudeCredentialAccess(
      credentialsURL: ProviderLimitCollector.claudeCredentialsURL(homeDirectory: homeDirectory)
    )
    cachedLimits = nil
  }

  public func authorizeOpenRouterCredentialAccess() throws {
    guard let key = try credentialStore.authorizeOpenRouterAPIKey() else {
      openRouterAPIKey = nil
      limitsGeneration = UUID()
      analyticsGeneration = UUID()
      cachedLimits = nil
      throw LocalUsageServiceError.missingCredential
    }
    openRouterAPIKey = key
    limitsGeneration = UUID()
    analyticsGeneration = UUID()
    cachedLimits = nil
  }

  private func loadOpenRouterAPIKey() throws -> String? {
    let revision = DefaultAgentSupport.revision
    if revision != openRouterCredentialRevision {
      openRouterAPIKey = nil; openRouterCredentialRevision = revision
    }
    if let openRouterAPIKey { return openRouterAPIKey }
    let key = try credentialStore.loadOpenRouterAPIKey()
    openRouterAPIKey = key
    return key
  }

  private func openUsageStore() async -> AsyncUsageStore? {
    if let usageStore { return usageStore }
    if usageStoreFailure != nil { return nil }
    let opening: Task<AsyncUsageStore, any Error>
    if let pending = usageStoreOpening { opening = pending }
    else {
      let url = databaseURL
      opening = Task { try await AsyncUsageStore(databaseURL: url) }
      usageStoreOpening = opening
    }
    do {
      let store = try await opening.value
      usageStore = store
      usageStoreOpening = nil
      return store
    } catch {
      usageStoreOpening = nil
      // Queue pressure and cancellation are retryable, not a corrupt index.
      if !(error is CancellationError), !(error is DatabaseWorkerError) {
        usageStoreFailure = error.localizedDescription
      }
      return nil
    }
  }

  private func shouldImportLocal(
    store: AsyncUsageStore,
    reason: UsageRefreshReason,
    requestedCutoff: Date,
    now: Date
  ) async -> Bool {
    let lastImport = try? await store.metadataDate("usage.local-import-at")
    let indexedAfter = try? await store.metadataDate("usage.local-indexed-after")
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
    store: AsyncUsageStore,
    reason: UsageRefreshReason,
    now: Date
  ) async -> Bool {
    let lastAttempt = try? await store.metadataDate("usage.openrouter-attempt-at")
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
    store: AsyncUsageStore,
    reason: UsageRefreshReason,
    now: Date
  ) async -> Bool {
    let lastAttempt = try? await store.metadataDate("usage.cursor-attempt-at")
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
    store: AsyncUsageStore,
    cutoff: Date,
    generation: UUID,
    now: Date
  ) async {
    do {
      let activity = try await CursorAccountClient(homeDirectory: homeDirectory)
        .activity(since: cutoff, until: now)
      guard isCurrentAnalytics(generation) else { return }
      let retainedInterval = DateInterval(
        start: now.addingTimeInterval(-Self.retention),
        end: now
      )
      let retained = (try? await store.samples(in: retainedInterval, sourceID: "cursor:account")) ?? []
      var samplesByEvent = Dictionary(
        uniqueKeysWithValues: retained.map { ($0.sourceEventID, $0) }
      )
      for sample in activity.samples {
        samplesByEvent[sample.sourceEventID] = sample
      }
      try await store.replace(
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
      guard isCurrentAnalytics(generation) else { return }
      cursorAccountStatus = .unavailable
      cursorAccountDetail = "Sign in to Cursor.app to import account-wide usage from all devices."
    } catch {
      guard isCurrentAnalytics(generation) else { return }
      cursorAccountStatus = .partial
      cursorAccountDetail = "Cursor account refresh failed: \(error.localizedDescription) Persisted history remains available."
    }
  }

  private func importLocalSources(store: AsyncUsageStore, cutoff: Date,
    enabledProviders: Set<ProviderKind>, now: Date) async -> Bool {
    let home = homeDirectory
    let outcomes = importOutcomes
    do {
      let result = try await store.write { connection in
        let importer = UsageTranscriptImporter(homeDirectory: home, fileManager: FileManager(), outcomes: outcomes)
        let succeeded = importer.run(store: connection, cutoff: cutoff, enabledProviders: enabledProviders, now: now)
        return (succeeded, importer.importOutcomes)
      }
      importOutcomes = result.1
      return result.0
    } catch {
      importOutcomes["wovenmatter:index"] = .init(failures: 1)
      return false
    }
  }

  private func isCurrentAnalytics(_ generation: UUID) -> Bool {
    analyticsGeneration == generation && !Task.isCancelled
  }

  private func importOpenRouterActivity(store: AsyncUsageStore, generation: UUID, now: Date) async {
    do {
      guard let key = try loadOpenRouterAPIKey() else {
        openRouterStatus = .unavailable
        openRouterDetail = "Add an OpenRouter management key to import official account activity."
        return
      }
      let activity = try await openRouterActivityFetcher(key)
      guard isCurrentAnalytics(generation) else { return }
      for (date, samples) in activity.samplesByUTCDate {
        try await store.replace(
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
      guard isCurrentAnalytics(generation) else { return }
      openRouterStatus = error is OpenRouterActivityError ? .partial : .failed
      openRouterDetail = error.localizedDescription
    }
  }

  private func coverage(
    store: AsyncUsageStore,
    interval: DateInterval,
    enabledProviders: Set<ProviderKind>,
    allowCredentialAccess: Bool
  ) async -> [UsageSourceCoverage] {
    var sources: [UsageSourceCoverage] = []
    if enabledProviders.contains(.codex) { await sources.append(sourceCoverage(
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
    if enabledProviders.contains(.claude) { await sources.append(sourceCoverage(
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
    if enabledProviders.contains(.grok) { await sources.append(sourceCoverage(
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
    if enabledProviders.contains(.openCodeGo) { await sources.append(sourceCoverage(
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
    if !enabledProviders.isEmpty { await sources.append(sourceCoverage(
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
    await sources.append(sourceCoverage(
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
    var hermes = await sourceCoverage(
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
      await sources.append(cursorCoverage(store: store, interval: interval))
    }

    if enabledProviders.contains(.openRouter) {
      let openRouterStats = try? await store.statistics(
        sourceIDPrefix: "openrouter:activity:",
        in: interval
      )
      let credentialPresence = Result {
        try allowCredentialAccess && (openRouterAPIKey != nil || credentialStore.hasOpenRouterAPIKey())
      }
      let remoteStatus: UsageSourceStatus
      let remoteDetail: String
      switch credentialPresence {
      case .success(true):
        remoteStatus = openRouterStatus
        remoteDetail = openRouterDetail
      case .success(false):
        remoteStatus = (openRouterStats?.events ?? 0) > 0 ? .partial : .unavailable
        remoteDetail = allowCredentialAccess
          ? "Add an OpenRouter management key to refresh account activity. Previously imported activity remains available."
          : "Credential access is disabled. Previously imported OpenRouter activity remains available."
      case .failure(let error):
        remoteStatus = (openRouterStats?.events ?? 0) > 0 ? .partial : .unavailable
        remoteDetail = error.localizedDescription
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
    store: AsyncUsageStore,
    interval: DateInterval,
    detail: String
  ) async -> UsageSourceCoverage {
    let outcome = importOutcomes[prefix] ?? .empty
    let stats = try? await store.statistics(sourceIDPrefix: prefix, in: interval)
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
    store: AsyncUsageStore,
    interval: DateInterval
  ) async -> UsageSourceCoverage {
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
    let stats = try? await store.statistics(sourceID: "cursor:account", in: interval)
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

  private func abbreviated(_ url: URL) -> String {
    let home = homeDirectory.path
    return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
  }
}

public enum LocalUsageServiceError: LocalizedError {
  case emptyCredential
  case missingCredential

  public var errorDescription: String? {
    switch self {
    case .emptyCredential: "Enter an OpenRouter API key before saving."
    case .missingCredential: "No OpenRouter key is stored in Keychain. Save a key before retrying access."
    }
  }
}

struct OpenCodeUsageDatabase {
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
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return samples }
      guard status == SQLITE_ROW else { throw OpenCodeUsageDatabaseError.queryFailed }
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
  }

  private func text(_ statement: OpaquePointer, column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
  }
}

private enum OpenCodeUsageDatabaseError: Error {
  case openFailed
  case queryFailed
}

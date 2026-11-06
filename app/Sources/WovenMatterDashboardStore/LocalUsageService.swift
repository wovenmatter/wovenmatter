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
    case .cursor, .unknown: []
    }
  }

  public static func resolve(_ choices: [Self], selectedID: String?) -> Self? {
    choices.first { $0.id == selectedID } ?? choices.first { $0.preferred } ?? choices.first
  }
}

public struct LocalUsageLimitsSnapshot: Equatable, Sendable {
  public let accounts: [UsageLimitAccount]
  public let hasOpenRouterCredential: Bool
  public let connectionChoices: [UsageConnectionChoice]
  public let selectedConnections: [String: String]

  public init(
    accounts: [UsageLimitAccount],
    hasOpenRouterCredential: Bool,
    connectionChoices: [UsageConnectionChoice] = [],
    selectedConnections: [String: String] = [:]
  ) {
    self.accounts = accounts
    self.hasOpenRouterCredential = hasOpenRouterCredential
    self.connectionChoices = connectionChoices
    self.selectedConnections = selectedConnections
  }
}

struct UsageLimitsRequest: Sendable {
  let allowCredentialAccess: Bool
  let enabledProviders: Set<ProviderKind>
  let now: Date
  var selectedConnections: [ProviderKind: UsageConnectionChoice] = [:]

  func collect(sharedCredentials: [String: DefaultAgentCredential] = [:],
               claudeStatus: BuiltInClaudeSignIn.Status? = nil) async -> [UsageLimitAccount] {
    await ProviderLimitCollector.collect(
      enabledProviders: enabledProviders,
      sharedCredentials: sharedCredentials,
      selectedConnections: selectedConnections,
      claudeStatus: claudeStatus,
      now: now
    )
  }
}

public actor LocalUsageService {
  private typealias ImportOutcome = UsageTranscriptImporter.Outcome

  private static let localRefreshInterval: TimeInterval = 5 * 60
  private static let viewRefreshInterval: TimeInterval = 60
  private var deviceExportCache: (since: Date, records: [UsageDeviceRecord])?

  private let homeDirectory: URL
  private let fileManager: FileManager
  private let credentialStore: any UsageCredentialStoring
  private let databaseURL: URL
  private let importPreparationWorker: DatabaseWorker?
  private let sharedConnectionRevision: @Sendable () -> UInt64
  private let sharedConnectionChoices: @Sendable (Set<ProviderKind>) throws -> [UsageConnectionChoice]
  private let limitCollector: @Sendable (UsageLimitsRequest) async -> [UsageLimitAccount]
  private var limitsGeneration = UsageRefreshOwnership() { didSet { oldValue.invalidate() } }
  private var analyticsGeneration = UsageRefreshOwnership() { didSet { oldValue.invalidate() } }
  private var usageStore: AsyncUsageStore?
  private struct StoreOpening {
    let id = UUID()
    let task: Task<AsyncUsageStore, any Error>
  }
  private var usageStoreOpening: StoreOpening?
  private var usageStoreFailure: String?
  private var cachedLimits: (
    date: Date,
    providers: Set<ProviderKind>,
    connectionRevision: UInt64,
    selectedConnections: [String: String],
    accounts: [UsageLimitAccount]
  )?
  private var importOutcomes: [String: ImportOutcome] = [:]
  // A successful read or explicit save authorizes this app session. Do not ask
  // Keychain again during the refresh triggered by a one-time Allow response.
  private var openRouterAPIKey: String?

  public init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    credentialService: String = WovenMatterKeychainService.current + ".usage",
    usageDatabaseURL: URL? = nil
  ) {
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    credentialStore = UsageCredentialStore(service: credentialService)
    importPreparationWorker = nil
    sharedConnectionRevision = { DefaultAgentSupport.revision }
    sharedConnectionChoices = { providers in
      try ProviderKind.supportedAccounts.filter { providers.contains($0) }.flatMap { provider in
        try UsageConnectionChoice.connectionTypes(for: provider).flatMap { type, title in
          try ProviderConnectionAccounts.list(provider: type, scope: "global").map { account in
            UsageConnectionChoice(provider: provider, connectionID: type, accountID: account.id,
              label: "\(title) · \(account.label)", preferred: account.isSelected)
          }
        }
      }
    }
    limitCollector = { request in
      guard request.allowCredentialAccess else {
        return request.enabledProviders.map { provider in
          UsageLimitAccount(provider: provider, accountLabel: provider.displayName, status: .unavailable,
            source: "Saved accounts", detail: "Enable Keychain access in Settings → General to check saved accounts.",
            observedAt: request.now)
        }
      }
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
        && credentials["claude-subscription"] != nil
        ? try? await BuiltInClaudeSignIn.status(profile: credentials["claude-subscription"]?.accountId) : nil
      return await request.collect(sharedCredentials: credentials, claudeStatus: claudeStatus)
    }
    databaseURL = usageDatabaseURL ?? homeDirectory.appending(
      path: "Library/Application Support/Woven Matter/workspace.sqlite"
    )
  }

  init(
    homeDirectory: URL,
    fileManager: FileManager,
    credentialStore: any UsageCredentialStoring,
    usageDatabaseURL: URL,
    sharedConnectionRevision: @escaping @Sendable () -> UInt64 = { DefaultAgentSupport.revision },
    sharedConnectionChoices: @escaping @Sendable (Set<ProviderKind>) throws -> [UsageConnectionChoice] = { _ in [] },
    importPreparationWorker: DatabaseWorker? = nil,
    limitCollector: @escaping @Sendable (UsageLimitsRequest) async -> [UsageLimitAccount] = {
      await $0.collect()
    }
  ) {
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    self.credentialStore = credentialStore
    self.importPreparationWorker = importPreparationWorker
    self.sharedConnectionRevision = sharedConnectionRevision
    self.sharedConnectionChoices = sharedConnectionChoices
    self.limitCollector = limitCollector
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

  public func limitsSnapshot(
    refresh: Bool,
    refreshReason: UsageRefreshReason = .manual,
    enabledProviders: Set<ProviderKind> = [],
    allowCredentialAccess: Bool = true,
    selectedConnections: [String: String] = [:],
    now: Date = Date()
  ) async throws -> LocalUsageLimitsSnapshot {
    try Task.checkCancellation()
    let connectionChoices = allowCredentialAccess ? try sharedConnectionChoices(enabledProviders) : []
    var resolvedConnections: [ProviderKind: UsageConnectionChoice] = [:]
    for provider in enabledProviders {
      resolvedConnections[provider] = UsageConnectionChoice.resolve(
        connectionChoices.filter { $0.provider == provider }, selectedID: selectedConnections[provider.rawValue])
    }
    let selectionIDs = Dictionary(uniqueKeysWithValues: resolvedConnections.map { ($0.key.rawValue, $0.value.id) })
    let connectionRevision = sharedConnectionRevision()
    let generation = makeRefreshOwnership()
    limitsGeneration = generation
    let accounts: [UsageLimitAccount]
    let mayReuseFreshLimits = refreshReason != .manual
      && refreshReason != .credentialChanged
    if let cachedLimits,
       cachedLimits.providers == enabledProviders,
       cachedLimits.selectedConnections == selectionIDs,
       cachedLimits.connectionRevision == connectionRevision,
       (!refresh || (mayReuseFreshLimits
         && now.timeIntervalSince(cachedLimits.date) < 60)) {
      accounts = cachedLimits.accounts
    } else if refresh {
      // Shared account switches must never inherit a previous account or harness
      // snapshot. Their live limits are cheap to re-fetch; keep only this session
      // cache, fenced by the shared connection revision.
      let requests = enabledProviders.sorted(by: { $0.rawValue < $1.rawValue }).flatMap { provider in
        let choices = connectionChoices.filter { $0.provider == provider }
        let selections: [[ProviderKind: UsageConnectionChoice]] = choices.isEmpty
          ? [[:]] : choices.map { [provider: $0] }
        return selections.map { selection in
          UsageLimitsRequest(allowCredentialAccess: allowCredentialAccess, enabledProviders: [provider],
            now: now, selectedConnections: selection)
        }
      }
      let collector = limitCollector
      accounts = try await withThrowingTaskGroup(of: (Int, [UsageLimitAccount]).self) { group in
        for (index, request) in requests.enumerated() {
          group.addTask {
            try generation.check()
            let accounts = await collector(request)
            try generation.check()
            return (index, accounts)
          }
        }
        var results: [(Int, [UsageLimitAccount])] = []
        for try await value in group { results.append(value) }
        return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
      }
      try checkCurrentLimits(generation, connectionRevision: connectionRevision)
      cachedLimits = (now, enabledProviders, connectionRevision, selectionIDs, accounts)
    } else {
      accounts = ProviderLimitCollector.placeholderAccounts(
        enabledProviders: enabledProviders,
        now: now
      )
    }
    try checkCurrentLimits(generation, connectionRevision: connectionRevision)
    return LocalUsageLimitsSnapshot(
      accounts: accounts,
      hasOpenRouterCredential: allowCredentialAccess
        && enabledProviders.contains(.openRouter)
        && (openRouterAPIKey != nil || (try? credentialStore.hasOpenRouterAPIKey()) == true),
      connectionChoices: connectionChoices,
      selectedConnections: selectionIDs
    )
  }

  private func checkCurrentLimits(_ generation: UsageRefreshOwnership, connectionRevision: UInt64) throws {
    try generation.check()
    guard limitsGeneration === generation, !Task.isCancelled,
          connectionRevision == sharedConnectionRevision() else {
      throw CancellationError()
    }
  }

  public func analyticsSnapshot(
    range: UsageTimeRange,
    refreshReason: UsageRefreshReason = .manual,
    now: Date = Date(),
    onHistoryProgress: (@Sendable (UsageHistoryImportProgress, UsageAnalyticsSnapshot?) async -> Void)? = nil
  ) async throws -> UsageAnalyticsSnapshot {
    try Task.checkCancellation()
    let generation = UsageRefreshOwnership()
    analyticsGeneration = generation
    let interval = range.interval(relativeTo: now)
    // Device analytics never depends on account-limit preferences or Keychain access.
    let localProviders = Set(ProviderKind.allCases)
    guard let store = await openUsageStore() else {
      guard isCurrentAnalytics(generation) else { throw CancellationError() }
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
    // Index all history once, whatever range is showing. Harnesses may delete old
    // transcripts, so this index is kept as the lasting record of past usage.
    let requestedImportCutoff = Date.usageHistoryStart
    if await shouldImportLocal(
      store: store,
      reason: refreshReason,
      requestedCutoff: requestedImportCutoff,
      now: now
    ) {
      guard isCurrentAnalytics(generation) else { throw CancellationError() }
      let indexedAfter = try? await store.metadataDate("usage.local-indexed-after")
      let isFirstFullImport = (indexedAfter ?? nil).map { $0 > requestedImportCutoff } ?? true
      var batches = [UsageTranscriptImporter.Batch?.none]
      if isFirstFullImport {
        // Newest files first, so usage appears quickly and fills in going back.
        var newer: Date?
        batches = (UsageHistoryImportProgress.stages.map { $0.duration ?? 0 } + [nil]).map { duration in
          let after = duration.map { now.addingTimeInterval(-$0) } ?? requestedImportCutoff
          defer { newer = after }
          return .init(modifiedAfter: after, modifiedBefore: newer)
        }
        await onHistoryProgress?(.init(covered: nil), nil)
        guard isCurrentAnalytics(generation) else { throw CancellationError() }
      }
      var isComplete = true
      for (index, batch) in batches.enumerated() {
        let finished = await importLocalSources(
          store: store,
          cutoff: requestedImportCutoff,
          enabledProviders: localProviders,
          generation: generation,
          now: now,
          batch: batch
        )
        isComplete = isComplete && finished
        guard isCurrentAnalytics(generation) else { throw CancellationError() }
        // The whole import lane is unavailable, so the next refresh picks up from here.
        if importOutcomes["wovenmatter:index"] != nil { break }
        if isFirstFullImport, index < UsageHistoryImportProgress.stages.count {
          await onHistoryProgress?(
            .init(covered: UsageHistoryImportProgress.stages[index]),
            await storedAnalytics(store: store, range: range, interval: interval, providers: localProviders, now: now)
          )
          guard isCurrentAnalytics(generation) else { throw CancellationError() }
        }
      }
      if isComplete {
        guard isCurrentAnalytics(generation) else { throw CancellationError() }
        try? await store.write(validating: { try generation.check() }) { connection in
          try connection.performTransaction {
            let previousCutoff = try connection.metadataDate("usage.local-indexed-after")
            try connection.setMetadataDate(now, for: "usage.local-import-at")
            try connection.setMetadataDate(min(previousCutoff ?? requestedImportCutoff, requestedImportCutoff),
              for: "usage.local-indexed-after")
          }
        }
      }
    }
    guard isCurrentAnalytics(generation) else { throw CancellationError() }
    let snapshot = await storedAnalytics(store: store, range: range, interval: interval, providers: localProviders, now: now)
    guard isCurrentAnalytics(generation) else { throw CancellationError() }
    return snapshot
  }

  /// What the index holds for this range right now.
  private func storedAnalytics(
    store: AsyncUsageStore,
    range: UsageTimeRange,
    interval: DateInterval,
    providers: Set<ProviderKind>,
    now: Date
  ) async -> UsageAnalyticsSnapshot {
    let storedSamples = ((try? await store.samples(in: interval)) ?? []).filter {
      // Legacy account-wide API imports are not activity on this device.
      !$0.sourceID.hasPrefix("openrouter:activity:")
    }
    let samples = Self.reconcileOpenRouter(
      deduplicated(storedSamples)
    ).sorted { lhs, rhs in
      lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp < rhs.timestamp
    }
    let sources = await coverage(store: store, interval: interval, enabledProviders: providers)
    return UsageAnalyticsSnapshot(range: range, generatedAt: now, samples: samples, sources: sources)
  }

  // MARK: - Linked devices

  private static let deviceExportPageSize = 2_000
  private static let deviceRecentWindow: TimeInterval = 3 * 24 * 60 * 60

  /// This Mac's usage for another device to read: counts and labels per hour, with
  /// no transcript content or file paths. Account-wide sources are left out because
  /// every Mac would otherwise count them again.
  public func deviceExport(
    _ request: UsageDeviceExportRequest,
    relaying relayed: [UsageDeviceIdentity] = [],
    now: Date = Date()
  ) async throws -> UsageDeviceExportPage {
    guard let store = await openUsageStore() else {
      throw WorkspaceToolError.invalid(usageStoreFailure ?? "The recorded usage index is unavailable.")
    }
    // Whole hours only. A partial hour would replace the complete total stored for it.
    let requested = Date(timeIntervalSince1970: max(0, request.since))
    let since = max(Calendar.current.dateInterval(of: .hour, for: requested)?.start ?? requested, .usageHistoryStart)
    let records: [UsageDeviceRecord]
    if request.offset > 0, let cached = deviceExportCache, cached.since == since {
      records = cached.records
    } else {
      let relayedIDs = Set(relayed.map(\.id))
      let stored = try await store.samples(in: DateInterval(start: since, end: max(since, now))).filter {
        guard !$0.sourceID.hasPrefix("openrouter:activity:"), $0.sourceID != "cursor:account" else { return false }
        return $0.usageDeviceID == UsageDeviceSource.localDeviceID || relayedIDs.contains($0.usageDeviceID)
      }
      let compact = UsageAnalyticsSnapshot(
        range: .allTime,
        generatedAt: now,
        samples: Self.reconcileOpenRouter(deduplicated(stored)),
        sources: []
      ).compacted(by: .hour)
      records = compact.samples.map(UsageDeviceRecord.init(sample:)).sorted { $0.timestamp < $1.timestamp }
      deviceExportCache = (since, records)
    }
    let offset = max(0, request.offset)
    let page = records.dropFirst(offset).prefix(Self.deviceExportPageSize)
    let hasMore = offset + page.count < records.count
    if !hasMore { deviceExportCache = nil }
    return UsageDeviceExportPage(
      state: .ready,
      generatedAt: now.timeIntervalSince1970,
      records: Array(page),
      hasMore: hasMore,
      nextOffset: offset + page.count,
      devices: relayed
    )
  }

  public func storedDeviceSummaries() async -> [(identity: UsageDeviceIdentity, syncedAt: Date)] {
    guard let store = await openUsageStore() else { return [] }
    return (try? await store.storedDevices()) ?? []
  }

  /// Reads everything a device has to report and stores it under that device.
  /// A partial read stores nothing, so a dropped connection can't lose usage.
  public func collectDeviceUsage(
    from endpoint: UsageDeviceEndpoint,
    now: Date = Date()
  ) async -> UsageDeviceSummary {
    let identity = endpoint.identity
    guard let store = await openUsageStore() else {
      return .init(identity: identity, state: .unavailable, detail: usageStoreFailure)
    }
    let previous = try? await store.storedDevices().first { $0.identity.id == identity.id }?.syncedAt
    let fullKey = "usage.device-full.\(identity.id)"
    let lastFull = try? await store.metadataDate(fullKey)
    // Recent days can still change as sessions finish. A daily full pass catches the rest.
    let isFull = endpoint.alwaysFull || (lastFull ?? nil).map { now.timeIntervalSince($0) >= 24 * 60 * 60 } ?? true
    let since = isFull ? Date.usageHistoryStart : (previous ?? nil).map { $0.addingTimeInterval(-Self.deviceRecentWindow) } ?? .usageHistoryStart
    // A Mac's index is a lasting record, so its report replaces everything. Hosts and
    // phones report only what they still hold, so older rows here outlive their copies.
    let replaceFrom = endpoint.keepsLastingHistory ? since : max(since, now.addingTimeInterval(-Self.deviceRecentWindow))
    do {
      var records: [UsageDeviceRecord] = []
      var relayed: [UsageDeviceIdentity] = []
      var offset = 0
      for _ in 0..<10_000 {
        try Task.checkCancellation()
        let page = try await endpoint.fetch(.init(since: since.timeIntervalSince1970, offset: offset))
        guard page.records.count <= UsageDeviceExportPage.maximumRecords else {
          throw UsageDeviceCollectionError.invalidPage
        }
        if page.state == .scanning {
          return .init(identity: identity, state: .scanning, syncedAt: previous ?? nil)
        }
        records += page.records
        relayed += page.devices ?? []
        guard page.hasMore else { break }
        guard page.nextOffset > offset else { throw UsageDeviceCollectionError.invalidPage }
        offset = page.nextOffset
      }
      let byDevice = Dictionary(grouping: records) { $0.device ?? identity.id }
      for id in Set([identity.id]).union(byDevice.keys) {
        // A relaying Mac may only speak for the devices it listed.
        let target = id == identity.id ? identity : relayed.first { $0.id == id }
        guard let target, !endpoint.excludedRelays.contains(id) else { continue }
        let samples = (byDevice[id] ?? []).compactMap { $0.sample(deviceID: target.id) }
        try await store.write { connection in
          try connection.replaceDeviceEvents(device: target, since: replaceFrom, samples: samples, importedAt: now)
          if isFull { try connection.setMetadataDate(now, for: fullKey) }
        }
      }
      return .init(identity: identity, state: .synced, syncedAt: now)
    } catch let error as UsageDeviceCollectionError where error == .updateRequired {
      return .init(identity: identity, state: .updateRequired, syncedAt: previous ?? nil)
    } catch {
      return .init(identity: identity, state: .unavailable, syncedAt: previous ?? nil, detail: error.localizedDescription)
    }
  }

  public func saveOpenRouterAPIKey(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw LocalUsageServiceError.emptyCredential }
    try credentialStore.saveOpenRouterAPIKey(key)
    openRouterAPIKey = key
    limitsGeneration = UsageRefreshOwnership()
    cachedLimits = nil
  }

  /// Agent reads use only the existing index. They never refresh a provider,
  /// inspect credentials, ingest transcripts or change usage preferences.
  public func recordedSamples(from start: Date, to end: Date, limit: Int = 101, offset: Int = 0) async throws -> [UsageSample] {
    guard start <= end, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
          (1...201).contains(limit), offset >= 0 else { throw WorkspaceToolError.invalid("Invalid usage range or pagination.") }
    guard let store = await openUsageStore() else {
      throw WorkspaceToolError.invalid(usageStoreFailure ?? "The recorded usage index is unavailable.")
    }
    // Agents and phones read what this Mac recorded, including runs it watched on a
    // remote workspace. Usage reported by other devices stays on the Usage page.
    return try await store.samples(in: DateInterval(start: start, end: end), limit: limit, offset: offset, excludingDevices: true)
  }

  public func deleteOpenRouterAPIKey() throws {
    try credentialStore.deleteOpenRouterAPIKey()
    openRouterAPIKey = nil
    limitsGeneration = UsageRefreshOwnership()
    cachedLimits = nil
  }

  public func authorizeOpenRouterCredentialAccess() throws {
    guard let key = try credentialStore.authorizeOpenRouterAPIKey() else {
      openRouterAPIKey = nil
      limitsGeneration = UsageRefreshOwnership()
      cachedLimits = nil
      throw LocalUsageServiceError.missingCredential
    }
    openRouterAPIKey = key
    limitsGeneration = UsageRefreshOwnership()
    cachedLimits = nil
  }

  private func openUsageStore() async -> AsyncUsageStore? {
    if let usageStore { return usageStore }
    if usageStoreFailure != nil { return nil }
    let opening: StoreOpening
    if let pending = usageStoreOpening { opening = pending }
    else {
      let url = databaseURL
      opening = StoreOpening(task: Task { try await AsyncUsageStore(databaseURL: url) })
      usageStoreOpening = opening
    }
    do {
      let store = try await opening.task.value
      usageStore = store
      if usageStoreOpening?.id == opening.id { usageStoreOpening = nil }
      return store
    } catch {
      // Multiple waiters can resume after another caller already started a retry.
      guard usageStoreOpening?.id == opening.id else { return usageStore }
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

  private func importLocalSources(store: AsyncUsageStore, cutoff: Date,
    enabledProviders: Set<ProviderKind>, generation: UsageRefreshOwnership, now: Date,
    batch: UsageTranscriptImporter.Batch? = nil) async -> Bool {
    let home = homeDirectory
    let outcomes = importOutcomes
    do {
      let importer = UsageTranscriptImporter(homeDirectory: home, outcomes: outcomes, ownership: generation,
        preparationWorker: importPreparationWorker)
      let complete = try await importer.run(store: store, cutoff: cutoff, enabledProviders: enabledProviders, now: now, batch: batch)
      let updatedOutcomes = await importer.importOutcomes
      guard isCurrentAnalytics(generation) else { return false }
      importOutcomes = updatedOutcomes
      return complete
    } catch {
      guard isCurrentAnalytics(generation) else { return false }
      importOutcomes["wovenmatter:index"] = .init(failures: 1)
      return false
    }
  }

  private func makeRefreshOwnership() -> UsageRefreshOwnership {
    UsageRefreshOwnership(connectionRevision: sharedConnectionRevision(), currentRevision: sharedConnectionRevision)
  }

  private func isCurrentAnalytics(_ generation: UsageRefreshOwnership) -> Bool {
    guard analyticsGeneration === generation, !Task.isCancelled else { return false }
    do { try generation.check(); return true } catch { return false }
  }

  private func coverage(
    store: AsyncUsageStore,
    interval: DateInterval,
    enabledProviders: Set<ProviderKind>
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

  /// Each device is deduplicated on its own, so identical keys on two devices never
  /// move usage from one to the other.
  private func deduplicated(_ samples: [UsageSample]) -> [UsageSample] {
    Dictionary(grouping: samples, by: \.usageDeviceID).values.flatMap { device in
      Self.droppingCoveredLiveRuns(deduplicatedWithinDevice(device))
    }
  }

  private func deduplicatedWithinDevice(_ samples: [UsageSample]) -> [UsageSample] {
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

  /// A host's own history already includes the runs this Mac saw it perform. Those
  /// live observations only stand in for harnesses the host's history doesn't cover.
  static func droppingCoveredLiveRuns(_ samples: [UsageSample]) -> [UsageSample] {
    let scannedHarnesses = Set(samples.filter { !$0.isRemoteLiveRun }.map(\.harness))
    return samples.filter { !$0.isRemoteLiveRun || !scannedHarnesses.contains($0.harness) }
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

  func samples(cutoff: Date, now: Date,
    check: @escaping @Sendable () throws -> Void = {}) throws -> [UsageSample] {
    try check()
    var database: OpaquePointer?
    let status = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
    guard status == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw OpenCodeUsageDatabaseError.openFailed
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 500)
    let cancellation = UsageSourceQueryCancellation(check)
    cancellation.install(on: database)
    defer { cancellation.remove(from: database) }

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
      try check()
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

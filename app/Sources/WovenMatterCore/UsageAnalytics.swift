import Foundation

public enum UsageTimeRange: String, CaseIterable, Codable, Identifiable, Sendable {
  case today
  case yesterday
  case last24Hours
  case last7Days
  case last30Days
  case last90Days
  case allTime

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .last24Hours: "24 hours"
    case .last7Days: "7 days"
    case .last30Days: "30 days"
    case .last90Days: "90 days"
    case .allTime: "All time"
    }
  }

  public var compactLabel: String {
    switch self {
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .last24Hours: "24H"
    case .last7Days: "7D"
    case .last30Days: "30D"
    case .last90Days: "90D"
    case .allTime: "All"
    }
  }

  public var duration: TimeInterval? {
    switch self {
    case .today, .yesterday, .allTime: nil
    case .last24Hours: 24 * 60 * 60
    case .last7Days: 7 * 24 * 60 * 60
    case .last30Days: 30 * 24 * 60 * 60
    case .last90Days: 90 * 24 * 60 * 60
    }
  }

  public var usesHourlyBuckets: Bool {
    self == .today || self == .yesterday || self == .last24Hours
  }

  public func interval(
    relativeTo date: Date,
    calendar: Calendar = .current
  ) -> DateInterval {
    switch self {
    case .today:
      return DateInterval(start: calendar.startOfDay(for: date), end: date)
    case .yesterday:
      let today = calendar.startOfDay(for: date)
      let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        ?? today.addingTimeInterval(-24 * 60 * 60)
      return DateInterval(start: yesterday, end: today)
    case .allTime:
      return DateInterval(start: .usageHistoryStart, end: max(date, .usageHistoryStart))
    case .last24Hours, .last7Days, .last30Days, .last90Days:
      return DateInterval(
        start: date.addingTimeInterval(-(duration ?? 0)),
        end: date
      )
    }
  }

}

/// How far a full history import has reached. History is read newest first in widening
/// batches, so recent usage appears within moments and older usage follows.
public struct UsageHistoryImportProgress: Codable, Equatable, Sendable {
  public static let stages: [UsageTimeRange] = [.last24Hours, .last7Days, .last30Days, .last90Days]

  /// The widest period fully read so far. Nil before the first batch finishes.
  public let covered: UsageTimeRange?

  public init(covered: UsageTimeRange?) {
    self.covered = covered
  }

  public func covers(_ range: UsageTimeRange, now: Date = Date(), calendar: Calendar = .current) -> Bool {
    guard let duration = covered?.duration else { return false }
    return range.interval(relativeTo: now, calendar: calendar).start >= now.addingTimeInterval(-duration)
  }
}

public extension Date {
  /// Earlier than any usage record, so All time and full imports cover everything.
  static let usageHistoryStart = Date(timeIntervalSince1970: 0)
}

public enum UsageAttributionConfidence: String, Codable, Sendable {
  case exact
  case derived
  case aggregate
  case unknown
}

public enum UsageGranularity: String, Codable, Sendable {
  case modelCall
  case turn
  case dailyAggregate
  case sessionAggregate
  case refreshDelta
}

public struct UsageModelIdentity: Codable, Equatable, Sendable {
  public let rawIdentifier: String
  public let canonicalName: String
  public let family: String
  public let publisher: String
  public let confidence: UsageAttributionConfidence

  public init(
    rawIdentifier: String,
    canonicalName: String,
    family: String,
    publisher: String,
    confidence: UsageAttributionConfidence
  ) {
    self.rawIdentifier = rawIdentifier
    self.canonicalName = canonicalName
    self.family = family
    self.publisher = publisher
    self.confidence = confidence
  }

  public static func resolve(_ value: String?) -> Self {
    let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty ?? "Unknown model"
    let lower = raw.lowercased()
    let modelPath = lower
      .replacingOccurrences(of: "accounts/fireworks/models/", with: "")
      .split(separator: "/").last.map(String.init) ?? lower
    let withoutOptions = modelPath.split(separator: "[").first.map(String.init)
      ?? modelPath
    let routed = withoutOptions.replacingOccurrences(of: "_", with: "-")
    let cursorRemainder = routed.hasPrefix("cursor-")
      ? String(routed.dropFirst("cursor-".count))
      : routed
    let normalized = ["gpt-", "claude-", "grok-", "glm-", "gemini-"]
      .contains(where: cursorRemainder.hasPrefix)
      ? cursorRemainder
      : routed

    let publisher: String = if lower.contains("anthropic") || normalized.hasPrefix("claude-") {
      "Anthropic"
    } else if lower.contains("openai") || normalized.hasPrefix("gpt-")
      || normalized.hasPrefix("o3") || normalized.hasPrefix("o4") {
      "OpenAI"
    } else if lower.contains("x-ai") || normalized.hasPrefix("grok-") {
      "xAI"
    } else if lower.contains("z-ai") || lower.contains("zhipu")
      || normalized.hasPrefix("glm-") {
      "Z.ai"
    } else if lower.contains("google") || normalized.hasPrefix("gemini-") {
      "Google"
    } else if lower.contains("cursor") || normalized.hasPrefix("composer-") {
      "Cursor"
    } else {
      "Unknown"
    }

    if normalized.hasPrefix("gpt-") {
      let pieces = normalized.split(separator: "-").map(String.init)
      let version = pieces.dropFirst().first ?? normalized.dropFirst(4).description
      let variant = pieces.dropFirst(2).first.flatMap { value -> String? in
        ["sol", "terra", "luna", "codex"].contains(value) ? value.capitalized : nil
      }
      let family = "GPT-\(version.uppercased())"
      return Self(
        rawIdentifier: raw,
        canonicalName: [family, variant].compactMap { $0 }.joined(separator: " "),
        family: family,
        publisher: publisher,
        confidence: .derived
      )
    }

    if normalized.hasPrefix("claude-") {
      let pieces = normalized.split(separator: "-").map(String.init)
      let namedTiers = ["opus", "sonnet", "haiku"]
      let tier: String
      let versionCandidates: ArraySlice<String>
      if pieces.count > 1, namedTiers.contains(pieces[1]) {
        tier = pieces[1].capitalized
        versionCandidates = pieces.dropFirst(2)
      } else if let tierIndex = pieces.indices.dropFirst().first(where: {
        namedTiers.contains(pieces[$0])
      }) {
        tier = pieces[tierIndex].capitalized
        versionCandidates = pieces[1..<tierIndex]
      } else {
        tier = pieces.count > 1 ? pieces[1].capitalized : "Unknown"
        versionCandidates = pieces.dropFirst(2)
      }
      var versionParts: [String] = []
      for part in versionCandidates.prefix(2) {
        guard Double(part) != nil, part.count <= 3 else { break }
        versionParts.append(part)
      }
      let version = versionParts.joined(separator: ".")
      let family = ["Claude", tier, version].filter { !$0.isEmpty }
        .joined(separator: " ")
      return Self(
        rawIdentifier: raw,
        canonicalName: family,
        family: family,
        publisher: publisher,
        confidence: .derived
      )
    }

    for prefix in ["glm-", "grok-", "gemini-"] where normalized.hasPrefix(prefix) {
      let pieces = normalized.split(separator: "-").map(String.init)
      let name = pieces.prefix(2).map { part in
        part == "glm" ? "GLM" : part.capitalized
      }.joined(separator: " ")
      return Self(
        rawIdentifier: raw,
        canonicalName: name,
        family: name,
        publisher: publisher,
        confidence: .derived
      )
    }

    return Self(
      rawIdentifier: raw,
      canonicalName: raw,
      family: raw,
      publisher: publisher,
      confidence: raw == "Unknown model" ? .unknown : .exact
    )
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

private func saturatedAdd<Value: FixedWidthInteger>(_ lhs: Value, _ rhs: Value) -> Value {
  let (value, overflow) = lhs.addingReportingOverflow(rhs)
  return overflow ? Value.max : value
}

public struct UsageTokenCounts: Codable, Equatable, Sendable {
  public let inputTokens: Int64
  public let cachedInputTokens: Int64
  public let cacheCreationTokens: Int64
  public let outputTokens: Int64
  public let reasoningTokens: Int64
  public let reportedTotalTokens: Int64?

  public init(
    inputTokens: Int64 = 0,
    cachedInputTokens: Int64 = 0,
    cacheCreationTokens: Int64 = 0,
    outputTokens: Int64 = 0,
    reasoningTokens: Int64 = 0,
    reportedTotalTokens: Int64? = nil
  ) {
    self.inputTokens = max(0, inputTokens)
    self.cachedInputTokens = max(0, cachedInputTokens)
    self.cacheCreationTokens = max(0, cacheCreationTokens)
    self.outputTokens = max(0, outputTokens)
    self.reasoningTokens = max(0, reasoningTokens)
    self.reportedTotalTokens = reportedTotalTokens.map { max(0, $0) }
  }

  public var totalTokens: Int64 {
    reportedTotalTokens
      ?? saturatedAdd(
        saturatedAdd(inputTokens, cachedInputTokens),
        saturatedAdd(cacheCreationTokens, outputTokens)
      )
  }

  public var totalInputTokens: Int64 {
    saturatedAdd(
      saturatedAdd(inputTokens, cachedInputTokens),
      cacheCreationTokens
    )
  }

  public static let zero = UsageTokenCounts()

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case cachedInputTokens = "cached_input_tokens"
    case cacheCreationTokens = "cache_creation_tokens"
    case outputTokens = "output_tokens"
    case reasoningTokens = "reasoning_tokens"
    case reportedTotalTokens = "reported_total_tokens"
  }

  public static func + (lhs: UsageTokenCounts, rhs: UsageTokenCounts) -> UsageTokenCounts {
    UsageTokenCounts(
      inputTokens: saturatedAdd(lhs.inputTokens, rhs.inputTokens),
      cachedInputTokens: saturatedAdd(lhs.cachedInputTokens, rhs.cachedInputTokens),
      cacheCreationTokens: saturatedAdd(lhs.cacheCreationTokens, rhs.cacheCreationTokens),
      outputTokens: saturatedAdd(lhs.outputTokens, rhs.outputTokens),
      reasoningTokens: saturatedAdd(lhs.reasoningTokens, rhs.reasoningTokens),
      reportedTotalTokens: saturatedAdd(lhs.totalTokens, rhs.totalTokens)
    )
  }
}

public struct UsageSample: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let provider: ProviderKind
  public let timestamp: Date
  public let sessionID: String
  public let accountLabel: String
  public let model: String
  public let canonicalModel: String
  public let modelFamily: String
  public let modelPublisher: String
  public let modelIdentityConfidence: UsageAttributionConfidence
  public let billingProvider: String
  public let billingRoute: String
  public let reasoningLevel: String?
  public let harness: String
  public let application: String
  public let agent: String?
  public let workspace: String?
  public let tokens: UsageTokenCounts
  public let requestCount: Int
  public let costUSD: Double?
  public let attributionConfidence: UsageAttributionConfidence
  public let granularity: UsageGranularity
  public let sourceID: String
  public let sourceEventID: String
  public let dedupeKey: String?

  /// Direct, usage-metered spend that the user is actually billed for.
  /// Subscription-backed providers may report API-equivalent or estimated
  /// values, which are intentionally excluded from product cost surfaces.
  public var directCostUSD: Double? {
    switch provider {
    case .openRouter, .openCodeGo:
      costUSD
    case .codex, .claude, .grok, .cursor, .unknown:
      nil
    }
  }

  public init(
    id: String,
    provider: ProviderKind,
    timestamp: Date,
    sessionID: String,
    accountLabel: String,
    model: String,
    billingProvider: String? = nil,
    billingRoute: String? = nil,
    reasoningLevel: String? = nil,
    harness: String,
    application: String,
    agent: String? = nil,
    workspace: String? = nil,
    tokens: UsageTokenCounts,
    requestCount: Int = 1,
    costUSD: Double? = nil,
    attributionConfidence: UsageAttributionConfidence = .exact,
    granularity: UsageGranularity = .modelCall,
    sourceID: String = "unknown",
    sourceEventID: String? = nil,
    dedupeKey: String? = nil
  ) {
    let identity = UsageModelIdentity.resolve(model)
    self.id = id
    self.provider = provider
    self.timestamp = timestamp
    self.sessionID = sessionID
    self.accountLabel = accountLabel
    self.model = model
    canonicalModel = identity.canonicalName
    modelFamily = identity.family
    modelPublisher = identity.publisher
    modelIdentityConfidence = identity.confidence
    self.billingProvider = billingProvider?.trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty ?? provider.displayName
    self.billingRoute = billingRoute?.trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty ?? accountLabel
    self.reasoningLevel = reasoningLevel
    self.harness = harness
    self.application = application
    self.agent = agent
    self.workspace = workspace
    self.tokens = tokens
    self.requestCount = max(1, requestCount)
    self.costUSD = costUSD
    self.attributionConfidence = attributionConfidence
    self.granularity = granularity
    self.sourceID = sourceID
    self.sourceEventID = sourceEventID ?? id
    self.dedupeKey = dedupeKey
  }
}

public enum UsageSourceStatus: String, Codable, Sendable {
  case available
  case partial
  case notFound
  case unavailable
  case failed
}

public struct UsageSourceCoverage: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let sourceName: String
  public let provider: ProviderKind
  public let harness: String?
  public let status: UsageSourceStatus
  public let location: String
  public let discoveredSessions: Int
  public let attributedSamples: Int
  public let detail: String

  public init(
    id: String? = nil,
    sourceName: String? = nil,
    provider: ProviderKind,
    harness: String? = nil,
    status: UsageSourceStatus,
    location: String,
    discoveredSessions: Int,
    attributedSamples: Int,
    detail: String
  ) {
    self.id = id ?? "\(provider.rawValue):\(location)"
    self.sourceName = sourceName ?? provider.displayName
    self.provider = provider
    self.harness = harness
    self.status = status
    self.location = location
    self.discoveredSessions = max(0, discoveredSessions)
    self.attributedSamples = max(0, attributedSamples)
    self.detail = detail
  }
}

public struct UsageAnalyticsSnapshot: Codable, Equatable, Sendable {
  public let range: UsageTimeRange
  public let generatedAt: Date
  public let samples: [UsageSample]
  public let sources: [UsageSourceCoverage]

  public init(
    range: UsageTimeRange,
    generatedAt: Date,
    samples: [UsageSample],
    sources: [UsageSourceCoverage]
  ) {
    self.range = range
    self.generatedAt = generatedAt
    self.samples = samples
    self.sources = sources
  }
}

extension UsageSample {
  /// The harness's current name for rows saved under an earlier one. Pi Durable ran
  /// as "Built-in" until October 2026.
  public static func currentHarnessName(_ name: String) -> String {
    name == "Built-in" ? AgentRuntimeKind.defaultAgent.displayName : name
  }
}

extension UsageAnalyticsSnapshot {
  /// Combines model calls that the Usage page cannot tell apart, so a long range
  /// stays small enough to send to the window and fast to filter. Every field the
  /// page filters, searches or attributes by stays separate, as does the period the
  /// graph draws it in. Totals, sessions, calls and costs are unchanged.
  public func compactedForDisplay(calendar: Calendar = .current) -> UsageAnalyticsSnapshot {
    compacted(by: range.usesHourlyBuckets ? .hour : .day, calendar: calendar)
  }

  /// `unit` is the shortest period a viewer of this data can still tell apart.
  public func compacted(by unit: Calendar.Component, calendar: Calendar = .current) -> UsageAnalyticsSnapshot {
    struct Key: Hashable {
      let period: Date
      let sourceID: String
      let sessionID: String
      let provider: ProviderKind
      let model: String
      let billingProvider: String
      let billingRoute: String
      let accountLabel: String
      let reasoningLevel: String?
      let harness: String
      let application: String
      let agent: String?
      let workspace: String?
      // A reported cost replaces list prices, so it must not spread to unreported calls.
      let hasCost: Bool
    }
    var groups: [Key: [UsageSample]] = [:]
    for sample in samples {
      let key = Key(
        period: calendar.dateInterval(of: unit, for: sample.timestamp)?.start ?? sample.timestamp,
        sourceID: sample.sourceID,
        sessionID: sample.sessionID,
        provider: sample.provider,
        model: sample.model,
        billingProvider: sample.billingProvider,
        billingRoute: sample.billingRoute,
        accountLabel: sample.accountLabel,
        reasoningLevel: sample.reasoningLevel,
        harness: sample.harness,
        application: sample.application,
        agent: sample.agent,
        workspace: sample.workspace,
        hasCost: sample.costUSD != nil
      )
      groups[key, default: []].append(sample)
    }
    let compacted = groups.values.compactMap { group -> UsageSample? in
      guard group.count > 1 else { return group.first }
      guard let latest = group.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
      let costs = group.compactMap(\.costUSD)
      return UsageSample(
        id: latest.id,
        provider: latest.provider,
        timestamp: latest.timestamp,
        sessionID: latest.sessionID,
        accountLabel: latest.accountLabel,
        model: latest.model,
        billingProvider: latest.billingProvider,
        billingRoute: latest.billingRoute,
        reasoningLevel: latest.reasoningLevel,
        harness: latest.harness,
        application: latest.application,
        agent: latest.agent,
        workspace: latest.workspace,
        tokens: group.reduce(.zero) { $0 + $1.tokens },
        requestCount: group.reduce(0) { saturatedAdd($0, $1.requestCount) },
        costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
        attributionConfidence: latest.attributionConfidence,
        granularity: .sessionAggregate,
        sourceID: latest.sourceID,
        sourceEventID: latest.sourceEventID
      )
    }
    return UsageAnalyticsSnapshot(
      range: range,
      generatedAt: generatedAt,
      samples: compacted.sorted { $0.timestamp > $1.timestamp },
      sources: sources
    )
  }
}

public struct UsageAnalyticsSummary: Equatable, Sendable {
  public let tokens: UsageTokenCounts
  public let sessions: Int
  public let requests: Int
  public let costUSD: Double?

  public init(samples: [UsageSample]) {
    tokens = samples.reduce(.zero) { $0 + $1.tokens }
    sessions = Set(samples.lazy.map { "\($0.sourceID):\($0.sessionID)" }).count
    requests = samples.reduce(0) { saturatedAdd($0, $1.requestCount) }
    let costs = samples.compactMap(\.directCostUSD)
    costUSD = costs.isEmpty ? nil : costs.reduce(0, +)
  }
}

public struct UsageBreakdownRow: Equatable, Identifiable, Sendable {
  public let label: String
  public let tokens: UsageTokenCounts
  public let requests: Int
  public let costUSD: Double?

  public var id: String { label }

  public init(label: String, samples: [UsageSample]) {
    self.label = label
    tokens = samples.reduce(.zero) { $0 + $1.tokens }
    requests = samples.reduce(0) { saturatedAdd($0, $1.requestCount) }
    let costs = samples.compactMap(\.directCostUSD)
    costUSD = costs.isEmpty ? nil : costs.reduce(0, +)
  }
}

public struct UsageModelRollup: Equatable, Identifiable, Sendable {
  public let family: String
  /// The provider carrying the most tokens for this model, which sets its color.
  public let provider: ProviderKind
  public let tokens: UsageTokenCounts
  public let requests: Int
  public let sessions: Int
  public let canonicalModels: [String]
  public let billingRoutes: [UsageBreakdownRow]
  public let accounts: [UsageBreakdownRow]
  public let harnesses: [UsageBreakdownRow]

  public var id: String { family }

  public init(family: String, samples: [UsageSample]) {
    self.family = family
    var tokensByProvider: [ProviderKind: Int64] = [:]
    for sample in samples {
      tokensByProvider[sample.provider] = saturatedAdd(
        tokensByProvider[sample.provider] ?? 0,
        sample.tokens.totalTokens
      )
    }
    let dominant = tokensByProvider.max { lhs, rhs in
      lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
    }
    provider = dominant?.key ?? .unknown
    tokens = samples.reduce(.zero) { $0 + $1.tokens }
    requests = samples.reduce(0) { saturatedAdd($0, $1.requestCount) }
    sessions = Set(samples.map { "\($0.sourceID):\($0.sessionID)" }).count
    canonicalModels = Array(Set(samples.map(\.canonicalModel))).sorted()
    billingRoutes = Self.rows(samples, by: { $0.billingRoute })
    accounts = Self.rows(samples, by: { $0.accountLabel })
    harnesses = Self.rows(samples, by: { $0.harness })
  }

  public static func aggregate(_ samples: [UsageSample]) -> [Self] {
    Dictionary(grouping: samples, by: \.modelFamily)
      .map { Self(family: $0.key, samples: $0.value) }
      .sorted { lhs, rhs in
        lhs.tokens.totalTokens == rhs.tokens.totalTokens
          ? lhs.family < rhs.family
          : lhs.tokens.totalTokens > rhs.tokens.totalTokens
      }
  }

  private static func rows(
    _ samples: [UsageSample],
    by key: (UsageSample) -> String
  ) -> [UsageBreakdownRow] {
    Dictionary(grouping: samples) {
      let value = key($0).trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? "Unknown" : value
    }
    .map { UsageBreakdownRow(label: $0.key, samples: $0.value) }
    .sorted { lhs, rhs in
      lhs.tokens.totalTokens == rhs.tokens.totalTokens
        ? lhs.label < rhs.label
        : lhs.tokens.totalTokens > rhs.tokens.totalTokens
    }
  }
}

public enum UsageLimitStatus: String, Codable, Sendable {
  case available
  case signedIn
  case needsCredential
  case unavailable
  case failed
}

public struct UsageLimitAccount: Codable, Equatable, Identifiable, Sendable {
  public let provider: ProviderKind
  public let accountScopeID: String?
  public let accountLabel: String
  public let status: UsageLimitStatus
  public let quotaWindows: [ProviderQuotaWindow]
  public let balance: ProviderMoney?
  public let providerBudget: ProviderReportedBudget?
  public let details: [ProviderUsageDetail]
  public let history: [ProviderUsageHistoryPoint]
  public let source: String
  public let detail: String
  public let observedAt: Date
  public let isStale: Bool
  public let refreshError: String?
  public let dashboardURL: URL?

  public var id: String { accountScopeID.map { provider.rawValue + ":" + $0 } ?? provider.rawValue }

  public init(
    provider: ProviderKind,
    accountScopeID: String? = nil,
    accountLabel: String,
    status: UsageLimitStatus,
    quotaWindows: [ProviderQuotaWindow] = [],
    balance: ProviderMoney? = nil,
    providerBudget: ProviderReportedBudget? = nil,
    details: [ProviderUsageDetail] = [],
    history: [ProviderUsageHistoryPoint] = [],
    source: String,
    detail: String,
    observedAt: Date = Date(),
    isStale: Bool = false,
    refreshError: String? = nil,
    dashboardURL: URL? = nil
  ) {
    self.provider = provider
    self.accountScopeID = accountScopeID
    self.accountLabel = accountLabel
    self.status = status
    self.quotaWindows = quotaWindows
    self.balance = balance
    self.providerBudget = providerBudget
    self.details = details
    self.history = history
    self.source = source
    self.detail = detail
    self.observedAt = observedAt
    self.isStale = isStale
    self.refreshError = refreshError
    self.dashboardURL = dashboardURL
  }
}

public struct LocalUsageSnapshot: Codable, Equatable, Sendable {
  public let analytics: UsageAnalyticsSnapshot
  public let limits: [UsageLimitAccount]
  public let hasOpenRouterCredential: Bool

  public init(
    analytics: UsageAnalyticsSnapshot,
    limits: [UsageLimitAccount],
    hasOpenRouterCredential: Bool
  ) {
    self.analytics = analytics
    self.limits = limits
    self.hasOpenRouterCredential = hasOpenRouterCredential
  }
}

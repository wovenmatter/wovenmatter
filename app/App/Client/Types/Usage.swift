import Foundation

/// A provider that usage is billed to, or that holds a subscription sign-in.
enum ProviderKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case codex
    case claude
    case grok
    case cursor
    case openCodeGo = "opencode-go"
    case openRouter = "openrouter"
    case unknown

    static let supportedAccounts: [ProviderKind] = [.codex, .claude, .grok, .openCodeGo, .openRouter]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex / OpenAI"
        case .claude: "Claude"
        case .grok: "Grok / xAI"
        case .cursor: "Cursor"
        case .openCodeGo: "OpenCode Go"
        case .openRouter: "OpenRouter"
        case .unknown: "Unknown"
        }
    }
}

enum UsageTimeRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case today
    case yesterday
    case last24Hours
    case last7Days
    case last30Days
    case last90Days
    case allTime

    var id: String { rawValue }

    var label: String {
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

    var compactLabel: String {
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

    var duration: TimeInterval? {
        switch self {
        case .today, .yesterday, .allTime: nil
        case .last24Hours: 24 * 60 * 60
        case .last7Days: 7 * 24 * 60 * 60
        case .last30Days: 30 * 24 * 60 * 60
        case .last90Days: 90 * 24 * 60 * 60
        }
    }

    var usesHourlyBuckets: Bool {
        self == .today || self == .yesterday || self == .last24Hours
    }

    func interval(relativeTo date: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .today:
            return DateInterval(start: calendar.startOfDay(for: date), end: date)
        case .yesterday:
            let today = calendar.startOfDay(for: date)
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-24 * 60 * 60)
            return DateInterval(start: yesterday, end: today)
        case .allTime:
            let start = Date(timeIntervalSince1970: 0)
            return DateInterval(start: start, end: max(date, start))
        case .last24Hours, .last7Days, .last30Days, .last90Days:
            return DateInterval(start: date.addingTimeInterval(-(duration ?? 0)), end: date)
        }
    }
}

/// How far reading past usage has reached. History is read newest first, so
/// recent usage appears at once and older usage follows.
struct UsageHistoryImportProgress: Hashable, Sendable {
    /// The widest period fully read so far. Nil before the first batch finishes.
    let covered: UsageTimeRange?

    func covers(_ range: UsageTimeRange, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let duration = covered?.duration else { return false }
        return range.interval(relativeTo: now, calendar: calendar).start >= now.addingTimeInterval(-duration)
    }
}

private func saturatedAdd<Value: FixedWidthInteger>(_ lhs: Value, _ rhs: Value) -> Value {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Value.max : value
}

struct UsageTokenCounts: Hashable, Sendable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheCreationTokens: Int64
    let outputTokens: Int64
    let reasoningTokens: Int64
    let reportedTotalTokens: Int64?

    init(inputTokens: Int64 = 0, cachedInputTokens: Int64 = 0, cacheCreationTokens: Int64 = 0,
         outputTokens: Int64 = 0, reasoningTokens: Int64 = 0, reportedTotalTokens: Int64? = nil) {
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheCreationTokens = max(0, cacheCreationTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningTokens = max(0, reasoningTokens)
        self.reportedTotalTokens = reportedTotalTokens.map { max(0, $0) }
    }

    static let zero = UsageTokenCounts()

    var totalTokens: Int64 {
        reportedTotalTokens
            ?? saturatedAdd(saturatedAdd(inputTokens, cachedInputTokens), saturatedAdd(cacheCreationTokens, outputTokens))
    }

    var totalInputTokens: Int64 {
        saturatedAdd(saturatedAdd(inputTokens, cachedInputTokens), cacheCreationTokens)
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: saturatedAdd(lhs.inputTokens, rhs.inputTokens),
            cachedInputTokens: saturatedAdd(lhs.cachedInputTokens, rhs.cachedInputTokens),
            cacheCreationTokens: saturatedAdd(lhs.cacheCreationTokens, rhs.cacheCreationTokens),
            outputTokens: saturatedAdd(lhs.outputTokens, rhs.outputTokens),
            reasoningTokens: saturatedAdd(lhs.reasoningTokens, rhs.reasoningTokens),
            reportedTotalTokens: saturatedAdd(lhs.totalTokens, rhs.totalTokens)
        )
    }
}

/// One usage record: tokens for one model call, turn or aggregate on one machine.
struct UsageSample: Identifiable, Hashable, Sendable {
    let id: String
    let provider: ProviderKind
    let timestamp: Date
    let sessionID: String
    let model: String
    let canonicalModel: String
    let modelFamily: String
    let billingProvider: String
    let billingRoute: String
    let reasoningLevel: String?
    let harness: String
    let application: String
    let agent: String?
    let workspace: String?
    let tokens: UsageTokenCounts
    let requestCount: Int
    /// What the provider reported, which for a subscription may be an API-equivalent figure.
    let costUSD: Double?
    let sourceID: String
    /// The machine the usage happened on.
    let machineID: String

    /// Usage-metered spend that is actually billed. Subscription providers'
    /// figures are left out of every cost the pages show.
    var directCostUSD: Double? {
        switch provider {
        case .openRouter, .openCodeGo: costUSD
        case .codex, .claude, .grok, .cursor, .unknown: nil
        }
    }
}

enum UsageSourceStatus: Hashable, Sendable {
    case available
    case partial
    case notFound
    case unavailable
    case failed
}

/// One place usage was read from, and how much it held.
struct UsageSourceCoverage: Identifiable, Hashable, Sendable {
    let id: String
    let sourceName: String
    let provider: ProviderKind
    let harness: String?
    let status: UsageSourceStatus
    let location: String
    let discoveredSessions: Int
    let attributedSamples: Int
    let detail: String
}

struct UsageAnalyticsSnapshot: Hashable, Sendable {
    let range: UsageTimeRange
    let generatedAt: Date
    let samples: [UsageSample]
    let sources: [UsageSourceCoverage]
}

// MARK: - Totals over the samples a filter leaves

struct UsageAnalyticsSummary: Hashable, Sendable {
    let tokens: UsageTokenCounts
    let sessions: Int
    let requests: Int
    let costUSD: Double?

    init(samples: [UsageSample]) {
        tokens = samples.reduce(.zero) { $0 + $1.tokens }
        sessions = Set(samples.lazy.map { "\($0.sourceID):\($0.sessionID)" }).count
        requests = samples.reduce(0) { saturatedAdd($0, $1.requestCount) }
        let costs = samples.compactMap(\.directCostUSD)
        costUSD = costs.isEmpty ? nil : costs.reduce(0, +)
    }
}

struct UsageBreakdownRow: Identifiable, Hashable, Sendable {
    let label: String
    let tokens: UsageTokenCounts
    let requests: Int

    var id: String { label }

    init(label: String, samples: [UsageSample]) {
        self.label = label
        tokens = samples.reduce(.zero) { $0 + $1.tokens }
        requests = samples.reduce(0) { saturatedAdd($0, $1.requestCount) }
    }
}

struct UsageModelRollup: Identifiable, Hashable, Sendable {
    let family: String
    /// The provider carrying the most tokens for this model, which sets its color.
    let provider: ProviderKind
    let tokens: UsageTokenCounts
    let requests: Int
    let sessions: Int
    let canonicalModels: [String]
    let billingRoutes: [UsageBreakdownRow]
    let harnesses: [UsageBreakdownRow]

    var id: String { family }

    init(family: String, samples: [UsageSample]) {
        self.family = family
        var tokensByProvider: [ProviderKind: Int64] = [:]
        for sample in samples {
            tokensByProvider[sample.provider] = saturatedAdd(tokensByProvider[sample.provider] ?? 0, sample.tokens.totalTokens)
        }
        let dominant = tokensByProvider.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }
        provider = dominant?.key ?? .unknown
        tokens = samples.reduce(.zero) { $0 + $1.tokens }
        requests = samples.reduce(0) { saturatedAdd($0, $1.requestCount) }
        sessions = Set(samples.map { "\($0.sourceID):\($0.sessionID)" }).count
        canonicalModels = Array(Set(samples.map(\.canonicalModel))).sorted()
        billingRoutes = Self.rows(samples) { $0.billingRoute }
        harnesses = Self.rows(samples) { $0.harness }
    }

    static func aggregate(_ samples: [UsageSample]) -> [Self] {
        Dictionary(grouping: samples, by: \.modelFamily)
            .map { Self(family: $0.key, samples: $0.value) }
            .sorted { lhs, rhs in
                lhs.tokens.totalTokens == rhs.tokens.totalTokens
                    ? lhs.family < rhs.family
                    : lhs.tokens.totalTokens > rhs.tokens.totalTokens
            }
    }

    private static func rows(_ samples: [UsageSample], by key: (UsageSample) -> String) -> [UsageBreakdownRow] {
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

// MARK: - Limits

enum UsageLimitStatus: Hashable, Sendable {
    case available
    case signedIn
    case needsCredential
    case unavailable
    case failed
}

struct ProviderQuotaWindow: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let remainingPercent: Double
    let usageKnown: Bool
    let windowMinutes: Int?
    let resetsAt: Date?
    let resetDescription: String?
}

struct ProviderMoney: Hashable, Sendable {
    let amountMicros: Int64
    let currency: String
}

struct ProviderReportedBudget: Hashable, Sendable {
    let usedMicros: Int64
    let limitMicros: Int64
    let remainingMicros: Int64
    let usedPercent: Double
    let currency: String
    let period: String?
}

struct ProviderUsageDetail: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct ProviderUsageHistoryPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let valueMicros: Int64

    var id: Date { date }
}

/// A provider account with its quota windows, balance and budget.
struct UsageLimitAccount: Identifiable, Hashable, Sendable {
    let provider: ProviderKind
    let accountScopeID: String?
    let accountLabel: String
    let status: UsageLimitStatus
    let quotaWindows: [ProviderQuotaWindow]
    let balance: ProviderMoney?
    let providerBudget: ProviderReportedBudget?
    let details: [ProviderUsageDetail]
    let history: [ProviderUsageHistoryPoint]
    let source: String
    let detail: String
    let isStale: Bool
    let refreshError: String?
    let dashboardURL: URL?

    var id: String { accountScopeID.map { provider.rawValue + ":" + $0 } ?? provider.rawValue }

    init(provider: ProviderKind, accountScopeID: String? = nil, accountLabel: String, status: UsageLimitStatus,
         quotaWindows: [ProviderQuotaWindow] = [], balance: ProviderMoney? = nil,
         providerBudget: ProviderReportedBudget? = nil, details: [ProviderUsageDetail] = [],
         history: [ProviderUsageHistoryPoint] = [], source: String, detail: String,
         isStale: Bool = false, refreshError: String? = nil, dashboardURL: URL? = nil) {
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
        self.isStale = isStale
        self.refreshError = refreshError
        self.dashboardURL = dashboardURL
    }
}

/// What the Usage pages show for the selected range: records and provider limits.
struct UsageSnapshot: Hashable, Sendable {
    let analytics: UsageAnalyticsSnapshot
    let limits: [UsageLimitAccount]
}

// MARK: - Machines

enum UsageMachineSyncState: Hashable, Sendable {
    case thisMachine
    case synced
    /// The machine is still reading its usage history.
    case scanning
    case waiting
    case updateRequired
    case unavailable
}

/// What the Usage page shows for one machine. A stale or unreachable machine
/// says so, because missing usage must never read as zero.
struct UsageMachineSummary: Identifiable, Hashable, Sendable {
    /// The machine id, which `UsageSample.machineID` matches.
    let id: String
    let name: String
    let state: UsageMachineSyncState
    let syncedAt: Date?
    let detail: String?
}

// MARK: - API list prices

/// USD per token for one model at public API list prices.
struct UsageTokenRate: Hashable, Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
}

/// What usage would cost at API list prices. An estimate for comparison, never a bill.
struct UsageCostEstimate: Hashable, Sendable {
    var input = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0
    var output = 0.0
    /// A provider-reported cost for a model without a list price cannot be split by token type.
    var reported = 0.0
    var cacheSavings = 0.0
    var pricedTokens: Int64 = 0
    var unpricedTokens: Int64 = 0

    var total: Double { input + cacheRead + cacheWrite + output + reported }
    var hasPrice: Bool { pricedTokens > 0 || total > 0 }

    /// The share of tokens left out of the estimate because no price is known.
    var unpricedShare: Double {
        let tokens = Double(pricedTokens) + Double(unpricedTokens)
        return tokens > 0 ? Double(unpricedTokens) / tokens : 0
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        var sum = lhs
        sum.input += rhs.input
        sum.cacheRead += rhs.cacheRead
        sum.cacheWrite += rhs.cacheWrite
        sum.output += rhs.output
        sum.reported += rhs.reported
        sum.cacheSavings += rhs.cacheSavings
        sum.pricedTokens = saturatedAdd(sum.pricedTokens, rhs.pricedTokens)
        sum.unpricedTokens = saturatedAdd(sum.unpricedTokens, rhs.unpricedTokens)
        return sum
    }
}

/// Model prices keyed by lowercased model identifier, as the server supplies them.
struct UsageRateTable: Hashable, Sendable {
    let rates: [String: UsageTokenRate]

    // Synthetic messages are unbilled, and bare tier names do not identify a generation.
    private static let unpriceableModels: Set<String> = ["<synthetic>", "synthetic", "opus", "sonnet", "haiku", "fable"]

    /// Unknown models return nil rather than a guess, so they show as unpriced.
    func rate(forModel model: String) -> UsageTokenRate? {
        var key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Bracketed context variants such as [1m] are priced at the base tier.
        if let bracket = key.firstIndex(of: "[") { key = String(key[..<bracket]) }
        let bare = key.split(separator: "/").last.map(String.init) ?? key
        guard !bare.isEmpty, !Self.unpriceableModels.contains(bare) else { return nil }
        if let rate = rates[key] ?? rates[bare] { return rate }
        let routed = bare.hasPrefix("cursor-") ? String(bare.dropFirst("cursor-".count)) : bare
        if let rate = rates[routed] { return rate }
        let undated = routed.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        return rates[undated] ?? rates[undated.replacingOccurrences(of: ".", with: "-")]
    }

    /// Prefers a cost the provider reported, then list prices. Reasoning tokens are
    /// part of output tokens, so they are not charged a second time.
    func estimate(_ samples: some Sequence<UsageSample>) -> UsageCostEstimate {
        var rateByModel: [String: UsageTokenRate?] = [:]
        var total = UsageCostEstimate()
        for sample in samples {
            let rate: UsageTokenRate?
            if let known = rateByModel[sample.model] {
                rate = known
            } else {
                rate = self.rate(forModel: sample.model)
                rateByModel[sample.model] = rate
            }
            total = total + estimate(sample, rate: rate)
        }
        return total
    }

    private func estimate(_ sample: UsageSample, rate: UsageTokenRate?) -> UsageCostEstimate {
        var estimate = UsageCostEstimate()
        let tokens = sample.tokens
        // A cost of zero means no charge on this plan, not that the model has no list price.
        let reported = sample.costUSD.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard let rate else {
            if let reported {
                estimate.reported = reported
                estimate.pricedTokens = tokens.totalTokens
            } else {
                estimate.unpricedTokens = tokens.totalTokens
            }
            return estimate
        }
        let input = Double(tokens.inputTokens) * rate.input
        let cacheRead = Double(tokens.cachedInputTokens) * rate.cacheRead
        let cacheWrite = Double(tokens.cacheCreationTokens) * rate.cacheWrite
        let output = Double(tokens.outputTokens) * rate.output
        let list = input + cacheRead + cacheWrite + output
        estimate.pricedTokens = tokens.totalTokens
        if let reported, list <= 0 {
            estimate.reported = reported
            return estimate
        }
        let scale = reported.map { $0 / list } ?? 1
        estimate.input = input * scale
        estimate.cacheRead = cacheRead * scale
        estimate.cacheWrite = cacheWrite * scale
        estimate.output = output * scale
        estimate.cacheSavings = Double(tokens.cachedInputTokens) * max(0, rate.input - rate.cacheRead) * scale
        return estimate
    }
}

/// The price table and whether it is loading or failed.
struct UsagePriceState: Hashable, Sendable {
    var table: UsageRateTable?
    var fetchedAt: Date?
    var isLoading = false
    var error: String?
}

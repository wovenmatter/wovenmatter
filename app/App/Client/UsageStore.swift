import Foundation
import Observation
import WovenProtocol

/// Usage records, analytics, provider limits, per-machine usage and the price table.
/// This Mac's server sums every machine's synced records, which cover every harness on
/// that machine, inside Woven Matter or not; limits are this Mac's own sign-ins.
@MainActor
@Observable
final class UsageStore {
    /// Records and limits for the selected range. Nil until the server first answers.
    private(set) var snapshot: UsageSnapshot?
    /// The last failure to read usage or limits.
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var isRefreshingLimits = false
    /// Every machine whose usage the pages include, this machine first.
    private(set) var machines: [UsageMachineSummary] = []
    private(set) var prices = UsagePriceState()
    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var machineStore: MachinesStore?
    @ObservationIgnored private var limits: [UsageLimitAccount] = []
    @ObservationIgnored private var limitsRead = false

    init() {}

    func attach(_ server: ServerConnection, machines: MachinesStore) {
        self.server = server
        machineStore = machines
    }

    /// Usage opened: read the selected range.
    func destinationAppeared(range: UsageTimeRange) async {
        await refresh(range: range, refreshLimits: !limitsRead)
    }

    /// The Analytics page was chosen.
    func analyticsSelected(range: UsageTimeRange) async {
        await refresh(range: range)
    }

    /// Re-reads usage for the range, and provider limits when asked.
    func refresh(range: UsageTimeRange, refreshLimits: Bool = false) async {
        guard let server, server.isConnected else {
            error = ClientError.notConnected.localizedDescription
            return
        }
        isRefreshing = true
        if refreshLimits { isRefreshingLimits = true }
        defer { isRefreshing = false; isRefreshingLimits = false }
        let now = Date()
        let interval = range.interval(relativeTo: now)
        do {
            let report = try await server.call(ReadUsage(start: interval.start, end: interval.end.addingTimeInterval(1),
                                                         periodSeconds: range.usesHourlyBuckets ? 3600 : 86_400))
            if refreshLimits {
                limits = try await server.call(ReadUsageLimits()).map(Self.account)
                limitsRead = true
            }
            let names = Dictionary((machineStore?.machines ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let samples = report.groups.enumerated().map { Self.sample($1, index: $0) }
            let sources = Dictionary(grouping: samples, by: \.machineID).map { machineID, values in
                UsageSourceCoverage(id: machineID, sourceName: names[machineID] ?? "Removed machine", provider: .unknown, harness: nil,
                                    status: .available, location: "Woven library",
                                    discoveredSessions: Set(values.map(\.sessionID)).count, attributedSamples: values.count, detail: "")
            }.sorted { $0.sourceName < $1.sourceName }
            snapshot = UsageSnapshot(
                analytics: UsageAnalyticsSnapshot(range: range, generatedAt: now, samples: samples, sources: sources),
                limits: limits)
            machines = summaries(report)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads the API list-price table, again when `force` is set.
    func loadPrices(force: Bool = false) async {
        guard force || (prices.table == nil && !prices.isLoading) else { return }
        guard let server, server.isConnected else {
            prices.error = ClientError.notConnected.localizedDescription
            return
        }
        prices.isLoading = true
        defer { prices.isLoading = false }
        do {
            let table = try await server.call(ReadModelPrices(refresh: force))
            prices.table = UsageRateTable(rates: table.prices.mapValues {
                UsageTokenRate(input: $0.input, output: $0.output, cacheRead: $0.cacheRead, cacheWrite: $0.cacheWrite)
            })
            prices.fetchedAt = table.fetchedAt
            prices.error = nil
        } catch {
            prices.error = error.localizedDescription
        }
    }

    // MARK: Mapping

    /// Each machine, this Mac first. Another machine on a different release does not sync.
    private func summaries(_ report: UsageReport) -> [UsageMachineSummary] {
        let all = machineStore?.machines ?? []
        let thisVersion = all.first(where: \.isThisMachine)?.appVersion
        return all.map { machine in
            let state: UsageMachineSyncState = if machine.isThisMachine { .thisMachine }
                else if let version = machine.appVersion, version != thisVersion { .updateRequired }
                else if machine.isOnline { .synced }
                else if report.newestByMachine[machine.id] == nil { .waiting }
                else { .unavailable }
            return UsageMachineSummary(id: machine.id, name: machine.name, state: state,
                                       syncedAt: report.newestByMachine[machine.id], detail: nil)
        }
    }

    private static func sample(_ group: UsageGroup, index: Int) -> UsageSample {
        let provider = provider(runtime: group.runtime, model: group.model)
        let bare = group.model.split(separator: "/").last.map(String.init) ?? group.model
        let family = bare.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        let harness = group.runtime == .piCLI ? "Pi CLI"
            : AgentRuntimeKind(runtime: group.runtime)?.displayName ?? group.runtime.rawValue
        // Usage outside Woven Matter has the harness's own session.
        let session = group.sessionID ?? group.nativeSessionID.map { "\(group.runtime.rawValue):\($0)" } ?? ""
        return UsageSample(
            id: "\(group.machineID):\(index)", provider: provider, timestamp: group.latest,
            sessionID: session, model: group.model, canonicalModel: bare,
            modelFamily: family.isEmpty ? "Unknown" : family, billingProvider: provider.displayName,
            billingRoute: provider.displayName, reasoningLevel: nil, harness: harness,
            application: group.inWoven ? "Woven Matter" : harness, agent: nil, workspace: nil,
            tokens: UsageTokenCounts(inputTokens: group.amounts.input, cachedInputTokens: group.amounts.cacheRead,
                                     cacheCreationTokens: group.amounts.cacheWrite, outputTokens: group.amounts.output),
            requestCount: group.amounts.requests, costUSD: group.amounts.cost > 0 ? group.amounts.cost : nil,
            sourceID: group.machineID, machineID: group.machineID)
    }

    /// Who bills the usage: the harness's own provider, or the provider a
    /// Pi Durable or OpenCode model names first ("openrouter/…").
    private static func provider(runtime: RuntimeKind, model: String) -> ProviderKind {
        switch runtime {
        case .codex: return .codex
        case .claudeCode: return .claude
        case .grokBuild: return .grok
        default: break
        }
        let prefix = model.split(separator: "/").first.map { $0.lowercased() } ?? ""
        switch prefix {
        case "openai", "openai-codex": return .codex
        case "anthropic", "claude": return .claude
        case "xai", "grok": return .grok
        case "openrouter": return .openRouter
        case "opencode-go", "opencode": return .openCodeGo
        default:
            let lower = model.lowercased()
            if lower.hasPrefix("gpt") || lower.hasPrefix("o3") || lower.hasPrefix("o4") { return .codex }
            if lower.hasPrefix("claude") { return .claude }
            if lower.hasPrefix("grok") { return .grok }
            return .unknown
        }
    }

    private static func account(_ limit: UsageLimit) -> UsageLimitAccount {
        let provider: ProviderKind = limit.provider == "openrouter" ? .openRouter : .codex
        let windows = limit.windows.enumerated().map { index, window in
            ProviderQuotaWindow(id: "\(index)", label: window.label, remainingPercent: max(0, 100 - window.usedPercent),
                                usageKnown: true, windowMinutes: window.windowMinutes, resetsAt: window.resetsAt,
                                resetDescription: nil)
        }
        let budget: ProviderReportedBudget? = if let spent = limit.spent, let cap = limit.limit, cap > 0 {
            ProviderReportedBudget(usedMicros: Int64(spent * 1_000_000), limitMicros: Int64(cap * 1_000_000),
                                   remainingMicros: Int64(max(0, cap - spent) * 1_000_000),
                                   usedPercent: min(100, spent / cap * 100), currency: "USD", period: nil)
        } else { nil }
        return UsageLimitAccount(provider: provider, accountLabel: limit.accountLabel,
                                 status: limit.error == nil ? .available : .failed, quotaWindows: windows,
                                 providerBudget: budget, source: "This Mac", detail: limit.error ?? "",
                                 refreshError: limit.error, dashboardURL: provider.usageDashboardURL)
    }
}

import SwiftUI
import WovenMatterCore

/// Everything the Usage analytics filter column can narrow by.
struct UsageAnalyticsFilters: Equatable {
    static let reasoningNotReported = "Not reported"

    var hiddenProviders: Set<ProviderKind> = []
    var hiddenDevices: Set<String> = []
    var model: String?
    var harness: String?
    var reasoning: String?
    var search = ""

    var isActive: Bool {
        !hiddenProviders.isEmpty || !hiddenDevices.isEmpty || model != nil
            || harness != nil || reasoning != nil || !search.isEmpty
    }

    mutating func clear() { self = UsageAnalyticsFilters() }

    /// Provider and device rows ignore their own filter so a hidden one still shows its total.
    func matches(_ sample: UsageSample, ignoringProviders: Bool = false, ignoringDevices: Bool = false) -> Bool {
        matches(sample, query: searchQuery, ignoringProviders: ignoringProviders, ignoringDevices: ignoringDevices)
    }

    /// The matching samples, normalizing the search once rather than once per sample.
    func filter(_ samples: [UsageSample], ignoringProviders: Bool = false, ignoringDevices: Bool = false) -> [UsageSample] {
        let query = searchQuery
        return samples.filter {
            matches($0, query: query, ignoringProviders: ignoringProviders, ignoringDevices: ignoringDevices)
        }
    }

    private var searchQuery: String { search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func matches(_ sample: UsageSample, query: String, ignoringProviders: Bool, ignoringDevices: Bool) -> Bool {
        (ignoringProviders || !hiddenProviders.contains(sample.provider))
            && (ignoringDevices || !hiddenDevices.contains(sample.usageDeviceID))
            && (model == nil || sample.modelFamily == model)
            && (harness == nil || sample.harness == harness)
            && (reasoning == nil || (sample.reasoningLevel ?? Self.reasoningNotReported) == reasoning)
            && (query.isEmpty || Self.searchText(sample).contains(query))
    }

    private static func searchText(_ sample: UsageSample) -> String {
        [
            sample.provider.displayName,
            sample.model,
            sample.canonicalModel,
            sample.modelFamily,
            sample.billingProvider,
            sample.billingRoute,
            sample.accountLabel,
            sample.reasoningLevel,
            sample.harness,
            sample.application,
            sample.agent,
            sample.workspace,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }
}

struct UsageProviderRollup: Identifiable {
    let provider: ProviderKind
    let summary: UsageAnalyticsSummary
    let estimate: UsageCostEstimate?

    var id: ProviderKind { provider }

    static func rollups(_ samples: [UsageSample], table: UsageRateTable?) -> [UsageProviderRollup] {
        Dictionary(grouping: samples, by: \.provider)
            .map { provider, values in
                UsageProviderRollup(
                    provider: provider,
                    summary: UsageAnalyticsSummary(samples: values),
                    estimate: table?.estimate(values)
                )
            }
            .sorted {
                $0.summary.tokens.totalTokens == $1.summary.tokens.totalTokens
                    ? $0.provider.rawValue < $1.provider.rawValue
                    : $0.summary.tokens.totalTokens > $1.summary.tokens.totalTokens
            }
    }
}

struct UsageSessionRow: Identifiable {
    let id: String
    let modelFamily: String
    let billingRoute: String
    let accountLabel: String
    let reasoningLevel: String?
    let harness: String
    let application: String
    /// Set for usage from another device.
    let deviceName: String?
    let latest: Date
    let tokens: UsageTokenCounts
    let directCostUSD: Double?
    let samples: [UsageSample]

    /// Attribution in reading order, with repeated values left out.
    var attribution: String {
        var parts: [String] = []
        for part in [deviceName, harness, application, billingRoute, accountLabel, reasoningLevel].compactMap({ $0 })
        where !part.isEmpty && !parts.contains(part) && part != "Unknown" {
            parts.append(part)
        }
        return parts.joined(separator: " · ")
    }

    static func rows(from samples: [UsageSample], deviceNames: [String: String] = [:]) -> [UsageSessionRow] {
        Dictionary(
            grouping: samples,
            by: { "\($0.sourceID):\($0.sessionID):\($0.modelFamily):\($0.billingRoute)" }
        )
        .compactMap { id, values in
            guard let latest = values.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            let costs = values.compactMap(\.directCostUSD)
            return UsageSessionRow(
                id: id,
                modelFamily: latest.modelFamily,
                billingRoute: latest.billingRoute,
                accountLabel: latest.accountLabel,
                reasoningLevel: latest.reasoningLevel,
                harness: latest.harness,
                application: latest.application,
                deviceName: deviceNames[latest.usageDeviceID],
                latest: latest.timestamp,
                tokens: values.reduce(.zero) { $0 + $1.tokens },
                directCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                samples: values
            )
        }
        .sorted { $0.latest > $1.latest }
    }
}

/// The analytics page: a fixed filter column beside the scrolling report.
struct UsageAnalyticsPage: View {
    let snapshot: UsageAnalyticsSnapshot
    @Binding var filters: UsageAnalyticsFilters
    @Binding var range: UsageTimeRange
    @Binding var chartStyle: UsageChartStyle
    @Binding var chartMetric: UsageChartMetric
    let devices: [UsageDeviceSummary]
    let prices: UsagePriceState
    let isRefreshing: Bool
    let historyImport: UsageHistoryImportProgress?
    let retryPrices: () -> Void

    /// Nothing has been read yet for this range, as opposed to a range with no usage.
    private var isAwaitingData: Bool {
        guard snapshot.samples.isEmpty else { return false }
        if let historyImport { return !historyImport.covers(snapshot.range) }
        return isRefreshing && snapshot.sources.isEmpty
    }

    var body: some View {
        let table = chartMetric == .apiEstimate ? prices.table : nil
        let unhidden = filters.filter(snapshot.samples, ignoringProviders: true)
        let samples = unhidden.filter { !filters.hiddenProviders.contains($0.provider) }
        HStack(spacing: 0) {
            UsageFilterColumn(
                allSamples: snapshot.samples,
                providerRollups: UsageProviderRollup.rollups(unhidden, table: table),
                devices: devices,
                deviceTotals: Self.deviceTotals(snapshot.samples, filters: filters, table: table),
                metric: table == nil ? .tokens : .apiEstimate,
                isAwaitingData: isAwaitingData,
                filters: $filters,
                range: $range
            )
            ScrollView {
                UsageAnalyticsReport(
                    snapshot: snapshot,
                    samples: samples,
                    deviceNames: Dictionary(
                        devices.filter { $0.state != .thisDevice }.map { ($0.id, $0.identity.name) },
                        uniquingKeysWith: { first, _ in first }
                    ),
                    table: table,
                    prices: prices,
                    isAwaitingData: isAwaitingData,
                    historyImport: historyImport,
                    retryPrices: retryPrices,
                    chartStyle: $chartStyle,
                    chartMetric: $chartMetric
                )
                .frame(maxWidth: 1000, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }
}

private extension UsageAnalyticsPage {
    /// Each device's total under every other filter, so a hidden device still shows its total.
    static func deviceTotals(
        _ samples: [UsageSample],
        filters: UsageAnalyticsFilters,
        table: UsageRateTable?
    ) -> [String: String] {
        Dictionary(grouping: filters.filter(samples, ignoringDevices: true), by: \.usageDeviceID)
            .mapValues { group in
                if let table {
                    let estimate = table.estimate(group)
                    return estimate.hasPrice ? UsageFormat.usdCompact(estimate.total) : ""
                }
                return UsageFormat.tokens(group.reduce(.zero) { $0 + $1.tokens }.totalTokens)
            }
    }
}

// MARK: - Filter column

private struct UsageFilterColumn: View {
    static let width: CGFloat = 172

    let allSamples: [UsageSample]
    let providerRollups: [UsageProviderRollup]
    let devices: [UsageDeviceSummary]
    let deviceTotals: [String: String]
    let metric: UsageChartMetric
    let isAwaitingData: Bool
    @Binding var filters: UsageAnalyticsFilters
    @Binding var range: UsageTimeRange

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WovenSearchField(text: $filters.search, prompt: "Search", compact: true)
                    .help("Search model, harness, app, or agent")
                group("Range") {
                    VStack(spacing: 4) {
                        WovenSegmentedSelector(
                            options: [.last7Days, .last30Days, .last90Days, .allTime],
                            selection: $range,
                            accessibilityLabel: \.label
                        ) { $0.compactLabel }
                        WovenSegmentedSelector(
                            options: [.last24Hours, .today, .yesterday],
                            selection: $range,
                            accessibilityLabel: \.label
                        ) { $0 == .yesterday ? "Yest." : $0.compactLabel }
                    }
                }
                group("Devices") {
                    VStack(spacing: 1) {
                        ForEach(devices) { device in
                            UsageFilterToggleRow(
                                title: device.identity.name,
                                color: WovenPalette.foreground,
                                value: deviceTotals[device.id].flatMap { $0.isEmpty ? nil : $0 },
                                detail: device.state.rowDetail,
                                help: device.helpText,
                                isOn: !filters.hiddenDevices.contains(device.id)
                            ) {
                                if filters.hiddenDevices.remove(device.id) == nil {
                                    filters.hiddenDevices.insert(device.id)
                                }
                            }
                        }
                    }
                }
                if isAwaitingData, providers.isEmpty {
                    group("Providers") { UsageFilterRowsPlaceholder() }
                }
                if !providers.isEmpty {
                    group("Providers") {
                        VStack(spacing: 1) {
                            ForEach(providers, id: \.self) { provider in
                                let isOn = !filters.hiddenProviders.contains(provider)
                                UsageFilterToggleRow(
                                    title: provider.usageName,
                                    color: provider.usageColor,
                                    value: value(for: provider),
                                    help: isOn ? "Hide \(provider.usageName)" : "Show \(provider.usageName)",
                                    isOn: isOn
                                ) {
                                    if filters.hiddenProviders.remove(provider) == nil {
                                        filters.hiddenProviders.insert(provider)
                                    }
                                }
                            }
                        }
                    }
                }
                group("Filter") {
                    VStack(spacing: 3) {
                        selector("Model", allLabel: "All models", selection: $filters.model) {
                            $0.modelFamily
                        }
                        selector("Harness", allLabel: "All harnesses", selection: $filters.harness) {
                            $0.harness
                        }
                        selector("Reasoning", allLabel: "All reasoning levels", selection: $filters.reasoning) {
                            $0.reasoningLevel ?? UsageAnalyticsFilters.reasoningNotReported
                        }
                    }
                }
                if filters.isActive {
                    Button("Clear filters") { filters.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(WovenPalette.success)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
    }

    /// Keeps a hidden provider listed after a range change so it can be turned back on.
    private var providers: [ProviderKind] {
        let present = Set(allSamples.map(\.provider)).union(filters.hiddenProviders)
        return ProviderKind.allCases.filter(present.contains)
    }

    private func value(for provider: ProviderKind) -> String? {
        guard let rollup = providerRollups.first(where: { $0.provider == provider }) else { return nil }
        if metric == .apiEstimate, let estimate = rollup.estimate {
            return estimate.hasPrice ? UsageFormat.usdCompact(estimate.total) : nil
        }
        return UsageFormat.tokens(rollup.summary.tokens.totalTokens)
    }

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageSectionHeading(title: title)
            content()
        }
    }

    private func selector(
        _ title: String,
        allLabel: String,
        selection: Binding<String?>,
        value: (UsageSample) -> String
    ) -> some View {
        UsageFilterSelector(
            title: title,
            allLabel: allLabel,
            selection: selection,
            // A value missing from the new range stays listed, so an active filter never reads as All.
            values: Set(allSamples.map(value)).union(selection.wrappedValue.map { [$0] } ?? [])
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        )
    }
}

/// One click shows or hides a device or provider. Provider rows also act as the graph's legend.
private struct UsageFilterToggleRow: View {
    let title: String
    let color: Color
    let value: String?
    var detail: String? = nil
    let help: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isOn ? color : Color.clear)
                    .overlay {
                        if !isOn {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(WovenPalette.mutedForeground.opacity(0.55), lineWidth: 1)
                        }
                    }
                    .frame(width: 10, height: 10)
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12))
                            .foregroundStyle(isOn ? WovenPalette.foreground : WovenPalette.mutedForeground)
                            .lineLimit(1)
                        if let detail {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(WovenPalette.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    if let value {
                        Text(value)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(WovenPalette.mutedForeground)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 25)
            .contentShape(Rectangle())
        }
        .buttonStyle(UsageRowButtonStyle())
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([isOn ? "Shown" : "Hidden", value, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isToggle)
    }
}

private extension UsageDeviceSyncState {
    /// Shown only when this device's usage may be missing or old.
    var rowDetail: String? {
        switch self {
        case .thisDevice, .synced: nil
        case .scanning: "Reading history"
        case .waiting: "Waiting to connect"
        case .updateRequired: "Needs an update"
        case .unavailable: "Not reachable"
        }
    }
}

private extension UsageDeviceSummary {
    var helpText: String {
        // Long device names can truncate in the row, so the full name is always here.
        var parts = [identity.name + "."]
        switch state {
        case .thisDevice: parts.append("Usage from this Mac.")
        case .synced: break
        case .scanning: parts.append("This device is still reading its usage history.")
        case .waiting: parts.append("Usage from this device hasn't arrived yet.")
        case .updateRequired:
            parts.append(identity.kind == .linux
                ? "Update this workspace's service in Settings to include its usage."
                : "Update Woven Matter on this device to include its usage.")
        case .unavailable: parts.append(detail ?? "This device couldn't be reached.")
        }
        if let syncedAt {
            parts.append("Last updated \(syncedAt.formatted(.relative(presentation: .named))).")
        } else if state != .thisDevice {
            parts.append("No usage has arrived yet, which doesn't mean there isn't any.")
        }
        return parts.joined(separator: " ")
    }
}

private struct UsageRowButtonStyle: ButtonStyle {
    @Environment(\.wovenTheme) private var theme
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? theme.palette.themeSoft
                    : (isHovering ? theme.palette.themeWhisper : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }
}

private struct UsageFilterSelector: View {
    @Environment(\.wovenTheme) private var theme
    let title: String
    let allLabel: String
    @Binding var selection: String?
    let values: [String]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                if let selection {
                    Text(selection)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WovenPalette.foreground)
                        .lineLimit(1)
                } else {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(WovenPalette.mutedForeground)
                    Spacer(minLength: 4)
                    Text("All")
                        .font(.system(size: 12))
                        .foregroundStyle(WovenPalette.foreground)
                }
                if selection != nil { Spacer(minLength: 4) }
                LucideIcon(glyph: .chevronDown, size: 11)
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            .background(
                selection == nil ? theme.palette.themeWhisper : theme.palette.themeSoft,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selection.map { "\(title): \($0)" } ?? allLabel)
        .accessibilityLabel(title)
        .accessibilityValue(selection ?? allLabel)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    option(allLabel, value: nil)
                    ForEach(values, id: \.self) { option($0, value: $0) }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(minWidth: 200, maxHeight: 360)
            .onExitCommand { isPresented = false }
        }
    }

    private func option(_ label: String, value: String?) -> some View {
        Button {
            selection = value
            isPresented = false
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(WovenPalette.foreground)
                Spacer(minLength: 12)
                if selection == value {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WovenPalette.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsMenuOptionButtonStyle())
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}

// MARK: - Report

private struct UsageAnalyticsReport: View {
    let snapshot: UsageAnalyticsSnapshot
    let samples: [UsageSample]
    let deviceNames: [String: String]
    let table: UsageRateTable?
    let prices: UsagePriceState
    let isAwaitingData: Bool
    let historyImport: UsageHistoryImportProgress?
    let retryPrices: () -> Void
    @Binding var chartStyle: UsageChartStyle
    @Binding var chartMetric: UsageChartMetric

    /// What the rows can show: tokens until prices have loaded.
    private var metric: UsageChartMetric { table == nil ? .tokens : .apiEstimate }

    var body: some View {
        let summary = UsageAnalyticsSummary(samples: samples)
        let estimate = table?.estimate(samples)
        if isAwaitingData {
            UsageReportPlaceholder(style: chartStyle) { chartControls }
        } else {
            report(summary: summary, estimate: estimate)
        }
    }

    /// Set when part of the selected range is still being read.
    private var importNotice: String? {
        guard let historyImport, !historyImport.covers(snapshot.range) else { return nil }
        guard let covered = historyImport.covered else { return "Older usage is still loading." }
        return "Showing the last \(covered.label) so far. Older usage is still loading."
    }

    private func report(summary: UsageAnalyticsSummary, estimate: UsageCostEstimate?) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                heroRow(summary: summary, estimate: estimate)
                if let importNotice {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text(importNotice)
                            .font(.system(size: 11.5))
                            .foregroundStyle(WovenPalette.mutedForeground)
                    }
                }
                if chartMetric == .apiEstimate, table == nil {
                    UsagePriceUnavailable(prices: prices, retry: retryPrices)
                } else if samples.isEmpty {
                    emptyState
                } else {
                    UsageChart(
                        data: chartData,
                        style: chartStyle,
                        metric: metric
                    )
                }
            }
            if !samples.isEmpty {
                UsageBreakdownNumbers(
                    summary: summary,
                    estimate: estimate,
                    modelCount: Set(samples.map(\.modelFamily)).count
                )
                UsageProviderList(
                    rollups: UsageProviderRollup.rollups(samples, table: table),
                    metric: metric
                )
                UsageModelList(samples: samples, table: table, metric: metric)
                UsageSessionList(
                    rows: UsageSessionRow.rows(from: samples, deviceNames: deviceNames),
                    table: table
                )
            }
            UsageSourceCoverageSection(
                sources: snapshot.sources,
                startsExpanded: snapshot.samples.isEmpty
            )
            footer
        }
    }

    private var chartData: UsageChartData {
        // The snapshot's own range, so old data never squeezes into a newly selected one while it loads.
        UsageChartData.build(samples: samples, range: snapshot.range, now: snapshot.generatedAt) { group in
            if let table { return table.estimate(group).total }
            return Double(group.reduce(.zero) { $0 + $1.tokens }.totalTokens)
        }
    }

    private func heroRow(summary: UsageAnalyticsSummary, estimate: UsageCostEstimate?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    heroFigure(summary: summary, estimate: estimate)
                    Spacer(minLength: 0)
                    chartControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    heroFigure(summary: summary, estimate: estimate)
                    chartControls
                }
            }
            Text(heroDetail(summary: summary, estimate: estimate))
                .font(.system(size: 11.5))
                .foregroundStyle(WovenPalette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func heroFigure(summary: UsageAnalyticsSummary, estimate: UsageCostEstimate?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(
                chartMetric == .apiEstimate
                    ? (estimate.map { $0.hasPrice ? UsageFormat.usd($0.total) : "Unpriced" } ?? "–")
                    : UsageFormat.tokens(summary.tokens.totalTokens)
            )
            .font(.system(size: 28, weight: .semibold).monospacedDigit())
            .tracking(-0.4)
            if chartMetric != .apiEstimate || estimate?.hasPrice != false {
                Text(chartMetric == .apiEstimate ? "est." : "tokens")
                    .font(.system(size: 12.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func heroDetail(summary: UsageAnalyticsSummary, estimate: UsageCostEstimate?) -> String {
        var parts = [
            UsageFormat.count(summary.sessions, unit: "session"),
            UsageFormat.count(summary.requests, unit: "model call"),
        ]
        if chartMetric == .apiEstimate { parts.insert("At API list prices, not your bill", at: 0) }
        if let cost = summary.costUSD {
            parts.append("\(UsageFormat.currency(cost)) direct spend")
        }
        if let estimate, estimate.unpricedTokens > 0 {
            parts.append("\(UsageFormat.percent(estimate.unpricedShare)) of tokens unpriced")
        }
        return parts.joined(separator: " · ")
    }

    private var chartControls: some View {
        HStack(spacing: 8) {
            WovenSegmentedSelector(
                options: UsageChartMetric.allCases,
                selection: $chartMetric
            ) { $0.title }
            .frame(width: 154)
            WovenSegmentedSelector(
                options: UsageChartStyle.allCases,
                selection: $chartStyle
            ) { $0.title }
            .frame(width: 98)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Text(snapshot.samples.isEmpty ? "No attributable usage in this range" : "No usage matches these filters")
            .font(.system(size: 13, weight: .semibold))
            Text(
                snapshot.samples.isEmpty
                    ? "Source coverage below shows what Woven Matter found on this Mac."
                    : "Clear filters or broaden the time range."
            )
            .font(.system(size: 11.5))
            .foregroundStyle(WovenPalette.mutedForeground)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if chartMetric == .apiEstimate, let fetchedAt = prices.fetchedAt {
                Text(
                    "API estimates use public list prices from LiteLLM, updated \(Text(fetchedAt, format: .relative(presentation: .named))). They are not your bill."
                )
            }
            Text("Usage tracking saves totals and metadata, not prompts or chat contents.")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(WovenPalette.mutedForeground)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UsagePriceUnavailable: View {
    let prices: UsagePriceState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Before the first download starts there is nothing to report yet, so it reads as loading.
            if prices.isLoading || prices.error == nil {
                ProgressView().controlSize(.small)
                Text("Loading model prices…")
                    .font(.system(size: 12))
                    .foregroundStyle(WovenPalette.mutedForeground)
            } else {
                Text("Model prices couldn’t be downloaded")
                    .font(.system(size: 13, weight: .semibold))
                Text("API estimates need LiteLLM’s public price list. Your usage isn’t sent anywhere.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .multilineTextAlignment(.center)
                Button("Try again", action: retry)
                    .buttonStyle(WovenQuietButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

private struct UsageBreakdownNumbers: View {
    let summary: UsageAnalyticsSummary
    let estimate: UsageCostEstimate?
    let modelCount: Int
    @State private var availableWidth: CGFloat = 0

    private struct Entry: Identifiable {
        let title: String
        let value: String
        let detail: String?
        /// Share of the bar below, using one neutral ramp so it never competes with provider colors.
        var share: Double?
        var ink: Double?

        var id: String { title }
    }

    private var entries: [Entry] {
        if let estimate {
            // Unknown prices read Unpriced, never $0.
            let usd = { (value: Double) in estimate.hasPrice ? UsageFormat.usd(value) : "Unpriced" }
            var entries = [
                Entry(title: "Cached input", value: usd(estimate.cacheRead), detail: nil, share: estimate.cacheRead, ink: 0.28),
                Entry(title: "Uncached input", value: usd(estimate.input), detail: nil, share: estimate.input, ink: 0.6),
                Entry(title: "Cache writes", value: usd(estimate.cacheWrite), detail: nil, share: estimate.cacheWrite, ink: 0.42),
                Entry(title: "Output", value: usd(estimate.output), detail: nil, share: estimate.output, ink: 1),
            ]
            if estimate.reported > 0 {
                entries.append(Entry(title: "Reported", value: usd(estimate.reported), detail: "Not split by type", share: estimate.reported, ink: 0.76))
            }
            entries.append(Entry(title: "Cache savings", value: usd(estimate.cacheSavings), detail: "vs. uncached"))
            return entries
        }
        let tokens = summary.tokens
        return [
            Entry(title: "Cached input", value: UsageFormat.tokens(tokens.cachedInputTokens), detail: cacheShare(tokens), share: Double(tokens.cachedInputTokens), ink: 0.28),
            Entry(title: "Uncached input", value: UsageFormat.tokens(tokens.inputTokens), detail: nil, share: Double(tokens.inputTokens), ink: 0.6),
            Entry(title: "Cache writes", value: UsageFormat.tokens(tokens.cacheCreationTokens), detail: nil, share: Double(tokens.cacheCreationTokens), ink: 0.42),
            Entry(title: "Output", value: UsageFormat.tokens(tokens.outputTokens), detail: "\(UsageFormat.tokens(tokens.reasoningTokens)) reasoning", share: Double(tokens.outputTokens), ink: 1),
            Entry(title: "Model calls", value: summary.requests.formatted(), detail: "Across \(UsageFormat.count(modelCount, unit: "model"))"),
        ]
    }

    private func cacheShare(_ tokens: UsageTokenCounts) -> String? {
        let input = tokens.totalInputTokens
        guard input > 0 else { return nil }
        return "\(UsageFormat.percent(Double(tokens.cachedInputTokens) / Double(input))) of input"
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading),
                    count: columnCount(for: entries.count)
                ),
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            if let ink = entry.ink {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(WovenPalette.foreground.opacity(ink))
                                    .frame(width: 6, height: 6)
                            }
                            Text(entry.title)
                                .font(.system(size: 10.5))
                                .foregroundStyle(WovenPalette.mutedForeground)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        Text(entry.value)
                            .font(.system(size: 16, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let detail = entry.detail {
                            Text(detail)
                                .font(.system(size: 10))
                                .foregroundStyle(WovenPalette.mutedForeground)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            shareBar(entries)
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { availableWidth = $0 }
    }

    /// As many equal columns as fit, so the numbers always span the report's width.
    private func columnCount(for entryCount: Int) -> Int {
        let fitting = Int((availableWidth + 10) / 88)
        return max(1, min(entryCount, availableWidth > 0 ? fitting : entryCount))
    }

    private func shareBar(_ entries: [Entry]) -> some View {
        let segments = entries.filter { ($0.share ?? 0) > 0 }
        let total = segments.reduce(0) { $0 + ($1.share ?? 0) }
        return GeometryReader { geometry in
            let available = geometry.size.width - CGFloat(max(0, segments.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(WovenPalette.foreground.opacity(segment.ink ?? 1))
                        .frame(width: max(2, available * CGFloat((segment.share ?? 0) / max(total, 1e-9))))
                        .help("\(segment.title): \(segment.value)")
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }
}

private struct UsageProviderList: View {
    @Environment(\.wovenTheme) private var theme
    let rollups: [UsageProviderRollup]
    let metric: UsageChartMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageSectionHeading(title: "By provider")
            VStack(spacing: 0) {
                ForEach(rollups) { rollup in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        UsageProviderSwatch(provider: rollup.provider)
                        Text(rollup.provider.usageName)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(
                            UsageFormat.count(rollup.summary.sessions, unit: "session")
                                + " · "
                                + UsageFormat.count(rollup.summary.requests, unit: "call")
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .lineLimit(1)
                        Spacer(minLength: 8)
                        UsageRowValue(
                            tokens: rollup.summary.tokens.totalTokens,
                            estimate: rollup.estimate,
                            metric: metric
                        )
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    if rollup.id != rollups.last?.id {
                        Rectangle().fill(theme.palette.border).frame(height: 1)
                    }
                }
            }
        }
    }
}

/// A row's figure: tokens, or the estimate with its tokens beside it.
private struct UsageRowValue: View {
    let tokens: Int64
    let estimate: UsageCostEstimate?
    let metric: UsageChartMetric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if metric == .apiEstimate {
                Text(UsageFormat.tokens(tokens))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(WovenPalette.mutedForeground)
                if let estimate, estimate.hasPrice {
                    Text(UsageFormat.usd(estimate.total))
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                } else {
                    Text("Unpriced")
                        .font(.system(size: 12.5))
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
            } else {
                Text(UsageFormat.tokens(tokens))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            }
        }
    }
}

private struct UsageModelList: View {
    @Environment(\.wovenTheme) private var theme
    let samples: [UsageSample]
    let table: UsageRateTable?
    let metric: UsageChartMetric
    @State private var expanded: Set<String> = []

    var body: some View {
        let groups = Dictionary(grouping: samples, by: \.modelFamily)
        let estimates = table.map { table in groups.mapValues { table.estimate($0) } } ?? [:]
        let byTokens = UsageModelRollup.aggregate(samples)
        let ordered = metric == .apiEstimate
            ? byTokens.sorted { (estimates[$0.family]?.total ?? 0) > (estimates[$1.family]?.total ?? 0) }
            : byTokens
        VStack(alignment: .leading, spacing: 6) {
            UsageSectionHeading(title: "By model")
            VStack(spacing: 0) {
                ForEach(ordered) { rollup in
                    DisclosureGroup(isExpanded: binding(for: rollup.family)) {
                        UsageModelDetail(rollup: rollup)
                            .padding(.leading, 18)
                            .padding(.top, 6)
                            .padding(.bottom, 12)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            UsageProviderSwatch(provider: rollup.provider)
                            Text(rollup.family)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Text(
                                UsageFormat.count(rollup.sessions, unit: "session")
                                    + " · "
                                    + UsageFormat.count(rollup.requests, unit: "call")
                            )
                            .font(.system(size: 10.5))
                            .foregroundStyle(WovenPalette.mutedForeground)
                            .lineLimit(1)
                            Spacer(minLength: 8)
                            UsageRowValue(
                                tokens: rollup.tokens.totalTokens,
                                estimate: estimates[rollup.family],
                                metric: metric
                            )
                        }
                        .padding(.vertical, 3)
                        // The disclosure style adds its own spacer, which must not take row width.
                        .layoutPriority(1)
                    }
                    if rollup.id != ordered.last?.id {
                        Rectangle().fill(theme.palette.border).frame(height: 1)
                    }
                }
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        }
    }

    private func binding(for family: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(family) },
            set: { isExpanded in
                if isExpanded { expanded.insert(family) } else { expanded.remove(family) }
            }
        )
    }
}

private struct UsageModelDetail: View {
    let rollup: UsageModelRollup

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                inlineMetric("Input", rollup.tokens.totalInputTokens)
                inlineMetric("Cached input", rollup.tokens.cachedInputTokens)
                inlineMetric("Output", rollup.tokens.outputTokens)
                Spacer(minLength: 0)
            }
            if rollup.canonicalModels.count > 1 {
                Text("Variants: " + rollup.canonicalModels.joined(separator: ", "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            dimension("Subscriptions and billing routes", rows: rollup.billingRoutes)
            dimension("Harnesses and applications", rows: rollup.harnesses)
            dimension("Accounts", rows: rollup.accounts)
        }
    }

    private func inlineMetric(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(WovenPalette.mutedForeground)
            Text(UsageFormat.tokens(value))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private func dimension(_ title: String, rows: [UsageBreakdownRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(WovenPalette.mutedForeground)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                        .help(row.label)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(WovenPalette.muted)
                            Capsule()
                                .fill(rollup.provider.usageColor.opacity(0.8))
                                .frame(
                                    width: geometry.size.width
                                        * CGFloat(row.tokens.totalTokens)
                                        / CGFloat(max(1, rollup.tokens.totalTokens))
                                )
                        }
                    }
                    .frame(height: 4)
                    Text(UsageFormat.tokens(row.tokens.totalTokens))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                    Text(UsageFormat.count(row.requests, unit: "call"))
                        .font(.system(size: 10))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .lineLimit(1)
                        .frame(width: 58, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct UsageSessionList: View {
    @Environment(\.wovenTheme) private var theme
    private static let pageSize = 80

    let rows: [UsageSessionRow]
    let table: UsageRateTable?
    @State private var visibleCount = UsageSessionList.pageSize

    var body: some View {
        let visible = rows.prefix(visibleCount)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                UsageSectionHeading(title: "Sessions and attribution")
                Spacer()
                Text("Showing \(visible.count) of \(rows.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            VStack(spacing: 0) {
                ForEach(visible) { row in
                    sessionRow(row)
                    if row.id != visible.last?.id {
                        Rectangle().fill(theme.palette.border).frame(height: 1)
                    }
                }
            }
            if rows.count > visible.count {
                Button("Show \(min(Self.pageSize, rows.count - visible.count)) more") {
                    visibleCount += Self.pageSize
                }
                .buttonStyle(WovenQuietButtonStyle())
                .padding(.top, 6)
            }
        }
    }

    private func sessionRow(_ row: UsageSessionRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.modelFamily)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(row.attribution)
                    .font(.system(size: 10.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .lineLimit(1)
                    .help(row.attribution)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(primaryValue(row))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                Text(row.latest, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .lineLimit(1)
            }
            .fixedSize()
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// Direct spend reads as spend. Anything from price lists is labeled as an estimate.
    private func primaryValue(_ row: UsageSessionRow) -> String {
        let tokens = UsageFormat.tokens(row.tokens.totalTokens)
        if let direct = row.directCostUSD {
            return "\(tokens) · \(UsageFormat.currency(direct))"
        }
        guard let table else { return tokens }
        let estimate = table.estimate(row.samples)
        return estimate.hasPrice
            ? "\(tokens) · \(UsageFormat.usd(estimate.total)) est."
            : "\(tokens) · Unpriced"
    }
}

private struct UsageSourceCoverageSection: View {
    let sources: [UsageSourceCoverage]
    @State private var isExpanded: Bool

    init(sources: [UsageSourceCoverage], startsExpanded: Bool) {
        self.sources = sources
        _isExpanded = State(initialValue: startsExpanded)
    }

    private var attentionCount: Int {
        sources.filter { $0.status == .failed || $0.status == .partial }.count
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            UsageProviderSwatch(provider: source.provider)
                            Text(source.sourceName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            if let harness = source.harness, harness != source.sourceName {
                                Text(harness)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(WovenPalette.mutedForeground)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            UsageStatusPill(text: source.status.title, color: source.status.color)
                        }
                        Text(
                            UsageFormat.count(source.discoveredSessions, unit: "session")
                                + " · "
                                + UsageFormat.count(source.attributedSamples, unit: "record")
                                + " · "
                                + source.detail
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(source.location)
                            .font(.system(size: 10.5).monospaced())
                            .foregroundStyle(WovenPalette.mutedForeground.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(source.location)
                    }
                    .padding(.leading, 18)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        } label: {
            HStack(spacing: 6) {
                Text("Source coverage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WovenPalette.mutedForeground)
                Text(UsageFormat.count(sources.count, unit: "source"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                if attentionCount > 0 {
                    Text("\(attentionCount) to review")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(WovenPalette.warning)
                }
                Spacer(minLength: 0)
            }
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
    }
}

private struct UsageStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }
}

private extension UsageSourceStatus {
    var title: String {
        switch self {
        case .available: "Available"
        case .partial: "Partial"
        case .notFound: "Not found"
        case .unavailable: "Unavailable"
        case .failed: "Needs attention"
        }
    }

    var color: Color {
        switch self {
        case .available: WovenPalette.success
        case .partial: WovenPalette.warning
        case .notFound, .unavailable: WovenPalette.mutedForeground
        case .failed: WovenPalette.danger
        }
    }
}

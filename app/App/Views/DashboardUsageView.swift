import Charts
import SwiftUI
import WovenMatterCore
import WovenMatterDashboardStore

private enum DashboardUsagePage: String, CaseIterable, Identifiable {
    case limits
    case analytics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .analytics: "Usage analytics"
        case .limits: "Usage limits"
        }
    }
}

private enum PendingUsageCredentialAction: Identifiable {
    case enableProvider(ProviderKind)
    case retryProvider(ProviderKind)
    case saveOpenRouter(String)
    case deleteOpenRouter

    var id: String {
        switch self {
        case .enableProvider(let provider): "enable-\(provider.rawValue)"
        case .retryProvider(let provider): "retry-\(provider.rawValue)"
        case .saveOpenRouter: "save-openrouter"
        case .deleteOpenRouter: "delete-openrouter"
        }
    }

    var purpose: String {
        switch self {
        case .enableProvider(let provider):
            "Enable \(provider.displayName) so Woven Matter can check its local sign-in and usage when you open or refresh Usage."
        case .retryProvider(let provider):
            "Retry \(provider.displayName) credential access once. macOS may ask for permission now; future automatic refreshes remain noninteractive."
        case .saveOpenRouter:
            "Save and use the OpenRouter API key you enter in this Mac's Keychain."
        case .deleteOpenRouter:
            "Access the saved OpenRouter item so it can be removed from this Mac's Keychain."
        }
    }
}

struct DashboardUsageView: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    @State private var page = DashboardUsagePage.limits
    @State private var range: UsageTimeRange = {
        let rawValue = UserDefaults.standard.string(
            forKey: "wovenmatter.usage.range"
        )
        return rawValue.flatMap(UsageTimeRange.init(rawValue:)) ?? .last30Days
    }()
    @State private var providerFilter = "all"
    @State private var modelFilter = "all"
    @State private var billingRouteFilter = "all"
    @State private var harnessFilter = "all"
    @State private var reasoningFilter = "all"
    @State private var searchText = ""
    @State private var openRouterAPIKey = ""
    @State private var pendingCredentialAction: PendingUsageCredentialAction?

    private var analytics: UsageAnalyticsSnapshot? { model.localUsage?.analytics }

    private var filteredSamples: [UsageSample] {
        guard let analytics else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return analytics.samples.filter { sample in
            (providerFilter == "all" || sample.provider.rawValue == providerFilter)
                && (modelFilter == "all" || sample.modelFamily == modelFilter)
                && (billingRouteFilter == "all" || sample.billingRoute == billingRouteFilter)
                && (harnessFilter == "all" || sample.harness == harnessFilter)
                && (reasoningFilter == "all" || (sample.reasoningLevel ?? "Not reported") == reasoningFilter)
                && (query.isEmpty || searchableText(sample).contains(query))
        }
    }

    private var pageBinding: Binding<DashboardUsagePage> {
        Binding(
            get: { page },
            set: { value in
                page = value
                if value == .analytics {
                    Task {
                        await model.usageAnalyticsSelected(range: range)
                    }
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                HStack(spacing: 10) {
                    Text("Usage page")
                        .fixedSize()
                    DashboardSegmentedSelector(
                        options: DashboardUsagePage.allCases,
                        selection: pageBinding
                    ) { page in
                        page.title
                    }
                    .frame(width: 320)
                }

                if let error = model.localUsageError {
                    UsageErrorBanner(text: error)
                }

                if let snapshot = model.localUsage {
                    switch page {
                    case .limits:
                        accountConnections(snapshot)
                    case .analytics:
                        analyticsPage(snapshot.analytics)
                    }
                } else {
                    UsageLoadingCard(isLoading: model.isRefreshingLocalUsage)
                }
            }
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
        }
        .scrollIndicators(.never)
        .background(theme.palette.workspace)
        .task {
            await model.usageDestinationAppeared(range: range)
        }
        .sheet(item: $pendingCredentialAction) { action in
            CredentialAccessDisclosureView(
                purpose: action.purpose,
                onEnable: {
                    model.acknowledgeCredentialAccessDisclosure()
                    pendingCredentialAction = nil
                    performCredentialAction(action)
                },
                onCancel: { pendingCredentialAction = nil }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                Text("AI activity and account allowances across connected accounts and runtimes.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer()
            if let generatedAt = model.localUsage?.analytics.generatedAt {
                Text("Updated \(generatedAt, format: .relative(presentation: .named))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .padding(.top, 10)
            }
            Button {
                Task {
                    await model.refreshLocalUsage(
                        range: range,
                        refreshLimits: page == .limits,
                        reason: .manual
                    )
                }
            } label: {
                HStack(spacing: 6) {
                    if model.isRefreshingLocalUsage {
                        ProgressView().controlSize(.small)
                    } else {
                        DashboardLucideIcon(glyph: .rotate, size: 14)
                    }
                    Text(model.isRefreshingLocalUsage ? "Refreshing…" : "Refresh")
                }
            }
            .buttonStyle(DashboardQuietButtonStyle())
            .disabled(model.isRefreshingLocalUsage)
        }
    }

    @ViewBuilder
    private func analyticsPage(_ snapshot: UsageAnalyticsSnapshot) -> some View {
        analyticsControls(snapshot)

        HStack(spacing: 7) {
            Image(systemName: "externaldrive.badge.checkmark")
                .foregroundStyle(theme.palette.themeAccent)
            Text("Normalized usage metadata is persisted in Woven Matter; prompts and transcript contents remain in their provider-owned stores.")
                .foregroundStyle(DashboardPalette.mutedForeground)
            Spacer()
        }
        .font(.system(size: 10.5, weight: .medium))

        let samples = filteredSamples
        let summary = UsageAnalyticsSummary(samples: samples)
        UsageSectionHeading(title: "Token breakdown")
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            UsageMetricCard(
                title: "Total tokens",
                value: compact(summary.tokens.totalTokens),
                detail: countDetail(summary.sessions, unit: "session")
            )
            UsageMetricCard(
                title: "Cached input",
                value: compact(summary.tokens.cachedInputTokens),
                detail: compact(summary.tokens.cacheCreationTokens)
                    + " cache write"
                    + (summary.tokens.cacheCreationTokens == 1 ? "" : "s")
            )
            UsageMetricCard(
                title: "Uncached input",
                value: compact(summary.tokens.inputTokens),
                detail: cacheRateDetail(summary.tokens)
            )
            UsageMetricCard(
                title: "Output",
                value: compact(summary.tokens.outputTokens),
                detail: compact(summary.tokens.reasoningTokens) + " reasoning"
            )
            UsageMetricCard(
                title: "Model calls",
                value: summary.requests.formatted(),
                detail: "Across \(modelCountDetail(samples))"
            )
        }

        if samples.isEmpty {
            UsageEmptyCard(
                title: snapshot.samples.isEmpty ? "No attributable usage in this range" : "No usage matches these filters",
                detail: snapshot.samples.isEmpty
                    ? "Source coverage below shows what Woven Matter found on this Mac."
                    : "Clear filters or broaden the time range."
            )
        } else {
            providerBreakdown(samples)
            providerUsageChart(samples)
            modelBreakdown(samples)
            sessionTable(samples)
        }

        sourceCoverage(snapshot.sources)
    }

    private func analyticsControls(_ snapshot: UsageAnalyticsSnapshot) -> some View {
        UsageSection {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Text("Range")
                                .fixedSize()
                            DashboardSegmentedSelector(
                                options: UsageTimeRange.allCases,
                                selection: rangeSelectionBinding
                            ) { range in
                                range.compactLabel
                            }
                                .frame(width: 430)
                        }

                        Spacer(minLength: 8)
                        DashboardSearchField(
                            text: $searchText,
                            prompt: "Search model, harness, app, or agent"
                        )
                            .frame(width: 260)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Range")
                        DashboardSegmentedSelector(
                            options: UsageTimeRange.allCases,
                            selection: rangeSelectionBinding
                        ) { range in
                            range.compactLabel
                        }
                        DashboardSearchField(
                            text: $searchText,
                            prompt: "Search model, harness, app, or agent"
                        )
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    filterPicker(
                        title: "Provider",
                        selection: $providerFilter,
                        options: snapshot.samples.map { ($0.provider.rawValue, $0.provider.displayName) }
                    )
                    filterPicker(
                        title: "Model",
                        selection: $modelFilter,
                        options: snapshot.samples.map { ($0.modelFamily, $0.modelFamily) }
                    )
                    filterPicker(
                        title: "Billing route",
                        selection: $billingRouteFilter,
                        options: snapshot.samples.map { ($0.billingRoute, $0.billingRoute) }
                    )
                    filterPicker(
                        title: "Harness",
                        selection: $harnessFilter,
                        options: snapshot.samples.map { ($0.harness, $0.harness) }
                    )
                    filterPicker(
                        title: "Reasoning",
                        selection: $reasoningFilter,
                        options: snapshot.samples.map {
                            let value = $0.reasoningLevel ?? "Not reported"
                            return (value, value)
                        }
                    )
                }
                if hasActiveFilters {
                    Button("Clear filters") { clearFilters() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.palette.themeAccent)
                }
            }
        }
    }

    private var rangeSelectionBinding: Binding<UsageTimeRange> {
        Binding(
            get: { range },
            set: { value in
                guard value != range else { return }
                range = value
                UserDefaults.standard.set(
                    value.rawValue,
                    forKey: "wovenmatter.usage.range"
                )
                Task {
                    await model.refreshLocalUsage(
                        range: value,
                        reason: .rangeChanged
                    )
                }
            }
        )
    }

    private func filterPicker(
        title: String,
        selection: Binding<String>,
        options: [(String, String)]
    ) -> some View {
        let unique = Dictionary(options, uniquingKeysWith: { first, _ in first })
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
        let allLabel = switch title {
        case "Harness": "All harnesses"
        case "Reasoning": "All reasoning levels"
        default: "All \(title.lowercased())s"
        }
        return UsageFilterSelector(
            title: title,
            selection: selection,
            options: [(key: "all", label: allLabel)]
                + unique.map { (key: $0.key, label: $0.value) }
        )
    }

    private func providerUsageChart(_ samples: [UsageSample]) -> some View {
        let buckets = ProviderUsageChartBucket.aggregate(
            samples: samples,
            range: range
        )
        let providers = Array(Set(buckets.map(\.provider))).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let summary = UsageAnalyticsSummary(samples: samples)
        return VStack(alignment: .leading, spacing: 8) {
            UsageSectionHeading(title: "Token breakdown over time")
            UsageSection {
                Chart(buckets) { bucket in
                    BarMark(
                        x: .value(
                            "Time",
                            bucket.date,
                            unit: range.usesHourlyBuckets ? .hour : .day
                        ),
                        y: .value("Tokens", bucket.tokens)
                    )
                    .foregroundStyle(by: .value("Provider", bucket.provider.displayName))
                    .cornerRadius(2)
                }
                .chartForegroundStyleScale(
                    domain: providers.map(\.displayName),
                    range: providers.map(providerColor)
                )
                .chartLegend(position: .top, alignment: .leading, spacing: 12)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: range.usesHourlyBuckets ? 8 : 10)) {
                        AxisGridLine().foregroundStyle(theme.palette.border)
                        AxisValueLabel(
                            format: range.usesHourlyBuckets
                                ? .dateTime.hour(.defaultDigits(amPM: .abbreviated))
                                : .dateTime.month(.abbreviated).day()
                        )
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(theme.palette.border)
                        AxisValueLabel {
                            if let tokenValue = value.as(Int64.self) {
                                Text(compact(tokenValue))
                            }
                        }
                    }
                }
                .frame(height: 290)
                .accessibilityLabel("Token volume by provider")
                .accessibilityValue(
                    "\(compact(summary.tokens.totalTokens)) tokens across "
                        + countDetail(summary.sessions, unit: "session")
                )
            }
        }
    }

    private func providerBreakdown(_ samples: [UsageSample]) -> some View {
        let providers = Dictionary(grouping: samples, by: \.provider)
            .map { provider, samples in
                (provider, UsageAnalyticsSummary(samples: samples))
            }
            .sorted {
                if $0.1.tokens.totalTokens == $1.1.tokens.totalTokens {
                    return $0.0.displayName < $1.0.displayName
                }
                return $0.1.tokens.totalTokens > $1.1.tokens.totalTokens
            }
        return VStack(alignment: .leading, spacing: 8) {
            UsageSectionHeading(title: "Token breakdown by provider")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(providers, id: \.0) { provider, summary in
                    UsageMetricCard(
                        title: provider.displayName,
                        value: compact(summary.tokens.totalTokens),
                        detail: countDetail(summary.sessions, unit: "session")
                            + " · "
                            + countDetail(summary.requests, unit: "call")
                    )
                }
            }
        }
    }

    private func modelBreakdown(_ samples: [UsageSample]) -> some View {
        let rollups = UsageModelRollup.aggregate(samples)
        let maximum = max(1, rollups.map { $0.tokens.totalTokens }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                UsageSectionHeading(title: "Breakdown by model")
                Spacer()
                Text("Select a model to inspect subscriptions, accounts, and harnesses.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            UsageSection {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Model")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 20)
                        Text("Tokens")
                            .frame(width: 110, alignment: .trailing)
                        Text("Calls")
                            .frame(width: 76, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .padding(.bottom, 8)

                    Divider().overlay(theme.palette.border)

                    ForEach(rollups) { rollup in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 18) {
                                    UsageInlineMetric(
                                        title: "Input",
                                        value: compact(rollup.tokens.totalInputTokens)
                                    )
                                    UsageInlineMetric(
                                        title: "Cached input",
                                        value: compact(rollup.tokens.cachedInputTokens)
                                    )
                                    UsageInlineMetric(
                                        title: "Output",
                                        value: compact(rollup.tokens.outputTokens)
                                    )
                                    Spacer()
                                }
                                if rollup.canonicalModels.count > 1 {
                                    Text("Variants: " + rollup.canonicalModels.joined(separator: ", "))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                }
                                modelDimension(
                                    title: "Subscriptions and billing routes",
                                    rows: rollup.billingRoutes,
                                    total: rollup.tokens.totalTokens,
                                    color: modelColor(rollup.family)
                                )
                                modelDimension(
                                    title: "Harnesses and applications",
                                    rows: rollup.harnesses,
                                    total: rollup.tokens.totalTokens,
                                    color: modelColor(rollup.family)
                                )
                                modelDimension(
                                    title: "Accounts",
                                    rows: rollup.accounts,
                                    total: rollup.tokens.totalTokens,
                                    color: modelColor(rollup.family)
                                )
                            }
                            .padding(.top, 12)
                            .padding(.leading, 20)
                            .padding(.bottom, 14)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(modelColor(rollup.family))
                                        .frame(width: 8, height: 8)
                                    Text(rollup.family)
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(compact(rollup.tokens.totalTokens))
                                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                        .frame(width: 110, alignment: .trailing)
                                    Text(rollup.requests.formatted())
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                        .frame(width: 76, alignment: .trailing)
                                }
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(DashboardPalette.muted)
                                        Capsule()
                                            .fill(modelColor(rollup.family))
                                            .frame(
                                                width: geometry.size.width
                                                    * CGFloat(rollup.tokens.totalTokens)
                                                    / CGFloat(maximum)
                                            )
                                    }
                                }
                                .frame(height: 6)
                            }
                            .padding(.vertical, 12)
                        }
                        if rollup.id != rollups.last?.id {
                            Divider().overlay(theme.palette.border)
                        }
                    }
                }
            }
        }
    }

    private func modelDimension(
        title: String,
        rows: [UsageBreakdownRow],
        total: Int64,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(DashboardPalette.mutedForeground)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 190, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DashboardPalette.muted)
                            Capsule()
                                .fill(color.opacity(0.78))
                                .frame(
                                    width: geometry.size.width
                                        * CGFloat(row.tokens.totalTokens)
                                        / CGFloat(max(1, total))
                                )
                        }
                    }
                    .frame(height: 5)
                    Text(compact(row.tokens.totalTokens))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                    Text(countDetail(row.requests, unit: "call"))
                        .font(.system(size: 10))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .frame(width: 66, alignment: .trailing)
                }
            }
        }
    }

    private func sessionTable(_ samples: [UsageSample]) -> some View {
        let rows = UsageSessionRow.rows(from: samples)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                UsageSectionHeading(title: "Sessions and attribution")
                Spacer()
                Text("Showing \(min(rows.count, 80)) of \(rows.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            UsageSection {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                        GridRow {
                            tableHeading("Model / reasoning", width: 180)
                            tableHeading("Subscription / provider", width: 180)
                            tableHeading("Account", width: 120)
                            tableHeading("Harness / app", width: 150)
                            tableHeading("Latest", width: 120)
                            tableHeading("Tokens", width: 105, alignment: .trailing)
                            tableHeading("Cost", width: 82, alignment: .trailing)
                        }
                        Divider().gridCellColumns(7)
                        ForEach(rows.prefix(80)) { row in
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.modelFamily).lineLimit(1)
                                    Text(row.reasoningLevel ?? "Reasoning not reported")
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                }
                                .frame(width: 180, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.billingRoute).lineLimit(1)
                                    Text(row.billingProvider)
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                }
                                .frame(width: 180, alignment: .leading)

                                Text(row.accountLabel)
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.harness).lineLimit(1)
                                    Text(row.application).foregroundStyle(DashboardPalette.mutedForeground)
                                }
                                .frame(width: 150, alignment: .leading)

                                Text(row.latest, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .frame(width: 120, alignment: .leading)
                                Text(compact(row.tokens.totalTokens))
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .frame(width: 105, alignment: .trailing)
                                Text(row.costUSD.map(currency) ?? "—")
                                    .frame(width: 82, alignment: .trailing)
                            }
                            .font(.system(size: 11.5))
                            .padding(.vertical, 9)
                            .accessibilityElement(children: .combine)
                            if row.id != rows.prefix(80).last?.id {
                                Divider().gridCellColumns(7)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func sourceCoverage(_ sources: [UsageSourceCoverage]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageSectionHeading(title: "Source coverage")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 310), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(sources) { source in
                    UsageSection {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ProviderDot(provider: source.provider)
                                Text(source.sourceName)
                                    .font(.system(size: 12.5, weight: .semibold))
                                if let harness = source.harness,
                                   harness != source.sourceName {
                                    Text(harness)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                }
                                Spacer()
                                UsageStatusPill(
                                    text: source.status.title,
                                    color: source.status.color
                                )
                            }
                            HStack(spacing: 16) {
                                Label(
                                    countDetail(source.discoveredSessions, unit: "session"),
                                    systemImage: "rectangle.stack"
                                )
                                Label(
                                    countDetail(source.attributedSamples, unit: "record"),
                                    systemImage: "number"
                                )
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            Text(source.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(source.location)
                                .font(.system(size: 10.5).monospaced())
                                .foregroundStyle(DashboardPalette.mutedForeground.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accountConnections(_ snapshot: LocalUsageSnapshot) -> some View {
        UsageSection {
            HStack(alignment: .top, spacing: 12) {
                DashboardLucideIcon(glyph: .keyRound, size: 18)
                    .foregroundStyle(theme.palette.themeAccent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect only the accounts you choose")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Nothing on this page checks credentials until you enable that account. Enabled subscription accounts use their provider CLI sign-in; OpenRouter uses only the API key you enter below.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        UsageSectionHeading(title: "Accounts")
        let accountsByProvider = Dictionary(
            uniqueKeysWithValues: snapshot.limits.map { ($0.provider, $0) }
        )
        let accounts = ProviderKind.supportedAccounts.map { provider in
            accountsByProvider[provider] ?? UsageLimitAccount(
                provider: provider,
                accountLabel: provider.displayName,
                status: .needsCredential,
                source: "Disabled",
                detail: "Enable this account to allow local credential discovery and usage checks.",
                dashboardURL: provider.usageDashboardURL
            )
        }
        ViewThatFits(in: .horizontal) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .topLeading),
                    GridItem(.flexible(), alignment: .topLeading),
                ],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(accounts) { account in
                    limitCard(account, pinsFooter: true)
                }
            }
            .frame(minWidth: 720)

            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .topLeading)],
                spacing: 12
            ) {
                ForEach(accounts) { account in
                    limitCard(account, pinsFooter: false)
                }
            }
        }
    }

    private func limitCard(
        _ account: UsageLimitAccount,
        pinsFooter: Bool
    ) -> some View {
        UsageSection {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 9) {
                    ProviderDot(provider: account.provider)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.provider.displayName)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(account.accountLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .lineLimit(1)
                    }
                    Spacer()
                    UsageStatusPill(
                        text: account.isStale ? "Stale" : account.status.title,
                        color: account.status.color
                    )
                }

                if account.provider == .codex,
                   model.codexUsageWorkspaces.count > 1 {
                    codexWorkspaceSelector
                }

                if account.quotaWindows.isEmpty,
                   account.balance == nil,
                   account.providerBudget == nil {
                    Text(account.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 48, alignment: .top)
                } else {
                    ForEach(account.quotaWindows) { window in
                        UsageLimitWindowRow(window: window, color: account.provider.usageColor)
                    }
                    if let balance = account.balance {
                        HStack {
                            Text("Remaining balance")
                            Spacer()
                            Text(money(balance.amountMicros, currency: balance.currency))
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 11.5))
                    }
                    if let budget = account.providerBudget {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(budget.period.map(sentenceCase) ?? "Allowance")
                                Spacer()
                                Text("\(budget.remainingMicros == 0 ? "0" : money(budget.remainingMicros, currency: budget.currency)) left")
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            ProgressView(value: budget.usedPercent, total: 100)
                                .tint(account.provider.usageColor)
                            Text("\(money(budget.usedMicros, currency: budget.currency)) of \(money(budget.limitMicros, currency: budget.currency)) used")
                                .font(.system(size: 10.5))
                                .foregroundStyle(DashboardPalette.mutedForeground)
                        }
                    }
                    if !account.details.isEmpty {
                        VStack(spacing: 5) {
                            ForEach(account.details) { detail in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(detail.label)
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                    Spacer()
                                    Text(detail.value)
                                        .fontWeight(.medium)
                                        .multilineTextAlignment(.trailing)
                                }
                                .font(.system(size: 10.5))
                            }
                        }
                    }
                    if !account.history.isEmpty {
                        Chart(account.history) { point in
                            BarMark(
                                x: .value("Day", point.date, unit: .day),
                                y: .value("Spend", Double(point.valueMicros) / 1_000_000)
                            )
                            .foregroundStyle(account.provider.usageColor.gradient)
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .frame(height: 42)
                        .accessibilityLabel("Daily local spend history")
                    }
                    if let refreshError = account.refreshError {
                        Label(refreshError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DashboardPalette.warning)
                    }
                    Text(account.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if account.provider == .openRouter,
                   model.isUsageProviderEnabled(.openRouter) {
                    openRouterCredentialControls
                }

                if pinsFooter { Spacer(minLength: 12) }
                Divider().overlay(theme.palette.border)
                HStack {
                    Text(account.source)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .lineLimit(1)
                    Spacer()
                    if !model.isUsageProviderEnabled(account.provider) {
                        Button("Enable") {
                            requestCredentialAction(
                                .enableProvider(account.provider)
                            )
                        }
                        .buttonStyle(SettingsQuietButtonStyle())
                    } else if account.provider == .claude,
                              account.status == .signedIn
                                || account.status == .unavailable
                                || account.status == .failed
                                || account.isStale {
                        Button("Retry access") {
                            requestCredentialAction(.retryProvider(.claude))
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                    } else if account.provider == .codex,
                              model.codexUsageWorkspaces.count > 1,
                              account.status != .available,
                              account.status != .signedIn {
                        Button(
                            model.signingInUsageProviders.contains(.codex)
                                ? "Reconnecting…"
                                : "Reconnect"
                        ) {
                            model.reconnectSelectedCodexUsageWorkspace()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .disabled(
                            model.signingInUsageProviders.contains(.codex)
                                || model.isRefreshingLocalUsage
                        )
                    } else if account.provider != .openRouter,
                              account.status != .available,
                              account.status != .signedIn {
                        Button(
                            model.signingInUsageProviders.contains(account.provider)
                                ? "Signing in…"
                                : "Sign in"
                        ) {
                            model.signInUsageProvider(account.provider)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .disabled(
                            model.signingInUsageProviders.contains(account.provider)
                        )
                    }
                    if model.isUsageProviderEnabled(account.provider) {
                        Button("Disable") {
                            Task {
                                await model.disableUsageProvider(
                                    account.provider,
                                    range: range
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    if let dashboardURL = account.dashboardURL {
                        Link("Open dashboard", destination: dashboardURL)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: pinsFooter ? .infinity : nil,
                alignment: .topLeading
            )
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: pinsFooter ? .infinity : nil,
            alignment: .topLeading
        )
    }

    private var codexWorkspaceSelector: some View {
        HStack(spacing: 8) {
            Text("Workspace")
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
            Spacer()
            Menu {
                ForEach(model.codexUsageWorkspaces) { workspace in
                    Button {
                        Task {
                            await model.selectCodexUsageWorkspace(
                                workspace.id,
                                range: range
                            )
                        }
                    } label: {
                        if workspace.id == model.selectedCodexUsageWorkspaceID {
                            Label(workspace.selectionLabel, systemImage: "checkmark")
                        } else {
                            Text(workspace.selectionLabel)
                        }
                    }
                }
            } label: {
                Text(selectedCodexWorkspace?.name ?? "Choose workspace")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isRefreshingUsageLimits)
        }
    }

    private var selectedCodexWorkspace: CodexUsageWorkspace? {
        model.codexUsageWorkspaces.first {
            $0.id == model.selectedCodexUsageWorkspaceID
        }
    }

    private var openRouterCredentialControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(openRouterConnectionLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                Spacer()
                if model.isOpenRouterCredentialConfigured {
                    Button("Remove", role: .destructive) {
                        requestCredentialAction(.deleteOpenRouter)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.danger)
                }
            }
            SecureField(
                model.isOpenRouterCredentialConfigured
                    ? "Enter a replacement key"
                    : "OpenRouter API key",
                text: $openRouterAPIKey
            )
            .textFieldStyle(.roundedBorder)
            Button(model.isOpenRouterCredentialConfigured ? "Replace key" : "Save API key") {
                requestCredentialAction(.saveOpenRouter(openRouterAPIKey))
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
            .disabled(
                openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isRefreshingLocalUsage
            )
        }
    }

    private var openRouterConnectionLabel: String {
        if model.isOpenRouterCredentialConfigured {
            return model.isUsageProviderEnabled(.openRouter)
                ? "Connected" : "Saved — access disabled"
        }
        return "Not connected"
    }

    private func requestCredentialAction(
        _ action: PendingUsageCredentialAction
    ) {
        if model.hasAcknowledgedCredentialAccessDisclosure {
            performCredentialAction(action)
        } else {
            pendingCredentialAction = action
        }
    }

    private func performCredentialAction(
        _ action: PendingUsageCredentialAction
    ) {
        switch action {
        case .enableProvider(let provider):
            Task {
                await model.enableUsageProvider(provider, range: range)
            }
        case .retryProvider(let provider):
            Task {
                await model.retryUsageProviderCredentialAccess(
                    provider,
                    range: range
                )
            }
        case .saveOpenRouter(let key):
            Task {
                await model.saveOpenRouterAPIKey(key, range: range)
                if model.localUsageError == nil { openRouterAPIKey = "" }
            }
        case .deleteOpenRouter:
            Task {
                await model.deleteOpenRouterAPIKey(range: range)
                if model.localUsageError == nil { openRouterAPIKey = "" }
            }
        }
    }

    private func tableHeading(
        _ title: String,
        width: CGFloat,
        alignment: Alignment = .leading
    ) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(DashboardPalette.mutedForeground)
            .frame(width: width, alignment: alignment)
            .padding(.bottom, 8)
    }

    private var hasActiveFilters: Bool {
        providerFilter != "all" || modelFilter != "all" || harnessFilter != "all"
            || billingRouteFilter != "all" || reasoningFilter != "all"
            || !searchText.isEmpty
    }

    private func clearFilters() {
        providerFilter = "all"
        modelFilter = "all"
        billingRouteFilter = "all"
        harnessFilter = "all"
        reasoningFilter = "all"
        searchText = ""
    }

    private func searchableText(_ sample: UsageSample) -> String {
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

    private func compact(_ value: Int64) -> String {
        let magnitude = Double(value)
        if magnitude >= 1_000_000_000 { return String(format: "%.1fB", magnitude / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.1fM", magnitude / 1_000_000) }
        if magnitude >= 1_000 { return String(format: "%.1fK", magnitude / 1_000) }
        return value.formatted()
    }

    private func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + String(value.dropFirst())
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 3 : 2)))
    }

    private func money(_ micros: Int64, currency: String) -> String {
        (Double(micros) / 1_000_000).formatted(
            .currency(code: currency).precision(.fractionLength(2))
        )
    }

    private func cacheRateDetail(_ tokens: UsageTokenCounts) -> String {
        let input = tokens.totalInputTokens
        guard input > 0 else { return "No input reported" }
        let percent = Double(tokens.cachedInputTokens) / Double(input) * 100
        return "\(percent.formatted(.number.precision(.fractionLength(0))))% cache-read share"
    }

    private func modelCountDetail(_ samples: [UsageSample]) -> String {
        let models = Set(samples.map(\.modelFamily)).count
        return "\(models) model\(models == 1 ? "" : "s")"
    }

    private func countDetail(_ count: Int, unit: String) -> String {
        "\(count.formatted()) \(unit)\(count == 1 ? "" : "s")"
    }

    private func providerColor(_ provider: ProviderKind) -> Color {
        switch provider {
        case .codex: .hex(0x0D8F5A)
        case .claude: .hex(0xC46B3C)
        case .grok: .hex(0x535A63)
        case .cursor: .hex(0x4D69D8)
        case .openCodeGo: .hex(0x8B5CF6)
        case .openRouter: .hex(0xE05D8B)
        case .unknown: .hex(0x8A8F98)
        }
    }

    private func modelColor(_ model: String) -> Color {
        let colors: [Color] = [
            .hex(0x4D69D8),
            .hex(0x0D8F5A),
            .hex(0xC46B3C),
            .hex(0x8B5CF6),
            .hex(0xE05D8B),
            .hex(0xC28A20),
            .hex(0x535A63),
        ]
        let hash = model.utf8.reduce(UInt32(2_166_136_261)) {
            ($0 ^ UInt32($1)) &* 16_777_619
        }
        return colors[Int(hash % UInt32(colors.count))]
    }
}

private struct UsageFilterSelector: View {
    @Environment(\.dashboardTheme) private var theme
    let title: String
    @Binding var selection: String
    let options: [(key: String, label: String)]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selectedLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(DashboardPalette.foreground)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(theme.palette.themeWhisper)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options, id: \.key) { option in
                    Button {
                        selection = option.key
                        isPresented = false
                    } label: {
                        HStack {
                            Text(option.label)
                                .font(.system(size: 13))
                                .foregroundStyle(DashboardPalette.foreground)
                            Spacer()
                            if option.key == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DashboardPalette.primary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(minWidth: 180)
        }
    }

    private var selectedLabel: String {
        options.first { $0.key == selection }?.label ?? options.first?.label ?? title
    }
}

private struct ProviderUsageChartBucket: Identifiable {
    let date: Date
    let provider: ProviderKind
    let tokens: Int64

    var id: String { "\(date.timeIntervalSinceReferenceDate):\(provider.rawValue)" }

    static func aggregate(
        samples: [UsageSample],
        range: UsageTimeRange,
        calendar: Calendar = .current
    ) -> [ProviderUsageChartBucket] {
        var totals: [String: (date: Date, provider: ProviderKind, tokens: Int64)] = [:]
        for sample in samples {
            let start = range.usesHourlyBuckets
                ? calendar.dateInterval(of: .hour, for: sample.timestamp)?.start ?? sample.timestamp
                : calendar.startOfDay(for: sample.timestamp)
            let key = "\(start.timeIntervalSinceReferenceDate):\(sample.provider.rawValue)"
            let current = totals[key]?.tokens ?? 0
            let (sum, overflow) = current.addingReportingOverflow(sample.tokens.totalTokens)
            totals[key] = (start, sample.provider, overflow ? Int64.max : sum)
        }
        return totals.values
            .map { ProviderUsageChartBucket(date: $0.date, provider: $0.provider, tokens: $0.tokens) }
            .sorted {
                $0.date == $1.date
                    ? $0.provider.rawValue < $1.provider.rawValue
                    : $0.date < $1.date
            }
    }
}

private struct UsageInlineMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(DashboardPalette.mutedForeground)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
    }
}

private struct UsageSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
    }
}

private struct UsageSectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(DashboardPalette.mutedForeground)
    }
}

private struct UsageMetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        UsageSection {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(DashboardPalette.mutedForeground)
                Text(value)
                    .font(.system(size: 21, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UsageSessionRow: Identifiable {
    let id: String
    let modelFamily: String
    let billingProvider: String
    let billingRoute: String
    let accountLabel: String
    let reasoningLevel: String?
    let harness: String
    let application: String
    let latest: Date
    let tokens: UsageTokenCounts
    let costUSD: Double?

    static func rows(from samples: [UsageSample]) -> [UsageSessionRow] {
        Dictionary(
            grouping: samples,
            by: {
                "\($0.sourceID):\($0.sessionID):\($0.modelFamily):\($0.billingRoute)"
            }
        )
        .compactMap { id, values in
            guard let latest = values.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            let tokens = values.reduce(.zero) { $0 + $1.tokens }
            let costs = values.compactMap(\.directCostUSD)
            return UsageSessionRow(
                id: id,
                modelFamily: latest.modelFamily,
                billingProvider: latest.billingProvider,
                billingRoute: latest.billingRoute,
                accountLabel: latest.accountLabel,
                reasoningLevel: latest.reasoningLevel,
                harness: latest.harness,
                application: latest.application,
                latest: latest.timestamp,
                tokens: tokens,
                costUSD: costs.isEmpty ? nil : costs.reduce(0, +)
            )
        }
        .sorted { $0.latest > $1.latest }
    }
}

private struct ProviderDot: View {
    let provider: ProviderKind

    var body: some View {
        Circle()
            .fill(provider.usageColor)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
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
            .padding(.vertical, 4)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }
}

private struct UsageLimitWindowRow: View {
    let window: ProviderQuotaWindow
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text(window.usageKnown ? "\(window.remainingPercent, specifier: "%.0f")% left" : "Unavailable")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            }
            if window.usageKnown {
                ProgressView(value: window.usedPercent, total: 100)
                    .tint(color)
                HStack {
                    Text("\(window.usedPercent, specifier: "%.0f")% used")
                    Spacer()
                    if let resetsAt = window.resetsAt {
                        Text("Resets \(resetsAt, format: .relative(presentation: .named))")
                    } else if let resetDescription = window.resetDescription {
                        Text(resetDescription)
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UsageErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            DashboardLucideIcon(glyph: .alertTriangle, size: 14)
                .foregroundStyle(DashboardPalette.danger)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(DashboardPalette.danger)
            Spacer()
        }
        .padding(12)
        .background(DashboardPalette.danger.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
    }
}

private struct UsageLoadingCard: View {
    let isLoading: Bool

    var body: some View {
        UsageSection {
            HStack(spacing: 10) {
                if isLoading { ProgressView().controlSize(.small) }
                Text(isLoading ? "Updating the persistent usage index…" : "Usage has not been loaded yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
        }
    }
}

private struct UsageEmptyCard: View {
    let title: String
    let detail: String

    var body: some View {
        UsageSection {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
        }
    }
}

private extension ProviderKind {
    var usageColor: Color {
        switch self {
        case .codex: Color.hex(0x0D8F5A)
        case .claude: Color.hex(0xC46B3C)
        case .grok: Color.hex(0x535A63)
        case .cursor: Color.hex(0x4D69D8)
        case .openCodeGo: Color.hex(0x8B5CF6)
        case .openRouter: Color.hex(0xE05D8B)
        case .unknown: DashboardPalette.mutedForeground
        }
    }

    var usageDashboardURL: URL? {
        switch self {
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")
        case .claude: URL(string: "https://claude.ai/settings/usage")
        case .grok: URL(string: "https://grok.com/?_s=usage")
        case .cursor: URL(string: "https://cursor.com/dashboard?tab=usage")
        case .openCodeGo: URL(string: "https://opencode.ai/auth")
        case .openRouter: URL(string: "https://openrouter.ai/settings/credits")
        case .unknown: nil
        }
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
        case .available: DashboardPalette.success
        case .partial: DashboardPalette.warning
        case .notFound, .unavailable: DashboardPalette.mutedForeground
        case .failed: DashboardPalette.danger
        }
    }
}

private extension UsageLimitStatus {
    var title: String {
        switch self {
        case .available: "Live"
        case .signedIn: "Signed in"
        case .needsCredential: "Needs sign-in"
        case .unavailable: "Unavailable"
        case .failed: "Needs attention"
        }
    }

    var color: Color {
        switch self {
        case .available: DashboardPalette.success
        case .signedIn: Color.hex(0x4D69D8)
        case .needsCredential: DashboardPalette.warning
        case .unavailable: DashboardPalette.mutedForeground
        case .failed: DashboardPalette.danger
        }
    }
}

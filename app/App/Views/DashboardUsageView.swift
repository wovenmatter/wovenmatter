import SwiftUI
import WovenMatterCore
import WovenMatterDashboardStore

enum DashboardUsagePage: String, CaseIterable, Identifiable {
    case analytics
    case limits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .analytics: "Analytics"
        case .limits: "Limits"
        }
    }
}

struct DashboardUsageView: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    @AppStorage("wovenmatter.usage.page") private var page = DashboardUsagePage.analytics
    @AppStorage("wovenmatter.usage.chart-style") private var chartStyle = UsageChartStyle.lines
    @AppStorage("wovenmatter.usage.chart-metric") private var chartMetric = UsageChartMetric.tokens
    @State private var range: UsageTimeRange = {
        let rawValue = UserDefaults.standard.string(forKey: "wovenmatter.usage.range")
        return rawValue.flatMap(UsageTimeRange.init(rawValue:)) ?? .last30Days
    }()
    @State private var filters = UsageAnalyticsFilters()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.palette.border)
                .frame(height: 1)
            if let error = model.localUsageError {
                UsageErrorBanner(text: error)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            if let snapshot = model.localUsage {
                switch page {
                case .analytics:
                    UsageAnalyticsPage(
                        snapshot: snapshot.analytics,
                        filters: $filters,
                        range: rangeSelectionBinding,
                        chartStyle: $chartStyle,
                        chartMetric: $chartMetric,
                        devices: model.usageDevices,
                        prices: model.usagePrices,
                        isRefreshing: model.isRefreshingLocalUsage,
                        retryPrices: { Task { await model.loadUsagePrices(force: true) } }
                    )
                case .limits:
                    ScrollView {
                        UsageLimitsPage(
                            accounts: UsageLimitsPage.accounts(
                                from: snapshot,
                                isRefreshingLimits: model.isRefreshingUsageLimits,
                                error: model.localUsageError
                            )
                        )
                        .frame(maxWidth: 880, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.never)
                }
            } else {
                UsageLoadingCard(isLoading: model.isRefreshingLocalUsage)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.palette.workspace)
        .task {
            await model.usageDestinationAppeared(range: range)
        }
        // Prices download only after the person chooses API estimates.
        .task(id: chartMetric) {
            if chartMetric == .apiEstimate { await model.loadUsagePrices() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Usage")
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
            DashboardSegmentedSelector(
                options: DashboardUsagePage.allCases,
                selection: pageBinding
            ) { $0.title }
            .frame(width: 168)
            Spacer(minLength: 8)
            if page == .limits {
                UsageSettingsLink()
            } else if let generatedAt = model.localUsage?.analytics.generatedAt {
                Text("Updated \(generatedAt, format: .relative(presentation: .named))")
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
            }
            Button {
                Task {
                    async let usage: Void = model.refreshLocalUsage(
                        range: range,
                        refreshLimits: page == .limits,
                        reason: .manual
                    )
                    if page == .analytics, chartMetric == .apiEstimate {
                        await model.loadUsagePrices(force: true)
                    }
                    await usage
                }
            } label: {
                Group {
                    if model.isRefreshingLocalUsage {
                        ProgressView().controlSize(.small)
                    } else {
                        DashboardLucideIcon(glyph: .rotate, size: 14)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(DashboardIconButtonStyle())
            .disabled(model.isRefreshingLocalUsage)
            .help("Refresh")
            .accessibilityLabel(model.isRefreshingLocalUsage ? "Refreshing" : "Refresh")
        }
        // The reveal-rail buttons float over this corner when a sidebar is hidden.
        .padding(.horizontal, reservesRailControlSpace ? 60 : 20)
        .frame(minHeight: reservesRailControlSpace ? 60 : 54)
    }

    private var pageBinding: Binding<DashboardUsagePage> {
        Binding(
            get: { page },
            set: { value in
                page = value
                if value == .analytics {
                    Task { await model.usageAnalyticsSelected(range: range) }
                }
            }
        )
    }

    private var rangeSelectionBinding: Binding<UsageTimeRange> {
        Binding(
            get: { range },
            set: { value in
                guard value != range else { return }
                range = value
                UserDefaults.standard.set(value.rawValue, forKey: "wovenmatter.usage.range")
                Task {
                    await model.refreshLocalUsage(range: value, reason: .rangeChanged)
                }
            }
        )
    }
}

struct UsageSectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DashboardPalette.mutedForeground)
    }
}

/// A provider's identity mark. Text beside it always names the provider too.
struct UsageProviderSwatch: View {
    let provider: ProviderKind

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(provider.usageColor)
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
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
        HStack(spacing: 10) {
            if isLoading { ProgressView().controlSize(.small) }
            Text(isLoading ? "Updating the persistent usage index…" : "Usage has not been loaded yet.")
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
}

/// Number and time formatting shared by the Usage pages.
enum UsageFormat {
    static func tokens(_ value: Int64) -> String {
        let magnitude = Double(value)
        if magnitude >= 1_000_000_000 { return String(format: "%.1fB", magnitude / 1_000_000_000) }
        if magnitude >= 1_000_000 { return String(format: "%.1fM", magnitude / 1_000_000) }
        if magnitude >= 1_000 { return String(format: "%.1fK", magnitude / 1_000) }
        return value.formatted()
    }

    /// Axis ticks are round, so a trailing .0 is noise.
    static func tokensAxis(_ value: Double) -> String {
        tokens(Int64(value.rounded())).replacingOccurrences(of: ".0", with: "")
    }

    static func usd(_ value: Double) -> String {
        if value > 0, value < 0.01 { return "<$0.01" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func usdCompact(_ value: Double) -> String {
        if value >= 1_000 { return usdAxis(value) }
        if value >= 100 { return value.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
        return usd(value)
    }

    static func usdAxis(_ value: Double) -> String {
        if value >= 1_000_000 {
            return "$" + String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".0", with: "")
        }
        if value >= 1_000 {
            return "$" + String(format: "%.1fK", value / 1_000).replacingOccurrences(of: ".0", with: "")
        }
        return value.rounded() == value
            ? value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
            : usd(value)
    }

    /// Direct spend keeps a third decimal below a dollar, where small charges add up.
    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 ? 3 : 2)))
    }

    static func money(_ micros: Int64, currency: String) -> String {
        (Double(micros) / 1_000_000).formatted(.currency(code: currency).precision(.fractionLength(2)))
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func count(_ count: Int, unit: String) -> String {
        "\(count.formatted()) \(unit)\(count == 1 ? "" : "s")"
    }

    static func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + String(value.dropFirst())
    }

    static func resetText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Resets soon" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "Resets in \(minutes)m" }
        if minutes < 24 * 60 {
            let remainder = minutes % 60
            return remainder == 0
                ? "Resets in \(minutes / 60)h"
                : "Resets in \(minutes / 60)h \(remainder)m"
        }
        if seconds < 7 * 24 * 60 * 60 {
            return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour(.defaultDigits(amPM: .abbreviated))))"
        }
        return "Resets \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

extension ProviderKind {
    /// The short name used across the Usage pages.
    var usageName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .cursor: "Cursor"
        case .openCodeGo: "OpenCode Go"
        case .openRouter: "OpenRouter"
        case .unknown: "Unknown"
        }
    }

    var usageColor: Color {
        switch self {
        case .codex: DashboardPalette.usageGreen
        case .claude: DashboardPalette.usageOrange
        case .grok: DashboardPalette.usageTeal
        case .cursor: DashboardPalette.usageBlue
        case .openCodeGo: DashboardPalette.usagePurple
        case .openRouter: DashboardPalette.usagePink
        case .unknown: DashboardPalette.usageUnknown
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

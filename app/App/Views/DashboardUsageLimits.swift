import Charts
import SwiftUI
import WovenMatterCore

enum UsageLimitPace {
    /// Where even spending would be, as the share of the window still to come.
    /// A remaining bar shorter than this is running ahead of pace.
    static func remainingFraction(of window: ProviderQuotaWindow, now: Date) -> Double? {
        guard let resetsAt = window.resetsAt,
              let minutes = window.windowMinutes,
              minutes > 0 else { return nil }
        let length = TimeInterval(minutes) * 60
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining >= 0, remaining <= length else { return nil }
        return remaining / length
    }
}

/// Saved accounts as full-width rows. Signed-out providers collapse to one line.
struct UsageLimitsPage: View {
    let accounts: [UsageLimitAccount]

    private var active: [UsageLimitAccount] {
        accounts.filter { !$0.isSignedOutPlaceholder }
    }
    private var signedOut: [UsageLimitAccount] {
        accounts.filter(\.isSignedOutPlaceholder)
    }

    /// Every supported provider appears, so a missing account is never mistaken for no usage.
    static func accounts(
        from snapshot: LocalUsageSnapshot,
        isRefreshingLimits: Bool,
        error: String?
    ) -> [UsageLimitAccount] {
        ProviderKind.supportedAccounts.flatMap { provider -> [UsageLimitAccount] in
            let saved = snapshot.limits.filter { $0.provider == provider }
            guard saved.isEmpty else { return saved }
            let unchecked = isRefreshingLimits || error != nil
            return [UsageLimitAccount(
                provider: provider,
                accountLabel: provider.usageName,
                status: unchecked ? .unavailable : .needsCredential,
                source: "Saved accounts",
                detail: error != nil
                    ? "Saved accounts could not be checked. Review the error above."
                    : isRefreshingLimits
                        ? "Checking saved accounts…"
                        : "Not signed in. Add an account in Settings → Usage.",
                dashboardURL: provider.usageDashboardURL
            )]
        }
    }

    var body: some View {
        // Reset times and pace marks move with the clock, not only with a refresh.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 24) {
                ForEach(active) { account in
                    UsageLimitAccountRows(account: account, now: context.date)
                }
                if !signedOut.isEmpty {
                    Text("Not signed in: " + signedOut.map(\.provider.usageName).joined(separator: ", "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .accessibilityHint("Add an account in Settings → Usage.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UsageLimitAccountRows: View {
    let account: UsageLimitAccount
    let now: Date

    private var hasLimits: Bool {
        !account.quotaWindows.isEmpty || account.balance != nil || account.providerBudget != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if hasLimits {
                limitRows
                if !account.details.isEmpty { detailRows }
                if let refreshError = account.refreshError {
                    Label(refreshError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashboardPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(account.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            UsageProviderSwatch(provider: account.provider)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(account.provider.usageName)
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 5) {
                if account.accountLabel != account.provider.usageName,
                   account.accountLabel != account.provider.displayName {
                    Text(account.accountLabel).lineLimit(1)
                    Text("·")
                }
                Text(account.isStale ? "Needs attention" : account.status.title)
                    .foregroundStyle(
                        account.isStale ? DashboardPalette.warning : account.status.headerColor
                    )
            }
            .font(.system(size: 11))
            .foregroundStyle(DashboardPalette.mutedForeground)
            Spacer(minLength: 12)
            if let balance = account.balance {
                Text("\(UsageFormat.money(balance.amountMicros, currency: balance.currency)) remaining")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            if let dashboardURL = account.dashboardURL {
                Link("Open dashboard", destination: dashboardURL)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DashboardPalette.success)
            }
        }
        .help(hasLimits ? "\(account.source). \(account.detail)" : account.source)
        .accessibilityElement(children: .combine)
    }

    private var limitRows: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            ForEach(account.quotaWindows) { window in
                windowRow(window)
            }
            if let budget = account.providerBudget {
                budgetRow(budget)
            }
            if !account.history.isEmpty {
                historyRow
            }
        }
        .padding(.leading, 16)
    }

    private func windowRow(_ window: ProviderQuotaWindow) -> some View {
        let pace = window.usageKnown ? UsageLimitPace.remainingFraction(of: window, now: now) : nil
        return GridRow {
            limitLabel(window.label)
            UsageLimitBar(
                remaining: window.usageKnown ? window.remainingPercent / 100 : nil,
                pace: pace,
                color: account.provider.usageColor
            )
            .help(paceHelp(window, pace: pace))
            limitValue(window.usageKnown ? "\(Int(window.remainingPercent.rounded()))% left" : "Unavailable")
            limitTrailing(resetText(window))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.label)
        .accessibilityValue(
            [
                window.usageKnown ? "\(Int(window.remainingPercent.rounded()))% left" : "Unavailable",
                resetText(window),
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
    }

    private func budgetRow(_ budget: ProviderReportedBudget) -> some View {
        GridRow {
            limitLabel(budget.period.map(UsageFormat.sentenceCase) ?? "Allowance")
            UsageLimitBar(
                remaining: max(0, 100 - budget.usedPercent) / 100,
                pace: nil,
                color: account.provider.usageColor
            )
            limitValue(
                budget.remainingMicros == 0
                    ? "0 left"
                    : "\(UsageFormat.money(budget.remainingMicros, currency: budget.currency)) left"
            )
            limitTrailing(
                "\(UsageFormat.money(budget.usedMicros, currency: budget.currency)) of "
                    + UsageFormat.money(budget.limitMicros, currency: budget.currency)
            )
        }
    }

    private func limitLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .lineLimit(1)
            .frame(width: 128, alignment: .leading)
            .help(text)
    }

    private func limitValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: 78, alignment: .trailing)
    }

    private func limitTrailing(_ text: String?) -> some View {
        Text(text ?? "")
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(DashboardPalette.mutedForeground)
            .lineLimit(1)
            .frame(width: 118, alignment: .leading)
    }

    private func resetText(_ window: ProviderQuotaWindow) -> String? {
        if let resetsAt = window.resetsAt { return UsageFormat.resetText(resetsAt, now: now) }
        return window.resetDescription
    }

    private func paceHelp(_ window: ProviderQuotaWindow, pace: Double?) -> String {
        guard window.usageKnown else { return "The provider did not report this limit." }
        let left = "\(Int(window.remainingPercent.rounded()))% left"
        guard let pace else { return left }
        return "\(left), \(Int((pace * 100).rounded()))% of the window left. The line marks even spending."
    }

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(account.details) { detail in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(detail.label)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .frame(width: 128, alignment: .leading)
                    Text(detail.value)
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.leading, 16)
    }

    private var historyRow: some View {
        GridRow {
            limitLabel("Daily spend")
            Chart(account.history) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Spend", Double(point.valueMicros) / 1_000_000)
                )
                .foregroundStyle(account.provider.usageColor)
                .cornerRadius(1.5)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 28)
            .accessibilityLabel("Daily local spend history")
            limitValue("")
            limitTrailing(nil)
        }
    }
}

/// What is left in a limit, with a tick where even spending would be.
private struct UsageLimitBar: View {
    @Environment(\.dashboardTheme) private var theme
    /// Nil when the provider did not report usage, so no fill suggests a known amount.
    let remaining: Double?
    let pace: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DashboardPalette.muted)
                    .frame(height: 6)
                if let remaining, remaining > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(6, width * remaining), height: 6)
                }
                if let pace {
                    // The surface-colored edge keeps the tick readable over the fill.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(DashboardPalette.foreground)
                        .frame(width: 2, height: 12)
                        .padding(.horizontal, 1.5)
                        .background(theme.palette.workspace)
                        .offset(x: min(max(0, width * pace - 2.5), max(0, width - 5)))
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: 12)
        .frame(minWidth: 60, maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

private extension UsageLimitAccount {
    var isSignedOutPlaceholder: Bool {
        status == .needsCredential
            && quotaWindows.isEmpty
            && balance == nil
            && providerBudget == nil
    }
}

private extension UsageLimitStatus {
    var title: String {
        switch self {
        case .available, .signedIn: "Signed in"
        case .needsCredential: "Needs sign-in"
        case .unavailable: "Unavailable"
        case .failed: "Needs attention"
        }
    }

    /// A healthy account stays quiet, and problems take a status color.
    var headerColor: Color {
        switch self {
        case .available, .signedIn, .unavailable: DashboardPalette.mutedForeground
        case .needsCredential: DashboardPalette.warning
        case .failed: DashboardPalette.danger
        }
    }
}

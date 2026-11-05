import Charts
import SwiftUI
import WovenMatterCore

enum UsageChartStyle: String, CaseIterable, Identifiable {
    case lines
    case bars

    var id: String { rawValue }
    var title: String { self == .lines ? "Lines" : "Bars" }
}

enum UsageChartMetric: String, CaseIterable, Identifiable {
    case tokens
    case apiEstimate

    var id: String { rawValue }
    var title: String { self == .tokens ? "Tokens" : "API estimate" }

    func axisLabel(_ value: Double) -> String {
        guard value > 0 else { return "0" }
        return self == .tokens ? UsageFormat.tokensAxis(value) : UsageFormat.usdAxis(value)
    }

    func valueLabel(_ value: Double) -> String {
        self == .tokens ? UsageFormat.tokens(Int64(value.rounded())) : UsageFormat.usd(value)
    }
}

/// One time period in the chart, including periods with no usage.
struct UsageChartColumn: Identifiable, Equatable {
    let index: Int
    let start: Date
    let values: [ProviderKind: Double]

    var id: Int { index }
    var total: Double { values.values.reduce(0, +) }
}

struct UsageChartData: Equatable {
    private static let earliestPlausibleUsage = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01

    let columns: [UsageChartColumn]
    /// Providers with usage, in fixed order so a filter never repaints the others.
    let providers: [ProviderKind]
    let usesHourlyBuckets: Bool

    var isEmpty: Bool { providers.isEmpty }

    /// `value` receives every sample for one provider in one period.
    static func build(
        samples: [UsageSample],
        range: UsageTimeRange,
        now: Date,
        calendar: Calendar = .current,
        value: ([UsageSample]) -> Double
    ) -> UsageChartData {
        let unit: Calendar.Component = range.usesHourlyBuckets ? .hour : .day
        func bucket(_ date: Date) -> Date {
            calendar.dateInterval(of: unit, for: date)?.start ?? date
        }
        let interval = range.interval(relativeTo: now, calendar: calendar)
        // All time starts at the first record rather than at the start of the index,
        // and a bad old timestamp can't stretch the axis across decades of empty days.
        let earliest = range == .allTime
            ? max(samples.map(\.timestamp).min() ?? now, min(earliestPlausibleUsage, now))
            : interval.start
        let first = bucket(earliest)
        // The interval's end is exclusive, so the period holding it may not be in range.
        let last = max(first, bucket(interval.end.addingTimeInterval(-1)))

        var grouped: [Date: [ProviderKind: [UsageSample]]] = [:]
        for sample in samples {
            // Keeps a stray timestamp in the chart total without stretching the axis.
            let start = min(max(bucket(sample.timestamp), first), last)
            grouped[start, default: [:]][sample.provider, default: []].append(sample)
        }

        var columns: [UsageChartColumn] = []
        var cursor = first
        while cursor <= last {
            let values = (grouped[cursor] ?? [:]).mapValues(value)
            columns.append(UsageChartColumn(index: columns.count, start: cursor, values: values))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        let present = Set(columns.flatMap { column in
            column.values.filter { $0.value > 0 }.keys
        })
        return UsageChartData(
            columns: columns,
            providers: ProviderKind.allCases.filter(present.contains),
            usesHourlyBuckets: range.usesHourlyBuckets
        )
    }

    func peak(for style: UsageChartStyle) -> Double {
        columns.reduce(0) { peak, column in
            let value = style == .bars ? column.total : (column.values.values.max() ?? 0)
            return max(peak, value)
        }
    }

    /// Largest series first so smaller lines draw on top.
    var providersByTotal: [ProviderKind] {
        providers.sorted { lhs, rhs in
            let left = columns.reduce(0) { $0 + ($1.values[lhs] ?? 0) }
            let right = columns.reduce(0) { $0 + ($1.values[rhs] ?? 0) }
            return left == right ? lhs.rawValue < rhs.rawValue : left > right
        }
    }
}

/// Round axis values with a little headroom above the tallest mark.
struct UsageChartScale: Equatable {
    let maximum: Double
    let ticks: [Double]

    static func nice(peak: Double, tickCount: Int = 4) -> UsageChartScale {
        guard peak > 0, peak.isFinite else { return UsageChartScale(maximum: 1, ticks: [0]) }
        let rawStep = peak / Double(tickCount)
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let step = (normalized > 5 ? 10 : normalized > 2 ? 5 : normalized > 1 ? 2 : 1) * magnitude
        let maximum = ceil(peak / step) * step
        let count = Int((maximum / step).rounded())
        return UsageChartScale(maximum: maximum, ticks: (0...count).map { Double($0) * step })
    }
}

/// The main Usage graph. Periods keep a minimum width, so a long range scrolls
/// sideways under a fixed y-axis and opens on the most recent period.
struct UsageChart: View {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let data: UsageChartData
    let style: UsageChartStyle
    let metric: UsageChartMetric

    @State private var hoveredIndex: Int?
    @State private var viewportWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var position = ScrollPosition(edge: .trailing)
    @State private var tooltipSize = CGSize.zero

    private static let plotHeight: CGFloat = 248
    private static let topInset: CGFloat = 8
    private static let axisHeight: CGFloat = 22
    private static let yAxisWidth: CGFloat = 42
    // Thirty days fit at the smallest window with both sidebars open; 90 days scroll.
    private static let minimumPeriodWidth: CGFloat = 13
    private static let minimumLabelSpacing: CGFloat = 62

    private var contentWidth: CGFloat {
        max(viewportWidth, CGFloat(data.columns.count) * Self.minimumPeriodWidth)
    }
    private var periodWidth: CGFloat {
        data.columns.isEmpty ? 0 : contentWidth / CGFloat(data.columns.count)
    }
    private var maximumOffset: CGFloat { max(0, contentWidth - viewportWidth) }
    private var isScrollable: Bool { maximumOffset > 1 }

    var body: some View {
        let scale = UsageChartScale.nice(peak: data.peak(for: style))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                yAxis(scale)
                viewport(scale)
            }
            if isScrollable { scrollFooter }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(metric.title) by provider over time")
    }

    private func yAxis(_ scale: UsageChartScale) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(scale.ticks, id: \.self) { tick in
                Text(metric.axisLabel(tick))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .frame(height: 14)
                    .offset(y: Self.topInset + y(for: tick, scale: scale) - 7)
            }
        }
        .frame(
            width: Self.yAxisWidth,
            height: Self.topInset + Self.plotHeight + Self.axisHeight,
            alignment: .topTrailing
        )
        .accessibilityHidden(true)
    }

    private func y(for value: Double, scale: UsageChartScale) -> CGFloat {
        Self.plotHeight * (1 - CGFloat(value / scale.maximum))
    }

    private func viewport(_ scale: UsageChartScale) -> some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                UsageChartPlot(
                    data: data,
                    style: style,
                    scale: scale,
                    width: contentWidth,
                    plotHeight: Self.plotHeight,
                    gridColor: theme.palette.border
                )
                .equatable()
                .padding(.top, Self.topInset)
                xAxis
            }
            .frame(width: contentWidth, alignment: .leading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    guard periodWidth > 0 else { return }
                    let index = Int(location.x / periodWidth)
                    hoveredIndex = min(max(0, index), data.columns.count - 1)
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, offset in
            scrollOffset = offset
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { viewportWidth = $0 }
        .onChange(of: data.columns.count) { _, _ in position.scrollTo(edge: .trailing) }
        .frame(maxWidth: .infinity)
        .frame(height: Self.topInset + Self.plotHeight + Self.axisHeight)
        .overlay { edgeFades }
        .overlay(alignment: .topLeading) {
            if let hoveredIndex, data.columns.indices.contains(hoveredIndex) {
                hoverLayer(data.columns[hoveredIndex], scale: scale)
            }
        }
        .clipped()
    }

    private var xAxis: some View {
        let spacing = max(1, Int(ceil(Self.minimumLabelSpacing / max(periodWidth, 1))))
        let count = data.columns.count
        // Counted back from the latest period so the most recent one is always labeled.
        let labeled = stride(from: count - 1, through: 0, by: -spacing).map { $0 }
        return ZStack(alignment: .topLeading) {
            ForEach(labeled, id: \.self) { index in
                Text(axisLabel(data.columns[index].start))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
                    .fixedSize()
                    .position(
                        x: min(
                            max((CGFloat(index) + 0.5) * periodWidth, 24),
                            max(contentWidth - 24, 24)
                        ),
                        y: Self.axisHeight / 2 + 2
                    )
            }
        }
        .frame(width: contentWidth, height: Self.axisHeight)
        .accessibilityHidden(true)
    }

    private func axisLabel(_ date: Date) -> String {
        data.usesHourlyBuckets
            ? date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var edgeFades: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [theme.palette.workspace, theme.palette.workspace.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 24)
            .opacity(scrollOffset > 1 ? 1 : 0)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [theme.palette.workspace.opacity(0), theme.palette.workspace],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 24)
            .opacity(isScrollable && scrollOffset < maximumOffset - 1 ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    private func hoverLayer(_ column: UsageChartColumn, scale: UsageChartScale) -> some View {
        let center = (CGFloat(column.index) + 0.5) * periodWidth - scrollOffset
        let preferred = center + 12 + tooltipSize.width <= viewportWidth
            ? center + 12
            : center - 12 - tooltipSize.width
        let tooltipX = min(max(0, preferred), max(0, viewportWidth - tooltipSize.width))
        return ZStack(alignment: .topLeading) {
            if style == .bars {
                Rectangle()
                    .fill(theme.palette.themeSoft)
                    .frame(width: periodWidth, height: Self.plotHeight)
                    .offset(x: center - periodWidth / 2, y: Self.topInset)
            } else {
                Rectangle()
                    .fill(DashboardPalette.mutedForeground.opacity(0.55))
                    .frame(width: 1, height: Self.plotHeight)
                    .offset(x: center - 0.5, y: Self.topInset)
                ForEach(data.providers) { provider in
                    Circle()
                        .fill(provider.usageColor)
                        .frame(width: 8, height: 8)
                        .padding(2)
                        .background(theme.palette.workspace, in: Circle())
                        .offset(
                            x: center - 6,
                            y: Self.topInset + y(for: column.values[provider] ?? 0, scale: scale) - 6
                        )
                }
            }
            UsageChartTooltip(
                title: tooltipTitle(column.start),
                column: column,
                providers: data.providers,
                metric: metric
            )
            .onGeometryChange(for: CGSize.self, of: \.size) { tooltipSize = $0 }
            .offset(x: tooltipX, y: Self.topInset + 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func tooltipTitle(_ date: Date) -> String {
        data.usesHourlyBuckets
            ? date.formatted(.dateTime.month(.abbreviated).day().hour(.defaultDigits(amPM: .abbreviated)))
            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private var scrollFooter: some View {
        HStack(spacing: 2) {
            Text(visibleRangeLabel)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(DashboardPalette.mutedForeground)
            Spacer(minLength: 8)
            scrollButton(forward: false)
            scrollButton(forward: true)
        }
        .padding(.leading, Self.yAxisWidth + 8)
    }

    private var visibleRangeLabel: String {
        guard periodWidth > 0, let lastColumn = data.columns.last else { return "" }
        let first = min(max(0, Int(scrollOffset / periodWidth)), lastColumn.index)
        let last = min(max(first, Int((scrollOffset + viewportWidth - 1) / periodWidth)), lastColumn.index)
        return "Showing \(axisLabel(data.columns[first].start)) to \(axisLabel(data.columns[last].start))"
    }

    private func scrollButton(forward: Bool) -> some View {
        Button {
            let distance = viewportWidth * 0.8 * (forward ? 1 : -1)
            let target = min(max(0, scrollOffset + distance), maximumOffset)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                position.scrollTo(x: target)
            }
        } label: {
            DashboardLucideIcon(glyph: .chevronDown, size: 12)
                .rotationEffect(.degrees(forward ? -90 : 90))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(DashboardIconButtonStyle())
        .disabled(forward ? scrollOffset >= maximumOffset - 1 : scrollOffset <= 1)
        .help(forward ? "Later" : "Earlier")
        .accessibilityLabel(forward ? "Show later periods" : "Show earlier periods")
    }
}

/// Kept separate and equatable so hovering and scrolling never rebuild the marks.
private struct UsageChartPlot: View, Equatable {
    let data: UsageChartData
    let style: UsageChartStyle
    let scale: UsageChartScale
    let width: CGFloat
    let plotHeight: CGFloat
    let gridColor: Color

    var body: some View {
        // An if/else inside Chart requires a newer macOS than this app's minimum.
        Group {
            if style == .lines {
                configured(Chart { lineMarks })
            } else {
                configured(Chart { barMarks })
            }
        }
        .frame(width: width, height: plotHeight)
    }

    private func configured<Content: ChartContent>(_ chart: Chart<Content>) -> some View {
        chart
            .chartXScale(domain: 0.0...Double(max(1, data.columns.count)))
            .chartYScale(domain: 0.0...scale.maximum)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(gridColor)
                }
            }
            .chartLegend(.hidden)
            .chartPlotStyle { $0.frame(height: plotHeight) }
    }

    private func x(_ column: UsageChartColumn) -> Double { Double(column.index) + 0.5 }

    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        ForEach(data.providersByTotal) { provider in
            ForEach(data.columns) { column in
                AreaMark(
                    x: .value("Period", x(column)),
                    yStart: .value("Base", 0.0),
                    yEnd: .value("Value", column.values[provider] ?? 0),
                    series: .value("Provider", provider.rawValue)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(provider.usageColor.opacity(0.1))
                .accessibilityHidden(true)
            }
        }
        ForEach(data.providersByTotal) { provider in
            ForEach(data.columns) { column in
                LineMark(
                    x: .value("Period", x(column)),
                    y: .value("Value", column.values[provider] ?? 0),
                    series: .value("Provider", provider.rawValue)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(provider.usageColor)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .accessibilityLabel(provider.usageName)
                .accessibilityValue(column.start.formatted(date: .abbreviated, time: .omitted))
            }
        }
        // A line needs two points, so a single period still shows as a dot.
        if data.columns.count == 1, let column = data.columns.first {
            ForEach(data.providers) { provider in
                PointMark(x: .value("Period", x(column)), y: .value("Value", column.values[provider] ?? 0))
                    .foregroundStyle(provider.usageColor)
                    .symbolSize(50)
            }
        }
    }

    @ChartContentBuilder
    private var barMarks: some ChartContent {
        let barWidth = max(4, min(24, width / CGFloat(max(1, data.columns.count)) * 0.66))
        let gap = scale.maximum * 2 / Double(plotHeight)
        ForEach(segments(gap: gap)) { segment in
            BarMark(
                x: .value("Period", segment.x),
                yStart: .value("Start", segment.start),
                yEnd: .value("End", segment.end),
                width: .fixed(barWidth)
            )
            .foregroundStyle(segment.provider.usageColor)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: segment.isTop ? 3 : 0,
                    topTrailingRadius: segment.isTop ? 3 : 0,
                    style: .continuous
                )
            )
            .accessibilityLabel(segment.provider.usageName)
            .accessibilityValue(segment.label)
        }
    }

    private struct Segment: Identifiable {
        let id: String
        let x: Double
        let start: Double
        let end: Double
        let provider: ProviderKind
        let isTop: Bool
        let label: String
    }

    private func segments(gap: Double) -> [Segment] {
        data.columns.flatMap { column -> [Segment] in
            var base = 0.0
            let present = data.providers.filter { (column.values[$0] ?? 0) > 0 }
            return present.map { provider in
                let value = column.values[provider] ?? 0
                let top = base + value
                let isTop = provider == present.last
                // A surface gap between stacked segments, never hiding a small one.
                let end = isTop ? top : max(base + gap * 0.5, top - gap)
                defer { base = top }
                return Segment(
                    id: "\(column.index):\(provider.rawValue)",
                    x: x(column),
                    start: base,
                    end: end,
                    provider: provider,
                    isTop: isTop,
                    label: column.start.formatted(date: .abbreviated, time: .omitted)
                )
            }
        }
    }
}

private struct UsageChartTooltip: View {
    @Environment(\.dashboardTheme) private var theme
    let title: String
    let column: UsageChartColumn
    let providers: [ProviderKind]
    let metric: UsageChartMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
            ForEach(providers) { provider in
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        UsageProviderSwatch(provider: provider)
                        Text(provider.usageName)
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer(minLength: 8)
                    Text(metric.valueLabel(column.values[provider] ?? 0))
                        .monospacedDigit()
                }
            }
            if providers.count > 1 {
                Rectangle()
                    .fill(theme.palette.border)
                    .frame(height: 1)
                    .padding(.vertical, 1)
                HStack {
                    Text("Total").foregroundStyle(DashboardPalette.mutedForeground)
                    Spacer(minLength: 8)
                    Text(metric.valueLabel(column.total))
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(DashboardPalette.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 148)
        .fixedSize()
        .background(
            DashboardPalette.background,
            in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
                .stroke(theme.palette.border, lineWidth: 1)
        }
        .shadow(color: DashboardPalette.foreground.opacity(0.08), radius: 12, y: 6)
    }
}

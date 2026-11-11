import SwiftUI
import WovenMatterCore

/// Fades placeholders gently while data is on its way, and holds still under Reduce Motion.
private struct UsagePlaceholderPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(isDimmed && !reduceMotion ? 0.5 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1).repeatForever(autoreverses: true), value: isDimmed)
            .onAppear { isDimmed = true }
    }
}

/// One line or figure of content that hasn't arrived.
private struct UsagePlaceholderBlock: View {
    var width: CGFloat?
    var height: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: min(height / 2, 5), style: .continuous)
            .fill(DashboardPalette.muted)
            .frame(width: width, height: height)
    }
}

/// Provider rows in the filter column, before any provider is known.
struct UsageFilterRowsPlaceholder: View {
    var body: some View {
        VStack(spacing: 1) {
            ForEach([62.0, 48, 70], id: \.self) { width in
                HStack(spacing: 8) {
                    UsagePlaceholderBlock(width: 10, height: 10)
                    UsagePlaceholderBlock(width: width, height: 9)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 25)
            }
        }
        .modifier(UsagePlaceholderPulse())
        .accessibilityHidden(true)
    }
}

/// The analytics report with its real layout, shown until this range has data.
struct UsageReportPlaceholder<Controls: View>: View {
    let style: UsageChartStyle
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                hero
                chart.modifier(UsagePlaceholderPulse())
            }
            Group {
                breakdown
                rows("By provider", widths: [90, 64, 110])
                rows("By model", widths: [120, 96, 140, 76])
                rows("Sessions and attribution", widths: [130, 104, 150, 92, 120], detail: true)
            }
            .modifier(UsagePlaceholderPulse())
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                UsagePlaceholderBlock(width: 120, height: 28)
                    .modifier(UsagePlaceholderPulse())
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                controls()
            }
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini)
                Text("Reading your usage history. Your most recent usage appears first.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
    }

    private var chart: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(0..<4) { _ in
                    UsagePlaceholderBlock(width: 26, height: 8)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: 42, height: 248, alignment: .trailing)
            VStack(spacing: 8) {
                plot.frame(height: 248)
                HStack {
                    ForEach(0..<5) { _ in
                        UsagePlaceholderBlock(width: 34, height: 8)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.top, 8)
        .accessibilityHidden(true)
    }

    /// A fixed made-up shape, so the graph's place is clear without implying any real values.
    private static var heights: [CGFloat] {
        (0..<30).map { index in
            let position = Double(index)
            return CGFloat(0.42 + 0.24 * sin(position / 2.6) + 0.14 * sin(position / 1.1 + 1))
        }
    }

    private var plot: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let heights = Self.heights
            let step = size.width / CGFloat(heights.count)
            ZStack(alignment: .topLeading) {
                if style == .bars {
                    ForEach(heights.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(DashboardPalette.muted)
                            .frame(width: max(4, step * 0.66), height: size.height * heights[index])
                            .offset(
                                x: CGFloat(index) * step + step * 0.17,
                                y: size.height * (1 - heights[index])
                            )
                    }
                } else {
                    Path { path in
                        for (index, height) in heights.enumerated() {
                            let point = CGPoint(x: (CGFloat(index) + 0.5) * step, y: size.height * (1 - height))
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(DashboardPalette.muted, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<5) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        UsagePlaceholderBlock(width: 58, height: 8)
                        UsagePlaceholderBlock(width: 46, height: 14)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            UsagePlaceholderBlock(height: 7)
        }
        .accessibilityHidden(true)
    }

    private func rows(_ title: String, widths: [CGFloat], detail: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageSectionHeading(title: title)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(widths, id: \.self) { width in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 5) {
                            UsagePlaceholderBlock(width: width, height: 10)
                            if detail { UsagePlaceholderBlock(width: width * 1.5, height: 8) }
                        }
                        Spacer(minLength: 8)
                        UsagePlaceholderBlock(width: 44, height: 10)
                    }
                    .padding(.vertical, 9)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Limit rows with their real layout, shown before the first snapshot arrives.
struct UsageLimitsPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach([96.0, 80, 110], id: \.self) { width in
                VStack(alignment: .leading, spacing: 10) {
                    UsagePlaceholderBlock(width: width, height: 12)
                    UsagePlaceholderBlock(height: 7)
                    UsagePlaceholderBlock(height: 7)
                }
            }
        }
        .modifier(UsagePlaceholderPulse())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading usage limits")
    }
}

import SwiftUI
import WovenMatterCore

private struct ConversationTaskProgressKey: EnvironmentKey {
    static let defaultValue: ConversationTaskProgress? = nil
}

extension EnvironmentValues {
    var conversationTaskProgress: ConversationTaskProgress? {
        get { self[ConversationTaskProgressKey.self] }
        set { self[ConversationTaskProgressKey.self] = newValue }
    }
}

/// The active run's checklist, attached above the composer as in T3: Tasks,
/// the current step, the completed count, and progress segments. Clicking
/// expands the full list. The root decides visibility and resets expansion
/// for blocking interactions and conversation switches.
struct ConversationTasksBadge: View {
    /// How far the badge's surface extends beneath the composer's top edge.
    static let attachmentOverlap: CGFloat = 17
    static let maximumListHeight: CGFloat = 320
    /// Segments need room beside the count; T3 shows them from 560 points.
    static let segmentMinimumWidth: CGFloat = 560

    let progress: ConversationTaskProgress
    @Binding var isExpanded: Bool
    /// Runs after each toggle, for example to return focus to the composer.
    var onInteraction: @MainActor () -> Void = {}
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var width: CGFloat = 0
    @State private var listHeight = Self.maximumListHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { isExpanded.toggle() }
                onInteraction()
            } label: {
                summary
            }
            .buttonStyle(ConversationTasksRowButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel(
                "\(isExpanded ? "Collapse tasks" : "Tasks"): \(progress.completedCount) of \(progress.totalCount) complete. Current task: \(progress.currentStep.label)"
            )

            if isExpanded {
                list
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
        .padding(.top, 5)
        .padding(.bottom, 5 + Self.attachmentOverlap)
        .background { surface }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var summary: some View {
        HStack(spacing: 4) {
            Image(systemName: "checklist")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .frame(width: 24)
            HStack(spacing: 6) {
                Text("Tasks")
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize()
                Text(progress.currentStep.label)
                    .fontWeight(.medium)
                    .foregroundStyle(DashboardPalette.foreground.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text("\(progress.completedCount)/\(progress.totalCount)")
                    .monospacedDigit()
                    .foregroundStyle(progress.isComplete ? DashboardPalette.success : DashboardPalette.mutedForeground)
                    .fixedSize()
                if (2...10).contains(progress.totalCount), width >= Self.segmentMinimumWidth {
                    segments
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .padding(.trailing, 6)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }

    private var segments: some View {
        HStack(spacing: 2) {
            ForEach(progress.steps) { step in
                Capsule()
                    .fill(segmentColor(step.status))
                    .frame(height: 3)
            }
        }
        .frame(width: 80)
        .accessibilityHidden(true)
    }

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(progress.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: icon(step.status))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(iconColor(step.status))
                            .frame(width: 24)
                        Text(step.label)
                            .foregroundStyle(labelColor(step.status))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(statusLabel(step.status)): \(step.label)")
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        }
        .scrollIndicators(.never)
        .frame(height: min(Self.maximumListHeight, max(1, listHeight)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task list. \(progress.completedCount) of \(progress.totalCount) complete.")
    }

    private var surface: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
        return ZStack {
            if reduceTransparency {
                shape.fill(DashboardPalette.background)
            } else {
                shape.fill(.regularMaterial)
            }
            shape.fill(theme.palette.themeWhisper)
            shape.stroke(DashboardPalette.foreground.opacity(0.06), lineWidth: 1)
        }
    }

    private func segmentColor(_ status: ConversationTaskProgress.Status) -> Color {
        switch status {
        case .completed: DashboardPalette.success
        case .inProgress: theme.palette.themeAccent
        case .pending, .cancelled: DashboardPalette.mutedForeground.opacity(0.25)
        }
    }

    private func icon(_ status: ConversationTaskProgress.Status) -> String {
        switch status {
        case .completed: "checkmark"
        case .inProgress: "smallcircle.filled.circle"
        case .pending, .cancelled: "circle"
        }
    }

    private func iconColor(_ status: ConversationTaskProgress.Status) -> Color {
        switch status {
        case .completed: DashboardPalette.success
        case .inProgress: theme.palette.themeAccent
        case .pending, .cancelled: DashboardPalette.mutedForeground.opacity(0.4)
        }
    }

    private func labelColor(_ status: ConversationTaskProgress.Status) -> Color {
        switch status {
        case .completed: DashboardPalette.mutedForeground.opacity(0.55)
        case .inProgress: DashboardPalette.foreground.opacity(0.9)
        case .pending, .cancelled: DashboardPalette.mutedForeground.opacity(0.7)
        }
    }

    private func statusLabel(_ status: ConversationTaskProgress.Status) -> String {
        switch status {
        case .completed: "Completed"
        case .inProgress: "Running"
        case .pending: "Pending"
        case .cancelled: "Cancelled"
        }
    }
}

/// A full-width row with a quiet hover fill. It never draws a focus ring, and
/// a click does not take keyboard focus from the composer.
private struct ConversationTasksRowButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed || hovered
                        ? theme.palette.themeSoft.opacity(configuration.isPressed ? 1 : 0.65)
                        : .clear)
            }
            .onHover { hovered = $0 }
    }
}

extension View {
    /// Attaches the Tasks badge above this composer, tucked beneath its top
    /// edge. Pass nil to hide the badge.
    func conversationTasksBadge(
        _ progress: ConversationTaskProgress?,
        isExpanded: Binding<Bool>,
        onInteraction: @escaping @MainActor () -> Void = {}
    ) -> some View {
        VStack(spacing: 0) {
            if let progress {
                ConversationTasksBadge(progress: progress, isExpanded: isExpanded, onInteraction: onInteraction)
                    .padding(.horizontal, 12)
                    .padding(.bottom, -ConversationTasksBadge.attachmentOverlap)
            }
            self
        }
    }
}

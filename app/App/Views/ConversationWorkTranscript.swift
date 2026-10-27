import SwiftUI
#if os(macOS)
import AppKit
import WovenMatterCore
import WovenMatterDashboardStore
#else
import WovenMatterCompanion
#endif

/// Display-only run values shared by the desktop and the device-owned runtime.
struct ConversationWorkRun {
    let id: String
    let conversationID: String
    let status: String
    var error: String? = nil
}

struct ConversationWorkPresentation {
    let startedAt: Date?
    let completedDuration: String?
}


private struct ConversationTranscriptInteractionKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

/// Loads one activity's complete record when compact records omit details.
/// The activity ID is `AgentRunActivity.id`, not the activity record ID.
private struct ConversationActivityDetailsKey: EnvironmentKey {
    static let defaultValue: (@MainActor (_ runID: String, _ activityID: String) async throws -> AgentRunActivity?)? = nil
}

extension EnvironmentValues {
    var conversationTranscriptInteraction: @MainActor () -> Void {
        get { self[ConversationTranscriptInteractionKey.self] }
        set { self[ConversationTranscriptInteractionKey.self] = newValue }
    }

    var conversationActivityDetails: (@MainActor (_ runID: String, _ activityID: String) async throws -> AgentRunActivity?)? {
        get { self[ConversationActivityDetailsKey.self] }
        set { self[ConversationActivityDetailsKey.self] = newValue }
    }
}

/// A run's work, inline and in order: commentary, thoughts, and tool groups.
/// While the run works the header counts elapsed time; once it settles the
/// work folds behind "Worked for" when a final reply follows. Failures stay
/// visible in either state.
struct ConversationWorkTranscript: View {
    let run: ConversationWorkRun
    let presentation: ConversationWorkPresentation?
    let records: [WorkspaceRunActivityRecord]
    let commentaryIDs: Set<String>
    let hasFinalReply: Bool
    /// A projection precomputed from `records` and `commentaryIDs`; built in
    /// `body` when absent.
    let timeline: ConversationWorkTimeline?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @Environment(\.conversationTranscriptState) private var transcriptState
    @State private var localExpansion: Bool?

    init(
        run: ConversationWorkRun,
        presentation: ConversationWorkPresentation?,
        records: [WorkspaceRunActivityRecord],
        commentaryIDs: Set<String> = [],
        hasFinalReply: Bool = false,
        timeline: ConversationWorkTimeline? = nil
    ) {
        self.run = run
        self.presentation = presentation
        self.records = records
        self.commentaryIDs = commentaryIDs
        self.hasFinalReply = hasFinalReply
        self.timeline = timeline
    }

    #if os(macOS)
    init(
        run: WorkspaceRunRecord,
        presentation: DashboardRunPresentation?,
        records: [WorkspaceRunActivityRecord],
        commentaryIDs: Set<String> = [],
        hasFinalReply: Bool = false,
        timeline: ConversationWorkTimeline? = nil
    ) {
        self.init(run: ConversationWorkRun(id: run.id, conversationID: run.conversationID, status: run.status, error: run.error),
                  presentation: presentation.map { ConversationWorkPresentation(startedAt: $0.startedAt, completedDuration: $0.completedDuration) },
                  records: records, commentaryIDs: commentaryIDs, hasFinalReply: hasFinalReply, timeline: timeline)
    }

    #endif

    var body: some View {
        let timeline = self.timeline ?? ConversationWorkTimeline(records: records, commentaryIDs: commentaryIDs)
        let content = ConversationWorkTranscriptPresentation(
            runStatus: run.status,
            runError: run.error,
            hasVisibleActivities: timeline.hasVisibleActivities
        )
        let isRunning = run.status == "running"
        let expanded = isRunning || isExpanded
        // Lost receipts can have no assistant output or tool activity at all.
        // Keep the recovery state visible independently of the work disclosure.
        if run.status == "uncertain" {
            VStack(alignment: .leading, spacing: 6) {
                Text("Waiting to confirm the remote outcome")
                    .font(.system(size: 13, weight: .medium))
                Text(RemoteNoteEditEnvelope.redactingEnvelopes(in: run.error
                    ?? "Reconnect this conversation to recover its result."))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
            .foregroundStyle(DashboardPalette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
        }
        if content.isVisible {
            VStack(alignment: .leading, spacing: 0) {
                if content.hasVisibleActivities, !isRunning {
                    Button {
                        setExpanded(!expanded)
                    } label: {
                        HStack(spacing: 7) {
                            elapsedLabel
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ConversationElapsedButtonStyle())
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                } else if content.failureMessage != nil {
                    HStack(spacing: 7) {
                        DashboardLucideIcon(glyph: .alertCircle, size: 13)
                        elapsedLabel
                    }
                    .foregroundStyle(DashboardPalette.danger)
                } else {
                    elapsedLabel
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }

                // Failure belongs to the run, not to its optional work history.
                // Keep it visible even when that history is empty or folded.
                if let failureMessage = content.failureMessage {
                    Text(RemoteNoteEditEnvelope.redactingEnvelopes(in: failureMessage))
                        .font(.system(size: 13))
                        .foregroundStyle(DashboardPalette.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                if content.hasVisibleActivities {
                    Divider()
                        .overlay(DashboardPalette.foreground.opacity(0.10))
                        .padding(.top, 12)

                    let entries = expanded ? timeline.entries : timeline.foldedEntries
                    if !entries.isEmpty {
                        let tailID = timeline.entries.last?.id
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(entries) { entry in
                                switch entry.content {
                                case .commentary(let activity):
                                    ConversationResponse(
                                        content: RemoteNoteEditEnvelope.redactingEnvelopes(in: activity.content ?? ""),
                                        isStreaming: false,
                                        showsCopyButton: false
                                    )
                                case .group(let group):
                                    ConversationWorkGroupRow(
                                        group: group,
                                        runID: run.id,
                                        runStatus: run.status,
                                        isTail: entry.id == tailID
                                    )
                                case .activity(let activity):
                                    if activity.htmlRender != nil {
                                        ConversationHTMLRenderView(activity: activity, runID: run.id)
                                    } else {
                                    ConversationActivityRow(
                                        activity: activity,
                                        runID: run.id,
                                        runStatus: run.status,
                                        showsProgress: activity.workTimelineShowsProgress
                                    )
                                    }
                                }
                            }
                        }
                        .environment(\.conversationArchiveConversationID, run.conversationID)
                        .padding(.top, 14)
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                if isRunning && timeline.needsThinkingIndicator {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.mini).frame(width: 17)
                        Text("Thinking").font(.system(size: 13.5))
                    }
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .padding(.top, 12)
                    .accessibilityLabel("Thinking")
                }
            }
        }
    }

    /// A settled run folds by default once it has a final reply. An explicit
    /// choice is kept per run in the injected transcript state.
    private var isExpanded: Bool {
        let defaultValue = localExpansion ?? !(run.status == "completed" && hasFinalReply)
        return transcriptState?.isRunExpanded(run.id, default: defaultValue) ?? defaultValue
    }

    private func setExpanded(_ expanded: Bool) {
        transcriptInteraction()
        if let transcriptState {
            transcriptState.setRunExpanded(run.id, expanded)
        } else {
            localExpansion = expanded
        }
    }

    @ViewBuilder
    private var elapsedLabel: some View {
        if run.status == "running", let startedAt = presentation?.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("Working for \(Self.elapsed(context.date.timeIntervalSince(startedAt)))")
                    .monospacedDigit()
            }
        } else if run.status == "running" {
            Text("Working")
        } else if run.status == "completed" {
            Text("Done after \(presentation?.completedDuration ?? "a moment")")
        } else if run.status == "failed" {
            Text("Error\(presentation?.completedDuration.map { " after \($0)" } ?? "")")
        } else if run.status == "cancelled" {
            Text("Idle (cancelled)\(presentation?.completedDuration.map { " after \($0)" } ?? "")")
        } else if run.status == "uncertain" {
            Text("Waiting to confirm the remote outcome")
        } else {
            Text(run.status.capitalized)
        }
    }

    /// Whole seconds for a once-per-second count; longer runs use the shared format.
    private static func elapsed(_ interval: TimeInterval) -> String {
        interval < 60 ? "\(max(0, Int(interval)))s" : dashboardRunDuration(interval)
    }

    #if os(macOS)
    static func hasVisibleContent(run: WorkspaceRunRecord, timeline: ConversationWorkTimeline) -> Bool {
        ConversationWorkTranscriptPresentation(
            runStatus: run.status,
            runError: run.error,
            hasVisibleActivities: timeline.hasVisibleActivities
        ).isVisible
    }
    #endif
}

private struct ConversationElapsedButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isEnabled && (configuration.isPressed || hovered)
                        ? theme.palette.themeSoft.opacity(configuration.isPressed ? 1 : 0.65)
                        : .clear)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -3)
            }
            .onHover { hovered = $0 }
    }
}

/// Expansion bound to the injected transcript state, else to local state.
@MainActor
private func conversationDisclosure(
    _ state: ConversationTranscriptState?,
    runID: String,
    itemID: String,
    local: Binding<Bool>,
    interaction: @escaping @MainActor () -> Void
) -> Binding<Bool> {
    let key = ConversationTranscriptState.disclosureKey(runID: runID, itemID: itemID)
    return Binding(
        get: { state?.isExpanded(key) ?? local.wrappedValue },
        set: { expanded in
            interaction()
            if let state {
                state.setExpanded(key, expanded)
            } else {
                local.wrappedValue = expanded
            }
        }
    )
}

/// Thoughts and tool calls between commentary. T3 keeps the trailing group
/// of an active run, and any group with a call still running, as one live row
/// naming the current call; settled groups summarize their calls.
private struct ConversationWorkGroupRow: View {
    let group: ConversationWorkGroup
    let runID: String
    let runStatus: String
    let isTail: Bool
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @Environment(\.conversationTranscriptState) private var transcriptState
    @State private var localExpanded = false
    @State private var localScrollOffset: CGFloat = 0

    var body: some View {
        let runIsActive = runStatus == "running"
        let liveLabel = runIsActive && ((isTail && !group.hasFailure) || group.hasActiveActivity)
            ? group.liveLabel(runIsActive: true)
            : nil
        let wasExpanded = transcriptState?.isExpanded(scrollKey) ?? localExpanded
        if liveLabel == nil, !wasExpanded, let single = group.singleActivity {
            ConversationActivityRow(
                activity: single,
                runID: runID,
                runStatus: runStatus,
                showsProgress: group.showsProgress(single)
            )
        } else {
            let expanded = conversationDisclosure(
                transcriptState,
                runID: runID,
                itemID: group.id,
                local: $localExpanded,
                interaction: transcriptInteraction
            )
            // The model can keep working between a successful tool and its
            // next visible part. Keep that live edge animated until the run ends.
            let showsProgress = liveLabel != nil && (!expanded.wrappedValue || group.isThoughtOnly)
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        if liveLabel != nil, !expanded.wrappedValue,
                           let thought = group.latestThought,
                           let source = thought.content?.nonempty ?? thought.detail?.nonempty {
                            let preview = AssistantStreamingText.reasoningPreview(
                                of: RemoteNoteEditEnvelope.redactingEnvelopes(in: source))
                            if !preview.isEmpty {
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(width: 17)
                                    Text(preview)
                                        .font(.system(size: 13.5))
                                        .lineSpacing(3)
                                        .lineLimit(4)
                                        .multilineTextAlignment(.leading)
                                }
                                .foregroundStyle(DashboardPalette.mutedForeground)
                            }
                        }
                        header(liveLabel: liveLabel.map { label in
                            if let activity = group.liveActivity, activity.kind == .thought,
                               activity.content?.nonempty != nil || activity.detail?.nonempty != nil {
                                return "Thinking"
                            }
                            return label
                        }, expanded: expanded.wrappedValue, showsProgress: showsProgress)
                    }
                }
                .buttonStyle(ConversationElapsedButtonStyle())
                .accessibilityValue((expanded.wrappedValue ? "Expanded" : "Collapsed") + (showsProgress ? ", In progress" : ""))
                .accessibilityIdentifier("work-group:" + group.id)

                // Rows exist only while expanded; collapsed groups build nothing.
                if expanded.wrappedValue {
                    ConversationBoundedWorkList(
                        group: group,
                        runID: runID,
                        runStatus: runStatus,
                        followsAppends: liveLabel != nil,
                        initialScrollOffset: transcriptState?.workScrollOffset(scrollKey) ?? localScrollOffset,
                        saveScrollOffset: { offset in
                            if let transcriptState { transcriptState.setWorkScrollOffset(scrollKey, offset) }
                            else { localScrollOffset = offset }
                        }
                    )
                    .padding(.top, 8)
                    .padding(.leading, 26)
                }
            }
        }
    }

    private var scrollKey: String {
        ConversationTranscriptState.disclosureKey(runID: runID, itemID: group.id)
    }

    private func header(liveLabel: String?, expanded: Bool, showsProgress: Bool) -> some View {
        HStack(spacing: 9) {
            Group {
                // Only collapsed groups with unsettled work need a summary spinner.
                if showsProgress {
                    ProgressView()
                        .controlSize(.mini)
                } else if group.hasFailure {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red.opacity(0.8))
                } else {
                    Image(systemName: group.isThoughtOnly
                        ? "sparkles"
                        : group.action?.systemImage ?? "wrench.and.screwdriver")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .frame(width: 17)
            Text(liveLabel ?? group.summary)
                .font(.system(size: 13.5, weight: group.isThoughtOnly ? .regular : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(DashboardPalette.mutedForeground)
            Spacer(minLength: 0)
        }
        .foregroundStyle(group.hasFailure && liveLabel == nil
            ? Color.red.opacity(0.8)
            : DashboardPalette.foreground.opacity(group.isThoughtOnly ? 0.58 : 0.72))
        .contentShape(Rectangle())
    }
}

/// Only an expanded work group owns a scroll view. Short groups keep their
/// intrinsic height; long ones are capped and render rows lazily.
private struct ConversationBoundedWorkList: View {
    static let maximumHeight: CGFloat = 320

    let group: ConversationWorkGroup
    let runID: String
    let runStatus: String
    let followsAppends: Bool
    let initialScrollOffset: CGFloat
    let saveScrollOffset: (CGFloat) -> Void
    @State private var contentHeight = Self.maximumHeight
    @State private var scrollState = ConversationWorkScrollState()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollOffset: CGFloat = 0
    @State private var reasoningText: [String: String] = [:]
    @State private var laidOutActivityIDs: [String]?
    @State private var growthStartedAtBottom = false
    @State private var isUserScrolling = false
    @State private var followTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { _ in
            ScrollView(.vertical) {
                Group {
                    if group.isThoughtOnly {
                        // A reasoning-only group opens directly into formatted
                        // text; mixed tool groups retain lazy rows.
                        VStack(alignment: .leading, spacing: 8) { rows }
                    } else {
                        LazyVStack(alignment: .leading, spacing: 8) { rows }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.conversationReasoningAtLiveEdge,
                    !isUserScrolling && (scrollState.isAtBottom || growthStartedAtBottom))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
        .scrollIndicators(.never)
        .frame(height: min(Self.maximumHeight, max(1, contentHeight)))
        .defaultScrollAnchor(.top, for: .initialOffset)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ConversationWorkScrollGeometry.self) { geometry in
            .init(contentHeight: geometry.contentSize.height, offset: max(0, geometry.contentOffset.y),
                  viewportHeight: geometry.containerSize.height)
        } action: { before, after in
            let ids = group.activities.map(\.id)
            if followsAppends, !isUserScrolling, let prior = laidOutActivityIDs,
               scrollState.shouldFollowAppend(from: prior, to: ids, wasAtBottom: before.isAtBottom) {
                followAfterLayout()
            }
            growthStartedAtBottom = after.contentHeight > before.contentHeight && before.isAtBottom
            laidOutActivityIDs = ids
            scrollOffset = after.offset
            scrollState.setAtBottom(after.isAtBottom)
        }
        .onPreferenceChange(ConversationReasoningTextKey.self) { after in
            let before = reasoningText
            reasoningText = after
            if followsAppends && !isUserScrolling && group.isThoughtOnly && before.keys.sorted() == after.keys.sorted(),
               after.allSatisfy({ key, value in value.utf16.starts(with: (before[key] ?? "").utf16) }),
               after.contains(where: { key, value in
                scrollState.shouldFollowTextAppend(from: before[key] ?? "", to: value,
                    wasAtBottom: scrollState.isAtBottom || growthStartedAtBottom)
               }) {
                followAfterLayout()
            }
        }
        .task {
            if initialScrollOffset > 0 { scrollPosition.scrollTo(y: initialScrollOffset) }
        }
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        }
        .onDisappear { followTask?.cancel(); saveScrollOffset(scrollOffset) }
        }
    }

    private func followAfterLayout() {
        followTask?.cancel()
        followTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    @ViewBuilder private var rows: some View {
                ForEach(group.activities) { activity in
                    if group.isThoughtOnly {
                        // One disclosure opens the complete formatted trace;
                        // reasoning-only groups need no second row disclosure.
                        ConversationActivityDetails(
                            activity: activity, runID: runID,
                            isLive: runStatus == "running" && group.showsProgress(activity),
                            summary: nil, indentation: 0)
                    } else {
                        ConversationActivityRow(
                            activity: activity,
                            runID: runID,
                            runStatus: runStatus,
                            showsProgress: group.showsProgress(activity)
                        )
                    }
                }
                if followsAppends && !group.isThoughtOnly && !group.hasActiveActivity {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.mini).frame(width: 17)
                        Text("Thinking").font(.system(size: 13.5))
                    }
                    .foregroundStyle(DashboardPalette.mutedForeground)
                }
                Color.clear.frame(height: 1).id("work-end")
    }
}

private struct ConversationActivityRow: View {
    let activity: AgentRunActivity
    let runID: String
    let runStatus: String
    /// The activity is unsettled, as its timeline decides; the run gates it.
    let showsProgress: Bool
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @Environment(\.conversationTranscriptState) private var transcriptState
    @State private var localExpanded = false

    var body: some View {
        if activity.kind == .plan, activity.planKind == "proposal" {
            ConversationProposedPlan(activity: activity)
        } else if activity.kind != .fileChange {
            if isExpandable {
                let expanded = conversationDisclosure(
                    transcriptState,
                    runID: runID,
                    itemID: "activity:\(activity.id)",
                    local: $localExpanded,
                    interaction: transcriptInteraction
                )
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        expanded.wrappedValue.toggle()
                    } label: {
                        activityLabel(expanded: expanded.wrappedValue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue((expanded.wrappedValue ? "Expanded" : "Collapsed") + (isLive && !isFailure ? ", In progress" : ""))
                    .accessibilityIdentifier("work-activity:" + activity.id)
                    if expanded.wrappedValue {
                        ConversationActivityDetails(
                            activity: activity,
                            runID: runID,
                            isLive: isLive,
                            summary: secondaryLabel
                        )
                    }
                }
            } else {
                activityLabel(expanded: nil)
            }
        }
    }

    @ViewBuilder
    private func activityLabel(expanded: Bool?) -> some View {
        if activity.kind == .activity, let content = activity.content?.nonempty {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(content)
                    .font(.system(size: 13))
                    .foregroundStyle(isFailure ? .red.opacity(0.8) : DashboardPalette.foreground.opacity(0.72))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let expanded { chevron(expanded) }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                activityIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(primaryLabel)
                            .font(.system(
                                size: 13.5,
                                weight: activity.kind == .thought ? .regular : .medium
                            ))
                            .foregroundStyle(DashboardPalette.foreground.opacity(
                                activity.kind == .thought ? 0.58 : 0.72
                            ))
                            .fixedSize(horizontal: false, vertical: true)
                        if let expanded { chevron(expanded) }
                    }
                    if let secondaryLabel {
                        Text(secondaryLabel)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .lineLimit(activity.kind == .thought ? 2 : 1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
    }

    private func chevron(_ expanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .foregroundStyle(DashboardPalette.mutedForeground)
    }

    @ViewBuilder
    private var activityIcon: some View {
        if isFailure {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red.opacity(0.8))
                .frame(width: 17)
        } else if isLive {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 17, height: 17)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .frame(width: 17)
        }
    }

    private var primaryLabel: String {
        switch activity.kind {
        case .thought, .tool:
            return activity.workTimelineLabel(active: isLive)
        case .assistant: return activity.title?.nonempty ?? "Commentary"
        case .plan: return activity.title?.nonempty ?? "Updated the plan"
        case .fileChange: return activity.title?.nonempty ?? "Changed files"
        case .progress: return activity.title?.nonempty ?? "Progress"
        case .activity: return activity.title?.nonempty ?? activity.toolName?.nonempty ?? "Agent activity"
        }
    }

    private var secondaryLabel: String? {
        if activity.kind == .thought {
            // A thought labelled from its own text needs no preview.
            guard ["Thinking", "Thought", "Reasoning", "Reasoning summary"].contains(primaryLabel),
                  let content = activity.content?.nonempty else { return nil }
            return Self.preview(content)
        }
        if let detail = activity.detail?.nonempty { return detail }
        guard activity.kind != .activity,
              let content = activity.content?.nonempty else { return nil }
        return Self.preview(content)
    }

    private var isFailure: Bool { activity.workTimelineIsFailure }

    private var isLive: Bool { runStatus == "running" && showsProgress }

    /// Expandable when anything is not already fully shown in the label.
    private var isExpandable: Bool {
        if activity.subagents?.isEmpty == false || activity.detailsAvailable == true { return true }
        if activity.rawInputJSON != nil || activity.rawOutputJSON != nil || activity.rawPayloadJSON != nil {
            return true
        }
        guard activity.kind != .activity, let content = activity.content?.nonempty else { return false }
        return content != secondaryLabel
    }

    private var systemImage: String {
        if activity.subagents != nil { return "person.2" }
        return switch activity.kind {
        case .assistant: "text.bubble"
        case .thought: "sparkles"
        case .tool: ConversationToolAction(activity).systemImage
        case .plan: "list.bullet.clipboard"
        case .fileChange: "pencil.and.outline"
        case .progress: activity.status?.lowercased() == "completed"
            ? "flag.checkered" : "arrow.trianglehead.2.clockwise.rotate.90"
        case .activity: "waveform.path.ecg"
        }
    }

    private static func preview(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        guard singleLine.count > 180 else { return singleLine }
        return String(singleLine.prefix(177)) + "…"
    }
}

/// Complete records of settled activities, keyed by run, activity, and detail
/// version, so re-expanding a row or scrolling it back into view does not
/// refetch. Live records are never cached.
@MainActor
private enum ConversationActivityDetailCache {
    private final class Entry {
        let activity: AgentRunActivity
        init(_ activity: AgentRunActivity) { self.activity = activity }
    }

    private static let entries: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    static func key(runID: String, activity: AgentRunActivity) -> NSString {
        "\(runID)\u{1F}\(activity.id)\u{1F}\(activity.detailVersion.map(String.init) ?? "")" as NSString
    }

    static subscript(key: NSString) -> AgentRunActivity? {
        get { entries.object(forKey: key)?.activity }
        set {
            if let newValue {
                let cost = [newValue.content, newValue.rawInputJSON, newValue.rawOutputJSON, newValue.rawPayloadJSON]
                    .compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
                entries.setObject(Entry(newValue), forKey: key, cost: cost)
            } else { entries.removeObject(forKey: key) }
        }
    }
}

/// Expanded details. Compact activity records may omit raw fields and bound
/// long content; the complete record then loads on expansion and again once
/// the activity settles or its settled detail version changes. While the
/// activity is live, its streamed fields stay current and the loaded record
/// only supplies what the compact record omits.
private struct ConversationActivityDetails: View {
    let activity: AgentRunActivity
    let runID: String
    let isLive: Bool
    /// Text already shown in the row label.
    let summary: String?
    var indentation: CGFloat = 26
    @Environment(\.conversationActivityDetails) private var loadDetails
    @State private var loaded: AgentRunActivity?
    @State private var loadToken: UUID?
    @State private var error: String?
    @State private var waitingForDetails = false
    @State private var attempt = 0
    @State private var isVisible = false

    private struct LoadKey: Hashable {
        let visible: Bool
        let settled: Bool
        let version: Int64?
        let attempt: Int
    }

    var body: some View {
        let complete = self.complete
        let content = field(\.content)?.nonempty
            ?? (activity.kind == .thought ? field(\.detail)?.nonempty ?? field(\.title)?.nonempty : nil)
        VStack(alignment: .leading, spacing: 8) {
            if activity.kind != .thought, !isLive, let title = complete?.title, title != activity.title {
                ConversationPagedText(text: title, style: .prose)
            }
            if activity.kind != .thought, !isLive, let detail = complete?.detail, detail != activity.detail {
                ConversationPagedText(text: detail, style: .prose)
            }
            if let subagents = field(\.subagents) {
                ForEach(subagents) { child in
                    ConversationSubagentRow(child: child)
                }
            }
            if activity.kind != .activity, let content = content?.nonempty, content != summary {
                if activity.kind == .thought {
                    ConversationReasoningText(
                        activityID: activity.id,
                        text: content, isLive: isLive)
                } else {
                    ConversationPagedText(text: content, style: .code)
                }
            }
            rawBlock("Input", field(\.rawInputJSON))
            rawBlock("Output", field(\.rawOutputJSON))
            rawBlock("Event", field(\.rawPayloadJSON))
            // A compact record can contain no inline fields. Keep a visible
            // placeholder so its visibility-driven detail read can start.
            if loadToken != nil || waitingForDetails || (activity.detailsAvailable == true && complete == nil && error == nil) {
                Text("Loading details…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error)
                        .foregroundStyle(DashboardPalette.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { attempt += 1 }
                        .buttonStyle(DashboardQuietButtonStyle())
                }
                .font(.system(size: 12.5))
            }
        }
        .padding(.top, 7)
        .padding(.leading, indentation)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
            if !visible { loaded = nil }
        }
        .task(id: loadKey) {
            let key = loadKey
            guard key.visible else { return }
            repeat {
                await load(key)
                guard isLive || waitingForDetails, !Task.isCancelled else { break }
                // Poll only visible live details or a referenced record still
                // arriving from sync. Collapsed rows never decode payloads.
                do { try await Task.sleep(for: error == nil ? .milliseconds(500) : .seconds(2)) }
                catch { break }
            } while !Task.isCancelled
        }
    }

    /// Per-token revisions do not restart the visible detail task.
    private var loadKey: LoadKey {
        LoadKey(visible: isVisible, settled: !isLive, version: isLive ? nil : activity.detailVersion, attempt: attempt)
    }

    private var cacheKey: NSString { ConversationActivityDetailCache.key(runID: runID, activity: activity) }

    private var complete: AgentRunActivity? {
        isLive ? loaded : ConversationActivityDetailCache[cacheKey] ?? loaded
    }

    /// The bounded live preview can be shorter than the loaded detail. Keep
    /// the full value until the next visible-only refresh, but use a corrected
    /// preview immediately if it is no longer a prefix of that value.
    private func field<Value>(_ path: KeyPath<AgentRunActivity, Value?>) -> Value? {
        let complete = self.complete
        if isLive, path == \AgentRunActivity.content,
           let preview = activity.content, let full = complete?.content,
           !full.utf16.starts(with: preview.utf16) {
            return activity[keyPath: path]
        }
        if isLive, path != \AgentRunActivity.content {
            return activity[keyPath: path] ?? complete?[keyPath: path]
        }
        return complete?[keyPath: path] ?? activity[keyPath: path]
    }

    private func load(_ key: LoadKey) async {
        guard activity.detailsAvailable == true, let loadDetails else { return }
        waitingForDetails = false
        let cacheKey = self.cacheKey
        if key.settled, let cached = ConversationActivityDetailCache[cacheKey] {
            loaded = cached
            error = nil
            return
        }
        let token = UUID()
        if loaded == nil { loadToken = token }
        // A superseded load must not clear the indicator of its replacement.
        defer { if loadToken == token { loadToken = nil } }
        do {
            let value = try await loadDetails(runID, activity.id)
            guard !Task.isCancelled else { return }
            loaded = value
            error = nil
            if key.settled { ConversationActivityDetailCache[cacheKey] = value }
            if value == nil { error = "Details for this activity are no longer available." }
        } catch is CancellationError {
        } catch let error as CompanionAPIError where error.code == "incomplete_activity_details" {
            guard !Task.isCancelled else { return }
            waitingForDetails = true
            self.error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private func rawBlock(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(DashboardPalette.mutedForeground)
                ConversationPagedText(text: value, style: .raw)
            }
        }
    }
}

/// Reasoning uses the response's Markdown renderer, safe links, and native
/// selection. Paging bounds layout without hiding any supplied trace text.
private struct ConversationReasoningText: View {
    private static let pageLength = 20_000
    let activityID: String
    let text: String
    let isLive: Bool
    @Environment(\.conversationReasoningAtLiveEdge) private var isAtLiveEdge
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var displayedEnd: Int?
    @State private var browsingHistory = false

    private var committedText: String {
        // Find stream boundaries and redact whole envelopes before slicing a
        // page; a page beginning inside an envelope must not expose its tail.
        RemoteNoteEditEnvelope.redactingEnvelopes(in:
            isLive ? AssistantStreamingText.readyPrefix(of: text) : text)
    }

    var body: some View {
        let stream = committedText
        let count = stream.count
        let endOffset = count <= Self.pageLength ? count
            : min(displayedEnd ?? (isLive ? count : Self.pageLength), count)
        let page = ConversationReasoningPage(text: stream, endOffset: endOffset, maximumCharacters: Self.pageLength)
        let startOffset = page.startOffset
        let shown = page.markdown
        VStack(alignment: .leading, spacing: 6) {
            if startOffset > 0 || endOffset < count {
                HStack(spacing: 12) {
                    if startOffset > 0 {
                        Button("Earlier reasoning") {
                            transcriptInteraction()
                            browsingHistory = true
                            displayedEnd = startOffset
                        }
                    }
                    if endOffset < count {
                        Button("Later reasoning") {
                            transcriptInteraction()
                            displayedEnd = min(count, endOffset + Self.pageLength)
                            browsingHistory = displayedEnd != count
                        }
                        Button("Latest reasoning") {
                            transcriptInteraction()
                            displayedEnd = count
                            browsingHistory = false
                        }
                    }
                }
                .buttonStyle(DashboardQuietButtonStyle())
                .font(.system(size: 12))
            }
            if !shown.isEmpty {
                ConversationResponse(content: shown, isStreaming: isLive, showsCopyButton: false)
            }
        }
        .onAppear { if displayedEnd == nil { displayedEnd = endOffset } }
        .onChange(of: stream) { before, after in
            if !browsingHistory, isAtLiveEdge, after.utf16.starts(with: before.utf16) {
                displayedEnd = after.count
            } else if before.count <= Self.pageLength {
                // Below the limit the full trace was rendered, even while
                // reading above the edge. Preserve that actual page when a
                // new append first requires paging.
                displayedEnd = min(before.count, after.count)
            } else if let displayedEnd, displayedEnd > after.count {
                self.displayedEnd = after.count
            }
        }
        .onChange(of: isAtLiveEdge) { _, atEdge in
            if atEdge, isLive, !browsingHistory { displayedEnd = committedText.count }
        }
        // Follow the supplied stream, not the current 20k rendering window:
        // its prefix necessarily changes when a long live trace advances.
        .preference(key: ConversationReasoningTextKey.self,
                    value: isLive && !browsingHistory ? [activityID: stream] : [:])
    }
}

/// A bounded Markdown page starts on a line boundary whenever possible. Carry
/// only the surrounding fence delimiters, so code at either edge stays code
/// and a later closing fence cannot accidentally consume following prose.
struct ConversationReasoningPage {
    let startOffset: Int
    let markdown: String

    init(text: String, endOffset: Int, maximumCharacters: Int) {
        let end = text.index(text.startIndex, offsetBy: min(endOffset, text.count))
        var start = text.index(end, offsetBy: -min(maximumCharacters, text.distance(from: text.startIndex, to: end)))
        if start > text.startIndex, text[text.index(before: start)] != "\n",
           let newline = text[start..<end].firstIndex(of: "\n"), text.index(after: newline) < end {
            start = text.index(after: newline)
        }
        startOffset = text.distance(from: text.startIndex, to: start)
        var source = String(text[start..<end])
        if let opening = Self.fence(in: text[..<start]) {
            source = opening.marker + opening.language + "\n" + source
        }
        if let closing = Self.fence(in: text[..<end]) {
            if !source.hasSuffix("\n") { source += "\n" }
            source += closing.marker
        }
        markdown = source
    }

    private struct Fence {
        let marker: String
        let language: String
        let indent: Int
    }

    private static func fence(in prefix: Substring) -> Fence? {
        var open: Fence?
        for line in prefix.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            guard let first = body.first, first == "`" || first == "~" else { continue }
            let marker = body.prefix { $0 == first }
            guard marker.count >= 3 else { continue }
            let remainder = body.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if let prior = open {
                if first == prior.marker.first, marker.count >= prior.marker.count,
                   indent <= prior.indent + 3, remainder.isEmpty { open = nil }
            } else {
                // The native renderer displays the language, not arbitrary info
                // metadata. Bound that context independently of a long trace.
                let language = remainder.split(whereSeparator: \.isWhitespace).first.map { String($0.prefix(80)) } ?? ""
                open = Fence(marker: String(marker), language: language, indent: indent)
            }
        }
        return open
    }
}

private struct ConversationReasoningAtLiveEdgeKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var conversationReasoningAtLiveEdge: Bool {
        get { self[ConversationReasoningAtLiveEdgeKey.self] }
        set { self[ConversationReasoningAtLiveEdgeKey.self] = newValue }
    }
}

private struct ConversationReasoningTextKey: PreferenceKey {
    static let defaultValue: [String: String] = [:]
    static func reduce(value: inout [String: String], nextValue: () -> [String: String]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Long text renders a page at a time so a large result never lays out as one
/// huge text, while every page stays reachable through Show more.
private struct ConversationPagedText: View {
    enum Style {
        case prose
        case code
        case raw
    }

    static let pageLength = 20_000

    let text: String
    let style: Style
    @State private var pages = 1

    var body: some View {
        let end = text.index(text.startIndex, offsetBy: pages * Self.pageLength, limitedBy: text.endIndex)
            ?? text.endIndex
        let shown = String(text[..<end])
        let remaining = text.utf16.count - shown.utf16.count
        VStack(alignment: .leading, spacing: 6) {
            if style == .raw {
                ScrollView(.horizontal) {
                    textView(shown)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(9)
                }
                .scrollIndicators(.never)
                .background(DashboardPalette.muted.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                textView(shown)
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if remaining > 0 {
                Button("Show more (\(remaining.formatted()) more characters)") { pages += 1 }
                    .buttonStyle(DashboardQuietButtonStyle())
                    .font(.system(size: 12))
            }
        }
    }

    private func textView(_ value: String) -> some View {
        Text(value)
            .font(style == .prose ? .system(size: 12.5) : .system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
    }
}

private extension ConversationToolAction {
    var systemImage: String {
        switch self {
        case .command: "terminal"
        case .read: "doc.text"
        case .edit: "pencil.and.outline"
        case .codeSearch: "magnifyingglass"
        case .webSearch, .webFetch, .browser: "globe"
        case .computer: "desktopcomputer"
        case .delegate: "person.2"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// A proposed plan is history, not execution progress: no counts or checks.
private struct ConversationProposedPlan: View {
    let activity: AgentRunActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .frame(width: 17)
                Text(activity.title?.nonempty ?? "Proposed plan")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.foreground.opacity(0.72))
            }
            if let content = activity.content?.nonempty {
                #if os(macOS)
                ConversationMarkdown(document: ConversationMarkdownDocument(content), isStreaming: false)
                #else
                ConversationResponse(content: content, isStreaming: false, showsCopyButton: false)
                #endif
            } else {
                ForEach(activity.planEntries.indices, id: \.self) { index in
                    Text("• \(activity.planEntries[index].content)")
                        .font(.system(size: 13))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 26)
                }
            }
        }
    }
}

struct ConversationChangedFilesCard: View {
    let records: [WorkspaceRunActivityRecord]
    // Evaluate only for a nonempty card. The lazy footer otherwise has no
    // height and need not project the work transcript merely to decide a gap.
    var topSpacing: () -> CGFloat = { 0 }
    @State private var expanded = true
    @State private var expandedDirectories: Set<String> = []
    @State private var selectedChange: ConversationChangedFile?

    var body: some View {
        let changes = self.changes
        let tree = expanded ? ConversationChangedFileTreeNode.build(changes) : []
        let directoryPaths = Set(tree.flatMap(\.allDirectoryPaths))
        let allDirectoriesExpanded = !directoryPaths.isEmpty
            && directoryPaths.isSubset(of: expandedDirectories)
        let visibleRows = ConversationChangedFileTreeRow.flatten(tree, expanded: expandedDirectories)
        let additions = changes.reduce(0) { $0 + $1.additions }
        let deletions = changes.reduce(0) { $0 + $1.deletions }
        if !changes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button { expanded.toggle() } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    Text("\(changes.count) changed \(changes.count == 1 ? "file" : "files")")
                        .fontWeight(.medium)
                    Text("+\(additions)").foregroundStyle(.green)
                    Text("−\(deletions)").foregroundStyle(.red)
                    Spacer()
                    if expanded, !directoryPaths.isEmpty {
                        Button { expandedDirectories = allDirectoriesExpanded ? [] : directoryPaths } label: {
                            Image(systemName: allDirectoriesExpanded
                                ? "chevron.up.chevron.down"
                                : "chevron.down.chevron.up")
                        }
                        .buttonStyle(DashboardQuietButtonStyle())
                        .accessibilityLabel(allDirectoriesExpanded
                            ? "Collapse all folders"
                            : "Expand all folders")
                    }
                    Button {
                        selectedChange = changes.first
                    } label: {
                        Label("Open diff", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(DashboardQuietButtonStyle())
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .frame(height: 48)

                if expanded {
                    Divider().opacity(0.45)
                    VStack(spacing: 0) {
                        ForEach(visibleRows) { row in
                            Button {
                                if row.node.isDirectory {
                                    if expandedDirectories.contains(row.node.path) {
                                        expandedDirectories.remove(row.node.path)
                                    } else {
                                        expandedDirectories.insert(row.node.path)
                                    }
                                } else {
                                    selectedChange = row.node.change
                                }
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: row.node.isDirectory
                                        ? "chevron.right"
                                        : "doc.text")
                                        .font(.system(size: 11, weight: .medium))
                                        .rotationEffect(.degrees(
                                            row.node.isDirectory
                                                && expandedDirectories.contains(row.node.path)
                                                ? 90 : 0
                                        ))
                                        .frame(width: 13)
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                    Image(systemName: row.node.isDirectory ? "folder" : "doc.text")
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                    Text(row.node.name)
                                        .lineLimit(1)
                                    Spacer()
                                    if row.node.additions > 0 {
                                        Text("+\(row.node.additions)").foregroundStyle(.green)
                                    }
                                    if row.node.deletions > 0 {
                                        Text("−\(row.node.deletions)").foregroundStyle(.red)
                                    }
                                }
                                .font(.system(size: 12.5))
                                .padding(.leading, CGFloat(row.depth) * 20)
                                .padding(.horizontal, 16)
                                .frame(height: 38)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .background(DashboardPalette.primary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(DashboardPalette.foreground.opacity(0.10), lineWidth: 1)
            }
            .sheet(item: $selectedChange) { change in
                // Resolve the current owner/revision while the sheet is open.
                ConversationDiffSheet(path: change.path, file: changes.first { $0.path == change.path })
            }
            .padding(.top, topSpacing())
        }
    }

    private var changes: [ConversationChangedFile] {
        var result: [String: ConversationChangedFile] = [:]
        for record in records {
            for change in record.activity.changes {
                result[change.path] = ConversationChangedFile(
                    path: change.path, runID: record.runID, activityID: record.activity.id,
                    version: record.activity.detailVersion,
                    additions: change.additionCount ?? 0, deletions: change.deletionCount ?? 0
                )
            }
        }
        return result.values.sorted { $0.path < $1.path }
    }

}

/// Tree and selection state carry metadata only, even if a caller supplies a
/// full record. Counts are materialized on the database worker, never in body.
private struct ConversationChangedFile: Identifiable, Hashable {
    let path: String
    let runID: String
    let activityID: String
    let version: Int64?
    let additions: Int
    let deletions: Int
    var id: String { path }
}

private struct ConversationChangedFileTreeNode: Identifiable {
    let id: String
    let path: String
    let name: String
    let change: ConversationChangedFile?
    let children: [Self]

    var isDirectory: Bool { change == nil }
    var additions: Int {
        change?.additions ?? children.reduce(0) { $0 + $1.additions }
    }
    var deletions: Int {
        change?.deletions ?? children.reduce(0) { $0 + $1.deletions }
    }
    var allDirectoryPaths: [String] {
        (isDirectory ? [path] : []) + children.flatMap(\.allDirectoryPaths)
    }

    static func build(_ changes: [ConversationChangedFile]) -> [Self] {
        nodes(
            changes.map {
                ($0.path.split(separator: "/").map(String.init), $0)
            },
            prefix: ""
        )
    }

    private static func nodes(
        _ entries: [([String], ConversationChangedFile)],
        prefix: String
    ) -> [Self] {
        let groups = Dictionary(grouping: entries) { $0.0.first ?? $0.1.path }
        return groups.keys.sorted().compactMap { name in
            guard let group = groups[name], let first = group.first else { return nil }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if first.0.count <= 1 {
                let change = first.1
                return Self(
                    id: "file:\(change.path)",
                    path: change.path,
                    name: name,
                    change: change,
                    children: []
                )
            }
            let children = nodes(group.map { (Array($0.0.dropFirst()), $0.1) }, prefix: path)
            return Self(
                id: "directory:\(path)",
                path: path,
                name: name,
                change: nil,
                children: children
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private struct ConversationChangedFileTreeRow: Identifiable {
    let node: ConversationChangedFileTreeNode
    let depth: Int
    var id: String { node.id }

    static func flatten(
        _ nodes: [ConversationChangedFileTreeNode],
        expanded: Set<String>,
        depth: Int = 0
    ) -> [Self] {
        nodes.flatMap { node in
            var rows = [Self(node: node, depth: depth)]
            if node.isDirectory, expanded.contains(node.path) {
                rows += flatten(node.children, expanded: expanded, depth: depth + 1)
            }
            return rows
        }
    }
}

private struct ConversationDiffSheet: View {
    let path: String
    let file: ConversationChangedFile?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.conversationActivityDetails) private var loadDetails
    @State private var state = LoadState.loading
    @State private var stateKey: LoadKey?
    @State private var loadToken: UUID?
    @State private var attempt = 0

    private enum LoadState {
        case loading
        case loaded(AgentRunFileChange)
        case failed(String)
    }

    private struct LoadKey: Hashable {
        let file: ConversationChangedFile?
        let attempt: Int
    }

    private var loadKey: LoadKey { LoadKey(file: file, attempt: attempt) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            if stateKey != loadKey {
                loading
            } else {
                switch state {
                case .loading:
                    loading
                case .loaded(let change):
                    diffContent(change)
                case .failed(let error):
                    VStack(spacing: 12) {
                        Text(error)
                            .foregroundStyle(DashboardPalette.danger)
                            .textSelection(.enabled)
                        Button("Retry") { attempt += 1 }
                            .buttonStyle(DashboardQuietButtonStyle())
                    }
                    .font(.system(size: 13))
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 780, idealWidth: 1040, minHeight: 520, idealHeight: 700)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .task(id: loadKey) { await load(loadKey) }
        .onDisappear {
            loadToken = nil
            state = .loading
            stateKey = nil
        }
    }

    private var loading: some View {
        ProgressView("Loading diff…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(_ key: LoadKey) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        loadToken = token
        stateKey = key
        state = .loading
        defer { if loadToken == token { loadToken = nil } }
        guard let file = key.file else {
            state = .failed("This file change is no longer available.")
            return
        }
        guard let loadDetails else {
            state = .failed("Diff details are unavailable in this conversation.")
            return
        }
        do {
            let activity = try await loadDetails(file.runID, file.activityID)
            guard !Task.isCancelled, loadToken == token else { return }
            guard let change = activity?.changes.last(where: { $0.path == file.path }) else {
                state = .failed("This file change is no longer available.")
                return
            }
            // Retain only the selected file for this sheet's lifetime.
            state = .loaded(change)
        } catch {
            guard !Task.isCancelled, loadToken == token else { return }
            state = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder
    private func diffContent(_ change: AgentRunFileChange) -> some View {
        if let unifiedDiff = change.unifiedDiff, !unifiedDiff.isEmpty {
            unifiedDiffPane(unifiedDiff)
        } else if change.oldText != nil || !change.newText.isEmpty {
            HStack(spacing: 0) {
                diffPane(title: "Before", text: change.oldText ?? "", color: .red)
                Divider()
                diffPane(title: "After", text: change.newText, color: .green)
            }
        } else {
            ContentUnavailableView(
                "Diff unavailable",
                systemImage: "doc.text.magnifyingglass",
                description: Text("The agent reported the changed path but did not supply diff content.")
            )
        }
    }

    private func diffPane(title: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(10)
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unifiedDiffPane(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : self
    }
}

func dashboardRunDuration(_ interval: TimeInterval) -> String {
    let milliseconds = max(0, interval * 1_000)
    if milliseconds < 1_000 {
        return "\(max(1, Int(milliseconds.rounded())))ms"
    }
    if milliseconds < 10_000 {
        let tenths = (milliseconds / 100).rounded() / 10
        return tenths >= 10 ? "10s" : String(format: "%.1fs", tenths)
    }
    if milliseconds < 60_000 {
        return "\(Int((milliseconds / 1_000).rounded()))s"
    }
    let minutes = Int(milliseconds / 60_000)
    let seconds = Int(((milliseconds.truncatingRemainder(dividingBy: 60_000)) / 1_000).rounded())
    if seconds == 0 { return "\(minutes)m" }
    if seconds == 60 { return "\(minutes + 1)m" }
    return "\(minutes)m \(seconds)s"
}

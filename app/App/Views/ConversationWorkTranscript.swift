import SwiftUI
import AppKit

/// Display-only run values shared by the desktop and the machine's runtime.
struct ConversationWorkRun {
    let id: String
    let conversationID: String
    let status: RunStatus
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
/// While the run streams, thinking and commentary stay visible and tool lists
/// fold at the next event boundary. The elapsed header folds all of it at any
/// time, and the turn folds itself when it ends.
struct ConversationWorkTranscript: View {
    let run: ConversationWorkRun
    let presentation: ConversationWorkPresentation?
    let records: [WorkspaceRunActivityRecord]
    let commentaryIDs: Set<String>
    /// The latest assistant text is rendered below this timeline. Its arrival
    /// closes the preceding tool list even before the run finishes.
    let hasFollowingResponse: Bool
    /// A projection precomputed from `records` and `commentaryIDs`; built in
    /// `body` when absent.
    let timeline: ConversationWorkTimeline?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @Environment(\.conversationTranscriptState) private var transcriptState
    @State private var localWorkExpanded = false
    @State private var localRunningFolded = false

    init(
        run: ConversationWorkRun,
        presentation: ConversationWorkPresentation?,
        records: [WorkspaceRunActivityRecord],
        commentaryIDs: Set<String> = [],
        hasFollowingResponse: Bool = false,
        timeline: ConversationWorkTimeline? = nil
    ) {
        self.run = run
        self.presentation = presentation
        self.records = records
        self.commentaryIDs = commentaryIDs
        self.hasFollowingResponse = hasFollowingResponse
        self.timeline = timeline
    }

    init(
        run: WorkspaceRunRecord,
        records: [WorkspaceRunActivityRecord],
        commentaryIDs: Set<String> = [],
        hasFollowingResponse: Bool = false,
        timeline: ConversationWorkTimeline? = nil
    ) {
        // A run starts with its message and ends with its last saved item.
        let duration = run.status == .running ? nil : run.startedAt.flatMap { start in
            run.completedAt.map { formattedRunDuration($0.timeIntervalSince(start)) }
        }
        self.init(run: ConversationWorkRun(id: run.id, conversationID: run.conversationID, status: run.status, error: run.error),
                  presentation: ConversationWorkPresentation(startedAt: run.startedAt, completedDuration: duration),
                  records: records, commentaryIDs: commentaryIDs,
                  hasFollowingResponse: hasFollowingResponse, timeline: timeline)
    }


    var body: some View {
        let timeline = self.timeline ?? ConversationWorkTimeline(records: records, commentaryIDs: commentaryIDs)
        let content = ConversationWorkTranscriptPresentation(
            runStatus: run.status,
            runError: run.error,
            hasVisibleActivities: timeline.hasVisibleActivities
        )
        let isRunning = run.status == .running
        let foldable = timeline.hasFoldableEntries
        let workExpanded = workDisclosure
        let folded = foldable && !workExpanded.wrappedValue
        if content.isVisible {
            VStack(alignment: .leading, spacing: 0) {
                let headerStyle = content.failureMessage != nil ? WovenPalette.danger : WovenPalette.mutedForeground
                if foldable {
                    Button { workExpanded.wrappedValue.toggle() } label: {
                        HStack(spacing: 6) {
                            headerLabel(failed: content.failureMessage != nil)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(workExpanded.wrappedValue ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ConversationElapsedButtonStyle())
                    .foregroundStyle(headerStyle)
                    .accessibilityValue(workExpanded.wrappedValue ? "Expanded" : "Collapsed")
                    .accessibilityHint(workExpanded.wrappedValue ? "Hides this turn's work" : "Shows this turn's thinking and tool calls")
                    .accessibilityIdentifier("work-turn:" + run.id)
                } else {
                    headerLabel(failed: content.failureMessage != nil)
                        .foregroundStyle(headerStyle)
                }

                // Failure belongs to the run, not to its optional work history.
                // Keep it visible even when no tool or thinking event was supplied.
                if let failureMessage = content.failureMessage {
                    Text(failureMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(WovenPalette.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                // The divider sits under the header from the moment the turn works.
                if content.hasVisibleActivities || isRunning {
                    Divider()
                        .overlay(WovenPalette.foreground.opacity(0.10))
                        .padding(.top, 12)

                    let entries = folded ? timeline.entriesOutsideFold : timeline.entries
                    if !entries.isEmpty {
                        let tailID = timeline.entries.last?.id
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(entries) { entry in
                                switch entry.content {
                                case .commentary(let activity):
                                    ConversationResponse(
                                        content: activity.content ?? "",
                                        isStreaming: false,
                                        showsCopyButton: false
                                    )
                                case .group(let group):
                                    ConversationWorkGroupRow(
                                        group: group,
                                        runID: run.id,
                                        runStatus: run.status,
                                        isTail: entry.id == tailID && !hasFollowingResponse
                                    )
                                case .activity(let activity):
                                    if activity.kind == .thought {
                                        ConversationThinkingBlock(activity: activity, runID: run.id,
                                            isLive: isRunning && entry.id == tailID && !hasFollowingResponse)
                                    } else if let reference = activity.htmlRender {
                                        ConversationHTMLRenderView(reference: reference)
                                    } else if let children = activity.subagents, !children.isEmpty {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(children) { child in
                                                ConversationSubagentRow(child: child)
                                            }
                                        }
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
                        .padding(.top, 14)
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                // A folded turn shows only the dots below.
                if isRunning && !hasFollowingResponse && !folded && timeline.needsThinkingIndicator {
                    HStack(spacing: 9) {
                        Image(systemName: "brain").frame(width: 17)
                        Text("Thinking").font(.system(size: 13.5))
                    }
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .padding(.top, 12)
                    .accessibilityLabel("Thinking")
                }
                // A response below takes the dots under its text instead.
                if isRunning && !hasFollowingResponse {
                    ConversationRunningDots().padding(.top, 6)
                }
            }
        }
    }

    /// Whether the turn's work shows: open while it runs, folded once it ends,
    /// and flipped by the header. A fold made while it runs is its own choice,
    /// so the end of the turn folds it whether or not it was open.
    private var workDisclosure: Binding<Bool> {
        let running = run.status == .running
        let flipped = conversationDisclosure(transcriptState, runID: run.id,
            itemID: running ? "turn:running" : "turn",
            local: running ? $localRunningFolded : $localWorkExpanded,
            interaction: transcriptInteraction)
        return Binding(get: { flipped.wrappedValue != running }, set: { flipped.wrappedValue = $0 != running })
    }

    /// The elapsed label, after an alert icon when the turn failed.
    @ViewBuilder
    private func headerLabel(failed: Bool) -> some View {
        if failed {
            HStack(spacing: 7) {
                LucideIcon(glyph: .alertCircle, size: 13)
                elapsedLabel
            }
        } else {
            elapsedLabel
        }
    }

    @ViewBuilder
    private var elapsedLabel: some View {
        switch run.status {
        case .running:
            if let startedAt = presentation?.startedAt {
                RunningElapsedLabel(startedAt: startedAt)
            } else {
                Text("Working")
            }
        case .queued:
            Text("Queued")
        case .completed:
            Text("Done after \(presentation?.completedDuration ?? "a moment")")
        case .failed:
            Text("Error\(presentation?.completedDuration.map { " after \($0)" } ?? "")")
        case .cancelled:
            Text("Idle (cancelled)\(presentation?.completedDuration.map { " after \($0)" } ?? "")")
        }
    }

    /// Whole seconds for a once-per-second count; longer runs use the shared format.
    static func elapsed(_ interval: TimeInterval) -> String {
        interval < 60 ? "\(max(0, Int(interval)))s" : formattedRunDuration(interval)
    }

    static func hasVisibleContent(run: WorkspaceRunRecord, timeline: ConversationWorkTimeline) -> Bool {
        ConversationWorkTranscriptPresentation(
            runStatus: run.status,
            runError: run.error,
            hasVisibleActivities: timeline.hasVisibleActivities
        ).isVisible
    }
}

private struct ConversationElapsedButtonStyle: ButtonStyle {
    @Environment(\.wovenTheme) private var theme
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

/// Supplied thinking stays in the transcript independently of tool disclosures.
/// Long traces retain the existing bounded, selectable reasoning viewport.
private struct ConversationThinkingBlock: View {
    let activity: AgentRunActivity
    let runID: String
    let isLive: Bool
    @Environment(\.conversationTranscriptState) private var transcriptState
    @State private var localScrollSnapshot = ConversationWorkScrollSnapshot()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Thinking", systemImage: "brain")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(WovenPalette.mutedForeground)
            ConversationBoundedWorkList(
                group: ConversationWorkGroup(id: activity.id, activities: [activity], endsTimeline: isLive),
                runID: runID, runStatus: isLive ? .running : .completed, followsAppends: isLive,
                initialScrollSnapshot: transcriptState?.workScrollSnapshot(scrollKey) ?? localScrollSnapshot,
                saveScrollSnapshot: { snapshot in
                    if let transcriptState { transcriptState.setWorkScrollSnapshot(scrollKey, snapshot) }
                    else { localScrollSnapshot = snapshot }
                })
        }
        .accessibilityIdentifier("work-thinking:" + activity.id)
    }

    private var scrollKey: String {
        ConversationTranscriptState.disclosureKey(runID: runID, itemID: "thinking:" + activity.id)
    }
}

/// Live tools append as separate rows in the outer conversation. Once another
/// event arrives (or the run ends), only this tool list becomes a disclosure.
private struct ConversationWorkGroupRow: View {
    let group: ConversationWorkGroup
    let runID: String
    let runStatus: RunStatus
    let isTail: Bool
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @Environment(\.conversationTranscriptState) private var transcriptState
    @State private var localExpanded = false
    @State private var localScrollSnapshot = ConversationWorkScrollSnapshot()

    var body: some View {
        let runIsActive = runStatus == .running
        let wasExpanded = transcriptState?.isExpanded(scrollKey) ?? localExpanded
        if runIsActive && isTail {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.activities) { activity in
                    ConversationActivityRow(activity: activity, runID: runID, runStatus: runStatus,
                        showsProgress: group.showsProgress(activity))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("work-live-group:" + group.id)
        } else if !wasExpanded, let single = group.singleActivity {
            ConversationActivityRow(activity: single, runID: runID, runStatus: runStatus,
                showsProgress: group.showsProgress(single))
        } else {
            let expanded = conversationDisclosure(transcriptState, runID: runID, itemID: group.id,
                local: $localExpanded, interaction: transcriptInteraction)
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.wrappedValue.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: group.hasFailure ? "exclamationmark.triangle"
                            : group.action?.systemImage ?? "wrench.and.screwdriver")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 17)
                        Text(group.summary)
                            .font(.system(size: 13.5, weight: .medium))
                            .lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                            .foregroundStyle(WovenPalette.mutedForeground)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(group.hasFailure ? Color.red.opacity(0.8)
                        : WovenPalette.foreground.opacity(0.72))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ConversationElapsedButtonStyle())
                .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("work-group:" + group.id)
                if expanded.wrappedValue {
                    ConversationBoundedWorkList(group: group, runID: runID, runStatus: runStatus,
                        followsAppends: false,
                        initialScrollSnapshot: transcriptState?.workScrollSnapshot(scrollKey) ?? localScrollSnapshot,
                        saveScrollSnapshot: { snapshot in
                            if let transcriptState { transcriptState.setWorkScrollSnapshot(scrollKey, snapshot) }
                            else { localScrollSnapshot = snapshot }
                        })
                        .padding(.top, 8).padding(.leading, 26)
                }
            }
        }
    }

    private var scrollKey: String {
        ConversationTranscriptState.disclosureKey(runID: runID, itemID: group.id)
    }
}

/// Only an expanded work group owns a scroll view. Short groups keep their
/// intrinsic height; long ones are capped and render rows lazily.
private struct ConversationBoundedWorkList: View {
    static let maximumHeight: CGFloat = 320

    let group: ConversationWorkGroup
    let runID: String
    let runStatus: RunStatus
    let followsAppends: Bool
    let initialScrollSnapshot: ConversationWorkScrollSnapshot
    let saveScrollSnapshot: (ConversationWorkScrollSnapshot) -> Void
    @State private var contentHeight = Self.maximumHeight
    @State private var scrollState = ConversationWorkScrollState()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrollOffset: CGFloat = 0
    @State private var reasoningText: [String: String] = [:]
    @State private var laidOutActivityIDs: [String]?
    @State private var growthStartedAtBottom = false
    @State private var isUserScrolling = false
    @State private var followTask: Task<Void, Never>?
    @State private var restoringScroll = true

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
                    !restoringScroll && !isUserScrolling && (scrollState.isAtBottom || growthStartedAtBottom))
                .environment(\.conversationInBoundedList, true)
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
            if restoringScroll {
                scrollOffset = after.offset
                scrollState.setAtBottom(after.isAtBottom)
                laidOutActivityIDs = ids
                // A compact preview may be at its bottom before the saved
                // reasoning page has loaded. Wait for its original position.
                guard after.contentHeight - after.viewportHeight + 4 >= initialScrollSnapshot.offset else { return }
                if followsAppends && initialScrollSnapshot.isAtBottom {
                    if after.isAtBottom { restoringScroll = false }
                    else { followAfterLayout() }
                } else if after.contentHeight - after.viewportHeight >= initialScrollSnapshot.offset {
                    scrollPosition.scrollTo(y: initialScrollSnapshot.offset)
                    restoringScroll = false
                }
                return
            }
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
            if followsAppends && !restoringScroll && !isUserScrolling && group.isThoughtOnly && before.keys.sorted() == after.keys.sorted(),
               after.allSatisfy({ key, value in value.utf16.starts(with: (before[key] ?? "").utf16) }),
               after.contains(where: { key, value in
                scrollState.shouldFollowTextAppend(from: before[key] ?? "", to: value,
                    wasAtBottom: scrollState.isAtBottom || growthStartedAtBottom)
               }) {
                followAfterLayout()
            }
        }
        .task {
            if followsAppends && initialScrollSnapshot.isAtBottom {
                followAfterLayout()
            } else if initialScrollSnapshot.offset > 0 {
                scrollPosition.scrollTo(y: initialScrollSnapshot.offset)
            } else {
                restoringScroll = false
            }
        }
        .onScrollPhaseChange { _, phase in
            isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if isUserScrolling { restoringScroll = false }
        }
        .onDisappear {
            followTask?.cancel()
            saveScrollSnapshot(.init(offset: scrollOffset, isAtBottom: scrollState.isAtBottom))
        }
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
                            isLive: runStatus == .running && group.showsProgress(activity),
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
                Color.clear.frame(height: 1).id("work-end")
    }
}

private struct ConversationActivityRow: View {
    let activity: AgentRunActivity
    let runID: String
    let runStatus: RunStatus
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
                    .foregroundStyle(isFailure ? .red.opacity(0.8) : WovenPalette.foreground.opacity(0.72))
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
                            .foregroundStyle(WovenPalette.foreground.opacity(
                                activity.kind == .thought ? 0.58 : 0.72
                            ))
                            .fixedSize(horizontal: false, vertical: true)
                        if let expanded { chevron(expanded) }
                    }
                    if let secondaryLabel {
                        Text(secondaryLabel)
                            .font(.system(size: 12.5))
                            .foregroundStyle(WovenPalette.mutedForeground)
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
            .foregroundStyle(WovenPalette.mutedForeground)
    }

    @ViewBuilder
    private var activityIcon: some View {
        if isFailure {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red.opacity(0.8))
                .frame(width: 17)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WovenPalette.mutedForeground)
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

    private var isLive: Bool { runStatus == .running && showsProgress }

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
        case .thought: "brain"
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
        "\(runID)\u{1F}\(activity.id)\u{1F}\(activity.detailStamp.map(String.init) ?? "")" as NSString
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
                        activityID: activity.id, runID: runID,
                        text: content, isLive: isLive,
                        hasCompleteText: activity.detailsAvailable != true || complete != nil)
                } else {
                    ConversationPagedText(text: content, style: .code)
                }
            }
            // Reasoning disclosures contain supplied reasoning, not the ACP
            // envelope that carried it. Tool details retain their raw fields.
            if let calls = field(\.codeCalls) {
                // A script: its source folded away, the tools it called, then what it printed.
                ConversationCodeScript(source: field(\.rawInputJSON))
                ConversationCodeCallList(calls: calls)
                rawBlock("Output", field(\.rawOutputJSON))
            } else if let questions = field(\.questions) {
                // Each question with its answer, or that it was not answered.
                ConversationQuestionList(questions: questions, isLive: isLive)
            } else if activity.kind != .thought {
                rawBlock("Input", field(\.rawInputJSON))
                rawBlock("Output", field(\.rawOutputJSON))
                rawBlock("Event", field(\.rawPayloadJSON))
            }
            // A compact record can contain no inline fields. Keep a visible
            // placeholder so its visibility-driven detail read can start.
            if loadToken != nil || waitingForDetails || (activity.detailsAvailable == true && complete == nil && error == nil) {
                Text("Loading details…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(error)
                        .foregroundStyle(WovenPalette.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { attempt += 1 }
                        .buttonStyle(WovenQuietButtonStyle())
                }
                .font(.system(size: 12.5))
            }
        }
        .padding(.top, 7)
        .padding(.leading, indentation)
        // A bounded viewport may expose less than one percent of a long
        // reasoning page. Any visible portion must keep its detail load alive.
        .onScrollVisibilityChange(threshold: 0) { visible in
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
        LoadKey(visible: isVisible, settled: !isLive, version: isLive ? nil : activity.detailStamp, attempt: attempt)
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
                    .foregroundStyle(WovenPalette.mutedForeground)
                ConversationPagedText(text: value, style: .raw)
            }
        }
    }
}

/// A script's source, folded away until asked for.
private struct ConversationCodeScript: View {
    let source: String?
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var expanded = false

    var body: some View {
        if let source, !source.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                // Its chevron follows the label, as on every other disclosure here.
                Button {
                    transcriptInteraction()
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text("Script").font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded { ConversationPagedText(text: source, style: .raw) }
            }
        }
    }
}

/// The tools a script called. A long list scrolls within a bounded height,
/// as an expanded work group does, so one script never pushes the rest of
/// the transcript far down.
private struct ConversationCodeCallList: View {
    static let maximumHeight: CGFloat = 320
    /// About one row, for the first layout before the rows are measured.
    private static let rowEstimate: CGFloat = 24
    let calls: [AgentRunCodeCall]
    @Environment(\.conversationInBoundedList) private var inBoundedList
    @State private var contentHeight: CGFloat?

    var body: some View {
        if inBoundedList {
            // The group scrolls; a second scroll area inside it would only trap the pointer.
            rows
        } else {
            let height = contentHeight ?? CGFloat(calls.count) * Self.rowEstimate
            ScrollView(.vertical) {
                rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.never)
            .scrollDisabled(height <= Self.maximumHeight)
            .frame(height: min(Self.maximumHeight, max(1, height)))
            .defaultScrollAnchor(.top, for: .initialOffset)
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(calls) { call in ConversationCodeCallRow(call: call) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The questions the model asked with its question tool, each with the answer given.
private struct ConversationQuestionList: View {
    let questions: [AgentRunQuestion]
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 3) {
                    let title = question.title?.nonempty
                    Text(title ?? question.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(WovenPalette.foreground.opacity(0.72))
                    if title != nil, question.text.nonempty != nil {
                        Text(question.text).font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground)
                    }
                    if let answer = question.answer, !answer.isEmpty {
                        Text(answer.joined(separator: ", ")).font(.system(size: 12.5)).foregroundStyle(WovenPalette.foreground)
                    } else {
                        Text(question.answer == nil ? (isLive ? "Waiting for an answer" : "Not answered") : "Left unanswered")
                            .font(.system(size: 12.5)).foregroundStyle(WovenPalette.mutedForeground)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool a script called: its name, how it went, and its error when it failed.
private struct ConversationCodeCallRow: View {
    let call: AgentRunCodeCall

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The note of calls left out is not a call, so it has no icon.
                Image(systemName: call.status == .failed ? "exclamationmark.triangle"
                    : call.status == .shownInChat ? "rectangle.on.rectangle" : "wrench.and.screwdriver")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(call.status == .failed ? WovenPalette.danger : WovenPalette.mutedForeground)
                    .frame(width: 14)
                    .opacity(call.status == nil ? 0 : 1)
                Text(call.name)
                    .font(.system(size: 12.5, weight: call.status == nil ? .regular : .medium))
                    .foregroundStyle(call.status == nil ? WovenPalette.mutedForeground : WovenPalette.foreground.opacity(0.72))
                    .lineLimit(1).truncationMode(.middle)
                if let label {
                    Text(label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
                Spacer(minLength: 0)
            }
            if let error = call.error?.nonempty {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(WovenPalette.danger)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String? {
        switch call.status {
        case .running: "Running"
        case .completed: "Done"
        case .failed: "Failed"
        case .shownInChat: "Shown in the chat"
        case nil: nil
        }
    }
}

/// Reasoning uses the response's Markdown renderer, safe links, and native
/// selection. Paging bounds layout without hiding any supplied trace text.
private struct ConversationReasoningText: View {
    private static let pageLength = 20_000
    let activityID: String
    let runID: String
    let text: String
    let isLive: Bool
    let hasCompleteText: Bool
    @Environment(\.conversationReasoningAtLiveEdge) private var isAtLiveEdge
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @Environment(\.conversationTranscriptState) private var transcriptState
    @State private var displayedEnd: Int?
    @State private var browsingHistory = false
    @State private var awaitingRestoredText = false

    private struct ContentState: Equatable {
        let text: String
        let isComplete: Bool
    }

    private var pageKey: String {
        ConversationTranscriptState.disclosureKey(runID: runID, itemID: "reasoning:" + activityID)
    }

    private var committedText: String {
        isLive ? AssistantStreamingText.readyPrefix(of: text) : text
    }

    var body: some View {
        let stream = committedText
        let count = stream.count
        let saved = displayedEnd == nil ? transcriptState?.reasoningPageSnapshot(pageKey) : nil
        let endOffset = count <= Self.pageLength ? count
            : min(displayedEnd ?? saved?.displayedEnd ?? (isLive ? count : Self.pageLength), count)
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
                .buttonStyle(WovenQuietButtonStyle())
                .font(.system(size: 12))
            }
            if !shown.isEmpty {
                ConversationResponse(content: shown, isStreaming: isLive, showsCopyButton: false)
            }
        }
        .onAppear {
            if displayedEnd == nil {
                displayedEnd = saved?.displayedEnd ?? endOffset
                browsingHistory = saved?.browsingHistory ?? false
                awaitingRestoredText = saved != nil && !hasCompleteText
            }
        }
        .onDisappear {
            transcriptState?.setReasoningPageSnapshot(pageKey,
                .init(displayedEnd: displayedEnd ?? endOffset, browsingHistory: browsingHistory))
        }
        .onChange(of: ContentState(text: stream, isComplete: hasCompleteText)) { before, after in
            guard after.isComplete else {
                if before.isComplete { awaitingRestoredText = true }
                return
            }
            if awaitingRestoredText {
                displayedEnd = min(displayedEnd ?? after.text.count, after.text.count)
                awaitingRestoredText = false
                return
            }
            if !before.isComplete {
                // The compact preview's end is not a chosen page boundary.
                // Open the first complete trace at its normal live/settled page.
                displayedEnd = isLive ? after.text.count : min(after.text.count, Self.pageLength)
                return
            }
            if !browsingHistory, isAtLiveEdge, after.text.utf16.starts(with: before.text.utf16) {
                displayedEnd = after.text.count
            } else if before.text.count <= Self.pageLength {
                // Below the limit the full trace was rendered, even while
                // reading above the edge. Preserve that actual page when a
                // new append first requires paging.
                displayedEnd = min(before.text.count, after.text.count)
            } else if let displayedEnd, displayedEnd > after.text.count {
                self.displayedEnd = after.text.count
            }
        }
        .onChange(of: isAtLiveEdge) { _, atEdge in
            if atEdge, isLive, !browsingHistory, hasCompleteText, !awaitingRestoredText {
                displayedEnd = committedText.count
            }
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

    /// Inside an expanded work group, which already scrolls within its own
    /// bounded height.
    @Entry var conversationInBoundedList = false
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
                .background(WovenPalette.muted.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                textView(shown)
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if remaining > 0 {
                Button("Show more (\(remaining.formatted()) more characters)") { pages += 1 }
                    .buttonStyle(WovenQuietButtonStyle())
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
        case .code: "curlybraces"
        case .read: "doc.text"
        case .edit: "pencil.and.outline"
        case .codeSearch: "magnifyingglass"
        case .webSearch, .webFetch, .browser: "globe"
        case .computer: "desktopcomputer"
        case .delegate: "person.2"
        case .question: "questionmark.bubble"
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
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .frame(width: 17)
                Text(activity.title?.nonempty ?? "Proposed plan")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(WovenPalette.foreground.opacity(0.72))
            }
            if let content = activity.content?.nonempty {
                ConversationMarkdown(document: ConversationMarkdownDocument(content), isStreaming: false)
            } else {
                ForEach(activity.planEntries.indices, id: \.self) { index in
                    Text("• \(activity.planEntries[index].content)")
                        .font(.system(size: 13))
                        .foregroundStyle(WovenPalette.mutedForeground)
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
                        .buttonStyle(WovenQuietButtonStyle())
                        .accessibilityLabel(allDirectoriesExpanded
                            ? "Collapse all folders"
                            : "Expand all folders")
                    }
                    Button {
                        selectedChange = changes.first
                    } label: {
                        Label("Open diff", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(WovenQuietButtonStyle())
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
                                        .foregroundStyle(WovenPalette.mutedForeground)
                                    Image(systemName: row.node.isDirectory ? "folder" : "doc.text")
                                        .foregroundStyle(WovenPalette.mutedForeground)
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
            .background(WovenPalette.primary.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(WovenPalette.foreground.opacity(0.10), lineWidth: 1)
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
                    version: record.activity.detailStamp,
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
                            .foregroundStyle(WovenPalette.danger)
                            .textSelection(.enabled)
                        Button("Retry") { attempt += 1 }
                            .buttonStyle(WovenQuietButtonStyle())
                    }
                    .font(.system(size: 13))
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 780, idealWidth: 1040, minHeight: 520, idealHeight: 700)
        .task(id: loadKey) { await load(loadKey) }
        .onDisappear {
            loadToken = nil
            state = .loading
            stateKey = nil
        }
    }

    private var loading: some View {
        Text("Loading diff…")
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

extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : self
    }
}

func formattedRunDuration(_ interval: TimeInterval) -> String {
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

/// "Working for …" while a run is under way. It ticks once a second from its
/// own timer and only repaints itself: its size never changes, so a tick
/// never makes the transcript lay out again.
private struct RunningElapsedLabel: NSViewRepresentable {
    let startedAt: Date

    func makeNSView(context: Context) -> RunningElapsedView { RunningElapsedView() }

    func updateNSView(_ view: RunningElapsedView, context: Context) { view.startedAt = startedAt }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RunningElapsedView, context: Context) -> CGSize? {
        RunningElapsedView.size
    }
}

private final class RunningElapsedView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Wide enough for any count, so the label keeps one size.
    static let size: CGSize = {
        let size = NSAttributedString(string: "Working for 999m 59s", attributes: [.font: font]).size()
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }()

    var startedAt = Date.distantPast {
        didSet { if startedAt != oldValue { needsDisplay = true; schedule() } }
    }
    private var timer: Timer?

    override var isFlipped: Bool { true }

    private var text: String {
        "Working for \(ConversationWorkTranscript.elapsed(Date().timeIntervalSince(startedAt)))"
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedule()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Fires on each whole second since the start, as the count changes.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard window != nil, startedAt != .distantPast else { return }
        let next = startedAt.addingTimeInterval(Date().timeIntervalSince(startedAt).rounded(.down) + 1)
        let timer = Timer(fire: next, interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: WovenColors.mutedForeground])
            .draw(at: .zero)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text }
}

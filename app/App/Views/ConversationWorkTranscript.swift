import AppKit
import SwiftUI
import WovenMatterCore
import WovenMatterDashboardStore

func conversationActivityShowsProgress(
    runStatus: String,
    activityStatus: String?,
    activityPhase: String?
) -> Bool {
    guard runStatus.lowercased() == "running" else { return false }
    return ["pending", "in_progress", "running", "started"].contains(
        activityStatus?.lowercased() ?? activityPhase?.lowercased() ?? ""
    )
}

private struct ConversationTranscriptInteractionKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

private struct ConversationArchiveConversationKey: EnvironmentKey {
    static let defaultValue = ""
}

private struct ConversationSubagentHistoryKey: EnvironmentKey {
    static let defaultValue: (@MainActor (BuiltInSubagentArchiveRequest) async throws -> GatewayJSONValue)? = nil
}

extension EnvironmentValues {
    var conversationTranscriptInteraction: @MainActor () -> Void {
        get { self[ConversationTranscriptInteractionKey.self] }
        set { self[ConversationTranscriptInteractionKey.self] = newValue }
    }
    var conversationArchiveConversationID: String {
        get { self[ConversationArchiveConversationKey.self] }
        set { self[ConversationArchiveConversationKey.self] = newValue }
    }
    var conversationSubagentHistory: (@MainActor (BuiltInSubagentArchiveRequest) async throws -> GatewayJSONValue)? {
        get { self[ConversationSubagentHistoryKey.self] }
        set { self[ConversationSubagentHistoryKey.self] = newValue }
    }
}

/// Expanded work has its own scroll owner. Short transcripts retain their
/// intrinsic height; long histories are capped at 420 points.
private struct ConversationBoundedTranscript<Content: View>: View {
    @State private var contentHeight: CGFloat = 420
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.never)
        .frame(height: min(420, max(1, contentHeight)))
        .defaultScrollAnchor(.top)
    }
}

struct ConversationWorkTranscript: View {
    let run: WorkspaceRunRecord
    let presentation: DashboardRunPresentation?
    let records: [WorkspaceRunActivityRecord]
    let commentaryIDs: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var expanded: Bool

    init(
        run: WorkspaceRunRecord,
        presentation: DashboardRunPresentation?,
        records: [WorkspaceRunActivityRecord],
        commentaryIDs: Set<String> = [],
        hasFinalReply: Bool = false
    ) {
        self.run = run
        self.presentation = presentation
        self.records = records
        self.commentaryIDs = commentaryIDs
        _expanded = State(initialValue: run.status != "completed" || !hasFinalReply)
    }

    var body: some View {
        let activities = self.activities
        let content = ConversationWorkTranscriptPresentation(
            runStatus: run.status,
            runError: run.error,
            hasVisibleActivities: activities.contains { $0.kind != .fileChange }
        )
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
                if content.hasVisibleActivities {
                    Button {
                        transcriptInteraction()
                        expanded.toggle()
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
                // Keep it visible even when that history is empty or collapsed.
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

                    if expanded {
                        let timelineItems = timelineItems(for: activities)
                        ConversationBoundedTranscript {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(timelineItems) { item in
                                    if item.activities.first?.kind == .tool {
                                        ConversationToolGroup(
                                            activities: item.activities,
                                            runStatus: run.status
                                        )
                                    } else if let activity = item.activities.first {
                                        if activity.kind == .assistant {
                                            ConversationResponse(
                                                content: RemoteNoteEditEnvelope.redactingEnvelopes(in: activity.content ?? ""),
                                                isStreaming: false
                                            )
                                        } else {
                                            ConversationActivityRow(activity: activity, runStatus: run.status)
                                        }
                                    }
                                }
                            }
                        }
                        .environment(\.conversationArchiveConversationID, run.conversationID)
                        .padding(.top, 14)
                        .padding(.leading, 18)
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var elapsedLabel: some View {
        if run.status == "running", let startedAt = presentation?.startedAt {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                Text("Working for \(dashboardRunDuration(context.date.timeIntervalSince(startedAt)))")
            }
        } else if run.status == "completed" {
            Text("Worked for \(presentation?.completedDuration ?? "a moment")")
        } else if run.status == "failed" {
            Text("Run failed\(presentation?.completedDuration.map { " after \($0)" } ?? "")")
        } else if run.status == "cancelled" {
            Text("Stopped\(presentation?.completedDuration.map { " after \($0)" } ?? "")")
        } else if run.status == "uncertain" {
            Text("Waiting to confirm the remote outcome")
        } else {
            Text(run.status.capitalized)
        }
    }

    private var activities: [AgentRunActivity] {
        Self.visibleActivities(in: records, commentaryIDs: commentaryIDs)
    }

    static func hasVisibleContent(run: WorkspaceRunRecord, in records: [WorkspaceRunActivityRecord], commentaryIDs: Set<String>) -> Bool {
        ConversationWorkTranscriptPresentation(
            runStatus: run.status,
            runError: run.error,
            hasVisibleActivities: visibleActivities(in: records, commentaryIDs: commentaryIDs).contains { $0.kind != .fileChange }
        ).isVisible
    }

    private static func visibleActivities(in records: [WorkspaceRunActivityRecord], commentaryIDs: Set<String>) -> [AgentRunActivity] {
        var order: [String] = []
        var values: [String: AgentRunActivity] = [:]
        for record in records.filter({
            $0.activity.phase != "clear" && ($0.activity.kind != .assistant || commentaryIDs.contains($0.activity.id))
        }).sorted(by: WorkspaceRunActivityRecord.precedes) {
            let update = record.activity
            if let prior = values[update.id] {
                values[update.id] = prior.merging(update)
            } else {
                order.append(update.id)
                values[update.id] = update
            }
        }
        return order.compactMap { values[$0] }
    }

    private func timelineItems(for activities: [AgentRunActivity]) -> [ConversationTimelineItem] {
        var items: [ConversationTimelineItem] = []
        var pendingTools: [AgentRunActivity] = []
        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            items.append(ConversationTimelineItem(activities: pendingTools))
            pendingTools.removeAll(keepingCapacity: true)
        }
        for activity in activities where activity.kind != .fileChange {
            if activity.kind == .tool {
                pendingTools.append(activity)
            } else {
                flushTools()
                items.append(ConversationTimelineItem(activities: [activity]))
            }
        }
        flushTools()
        return items
    }
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

private struct ConversationTimelineItem: Identifiable {
    let activities: [AgentRunActivity]
    var id: String { activities.first?.id ?? "empty" }
}

private struct ConversationToolGroup: View {
    let activities: [AgentRunActivity]
    let runStatus: String
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var expanded = false

    var body: some View {
        // Keep the disclosure and each tool row in place across start/result
        // updates and the arrival of additional calls.
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { transcriptInteraction(); expanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(activities) { activity in
                    ConversationActivityRow(activity: activity, runStatus: runStatus)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: summaryIcon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 17)
                Text(summaryLabel)
                    .font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(DashboardPalette.foreground.opacity(0.72))
        }
    }

    private var hasActiveTools: Bool {
        activities.contains {
            conversationActivityShowsProgress(
                runStatus: runStatus,
                activityStatus: $0.status,
                activityPhase: $0.phase
            )
        }
    }

    private var summaryLabel: String {
        (singleCategory ?? .generic).summary(count: activities.count, isRunning: hasActiveTools)
    }

    private var summaryIcon: String {
        singleCategory?.systemImage ?? "wrench.and.screwdriver"
    }

    private var singleCategory: ConversationToolCategory? {
        let categories = Set(activities.map(ConversationToolCategory.init))
        return categories.count == 1 ? categories.first : nil
    }
}

private struct ConversationActivityRow: View {
    let activity: AgentRunActivity
    let runStatus: String
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var rawExpanded = false

    var body: some View {
        if activity.kind == .plan, !activity.planEntries.isEmpty {
            ConversationPlanProgress(activity: activity)
        } else if activity.kind != .fileChange {
            if isExpandable {
                DisclosureGroup(isExpanded: Binding(get: { rawExpanded }, set: { transcriptInteraction(); rawExpanded = $0 })) {
                    activityDetails
                } label: {
                    activityLabel
                }
            } else {
                activityLabel
            }
        }
    }

    @ViewBuilder
    private var activityLabel: some View {
        if activity.kind == .activity, let content = activity.content?.nonempty {
            Text(content)
                .font(.system(size: 13))
                .foregroundStyle(isFailure ? .red.opacity(0.8) : DashboardPalette.foreground.opacity(0.72))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                activityIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryLabel)
                        .font(.system(
                            size: 13.5,
                            weight: activity.kind == .thought ? .regular : .medium
                        ))
                        .foregroundStyle(DashboardPalette.foreground.opacity(
                            activity.kind == .thought ? 0.58 : 0.72
                        ))
                        .fixedSize(horizontal: false, vertical: true)
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

    private var activityDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let subagents = activity.subagents {
                ForEach(subagents) { child in
                    ConversationSubagentRow(child: child)
                }
            }
            if let expandedContent {
                Text(String(expandedContent.prefix(120_000)) + (expandedContent.count > 120_000 ? "\n… (display truncated)" : ""))
                    .font(activity.kind == .thought
                        ? .system(size: 12.5)
                        : .system(size: 11.5, design: .monospaced))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            rawBlock("Input", activity.rawInputJSON)
            rawBlock("Output", activity.rawOutputJSON)
            rawBlock("Event", activity.rawPayloadJSON)
        }
        .padding(.top, 7)
        .padding(.leading, 26)
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
                .foregroundStyle(DashboardPalette.mutedForeground)
                .frame(width: 17)
        }
    }

    private var primaryLabel: String {
        let fallback: String = switch activity.kind {
            case .assistant: "Commentary"
            case .thought: "Thinking"
            case .tool: "Used a tool"
            case .plan: "Updated the plan"
            case .fileChange: "Changed files"
            case .progress: "Progress"
            case .activity: "Agent activity"
        }
        return activity.title?.nonempty ?? activity.toolName?.nonempty ?? fallback
    }

    private var secondaryLabel: String? {
        if let detail = activity.detail?.nonempty { return detail }
        guard activity.kind != .activity,
              let content = activity.content?.nonempty else { return nil }
        return Self.preview(content)
    }

    private var expandedContent: String? {
        guard rawExpanded, activity.kind != .activity else { return nil }
        let content = activity.content?.nonempty
        return content == secondaryLabel ? nil : content
    }

    private var isFailure: Bool {
        ["failed", "error", "cancelled", "canceled"].contains(
            activity.status?.lowercased() ?? ""
        )
    }

    private var hasRawDetails: Bool {
        activity.rawInputJSON != nil || activity.rawOutputJSON != nil || activity.rawPayloadJSON != nil
    }

    private var isExpandable: Bool {
        activity.subagents?.isEmpty == false || hasRawDetails
            || (activity.kind != .activity && (activity.content?.nonempty?.count ?? 0) > 140)
    }

    private var systemImage: String {
        if activity.subagents != nil { return "person.2" }
        return switch activity.kind {
        case .assistant: "text.bubble"
        case .thought: "sparkles"
        case .tool: ConversationToolCategory(activity).systemImage
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

    @ViewBuilder
    private func rawBlock(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                ScrollView(.horizontal) {
                    Text(String(value.prefix(120_000)) + (value.count > 120_000 ? "\n… (display truncated)" : ""))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(9)
                }
                .scrollIndicators(.never)
                .background(DashboardPalette.muted.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct ConversationSubagentRow: View {
    let child: AgentRunSubagent
    @Environment(\.conversationTranscriptInteraction) private var transcriptInteraction
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { transcriptInteraction(); expanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                if let task = child.task?.nonempty { textBlock("Task", task) }
                VStack(alignment: .leading, spacing: 3) {
                    metadata("Model", child.modelID)
                    metadata("Provider", child.provider)
                    metadata("Connection", child.connectionLabel?.nonempty ?? child.connectionID)
                    metadata("Access", child.accessKind)
                    metadata("Thinking", child.thinking)
                    metadata("Archive ID", child.id)
                }
                if let detail = child.detail?.nonempty { textBlock("Status", detail) }
                if let result = child.result?.nonempty { textBlock("Result", result) }
                if let activity = child.activity, !activity.isEmpty { entries("Activity", activity) }
                if let history = child.history, !history.isEmpty { entries("Recent Messages", history) }
                if let sourceID = child.sourceID,
                   let nativeSessionID = child.nativeSessionID,
                   let nativeConversationID = child.nativeConversationID {
                    ConversationSubagentHistory(sourceID: sourceID, nativeSessionID: nativeSessionID,
                        nativeConversationID: nativeConversationID)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(child.name?.nonempty ?? "Subagent")
                    .font(.system(size: 12.5, weight: .medium))
                if let state = child.state?.nonempty {
                    Text(state.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(DashboardPalette.foreground.opacity(0.72))
        }
    }

    @ViewBuilder
    private func metadata(_ label: String, _ value: String?) -> some View {
        if let value = value?.nonempty {
            Text("\(label): \(value)")
                .font(.system(size: 11.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func textBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11.5, weight: .medium))
            Text(String(value.prefix(120_000)))
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DashboardPalette.mutedForeground)
    }

    private func entries(_ label: String, _ values: [AgentRunSubagentActivity]) -> some View {
        DisclosureGroup(label) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(values) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title?.nonempty ?? entry.kind?.capitalized ?? "Activity")
                            .font(.system(size: 11.5, weight: .medium))
                        if let status = entry.status?.nonempty { metadata("Status", status) }
                        if let content = entry.content?.nonempty {
                            Text(String(content.prefix(120_000)))
                                .font(.system(size: 12.5))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 5)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(DashboardPalette.mutedForeground)
    }
}

private struct ConversationSubagentHistory: View {
    let sourceID: String
    let nativeSessionID: String
    let nativeConversationID: String
    @Environment(\.conversationArchiveConversationID) private var conversationID
    @Environment(\.conversationSubagentHistory) private var loadHistory
    @State private var expanded = false
    @State private var rows: [GatewayJSONValue] = []
    @State private var cursor: Int64 = 0
    @State private var hasMore = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if loadHistory != nil {
            DisclosureGroup("History", isExpanded: $expanded) {
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            if let fields = row.objectValue, let eventID = fields["id"]?.stringValue {
                                ConversationSubagentArchiveEvent(request: request(eventID: eventID), fields: fields)
                            }
                        }
                        if let error { Text(error).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
                        if hasMore {
                            Button(rows.isEmpty ? "Load history" : "Load more history") { Task { await loadNextPage() } }
                                .buttonStyle(DashboardQuietButtonStyle())
                                .disabled(busy)
                        }
                        if busy { ProgressView().controlSize(.small) }
                    }.padding(.top, 5)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(DashboardPalette.mutedForeground)
        }
    }

    private func request(eventID: String? = nil) -> BuiltInSubagentArchiveRequest {
        .init(conversationID: conversationID, sourceID: sourceID,
            nativeSessionID: nativeSessionID, nativeConversationID: nativeConversationID,
            after: cursor, eventID: eventID)
    }

    @MainActor private func loadNextPage() async {
        guard !busy, let loadHistory else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let page = try await loadHistory(request())
            rows.append(contentsOf: page.objectValue?["rows"]?.arrayValue ?? [])
            hasMore = page.objectValue?["hasMore"]?.boolValue ?? false
            cursor = Int64(page.objectValue?["nextCursor"]?.intValue ?? Int(cursor))
        } catch { self.error = error.localizedDescription }
    }
}

private struct ConversationSubagentArchiveEvent: View {
    let request: BuiltInSubagentArchiveRequest
    let fields: [String: GatewayJSONValue]
    @Environment(\.conversationSubagentHistory) private var loadHistory
    @State private var chunks: [String] = []
    @State private var offset = 0
    @State private var hasMore = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        DisclosureGroup(fields["kind"]?.stringValue ?? "Native record") {
            VStack(alignment: .leading, spacing: 6) {
                if let text = fields["text_content"]?.stringValue, !text.isEmpty {
                    Text(text).font(.system(size: 12.5)).textSelection(.enabled)
                }
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    Text(chunk).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                }
                if let error { Text(error).foregroundStyle(DashboardPalette.danger).textSelection(.enabled) }
                if hasMore {
                    Button(chunks.isEmpty ? "Read native record" : "Read more") { Task { await loadNextChunk() } }
                        .buttonStyle(DashboardQuietButtonStyle()).disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
    }

    @MainActor private func loadNextChunk() async {
        guard !busy, let loadHistory else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            var next = request; next.offset = offset
            let page = try await loadHistory(next)
            guard let row = page.objectValue?["rows"]?.arrayValue?.first?.objectValue else {
                throw BackendRPCError.remote("The native record is unavailable.")
            }
            chunks.append(row["payload"]?.stringValue ?? "")
            hasMore = (row["payload_has_more"]?.intValue ?? 0) != 0
            offset += 65536
        } catch { self.error = error.localizedDescription }
    }
}

private enum ConversationToolCategory: Hashable {
    case command
    case read
    case write
    case search
    case web
    case delegated
    case generic

    init(_ activity: AgentRunActivity) {
        let name = (activity.toolName ?? activity.title ?? "").lowercased()
        if name.contains("bash") || name.contains("shell") || name == "exec"
            || name.contains("command") {
            self = .command
        } else if name.contains("web") || name.contains("fetch") {
            self = .web
        } else if name.contains("grep") || name.contains("glob")
            || name.contains("search") || name.contains("find") {
            self = .search
        } else if name.contains("write") || name.contains("edit")
            || name.contains("patch") {
            self = .write
        } else if name.contains("read") {
            self = .read
        } else if name.contains("task") || name.contains("agent") {
            self = .delegated
        } else {
            self = .generic
        }
    }

    var systemImage: String {
        switch self {
        case .command: "terminal"
        case .read: "doc.text"
        case .write: "pencil.and.outline"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .delegated: "person.2"
        case .generic: "wrench.and.screwdriver"
        }
    }

    func summary(count: Int, isRunning: Bool) -> String {
        let plural = count == 1 ? "" : "s"
        switch self {
        case .command: return "\(isRunning ? "Running" : "Ran") \(count) command\(plural)"
        case .read: return "\(isRunning ? "Reading" : "Read") \(count) file\(plural)"
        case .write: return "\(isRunning ? "Updating" : "Changed") \(count) file\(plural)"
        case .search: return "\(isRunning ? "Running" : "Ran") \(count) search\(count == 1 ? "" : "es")"
        case .web: return isRunning ? "Using the web · \(count) call\(plural)" : "Used the web \(count) time\(plural)"
        case .delegated: return "\(isRunning ? "Delegating" : "Delegated") \(count) task\(plural)"
        case .generic: return "\(isRunning ? "Using" : "Used") \(count) tool\(plural)"
        }
    }
}

private struct ConversationPlanProgress: View {
    let activity: AgentRunActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(activity.planEntries.indices, id: \.self) { index in
                        Capsule()
                            .fill(isComplete(activity.planEntries[index])
                                ? DashboardPalette.primary
                                : DashboardPalette.foreground.opacity(0.12))
                            .frame(width: 18, height: 4)
                    }
                }
                Text(activity.title?.nonempty ?? currentStep?.content ?? "Plan")
                    .lineLimit(1)
                Text("\(completedCount)/\(activity.planEntries.count)")
                    .monospacedDigit()
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .font(.system(size: 13.5, weight: .medium))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(activity.planEntries) { entry in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: isComplete(entry) ? "checkmark" : "circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isComplete(entry)
                                ? DashboardPalette.primary
                                : DashboardPalette.mutedForeground)
                            .frame(width: 14, height: 18)
                        Text(entry.content)
                            .font(.system(size: 13))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)
            if let content = activity.content, !content.isEmpty {
                ConversationMarkdown(document: ConversationMarkdownDocument(content), isStreaming: false)
            }
        }
    }

    private var completedCount: Int { activity.planEntries.filter(isComplete).count }
    private var currentStep: AgentRunPlanEntry? {
        activity.planEntries.first { !isComplete($0) } ?? activity.planEntries.last
    }
    private func isComplete(_ entry: AgentRunPlanEntry) -> Bool {
        ["completed", "complete", "done"].contains(entry.status.lowercased())
    }
}

struct ConversationChangedFilesCard: View {
    let records: [WorkspaceRunActivityRecord]
    // Evaluate only for a nonempty card. The lazy footer otherwise has no
    // height and need not project the work transcript merely to decide a gap.
    var topSpacing: () -> CGFloat = { 0 }
    @State private var expanded = true
    @State private var expandedDirectories: Set<String> = []
    @State private var selectedChange: AgentRunFileChange?

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
                ConversationDiffSheet(change: change)
            }
            .padding(.top, topSpacing())
        }
    }

    private var changes: [AgentRunFileChange] {
        var result: [String: AgentRunFileChange] = [:]
        for change in records.flatMap(\.activity.changes) { result[change.path] = change }
        return result.values.sorted { $0.path < $1.path }
    }

}

private struct ConversationChangedFileTreeNode: Identifiable {
    let id: String
    let path: String
    let name: String
    let change: AgentRunFileChange?
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

    static func build(_ changes: [AgentRunFileChange]) -> [Self] {
        nodes(
            changes.map {
                ($0.path.split(separator: "/").map(String.init), $0)
            },
            prefix: ""
        )
    }

    private static func nodes(
        _ entries: [([String], AgentRunFileChange)],
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
    let change: AgentRunFileChange
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(change.path).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
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
        .frame(minWidth: 780, idealWidth: 1040, minHeight: 520, idealHeight: 700)
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

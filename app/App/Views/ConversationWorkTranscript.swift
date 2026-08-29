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

struct ConversationWorkTranscript: View {
    let run: WorkspaceRunRecord
    let presentation: DashboardRunPresentation?
    let records: [WorkspaceRunActivityRecord]
    @State private var expanded: Bool

    init(
        run: WorkspaceRunRecord,
        presentation: DashboardRunPresentation?,
        records: [WorkspaceRunActivityRecord]
    ) {
        self.run = run
        self.presentation = presentation
        self.records = records
        _expanded = State(initialValue: run.status == "running")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
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
            .buttonStyle(.plain)
            .foregroundStyle(DashboardPalette.mutedForeground)

            Divider()
                .overlay(DashboardPalette.foreground.opacity(0.10))
                .padding(.top, 12)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(timelineItems) { item in
                        if item.activities.count == 1,
                           let activity = item.activities.first {
                            ConversationActivityRow(
                                activity: activity,
                                runStatus: run.status
                            )
                        } else {
                            ConversationToolGroup(
                                activities: item.activities,
                                runStatus: run.status
                            )
                        }
                    }
                    if activities.isEmpty {
                        HStack(spacing: 8) {
                            if run.status == "running" {
                                Image(systemName: "ellipsis")
                                    .frame(width: 16)
                            } else {
                                Image(systemName: "minus")
                                    .frame(width: 16)
                            }
                            Text(run.status == "running"
                                ? "Waiting for agent activity…"
                                : "This turn completed without tool or thinking activity.")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                }
                .padding(.top, 14)
                .padding(.leading, 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: run.status) { _, status in
            if status == "running" { expanded = true }
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
        } else {
            Text(run.status.capitalized)
        }
    }

    private var activities: [AgentRunActivity] {
        var order: [String] = []
        var values: [String: AgentRunActivity] = [:]
        for record in records.sorted(by: {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }) {
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

    private var timelineItems: [ConversationTimelineItem] {
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

private struct ConversationTimelineItem: Identifiable {
    let activities: [AgentRunActivity]
    var id: String { activities.map(\.id).joined(separator: ":") }
}

private struct ConversationToolGroup: View {
    let activities: [AgentRunActivity]
    let runStatus: String
    @State private var expanded = false

    var body: some View {
        if let activeActivity {
            VStack(alignment: .leading, spacing: 8) {
                ConversationActivityRow(
                    activity: activeActivity,
                    runStatus: runStatus
                )
                if !priorActivities.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(priorActivities) { activity in
                                ConversationActivityRow(
                                    activity: activity,
                                    runStatus: "completed"
                                )
                            }
                        }
                        .padding(.top, 7)
                    } label: {
                        Text("+\(priorActivities.count) previous \(priorActivities.count == 1 ? "tool call" : "tool calls")")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .padding(.leading, 26)
                }
            }
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activities) { activity in
                        ConversationActivityRow(
                            activity: activity,
                            runStatus: runStatus
                        )
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
    }

    private var activeActivity: AgentRunActivity? {
        guard runStatus.lowercased() == "running" else { return nil }
        return activities.last(where: {
            conversationActivityShowsProgress(
                runStatus: runStatus,
                activityStatus: $0.status,
                activityPhase: $0.phase
            )
        })
    }

    private var priorActivities: [AgentRunActivity] {
        guard let activeActivity else { return activities }
        return activities.filter { $0.id != activeActivity.id }
    }

    private var summaryLabel: String {
        guard let singleCategory else {
            return "Used \(activities.count) tools"
        }
        return singleCategory.summary(count: activities.count)
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
    @State private var rawExpanded = false

    var body: some View {
        if activity.kind == .plan, !activity.planEntries.isEmpty {
            ConversationPlanProgress(activity: activity)
        } else if activity.kind != .fileChange {
            if isExpandable {
                DisclosureGroup(isExpanded: $rawExpanded) {
                    activityDetails
                } label: {
                    activityLabel
                }
            } else {
                activityLabel
            }
        }
    }

    private var activityLabel: some View {
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

    private var activityDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let expandedContent {
                Text(expandedContent)
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
        guard let content = activity.content?.nonempty else { return nil }
        return Self.preview(content)
    }

    private var expandedContent: String? {
        guard rawExpanded else { return nil }
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
        hasRawDetails || (activity.content?.nonempty?.count ?? 0) > 140
    }

    private var systemImage: String {
        switch activity.kind {
        case .thought: "sparkles"
        case .tool: ConversationToolCategory(activity).systemImage
        case .plan: "list.bullet.clipboard"
        case .fileChange: "pencil.and.outline"
        case .progress: "arrow.trianglehead.2.clockwise.rotate.90"
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
                    Text(value)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(9)
                }
                .background(DashboardPalette.muted.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
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

    func summary(count: Int) -> String {
        switch self {
        case .command: "Ran \(count) commands"
        case .read: "Read \(count) files"
        case .write: "Changed \(count) files"
        case .search: "Ran \(count) searches"
        case .web: "Used the web \(count) times"
        case .delegated: "Delegated \(count) tasks"
        case .generic: "Used \(count) tools"
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
    @State private var expanded = true
    @State private var expandedDirectories: Set<String> = []
    @State private var selectedChange: AgentRunFileChange?

    var body: some View {
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
                        Button { toggleAllDirectories() } label: {
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
        }
    }

    private var changes: [AgentRunFileChange] {
        var result: [String: AgentRunFileChange] = [:]
        for change in records.flatMap(\.activity.changes) { result[change.path] = change }
        return result.values.sorted { $0.path < $1.path }
    }
    private var tree: [ConversationChangedFileTreeNode] {
        ConversationChangedFileTreeNode.build(changes)
    }
    private var directoryPaths: Set<String> {
        Set(tree.flatMap(\.allDirectoryPaths))
    }
    private var allDirectoriesExpanded: Bool {
        !directoryPaths.isEmpty && directoryPaths.isSubset(of: expandedDirectories)
    }
    private var visibleRows: [ConversationChangedFileTreeRow] {
        ConversationChangedFileTreeRow.flatten(tree, expanded: expandedDirectories)
    }
    private var additions: Int { changes.reduce(0) { $0 + $1.additions } }
    private var deletions: Int { changes.reduce(0) { $0 + $1.deletions } }

    private func toggleAllDirectories() {
        expandedDirectories = allDirectoriesExpanded ? [] : directoryPaths
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
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

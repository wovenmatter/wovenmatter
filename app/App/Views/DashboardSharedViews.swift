import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

struct DashboardUnavailableUtility: View {
    @Environment(\.dashboardTheme) private var theme
    let icon: DashboardLucideGlyph
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                HStack(spacing: 10) {
                    DashboardLucideIcon(glyph: icon, size: 18)
                        .foregroundStyle(DashboardPalette.primary)
                        .frame(width: 36, height: 36)
                        .background(DashboardPalette.muted)
                        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                            .tracking(-0.3)
                        Text(utilitySubtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 56)
            DashboardConversationEmptyState(icon: icon, title: emptyTitle, detail: detail)
                .frame(maxHeight: .infinity)
        }
        .background(theme.palette.workspace)
    }

    private var emptyTitle: String {
        switch title {
        case "Calendar": "No calendar items yet"
        case "Cron Jobs": "No scheduled jobs"
        default: "No library items yet"
        }
    }

    private var utilitySubtitle: String {
        switch title {
        case "Calendar": "Events, reminders, and scheduled agent work."
        case "Cron Jobs": "Scheduled jobs and cron deliveries across agents."
        default: "Files and images shared across conversations."
        }
    }

}

struct DashboardConversationEmptyState: View {
    let icon: DashboardLucideGlyph
    let title: String
    let detail: String
    var loading = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(DashboardPalette.primary)
                    .frame(width: 56, height: 56)
                    .shadow(color: DashboardPalette.primary.opacity(0.30), radius: 15, y: 8)
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    DashboardLucideIcon(glyph: icon, size: 22)
                        .foregroundStyle(.white)
                }
            }
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DashboardPalette.foreground)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

struct DashboardInlineError: View {
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            DashboardLucideIcon(glyph: .alertCircle, size: 15)
            Text(text).lineLimit(3)
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(DashboardPalette.danger)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DashboardPalette.danger.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
    }
}

struct DashboardRevealRailButton: View {
    enum Side { case left, right }
    let side: Side
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DashboardLucideIcon(
                glyph: side == .left ? .rightCollapse : .leftCollapse,
                size: 18
            )
            .frame(width: 36, height: 36)
        }
        .buttonStyle(DashboardIconButtonStyle())
        .help(side == .left ? "Show agents" : "Show workspace")
    }
}

struct DashboardFolderNamePopover: View {
    let title: String
    let actionTitle: String
    @Binding var name: String
    let onCancel: () -> Void
    let onCommit: () -> Void
    @FocusState private var nameFocused: Bool

    private var canCommit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit {
                    if canCommit { onCommit() }
                }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: onCommit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
            }
        }
        .padding(16)
        .frame(width: 280)
        .task { nameFocused = true }
    }
}

struct DashboardNewArtifactButton: View {
    @Environment(\.dashboardTheme) private var theme
    @State private var hovered = false
    var hoverID = "action:new-note"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DashboardLucideIcon(glyph: .fileText, size: 13)
                    .foregroundStyle(DashboardPalette.foreground)
                    .frame(width: 15, height: 15)
                Text("New note")
                    .lineLimit(1)
                Spacer()
            }
            .font(.system(size: 13))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: DashboardMetrics.rowHeight)
            .background(
                hovered ? theme.palette.themeSoft : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(DashboardRailButtonStyle())
        .dashboardScrollAwareHover($hovered, token: hoverID)
        .accessibilityLabel("Create note or artifact")
    }
}

struct DashboardRailRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    let icon: DashboardLucideGlyph
    var harnessLogo: DashboardHarnessLogo? = nil
    let title: String
    let hoverID: String
    var trailing: String? = nil
    var showsPin = false
    var selected = false
    var isRunningConversation = false
    var iconColor: Color? = nil
    var pinMenuTitle: String? = nil
    var onTogglePin: (() -> Void)? = nil
    var moveUpTitle: String? = nil
    var moveUpEnabled = true
    var onMoveUp: (() -> Void)? = nil
    var moveDownTitle: String? = nil
    var moveDownEnabled = true
    var onMoveDown: (() -> Void)? = nil
    var renameMenuTitle: String? = nil
    var onRename: (() -> Void)? = nil
    var exportMenuTitle: String? = nil
    var onExport: (() -> Void)? = nil
    var destructiveMenuTitle: String? = nil
    var onDelete: (() -> Void)? = nil
    let action: () -> Void

    private var hasContextMenu: Bool {
        onTogglePin != nil || onMoveUp != nil || onMoveDown != nil
            || onRename != nil || onExport != nil || onDelete != nil
    }

    var body: some View {
        let activityPresentation = ConversationActivityPresentation.resolve(
            isRunning: isRunningConversation,
            reduceMotion: reduceMotion
        )
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let harnessLogo {
                        DashboardHarnessLogoIcon(logo: harnessLogo, size: 15)
                    } else {
                        DashboardLucideIcon(glyph: icon, size: 13)
                            .foregroundStyle(iconColor ?? DashboardPalette.foreground)
                    }
                }
                .frame(width: 15, height: 15)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsPin {
                    DashboardLucideIcon(glyph: .pin, size: 11)
                        .foregroundStyle(DashboardPalette.primary)
                        .accessibilityLabel("Pinned")
                }
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: DashboardMetrics.rowHeight)
            .background {
                DashboardActiveConversationRowBackground(
                    presentation: activityPresentation,
                    selected: selected,
                    hovered: hovered,
                    cornerRadius: 8
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(DashboardRailButtonStyle())
        .dashboardScrollAwareHover($hovered, token: hoverID)
        .contextMenu {
            if hasContextMenu {
                if let pinMenuTitle, let onTogglePin {
                    Button(pinMenuTitle, action: onTogglePin)
                }
                if let moveUpTitle, let onMoveUp {
                    Button(action: onMoveUp) {
                        Label {
                            Text(moveUpTitle)
                        } icon: {
                            DashboardLucideIcon(glyph: .arrowUp, size: 12)
                        }
                    }
                    .disabled(!moveUpEnabled)
                }
                if let moveDownTitle, let onMoveDown {
                    Button(action: onMoveDown) {
                        Label {
                            Text(moveDownTitle)
                        } icon: {
                            DashboardLucideIcon(glyph: .arrowDown, size: 12)
                        }
                    }
                    .disabled(!moveDownEnabled)
                }
                if let renameMenuTitle, let onRename {
                    Button(renameMenuTitle, action: onRename)
                }
                if let exportMenuTitle, let onExport {
                    Divider()
                    Button(exportMenuTitle, action: onExport)
                }
                if let destructiveMenuTitle, let onDelete {
                    Divider()
                    Button(destructiveMenuTitle, role: .destructive, action: onDelete)
                }
            }
        }
    }
}

struct DashboardDisclosureHeading: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                DashboardLucideIcon(glyph: .chevronDown, size: 12)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DashboardListSectionHeader: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                DashboardLucideIcon(glyph: .chevronDown, size: 12)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                Spacer()
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DashboardEmptyListRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

struct DashboardConversationRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var hoverCardTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    let presentation: DashboardConversationRowPresentation
    let selected: Bool
    let isRunning: Bool
    @Binding var detailCardState: DashboardConversationDetailCardState
    let folders: [WorkspaceFolderRecord]
    let onMoveConversation: (String, String?) -> Void
    let onUnavailableMutation: (String) -> Void
    let action: () -> Void

    var body: some View {
        let conversation = presentation.conversation
        let activityPresentation = ConversationActivityPresentation.resolve(
            isRunning: isRunning,
            reduceMotion: reduceMotion
        )
        let meta = presentation.meta
        let accessibility = DashboardConversationRowAccessibility.resolve(
            conversation: conversation,
            title: presentation.title,
            meta: meta,
            preview: presentation.preview,
            time: presentation.time
        )

        // AppKit focuses a Button on mouse-down. Keep the popover state stable
        // until this native action receives the matching mouse-up.
        Button {
            action()
            detailCardState.completePrimaryAction(
                conversationID: conversation.id,
                hovered: hovered
            )
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(DashboardPalette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if conversation.unread {
                        Circle()
                            .fill(DashboardPalette.primary)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Unread")
                    }
                    Text(presentation.time)
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .monospacedDigit()
                }
                HStack(spacing: 5) {
                    Group {
                        if let harnessLogo {
                            DashboardHarnessLogoIcon(logo: harnessLogo, size: 13)
                        } else {
                            DashboardLucideIcon(glyph: agentGlyph, size: 12)
                                .foregroundStyle(
                                    DashboardPalette.mutedForeground.opacity(0.95)
                                )
                        }
                    }
                    .frame(width: 13, height: 13)
                    Text(meta.agentLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground.opacity(0.95))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 54)
            .background {
                DashboardActiveConversationRowBackground(
                    presentation: activityPresentation,
                    selected: selected,
                    hovered: hovered,
                    cornerRadius: DashboardMetrics.controlRadius
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(DashboardRailButtonStyle())
        .focused($focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityHint(accessibility.hint)
        .dashboardScrollAwareHover($hovered, token: "conversation:\(conversation.id)")
        .onChange(of: hovered) { _, isHovered in
            hoverCardTask?.cancel()
            if isHovered {
                hoverCardTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(380))
                    guard !Task.isCancelled, hovered, !Self.isMouseButtonPressed else { return }
                    detailCardState.setHovered(true, conversationID: conversation.id)
                }
            } else if !Self.isMouseButtonPressed {
                detailCardState.setHovered(false, conversationID: conversation.id)
            }
        }
        .onChange(of: focused) { _, isFocused in
            guard !Self.isMouseButtonPressed else { return }
            detailCardState.setFocused(isFocused, conversationID: conversation.id)
        }
        .popover(isPresented: detailCardPresented, arrowEdge: .trailing) {
            DashboardConversationHoverCard(presentation: presentation)
        }
        .contextMenu {
            Button(conversation.isPinned ? "Unpin" : "Pin") { onUnavailableMutation("Conversation pinning") }
            Button("Rename") { onUnavailableMutation("Conversation renaming") }
            Menu("Move to Folder") {
                moveTargetRow(title: "Workspace", folderID: nil, conversation: conversation)
                ForEach(folders) { folder in
                    moveTargetRow(title: folder.name, folderID: folder.id, conversation: conversation)
                }
            }
            Divider()
            Button("Export messages") { onUnavailableMutation("Conversation export") }
            Button("Export full run") { onUnavailableMutation("Conversation export") }
            Divider()
            Button("Move to Trash", role: .destructive) { onUnavailableMutation("Conversation trash management") }
        }
        .onDisappear {
            hoverCardTask?.cancel()
            detailCardState.remove(conversationID: conversation.id)
        }
    }

    private var agentGlyph: DashboardLucideGlyph {
        if let agent = presentation.agent {
            return dashboardAgentGlyph(agent)
        }
        return presentation.conversation.localRuntimeKind == nil ? .bot : .terminal
    }

    private static var isMouseButtonPressed: Bool {
        NSEvent.pressedMouseButtons != 0
    }

    private var harnessLogo: DashboardHarnessLogo? {
        if let agent = presentation.agent {
            return DashboardHarnessLogo(runtimeKind: agent.runtimeKind)
        }
        return presentation.conversation.localRuntimeKind.map {
            DashboardHarnessLogo(runtimeKind: $0)
        }
    }

    private var detailCardPresented: Binding<Bool> {
        Binding(
            get: {
                detailCardState.presentedConversationID == presentation.id
            },
            set: { presented in
                if !presented {
                    detailCardState.dismiss()
                }
            }
        )
    }

    private func moveTargetRow(
        title: String,
        folderID: String?,
        conversation: WorkspaceConversationRecord
    ) -> some View {
        let isCurrent = conversation.folderID == folderID
        return Button {
            onMoveConversation(conversation.id, folderID)
        } label: {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .disabled(isCurrent)
    }
}

/// Hover pop-out for a workspace chat row — folder, agent, runtime (not git/device).
struct DashboardConversationHoverCard: View {
    let presentation: DashboardConversationRowPresentation

    var body: some View {
        let meta = presentation.meta
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DashboardPalette.foreground)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                hoverRow(icon: .folder, text: meta.folderLabel)
                hoverRow(icon: .bot, text: meta.agentLabel)
                if let runtime = meta.runtimeLabel {
                    hoverRow(
                        icon: .terminal,
                        harnessLogo: meta.runtimeKind.map {
                            DashboardHarnessLogo(runtimeKind: $0)
                        },
                        text: runtime
                    )
                }
                hoverRow(icon: meta.locationKind.glyph, text: meta.locationLabel)
                if let workspace = meta.buzzWorkspaceLabel {
                    hoverRow(icon: .panelTop, text: workspace)
                }
            }

            if !presentation.preview.isEmpty {
                Divider().opacity(0.35)
                Text(presentation.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(presentation.time)
                .font(.system(size: 10.5))
                .foregroundStyle(DashboardPalette.mutedForeground.opacity(0.9))
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private func hoverRow(
        icon: DashboardLucideGlyph,
        harnessLogo: DashboardHarnessLogo? = nil,
        text: String
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                if let harnessLogo {
                    DashboardHarnessLogoIcon(logo: harnessLogo, size: 14)
                } else {
                    DashboardLucideIcon(glyph: icon, size: 13)
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
            }
            .frame(width: 14, height: 14)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.foreground.opacity(0.92))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

struct DashboardNoteRow: View {
    @Environment(\.dashboardTheme) private var theme
    @State private var hovered = false
    let presentation: DashboardNoteRowPresentation
    let selected: Bool
    let onUnavailableMutation: (String) -> Void
    let action: () -> Void

    var body: some View {
        let note = presentation.note

        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    switch presentation.kind {
                    case .note:
                        DashboardLucideIcon(glyph: .fileText, size: 18)
                    case .spreadsheet:
                        Image(systemName: "tablecells")
                            .font(.system(size: 15, weight: .medium))
                    case .html:
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .foregroundStyle(note.isPinned ? DashboardPalette.primary : DashboardPalette.foreground)
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    Text(presentation.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(
                selected ? theme.palette.themeStrong : hovered ? theme.palette.themeSoft : .clear,
                in: RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(DashboardRailButtonStyle())
        .dashboardScrollAwareHover($hovered, token: "note:\(note.id)")
        .contextMenu {
            Button(note.isPinned ? "Unpin" : "Pin") { onUnavailableMutation("Note pinning") }
            Button("Rename") { onUnavailableMutation("Note renaming") }
            Button("Move to folder…") { onUnavailableMutation("Note moving") }
            Divider()
            Button("Export note") { onUnavailableMutation("Note export") }
            Button("Move to Trash", role: .destructive) { onUnavailableMutation("Note trash management") }
        }
    }
}

struct DashboardRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct DashboardScrollAwareHoverModifier: ViewModifier {
    @Environment(\.dashboardScrollHoverCoordinator) private var coordinator
    @Binding var hovered: Bool
    let token: String

    func body(content: Content) -> some View {
        content
            .onHover { next in
                coordinator.recordHover(next, token: token) { next in
                    if hovered != next {
                        hovered = next
                    }
                }
            }
            .onDisappear {
                coordinator.unregister(token: token)
            }
    }
}

extension View {
    func dashboardScrollAwareHover(_ hovered: Binding<Bool>, token: String) -> some View {
        modifier(DashboardScrollAwareHoverModifier(hovered: hovered, token: token))
    }
}

struct DashboardIconButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                isEnabled
                    ? DashboardPalette.mutedForeground
                    : DashboardPalette.mutedForeground.opacity(0.68)
            )
            .background(
                isEnabled && (configuration.isPressed || hovered)
                    ? theme.palette.themeSoft
                    : .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}

struct DashboardPillButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DashboardPalette.mutedForeground)
            .background(configuration.isPressed ? theme.palette.themeSoft : DashboardPalette.background.opacity(0.7))
            .clipShape(Capsule())
    }
}

func dashboardAgentPresentation(_ agent: WorkspaceAgent) -> DashboardAgentPresentation {
    DashboardAgentPresentation(
        displayName: agent.displayName,
        iconKey: agent.iconKey
    )
}

func dashboardAgentDisplayName(_ agent: WorkspaceAgent) -> String {
    dashboardAgentPresentation(agent).displayName
}

func dashboardComposerPlaceholder(
    agent: WorkspaceAgent?,
    runtimeKind: AgentRuntimeKind?
) -> String {
    let recipient = agent.map(dashboardAgentDisplayName)
        ?? runtimeKind?.displayName
        ?? "agent"
    return "Message \(recipient)…"
}

func dashboardAgentGlyph(
    _ agent: WorkspaceAgent,
    iconKey: String? = nil
) -> DashboardLucideGlyph {
    let key = (iconKey ?? dashboardAgentPresentation(agent).iconKey).lowercased()
    switch key {
    case "monitor": return .monitor
    case "circle-user": return .circleUser
    case "user-round": return .userRound
    case "bot": return .bot
    case "cpu": return .cpu
    case "terminal": return .terminal
    case "briefcase": return .briefcase
    case "compass": return .compass
    case "flame": return .flame
    case "rocket": return .rocket
    case "sparkles": return .sparkles
    case "brain": return .brain
    default:
        if key.contains("terminal") || key.contains("codex") { return .terminal }
        if key.contains("briefcase") { return .briefcase }
        if key.contains("compass") { return .compass }
        if key.contains("flame") { return .flame }
        if key.contains("rocket") { return .rocket }
        if key.contains("spark") { return .sparkles }
        if key.contains("brain") { return .brain }
        if key.contains("user") { return .userRound }
        if key.contains("cpu") || agent.runtimeKind == .pi { return .cpu }
        return agent.executionLocation == .local ? .monitor : .bot
    }
}

func dashboardChatWidthBounds(totalWidth: CGFloat) -> ClosedRange<Double> {
    let contentWidth = max(1, totalWidth - DashboardMetrics.separatorWidth)
    let minimum = max(
        Double(DashboardMetrics.minimumChatWidthPercent),
        Double(DashboardMetrics.chatMinimumWidth / contentWidth * 100)
    )
    let maximum = min(
        Double(DashboardMetrics.maximumChatWidthPercent),
        100 - Double(DashboardMetrics.companionMinimumWidth / contentWidth * 100)
    )
    if minimum > maximum {
        let midpoint = (minimum + maximum) / 2
        return midpoint...midpoint
    }
    return minimum...maximum
}

func dashboardListPreview(_ content: String, limit: Int) -> String {
    guard limit > 0 else { return "" }

    var preview = ""
    preview.reserveCapacity(min(content.utf8.count, limit))
    var characterCount = 0
    var insideTag = false
    var pendingSpace = false

    for character in content {
        if character == "<" {
            insideTag = true
            pendingSpace = true
            continue
        }
        if insideTag {
            if character == ">" {
                insideTag = false
            }
            continue
        }
        if character.isWhitespace {
            pendingSpace = true
            continue
        }
        if pendingSpace, !preview.isEmpty {
            preview.append(" ")
            characterCount += 1
            if characterCount >= limit { break }
        }
        pendingSpace = false
        preview.append(character)
        characterCount += 1
        if characterCount >= limit { break }
    }

    return preview.trimmingCharacters(in: .whitespacesAndNewlines)
}

func dashboardShortTime(_ value: String?) -> String {
    guard let value, let date = dashboardParsedDate(value) else { return "" }
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
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

func dashboardParsedDate(_ value: String) -> Date? {
    (try? dashboardFractionalDateStyle.parse(value))
        ?? (try? dashboardDateStyle.parse(value))
}

let dashboardFractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
let dashboardDateStyle = Date.ISO8601FormatStyle()

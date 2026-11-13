import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct ConversationEmptyState: View {
    let icon: LucideGlyph
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(WovenPalette.primaryFill)
                    .frame(width: 56, height: 56)
                    .shadow(color: WovenPalette.primaryFill.opacity(0.30), radius: 15, y: 8)
                LucideIcon(glyph: icon, size: 22)
                    .foregroundStyle(WovenPalette.primaryForeground)
            }
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WovenPalette.foreground)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            if let detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

struct InlineError: View {
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            LucideIcon(glyph: .alertCircle, size: 15)
            Text(text).lineLimit(3)
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(WovenPalette.danger)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(WovenPalette.danger.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    }
}

struct RevealRailButton: View {
    enum Side { case left, right }
    let side: Side
    var width: CGFloat = 36
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon(
                glyph: side == .left ? .rightCollapse : .leftCollapse,
                size: 18
            )
            .frame(width: width, height: height)
        }
        .buttonStyle(WovenIconButtonStyle())
        .help(side == .left ? "Show agents" : "Show workspace")
    }
}

/// Observe clicks in this form's native window without consuming control events.
/// Native text fields do not reliably deliver their surrounding SwiftUI tap gesture.
private struct FormFocusDismissalMonitor: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(view: view, onDismiss: onDismiss)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(view: view, onDismiss: onDismiss)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private var eventMonitor: Any?
        private var onDismiss: () -> Void = {}

        func update(view: NSView, onDismiss: @escaping () -> Void) {
            self.view = view
            self.onDismiss = onDismiss
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] event in
                guard let self, let view = self.view, let window = view.window else { return event }
                guard event.window === window,
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return event }
                let field = (editor.delegate as? NSView) ?? editor
                let fieldPoint = field.convert(event.locationInWindow, from: nil)
                guard !field.bounds.contains(fieldPoint) else { return event }
                self.onDismiss()
                window.endEditing(for: nil)
                window.makeFirstResponder(nil)
                return event
            }
        }

        func stop() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}

private struct QuietTextInputModifier: ViewModifier {
    @Environment(\.wovenTheme) private var theme
    let font: Font

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(WovenPalette.foreground)
            .focusEffectDisabled()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.palette.input, in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WovenMetrics.controlRadius)
                    .stroke(theme.palette.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func formFocusDismissal(_ onDismiss: @escaping () -> Void) -> some View {
        background {
            FormFocusDismissalMonitor(onDismiss: onDismiss)
                .allowsHitTesting(false)
        }
    }

    func quietTextInput(font: Font = .system(size: 13)) -> some View {
        modifier(QuietTextInputModifier(font: font))
    }
}

struct FolderNamePopover: View {
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
                .focused($nameFocused)
                .quietTextInput()
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
        .formFocusDismissal { nameFocused = false }
        .task { nameFocused = true }
    }
}

struct NewArtifactButton: View {
    @Environment(\.wovenTheme) private var theme
    @State private var hovered = false
    var hoverID = "action:new-note"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                LucideIcon(glyph: .fileText, size: 13)
                    .foregroundStyle(WovenPalette.foreground)
                    .frame(width: 15, height: 15)
                Text("New note")
                    .lineLimit(1)
                Spacer()
            }
            .font(.system(size: 13))
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: WovenMetrics.rowHeight)
            .background(
                hovered ? theme.palette.themeSoft : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(RailButtonStyle())
        .scrollAwareHover($hovered, token: hoverID)
        .accessibilityLabel("Create note or artifact")
    }
}

struct RailRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var folderHoverTask: Task<Void, Never>?
    let icon: LucideGlyph
    var harnessLogo: HarnessLogo? = nil
    let title: String
    let hoverID: String
    var trailing: String? = nil
    var showsPin = false
    var selected = false
    var isRunningConversation = false
    var conversationID: String? = nil
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
    var referenceMenuTitle: String? = nil
    var onManageReferences: (() -> Void)? = nil
    var destructiveMenuTitle: String? = nil
    var onDelete: (() -> Void)? = nil
    var folderDetails: FolderHoverDetails? = nil
    var presentedFolderID: Binding<String?> = .constant(nil)
    let action: () -> Void

    private var hasContextMenu: Bool {
        onTogglePin != nil || onMoveUp != nil || onMoveDown != nil
            || onRename != nil || onExport != nil || onManageReferences != nil || onDelete != nil
    }

    var body: some View {
        let activityPresentation = ConversationActivityPresentation.resolve(
            isRunning: isRunningConversation,
            reduceMotion: reduceMotion
        )
        Button {
            dismissFolderDetails()
            action()
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let harnessLogo {
                        HarnessLogoIcon(logo: harnessLogo, size: 15)
                    } else {
                        LucideIcon(glyph: icon, size: 13)
                            .foregroundStyle(iconColor ?? WovenPalette.foreground)
                    }
                }
                .frame(width: 15, height: 15)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let conversationID { WorkspaceSessionIndicators(sessionID: conversationID) }
                if showsPin {
                    LucideIcon(glyph: .pin, size: 11)
                        .foregroundStyle(WovenPalette.foreground)
                        .accessibilityLabel("Pinned")
                }
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(WovenPalette.foreground)
                }
            }
            .font(.system(size: 13, weight: selected ? .medium : .regular))
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: WovenMetrics.rowHeight)
            .background {
                ActiveConversationRowBackground(
                    presentation: activityPresentation,
                    selected: selected,
                    hovered: hovered,
                    cornerRadius: 8
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(RailButtonStyle())
        .scrollAwareHover($hovered, token: hoverID)
        .accessibilityValue(folderDetails?.accessibilityValue ?? "")
        .onChange(of: hovered) { _, isHovered in
            folderHoverTask?.cancel()
            if isHovered, let folderDetails {
                folderHoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, hovered, NSEvent.pressedMouseButtons == 0 else { return }
                    presentedFolderID.wrappedValue = folderDetails.folder.id
                }
            } else {
                dismissFolderDetails()
            }
        }
        .background {
            if let folderDetails {
                ConversationPopover(isPresented: Binding(
                    get: { presentedFolderID.wrappedValue == folderDetails.folder.id },
                    set: { if !$0 { dismissFolderDetails() } }
                )) {
                    FolderHoverCard(details: folderDetails)
                }
            }
        }
        .onDisappear { dismissFolderDetails() }
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
                            LucideIcon(glyph: .arrowUp, size: 12)
                        }
                    }
                    .disabled(!moveUpEnabled)
                }
                if let moveDownTitle, let onMoveDown {
                    Button(action: onMoveDown) {
                        Label {
                            Text(moveDownTitle)
                        } icon: {
                            LucideIcon(glyph: .arrowDown, size: 12)
                        }
                    }
                    .disabled(!moveDownEnabled)
                }
                if let renameMenuTitle, let onRename {
                    Button(renameMenuTitle, action: onRename)
                }
                if let referenceMenuTitle, let onManageReferences {
                    Button(referenceMenuTitle, action: onManageReferences)
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
    private func dismissFolderDetails() {
        folderHoverTask?.cancel()
        folderHoverTask = nil
        if let folderDetails, presentedFolderID.wrappedValue == folderDetails.folder.id {
            presentedFolderID.wrappedValue = nil
        }
    }
}

struct DisclosureHeading: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                LucideIcon(glyph: .chevronDown, size: 12)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ListSectionHeader: View {
    let title: String
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                LucideIcon(glyph: .chevronDown, size: 12)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                Spacer()
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct EmptyListRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(WovenPalette.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }
}

struct ConversationRow: View {
    @Environment(\.workspaceApplicationModel) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var hoverCardTask: Task<Void, Never>?
    let presentation: ConversationRowPresentation
    let selected: Bool
    let isRunning: Bool
    @Binding var detailCardState: ConversationDetailCardState
    let folders: [WorkspaceFolderRecord]
    let onConversationAction: (WorkspaceConversationRecord, ConversationMenuAction) -> Void
    let action: () -> Void

    var body: some View {
        let conversation = presentation.conversation
        let activityPresentation = ConversationActivityPresentation.resolve(
            isRunning: isRunning,
            reduceMotion: reduceMotion
        )
        let meta = presentation.meta
        let accessibility = ConversationRowAccessibility.resolve(
            conversation: conversation,
            title: presentation.title,
            meta: meta,
            preview: presentation.preview,
            time: presentation.time
        )

        Button {
            // Opening a chat must not present or pin its hover preview. A fresh
            // hover entry is required before the usual delay can start again.
            hoverCardTask?.cancel()
            hoverCardTask = nil
            detailCardState.completePrimaryAction()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(WovenPalette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    WorkspaceSessionIndicators(sessionID: conversation.id)
                    if conversation.unread {
                        Circle()
                            .fill(WovenPalette.foreground)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel("Unread")
                    }
                    Text(presentation.time)
                        .font(.system(size: 11))
                        .foregroundStyle(WovenPalette.foreground)
                        .monospacedDigit()
                }
                HStack(spacing: 5) {
                    Group {
                        if let harnessLogo {
                            HarnessLogoIcon(logo: harnessLogo, size: 13)
                        } else {
                            LucideIcon(glyph: agentGlyph, size: 12)
                                .foregroundStyle(
                                    WovenPalette.foreground
                                )
                        }
                    }
                    .frame(width: 13, height: 13)
                    Text(meta.agentLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(WovenPalette.foreground)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 54)
            .background {
                ActiveConversationRowBackground(
                    presentation: activityPresentation,
                    selected: selected,
                    hovered: hovered,
                    cornerRadius: WovenMetrics.controlRadius
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(RailButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value
            + (appModel?.agentTools?.relationships[conversation.id]?.coordinatorID != nil ? ", actively coordinated" : "")
            + (appModel?.agentTools?.timers.contains(where: { $0.sessionID == conversation.id && !$0.isPaused }) == true ? ", active timer" : ""))
        .accessibilityHint(accessibility.hint)
        .scrollAwareHover($hovered, token: "conversation:\(conversation.id)")
        .onChange(of: hovered) { _, isHovered in
            hoverCardTask?.cancel()
            hoverCardTask = nil
            if isHovered {
                hoverCardTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, hovered, !Self.isMouseButtonPressed else { return }
                    detailCardState.setHovered(true, conversationID: conversation.id)
                }
            } else {
                detailCardState.setHovered(false, conversationID: conversation.id)
            }
        }
        .background {
            ConversationPopover(isPresented: detailCardPresented) {
                ConversationHoverCard(presentation: presentation)
            }
        }
        .modifier(ConversationContextMenu(
            conversation: conversation,
            folders: folders,
            isRunning: isRunning,
            onAction: onConversationAction
        ))
        .onDisappear {
            hoverCardTask?.cancel()
            detailCardState.remove(conversationID: conversation.id)
        }
    }

    private var agentGlyph: LucideGlyph {
        if let agent = presentation.agent {
            return agentIconGlyph(agent)
        }
        return presentation.conversation.localRuntimeKind == nil ? .bot : .terminal
    }

    private static var isMouseButtonPressed: Bool {
        NSEvent.pressedMouseButtons != 0
    }

    private var harnessLogo: HarnessLogo? {
        if let agent = presentation.agent {
            return HarnessLogo(runtimeKind: agent.runtimeKind)
        }
        return presentation.conversation.localRuntimeKind.map {
            HarnessLogo(runtimeKind: $0)
        }
    }

    private var detailCardPresented: Binding<Bool> {
        Binding(
            get: {
                detailCardState.presentedConversationID == presentation.id
            },
            set: { presented in
                if !presented, detailCardState.presentedConversationID == presentation.id {
                    detailCardState.dismiss()
                }
            }
        )
    }
}

/// Hover pop-out for a workspace chat row.
struct ConversationHoverCard: View {
    let presentation: ConversationRowPresentation

    var body: some View {
        let meta = presentation.meta
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WovenPalette.foreground)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                hoverRow(icon: .folder, text: meta.folderLabel)
                if let agent = presentation.agent, agent.runtimeKind == .opencode {
                    hoverRow(icon: .bot, text: agentDisplayName(agent))
                }
                if let runtime = meta.runtimeLabel {
                    hoverRow(
                        icon: .terminal,
                        harnessLogo: meta.runtimeKind.map {
                            HarnessLogo(runtimeKind: $0)
                        },
                        text: runtime + (presentation.conversation.importedAt == nil ? "" : " (imported)")
                    )
                }
                hoverRow(icon: meta.locationKind.glyph, text: meta.locationLabel)
                if presentation.conversation.isScheduledTask {
                    Text("Scheduled Task")
                        .font(.system(size: 12))
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
            }

            WorkspaceSessionProvenance(sessionID: presentation.id)

            if !presentation.preview.isEmpty {
                Divider().opacity(0.35)
                Text(presentation.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(presentation.time)
                .font(.system(size: 10.5))
                .foregroundStyle(WovenPalette.mutedForeground.opacity(0.9))
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private func hoverRow(
        icon: LucideGlyph,
        harnessLogo: HarnessLogo? = nil,
        text: String
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                if let harnessLogo {
                    HarnessLogoIcon(logo: harnessLogo, size: 14)
                } else {
                    LucideIcon(glyph: icon, size: 13)
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
            }
            .frame(width: 14, height: 14)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(WovenPalette.foreground.opacity(0.92))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

struct NoteRow: View {
    @Environment(\.wovenTheme) private var theme
    @State private var hovered = false
    let presentation: NoteRowPresentation
    let selected: Bool
    let folders: [WorkspaceFolderRecord]
    let onNoteAction: (WorkspaceNoteRecord, NoteMenuAction) -> Void
    let action: () -> Void

    var body: some View {
        let note = presentation.note

        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    switch presentation.kind {
                    case .note:
                        LucideIcon(glyph: .fileText, size: 18)
                    case .spreadsheet:
                        Image(systemName: "tablecells")
                            .font(.system(size: 15, weight: .medium))
                    case .html:
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .foregroundStyle(WovenPalette.foreground)
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                    Text(presentation.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(WovenPalette.foreground)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(
                selected ? theme.palette.themeStrong : hovered ? theme.palette.themeSoft : .clear,
                in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(RailButtonStyle())
        .scrollAwareHover($hovered, token: "note:\(note.id)")
        .modifier(NoteContextMenu(note: note, folders: folders, onAction: onNoteAction))
    }
}

struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct ScrollAwareHoverModifier: ViewModifier {
    @Environment(\.scrollHoverCoordinator) private var coordinator
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
    func scrollAwareHover(_ hovered: Binding<Bool>, token: String) -> some View {
        modifier(ScrollAwareHoverModifier(hovered: hovered, token: token))
    }
}

struct PillButtonStyle: ButtonStyle {
    @Environment(\.wovenTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(WovenPalette.mutedForeground)
            .background(
                configuration.isPressed
                    ? theme.palette.themeSoft
                    : isEnabled && isHovering
                        ? theme.palette.themeWhisper
                        : WovenPalette.background.opacity(reduceTransparency ? 1 : 0.7)
            )
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

func agentPresentation(_ agent: WorkspaceAgent) -> AgentPresentation {
    AgentPresentation(
        displayName: agent.runtimeKind == .defaultAgent ? agent.runtimeKind.displayName : agent.displayName,
        iconKey: agent.iconKey
    )
}

func agentDisplayName(_ agent: WorkspaceAgent) -> String {
    agentPresentation(agent).displayName
}

func composerPlaceholder(
    agent: WorkspaceAgent?,
    runtimeKind: AgentRuntimeKind?
) -> String {
    let recipient = agent.map(agentDisplayName)
        ?? runtimeKind?.displayName
        ?? "agent"
    return "Message \(recipient)…"
}

func agentIconGlyph(_ agent: WorkspaceAgent) -> LucideGlyph {
    let key = agentPresentation(agent).iconKey.lowercased()
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
        if key.contains("cpu") { return .cpu }
        return agent.executionLocation == .local ? .monitor : .bot
    }
}

func chatWidthBounds(totalWidth: CGFloat) -> ClosedRange<Double> {
    let contentWidth = max(1, totalWidth - WovenMetrics.separatorWidth)
    let minimum = max(
        Double(WovenMetrics.minimumChatWidthPercent),
        Double(WovenMetrics.chatMinimumWidth / contentWidth * 100)
    )
    let maximum = min(
        Double(WovenMetrics.maximumChatWidthPercent),
        100 - Double(WovenMetrics.assetPaneMinimumWidth / contentWidth * 100)
    )
    if minimum > maximum {
        let midpoint = (minimum + maximum) / 2
        return midpoint...midpoint
    }
    return minimum...maximum
}

func listPreview(_ content: String, limit: Int) -> String {
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

func shortTime(_ value: String?) -> String {
    guard let value, let date = parsedISODate(value) else { return "" }
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
}


func parsedISODate(_ value: String) -> Date? {
    (try? fractionalISODateStyle.parse(value))
        ?? (try? isoDateStyle.parse(value))
}

let fractionalISODateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
let isoDateStyle = Date.ISO8601FormatStyle()

struct FolderContentCounts: Equatable {
    var chats = 0
    var notes = 0
    var total: Int { chats + notes }
    var summary: String {
        "\(chats) \(chats == 1 ? "chat" : "chats") · \(notes) \(notes == 1 ? "note" : "notes")"
    }
}

struct FolderHoverDetails {
    let folder: WorkspaceFolderRecord
    let workspaceTitle: String
    let counts: FolderContentCounts

    var accessibilityValue: String {
        ([workspaceTitle, counts.summary, "Root folder: " + (folder.rootPath ?? "Not linked")]
            + folder.referencePaths.map { "Additional folder: " + $0 }).joined(separator: ", ")
    }
}

struct FolderHoverCard: View {
    let details: FolderHoverDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(details.folder.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                LucideIcon(glyph: .panelsTopLeft, size: 13)
                    .foregroundStyle(WovenPalette.mutedForeground)
                Text(details.workspaceTitle).font(.system(size: 12.5))
            }
            Text(details.counts.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(WovenPalette.mutedForeground)
            Divider().opacity(0.35)
            ViewThatFits(in: .vertical) {
                paths
                ScrollView { paths }
                    .scrollIndicators(.never)
            }
            .frame(maxHeight: 280, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(WovenPalette.foreground)
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Root folder").font(.system(size: 11.5, weight: .medium))
            path(details.folder.rootPath ?? "Not linked")
            if !details.folder.referencePaths.isEmpty {
                Text(details.folder.referencePaths.count == 1 ? "Additional folder" : "Additional folders")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.top, 3)
                ForEach(Array(details.folder.referencePaths.enumerated()), id: \.offset) { _, reference in
                    path(reference)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func path(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12.5))
            .foregroundStyle(WovenPalette.foreground.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

struct DashboardPanelControlButton: View {
    let glyph: DashboardLucideGlyph
    let accessibilityLabel: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DashboardLucideIcon(glyph: glyph, size: 18)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(DashboardIconButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }
}

struct DashboardComposer: View {
    let placeholder: String
    @Binding var draft: String
    let attachedNoteTitle: String?
    let attachments: [AgentMessageAttachmentDraft]
    let showsSessionControls: Bool
    let sessionMetadata: LocalACPSessionMetadata?
    let sessionControlsDisabled: Bool
    let sendDisabled: Bool
    let startsCollapsed: Bool
    let focusRequestGeneration: Int?
    let onActivate: () -> Void
    let onSelectModel: ((String) -> Void)?
    let onSelectThinking: ((String) -> Void)?
    let onAttachmentAction: (DashboardComposerAttachmentAction) -> Void
    let onRemoveAttachment: (String) -> Void
    let onDropFiles: ([URL]) -> Bool
    let onUnavailableAction: (String) -> Void
    let onCommandNavigation: (DashboardComposerNavigationDirection) -> Bool
    let onSend: () -> Void
    @State private var focused = false
    @State private var openMenu: DashboardComposerMenuKind?
    @State private var isDropTarget = false
    @State private var collapseOverride: Bool?
    @State private var permitsNarrowExpandedControls = false

    private var isCollapsed: Bool {
        collapseOverride ?? startsCollapsed
    }

    var body: some View {
        VStack(spacing: 6) {
            if let attachedNoteTitle {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(attachedNoteTitle)
                        .lineLimit(1)
                    Text("available to agent")
                        .foregroundStyle(DashboardPalette.mutedForeground)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DashboardPalette.foreground)
                .accessibilityLabel("Open note \(attachedNoteTitle) is available to the agent")
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(attachments) { attachment in
                            DashboardDraftAttachmentChip(
                                attachment: attachment,
                                onRemove: { onRemoveAttachment(attachment.id) }
                            )
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isCollapsed {
                HStack(alignment: .bottom, spacing: 2) {
                    composerTextEditor(maximumVisibleLines: 3)
                    collapsedControls
                }
            } else {
                composerTextEditor(maximumVisibleLines: 7)
            }

            if !matchingSlashCommands.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matchingSlashCommands.prefix(8)) { command in
                        Button {
                            applySlashCommand(command)
                        } label: {
                            HStack(spacing: 8) {
                                Text("/\(command.name)")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(DashboardPalette.foreground)
                                if let detail = command.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(DashboardPalette.mutedForeground)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(DashboardPalette.background.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DashboardPalette.foreground.opacity(0.08), lineWidth: 1)
                }
            }

            if !isCollapsed {
                ViewThatFits(in: .horizontal) {
                    regularControls
                        .onAppear {
                            permitsNarrowExpandedControls = false
                        }
                    compactControls
                        .onAppear {
                            if permitsNarrowExpandedControls {
                                permitsNarrowExpandedControls = false
                            } else {
                                collapseOverride = true
                            }
                        }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(
                cornerRadius: DashboardMetrics.composerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: DashboardMetrics.composerRadius, style: .continuous)
                .stroke(
                    isDropTarget
                        ? DashboardPalette.primary
                        : DashboardPalette.foreground.opacity(0.06),
                    lineWidth: isDropTarget ? 2 : 1
                )
        }
        .shadow(
            color: focused ? DashboardPalette.primary.opacity(0.18) : DashboardPalette.foreground.opacity(0.04),
            radius: focused ? 14 : 2,
            y: focused ? 8 : 1
        )
        .background {
            RoundedRectangle(cornerRadius: DashboardMetrics.composerRadius, style: .continuous)
                .fill(.clear)
                .contentShape(
                    RoundedRectangle(cornerRadius: DashboardMetrics.composerRadius, style: .continuous)
                )
                .onTapGesture {
                    openMenu = nil
                    focused = true
                }
        }
        .background {
            DashboardComposerClickAwayMonitor(isActive: focused || openMenu != nil) {
                focused = false
                openMenu = nil
            }
            .allowsHitTesting(false)
        }
        .onExitCommand {
            focused = false
            openMenu = nil
        }
        .dropDestination(for: URL.self) { urls, _ in
            onActivate()
            return onDropFiles(urls)
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .onChange(of: focusRequestGeneration) { _, generation in
            guard generation != nil else { return }
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                onActivate()
            }
        }
        .onAppear {
            if focusRequestGeneration != nil {
                focused = true
            }
        }
        .animation(.easeOut(duration: 0.15), value: openMenu)
        .animation(.easeOut(duration: 0.15), value: isCollapsed)
    }

    private func composerTextEditor(maximumVisibleLines: Int) -> some View {
        DashboardComposerTextEditor(
            text: $draft,
            isFocused: $focused,
            placeholder: placeholder,
            maximumVisibleLines: maximumVisibleLines,
            onSubmit: {
                if applyFirstSlashCommandIfNeeded() { return }
                if canSend { onSend() }
            },
            onTab: applyFirstSlashCommandIfNeeded,
            onCommandNavigation: onCommandNavigation
        )
        .frame(
            minHeight: isCollapsed ? 36 : 32,
            alignment: .topLeading
        )
        .simultaneousGesture(TapGesture().onEnded { openMenu = nil })
    }

    private var canSend: Bool {
        !sendDisabled
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    private var slashQuery: String? {
        let line = draft.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).last.map(String.init) ?? draft
        guard line.hasPrefix("/"), !line.contains(" ") else { return nil }
        return String(line.dropFirst())
    }

    private var matchingSlashCommands: [LocalACPSlashCommand] {
        guard let query = slashQuery,
              let commands = sessionMetadata?.slashCommands,
              !commands.isEmpty else {
            return []
        }
        let needle = query.lowercased()
        return commands.filter { command in
            needle.isEmpty || command.name.lowercased().hasPrefix(needle)
        }
    }

    private func applyFirstSlashCommandIfNeeded() -> Bool {
        guard let command = matchingSlashCommands.first else { return false }
        applySlashCommand(command)
        return true
    }

    private func applySlashCommand(_ command: LocalACPSlashCommand) {
        let lines = draft.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var next = lines
        if next.isEmpty {
            next = ["/\(command.name) "]
        } else {
            next[next.count - 1] = "/\(command.name) "
        }
        draft = next.joined(separator: "\n")
        openMenu = nil
    }

    private func composerIconButton(
        icon: DashboardLucideGlyph,
        accessibilityLabel: String,
        menu: DashboardComposerMenuKind
    ) -> some View {
        Button {
            onActivate()
            focused = false
            openMenu = openMenu == menu ? nil : menu
        } label: {
            DashboardLucideIcon(glyph: icon, size: 16)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(openMenu == menu ? "Expanded" : "Collapsed")
        .help(accessibilityLabel)
    }

    private var regularControls: some View {
        HStack(spacing: 4) {
            attachmentControl

            if showsSessionControls {
                sessionMenu(
                    kind: .model,
                    icon: .cpu,
                    title: sessionMetadata?.model ?? "Model",
                    menuTitle: "Model",
                    accessibilityLabel: "Choose session model",
                    options: sessionMetadata?.selectableModels ?? [],
                    selection: sessionMetadata?.model,
                    action: onSelectModel
                )
                sessionMenu(
                    kind: .thinking,
                    icon: .brain,
                    title: sessionMetadata?.thinking.map(dashboardSessionThinkingLabel) ?? "Thinking",
                    menuTitle: "Thinking",
                    accessibilityLabel: "Choose thinking level",
                    options: sessionMetadata?.selectableThinkingLevels ?? [],
                    selection: sessionMetadata?.thinking,
                    capitalizeOptions: true,
                    action: onSelectThinking
                )
            }

            Spacer(minLength: 8)
            collapseControl
            voiceControl
            sendControl
        }
    }

    private var compactControls: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                attachmentControl
                if showsSessionControls {
                    compactSessionMenu(
                        kind: .model,
                        icon: .cpu,
                        title: sessionMetadata?.model ?? "Model",
                        menuTitle: "Model",
                        accessibilityLabel: "Choose session model",
                        options: sessionMetadata?.selectableModels ?? [],
                        selection: sessionMetadata?.model,
                        action: onSelectModel
                    )
                    compactSessionMenu(
                        kind: .thinking,
                        icon: .brain,
                        title: sessionMetadata?.thinking.map(dashboardSessionThinkingLabel) ?? "Thinking",
                        menuTitle: "Thinking",
                        accessibilityLabel: "Choose thinking level",
                        options: sessionMetadata?.selectableThinkingLevels ?? [],
                        selection: sessionMetadata?.thinking,
                        capitalizeOptions: true,
                        action: onSelectThinking
                    )
                }
            }

            HStack(spacing: 4) {
                collapseControl
                voiceControl
                sendControl
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var collapsedControls: some View {
        HStack(spacing: 4) {
            collapseControl
            voiceControl
            sendControl
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var collapseControl: some View {
        Button {
            onActivate()
            openMenu = nil
            if isCollapsed {
                permitsNarrowExpandedControls = true
                collapseOverride = false
            } else {
                permitsNarrowExpandedControls = false
                collapseOverride = true
            }
        } label: {
            DashboardLucideIcon(glyph: .chevronDown, size: 18)
                .rotationEffect(.degrees(isCollapsed ? 0 : 180))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle())
        .accessibilityLabel(isCollapsed ? "Expand composer" : "Collapse composer")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .help(isCollapsed ? "Expand composer" : "Collapse composer")
    }

    private var attachmentControl: some View {
        composerIconButton(
            icon: .plus,
            accessibilityLabel: "Add files or photos",
            menu: .attachments
        )
        .overlay(alignment: .bottomLeading) {
            if openMenu == .attachments {
                DashboardComposerAttachmentMenu { action in
                    openMenu = nil
                    onAttachmentAction(action)
                }
                .offset(y: -44)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .zIndex(openMenu == .attachments ? 3 : 0)
    }

    private var voiceControl: some View {
        Button {
            onActivate()
            openMenu = nil
            focused = false
            onUnavailableAction("Voice input")
        } label: {
            DashboardLucideIcon(glyph: .mic, size: 16)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle())
        .accessibilityLabel("Voice input unavailable")
        .help("Dictation unavailable")
    }

    private var sendControl: some View {
        Button {
            onActivate()
            onSend()
        } label: {
            DashboardLucideIcon(glyph: .arrowUp, size: 16)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(DashboardPalette.primary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.4)
        .accessibilityLabel("Send")
    }

    private func compactSessionMenu(
        kind: DashboardComposerMenuKind,
        icon: DashboardLucideGlyph,
        title: String,
        menuTitle: String,
        accessibilityLabel: String,
        options: [String],
        selection: String?,
        capitalizeOptions: Bool = false,
        action: ((String) -> Void)?
    ) -> some View {
        let unavailable = sessionControlsDisabled || options.count < 2 || action == nil
        return Button {
            guard !unavailable else { return }
            onActivate()
            focused = false
            openMenu = openMenu == kind ? nil : kind
        } label: {
            DashboardLucideIcon(glyph: icon, size: 16)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(DashboardComposerControlButtonStyle())
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(title), \(openMenu == kind ? "Expanded" : "Collapsed")")
        .help(accessibilityLabel)
        .overlay(alignment: .bottomLeading) {
            if openMenu == kind {
                DashboardComposerOptionMenu(
                    title: menuTitle,
                    options: options,
                    selection: selection,
                    capitalizeOptions: capitalizeOptions
                ) { option in
                    openMenu = nil
                    action?(option)
                }
                .offset(y: -44)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .zIndex(openMenu == kind ? 3 : 0)
    }

    private func sessionMenu(
        kind: DashboardComposerMenuKind,
        icon: DashboardLucideGlyph,
        title: String,
        menuTitle: String,
        accessibilityLabel: String,
        options: [String],
        selection: String?,
        capitalizeOptions: Bool = false,
        action: ((String) -> Void)?
    ) -> some View {
        let unavailable = sessionControlsDisabled || options.count < 2 || action == nil
        return Button {
            guard !unavailable else { return }
            onActivate()
            focused = false
            openMenu = openMenu == kind ? nil : kind
        } label: {
            DashboardComposerSessionLabel(icon: icon, title: title)
        }
        .buttonStyle(DashboardComposerControlButtonStyle())
        .disabled(unavailable)
        .opacity(unavailable ? 0.4 : 1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(title), \(openMenu == kind ? "Expanded" : "Collapsed")")
        .help(accessibilityLabel)
        .overlay(alignment: .bottomLeading) {
            if openMenu == kind {
                DashboardComposerOptionMenu(
                    title: menuTitle,
                    options: options,
                    selection: selection,
                    capitalizeOptions: capitalizeOptions
                ) { option in
                    openMenu = nil
                    action?(option)
                }
                .offset(y: -44)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
            }
        }
        .zIndex(openMenu == kind ? 3 : 0)
    }
}

struct DashboardComposerClickAwayMonitor: NSViewRepresentable {
    let isActive: Bool
    let onClickAway: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.update(view: view, isActive: isActive, onClickAway: onClickAway)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(view: nsView, isActive: isActive, onClickAway: onClickAway)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private var eventMonitor: Any?
        private var onClickAway: () -> Void = {}

        func update(view: NSView, isActive: Bool, onClickAway: @escaping () -> Void) {
            self.view = view
            self.onClickAway = onClickAway

            if isActive, eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                    [weak self] event in
                    guard let self,
                          let view = self.view,
                          event.window === view.window
                    else { return event }

                    let point = view.convert(event.locationInWindow, from: nil)
                    guard !view.bounds.contains(point) else { return event }

                    DispatchQueue.main.async { [weak self] in
                        self?.onClickAway()
                    }
                    return event
                }
            } else if !isActive {
                stop()
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

enum DashboardComposerMenuKind {
    case attachments
    case model
    case thinking
}

enum DashboardComposerAttachmentAction {
    case upload
    case note
    case conversation
}

enum DashboardAttachmentPickerKind: String, Identifiable {
    case note
    case conversation

    var id: String { rawValue }
}

struct DashboardDraftAttachmentChip: View {
    let attachment: AgentMessageAttachmentDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            preview
            Text(attachment.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(DashboardPalette.foreground.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private var preview: some View {
        switch attachment {
        case .file(let file):
            if file.kind == .image, let image = NSImage(contentsOf: file.localURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 25, height: 25)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(DashboardPalette.primary)
                    .frame(width: 25, height: 25)
            }
        case .reference(let reference):
            Image(systemName: reference.kind == .note ? "note.text" : "bubble.left.and.bubble.right")
                .foregroundStyle(DashboardPalette.primary)
                .frame(width: 25, height: 25)
        }
    }
}

struct DashboardComposerSessionLabel: View {
    let icon: DashboardLucideGlyph
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            DashboardLucideIcon(glyph: icon, size: 14)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            DashboardLucideIcon(glyph: .chevronDown, size: 14)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 36)
        .contentShape(Capsule())
    }
}

struct DashboardComposerControlButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                hovered ? DashboardPalette.primary : DashboardPalette.mutedForeground
            )
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

struct DashboardComposerAttachmentMenu: View {
    let onSelect: (DashboardComposerAttachmentAction) -> Void

    var body: some View {
        VStack(spacing: 2) {
            menuRow(icon: .upload, title: "Upload photos or files", action: .upload)
            menuRow(icon: .fileText, title: "Attach note", action: .note)
            menuRow(icon: .messageSquare, title: "Attach conversation", action: .conversation)
        }
        .padding(8)
        .frame(width: 224)
        .dashboardComposerPopover()
    }

    private func menuRow(
        icon: DashboardLucideGlyph,
        title: String,
        action: DashboardComposerAttachmentAction
    ) -> some View {
        DashboardComposerPopoverRow(action: { onSelect(action) }) {
            HStack(spacing: 12) {
                DashboardLucideIcon(glyph: icon, size: 16)
                    .foregroundStyle(DashboardPalette.primary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
    }
}

struct DashboardAttachmentPicker: View {
    @Environment(\.dismiss) private var dismiss
    let kind: DashboardAttachmentPickerKind
    let notes: [WorkspaceNoteRecord]
    let conversations: [WorkspaceConversationRecord]
    let onSelectNote: (WorkspaceNoteRecord) -> Void
    let onSelectConversation: (WorkspaceConversationRecord) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if kind == .note {
                    ForEach(filteredNotes) { note in
                        Button { onSelectNote(note) } label: {
                            pickerRow(
                                icon: "note.text",
                                title: note.title,
                                detail: note.content
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(filteredConversations) { conversation in
                        Button { onSelectConversation(conversation) } label: {
                            pickerRow(
                                icon: "bubble.left.and.bubble.right",
                                title: conversation.title,
                                detail: conversation.agentCodename ?? "Conversation"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: kind == .note ? "Search notes" : "Search conversations")
            .navigationTitle(kind == .note ? "Attach note" : "Attach conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }

    private var filteredNotes: [WorkspaceNoteRecord] {
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.content.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredConversations: [WorkspaceConversationRecord] {
        guard !query.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.agentCodename?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func pickerRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(DashboardPalette.primary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.foreground)
                Text(detail.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

struct DashboardComposerOptionMenu: View {
    let title: String
    let options: [String]
    let selection: String?
    let capitalizeOptions: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(DashboardPalette.mutedForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(options, id: \.self) { option in
                        DashboardComposerPopoverRow(action: { onSelect(option) }) {
                            HStack(spacing: 12) {
                                Text(optionLabel(option))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if option == selection {
                                    DashboardLucideIcon(glyph: .check, size: 14)
                                        .foregroundStyle(DashboardPalette.primary)
                                }
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(DashboardPalette.foreground)
                            .padding(.horizontal, 10)
                            .frame(height: 38)
                            .background(
                                option == selection ? DashboardPalette.muted.opacity(0.55) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: min(CGFloat(options.count) * 40, 248))
        }
        .padding(6)
        .frame(width: 288)
        .dashboardComposerPopover()
    }

    private func optionLabel(_ option: String) -> String {
        capitalizeOptions ? dashboardSessionThinkingLabel(option) : option
    }
}

struct DashboardComposerPopoverRow<Content: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let action: () -> Void
    let content: Content
    @State private var hovered = false

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            hovered ? theme.palette.themeSoft : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .onHover { hovered = $0 }
    }
}

struct DashboardComposerPopoverModifier: ViewModifier {
    @Environment(\.dashboardTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(
                DashboardPalette.background.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.palette.border.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: DashboardPalette.foreground.opacity(0.12), radius: 24, y: 14)
    }
}

extension View {
    func dashboardComposerPopover() -> some View {
        modifier(DashboardComposerPopoverModifier())
    }
}

func dashboardSessionThinkingLabel(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").capitalized
}

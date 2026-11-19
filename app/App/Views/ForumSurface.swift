import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

/// The Forum and, on wide panels, a thread beside it, laid out like a bot's channel.
/// The bots runtime owns the rooms; this is Woven's own chat UI over its protocol.
struct ForumWorkspace: View {
    @Bindable var bots: BotMachineSession
    let target: BotTarget
    let headerInsets: BotHeaderInsets
    let focusGeneration: Int?
    let startsComposerCollapsed: Bool
    let usesCompactSpacing: Bool
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let onActivate: () -> Void
    let onClosePanel: () -> Void
    let onAddPanel: () -> Void
    let onRoute: (BotTarget) -> Void
    let onOpenLink: (URL) -> Void
    @State private var threadWidth: CGFloat = 440

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= BotThreadSplit.wideWidth
            let split = target.conversationID != nil && target.showsThreadBesideMain && wide
            HStack(spacing: 0) {
                if split {
                    pane(roomID: nil, insets: BotHeaderInsets(left: headerInsets.left, right: 0),
                         showsClose: showsClosePanel, showsAdd: false, compact: true)
                    BotThreadResizer(threadWidth: $threadWidth, available: geometry.size.width)
                    threadPane(wide: wide, split: true, insets: BotHeaderInsets(left: 0, right: headerInsets.right), showsClose: false, showsAdd: showsAddPanel)
                        .frame(width: BotThreadSplit.clamped(threadWidth, available: geometry.size.width))
                } else if target.conversationID != nil {
                    threadPane(wide: wide, split: false, insets: headerInsets, showsClose: showsClosePanel, showsAdd: showsAddPanel)
                } else {
                    pane(roomID: nil, insets: headerInsets, showsClose: showsClosePanel, showsAdd: showsAddPanel)
                }
            }
        }
    }

    private func pane(roomID: Int?, insets: BotHeaderInsets, showsClose: Bool, showsAdd: Bool,
                      compact: Bool = false, showsPause: Bool = true, actions: [BotPaneAction] = []) -> some View {
        ForumPane(
            bots: bots,
            controller: bots.forumRoom(roomID: roomID),
            headerInsets: insets,
            headerActions: actions,
            showsPausedBanner: showsPause,
            focusGeneration: focusGeneration,
            startsComposerCollapsed: startsComposerCollapsed,
            usesCompactSpacing: usesCompactSpacing || compact,
            showsClosePanel: showsClose,
            showsAddPanel: showsAdd,
            onActivate: onActivate,
            onClosePanel: onClosePanel,
            onAddPanel: onAddPanel,
            onOpenThread: { onRoute(.forum(machineID: bots.machineID, roomID: $0, showsThreadBesideMain: true)) },
            onOpenLink: onOpenLink
        )
        .id(BotConversationKey(machineID: bots.machineID, botID: BotTarget.forumBotID, conversationID: roomID))
    }

    private func threadPane(wide: Bool, split: Bool, insets: BotHeaderInsets, showsClose: Bool, showsAdd: Bool) -> some View {
        let roomID = target.conversationID
        var actions: [BotPaneAction] = []
        if wide {
            actions.append(BotPaneAction(glyph: split ? .maximize : .columns,
                title: split ? "Expand thread" : "Show beside the Forum") {
                onRoute(.forum(machineID: bots.machineID, roomID: roomID, showsThreadBesideMain: !split))
            })
        }
        actions.append(BotPaneAction(glyph: .close, title: "Back to the Forum") {
            onRoute(.forum(machineID: bots.machineID))
        })
        // Beside the Forum, the Forum's own pane already says it is paused.
        return pane(roomID: roomID, insets: insets, showsClose: showsClose, showsAdd: showsAdd, compact: split,
                    showsPause: !split, actions: actions)
    }
}

private struct ForumPane: View {
    /// The window of recent posts rendered at once, like a bot channel's message page.
    private static let postPage = 60
    private static let endID = "forum-end"

    @Bindable var bots: BotMachineSession
    let controller: ForumRoomController
    let headerInsets: BotHeaderInsets
    let headerActions: [BotPaneAction]
    let showsPausedBanner: Bool
    let focusGeneration: Int?
    let startsComposerCollapsed: Bool
    let usesCompactSpacing: Bool
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let onActivate: () -> Void
    let onClosePanel: () -> Void
    let onAddPanel: () -> Void
    let onOpenThread: (Int) -> Void
    let onOpenLink: (URL) -> Void

    @Environment(\.wovenTheme) private var theme
    @State private var attached: ForumRoomController?
    @State private var following = true
    @State private var isUserScrolling = false
    @State private var shownPosts = ForumPane.postPage
    @State private var bottomStackHeight: CGFloat = 0
    @State private var composerCollapseOverride: Bool?
    @State private var pausing = false

    private var key: BotConversationKey { controller.key }
    private var isThread: Bool { controller.isThread }
    private var forum: PiBotForumState? { bots.forum }
    private var thread: PiBotForumThread? { key.conversationID.flatMap { forum?.thread(roomID: $0) } }
    private var posts: [PiBotForumPost] { controller.state.posts }
    private var isPaused: Bool { forum?.paused == true }
    private var isEmpty: Bool { posts.isEmpty && controller.pending.isEmpty }
    private var isNewThread: Bool { isThread && isEmpty }

    private func name(_ botID: String) -> String? { bots.bots.first { $0.id == botID }?.name }

    /// The bots that hear this room: everyone in the Forum, or a thread's own members.
    private var memberIDs: Set<String> {
        let active = forum?.activeBotIDs ?? []
        guard isThread else { return active }
        return active.intersection(thread?.botIds ?? [])
    }

    private var mentionCandidates: [PiBotForumMentions.Candidate] {
        let active = forum?.activeBotIDs ?? []
        let members = memberIDs
        return bots.bots.map { .init(id: $0.id, name: $0.name, active: active.contains($0.id), member: members.contains($0.id)) }
    }

    private var draftMentions: PiBotForumMentions {
        PiBotForumMentions.resolve(bots.drafts[key].text, candidates: mentionCandidates)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isPaused, showsPausedBanner {
                ForumPausedBanner(busy: pausing) { setPaused(false) }
                    .frame(maxWidth: 768)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
            }
            ZStack(alignment: .bottom) {
                transcript
                bottomStack
            }
        }
        .background(theme.palette.workspace)
        .environment(\.conversationLinkHandler, onOpenLink)
        .onAppear {
            guard attached == nil else { return }
            controller.attach()
            attached = controller
        }
        .onDisappear {
            attached?.detach()
            attached = nil
        }
    }

    private func setPaused(_ paused: Bool) {
        guard !pausing else { return }
        pausing = true
        Task {
            await bots.setForumPaused(paused)
            pausing = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(isThread ? (thread?.label ?? "Thread") : "Forum")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isThread && thread?.hasTitle != true ? WovenPalette.mutedForeground : WovenPalette.foreground)
                .lineLimit(1)
            if isThread {
                Text("in Forum")
                    .font(.system(size: 12))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 8)
            if isThread {
                ForumThreadMembersButton(names: bots.bots.filter { memberIDs.contains($0.id) }.map(\.name))
            } else {
                ForumMembersButton(bots: bots)
                ForumSchedulesButton(bots: bots)
                Button(isPaused ? "Resume" : "Pause") { setPaused(!isPaused) }
                    .buttonStyle(WovenQuietButtonStyle())
                    .disabled(pausing || forum == nil || !bots.isConnected)
                    .help(isPaused ? "Let bots see the Forum again. Each one catches up on what it missed."
                                   : "Stop every bot's Forum reply and hold new posts until you resume.")
            }
            ForEach(headerActions) { item in
                Button(action: item.action) {
                    LucideIcon(glyph: item.glyph, size: 14)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(WovenIconButtonStyle())
                .accessibilityLabel(item.title)
                .help(item.title)
            }
        }
        .padding(.leading, 16 + headerInsets.left)
        .padding(.trailing, 10 + headerInsets.right)
        .frame(height: 44)
        .padding(.top, 8)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if isThread, let parent = controller.state.parent {
                        ForumThreadOrigin(post: parent)
                            .padding(.bottom, 20)
                    }
                    transcriptContent(proxy)
                    Color.clear
                        .frame(height: bottomClearance)
                        .padding(.top, 24)
                        .id(Self.endID)
                }
                .frame(maxWidth: 768)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 16)
            }
            .scrollIndicators(.never)
            // Text fades under the header instead of being cut off at it.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Color.black
                }
            }
            .defaultScrollAnchor(isNewThread ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .onScrollPhaseChange { _, phase in
                isUserScrolling = phase == .interacting || phase == .tracking || phase == .decelerating
            }
            .onScrollGeometryChange(for: ConversationGeometry.self) { geometry in
                ConversationGeometry(
                    contentHeight: geometry.contentSize.height,
                    isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 90,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { old, new in
                let resized = old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight
                if isNewThread {
                    // A new thread opens at the top, with its starting post in view.
                } else if resized, following, !isUserScrolling {
                    Task { @MainActor in
                        await Task.yield()
                        guard following, !isUserScrolling else { return }
                        proxy.scrollTo(Self.endID, anchor: .bottom)
                    }
                } else if !resized || isUserScrolling {
                    // Any movement of the reader's own decides whether the newest post stays in view.
                    following = new.isNearBottom
                }
            }
            .onChange(of: controller.loading) { _, loading in
                guard !loading, following, !isNewThread else { return }
                jumpToEnd(proxy)
            }
            // A room already loaded opens at its newest post, too.
            .onAppear {
                guard !controller.loading, following, !isNewThread else { return }
                jumpToEnd(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button("Latest post", systemImage: "arrow.down") {
                        following = true
                        jumpToEnd(proxy)
                    }
                    .buttonStyle(WovenQuietButtonStyle())
                    .padding(.trailing, 32)
                    .padding(.bottom, bottomClearance)
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { onActivate() })
    }

    private func jumpToEnd(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(Self.endID, anchor: .bottom)
        }
    }

    @ViewBuilder private func transcriptContent(_ proxy: ScrollViewProxy) -> some View {
        if controller.loading && isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 13)).foregroundStyle(WovenPalette.mutedForeground)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if isEmpty, isThread {
            VStack(spacing: 4) {
                Text("New thread").font(.system(size: 15, weight: .semibold))
                Text(emptyThreadDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            thinkingRow
        } else if isEmpty {
            ConversationEmptyState(
                icon: .messageSquareReply,
                title: "Say hello to the Forum",
                detail: "You and your bots share this channel. Every bot sees every post and answers when it wants to. @mention one to ask it directly."
            )
            thinkingRow
        } else {
            let hidden = max(0, posts.count - shownPosts)
            if hidden > 0 || controller.state.hasEarlier, let firstShown = posts[hidden...].first {
                Button(controller.loadingEarlier ? "Loading…" : "Show earlier posts") {
                    showEarlier(hidden: hidden, anchor: firstShown.id, proxy)
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(controller.loadingEarlier)
                .padding(.bottom, 24)
            }
            VStack(spacing: 12) {
                ForEach(posts[hidden...]) { post in
                    ForumPostRow(
                        post: post,
                        showsThreadControls: !isThread,
                        canStartThread: controller.isReady,
                        onOpenThread: { openThread(from: post) }
                    )
                    .id(post.id)
                }
                ForEach(controller.pending) { item in
                    BotPendingMessage(text: item.text)
                }
                thinkingRow
            }
        }
    }

    private var emptyThreadDetail: String {
        let names = bots.bots.filter { memberIDs.contains($0.id) }.map(\.name)
        if names.isEmpty { return "@mention a bot to bring it into this thread." }
        let verb = names.count == 1 ? "is" : "are"
        return "\(PiBotForumMentions.list(names)) \(verb) in this thread. @mention another bot to add it."
    }

    /// Who has a turn running here, so it shows that bots saw a post before any has answered.
    @ViewBuilder private var thinkingRow: some View {
        if let text = PiBotForumRoomState.thinkingText(controller.state.thinking.compactMap(name)) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// Earlier posts already here come first; then the runtime's older pages.
    private func showEarlier(hidden: Int, anchor: Int, _ proxy: ScrollViewProxy) {
        following = false
        Task { @MainActor in
            if hidden == 0 { await controller.loadEarlier() }
            shownPosts += Self.postPage
            await Task.yield()
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private func openThread(from post: PiBotForumPost) {
        if let thread = post.thread {
            onOpenThread(thread.roomId)
            return
        }
        Task {
            if let thread = await controller.startThread(from: post) { onOpenThread(thread.roomId) }
        }
    }

    // MARK: Composer

    private var bottomClearance: CGFloat {
        CGFloat(ConversationBottomOverlayLayout.scrollClearance(stackHeight: Double(bottomStackHeight)))
    }

    private var bottomStack: some View {
        VStack(spacing: 8) {
            if let error = controller.error {
                BotDismissibleError(text: error) { controller.error = nil }
                    .frame(maxWidth: 768)
                    .padding(.horizontal, showsClosePanel || showsAddPanel ? PanelControlButton.size + 8 : 0)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if showsClosePanel {
                        PanelControlButton(glyph: .panelRightOpen, accessibilityLabel: "Remove panel", help: "Remove panel", action: onClosePanel)
                    } else if showsAddPanel {
                        Color.clear
                            .frame(width: PanelControlButton.size, height: PanelControlButton.size)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, ConversationComposer.verticalPadding)
                VStack(alignment: .leading, spacing: 6) {
                    ForumMentionBar(
                        bots: bots.bots.filter { forum?.isActive($0.id) == true },
                        note: draftMentions.note,
                        onInsert: insertMention
                    )
                    composer
                }
                .frame(maxWidth: 768)
                Group {
                    if showsAddPanel {
                        PanelControlButton(glyph: .panelLeftOpen, accessibilityLabel: "Add panel", help: "Add panel", action: onAddPanel)
                    } else if showsClosePanel {
                        Color.clear
                            .frame(width: PanelControlButton.size, height: PanelControlButton.size)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, ConversationComposer.verticalPadding)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, usesCompactSpacing ? 12 : 32)
        .padding(.top, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomStackHeight = max(0, $0) }
        .padding(.bottom, ConversationBottomOverlayLayout.bottomOffset)
    }

    private var draftBinding: Binding<String> {
        let key = key
        let drafts = bots.drafts
        return Binding(get: { drafts[key].text }, set: { drafts[key].text = $0 })
    }

    private var composerAttachments: [AgentMessageAttachmentDraft] {
        bots.drafts[key].attachments.map { file in
            .file(AgentFileAttachmentDraft(id: file.id, kind: .file, fileName: file.name, mimeType: "text/plain",
                sizeBytes: Int64(file.text.utf8.count), contentHash: "", localURL: file.url))
        }
    }

    private var composer: some View {
        let ready = controller.isReady
        let placeholder = !ready ? "Connecting…" : isThread ? "Reply in thread…" : "Message the Forum…"
        return ConversationComposer(
            placeholder: placeholder,
            draft: draftBinding,
            attachedNoteTitle: nil,
            attachments: composerAttachments,
            agentTools: nil,
            sessionID: nil,
            supportsGoals: false,
            showsSessionControls: false,
            showsPermissionControl: false,
            sessionMetadataLoading: false,
            sessionMetadata: nil,
            sessionControlsDisabled: true,
            sendDisabled: !ready || controller.sending,
            startsCollapsed: startsComposerCollapsed,
            collapseOverride: $composerCollapseOverride,
            focusRequestGeneration: focusGeneration,
            onActivate: onActivate,
            onSelectModel: nil,
            onSelectThinking: nil,
            onSelectPermission: nil,
            onAttachmentAction: { _ in chooseFiles() },
            onRemoveAttachment: { id in bots.drafts[key].attachments.removeAll { $0.id == id } },
            onOpenAttachment: { NSWorkspace.shared.open($0.localURL) },
            onDropFiles: attach,
            onCommandNavigation: { _ in false },
            onSend: send,
            directAttachmentLabel: "Attach text or code files"
        )
    }

    private func insertMention(_ name: String) {
        var text = bots.drafts[key].text
        if let last = text.last, !last.isWhitespace { text += " " }
        bots.drafts[key].text = text + "@\(name) "
        composerCollapseOverride = false
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, .sourceCode, .json, .xml, .yaml, .commaSeparatedText, .html, .shellScript]
        panel.message = "Choose text or code files, each smaller than 80 KB."
        panel.begin { response in
            guard response == .OK else { return }
            _ = attach(panel.urls)
        }
    }

    private func attach(_ urls: [URL]) -> Bool {
        do {
            let added = try urls.map(PiBotAttachmentDraft.read)
            bots.drafts[key].attachments += added
            controller.error = nil
            return true
        } catch {
            controller.error = error.localizedDescription
            return false
        }
    }

    private func send() {
        let draft = bots.drafts[key]
        let text = PiBotAttachmentDraft.message(draft: draft.text, attachments: draft.attachments)
        guard !text.isEmpty, controller.isReady, !controller.sending else { return }
        // Mentions come from what was typed, never from an attached file's text.
        let mentions = draftMentions
        following = true
        // Cleared on the way out so typing keeps working; put back if the runtime refuses it.
        bots.drafts[key] = BotDraftStore.Draft()
        let drafts = bots.drafts
        let key = key
        Task {
            let sent = await controller.send(text: text, mentions: mentions.botIDs, everyone: mentions.everyone)
            if !sent {
                var restored = drafts[key]
                restored.text = restored.text.isEmpty ? draft.text : draft.text + "\n" + restored.text
                restored.attachments = draft.attachments + restored.attachments
                drafts[key] = restored
            }
        }
    }
}

// MARK: - Posts

private struct ForumPostRow: View {
    let post: PiBotForumPost
    /// The Forum's own posts start and open threads; a thread's posts do not.
    let showsThreadControls: Bool
    let canStartThread: Bool
    let onOpenThread: () -> Void
    private enum Action: Hashable { case copy, thread }
    @State private var hovering = false
    @State private var copied = false
    @FocusState private var focusedAction: Action?

    var body: some View {
        HStack(spacing: 0) {
            if post.isUser { Spacer(minLength: 72) }
            VStack(alignment: post.isUser ? .trailing : .leading, spacing: 6) {
                if !post.isUser {
                    Text(post.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WovenPalette.foreground)
                        .padding(.horizontal, 4)
                }
                if post.isUser {
                    ConversationUserBubble(content: post.text.trimmingCharacters(in: .whitespacesAndNewlines)) { EmptyView() }
                    if post.isScheduled {
                        Text("Scheduled")
                            .font(.system(size: 11.5))
                            .foregroundStyle(WovenPalette.mutedForeground)
                            .padding(.horizontal, 4)
                    }
                } else {
                    ConversationResponse(content: post.text, isStreaming: false, showsCopyButton: false)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                ForEach(post.unanswered ?? []) { note in
                    InlineError(text: "\(note.name) didn't answer: \(note.reason)")
                    if note.needsSignIn { BotIssueButtons(issue: .signIn) }
                    else if note.hitLimit { BotIssueButtons(issue: .limit) }
                }
                if showsThreadControls, let thread = post.thread {
                    ForumThreadLink(replies: thread.replies, action: onOpenThread)
                }
                actions
            }
            .frame(maxWidth: post.isUser ? nil : .infinity, alignment: post.isUser ? .trailing : .leading)
            if !post.isUser { Spacer(minLength: 0) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(post.text, forType: .string)
            } label: {
                LucideIcon(glyph: copied ? .check : .copy, size: 13)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(WovenIconButtonStyle())
            .focused($focusedAction, equals: .copy)
            .help("Copy post")
            .accessibilityLabel(copied ? "Post copied" : "Copy post")
            if showsThreadControls, canStartThread || post.thread != nil {
                Button(action: onOpenThread) {
                    HStack(spacing: 5) {
                        LucideIcon(glyph: .messageSquareReply, size: 12)
                        Text("Reply in thread").font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(WovenIconButtonStyle())
                .focused($focusedAction, equals: .thread)
            }
        }
        // Nearly invisible rather than hidden, so VoiceOver and the keyboard still reach them.
        .opacity(hovering || focusedAction != nil ? 1 : 0.001)
        .onChange(of: hovering) { _, isHovering in if !isHovering { copied = false } }
    }
}

/// A Forum post's thread: how many posts it holds, opening it.
private struct ForumThreadLink: View {
    let replies: Int
    let action: () -> Void

    private var title: String {
        switch replies {
        case 0: "Thread"
        case 1: "1 reply"
        default: "\(replies) replies"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LucideIcon(glyph: .messageSquareReply, size: 12)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(replies > 0 ? WovenPalette.success : WovenPalette.mutedForeground)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open thread, \(title)")
    }
}

/// The Forum post a thread started from.
private struct ForumThreadOrigin: View {
    let post: PiBotForumPost
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Started from")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(WovenPalette.mutedForeground)
            if post.isUser {
                Text(post.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            } else {
                Text(post.name).font(.system(size: 12, weight: .medium))
                ConversationResponse(content: post.text, isStreaming: false, showsCopyButton: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: WovenMetrics.cardRadius, style: .continuous))
    }
}

private struct ForumPausedBanner: View {
    let busy: Bool
    let onResume: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            LucideIcon(glyph: .alertCircle, size: 15)
                .foregroundStyle(WovenPalette.warning)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 2) {
                Text("The Forum is paused.").font(.system(size: 12.5, weight: .medium))
                Text("Bots see no posts until you resume. You can still post; each bot catches up then.")
                    .font(.system(size: 12))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Resume", action: onResume)
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(busy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(WovenPalette.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Mentions

/// The "@" menu and what the draft's mentions will do, above the composer.
private struct ForumMentionBar: View {
    /// Bots in the Forum.
    let bots: [PiBotSummary]
    let note: String?
    let onInsert: (String) -> Void
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(bots) { bot in
                    Button(bot.name) { onInsert(bot.name) }
                }
                if !bots.isEmpty { Divider() }
                Button("Everyone here") { onInsert(PiBotForumMentions.everyoneKeyword) }
            } label: {
                Text(verbatim: "@")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(WovenIconButtonStyle())
            .fixedSize()
            .help("Mention a bot to ask it to reply")
            .accessibilityLabel("Mention a bot")
            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        // Posts scroll under this row, so it carries the page's own surface.
        .background(theme.palette.workspace.opacity(0.92), in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    }
}

// MARK: - Members

/// Who is in the Forum: a switch per bot. A bot that is out hears nothing and leaves its threads.
private struct ForumMembersButton: View {
    @Bindable var bots: BotMachineSession
    @State private var shown = false

    private var activeCount: Int { bots.forum?.activeBotIDs.count ?? 0 }

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                LucideIcon(glyph: .bot, size: 14)
                Text("\(activeCount)")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        .accessibilityLabel(activeCount == 1 ? "1 bot in the Forum" : "\(activeCount) bots in the Forum")
        .help("Bots in the Forum")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In the Forum")
                        .font(.system(size: 13, weight: .semibold))
                    Text("A bot that is in sees every post. Switched out, it sees none and leaves its threads.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForumMemberSwitches(bots: bots)
            }
            .padding(14)
            .frame(width: 300)
        }
    }
}

/// One "In the Forum" switch per bot, Admin Bot last. Used here and in Settings → Bots.
struct ForumMemberSwitches: View {
    @Bindable var bots: BotMachineSession
    @State private var changing = Set<String>()

    private var ordered: [PiBotSummary] { bots.bots.filter { !$0.isAdmin } + bots.bots.filter(\.isAdmin) }

    var body: some View {
        ForEach(ordered) { bot in
            Toggle(bot.name, isOn: Binding(
                get: { bots.forum?.isActive(bot.id) == true },
                set: { active in
                    changing.insert(bot.id)
                    Task {
                        await bots.setForumBotActive(botID: bot.id, active: active)
                        changing.remove(bot.id)
                    }
                }
            ))
            .toggleStyle(SettingsSwitchToggleStyle())
            .disabled(changing.contains(bot.id) || bots.forum == nil || !bots.isConnected)
        }
    }
}

/// Who hears a thread. Only a mention adds a bot, so this only lists them.
private struct ForumThreadMembersButton: View {
    let names: [String]
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                LucideIcon(glyph: .bot, size: 14)
                Text("\(names.count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        .accessibilityLabel(names.count == 1 ? "1 bot in this thread" : "\(names.count) bots in this thread")
        .help("Bots in this thread")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("In this thread")
                    .font(.system(size: 13, weight: .semibold))
                if names.isEmpty {
                    Text("No bots yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
                ForEach(names, id: \.self) { name in
                    Text(name).font(.system(size: 12.5))
                }
                Text("@mention a bot to add it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            .padding(14)
            .frame(width: 240, alignment: .leading)
        }
    }
}

// MARK: - Scheduled posts

/// Posts the runtime makes as the user at a set time. It keeps and fires them, so they
/// arrive with no app open.
private struct ForumSchedulesButton: View {
    @Bindable var bots: BotMachineSession
    @State private var shown = false
    @State private var draft = PiBotForumScheduleDraft(date: ForumSchedulesButton.nextHour())
    @State private var saving = false

    private var schedules: [PiBotForumSchedule] { bots.forumSchedules ?? [] }

    private static func nextHour() -> Date {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .hour, for: Date())?.start ?? Date()
        return calendar.date(byAdding: .hour, value: 1, to: start) ?? Date()
    }

    private var candidates: [PiBotForumMentions.Candidate] {
        bots.bots.map { .init(id: $0.id, name: $0.name, active: bots.forum?.isActive($0.id) == true) }
    }

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                LucideIcon(glyph: .calendarClockControl, size: 14)
                if !schedules.isEmpty {
                    Text("\(schedules.count)")
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(WovenIconButtonStyle())
        .accessibilityLabel(schedules.isEmpty ? "Scheduled posts"
            : schedules.count == 1 ? "1 scheduled post" : "\(schedules.count) scheduled posts")
        .help("Scheduled posts")
        .task(id: bots.isConnected) { await bots.loadForumSchedules() }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scheduled posts")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Each one is posted to the Forum as you, at its time.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(WovenPalette.mutedForeground)
                }
                ForEach(schedules) { schedule in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(schedule.text)
                                .font(.system(size: 12))
                                .lineLimit(2)
                            Text(schedule.whenText())
                                .font(.system(size: 11))
                                .foregroundStyle(WovenPalette.mutedForeground)
                        }
                        Spacer(minLength: 8)
                        Button { Task { await bots.deleteForumSchedule(id: schedule.id) } } label: {
                            LucideIcon(glyph: .trash, size: 14)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(WovenIconButtonStyle())
                        .accessibilityLabel("Remove scheduled post: \(schedule.text)")
                        .help("Remove scheduled post")
                    }
                }
                form
            }
            .padding(14)
            .frame(width: 340)
            .task { await bots.loadForumSchedules() }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            CalendarField("Schedule a post") {
                TextField("What to post", text: $draft.text, axis: .vertical)
                    .lineLimit(1...4)
                    .modifier(CalendarInputStyle())
                    .accessibilityLabel("What to post")
            }
            HStack(alignment: .top, spacing: 12) {
                CalendarField("Repeat") {
                    CalendarMenuPicker(title: "Repeat", selection: $draft.repeat, options: PiBotForumSchedule.Repeat.allCases) { $0.title }
                }
                if draft.repeat == .weekly {
                    CalendarField("Day") {
                        CalendarMenuPicker(title: "Day", selection: $draft.weekday, options: Array(0..<7)) {
                            PiBotForumSchedule.weekdayName($0) ?? ""
                        }
                    }
                }
            }
            CalendarField(draft.repeat == .once ? "When" : "Time") {
                if draft.repeat == .once {
                    DatePicker("When", selection: $draft.date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                } else {
                    DatePicker("Time", selection: $draft.date, displayedComponents: [.hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                }
            }
            if let note = PiBotForumMentions.resolve(draft.text, candidates: candidates).note {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Schedule") { save() }
                    .buttonStyle(WovenPrimaryButtonStyle())
                    .disabled(!draft.canSave || saving || !bots.isConnected)
            }
        }
    }

    private func save() {
        var next = draft
        let mentions = PiBotForumMentions.resolve(draft.text, candidates: candidates)
        next.mentions = mentions.botIDs
        next.everyone = mentions.everyone
        next.timeZone = .current
        saving = true
        Task {
            if await bots.saveForumSchedule(next) {
                draft = PiBotForumScheduleDraft(date: Self.nextHour())
            }
            saving = false
        }
    }
}

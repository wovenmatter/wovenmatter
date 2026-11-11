import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterClient
import WovenMatterCore

/// A bot's channel or thread in a chat panel. The bot's runtime owns the conversation; this
/// is Woven's own chat UI over its protocol, with Pi Bot's thread behavior.
struct BotConversationSurface: View {
    @Bindable var bots: BotsModel
    let panelID: DashboardChatPanelID
    let target: DashboardBotTarget
    let context: String?
    let headerInsets: BotHeaderInsets
    let focusGeneration: Int?
    let startsComposerCollapsed: Bool
    let usesCompactSpacing: Bool
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let onActivate: () -> Void
    let onClosePanel: () -> Void
    let onAddPanel: () -> Void
    let onRoute: (DashboardBotTarget) -> Void
    let onOpenLink: (URL) -> Void
    let onOpenSettings: () -> Void
    var onOpenConnections: () -> Void = {}

    private var session: BotMachineSession? { bots.session(for: target.machineID) }
    private var bot: PiBotSummary? { session?.bots.first { $0.id == target.botID } }

    var body: some View {
        Group {
            if let session, session.isAvailable {
                content(session)
            } else {
                unavailable
            }
        }
        .simultaneousGesture(TapGesture().onEnded { onActivate() })
        // A provider connected in Settings, or by another client, ends first-run setup here.
        .task(id: target.botID) { await session?.refreshOnboarding() }
    }

    @ViewBuilder private func content(_ session: BotMachineSession) -> some View {
            if session.onboarding?.needed == true {
                ZStack {
                    BotOnboardingView(bots: session, onOpenConnections: onOpenConnections)
                    controls
                }
            } else if let bot {
                BotConversationWorkspace(
                    bots: session,
                    bot: bot,
                    target: target,
                    context: context,
                    headerInsets: headerInsets,
                    focusGeneration: focusGeneration,
                    startsComposerCollapsed: startsComposerCollapsed,
                    usesCompactSpacing: usesCompactSpacing,
                    showsClosePanel: showsClosePanel,
                    showsAddPanel: showsAddPanel,
                    onActivate: onActivate,
                    onClosePanel: onClosePanel,
                    onAddPanel: onAddPanel,
                    onRoute: onRoute,
                    onOpenLink: onOpenLink
                )
            } else if session.hasLoadedBots {
                ZStack {
                    DashboardConversationEmptyState(icon: .bot, title: "This bot was deleted",
                        detail: "Restore it from Settings → Bots, or choose another bot.")
                    controls
                }
            } else {
                unavailable
            }
    }

    private var unavailable: some View {
        ZStack {
            BotsUnavailableView(machine: session?.machine ?? bots.machines.first { $0.id == target.machineID },
                                compatible: session?.isCompatible ?? true, onOpenSettings: onOpenSettings)
            controls
        }
    }

    /// The same side-of-composer placement regular chats use for panel controls.
    @ViewBuilder private var controls: some View {
        if showsClosePanel || showsAddPanel {
            VStack {
                Spacer()
                HStack {
                    if showsClosePanel {
                        DashboardPanelControlButton(glyph: .panelRightOpen, accessibilityLabel: "Remove panel", help: "Remove panel", action: onClosePanel)
                    }
                    Spacer()
                    if showsAddPanel {
                        DashboardPanelControlButton(glyph: .panelLeftOpen, accessibilityLabel: "Add panel", help: "Add panel", action: onAddPanel)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, DashboardComposer.verticalPadding)
            }
        }
    }
}

/// The main channel and, on wide panels, a thread beside it. Narrow panels show one at a time.
private struct BotConversationWorkspace: View {
    private static let wideWidth: CGFloat = 760
    private static let minimumThreadWidth: CGFloat = 340
    private static let minimumMainWidth: CGFloat = 360

    @Bindable var bots: BotMachineSession
    let bot: PiBotSummary
    let target: DashboardBotTarget
    let context: String?
    let headerInsets: BotHeaderInsets
    let focusGeneration: Int?
    let startsComposerCollapsed: Bool
    let usesCompactSpacing: Bool
    let showsClosePanel: Bool
    let showsAddPanel: Bool
    let onActivate: () -> Void
    let onClosePanel: () -> Void
    let onAddPanel: () -> Void
    let onRoute: (DashboardBotTarget) -> Void
    let onOpenLink: (URL) -> Void
    @State private var threadWidth: CGFloat = 440
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= Self.wideWidth
            let split = target.conversationID != nil && target.showsThreadBesideMain && wide
            HStack(spacing: 0) {
                if split {
                    pane(conversationID: nil, insets: BotHeaderInsets(left: headerInsets.left, right: 0),
                         showsClose: showsClosePanel, showsAdd: false, compact: true)
                    resizer(available: geometry.size.width)
                    threadPane(wide: wide, split: true, insets: BotHeaderInsets(left: 0, right: headerInsets.right), showsClose: false, showsAdd: showsAddPanel)
                        .frame(width: clampedThreadWidth(available: geometry.size.width))
                } else if target.conversationID != nil {
                    threadPane(wide: wide, split: false, insets: headerInsets, showsClose: showsClosePanel, showsAdd: showsAddPanel)
                } else {
                    pane(conversationID: nil, insets: headerInsets, showsClose: showsClosePanel, showsAdd: showsAddPanel)
                }
            }
        }
    }

    private func clampedThreadWidth(available: CGFloat) -> CGFloat {
        max(Self.minimumThreadWidth, min(available - Self.minimumMainWidth, threadWidth))
    }

    private func pane(conversationID: Int?, insets: BotHeaderInsets, showsClose: Bool, showsAdd: Bool,
                      compact: Bool = false, actions: [BotPaneAction] = []) -> some View {
        BotConversationPane(
            bots: bots,
            bot: bot,
            controller: bots.conversation(botID: bot.id, conversationID: conversationID),
            context: context,
            headerInsets: insets,
            headerActions: actions,
            focusGeneration: focusGeneration,
            startsComposerCollapsed: startsComposerCollapsed,
            usesCompactSpacing: usesCompactSpacing || compact,
            showsClosePanel: showsClose,
            showsAddPanel: showsAdd,
            onActivate: onActivate,
            onClosePanel: onClosePanel,
            onAddPanel: onAddPanel,
            onOpenThread: { onRoute(DashboardBotTarget(machineID: bots.machineID, botID: bot.id, conversationID: $0, showsThreadBesideMain: true)) },
            onOpenLink: onOpenLink
        )
        .id(BotConversationKey(machineID: bots.machineID, botID: bot.id, conversationID: conversationID))
    }

    private func threadPane(wide: Bool, split: Bool, insets: BotHeaderInsets, showsClose: Bool, showsAdd: Bool) -> some View {
        let conversationID = target.conversationID
        var actions: [BotPaneAction] = []
        if wide {
            actions.append(BotPaneAction(glyph: split ? .maximize : .columns,
                title: split ? "Expand thread" : "Show beside Main") {
                onRoute(DashboardBotTarget(machineID: bots.machineID, botID: bot.id, conversationID: conversationID, showsThreadBesideMain: !split))
            })
        }
        actions.append(BotPaneAction(glyph: .close, title: "Back to Main") {
            onRoute(DashboardBotTarget(machineID: bots.machineID, botID: bot.id))
        })
        return pane(conversationID: conversationID, insets: insets, showsClose: showsClose, showsAdd: showsAdd, compact: split, actions: actions)
    }

    private func resizer(available: CGFloat) -> some View {
        Rectangle()
            .fill(DashboardPalette.foreground.opacity(0.08))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStartWidth ?? clampedThreadWidth(available: available)
                            dragStartWidth = start
                            threadWidth = max(Self.minimumThreadWidth, min(available - Self.minimumMainWidth, start - value.translation.width))
                        }
                        .onEnded { _ in dragStartWidth = nil })
            }
            .accessibilityElement()
            .accessibilityLabel("Resize thread pane")
            .accessibilityValue("\(Int(clampedThreadWidth(available: available))) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 24 : -24
                threadWidth = max(Self.minimumThreadWidth, min(available - Self.minimumMainWidth, threadWidth + step))
            }
    }
}

private struct BotPaneAction: Identifiable {
    let glyph: DashboardLucideGlyph
    let title: String
    let action: () -> Void
    var id: String { title }
}

/// Room for native controls floating over the header at the window's edges.
struct BotHeaderInsets: Equatable {
    var left: CGFloat
    var right: CGFloat
}

private struct BotConversationPane: View {
    /// The window of recent messages rendered at once, like a regular chat's message page.
    private static let messagePage = 60
    private static let endID = "bot-chat-end"

    @Bindable var bots: BotMachineSession
    let bot: PiBotSummary
    let controller: BotConversationController
    let context: String?
    let headerInsets: BotHeaderInsets
    let headerActions: [BotPaneAction]
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

    @Environment(\.dashboardTheme) private var theme
    @Environment(\.workspaceApplicationModel) private var appModel
    @State private var attached: BotConversationController?
    @State private var following = true
    @State private var isUserScrolling = false
    @State private var shownMessages = BotConversationPane.messagePage
    @State private var bottomStackHeight: CGFloat = 0
    @State private var composerCollapseOverride: Bool?
    @State private var dismissedStatus: String?

    private var key: BotConversationKey { controller.key }
    private var threads: [PiBotThread] { bots.threads(for: bot.id) }
    private var thread: PiBotThread? { threads.first { $0.conversationId == controller.viewedID } }
    private var isThread: Bool { controller.isThread }
    private var fromThread: Bool { thread.map { $0.parentConversationId != controller.mainID } ?? false }
    private var entries: [PiBotDisplayEntry] { controller.visibleEntries }
    private var state: PiBotConversationState { controller.state }
    private var isEmpty: Bool { entries.isEmpty && state.pending.isEmpty && !state.running && state.streaming == nil }
    private var isNewThread: Bool { key.conversationID != nil && isEmpty }
    private var startingMessage: PiBotDisplayEntry? {
        guard isThread else { return nil }
        return controller.origin ?? thread.flatMap { thread in state.entries.first { $0.id == thread.forkedAt } }
    }

    /// Threads hang off the message they were forked from, like replies.
    private func replies(to entry: PiBotDisplayEntry) -> [PiBotThread] {
        threads.filter { candidate in
            (candidate.parentConversationId == controller.viewedID || candidate.parentConversationId == entry.conversationId)
                && candidate.forkedAt == entry.id && candidate.conversationId != controller.viewedID
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let status = bot.modelStatus, let statusKey = statusKey(status), statusKey != dismissedStatus {
                BotModelStatusBanner(text: PiBotModelStatusText(status: status, botName: bot.name)) { dismissedStatus = statusKey }
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

    private func statusKey(_ status: PiBotSummary.ModelStatus) -> String? {
        "\(bot.id):\(status.kind):\(status.at ?? 0)"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(isThread ? (thread?.label ?? "Untitled thread") : bot.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isThread && thread?.title?.isEmpty != false ? DashboardPalette.mutedForeground : DashboardPalette.foreground)
                .lineLimit(1)
            if isThread {
                Text(fromThread ? "in a thread" : "in \(bot.name)")
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let profile = bot.profileName, !profile.isEmpty {
                Text(profile)
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardPalette.mutedForeground)
                    .lineLimit(1)
                    .help("Profile")
            }
            if !isThread, let tools = appModel?.agentTools {
                let timers = tools.timers(forBot: bot.id, on: bots.machineID)
                if !timers.isEmpty { BotTimersButton(botName: bot.name, timers: timers, tools: tools) }
            }
            ForEach(headerActions) { item in
                Button(action: item.action) {
                    DashboardLucideIcon(glyph: item.glyph, size: 14)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DashboardIconButtonStyle())
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
                    if let startingMessage {
                        BotThreadOrigin(entry: startingMessage, botName: bot.name)
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
            .onScrollGeometryChange(for: DashboardConversationGeometry.self) { geometry in
                DashboardConversationGeometry(
                    contentHeight: geometry.contentSize.height,
                    isNearBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - 90,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { old, new in
                let resized = old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight
                if isNewThread {
                    // A new thread opens at the top, with its starting message in view.
                } else if resized, following, !isUserScrolling {
                    Task { @MainActor in
                        await Task.yield()
                        guard following, !isUserScrolling else { return }
                        proxy.scrollTo(Self.endID, anchor: .bottom)
                    }
                } else if !resized || isUserScrolling {
                    // Any movement of the reader's own decides whether the newest reply stays in view.
                    following = new.isNearBottom
                }
            }
            .onChange(of: controller.loading) { _, loading in
                guard !loading, following, !isNewThread else { return }
                jumpToEnd(proxy)
            }
            // A conversation already loaded opens at its newest message, too.
            .onAppear {
                guard !controller.loading, following, !isNewThread else { return }
                jumpToEnd(proxy)
            }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button("Latest reply", systemImage: "arrow.down") {
                        following = true
                        jumpToEnd(proxy)
                    }
                    .buttonStyle(DashboardQuietButtonStyle())
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
        if controller.loading && entries.isEmpty && state.pending.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.system(size: 13)).foregroundStyle(DashboardPalette.mutedForeground)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if isEmpty, startingMessage != nil {
            VStack(spacing: 4) {
                Text("New thread").font(.system(size: 15, weight: .semibold))
                Text("It picks up from the message you chose.")
                    .font(.system(size: 13))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        } else if isEmpty {
            DashboardConversationEmptyState(
                icon: isThread ? .gitBranch : .bot,
                title: isThread ? "New thread" : "Say hello to \(bot.name)",
                detail: isThread ? "It picks up from the message you chose." : "This is its main conversation. Start a thread from any message."
            )
        } else {
            let hidden = max(0, entries.count - shownMessages)
            if hidden > 0, let firstShown = entries[hidden...].first {
                Button("Show earlier messages") {
                    following = false
                    shownMessages += Self.messagePage
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(firstShown.id, anchor: .top)
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .padding(.bottom, 24)
            }
            VStack(spacing: 12) {
                ForEach(entries[hidden...]) { entry in
                    BotMessageRow(
                        entry: entry,
                        botName: bot.name,
                        replies: replies(to: entry),
                        canStartThread: controller.isReady,
                        onStartThread: { startThread(from: entry) },
                        onOpenThread: onOpenThread
                    )
                    .id(entry.id)
                }
                ForEach(state.pending) { item in
                    BotPendingMessage(text: item.text)
                }
                if state.streaming != nil || state.running {
                    BotStreamingMessage(botName: bot.name, text: state.streaming)
                }
            }
        }
    }

    private func startThread(from entry: PiBotDisplayEntry) {
        Task {
            if let thread = await controller.startThread(from: entry) {
                onOpenThread(thread.conversationId)
            }
        }
    }

    // MARK: Composer

    private var bottomClearance: CGFloat {
        CGFloat(ConversationBottomOverlayLayout.scrollClearance(stackHeight: Double(bottomStackHeight)))
    }

    private var bottomStack: some View {
        VStack(spacing: 8) {
            // A failed reply already shows its error on the message itself.
            if let error = controller.error, error != entries.last?.error {
                BotDismissibleError(text: error) { controller.error = nil }
                    .frame(maxWidth: 768)
                    .padding(.horizontal, showsClosePanel || showsAddPanel ? DashboardPanelControlButton.size + 8 : 0)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if showsClosePanel {
                        DashboardPanelControlButton(glyph: .panelRightOpen, accessibilityLabel: "Remove panel", help: "Remove panel", action: onClosePanel)
                    } else if showsAddPanel {
                        Color.clear
                            .frame(width: DashboardPanelControlButton.size, height: DashboardPanelControlButton.size)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, DashboardComposer.verticalPadding)
                composer
                    .frame(maxWidth: 768)
                Group {
                    if showsAddPanel {
                        DashboardPanelControlButton(glyph: .panelLeftOpen, accessibilityLabel: "Add panel", help: "Add panel", action: onAddPanel)
                    } else if showsClosePanel {
                        Color.clear
                            .frame(width: DashboardPanelControlButton.size, height: DashboardPanelControlButton.size)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, DashboardComposer.verticalPadding)
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

    private var stopAction: (() -> Void)? {
        guard state.running, controller.isReady, !controller.stopping else { return nil }
        return { stop() }
    }

    private var escapeAction: (() -> Bool)? {
        guard state.running, controller.isReady else { return nil }
        return {
            stop()
            return true
        }
    }

    private var composer: some View {
        let ready = controller.isReady
        let placeholder = !ready ? "Connecting…" : isThread ? "Reply in thread…" : "Message \(bot.name)…"
        return DashboardComposer(
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
            onStop: stopAction,
            directAttachmentLabel: "Attach text or code files",
            onEscapeKey: escapeAction
        )
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
        following = true
        // Cleared on the way out so typing keeps working; put back if the server refuses it.
        bots.drafts[key] = BotDraftStore.Draft()
        let drafts = bots.drafts
        let key = key
        Task {
            let sent = await controller.send(text: text, context: context)
            if !sent {
                var restored = drafts[key]
                restored.text = restored.text.isEmpty ? draft.text : draft.text + "\n" + restored.text
                restored.attachments = draft.attachments + restored.attachments
                drafts[key] = restored
            }
        }
    }

    private func stop() {
        Task { await controller.stop() }
    }
}

/// The bot's own Woven timers (its schedule), labelled with its name. Each one
/// reaches the bot as a message when it fires; this Mac keeps and fires them.
private struct BotTimersButton: View {
    let botName: String
    let timers: [WorkspaceSessionTimer]
    let tools: WorkspaceAgentToolsModel
    @State private var shown = false

    private var title: String { "\(botName)’s timers" }

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                DashboardLucideIcon(glyph: .calendarClockControl, size: 14)
                Text("\(timers.count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardIconButtonStyle())
        .accessibilityLabel(timers.count == 1 ? "1 timer for \(botName)" : "\(timers.count) timers for \(botName)")
        .help(title)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text("Each one reaches \(botName) as a message when it fires.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
                ForEach(timers) { timer in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(timer.instruction)
                                .font(.system(size: 12))
                                .lineLimit(2)
                            Group {
                                if timer.isPaused { Text("Paused") }
                                else { Text(timer.nextFireAt, format: .dateTime.month(.abbreviated).day().hour().minute()) }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                        }
                        Spacer(minLength: 8)
                        Button(timer.isPaused ? "Resume" : "Pause") {
                            Task { await tools.pauseTimer(timer, paused: !timer.isPaused) }
                        }
                        .buttonStyle(DashboardQuietButtonStyle())
                        Button { Task { await tools.removeTimer(timer) } } label: {
                            DashboardLucideIcon(glyph: .trash, size: 14)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(DashboardIconButtonStyle())
                        .accessibilityLabel("Remove timer: \(timer.instruction)")
                        .help("Remove timer")
                    }
                }
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}

private struct BotMessageRow: View {
    let entry: PiBotDisplayEntry
    let botName: String
    let replies: [PiBotThread]
    let canStartThread: Bool
    let onStartThread: () -> Void
    let onOpenThread: (Int) -> Void
    private enum Action: Hashable { case copy, startThread }
    @State private var hovering = false
    @State private var copied = false
    @FocusState private var focusedAction: Action?

    var body: some View {
        HStack(spacing: 0) {
            if entry.isUser { Spacer(minLength: 72) }
            VStack(alignment: entry.isUser ? .trailing : .leading, spacing: 6) {
                if !entry.isUser {
                    Text(botName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DashboardPalette.foreground)
                        .padding(.horizontal, 4)
                }
                if !entry.text.isEmpty {
                    if entry.isUser {
                        ConversationUserBubble(content: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)) { EmptyView() }
                    } else {
                        ConversationResponse(content: entry.text, isStreaming: false, showsCopyButton: false)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                }
                if entry.isStopped {
                    Text("Stopped")
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .padding(.horizontal, 4)
                }
                if let error = entry.error {
                    DashboardInlineError(text: error)
                }
                if !replies.isEmpty {
                    BotThreadReplies(replies: replies, onOpen: onOpenThread)
                }
                actions
            }
            .frame(maxWidth: entry.isUser ? nil : .infinity, alignment: entry.isUser ? .trailing : .leading)
            if !entry.isUser { Spacer(minLength: 0) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(entry.text, forType: .string)
            } label: {
                DashboardLucideIcon(glyph: copied ? .check : .copy, size: 13)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DashboardIconButtonStyle())
            .focused($focusedAction, equals: .copy)
            .help("Copy message")
            .accessibilityLabel(copied ? "Message copied" : "Copy message")
            if canStartThread {
                Button(action: onStartThread) {
                    HStack(spacing: 5) {
                        DashboardLucideIcon(glyph: .gitBranch, size: 12)
                        Text("Start thread").font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DashboardIconButtonStyle())
                .focused($focusedAction, equals: .startThread)
            }
        }
        // Nearly invisible rather than hidden, so VoiceOver and the keyboard still reach them.
        .opacity(hovering || focusedAction != nil ? 1 : 0.001)
        .onChange(of: hovering) { _, isHovering in if !isHovering { copied = false } }
    }
}

private struct BotThreadReplies: View {
    let replies: [PiBotThread]
    let onOpen: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(replies) { reply in
                Button { onOpen(reply.conversationId) } label: {
                    HStack(spacing: 6) {
                        DashboardLucideIcon(glyph: .messageSquareReply, size: 12)
                        Text(reply.label)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(reply.title?.isEmpty == false ? DashboardPalette.success : DashboardPalette.mutedForeground)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open thread: \(reply.label)")
            }
        }
    }
}

private struct BotThreadOrigin: View {
    let entry: PiBotDisplayEntry
    let botName: String
    @Environment(\.dashboardTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Started from")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DashboardPalette.mutedForeground)
            if entry.isUser {
                Text(entry.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            } else {
                Text(botName).font(.system(size: 12, weight: .medium))
                ConversationResponse(content: entry.text, isStreaming: false, showsCopyButton: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(theme.palette.themeWhisper, in: RoundedRectangle(cornerRadius: DashboardMetrics.cardRadius, style: .continuous))
    }
}

private struct BotPendingMessage: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 72)
            ConversationUserBubble(content: text) { EmptyView() }
                .opacity(0.6)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BotStreamingMessage: View {
    let botName: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(botName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DashboardPalette.foreground)
                .padding(.horizontal, 4)
            if let text, !text.isEmpty {
                ConversationResponse(content: text, isStreaming: true, showsCopyButton: false)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…")
                        .font(.system(size: 13))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct BotModelStatusBanner: View {
    let text: PiBotModelStatusText
    let onDismiss: () -> Void

    private var tint: Color {
        switch text.tone {
        case .success: DashboardPalette.success
        case .warning: DashboardPalette.warning
        case .error: DashboardPalette.danger
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            DashboardLucideIcon(glyph: text.tone == .success ? .circleCheck : .alertCircle, size: 15)
                .foregroundStyle(tint)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 2) {
                Text(text.title).font(.system(size: 12.5, weight: .medium))
                ForEach(text.lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(SettingsQuietButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct BotDismissibleError: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            DashboardLucideIcon(glyph: .alertCircle, size: 15)
            Text(text).lineLimit(3)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                DashboardLucideIcon(glyph: .close, size: 12)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .font(.system(size: 12))
        .foregroundStyle(DashboardPalette.danger)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(DashboardPalette.danger.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
    }
}

struct BotsUnavailableView: View {
    let machine: BotMachine?
    var compatible = true
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if machine?.state == .starting || (machine?.state == .ready && compatible) {
                ProgressView().controlSize(.small)
            } else {
                DashboardLucideIcon(glyph: .bot, size: 20)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            if let detail {
                Text(detail).font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            Button("Open Bot Settings", action: onOpenSettings).buttonStyle(SettingsQuietButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var name: String { machine?.displayName ?? "that machine" }

    private var title: String {
        guard let machine else { return "This bot's machine isn't connected" }
        switch machine.state {
        case .off: return machine.kind == .thisMac ? "Bots are off on this Mac" : "Bots are off on \(name)"
        case .starting: return "Starting bots on \(name)"
        case .ready: return compatible ? "Connecting…" : "Update bots on \(name)"
        case .unreachable: return "\(name) is unavailable"
        case .needsUpdate: return "Update everything to use these bots"
        case .failed: return "Bots on \(name) could not start"
        }
    }

    private var detail: String? {
        guard let machine else { return "Connect it in Settings → Apple Devices or Settings → Workspaces, then try again." }
        if machine.state == .ready, !compatible { return "Its bots runtime is older than this app can use." }
        if machine.state == .off, machine.kind == .thisMac { return "Turn them on in Settings → Bots." }
        return machine.message
    }
}

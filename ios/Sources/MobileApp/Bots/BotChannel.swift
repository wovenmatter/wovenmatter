import SwiftUI

/// A bot's main channel or one of its threads, followed on the bots' host while
/// it shows, and read from the library while the host is away. The composer
/// sits on the bottom bar; a thread started from a message opens as its own page.
struct BotChannel: View {
    /// The window of recent messages shown at once, as on the Mac.
    private static let messagePage = 60

    @Bindable var model: MobileModel
    let bot: PiBotSummary
    /// nil is the main channel.
    let conversationID: Int?
    let embedded: Bool
    @State private var attached: BotChatStore?
    @State private var following = true
    @State private var shownMessages = BotChannel.messagePage
    @State private var dismissedStatus: String?

    private var bots: BotsStore { model.app.bots }
    private var controller: BotChatStore { bots.conversation(botID: bot.id, conversationID: conversationID) }
    private var key: BotConversationKey { controller.key }
    private var state: PiBotConversationState { controller.state }
    private var entries: [PiBotDisplayEntry] { controller.visibleEntries }
    private var threads: [PiBotThread] { bots.threads(for: bot.id) }
    private var thread: PiBotThread? { threads.first { $0.conversationId == (controller.viewedID ?? conversationID) } }
    private var isThread: Bool { conversationID != nil }
    private var fromThread: Bool { thread.map { $0.parentConversationId != controller.mainID } ?? false }
    private var isEmpty: Bool { entries.isEmpty && state.pending.isEmpty && !state.running && state.streaming == nil }
    private var isNewThread: Bool { isThread && isEmpty }
    private var startingMessage: PiBotDisplayEntry? {
        guard isThread else { return nil }
        return controller.origin ?? thread.flatMap { thread in state.entries.first { $0.id == thread.forkedAt } }
    }

    var body: some View {
        BotPageFrame(title: isThread ? (thread?.label ?? "Untitled thread") : bot.name,
                     subtitle: isThread ? (fromThread ? "in a thread" : "in \(bot.name)") : bot.profileName.flatMap { $0.isEmpty ? nil : $0 },
                     titleIsPlaceholder: isThread && thread?.title?.isEmpty != false,
                     embedded: embedded, actions: { EmptyView() }) {
            BotTranscriptScroll(startsAtTop: isNewThread, loading: controller.loading, following: $following) { proxy in
                if let startingMessage {
                    BotThreadOrigin {
                        if !startingMessage.isUser { BotAuthorName(name: bot.name) }
                        ConversationResponse(content: startingMessage.text, isStreaming: false, showsCopyButton: false)
                    }
                }
                transcript(proxy)
            }
            .safeAreaInset(edge: .top, spacing: 0) { banner }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomStack }
        }
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

    @ViewBuilder private func transcript(_ proxy: ScrollViewProxy) -> some View {
        if controller.loading && entries.isEmpty && state.pending.isEmpty {
            Text("Loading…").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else if isEmpty, startingMessage != nil {
            BotNewThreadNote(detail: "It picks up from the message you chose.")
        } else if isEmpty {
            BotsNotice(glyph: isThread ? .gitBranch : .bot,
                       title: isThread ? "New thread" : "Say hello to \(bot.name)",
                       detail: isThread ? "It picks up from the message you chose."
                           : "This is its main conversation. Start a thread from any message.")
        } else {
            let hidden = max(0, entries.count - shownMessages)
            if hidden > 0 || controller.hasEarlierSaved, let firstShown = entries[hidden...].first {
                Button("Show earlier messages") {
                    following = false
                    shownMessages += Self.messagePage
                    Task { @MainActor in
                        if hidden == 0 { await controller.loadEarlierSaved() }
                        await Task.yield()
                        proxy.scrollTo(firstShown.id, anchor: .top)
                    }
                }
                .font(.footnote)
                .buttonStyle(WovenQuietButtonStyle())
                .padding(.bottom, 20)
                .accessibilityIdentifier("bot-show-earlier")
            }
            LazyVStack(spacing: 14) {
                ForEach(entries[hidden...]) { entry in
                    BotEntryRow(entry: entry, botName: bot.name, replies: replies(to: entry),
                                canStartThread: controller.isReady,
                                onStartThread: { startThread(from: entry) }, onOpenThread: openThread)
                        .id(entry.id)
                }
                ForEach(state.pending) { item in BotPendingRow(text: item.text) }
                if state.streaming != nil || state.running {
                    BotStreamingRow(botName: bot.name, text: state.streaming)
                }
            }
        }
    }

    /// Threads hang off the message they were forked from, like replies.
    private func replies(to entry: PiBotDisplayEntry) -> [PiBotThread] {
        threads.filter { candidate in
            (candidate.parentConversationId == controller.viewedID || candidate.parentConversationId == entry.conversationId)
                && candidate.forkedAt == entry.id && candidate.conversationId != controller.viewedID
        }
    }

    // MARK: Banner and composer

    @ViewBuilder private var banner: some View {
        if let status = bot.modelStatus {
            let statusKey = "\(bot.id):\(status.kind):\(status.at ?? 0)"
            if statusKey != dismissedStatus {
                BotModelStatusBanner(text: PiBotModelStatusText(status: status, botName: bot.name)) { dismissedStatus = statusKey }
                    .frame(maxWidth: 768)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    private var bottomStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A failed reply already shows its error on the message itself; while
            // the bots are away, the caption says why instead.
            BotComposerNotes(caption: controller.isReady ? nil : BotsStatusCaption.text(bots),
                             error: bots.isConnected && controller.error != entries.last?.error ? controller.error : nil) {
                controller.error = nil
            }
            BotComposer(draft: draftBinding, identity: "bot:\(key.botID):\(key.conversationID ?? 0)",
                        prompt: isThread ? "Reply in thread…" : "Message \(bot.name)…",
                        canSend: controller.isReady && !controller.sending,
                        onStop: state.running && controller.isReady && !controller.stopping ? { Task { await controller.stop() } } : nil,
                        onSend: send, onAttachFailed: { controller.error = $0 })
        }
        .frame(maxWidth: 768)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background { MobileBottomFade() }
    }

    private var draftBinding: Binding<BotDraftStore.Draft> {
        let key = key
        let drafts = bots.drafts
        return Binding(get: { drafts[key] }, set: { drafts[key] = $0 })
    }

    private func send() {
        let draft = bots.drafts[key]
        let text = PiBotAttachmentDraft.message(draft: draft.text, attachments: draft.attachments)
        guard !text.isEmpty, controller.isReady, !controller.sending else { return }
        following = true
        // Cleared on the way out so typing keeps working; put back if the host refuses it.
        bots.drafts[key] = BotDraftStore.Draft()
        let drafts = bots.drafts
        let key = key
        let controller = controller
        Task {
            if !(await controller.send(text: text, context: nil)) {
                var restored = drafts[key]
                restored.text = restored.text.isEmpty ? draft.text : draft.text + "\n" + restored.text
                restored.attachments = draft.attachments + restored.attachments
                drafts[key] = restored
            }
        }
    }

    private func startThread(from entry: PiBotDisplayEntry) {
        let controller = controller
        Task {
            if let thread = await controller.startThread(from: entry) { openThread(thread.conversationId) }
        }
    }

    /// A thread opens as its own page: a phone is narrower than the Mac's side-by-side width.
    private func openThread(_ id: Int) {
        model.paths[.bots, default: NavigationPath()]
            .append(BotTarget(machineID: key.machineID, botID: bot.id, conversationID: id))
    }
}

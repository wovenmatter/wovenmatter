import SwiftUI
import UIKit

/// The Forum, or one of its threads: laid out like a bot's channel, with the
/// poster's name over each bot's post. Its header holds who is in, the
/// scheduled posts and the one Pause or Resume button; a banner shows while it
/// is paused, and a line above the composer says what the draft's mentions do.
struct ForumChannel: View {
    /// The window of recent posts shown at once, as on the Mac.
    private static let postPage = 60

    @Bindable var model: MobileModel
    /// nil is the Forum itself.
    let roomID: Int?
    let embedded: Bool
    @State private var attached: ForumRoomStore?
    @State private var following = true
    @State private var shownPosts = ForumChannel.postPage
    @State private var pausing = false
    @State private var dismissedStatuses: Set<String> = []
    @State private var sheet: Sheet?

    private enum Sheet: String, Identifiable {
        case members, schedules
        var id: String { rawValue }
    }

    private var bots: BotsStore { model.app.bots }
    private var controller: ForumRoomStore { bots.forumRoom(roomID: roomID) }
    private var key: BotConversationKey { controller.key }
    private var forum: PiBotForumState? { bots.forum }
    private var isThread: Bool { roomID != nil }
    private var thread: PiBotForumThread? { roomID.flatMap { forum?.thread(roomID: $0) } }
    private var posts: [PiBotForumPost] { controller.state.posts }
    private var isPaused: Bool { forum?.paused == true }
    private var isEmpty: Bool { posts.isEmpty && controller.pending.isEmpty }

    private func name(_ botID: String) -> String? { bots.bots.first { $0.id == botID }?.name }

    /// The bots that hear this room: everyone in the Forum, or a thread's own members.
    private var memberIDs: Set<String> {
        let active = forum?.activeBotIDs ?? []
        guard isThread else { return active }
        return active.intersection(thread?.botIds ?? [])
    }

    private var draftMentions: PiBotForumMentions {
        let active = forum?.activeBotIDs ?? []
        let members = memberIDs
        return PiBotForumMentions.resolve(bots.drafts[key].text, candidates: bots.bots.map {
            .init(id: $0.id, name: $0.name, active: active.contains($0.id), member: members.contains($0.id))
        })
    }

    /// Who typing "@" offers: the bots in the Forum, then everyone in this room.
    private var composerMentions: [ComposerMention] {
        let members = memberIDs
        let named = bots.bots.filter { forum?.isActive($0.id) == true }.map { bot in
            ComposerMention(name: bot.name, detail: isThread && !members.contains(bot.id) ? "Adds it to this thread" : nil)
        }
        return named + [ComposerMention(name: PiBotForumMentions.everyoneKeyword,
                                        detail: isThread ? "Every bot in this thread" : "Every bot in the Forum")]
    }

    var body: some View {
        BotPageFrame(title: isThread ? (thread?.label ?? "Thread") : "Forum", subtitle: isThread ? "in Forum" : nil,
                     titleIsPlaceholder: isThread && thread?.hasTitle != true, embedded: embedded) {
            headerActions
        } content: {
            BotTranscriptScroll(startsAtTop: isThread && isEmpty, loading: controller.loading, following: $following) { proxy in
                if isThread, let parent = controller.state.parent {
                    BotThreadOrigin {
                        if !parent.isUser { BotAuthorName(name: parent.name) }
                        if let visualReply = parent.visualReply {
                            ConversationHTMLRenderView(reference: visualReply)
                        } else {
                            ConversationResponse(content: parent.text, isStreaming: false, showsCopyButton: false)
                        }
                    }
                }
                transcript(proxy)
            }
            .safeAreaInset(edge: .top, spacing: 0) { banners }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomStack }
        }
        .sheet(item: $sheet) { sheet in
            ForumSheet(bots: bots, kind: sheet == .members ? (isThread ? .threadMembers(memberNames) : .members) : .schedules)
        }
        .task(id: bots.isConnected) { if !isThread { await bots.loadForumSchedules() } }
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

    private var memberNames: [String] { bots.bots.filter { memberIDs.contains($0.id) }.map(\.name) }

    // MARK: Header

    @ViewBuilder private var headerActions: some View {
        let count = isThread ? memberNames.count : forum?.activeBotIDs.count ?? 0
        Button { sheet = .members } label: {
            HStack(spacing: 4) {
                LucideIcon(glyph: .bot, size: 17)
                Text("\(count)").font(.subheadline).monospacedDigit()
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(isThread ? (count == 1 ? "1 bot in this thread" : "\(count) bots in this thread")
                            : (count == 1 ? "1 bot in the Forum" : "\(count) bots in the Forum"))
        .accessibilityIdentifier("forum-members")
        if !isThread {
            let scheduled = bots.forumSchedules?.count ?? 0
            Button { sheet = .schedules } label: {
                HStack(spacing: 4) {
                    LucideIcon(glyph: .calendarClockControl, size: 17)
                    if scheduled > 0 { Text("\(scheduled)").font(.subheadline).monospacedDigit() }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(scheduled == 0 ? "Scheduled posts" : scheduled == 1 ? "1 scheduled post" : "\(scheduled) scheduled posts")
            .accessibilityIdentifier("forum-schedules")
            Button(isPaused ? "Resume" : "Pause") { setPaused(!isPaused) }
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
                .disabled(pausing || forum == nil || !bots.isConnected)
                .accessibilityHint(isPaused ? "Lets bots see the Forum again. Each one catches up on what it missed."
                                   : "Stops every bot’s Forum reply and holds new posts until you resume.")
                .accessibilityIdentifier("forum-pause")
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

    // MARK: Transcript

    @ViewBuilder private func transcript(_ proxy: ScrollViewProxy) -> some View {
        if controller.loading && isEmpty {
            Text("Loading…").font(.callout).foregroundStyle(WovenPalette.mutedForeground)
                .frame(maxWidth: .infinity).padding(.top, 40)
        } else if isEmpty, isThread {
            BotNewThreadNote(detail: emptyThreadDetail)
            thinkingRow.padding(.top, 14)
        } else if isEmpty {
            BotsNotice(glyph: .messageSquareReply, title: "Say hello to the Forum",
                       detail: "You and your bots share this channel. Every bot sees every post and answers when it wants to. @mention one to ask it directly.")
            thinkingRow
        } else {
            let hidden = max(0, posts.count - shownPosts)
            if hidden > 0 || controller.state.hasEarlier, let firstShown = posts[hidden...].first {
                Button(controller.loadingEarlier ? "Loading…" : "Show earlier posts") {
                    following = false
                    Task { @MainActor in
                        if hidden == 0 { await controller.loadEarlier() }
                        shownPosts += Self.postPage
                        await Task.yield()
                        proxy.scrollTo(firstShown.id, anchor: .top)
                    }
                }
                .font(.footnote)
                .buttonStyle(WovenQuietButtonStyle())
                .disabled(controller.loadingEarlier)
                .padding(.bottom, 20)
                .accessibilityIdentifier("forum-show-earlier")
            }
            LazyVStack(spacing: 14) {
                ForEach(posts[hidden...]) { post in
                    ForumPostRow(post: post, showsThreadControls: !isThread, canStartThread: controller.isReady,
                                 onOpenThread: { openThread(from: post) })
                        .id(post.id)
                }
                ForEach(controller.pending) { item in BotPendingRow(text: item.text) }
                thinkingRow
            }
        }
    }

    private var emptyThreadDetail: String {
        let names = memberNames
        if names.isEmpty { return "@mention a bot to bring it into this thread." }
        return "\(PiBotForumMentions.list(names)) \(names.count == 1 ? "is" : "are") in this thread. @mention another bot to add it."
    }

    /// Who has a turn running here, so it shows that bots saw a post before any has answered.
    @ViewBuilder private var thinkingRow: some View {
        if let text = PiBotForumRoomState.thinkingText(controller.state.thinking.compactMap(name)) {
            VStack(alignment: .leading, spacing: 6) {
                BotThinkingLabel(text: text)
                ConversationRunningDots().padding(.horizontal, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func openThread(from post: PiBotForumPost) {
        if let thread = post.thread { return push(thread.roomId) }
        let controller = controller
        Task {
            if let thread = await controller.startThread(from: post) { push(thread.roomId) }
        }
    }

    /// A thread opens as its own page: a phone is narrower than the Mac's side-by-side width.
    private func push(_ roomID: Int) {
        model.paths[.bots, default: NavigationPath()].append(BotTarget.forum(machineID: key.machineID, roomID: roomID))
    }

    // MARK: Banners and composer

    @ViewBuilder private var banners: some View {
        VStack(spacing: 6) {
            if isPaused {
                BotBanner(glyph: .alertCircle, tint: WovenPalette.warning, title: "The Forum is paused.",
                          lines: ["Bots see no posts until you resume. You can still post; each bot catches up then."],
                          actionTitle: "Resume", busy: pausing || !bots.isConnected) { setPaused(false) }
                    .accessibilityIdentifier("forum-paused")
            }
            // A bot here on a fallback model or out of usage says so, as in its own chat.
            ForEach(statusBots, id: \.bot.id) { item in
                BotModelStatusBanner(text: PiBotModelStatusText(status: item.status, botName: item.bot.name)) {
                    dismissedStatuses.insert(item.key)
                }
            }
        }
        .frame(maxWidth: 768)
        .padding(.horizontal, 12)
        .padding(.bottom, isPaused || !statusBots.isEmpty ? 6 : 0)
    }

    private var statusBots: [(bot: PiBotSummary, status: PiBotSummary.ModelStatus, key: String)] {
        let members = memberIDs
        return bots.bots.compactMap { bot in
            guard members.contains(bot.id), let status = bot.modelStatus else { return nil }
            let key = "\(bot.id):\(status.kind):\(status.at ?? 0)"
            return dismissedStatuses.contains(key) ? nil : (bot, status, key)
        }
    }

    private var bottomStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = draftMentions.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(WovenPalette.mutedForeground)
                    .lineLimit(2)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("forum-mention-note")
            }
            BotComposerNotes(caption: controller.isReady ? nil : BotsStatusCaption.text(bots),
                             error: bots.isConnected ? controller.error : nil) { controller.error = nil }
            BotComposer(draft: draftBinding, identity: "forum:\(roomID ?? 0)",
                        prompt: isThread ? "Reply in thread…" : "Message the Forum…",
                        canSend: controller.isReady && !controller.sending,
                        onStop: !controller.state.thinking.isEmpty && controller.isReady && !controller.stopping
                            ? { Task { await controller.stop() } } : nil,
                        mentions: composerMentions, onSend: send, onAttachFailed: { controller.error = $0 })
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
        // Mentions come from what was typed, never from an attached file's text.
        let mentions = draftMentions
        following = true
        bots.drafts[key] = BotDraftStore.Draft()
        let drafts = bots.drafts
        let key = key
        let controller = controller
        Task {
            if !(await controller.send(text: text, mentions: mentions.botIDs, everyone: mentions.everyone, context: nil)) {
                var restored = drafts[key]
                restored.text = restored.text.isEmpty ? draft.text : draft.text + "\n" + restored.text
                restored.attachments = draft.attachments + restored.attachments
                drafts[key] = restored
            }
        }
    }
}

/// One Forum post: the person's in the user bubble, a bot's under the name it
/// posted with; a mentioned bot that did not answer, and the post's thread.
private struct ForumPostRow: View {
    let post: PiBotForumPost
    /// The Forum's own posts start and open threads; a thread's posts do not.
    let showsThreadControls: Bool
    let canStartThread: Bool
    let onOpenThread: () -> Void

    var body: some View {
        BotMessageLayout(isUser: post.isUser) {
            if !post.isUser { BotAuthorName(name: post.name) }
            if post.isUser {
                ConversationUserBubble(content: post.text.trimmingCharacters(in: .whitespacesAndNewlines)) { EmptyView() }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = post.text }
                        if showsThreadControls, canStartThread || post.thread != nil {
                            Button(action: onOpenThread) { Label("Reply in thread", glyph: .messageSquareReply) }
                        }
                    }
                if post.isScheduled { BotQuietLine(text: "Scheduled") }
            } else if let visualReply = post.visualReply {
                ConversationHTMLRenderView(reference: visualReply).padding(.horizontal, 4)
            } else {
                ConversationResponse(content: post.text, isStreaming: false, showsCopyButton: false)
                    .padding(.horizontal, 4)
            }
            ForEach(post.unanswered) { note in
                BotInlineError(text: "\(note.name) didn't answer: \(note.reason)")
            }
            if showsThreadControls, let thread = post.thread {
                BotThreadLink(title: Self.repliesTitle(thread.replies), isTitled: thread.replies > 0, action: onOpenThread)
            }
            if !post.isUser, post.visualReply == nil {
                BotMessageActions(text: post.text,
                                  threadTitle: showsThreadControls && canStartThread && post.thread == nil ? "Reply in thread" : nil,
                                  threadGlyph: .messageSquareReply, onThread: onOpenThread)
            }
        }
        .accessibilityAction(named: "Copy post") { UIPasteboard.general.string = post.text }
        .accessibilityActions {
            if showsThreadControls, canStartThread || post.thread != nil { Button("Reply in thread", action: onOpenThread) }
        }
    }

    static func repliesTitle(_ replies: Int) -> String {
        switch replies {
        case 0: "Thread"
        case 1: "1 reply"
        default: "\(replies) replies"
        }
    }
}

/// What the Forum header's buttons open: who is in, a thread's bots, or the
/// scheduled posts.
private struct ForumSheet: View {
    enum Kind {
        case members
        case threadMembers([String])
        case schedules
    }

    @Bindable var bots: BotsStore
    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.wovenTheme) private var theme
    @State private var changing = Set<String>()

    var body: some View {
        NavigationStack {
            List { content }
                .mobilePageSurface()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
        .environment(\.wovenTheme, theme)
        .preferredColorScheme(theme.colorScheme)
        .tint(theme.palette.themeAccent)
    }

    private var title: String {
        switch kind {
        case .members: "In the Forum"
        case .threadMembers: "In this thread"
        case .schedules: "Scheduled posts"
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .members:
            Section {
                // Admin Bot last, as on the Mac.
                ForEach(bots.bots.filter { !$0.isAdmin } + bots.bots.filter(\.isAdmin)) { bot in
                    Toggle(bot.name, isOn: Binding(
                        get: { bots.forum?.isActive(bot.id) == true },
                        set: { active in
                            changing.insert(bot.id)
                            Task {
                                await bots.setForumBotActive(botID: bot.id, active: active)
                                changing.remove(bot.id)
                            }
                        }))
                    .disabled(changing.contains(bot.id) || bots.forum == nil || !bots.isConnected)
                    .frame(minHeight: 44)
                    .listRowBackground(theme.palette.themeWhisper)
                }
            } footer: {
                Text("A bot that is in sees every post. Switched out, it sees none and leaves its threads.")
            }
        case .threadMembers(let names):
            Section {
                if names.isEmpty {
                    Text("No bots yet.").foregroundStyle(WovenPalette.mutedForeground).listRowBackground(theme.palette.themeWhisper)
                }
                ForEach(names, id: \.self) { name in
                    Text(name).frame(minHeight: 44).listRowBackground(theme.palette.themeWhisper)
                }
            } footer: {
                Text("@mention a bot to add it.")
            }
        case .schedules:
            let schedules = bots.forumSchedules ?? []
            Section {
                if schedules.isEmpty {
                    Text(bots.forumSchedules == nil ? "Loading…" : "No scheduled posts")
                        .foregroundStyle(WovenPalette.mutedForeground)
                        .listRowBackground(theme.palette.themeWhisper)
                }
                ForEach(schedules) { schedule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(schedule.text).lineLimit(3)
                        Text(schedule.whenText()).font(.caption).foregroundStyle(WovenPalette.mutedForeground)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .listRowBackground(theme.palette.themeWhisper)
                    .swipeActions {
                        if bots.isConnected {
                            Button("Remove", role: .destructive) { Task { await bots.deleteForumSchedule(id: schedule.id) } }
                        }
                    }
                }
            } footer: {
                Text("Each one is posted to the Forum as you, at its time.")
            }
        }
    }
}

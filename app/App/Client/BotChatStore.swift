import Foundation
import Observation
import WovenProtocol

struct BotConversationKey: Hashable, Sendable {
    /// The bots' host.
    let machineID: String
    let botID: String
    /// nil is the bot's main channel, or the Forum itself.
    let conversationID: Int?
}

/// One open bot conversation: its history, the reply being written, and messages not yet
/// recorded. While a pane shows it, it follows one `SubscribeBots(open:)` on the host's server;
/// while the host is away it shows the conversation's saved items.
@MainActor
@Observable
final class BotChatStore {
    let key: BotConversationKey
    private(set) var state = PiBotConversationState()
    /// A thread's starting message.
    private(set) var origin: PiBotDisplayEntry?
    private(set) var viewedID: Int?
    private(set) var mainID: Int?
    private(set) var loading = true
    private(set) var sending = false
    private(set) var stopping = false
    var error: String?

    /// Reading the library's copy, which holds older items than those shown.
    private(set) var hasEarlierSaved = false

    /// Subscribed to the runtime's conversation, not reading the library's copy.
    private var isLive = false
    /// The library's copy is read a page at a time, newest first, as chats are.
    static let savedPage = 200
    @ObservationIgnored private var savedSessionID: String?
    @ObservationIgnored private var oldestSaved: Int?
    @ObservationIgnored private weak var bots: BotsStore?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var nextPendingID = 0

    init(key: BotConversationKey, bots: BotsStore) {
        self.key = key
        self.bots = bots
    }

    var isThread: Bool { viewedID != nil && mainID != nil && viewedID != mainID }

    /// Ready to take a message: subscribed, loaded, and showing the conversation asked for.
    var isReady: Bool {
        guard isLive, bots?.isConnected == true, !loading, let viewedID else { return false }
        return key.conversationID.map { $0 == viewedID } ?? (viewedID == mainID)
    }

    /// In a thread, only what was said in the thread. Inherited history stays with its parent.
    var visibleEntries: [PiBotDisplayEntry] {
        isThread ? state.entries.filter { $0.conversationId == viewedID } : state.entries
    }

    func attach() {
        viewers += 1
        if viewers == 1 { open() }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { close() }
    }

    /// The runtime came or went: follow it, or read the library's copy.
    func reopen() {
        if viewers > 0 { open() }
    }

    private func open() {
        close()
        loading = true
        guard let bots, let server = bots.server else { return }
        if bots.isConnected {
            var request: [String: JSONValue] = ["type": .string("conversation.open"), "botId": .string(key.botID)]
            if let conversationID = key.conversationID { request["conversationId"] = .integer(Int64(conversationID)) }
            following = Task { [weak self] in
                await server.follow(SubscribeBots(open: .object(request)), reply: { [weak self] opened in
                    self?.opened(opened)
                }, event: { [weak self] event in
                    self?.receive(event)
                }, failure: { [weak self] failure in
                    self?.error = failure.message
                    self?.loading = false
                })
            }
        } else if bots.isReadingSaved {
            following = Task { [weak self] in await self?.loadSaved() }
        }
    }

    private func close() {
        following?.cancel()
        following = nil
        isLive = false
        hasEarlierSaved = false
        savedSessionID = nil
    }

    private func opened(_ reply: BotsOpened) {
        bots?.apply(reply.status)
        guard let value = reply.opened else { return }
        do {
            let snapshot = try value.decode(BotsWire.ConversationSnapshot.self)
            origin = snapshot.threadOrigin.map(PiBotDisplayEntry.init)
            viewedID = snapshot.conversationId
            mainID = snapshot.mainConversationId
            state = PiBotConversationState(snapshot: snapshot, pending: state.pending)
            isLive = true
            loading = false
            error = nil
            let botID = key.botID
            Task { [weak bots] in await bots?.loadThreads(botID: botID) }
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func receive(_ event: BotsEvent) {
        switch event {
        case .status(let status): bots?.apply(status)
        case .message(let value):
            guard case .event(let botID, let conversationID, let event)? = try? value.decode(BotsWire.Message.self),
                  botID == key.botID, conversationID == viewedID else { return }
            state.apply(event)
            if case .error(let message) = event { error = message }
            if case .run(started: false) = event {
                // Thread titles may have been generated meanwhile.
                Task { [weak bots] in await bots?.loadThreads(botID: botID) }
            }
        }
    }

    /// The conversation as the library holds it; sending stays off.
    private func loadSaved() async {
        guard let bots, let server = bots.library else { return }
        let main = bots.savedChat(botID: key.botID, conversationID: nil)
        mainID = main?.conversationID
        origin = nil
        guard let chat = bots.savedChat(botID: key.botID, conversationID: key.conversationID) else {
            viewedID = key.conversationID ?? mainID
            state = PiBotConversationState()
            loading = false
            return
        }
        do {
            let items = try await server.call(SessionItems(sessionID: chat.session.id, beforeSequence: .max, limit: Self.savedPage))
            guard !Task.isCancelled else { return }
            viewedID = chat.conversationID
            state = PiBotConversationState()
            state.entries = PiBotDisplayEntry.saved(items, conversationID: chat.conversationID)
            savedSessionID = chat.session.id
            oldestSaved = items.first?.sequence
            hasEarlierSaved = (items.first?.sequence ?? 1) > 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Pages in older items of the library's copy.
    func loadEarlierSaved() async {
        guard !isLive, hasEarlierSaved, let sessionID = savedSessionID, let oldest = oldestSaved, let viewedID,
              let server = bots?.library else { return }
        do {
            let items = try await server.call(SessionItems(sessionID: sessionID, beforeSequence: oldest, limit: Self.savedPage))
            guard savedSessionID == sessionID else { return }
            state.entries = PiBotDisplayEntry.saved(items, conversationID: viewedID) + state.entries
            oldestSaved = items.first?.sequence ?? oldest
            hasEarlierSaved = (items.first?.sequence ?? 1) > 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reports whether the server took the message, so the composer keeps it otherwise.
    func send(text: String, context: String?) async -> Bool {
        guard isReady, let viewedID, let bots else { return false }
        if text.count > PiBotAttachmentDraft.maxMessageCharacters {
            error = "Message and attachments must total fewer than 100,000 characters."
            return false
        }
        sending = true
        defer { sending = false }
        error = nil
        nextPendingID += 1
        let pendingID = nextPendingID
        state.pending.append(.init(id: pendingID, text: text))
        var fields: [String: JSONValue] = ["botId": .string(key.botID), "conversationId": .integer(Int64(viewedID)),
                                           "text": .string(text)]
        if let context, !context.isEmpty { fields["context"] = .string(context) }
        do {
            _ = try await bots.call("message.send", fields)
            return true
        } catch {
            state.pending.removeAll { $0.id == pendingID }
            self.error = error.localizedDescription
            return false
        }
    }

    func stop() async {
        guard !stopping, let viewedID, let bots else { return }
        stopping = true
        defer { stopping = false }
        error = nil
        do {
            _ = try await bots.call("conversation.abort", ["botId": .string(key.botID), "conversationId": .integer(Int64(viewedID))])
            // Queued follow-ups went with the reply: they never become entries.
            state.pending = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    func startThread(from entry: PiBotDisplayEntry) async -> PiBotThread? {
        guard let viewedID, let bots else { return nil }
        error = nil
        do {
            let result = try await bots.call("thread.fork", ["botId": .string(key.botID), "conversationId": .integer(Int64(viewedID)),
                                                             "entryId": .integer(Int64(entry.id))], as: BotsWire.ThreadResult.self)
            await bots.loadThreads(botID: key.botID)
            return PiBotThread(result.thread)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// One open Forum room: the Forum itself or one of its threads. Followed like a bot's chat.
@MainActor
@Observable
final class ForumRoomStore {
    struct Pending: Equatable, Identifiable, Sendable {
        let id: Int
        let text: String
    }

    let key: BotConversationKey
    private(set) var state = PiBotForumRoomState()
    /// The room the runtime opened; the Forum's own room id is only known from its answer.
    private(set) var roomID: Int?
    private(set) var mainRoomID: Int?
    private(set) var loading = true
    private(set) var sending = false
    private(set) var loadingEarlier = false
    private(set) var stopping = false
    /// Posts sent and not yet back from the server.
    private(set) var pending: [Pending] = []
    var error: String?

    private var isLive = false
    @ObservationIgnored private weak var bots: BotsStore?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var following: Task<Void, Never>?
    @ObservationIgnored private var nextPendingID = 0
    /// The library's copy, while reading it: its session and the oldest item shown.
    @ObservationIgnored private var saved: (sessionID: String, oldest: Int)?

    init(key: BotConversationKey, bots: BotsStore) {
        self.key = key
        self.bots = bots
    }

    var isThread: Bool { key.conversationID != nil }

    /// Ready to take a post: subscribed, loaded, and showing the room asked for.
    var isReady: Bool {
        guard isLive, bots?.isConnected == true, !loading, let roomID else { return false }
        return key.conversationID.map { $0 == roomID } ?? (roomID == mainRoomID)
    }

    func attach() {
        viewers += 1
        if viewers == 1 { open() }
    }

    func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { close() }
    }

    /// The runtime came or went: follow it, or read the library's copy.
    func reopen() {
        if viewers > 0 { open() }
    }

    private func open() {
        close()
        loading = true
        guard let bots, let server = bots.server else { return }
        if bots.isConnected {
            var request: [String: JSONValue] = ["type": .string("forum.open")]
            if let roomID = key.conversationID { request["roomId"] = .integer(Int64(roomID)) }
            following = Task { [weak self] in
                await server.follow(SubscribeBots(open: .object(request)), reply: { [weak self] opened in
                    self?.opened(opened)
                }, event: { [weak self] event in
                    self?.receive(event)
                }, failure: { [weak self] failure in
                    self?.error = failure.message
                    self?.loading = false
                })
            }
        } else if bots.isReadingSaved {
            following = Task { [weak self] in await self?.loadSaved() }
        }
    }

    private func close() {
        following?.cancel()
        following = nil
        isLive = false
        saved = nil
    }

    private func opened(_ reply: BotsOpened) {
        bots?.apply(reply.status)
        guard let value = reply.opened else { return }
        do {
            let snapshot = try value.decode(BotsWire.ForumRoomSnapshot.self)
            roomID = snapshot.roomId
            mainRoomID = snapshot.mainRoomId
            state = PiBotForumRoomState(snapshot: snapshot)
            isLive = true
            loading = false
            error = nil
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func receive(_ event: BotsEvent) {
        switch event {
        case .status(let status): bots?.apply(status)
        case .message(let value):
            guard let roomID, let message = try? value.decode(BotsWire.Message.self) else { return }
            switch message {
            case .forumPost(let post): state.apply(PiBotForumPost(post), roomID: roomID)
            case .forumThinking(let changed, let botIDs) where changed == roomID: state.thinking = botIDs
            default: break
            }
        }
    }

    /// The room as the library holds it; posting stays off.
    private func loadSaved() async {
        guard let bots, let server = bots.library else { return }
        guard let room = bots.savedForumRoom(roomID: key.conversationID) else {
            state = PiBotForumRoomState()
            loading = false
            return
        }
        do {
            let items = try await server.call(SessionItems(sessionID: room.session.id, beforeSequence: .max,
                                                           limit: BotChatStore.savedPage))
            guard !Task.isCancelled else { return }
            roomID = room.conversationID
            mainRoomID = bots.savedForumRoom(roomID: nil)?.conversationID
            state = PiBotForumRoomState(posts: PiBotForumPost.saved(items, roomID: room.conversationID))
            saved = items.first.map { (room.session.id, $0.sequence) }
            state.hasEarlier = (items.first?.sequence ?? 1) > 1
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Reports whether the server took the post, so the composer keeps it otherwise.
    func send(text: String, mentions: [String], everyone: Bool, context: String?) async -> Bool {
        guard isReady, let roomID, let bots else { return false }
        if text.count > PiBotAttachmentDraft.maxMessageCharacters {
            error = "Message and attachments must total fewer than 100,000 characters."
            return false
        }
        sending = true
        defer { sending = false }
        error = nil
        nextPendingID += 1
        let pendingID = nextPendingID
        pending.append(.init(id: pendingID, text: text))
        defer { pending.removeAll { $0.id == pendingID } }
        var fields: [String: JSONValue] = ["roomId": .integer(Int64(roomID)), "text": .string(text)]
        if everyone { fields["everyone"] = .bool(true) }
        else if !mentions.isEmpty { fields["mentions"] = .array(mentions.map(JSONValue.string)) }
        if let context, !context.isEmpty { fields["context"] = .string(context) }
        do {
            let result = try await bots.call("forum.post", fields, as: BotsWire.ForumPostResult.self)
            // The push usually got here first; either way the post is shown once.
            if self.roomID == roomID { state.apply(PiBotForumPost(result.post), roomID: roomID) }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Stops the bots working in this room, as a chat's Stop does; the Forum is not paused.
    func stop() async {
        guard !stopping, let roomID, let bots else { return }
        stopping = true
        defer { stopping = false }
        error = nil
        do {
            _ = try await bots.call("forum.abort", ["roomId": .integer(Int64(roomID))])
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fetches the page of posts before the oldest one shown.
    func loadEarlier() async {
        guard isLive else { return await loadEarlierSaved() }
        guard !loadingEarlier, state.hasEarlier, let roomID, let oldest = state.posts.first?.id, let bots else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            let page = try await bots.call("forum.posts", ["roomId": .integer(Int64(roomID)), "before": .integer(Int64(oldest))],
                                           as: BotsWire.ForumPostsPage.self)
            guard self.roomID == roomID else { return }
            state.posts = PiBotForumRoomState.merge(state.posts, page.posts.map(PiBotForumPost.init))
            state.hasEarlier = page.hasEarlier && !page.posts.isEmpty
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pages in older posts of the library's copy.
    private func loadEarlierSaved() async {
        guard !loadingEarlier, state.hasEarlier, let saved, let roomID, let server = bots?.library else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        do {
            let items = try await server.call(SessionItems(sessionID: saved.sessionID, beforeSequence: saved.oldest,
                                                           limit: BotChatStore.savedPage))
            guard self.saved?.sessionID == saved.sessionID else { return }
            state.posts = PiBotForumRoomState.merge(state.posts, PiBotForumPost.saved(items, roomID: roomID))
            self.saved = (saved.sessionID, items.first?.sequence ?? saved.oldest)
            state.hasEarlier = (items.first?.sequence ?? 1) > 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The post's thread, created when it has none.
    func startThread(from post: PiBotForumPost) async -> PiBotForumThread? {
        guard let bots else { return nil }
        error = nil
        do {
            let result = try await bots.call("forum.thread.create", ["postId": .integer(Int64(post.id))], as: BotsWire.ForumThreadResult.self)
            await bots.refreshForum()
            return PiBotForumThread(result.thread)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// Text and attachments not sent yet, keyed by bot and conversation.
@MainActor
@Observable
final class BotDraftStore {
    struct Draft: Equatable {
        var text = ""
        var attachments: [PiBotAttachmentDraft] = []
    }
    private var drafts: [BotConversationKey: Draft] = [:]

    subscript(key: BotConversationKey) -> Draft {
        get { drafts[key] ?? Draft() }
        set { drafts[key] = newValue == Draft() ? nil : newValue }
    }
}

import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore

/// One open Forum room: the Forum itself (`key.conversationID` nil) or a thread. Opening and
/// re-opening after a reconnect follow `BotConversationController`, so a post made while the
/// socket was down still appears.
@MainActor @Observable
final class ForumRoomController {
    struct Pending: Equatable, Identifiable {
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
    /// Posts sent and not yet acknowledged.
    private(set) var pending: [Pending] = []
    var error: String?

    @ObservationIgnored private weak var bots: BotMachineSession?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var subscriptionID: JSONValue?
    @ObservationIgnored private var openedOn: PiBotClient?
    @ObservationIgnored private var nextPendingID = 0
    @ObservationIgnored private var openGeneration = 0
    /// Pushes can overtake the answer to `forum.open`, which also names the room.
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var postsDuringOpen: [PiBotForumPost] = []
    @ObservationIgnored private var thinkingDuringOpen: [Int: [String]] = [:]
    @ObservationIgnored private var lastRequest: Task<Void, Never>?
    private var isSubscribed = false

    init(session: BotMachineSession, key: BotConversationKey) {
        self.bots = session
        self.key = key
    }

    var isAttached: Bool { viewers > 0 }
    var isThread: Bool { key.conversationID != nil }
    /// Ready to take a post: connected, loaded and subscribed to the room asked for.
    var isReady: Bool {
        guard bots?.isConnected == true, !loading, isSubscribed, let roomID else { return false }
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

    func connectionOpened() { if isAttached { open() } }

    func connectionLost() {
        resetOpen()
        subscriptionID = nil
        openedOn = nil
        loading = true
        // Who is thinking comes back with the next snapshot.
        state.thinking = []
    }

    /// The machine's runtime changed: nothing here applies any more.
    func forget() {
        resetOpen()
        viewers = 0
        subscriptionID = nil
        openedOn = nil
    }

    private func resetOpen() {
        openGeneration += 1
        isOpening = false
        postsDuringOpen = []
        thinkingDuringOpen = [:]
        isSubscribed = false
        lastRequest = nil
    }

    /// Opens and closes run one at a time: the runtime keeps one subscription per room on a
    /// socket, so one overtaking another could leave none.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = lastRequest
        lastRequest = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func open() {
        guard let client = bots?.connectedClient else { return }
        openGeneration += 1
        let generation = openGeneration
        isOpening = false
        postsDuringOpen = []
        thinkingDuringOpen = [:]
        isSubscribed = false
        loading = true
        error = nil
        let requested = key.conversationID
        enqueue { [weak self] in
            guard let self, generation == openGeneration else { return }
            // Only now: until the previous close is done, its subscription can still send pushes.
            isOpening = true
            postsDuringOpen = []
            thinkingDuringOpen = [:]
            do {
                let snapshot = try await client.openForumRoom(roomID: requested)
                guard generation == openGeneration else {
                    // Superseded while it was on the way: don't leave its subscription behind.
                    try? await client.closeForumRoom(roomID: snapshot.roomId, subscriptionID: snapshot.subscriptionId)
                    return
                }
                subscriptionID = snapshot.subscriptionId
                openedOn = client
                isSubscribed = true
                roomID = snapshot.roomId
                mainRoomID = snapshot.mainRoomId
                state = PiBotForumRoomState.opened(snapshot: snapshot, posts: postsDuringOpen,
                                                   thinking: thinkingDuringOpen[snapshot.roomId])
                isOpening = false
                postsDuringOpen = []
                thinkingDuringOpen = [:]
                loading = false
            } catch {
                guard generation == openGeneration else { return }
                isOpening = false
                postsDuringOpen = []
                thinkingDuringOpen = [:]
                self.error = error.localizedDescription
                loading = false
                retryOpen(after: generation)
            }
        }
    }

    /// The composer stays off without a subscription, so a failed open keeps trying.
    private func retryOpen(after generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, generation == openGeneration, isAttached else { return }
            open()
        }
    }

    private func close() {
        openGeneration += 1
        isOpening = false
        postsDuringOpen = []
        thinkingDuringOpen = [:]
        isSubscribed = false
        guard let client = openedOn, let roomID else { return }
        let subscription = subscriptionID
        subscriptionID = nil
        openedOn = nil
        enqueue { try? await client.closeForumRoom(roomID: roomID, subscriptionID: subscription) }
    }

    func receive(_ post: PiBotForumPost) {
        if isOpening {
            postsDuringOpen.append(post)
        } else if let roomID, isAttached {
            state.apply(post, roomID: roomID)
        }
    }

    func receive(thinking botIDs: [String], roomID changed: Int) {
        if isOpening {
            thinkingDuringOpen[changed] = botIDs
        } else if changed == roomID, isAttached {
            state.apply(thinking: botIDs)
        }
    }

    /// Posts and reports whether the runtime took it, so the composer keeps it otherwise.
    func send(text: String, mentions: [String], everyone: Bool) async -> Bool {
        guard isReady, let roomID, let client = bots?.connectedClient else { return false }
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
        do {
            let post = try await client.postToForum(roomID: roomID, text: text, mentions: mentions, everyone: everyone)
            // The push usually got here first; either way the post is shown once.
            if let post, self.roomID == roomID { state.apply(post, roomID: roomID) }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Fetches the page of posts before the oldest one shown.
    func loadEarlier() async {
        guard !loadingEarlier, state.hasEarlier, let roomID, let oldest = state.posts.first?.id,
              let client = bots?.connectedClient else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let generation = openGeneration
        do {
            let page = try await client.forumPosts(roomID: roomID, before: oldest)
            guard generation == openGeneration else { return }
            state.prepend(page.posts, hasEarlier: page.hasEarlier && !page.posts.isEmpty)
        } catch {
            guard generation == openGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    /// The post's thread, created when it has none.
    func startThread(from post: PiBotForumPost) async -> PiBotForumThread? {
        guard let client = bots?.connectedClient else { return nil }
        error = nil
        do {
            let thread = try await client.forumThread(postID: post.id)
            await bots?.refreshForum()
            return thread
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

import Foundation
import Observation
import WovenMatterClient

struct BotConversationKey: Hashable, Sendable {
    let botID: String
    /// nil is the bot's main channel.
    let conversationID: Int?
}

/// One open Pi Bot conversation: its history, stream and pending messages. Opening and
/// re-opening after a reconnect follow Pi Bot's own client, so a reply that finished while
/// the socket was down still appears.
@MainActor @Observable
final class BotConversationController {
    let key: BotConversationKey
    private(set) var state = PiBotConversationState()
    private(set) var origin: PiBotDisplayEntry?
    private(set) var viewedID: Int?
    private(set) var mainID: Int?
    private(set) var loading = true
    private(set) var sending = false
    private(set) var stopping = false
    var error: String?

    @ObservationIgnored private weak var bots: BotsModel?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var subscriptionID: GatewayJSONValue?
    @ObservationIgnored private var openedOn: PiBotClient?
    @ObservationIgnored private var nextPendingID = 0
    @ObservationIgnored private var openGeneration = 0

    init(bots: BotsModel, key: BotConversationKey) {
        self.bots = bots
        self.key = key
    }

    var isAttached: Bool { viewers > 0 }
    var isThread: Bool { viewedID != nil && mainID != nil && viewedID != mainID }
    /// Ready to take a message: connected, loaded, and showing the conversation asked for.
    var isReady: Bool {
        guard bots?.isConnected == true, !loading, let viewedID else { return false }
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

    func connectionOpened() { if isAttached { open() } }

    func connectionLost() {
        openGeneration += 1
        subscriptionID = nil
        openedOn = nil
        loading = true
        // A stream cut off mid-reply resumes from the next snapshot.
        state.streaming = nil
        state.running = false
    }

    /// The device changed: nothing here applies any more.
    func forget() {
        openGeneration += 1
        viewers = 0
        subscriptionID = nil
        openedOn = nil
    }

    private func open() {
        guard let client = bots?.connectedClient else { return }
        openGeneration += 1
        let generation = openGeneration
        loading = true
        error = nil
        let key = key
        Task { [weak self] in
            do {
                let snapshot = try await client.openConversation(botID: key.botID, conversationID: key.conversationID)
                guard let self else { return }
                guard generation == openGeneration else {
                    // Superseded while it was on the way: don't leave its subscription behind.
                    try? await client.closeConversation(botID: key.botID, conversationID: snapshot.conversationId, subscriptionID: snapshot.subscriptionId)
                    return
                }
                subscriptionID = snapshot.subscriptionId
                openedOn = client
                origin = snapshot.threadOrigin
                viewedID = snapshot.conversationId
                mainID = snapshot.mainConversationId
                state.apply(snapshot: snapshot)
                loading = false
                await bots?.loadThreads(botID: key.botID)
            } catch {
                guard let self, generation == openGeneration else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func close() {
        openGeneration += 1
        guard let client = openedOn, let viewedID else { return }
        let subscription = subscriptionID
        subscriptionID = nil
        openedOn = nil
        let botID = key.botID
        Task { try? await client.closeConversation(botID: botID, conversationID: viewedID, subscriptionID: subscription) }
    }

    func receive(_ event: PiBotStreamEvent) {
        if case .error(let message) = event { error = message }
        state.apply(event)
        if case .run(started: false) = event {
            // Thread titles may have been generated meanwhile.
            let botID = key.botID
            Task { [weak bots] in await bots?.loadThreads(botID: botID) }
        }
    }

    /// Sends and reports whether the server took the message, so the composer keeps it otherwise.
    func send(text: String, context: String?) async -> Bool {
        guard isReady, let viewedID, let client = bots?.connectedClient else { return false }
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
        do {
            try await client.send(botID: key.botID, conversationID: viewedID, text: text, context: context)
            return true
        } catch {
            state.pending.removeAll { $0.id == pendingID }
            self.error = error.localizedDescription
            return false
        }
    }

    func stop() async {
        guard !stopping, let viewedID, let client = bots?.connectedClient else { return }
        stopping = true
        defer { stopping = false }
        error = nil
        do {
            try await client.abort(botID: key.botID, conversationID: viewedID)
            // Queued follow-ups went with the reply: they never become entries.
            state.pending = []
        } catch {
            self.error = error.localizedDescription
        }
    }

    func startThread(from entry: PiBotDisplayEntry) async -> PiBotThread? {
        guard let viewedID, let client = bots?.connectedClient else { return nil }
        error = nil
        do {
            let thread = try await client.forkThread(botID: key.botID, conversationID: viewedID, entryID: entry.id)
            await bots?.loadThreads(botID: key.botID)
            return thread
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// Text and attachments not sent yet, keyed by bot and conversation.
@MainActor @Observable
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

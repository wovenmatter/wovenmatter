// The bots client runs in the Mac and iPhone apps; Linux library builds skip it.
#if canImport(Darwin)
import Foundation
import Observation

/// One machine's bots connection as a conversation sees it: the Mac's
/// `BotMachineSession` and the iPhone's `MobileBotSession`.
@MainActor public protocol PiBotConversationHost: AnyObject {
    /// The socket, once the machine's runtime answered; nil while connecting.
    var connectedClient: PiBotClient? { get }
    var isConnected: Bool { get }
    /// Reloads a bot's threads (titles arrive after a reply, a fork adds one).
    func loadThreads(botID: String) async
}

public struct PiBotConversationKey: Hashable, Sendable {
    /// The machine whose runtime hosts the bot.
    public let machineID: String
    public let botID: String
    /// nil is the bot's main channel.
    public let conversationID: Int?
    public init(machineID: String, botID: String, conversationID: Int?) {
        self.machineID = machineID; self.botID = botID; self.conversationID = conversationID
    }
}

/// One open bot conversation: its history, stream and pending messages. Opening and
/// re-opening after a reconnect follow Pi Bot's own client, so a reply that finished while
/// the socket was down still appears.
@MainActor @Observable
public final class PiBotConversationController {
    public let key: PiBotConversationKey
    public private(set) var state = PiBotConversationState()
    public private(set) var origin: PiBotDisplayEntry?
    public private(set) var viewedID: Int?
    public private(set) var mainID: Int?
    public private(set) var loading = true
    public private(set) var sending = false
    public private(set) var stopping = false
    public var error: String?

    @ObservationIgnored private weak var host: (any PiBotConversationHost)?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var subscriptionID: JSONValue?
    @ObservationIgnored private var openedOn: PiBotClient?
    @ObservationIgnored private var nextPendingID = 0
    @ObservationIgnored private var openGeneration = 0
    /// Events can overtake the answer to `conversation.open`, which also names the conversation.
    @ObservationIgnored private var isOpening = false
    @ObservationIgnored private var duringOpen: [(conversationID: Int, event: PiBotStreamEvent)] = []
    @ObservationIgnored private var lastRequest: Task<Void, Never>?
    private var isSubscribed = false

    public init(host: any PiBotConversationHost, key: PiBotConversationKey) {
        self.host = host
        self.key = key
    }

    public var isAttached: Bool { viewers > 0 }
    public var isThread: Bool { viewedID != nil && mainID != nil && viewedID != mainID }
    /// Ready to take a message: connected, loaded, and showing the conversation asked for.
    public var isReady: Bool {
        guard host?.isConnected == true, !loading, isSubscribed, let viewedID else { return false }
        return key.conversationID.map { $0 == viewedID } ?? (viewedID == mainID)
    }

    /// In a thread, only what was said in the thread. Inherited history stays with its parent.
    public var visibleEntries: [PiBotDisplayEntry] {
        isThread ? state.entries.filter { $0.conversationId == viewedID } : state.entries
    }

    public func attach() {
        viewers += 1
        if viewers == 1 { open() }
    }

    public func detach() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { close() }
    }

    public func connectionOpened() { if isAttached { open() } }

    public func connectionLost() {
        openGeneration += 1
        isOpening = false
        duringOpen = []
        isSubscribed = false
        lastRequest = nil
        subscriptionID = nil
        openedOn = nil
        loading = true
        // A stream cut off mid-reply resumes from the next snapshot.
        state.streaming = nil
        state.running = false
    }

    /// The machine's runtime changed: nothing here applies any more.
    public func forget() {
        openGeneration += 1
        isOpening = false
        duringOpen = []
        isSubscribed = false
        lastRequest = nil
        viewers = 0
        subscriptionID = nil
        openedOn = nil
    }

    /// Opens and closes run one at a time: the server keeps one subscription per conversation
    /// on a socket, so one overtaking another could leave none.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = lastRequest
        lastRequest = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func open() {
        guard let client = host?.connectedClient else { return }
        openGeneration += 1
        let generation = openGeneration
        isOpening = false
        duringOpen = []
        isSubscribed = false
        loading = true
        error = nil
        let key = key
        enqueue { [weak self] in
            guard let self, generation == openGeneration else { return }
            // Only now: until the previous close is done, its subscription can still send events.
            isOpening = true
            duringOpen = []
            do {
                let snapshot = try await client.openConversation(botID: key.botID, conversationID: key.conversationID)
                guard generation == openGeneration else {
                    // Superseded while it was on the way: don't leave its subscription behind.
                    try? await client.closeConversation(botID: key.botID, conversationID: snapshot.conversationId, subscriptionID: snapshot.subscriptionId)
                    return
                }
                subscriptionID = snapshot.subscriptionId
                openedOn = client
                isSubscribed = true
                origin = snapshot.threadOrigin
                viewedID = snapshot.conversationId
                mainID = snapshot.mainConversationId
                let streamed = duringOpen.filter { $0.conversationID == snapshot.conversationId }.map(\.event)
                isOpening = false
                duringOpen = []
                state = PiBotConversationState.opened(snapshot: snapshot, events: streamed)
                loading = false
                for event in streamed { reportSideEffects(of: event) }
                Task { [weak host] in await host?.loadThreads(botID: key.botID) }
            } catch {
                guard generation == openGeneration else { return }
                isOpening = false
                duringOpen = []
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
        duringOpen = []
        isSubscribed = false
        guard let client = openedOn, let viewedID else { return }
        let subscription = subscriptionID
        subscriptionID = nil
        openedOn = nil
        let botID = key.botID
        enqueue { try? await client.closeConversation(botID: botID, conversationID: viewedID, subscriptionID: subscription) }
    }

    public func receive(conversationID: Int, _ event: PiBotStreamEvent) {
        if isOpening {
            duringOpen.append((conversationID, event))
        } else if conversationID == viewedID, isAttached {
            state.apply(event)
            reportSideEffects(of: event)
        }
    }

    private func reportSideEffects(of event: PiBotStreamEvent) {
        if case .error(let message) = event { error = message }
        if case .run(started: false) = event {
            // Thread titles may have been generated meanwhile.
            let botID = key.botID
            Task { [weak host] in await host?.loadThreads(botID: botID) }
        }
    }

    /// Sends and reports whether the server took the message, so the composer keeps it otherwise.
    public func send(text: String, context: String?) async -> Bool {
        guard isReady, let viewedID, let client = host?.connectedClient else { return false }
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

    public func stop() async {
        guard !stopping, let viewedID, let client = host?.connectedClient else { return }
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

    public func startThread(from entry: PiBotDisplayEntry) async -> PiBotThread? {
        guard let viewedID, let client = host?.connectedClient else { return nil }
        error = nil
        do {
            let thread = try await client.forkThread(botID: key.botID, conversationID: viewedID, entryID: entry.id)
            await host?.loadThreads(botID: key.botID)
            return thread
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}
#endif

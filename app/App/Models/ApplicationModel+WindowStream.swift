import Foundation
import LibraryClient
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The background server's Unix-socket connection, read as the stream's byte channel.
extension BackendStreamChannel: StreamByteChannel {}

/// A window's one persistent connection to its own background server ("Mac
/// window to its own server" in docs/architecture/WOVEN_EVERYWHERE.md) and
/// what it follows on it. Bulk history and lists stay in the read-only
/// projection; this carries what changed.
@MainActor
final class WindowLiveState {
    var connection: StreamConnection?
    var stateTask: Task<Void, Never>?
    var serverState: StreamSubscription?
    /// Bumped by every start and stop, so a closed connection's late events are ignored.
    var generation = 0
    // `server.state` work. Conversations and the rest are read by separate
    // workers, so a transcript never waits for settings or inventory.
    var pendingConversationIDs: Set<String> = []
    var reloadConversations = false
    var conversationWorker: Task<Void, Never>?
    var pendingScopes: Set<BackendInvalidationScope> = []
    var reloadScopes = false
    var scopeWorker: Task<Void, Never>?
    var scopeRetry: Task<Void, Never>?
    /// Open chats and their `conversation` subscriptions.
    var follows: [String: LiveConversation] = [:]

    @MainActor final class LiveConversation {
        var holders = 0
        var subscription: StreamSubscription?
        var events: [StreamSubscriptionEvent] = []
        var draining = false
        /// The server ended the subscription for good (a session it does not
        /// stream): `server.state` reloads this chat from the projection instead.
        var ended = false
        /// Another machine runs it: its items are the chat's live state.
        var remote = false
        /// A local chat's run state as the stream last sent it.
        var runState: RunState?
        var transcript: LibraryTranscript?
        var capability: HarnessCapabilities?
        var session: SessionSettings?
        var interactions: [PendingInteraction]?
        var owner: StreamOwner?
    }

    struct RunState: Equatable {
        var activeRunID: String?
        var runs: [LibraryTranscriptRun]?
        var removedMessageIDs: [String]?
        init(_ transcript: LibraryTranscript) {
            activeRunID = transcript.activeRunID; runs = transcript.runs; removedMessageIDs = transcript.removedMessageIDs
        }
    }
}

extension ApplicationModel {
    // MARK: Connection

    /// Opens the window's connection. It reconnects by itself (a local server
    /// restarts quickly, so within 2 s), resubscribes, and `synchronized`
    /// then reads everything again from the projection.
    func startWindowStream(socketURL: URL) async {
        await stopWindowStream()
        let live = windowLive
        let generation = live.generation
        let configuration = StreamConnection.Configuration(retrySleep: { delay in
            try await Task.sleep(for: min(delay, .seconds(2)))
        })
        let connection = StreamConnection(configuration: configuration) {
            LengthPrefixedStreamTransport(channel: try await BackendRPCClient(socketURL: socketURL).openStream())
        }
        live.connection = connection
        live.stateTask = Task { [weak self] in
            for await state in connection.states { self?.windowStreamState(state, generation: generation) }
        }
        live.serverState = await connection.subscribe(.serverState) { [weak self] event in
            await self?.receiveServerState(event, generation: generation)
            return .accepted
        }
        for (id, follow) in live.follows where follow.holders > 0 { await subscribeLive(id, follow) }
        await connection.start()
    }

    func stopWindowStream() async {
        let live = windowLive
        live.generation &+= 1
        live.stateTask?.cancel(); live.stateTask = nil
        live.conversationWorker?.cancel(); live.conversationWorker = nil
        live.scopeWorker?.cancel(); live.scopeWorker = nil
        live.scopeRetry?.cancel(); live.scopeRetry = nil
        live.pendingConversationIDs = []; live.pendingScopes = []
        live.reloadConversations = false; live.reloadScopes = false
        let connection = live.connection
        live.connection = nil; live.serverState = nil
        for follow in live.follows.values { follow.subscription = nil; follow.events = [] }
        await connection?.stop()
    }

    private func windowStreamState(_ state: StreamConnection.State, generation: Int) {
        guard generation == windowLive.generation else { return }
        switch state {
        case .waiting, .memberRemoved: reportBackendDisconnected()
        case .open, .connecting, .idle: break
        }
    }

    // MARK: server.state

    func receiveServerState(_ event: StreamSubscriptionEvent, generation: Int) {
        let live = windowLive
        guard generation == live.generation else { return }
        switch event {
        case .ended:
            // Ended for good: subscribe again, which starts from `synchronized`.
            live.serverState = nil
            guard let connection = live.connection else { return }
            Task { [weak self] in
                let subscription = await connection.subscribe(.serverState) { [weak self] event in
                    await self?.receiveServerState(event, generation: generation)
                    return .accepted
                }
                guard let self, generation == self.windowLive.generation else { await connection.unsubscribe(subscription); return }
                self.windowLive.serverState = subscription
            }
        case .item(let item):
            switch item.payload {
            case .synchronized:
                applyServerState(scopes: [], conversationIDs: [], reloadAll: true)
            case .serverState(let state):
                applyServerState(scopes: Set(state.scopes.compactMap(BackendInvalidationScope.init(rawValue:))),
                                 conversationIDs: Set(state.conversationIDs ?? []), reloadAll: false)
            default: break
            }
        }
    }

    /// One `server.state` change. `reloadAll` (on subscribe and after every
    /// reconnect): every scope and every loaded chat is read again.
    func applyServerState(scopes: Set<BackendInvalidationScope>, conversationIDs: Set<String>, reloadAll: Bool) {
        let live = windowLive
        if reloadAll { live.reloadConversations = true; live.reloadScopes = true }
        live.pendingConversationIDs.formUnion(conversationIDs)
        live.pendingScopes.formUnion(scopes)
        if live.reloadConversations || !live.pendingConversationIDs.isEmpty { runConversationWork() }
        if live.reloadScopes || !live.pendingScopes.isEmpty { runScopeWork() }
    }

    private func runConversationWork() {
        let live = windowLive
        guard live.conversationWorker == nil else { return }
        live.conversationWorker = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard live.reloadConversations || !live.pendingConversationIDs.isEmpty else { break }
                let reload = live.reloadConversations, ids = live.pendingConversationIDs
                live.reloadConversations = false; live.pendingConversationIDs = []
                // A chat that follows its own subscription gets its changes there.
                let followed = Set(live.follows.filter { $0.value.subscription != nil && !$0.value.ended }.keys)
                let loaded = Set(self.conversationStatesByID.keys)
                for id in (reload ? loaded : ids.intersection(loaded)).subtracting(followed) {
                    guard !Task.isCancelled else { break }
                    await self.refreshConversation(id: id)
                }
            }
            live.conversationWorker = nil
        }
    }

    private func runScopeWork() {
        let live = windowLive
        guard live.scopeWorker == nil else { return }
        live.scopeWorker = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard live.reloadScopes || !live.pendingScopes.isEmpty else { break }
                let reload = live.reloadScopes, scopes = live.pendingScopes
                live.reloadScopes = false; live.pendingScopes = []
                do { try await self.applyServerScopes(scopes, reloadAll: reload) }
                catch is CancellationError { break }
                catch {
                    // Never treat state whose read failed as current: read
                    // everything again once, shortly, while still connected.
                    guard !Task.isCancelled else { break }
                    live.reloadScopes = true
                    self.reportBackendDisconnected()
                    self.retryScopesSoon()
                    break
                }
            }
            live.scopeWorker = nil
        }
    }

    private func retryScopesSoon() {
        let live = windowLive, generation = live.generation
        live.scopeRetry?.cancel()
        live.scopeRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, generation == live.generation, await live.connection?.isOpen == true else { return }
            self.runScopeWork()
        }
    }

    // MARK: Conversations

    /// Follows an open chat's live state until the calling task is cancelled
    /// (the chat closes). Several views may follow one chat; it has one subscription.
    func followLiveConversation(_ id: String) async {
        guard isBackendFrontend else { return }
        let live = windowLive
        let follow = live.follows[id] ?? WindowLiveState.LiveConversation()
        live.follows[id] = follow
        follow.holders += 1
        if follow.holders == 1, follow.subscription == nil { await subscribeLive(id, follow) }
        // An AsyncStream's iteration ends when its task is cancelled.
        let (closed, keep) = AsyncStream<Void>.makeStream()
        for await _ in closed {}
        keep.finish()
        follow.holders -= 1
        guard follow.holders == 0, live.follows[id] === follow else { return }
        live.follows.removeValue(forKey: id)
        if let subscription = follow.subscription, let connection = live.connection { await connection.unsubscribe(subscription) }
    }

    private func subscribeLive(_ id: String, _ follow: WindowLiveState.LiveConversation) async {
        guard let connection = windowLive.connection else { return }
        follow.ended = false
        let subscription = await connection.subscribe(.conversation, params: .init(conversationID: id)) { [weak self] event in
            await self?.receiveLiveConversation(event, conversationID: id)
            return .accepted
        }
        guard follow.holders > 0, windowLive.follows[id] === follow, windowLive.connection === connection else {
            await connection.unsubscribe(subscription); return
        }
        follow.subscription = subscription
    }

    /// Takes one item without waiting: the connection reads its next frame at
    /// once, and the chat applies its items in order on its own.
    func receiveLiveConversation(_ event: StreamSubscriptionEvent, conversationID id: String) {
        guard let follow = windowLive.follows[id] else { return }
        follow.events.append(event)
        guard !follow.draining else { return }
        follow.draining = true
        Task { [weak self] in await self?.drainLiveConversation(id, follow) }
    }

    private func drainLiveConversation(_ id: String, _ follow: WindowLiveState.LiveConversation) async {
        defer { follow.draining = false }
        while windowLive.follows[id] === follow, !follow.events.isEmpty {
            let events = follow.events
            follow.events = []
            let relayed = events.contains { if case .item(let item) = $0, case .owner = item.payload { true } else { false } }
            if follow.remote || relayed || federatedExecutionOwners[id] != nil {
                follow.remote = true
                applyRelayedConversation(id, events, follow)
            } else {
                await applyLocalConversation(id, events, follow)
            }
        }
    }

    /// A chat another machine runs: its items are its live state, as they come.
    private func applyRelayedConversation(_ id: String, _ events: [StreamSubscriptionEvent], _ follow: WindowLiveState.LiveConversation) {
        for event in events {
            switch event {
            case .ended(let error):
                follow.ended = true
                follow.owner = .init(online: false, error: error?.message ?? follow.owner?.error)
            case .item(let item):
                switch item.payload {
                case .transcript(let value):
                    guard value.transcript.conversationID == id else { continue }
                    follow.transcript = value.snapshot ? value.transcript
                        : (follow.transcript ?? LibraryTranscript(conversationID: id)).applying(value)
                case .capabilities(let value): follow.capability = value.capabilities
                case .session(let value): follow.session = value.settings
                case .pending(let value): follow.interactions = value.interactions.filter { $0.conversationID == id }
                case .owner(let value): follow.owner = value
                case .conversations, .journal, .synchronized, .serverState, .unknown: break
                }
            }
        }
        if let snapshot = federatedExecutionSnapshots[id] { federatedExecutionSnapshots[id] = Self.overlay(snapshot, follow) }
    }

    /// A chat this Mac runs. Live text of a message the chat already shows is
    /// applied as it comes; anything else (a new message, activities, run
    /// state, a fresh subscription) is read from the projection, which holds
    /// the rows those items point to.
    private func applyLocalConversation(_ id: String, _ events: [StreamSubscriptionEvent], _ follow: WindowLiveState.LiveConversation) async {
        var reload = false
        var text: [String: (content: String, status: String?)] = [:]
        for event in events {
            switch event {
            case .ended: follow.ended = true
            case .item(let item):
                guard case .transcript(let value) = item.payload, value.transcript.conversationID == id else { continue }
                let runState = WindowLiveState.RunState(value.transcript)
                if value.snapshot || follow.runState == nil || follow.runState != runState || !value.transcript.activities.isEmpty {
                    reload = true
                }
                follow.runState = runState
                for message in value.transcript.messages {
                    // The stream shows user prompts as displayed; the projection holds them as saved.
                    if message.role == "user" { reload = true } else { text[message.id] = (message.content, message.status) }
                }
            }
        }
        if reload { await refreshConversation(id: id); return }
        guard !text.isEmpty else { return }
        if !(await applyLiveText(id, text)) { await refreshConversation(id: id) }
    }

    /// Applies live text to the messages a chat already shows; false when it
    /// cannot (a message it does not hold, or a projection read landed meanwhile).
    func applyLiveText(_ id: String, _ text: [String: (content: String, status: String?)]) async -> Bool {
        guard let state = conversationStatesByID[id], let presentation = state.presentation,
              let window = presentation.window.updatingMessages(text) else { return false }
        guard window != presentation.window else { return true }
        let revision = state.presentationRevision
        let previous = presentation.messagesByID
        let rendered = await Task.detached(priority: .userInitiated) {
            Self.renderMessagePresentations(window.messages, activities: window.activities, runs: window.runs, reusing: previous)
        }.value
        guard conversationStatesByID[id] === state, state.presentationRevision == revision else { return false }
        state.apply(DashboardConversationPresentation(window: window, messagesByID: rendered, runsByID: presentation.runsByID))
        return true
    }

    // MARK: Relayed snapshots

    /// Stores a chat's snapshot from the background service. What its live
    /// subscription already delivered stays: the snapshot may be older.
    func storeFederatedSnapshot(_ snapshot: FederatedExecutionSnapshot, conversationID id: String) {
        if let follow = windowLive.follows[id], follow.remote {
            federatedExecutionSnapshots[id] = Self.overlay(snapshot, follow)
        } else {
            federatedExecutionSnapshots[id] = snapshot
        }
    }

    private static func overlay(_ base: FederatedExecutionSnapshot, _ follow: WindowLiveState.LiveConversation) -> FederatedExecutionSnapshot {
        var snapshot = base
        if let transcript = follow.transcript { snapshot.transcript = transcript }
        if let capability = follow.capability { snapshot.capability = capability }
        if let session = follow.session { snapshot.session = session }
        if let interactions = follow.interactions { snapshot.interactions = interactions }
        if let owner = follow.owner { snapshot.online = owner.online; snapshot.error = owner.error }
        snapshot.streamed = follow.subscription != nil && !follow.ended
        return snapshot
    }
}

import Foundation
import LibraryClient
import WovenMatterCore
import WovenMatterShared

/// A client-mode Dev build's one stream to its live library host
/// (docs/DEVELOPMENT_BUILDS.md, "Client mode"): `workspace` once, and one
/// `conversation` subscription for every chat of the host's own that this
/// build's windows hold open. The socket is the live host's loopback
/// development listener, signed with this instance's Dev stream key; its key
/// is admitted again on the same-user socket before every attempt.
///
/// `workspace` items replace the client's timers: `conversations` keeps the
/// host's session summaries (run state) current, `pending` its questions and
/// approvals, and `library` says when library sync has something to fetch.
/// `conversation` items carry each open chat's transcript, capabilities and
/// settings. Live transcript text stays in memory; a snapshot and a settled
/// run reach the replica's cache.
actor DevelopmentLiveStream {
    enum Update: Sendable {
        case state(StreamConnection.State)
        /// Host session summaries reached the replica.
        case conversations
        case pending([PendingInteraction])
        /// The host's library change cursor.
        case library(Int64)
        case transcript(String, LibraryTranscript)
        case capabilities(String, HarnessCapabilities)
        case session(String, SessionSettings)
        /// The host does not serve this chat live (another machine runs it).
        case ended(String)
        /// The host ended the `workspace` subscription for good: nothing says
        /// when to sync until the next connection subscribes again, so the
        /// client's fallback timer runs meanwhile.
        case workspaceEnded(StreamError?)
    }

    /// The route the current socket was opened with, written by its connector.
    final class Route: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DevelopmentStreamRoute?
        var current: DevelopmentStreamRoute? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    nonisolated let connection: StreamConnection
    nonisolated let route: Route
    private let libraryID: String
    private let store: MobileStore
    private let update: @Sendable (Update) async -> Void
    private var workspaceSubscription: StreamSubscription?
    private var followed: [String: StreamSubscription] = [:]
    private var wanted: Set<String> = []
    /// Chats whose subscription the host ended; not asked for again on this socket.
    private var ended: Set<String> = []
    private var transcripts: [String: LibraryTranscript] = [:]
    private var reconciling = false
    private var stateTask: Task<Void, Never>?

    init(libraryID: String, store: MobileStore, connection: StreamConnection, route: Route,
         update: @escaping @Sendable (Update) async -> Void) {
        self.libraryID = libraryID; self.store = store; self.connection = connection; self.route = route; self.update = update
    }

    /// Chats with a live subscription now.
    var followedConversationIDs: Set<String> { Set(followed.keys) }

    func start() async {
        if stateTask == nil {
            let connection = connection
            stateTask = Task { [weak self] in
                for await state in connection.states { await self?.stateChanged(state) }
            }
        }
        await subscribeWorkspace()
        await connection.start()
    }

    private func subscribeWorkspace() async {
        // `start()` and a new `hello` can both ask; one subscription is sent.
        guard workspaceSubscription == nil, !subscribingWorkspace else { return }
        subscribingWorkspace = true
        defer { subscribingWorkspace = false }
        let ends = workspaceEnds
        let subscription = await connection.subscribe(.workspace) { [weak self] event in
            await self?.workspaceEvent(event) ?? .accepted
        }
        // Ended while it was being sent: the connection already dropped it,
        // and the next `hello` subscribes again.
        guard workspaceEnds == ends else { return }
        workspaceSubscription = subscription
    }
    private var subscribingWorkspace = false
    /// Terminal ends of the `workspace` subscription so far.
    private var workspaceEnds = 0

    /// Ends the socket (1000) and every subscription.
    func close() async {
        stateTask?.cancel(); stateTask = nil
        await connection.stop()
    }

    /// The chats to follow live; the others are unsubscribed.
    func follow(_ ids: Set<String>) async {
        wanted = ids
        ended.formIntersection(ids)
        transcripts = transcripts.filter { ids.contains($0.key) }
        guard !reconciling else { return }
        reconciling = true; defer { reconciling = false }
        var changed = true
        while changed {
            changed = false
            for (id, subscription) in followed where !wanted.contains(id) {
                followed.removeValue(forKey: id); changed = true
                await connection.unsubscribe(subscription)
            }
            for id in wanted.sorted() where followed[id] == nil && !ended.contains(id) {
                followed[id] = await connection.subscribe(.conversation, params: .init(conversationID: id)) { [weak self] event in
                    await self?.conversationEvent(event, conversationID: id) ?? .accepted
                }
                changed = true
            }
        }
    }

    private func stateChanged(_ state: StreamConnection.State) async {
        if case .open(let hello) = state {
            // The socket must answer as the live host this client syncs with.
            guard let expected = route.current, hello.deviceID.lowercased() == expected.audience.lowercased(),
                  hello.libraryID == libraryID, hello.libraryID == expected.libraryID, hello.workspaceID == expected.workspaceID else {
                await connection.stop()
                await update(.state(.waiting(.refused(status: 200, code: "wrong_workspace", message: "The live host answered as another library."))))
                return
            }
            if !ended.isEmpty { ended.removeAll(); await follow(wanted) }
            // A `workspace` subscription the host ended on the last socket starts again on this one.
            await subscribeWorkspace()
        }
        await update(.state(state))
    }

    private func workspaceEvent(_ event: StreamSubscriptionEvent) async -> StreamItemDisposition {
        guard case .item(let item) = event else {
            // `.ended` is final (the connection itself resubscribes a `resync`).
            if case .ended(let error) = event { workspaceSubscription = nil; workspaceEnds += 1; await update(.workspaceEnded(error)) }
            return .accepted
        }
        switch item.payload {
        case .conversations(let value):
            try? await store.cacheLibraryHostConversations(value.conversations)
            await update(.conversations)
        case .pending(let value):
            await update(.pending(value.interactions))
        case .library(let value):
            await update(.library(value.cursor))
        case .journal, .transcript, .capabilities, .session, .owner, .synchronized, .serverState, .unknown:
            break
        }
        return .accepted
    }

    private func conversationEvent(_ event: StreamSubscriptionEvent, conversationID id: String) async -> StreamItemDisposition {
        guard followed[id] != nil else { return .accepted }
        switch event {
        case .ended:
            followed.removeValue(forKey: id); ended.insert(id); transcripts.removeValue(forKey: id)
            await update(.ended(id))
        case .item(let item):
            switch item.payload {
            case .transcript(let value):
                guard value.transcript.conversationID == id else { return .accepted }
                let base: LibraryTranscript
                if let held = transcripts[id] { base = held }
                else { base = await store.snapshot().transcripts[id] ?? .init(conversationID: id) }
                let next = base.applying(value)
                transcripts[id] = next
                // Text as it is written stays here; a snapshot and a settled run are kept.
                if value.snapshot || next.activeRunID == nil { try? await store.cache(next) }
                await update(.transcript(id, next))
            case .capabilities(let value):
                await update(.capabilities(id, value.capabilities))
            case .session(let value):
                guard value.settings.conversationID == id else { return .accepted }
                await update(.session(id, value.settings))
            case .conversations, .pending, .journal, .owner, .library, .synchronized, .serverState, .unknown:
                break
            }
        }
        return .accepted
    }
}

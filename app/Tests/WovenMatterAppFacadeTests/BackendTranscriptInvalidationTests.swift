import Foundation
import LibraryClient
import Testing
import WorkspaceFixtures
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

/// The window's side of its connection to its own background server: how it
/// applies `server.state` and `conversation` items to what it shows.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct BackendTranscriptInvalidationTests {
    @Test func serverStateReloadsChatsWithoutWaitingForTheRestOfTheServer() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let id = try await fixture.database.createFixtureLocalACPSession(runtimeKind: .grokBuild,
            title: "Invalidation fixture", ownerDeviceID: UUID())
        await fixture.model.refreshConversation(id: id)
        let state = try #require(fixture.model.conversationState(for: id))

        // Settings cannot be read here (no background service), and the
        // prompt still appears: transcripts never wait for that worker.
        let run = try await fixture.database.beginLocalACPRun(conversationID: id, input: .init(text: "Visible fixture prompt"))
        fixture.model.applyServerState(scopes: [.settings, .usage], conversationIDs: [id, "unobserved-session"], reloadAll: false)
        try await waitUntil { state.content?.messages.contains { $0.role == "user" && $0.content == "Visible fixture prompt" } == true }
        #expect(fixture.model.conversationState(for: "unobserved-session") == nil, "an unloaded chat was read")

        try await fixture.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "First visible response.\n\n")
        fixture.model.applyServerState(scopes: [], conversationIDs: [id], reloadAll: false)
        try await waitUntil { state.messagePresentations[run.assistantMessageID]?.displayedBody == "First visible response.\n\n" }

        // `synchronized` (subscribe, reconnect) reads every loaded chat again.
        try await fixture.database.completeLocalACPRun(runID: run.runID)
        fixture.model.applyServerState(scopes: [], conversationIDs: [], reloadAll: true)
        try await waitUntil { state.content?.runs.first?.status == "completed" }
        #expect(state.content?.messages.filter { $0.role == "user" }.count == 1)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }

    @Test func liveTextReachesTheOpenChatAsItemsAndStructureFromTheProjection() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let id = try await fixture.database.createFixtureLocalACPSession(runtimeKind: .grokBuild,
            title: "Live fixture", ownerDeviceID: UUID())
        let run = try await fixture.database.beginLocalACPRun(conversationID: id, input: .init(text: "Stream something"))
        try await fixture.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "Stored start")
        await model.refreshConversation(id: id)
        let state = try #require(model.conversationState(for: id))
        model.windowLive.follows[id] = WindowLiveState.LiveConversation()

        func transcript(_ content: String?, snapshot: Bool, runs: [LibraryTranscriptRun] = [.init(id: run.runID, status: "running")]) -> StreamSubscriptionEvent {
            .item(.init(id: "s1", payload: .transcript(.init(transcript: .init(conversationID: id,
                messages: content.map { [.init(id: run.assistantMessageID, conversationID: id, runID: run.runID, role: "assistant", content: $0, status: "streaming")] } ?? [],
                activeRunID: run.runID, runs: runs), snapshot: snapshot))))
        }
        // A subscription starts from a snapshot: the chat reads its projection.
        model.receiveLiveConversation(transcript(nil, snapshot: true), conversationID: id)
        let follow = try #require(model.windowLive.follows[id])
        try await waitUntil { !follow.draining && follow.events.isEmpty && state.messagePresentations[run.assistantMessageID]?.source == "Stored start" }
        // Live text is applied from the item itself. It is deliberately not in
        // the database, so it can only have come from the stream.
        model.receiveLiveConversation(transcript("Streamed, not stored", snapshot: false), conversationID: id)
        try await waitUntil { state.messagePresentations[run.assistantMessageID]?.source == "Streamed, not stored" }
        #expect(state.content?.messages.first { $0.id == run.assistantMessageID }?.status == "streaming")

        // A changed run is structure: read from the projection, which has the stored text.
        try await fixture.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: ", then stored")
        try await fixture.database.completeLocalACPRun(runID: run.runID)
        model.receiveLiveConversation(transcript("Stored start, then stored", snapshot: false, runs: [.init(id: run.runID, status: "completed")]), conversationID: id)
        try await waitUntil { state.content?.runs.first?.status == "completed" && state.messagePresentations[run.assistantMessageID]?.source == "Stored start, then stored" }

        // A chat whose subscription the server ended (a session it does not
        // stream) goes back to being read for `server.state`.
        model.receiveLiveConversation(.ended(.init(.notFound, "This conversation is not running on this Mac.")), conversationID: id)
        try await waitUntil { model.windowLive.follows[id]?.ended == true }
        let next = try await fixture.database.beginLocalACPRun(conversationID: id, input: .init(text: "Again"))
        try await fixture.database.appendLocalACPAssistantChunk(runID: next.runID, chunk: "Second answer")
        model.applyServerState(scopes: [], conversationIDs: [id], reloadAll: false)
        try await waitUntil { state.messagePresentations[next.assistantMessageID]?.source == "Second answer" }
    }

    @Test func aSessionAnotherMachineRunsShowsItsItemsAndKeepsThemOverAnOlderSnapshot() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let model = fixture.model
        let id = "remote-chat"
        let workspace = ExecutionWorkspace(id: "linux-1", libraryID: "library", ownerDeviceID: "linux-1", kind: .linux, name: "Workstation")
        let saved = FederatedExecutionSnapshot(workspace: workspace, transcript: .init(conversationID: id), capability: nil,
            interactions: [], session: nil, online: true, error: nil)
        model.federatedExecutionOwners[id] = workspace.id
        model.storeFederatedSnapshot(saved, conversationID: id)
        model.windowLive.follows[id] = WindowLiveState.LiveConversation()

        let message = LibraryMessage(id: "m1", conversationID: id, role: "assistant", content: "Working on it", status: "streaming")
        let settings = SessionSettings(conversationID: id, model: "gpt-5.5-codex", thinking: "high", permission: nil, models: [],
            thinkingLevels: [], permissions: [], availableTools: [], enabledTools: [], canConfigure: true)
        let question = PendingInteraction(id: "q1", conversationID: id, runID: "r1", kind: .approval, title: "Run npm test?")
        for payload: StreamItem.Payload in [
            .transcript(.init(transcript: .init(conversationID: id, messages: [message], activeRunID: "r1"), snapshot: true)),
            .session(.init(settings: settings)), .pending(.init(interactions: [question])),
            .owner(.init(online: false, error: "Workstation is not connected.")), .synchronized,
        ] { model.receiveLiveConversation(.item(.init(id: "s7", payload: payload)), conversationID: id) }
        try await waitUntil { model.federatedExecutionSnapshots[id]?.online == false }
        let live = try #require(model.federatedExecutionSnapshots[id])
        #expect(live.transcript?.messages == [message] && live.transcript?.activeRunID == "r1")
        #expect(live.session == settings && live.interactions == [question])
        #expect(live.error == "Workstation is not connected.")

        // Live text: the whole message so far replaces it by ID.
        var longer = message; longer.content = "Working on it. Done."
        model.receiveLiveConversation(.item(.init(id: "s7", payload: .transcript(.init(transcript: .init(conversationID: id,
            messages: [longer], activeRunID: nil), snapshot: false)))), conversationID: id)
        try await waitUntil { model.federatedExecutionSnapshots[id]?.transcript?.messages.first?.content == "Working on it. Done." }

        // A snapshot the background service read earlier does not undo it.
        model.storeFederatedSnapshot(saved, conversationID: id)
        #expect(model.federatedExecutionSnapshots[id]?.transcript?.messages.first?.content == "Working on it. Done.")
        #expect(model.federatedExecutionSnapshots[id]?.session == settings)
    }

    /// A `server.state` the server keeps ending is subscribed again after a
    /// wait that grows (1 s doubling to 30 s), never at once in a loop.
    @Test func serverStateEndsAreSubscribedAgainWithBackoff() async throws {
        let fixture = try await FacadeFixture()
        defer { fixture.remove() }
        let model = fixture.model, live = model.windowLive
        let waits = DurationLog()
        live.retrySleep = { delay in await waits.add(delay) }
        // Not started: a subscription is only recorded until it opens.
        live.connection = StreamConnection { throw CancellationError() }
        for attempt in 1...7 {
            model.receiveServerState(.ended(nil), generation: live.generation)
            try await waitUntil { live.serverState != nil }
            #expect(await waits.all.count == attempt)
            live.serverState = nil
        }
        let all = await waits.all
        #expect(all[0] >= .milliseconds(750) && all[0] <= .milliseconds(1_250))
        // Jitter is ±25 %: the first six waits cannot overlap; later ones stay at the 30 s cap.
        let growing = Array(all.prefix(6))
        #expect(zip(growing, growing.dropFirst()).allSatisfy { $0 < $1 }, "\(all)")
        #expect(all.allSatisfy { $0 <= .seconds(30) } && all.last! >= .milliseconds(22_500))

        // An item resets it: the next end waits a second again.
        model.receiveServerState(.item(.init(id: "s1", payload: .synchronized)), generation: live.generation)
        model.receiveServerState(.ended(nil), generation: live.generation)
        try await waitUntil { live.serverState != nil }
        let reset = try #require(await waits.all.last)
        #expect(reset <= .milliseconds(1_250))
        await model.stopWindowStream()
    }

    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        if try await pollUntil(attempts: 300, interval: .milliseconds(10), { condition() }) { return }
        try #require(condition(), sourceLocation: sourceLocation)
    }
}

private actor DurationLog {
    private(set) var all: [Duration] = []
    func add(_ value: Duration) { all.append(value) }
}

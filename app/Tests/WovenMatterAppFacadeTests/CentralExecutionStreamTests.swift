import LibraryClient
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

/// A `stream.v1` workspace reaches this Mac on its stream: questions and
/// approvals, the open chat's transcript, capabilities and settings, and
/// commands. History arrives only by library sync. Nothing polls it.
@MainActor @Suite(.serialized)
struct CentralExecutionStreamTests {
    private struct Setup {
        let fixture: FacadeFixture
        let workspace: ExecutionWorkspace
        let conversationID: String
        let journalURL: URL
        let server: StreamFixtureServer
        let http: StreamFixtureHTTP
        let client: CentralExecutionClient
        let live: LiveChanges
    }

    private func setup(seedingOwner: Bool = false, alsoSeeding others: [String] = [],
                       retrySleep: @escaping @Sendable (Duration) async throws -> Void = { _ in await Task.yield() }) async throws -> Setup {
        let fixture = try await FacadeFixture()
        let identity = try await fixture.database.libraryIdentity()
        let workspace = try await fixture.database.registerExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            kind: .linux, name: "Build server", endpoint: URL(string: "https://server.fixture.ts.net/wovenmatter-execution/build"),
            capabilities: [StreamProtocol.capability], executionDeviceID: UUID().uuidString.lowercased())), deviceID: identity.hostDeviceID)
        let server = StreamFixtureServer()
        let http = StreamFixtureHTTP(workspace: workspace)
        let journalURL = fixture.directory.appending(path: "stream-commands.json")
        let conversationID = UUID().uuidString.lowercased()
        if seedingOwner {
            // The conversations' owner is known from the library, as library sync brings it.
            let ids = [conversationID] + others
            _ = try await fixture.database.ingestExecutionJournal(.init(libraryID: workspace.libraryID,
                entries: ids.enumerated().map { index, id in .init(workspaceID: workspace.id,
                    originSequence: Int64(index + 1), conversationID: id, kind: .conversation,
                    conversation: .init(id: id, title: "Chat \(index)", libraryID: workspace.libraryID, workspaceID: workspace.id)) }),
                deviceID: workspace.executionDeviceID!)
        }
        let client = try CentralExecutionClient(database: fixture.database, commandJournalURL: journalURL,
            provision: { _ in throw LibraryAPIError(code: "unexpected", message: "Nothing is provisioned for a member.") },
            makeTransport: { _ in http }, loadCredential: { _ in nil }, saveCredential: { _ in },
            makeSignedTransport: { _ in http },
            makeStream: { _ in { try server.connect() } },
            streamConfiguration: .init(pingInterval: .seconds(3600), requestTimeout: .seconds(5), retrySleep: retrySleep))
        let live = LiveChanges()
        client.onLive = { live.record($0) }
        return Setup(fixture: fixture, workspace: workspace, conversationID: conversationID, journalURL: journalURL,
                     server: server, http: http, client: client, live: live)
    }

    private func open(_ setup: Setup, socket index: Int = 0) async throws -> StreamFixtureSocket {
        try await until("socket \(index)") { setup.server.sockets.count > index }
        let socket = setup.server.sockets[index]
        await socket.push(.hello(.init(deviceID: setup.workspace.executionDeviceID!, libraryID: setup.workspace.libraryID,
            workspaceID: setup.workspace.id, serverTime: MemberRequestSignature.now(), capabilities: [StreamProtocol.capability])))
        try await until("online") { setup.client.onlineWorkspaces.contains(setup.workspace.id) }
        return socket
    }

    @Test func theWorkspaceStreamCarriesQuestionsAndNoHistory() async throws {
        let setup = try await setup(); defer { setup.fixture.remove() }
        let (client, workspace, id) = (setup.client, setup.workspace, setup.conversationID)
        await client.connectRegisteredWorkspaces()
        #expect(client.isStreamed(workspace.id))
        let socket = try await open(setup)
        try await until("workspace subscription") { await socket.subscriptions.count == 1 }
        let subscription = await socket.subscriptions[0]
        // No cursor: this Mac never asks for the workspace's journal.
        #expect(subscription.stream == "workspace" && subscription.params.after == nil)

        // A journal item, were one sent, is not history here: library sync is.
        let conversation = LibraryConversation(id: id, title: "Fix the build", libraryID: workspace.libraryID, workspaceID: workspace.id)
        await socket.push(.item(.init(id: subscription.id, seq: 1, payload: .journal(.init(entry: .init(workspaceID: workspace.id,
            originSequence: 1, conversationID: id, kind: .conversation, conversation: conversation))))))
        let interaction = PendingInteraction(id: "q1", conversationID: id, runID: "run", kind: .approval, title: "Run npm test?")
        await socket.push(.item(.init(id: subscription.id, payload: .pending(.init(interactions: [interaction])))))
        await socket.push(.item(.init(id: subscription.id, payload: .synchronized)))
        try await until("pending") { client.pending[workspace.id] == [interaction] }
        #expect(setup.live.all.contains(id))
        #expect(client.transcripts[id] == nil)
        #expect(try await client.workspace(conversationID: id) == nil)
        let journal = try WorkspaceJournal(file: setup.journalURL)
        let cached = await journal.snapshot()
        #expect(cached.entries.isEmpty && cached.directCursors.isEmpty)
        #expect(await socket.subscriptions.count == 1, "Nothing resubscribes for a journal")

        // Registry changes and time open nothing new and read nothing.
        await client.connectRegisteredWorkspaces()
        await client.connectRegisteredWorkspaces()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await setup.http.eventRequests == 0)
        #expect(await setup.http.pendingRequests == 0)
        #expect(await setup.http.transcriptRequests == 0)
        #expect(setup.server.sockets.count == 1)
        #expect(await socket.requests.isEmpty)
    }

    @Test func aMachineThatIsNotConnectedShowsItsLastKnownStateFromTheLibrary() async throws {
        // Reconnect attempts back off, as they do in the app.
        let setup = try await setup(seedingOwner: true, retrySleep: { _ in try await Task.sleep(for: .milliseconds(200)) })
        defer { setup.fixture.remove() }
        let (client, workspace, id, model) = (setup.client, setup.workspace, setup.conversationID, setup.fixture.model)
        _ = try await setup.fixture.database.ingestExecutionJournal(.init(libraryID: workspace.libraryID, entries: [
            .init(workspaceID: workspace.id, originSequence: 2, conversationID: id, kind: .transcript, transcript: .init(conversationID: id, messages: [
                .init(id: UUID().uuidString.lowercased(), conversationID: id, role: "user", content: "Run the tests"),
                .init(id: UUID().uuidString.lowercased(), conversationID: id, role: "assistant", content: "All 214 tests pass.")
            ]))]), deviceID: workspace.executionDeviceID!)
        setup.server.offline = true
        model.federatedExecutionClient = client
        await client.connectRegisteredWorkspaces()
        try await until("waiting") { client.errors[workspace.id] != nil }

        await #expect(throws: LibraryAPIError.self) { try await client.refresh(conversationID: id) }
        #expect(client.transcripts[id]?.messages.map(\.content) == ["Run the tests", "All 214 tests pass."])
        #expect(client.transcripts[id]?.olderCursor?.hasPrefix("library:") ?? true)
        let snapshot = try await model.performFederatedExecution(.refresh(conversationID: id))
        #expect(!snapshot.online)
        #expect(snapshot.error?.isEmpty == false)
        #expect(snapshot.transcript?.messages.count == 2)

        // While it stays away, only the stream's own reconnects happen: no reads.
        try await Task.sleep(for: .milliseconds(600))
        #expect(await setup.http.eventRequests == 0)
        #expect(await setup.http.pendingRequests == 0)
        #expect(await setup.http.transcriptRequests == 0)

        // When it is back, the chat follows its stream again.
        setup.server.offline = false
        let socket = try await open(setup)
        let refresh = Task { try await client.refresh(conversationID: id) }
        try await until("conversation subscription") { await socket.subscriptions.contains { $0.stream == "conversation" } }
        let subscription = try #require(await socket.subscriptions.first { $0.stream == "conversation" })
        await socket.push(.item(.init(id: subscription.id, payload: .transcript(.init(transcript: .init(conversationID: id, messages: [
            .init(id: "m3", conversationID: id, role: "assistant", content: "Live again", status: "streaming")
        ], activeRunID: "run"), snapshot: true)))))
        await socket.push(.item(.init(id: subscription.id, payload: .synchronized)))
        try await refresh.value
        #expect(client.onlineWorkspaces.contains(workspace.id))
        #expect(client.transcripts[id]?.messages.last?.content == "Live again")
    }

    @Test func theOpenChatsTranscriptUpdatesMergeByID() async throws {
        let setup = try await setup(seedingOwner: true); defer { setup.fixture.remove() }
        let (client, id) = (setup.client, setup.conversationID)
        let refresh = Task { try await client.refresh(conversationID: id) }
        let socket = try await open(setup)
        try await until("conversation subscription") { await socket.subscriptions.contains { $0.stream == "conversation" } }
        let subscription = try #require(await socket.subscriptions.first { $0.stream == "conversation" })
        #expect(subscription.params.conversationID == id)
        await socket.push(.item(.init(id: subscription.id, payload: .transcript(.init(transcript: .init(conversationID: id, messages: [
            .init(id: "m1", conversationID: id, role: "user", content: "Run the tests"),
            .init(id: "m2", conversationID: id, role: "assistant", content: "All 214 tests pass so f", status: "streaming")
        ], activeRunID: "run", olderCursor: "c-20", runs: [.init(id: "run", status: "running")]), snapshot: true)))))
        let capability = HarnessCapabilities(id: "codex", runtimeKind: "codex", displayName: "Codex", available: true, canSteer: true, canStop: true)
        await socket.push(.item(.init(id: subscription.id, payload: .capabilities(.init(capabilities: capability)))))
        await socket.push(.item(.init(id: subscription.id, payload: .synchronized)))
        try await refresh.value
        #expect(client.transcripts[id]?.olderCursor == "owner:c-20")
        #expect(client.capabilities[id] == capability)

        await socket.push(.item(.init(id: subscription.id, payload: .transcript(.init(transcript: .init(conversationID: id, messages: [
            .init(id: "m2", conversationID: id, role: "assistant", content: "All 214 tests pass so far."),
            .init(id: "m3", conversationID: id, role: "assistant", content: "Done.")
        ], activeRunID: nil, runs: [.init(id: "run", status: "completed")]), snapshot: false)))))
        try await until("update") { client.transcripts[id]?.messages.count == 3 }
        let transcript = try #require(client.transcripts[id])
        #expect(transcript.messages.map(\.content) == ["Run the tests", "All 214 tests pass so far.", "Done."])
        #expect(transcript.activeRunID == nil && transcript.runs == [.init(id: "run", status: "completed")])
        #expect(transcript.olderCursor == "owner:c-20", "An update keeps the marked older-page cursor")
        #expect(setup.live.all.contains(id))
        // A second refresh reads what the stream holds; nothing goes over HTTP.
        try await client.refresh(conversationID: id)
        #expect(await setup.http.transcriptRequests == 0)
        #expect(await setup.http.eventRequests == 0)

        await client.unwatch(id)
        try await until("cancel") { await socket.cancels.contains(subscription.id) }
    }

    @Test func commandsUseTheSocketAndALostReplyIsResolvedByReceipt() async throws {
        let setup = try await setup(); defer { setup.fixture.remove() }
        let (client, workspace, id) = (setup.client, setup.workspace, setup.conversationID)
        await client.connectRegisteredWorkspaces()
        let first = try await open(setup)
        let send = Task { try await client.send(to: workspace, conversationID: id, text: "Exactly once") }
        try await until("command") { await first.requests.contains { $0.method == "execution.command" } }
        let request = try #require(await first.requests.first { $0.method == "execution.command" })
        let command = try request.decodeParams(StreamCommandParams.self).command
        #expect(command.text == "Exactly once" && command.workspaceID == workspace.id && command.libraryID == workspace.libraryID)
        await first.serverClose(code: 1006)
        await #expect(throws: LibraryAPIError.self) { _ = try await send.value }
        let journal = try WorkspaceJournal(file: setup.journalURL)
        #expect(await journal.commandRecords(workspaceID: workspace.id).first?.receipt?.status == .outcomeUnknown)

        // After reconnecting, the outcome is asked for; the command is not resent.
        let second = try await open(setup, socket: 1)
        try await until("receipt request") { await second.requests.contains { $0.method == "execution.receipt" } }
        let ask = try #require(await second.requests.first { $0.method == "execution.receipt" })
        #expect(try ask.decodeParams(StreamReceiptParams.self).commandID == command.commandID)
        let accepted = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .accepted,
                                             conversationID: id, workspaceID: workspace.id)
        await second.push(.response(try .init(id: ask.id, encoding: accepted)))
        try await until("resolved") {
            await (try? WorkspaceJournal(file: setup.journalURL))?.commandRecords(workspaceID: workspace.id).first?.receipt?.status == .accepted
        }
        #expect(await second.requests.allSatisfy { $0.method != "execution.command" })

        // A later command goes over the socket too, and its receipt is checked first only when retried.
        let stop = Task { try await client.submit(.init(deviceID: command.deviceID, kind: .stop, conversationID: id, runID: "run",
                                                        libraryID: workspace.libraryID, workspaceID: workspace.id), workspace: workspace) }
        try await until("stop") { await second.requests.contains { $0.method == "execution.command" } }
        let stopRequest = try #require(await second.requests.first { $0.method == "execution.command" })
        let stopCommand = try stopRequest.decodeParams(StreamCommandParams.self).command
        await second.push(.response(try .init(id: stopRequest.id, encoding: LibraryCommandReceipt(commandID: stopCommand.commandID,
            deviceID: stopCommand.deviceID, status: .completed, workspaceID: workspace.id))))
        #expect(try await stop.value.status == .completed)
        #expect(await setup.http.commands == 0)
        #expect(await setup.http.receiptRequests == 0)
    }

    /// Answers every chat's `conversation` subscription with a snapshot, as a
    /// workspace's server does, until cancelled.
    private func serveConversations(_ socket: StreamFixtureSocket) -> Task<Void, Never> {
        Task {
            var answered: Set<String> = []
            while !Task.isCancelled {
                for subscription in await socket.subscriptions where subscription.stream == "conversation" && !answered.contains(subscription.id) {
                    answered.insert(subscription.id)
                    let id = subscription.params.conversationID ?? ""
                    await socket.push(.item(.init(id: subscription.id, payload: .transcript(.init(transcript: .init(conversationID: id, messages: [
                        .init(id: id + "-m1", conversationID: id, role: "user", content: "Hello")
                    ]), snapshot: true)))))
                    await socket.push(.item(.init(id: subscription.id, payload: .synchronized)))
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    @Test func everyChatOpenInAWindowStaysLive() async throws {
        let others = (0..<14).map { _ in UUID().uuidString.lowercased() }
        let setup = try await setup(seedingOwner: true, alsoSeeding: others); defer { setup.fixture.remove() }
        let client = setup.client
        let open = [setup.conversationID] + others.prefix(5)
        // Six chats open in windows: more than any number the client keeps for other reasons.
        for id in open { client.hold(id) }
        let first = Task { try await client.refresh(conversationID: open[0]) }
        let socket = try await self.open(setup)
        let server = serveConversations(socket)
        defer { server.cancel() }
        try await first.value
        for id in open.dropFirst() { try await client.refresh(conversationID: id) }
        #expect(Set(client.watchedConversationIDs) == Set(open))

        // Chats read but not open (an agent's status, a send) are bounded; the
        // least recently viewed of those closes first, never an open one.
        let unheld = Array(others.suffix(8 + 1))
        for id in unheld { try await client.refresh(conversationID: id) }
        #expect(client.watchedConversationIDs.count == open.count + CentralExecutionClient.maximumUnheldWatches)
        #expect(Set(open).isSubset(of: client.watchedConversationIDs))
        #expect(!client.watchedConversationIDs.contains(unheld[0]))
        let subscriptions = await socket.subscriptions.filter { $0.stream == "conversation" }
        let cancelled = Set(await socket.cancels)
        #expect(subscriptions.filter { cancelled.contains($0.id) }.compactMap(\.params.conversationID) == [unheld[0]])

        // Every open chat still takes its live updates.
        for id in open {
            let subscription = try #require(subscriptions.first { $0.params.conversationID == id })
            await socket.push(.item(.init(id: subscription.id, payload: .transcript(.init(transcript: .init(conversationID: id, messages: [
                .init(id: id + "-m2", conversationID: id, role: "assistant", content: "Live", status: "streaming")
            ], activeRunID: "run"), snapshot: false)))))
        }
        try await until("every open chat updated") { open.allSatisfy { client.transcripts[$0]?.messages.count == 2 } }

        // Viewing the evicted chat again subscribes it again.
        try await client.refresh(conversationID: unheld[0])
        #expect(client.watchedConversationIDs.last == unheld[0])
        // A closed chat is no longer held: it counts with the others.
        client.release(open[1])
        await client.unwatch(open[1])
        #expect(!client.watchedConversationIDs.contains(open[1]))
    }

    @Test func aDisclosureReadsTheActivityFromItsOwnersDetailsRoute() async throws {
        let setup = try await setup(seedingOwner: true); defer { setup.fixture.remove() }
        let (client, id, model) = (setup.client, setup.conversationID, setup.fixture.model)
        let full = AgentRunActivity(id: "run:edit", kind: .tool, title: "Edit app.swift", status: "completed", toolName: "edit",
            content: "Edited", changes: [.init(path: "app.swift", oldText: "a", newText: "b")], rawInputJSON: #"{"path":"app.swift"}"#)
        let projection = String(decoding: try JSONEncoder().encode(full), as: UTF8.self)
        await setup.http.setDetails(.init(id: "run:edit", runID: "run", title: "Edit app.swift", status: "completed", projectionJSON: projection))
        let direct = try await client.activityDetails(conversationID: id, runID: "run", activityID: "run:edit")
        #expect(direct.projectionJSON == projection)
        #expect(await setup.http.detailRequests == [[id, "run", "run:edit"]])

        // The window's view loads it through the same member route, once per version.
        model.federatedExecutionClient = client
        model.federatedExecutionOwners[id] = setup.workspace.id
        let compact = full.presentationSummary(version: 3)
        let summary = String(decoding: try JSONEncoder().encode(compact), as: UTF8.self)
        model.federatedExecutionSnapshots[id] = .init(workspace: setup.workspace, transcript: .init(conversationID: id, messages: [
            .init(id: "u", conversationID: id, runID: "run", role: "user", content: "Edit it"),
            .init(id: "run", conversationID: id, runID: "run", role: "assistant", content: "Done", status: "completed")
        ], activities: [.init(id: "run:edit", runID: "run", title: "Edit app.swift", status: "completed", projectionJSON: summary, sequence: 1)],
            runs: [.init(id: "run", status: "completed")]), capability: nil, interactions: [], session: nil, online: true)
        await model.renderRemoteConversationNow(id)
        let shown = try #require(model.conversationState(for: id)?.runActivities.first?.activity)
        #expect(shown.detailsAvailable == true && shown.rawInputJSON == nil && shown.changes.first?.newText == "")
        let loaded = try await model.remoteActivityDetails(conversationID: id, runID: "run", activityID: "run:edit")
        #expect(loaded == full)
        _ = try await model.remoteActivityDetails(conversationID: id, runID: "run", activityID: "run:edit")
        #expect(await setup.http.detailRequests.count == 2, "A settled activity's details are read once per version")
    }
}

@MainActor private func until(_ what: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for \(what)")
    throw CancellationError()
}

@MainActor private final class LiveChanges {
    private(set) var all: Set<String> = []
    func record(_ ids: Set<String>) { all.formUnion(ids) }
}

/// One in-process socket; the test plays the workspace's server.
private actor StreamFixtureSocket: StreamTransport {
    private(set) var sent: [StreamFrame] = []
    private var inbox: [Result<StreamFrame, any Error>] = []
    private var receiver: CheckedContinuation<StreamFrame, any Error>?
    private var closed = false
    func receive() async throws -> StreamFrame {
        if !inbox.isEmpty { return try inbox.removeFirst().get() }
        if closed { throw StreamTransportClosed() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func send(_ frame: StreamFrame) throws {
        guard !closed else { throw StreamTransportClosed() }
        sent.append(frame)
    }
    func ping() {}
    func close(_ code: StreamProtocol.CloseCode) { serverClose(code: code.rawValue) }
    func push(_ frame: StreamFrame) { deliver(.success(frame)) }
    func serverClose(code: Int?) {
        guard !closed else { return }
        closed = true
        deliver(.failure(StreamTransportClosed(code: code)))
    }
    private func deliver(_ result: Result<StreamFrame, any Error>) {
        if let receiver { self.receiver = nil; receiver.resume(with: result) } else { inbox.append(result) }
    }
    var subscriptions: [StreamSubscribe] { sent.compactMap { if case .subscribe(let value) = $0 { value } else { nil } } }
    var requests: [StreamRequest] { sent.compactMap { if case .request(let value) = $0 { value } else { nil } } }
    var cancels: [String] { sent.compactMap { if case .cancel(let value) = $0 { value.id } else { nil } } }
}

private final class StreamFixtureServer: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [StreamFixtureSocket] = []
    private var unreachable = false
    var sockets: [StreamFixtureSocket] { lock.withLock { opened } }
    /// The machine cannot be reached: every connection attempt fails.
    var offline: Bool {
        get { lock.withLock { unreachable } }
        set { lock.withLock { unreachable = newValue } }
    }
    func connect() throws -> any StreamTransport {
        try lock.withLock {
            if unreachable { throw URLError(.cannotConnectToHost) }
            let socket = StreamFixtureSocket(); opened.append(socket); return socket
        }
    }
}

/// The workspace's HTTP routes: only identity, providers and reads may be used.
private actor StreamFixtureHTTP: ExecutionWorkspaceTransport, ExecutionActivityDetailsReading {
    let workspace: ExecutionWorkspace
    var eventRequests = 0, pendingRequests = 0, transcriptRequests = 0, commands = 0, receiptRequests = 0
    /// Each details read: (conversation, run, activity).
    var detailRequests: [[String]] = []
    var details: [String: LibraryActivity] = [:]
    init(workspace: ExecutionWorkspace) { self.workspace = workspace }
    func setDetails(_ value: LibraryActivity) { details[value.id] = value }
    func activityDetails(_ id: String, runID: String, activityID: String) throws -> LibraryActivity {
        detailRequests.append([id, runID, activityID])
        guard let value = details[activityID] else { throw MobileConnectionError.http(404, "No such activity.") }
        return value
    }
    func identity() -> ExecutionWorkspace { workspace }
    func providers() -> [HarnessCapabilities] { [] }
    func pending() -> [PendingInteraction] { pendingRequests += 1; return [] }
    func command(_ command: LibraryCommand) -> LibraryCommandReceipt {
        commands += 1
        return .init(commandID: command.commandID, deviceID: command.deviceID, status: .completed)
    }
    func receipt(_ id: String) -> LibraryCommandReceipt? { receiptRequests += 1; return nil }
    func events(after: Int64) -> ExecutionJournalPage { eventRequests += 1; return .init(libraryID: workspace.libraryID, cursor: after) }
    func conversations() -> [LibraryConversation] { [] }
    func transcript(_ id: String) -> LibraryTranscript { transcriptRequests += 1; return .init(conversationID: id) }
    func readWorkspace(_ request: LibraryWorkspaceRead) throws -> LibraryWorkspaceResult {
        throw LibraryAPIError(code: "unavailable", message: "Not in this fixture.")
    }
}

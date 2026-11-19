import Foundation
import Network
import Testing
import WovenMatterClient
@testable import WovenMatterAppFacade

/// Speaks Pi Bot's WebSocket framing over a real loopback socket, so the client, the model and
/// the conversation run as they do against the server.
private final class ScriptedPiBot: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var received: [[String: Any]] = []
    private var handlers: [String: @Sendable ([String: Any]) throws -> Any] = [:]
    private(set) var port = 0
    /// What the runtime says it can do; a runtime from before the Forum names neither addition.
    private let capabilities: [String]

    init(capabilities: [String] = ["groups", "woven.mcp", "message.context"]) async throws {
        self.capabilities = capabilities
        port = try await start(on: .any)
    }

    private func start(on requested: NWEndpoint.Port) async throws -> Int {
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requested)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state, let port = listener?.port { continuation.yield(Int(port.rawValue)) }
        }
        listener.start(queue: .global())
        lock.withLock { self.listener = listener }
        return await stream.first { _ in true } ?? 0
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: .global())
        write(connection, ["type": "hello", "version": "0.1.0", "protocol": 1, "installationId": "fixture", "environment": "mac-vm",
                           "capabilities": capabilities])
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(body, on: connection) }
            self.receive(connection)
        }
    }

    private func handle(_ body: [String: Any], on connection: NWConnection) {
        lock.withLock { received.append(body) }
        let id = body["id"] ?? NSNull()
        let type = body["type"] as? String ?? ""
        let handler = lock.withLock { handlers[type] }
        do {
            write(connection, ["type": "result", "id": id, "data": try handler?(body) ?? [:]])
        } catch {
            write(connection, ["type": "error", "id": id, "message": "\(error)"])
        }
    }

    private func write(_ connection: NWConnection, _ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func on(_ type: String, _ handler: @escaping @Sendable ([String: Any]) throws -> Any) {
        lock.withLock { handlers[type] = handler }
    }

    func push(_ body: [String: Any]) {
        for connection in lock.withLock({ connections }) { write(connection, body) }
    }

    var allRequests: [[String: Any]] { lock.withLock { received } }

    func requests(_ type: String) -> [[String: Any]] {
        lock.withLock { received.filter { $0["type"] as? String == type } }
    }

    func dropConnections() {
        let dropped = lock.withLock { () -> [NWConnection] in
            defer { connections = [] }
            return connections
        }
        dropped.forEach { $0.cancel() }
    }

    deinit {
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }
}

private func entry(_ id: Int, _ role: String, _ text: String, conversation: Int = 5) -> [String: Any] {
    ["id": id, "conversationId": conversation, "role": role, "text": text]
}

private struct Rejected: Error, CustomStringConvertible { var description: String { "The server refused it." } }

@MainActor
private func eventually(_ what: String = "condition", _ condition: () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(what)")
    throw CancellationError()
}

@MainActor
@Suite(.serialized)
struct BotConversationControllerTests {
    private func machine(_ server: ScriptedPiBot, id: String = "fixture") -> BotMachine {
        BotMachine(id: id, name: "Fixture", kind: .thisMac, state: .ready,
                   socket: .init(url: URL(string: "ws://127.0.0.1:\(server.port)/ws")!, bearer: "fixture-token"))
    }

    private func connected(_ server: ScriptedPiBot) async throws -> BotMachineSession {
        server.on("bots.list") { _ in ["bots": []] }
        server.on("groups.list") { _ in ["groups": []] }
        server.on("threads.list") { _ in ["threads": []] }
        server.on("onboarding.status") { _ in
            ["adminId": "admin", "profileId": "default", "mainModel": "m", "mainModelAvailable": true, "signedIn": true, "needed": false]
        }
        let bots = BotMachineSession(machineID: "fixture", drafts: BotDraftStore())
        bots.apply(machine(server))
        // Wait for hello as well: it reopens attached conversations, which would race the test.
        try await eventually("connection") { bots.isConnected && bots.health != nil }
        return bots
    }

    private func openMain(_ server: ScriptedPiBot, entries: [[String: Any]] = [], running: Bool = false) {
        nonisolated(unsafe) let history = entries
        server.on("conversation.open") { _ in
            ["subscriptionId": 9, "botId": "a", "conversationId": 5, "mainConversationId": 5, "entries": history, "running": running]
        }
    }

    @Test func historyThenTheStreamThenTheFinalEntry() async throws {
        let server = try await ScriptedPiBot()
        openMain(server, entries: [entry(1, "user", "hi")])
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        #expect(controller.state.entries.map(\.id) == [1])

        func event(_ body: [String: Any]) { server.push(["type": "event", "botId": "a", "conversationId": 5, "event": body]) }
        event(["kind": "run", "state": "start"])
        event(["kind": "assistant_start", "text": "He"])
        event(["kind": "delta", "text": "llo"])
        try await eventually("streaming") { controller.state.streaming == "Hello" }
        #expect(controller.state.running)
        event(["kind": "entry", "entry": entry(2, "assistant", "Hello")])
        event(["kind": "run", "state": "end"])
        try await eventually("end of run") { !controller.state.running && controller.state.streaming == nil }
        #expect(controller.state.entries.map(\.id) == [1, 2])
        // Titles may have appeared while it ran.
        try await eventually("threads refresh") { server.requests("threads.list").count >= 2 }
    }

    @Test func eventsForAnotherConversationAreIgnored() async throws {
        let server = try await ScriptedPiBot()
        openMain(server)
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        server.push(["type": "event", "botId": "a", "conversationId": 6, "event": ["kind": "assistant_start", "text": "other"]])
        server.push(["type": "event", "botId": "b", "conversationId": 5, "event": ["kind": "assistant_start", "text": "other"]])
        server.push(["type": "event", "botId": "a", "conversationId": 5, "event": ["kind": "assistant_start", "text": "mine"]])
        try await eventually("own event") { controller.state.streaming != nil }
        #expect(controller.state.streaming == "mine")
    }

    @Test func aSentMessageIsPendingUntilItsEntryArrives() async throws {
        let server = try await ScriptedPiBot()
        openMain(server)
        server.on("message.send") { _ in ["conversationId": 5, "submissionId": 1] }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }

        #expect(await controller.send(text: "hello", context: "open tabs"))
        #expect(controller.state.pending.map(\.text) == ["hello"])
        let sent = try #require(server.requests("message.send").first)
        #expect(sent["conversationId"] as? Int == 5)
        #expect(sent["context"] as? String == "open tabs")
        server.push(["type": "event", "botId": "a", "conversationId": 5, "event": ["kind": "entry", "entry": entry(3, "user", "hello")]])
        try await eventually("entry") { controller.state.pending.isEmpty }
    }

    @Test func aRefusedMessageLeavesNothingPendingAndSaysWhy() async throws {
        let server = try await ScriptedPiBot()
        openMain(server)
        server.on("message.send") { _ in throw Rejected() }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        #expect(await controller.send(text: "hello", context: nil) == false)
        #expect(controller.state.pending.isEmpty)
        #expect(controller.error == "The server refused it.")
        #expect(await controller.send(text: String(repeating: "x", count: 100_001), context: nil) == false)
        #expect(controller.error?.contains("100,000") == true)
    }

    @Test func stoppingDropsQueuedMessages() async throws {
        let server = try await ScriptedPiBot()
        openMain(server, running: true)
        server.on("message.send") { _ in ["conversationId": 5, "submissionId": 1] }
        server.on("conversation.abort") { _ in ["conversationId": 5, "stopped": true] }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        #expect(await controller.send(text: "queued", context: nil))
        await controller.stop()
        #expect(controller.state.pending.isEmpty)
        #expect(server.requests("conversation.abort").first?["conversationId"] as? Int == 5)
    }

    @Test func theLastViewerClosesTheSubscription() async throws {
        let server = try await ScriptedPiBot()
        openMain(server)
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        controller.attach()
        try await eventually("ready") { controller.isReady }
        #expect(server.requests("conversation.open").count == 1)
        controller.detach()
        #expect(server.requests("conversation.close").isEmpty)
        controller.detach()
        try await eventually("close") { !server.requests("conversation.close").isEmpty }
        #expect(server.requests("conversation.close").first?["subscriptionId"] as? Int == 9)
    }

    @Test func leavingBeforeTheOpenAnswersStillClosesIt() async throws {
        let server = try await ScriptedPiBot()
        server.on("conversation.open") { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return ["subscriptionId": 9, "botId": "a", "conversationId": 5, "mainConversationId": 5, "entries": [], "running": false]
        }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("open sent") { !server.requests("conversation.open").isEmpty }
        controller.detach()
        try await eventually("close") { !server.requests("conversation.close").isEmpty }
        #expect(server.requests("conversation.close").first?["subscriptionId"] as? Int == 9)
    }

    @Test func aSupersededOpenIsClosedBeforeTheNextOneGoesOut() async throws {
        let server = try await ScriptedPiBot()
        server.on("conversation.open") { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return ["subscriptionId": 9, "botId": "a", "conversationId": 5, "mainConversationId": 5, "entries": [], "running": false]
        }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("first open") { server.requests("conversation.open").count == 1 }
        controller.detach()
        controller.attach()
        try await eventually("ready") { controller.isReady }
        let order = server.allRequests.compactMap { $0["type"] as? String }.filter { $0.hasPrefix("conversation.") }
        #expect(order == ["conversation.open", "conversation.close", "conversation.open"])
    }

    @Test func aReconnectReopensAndKeepsWhatWasOnScreen() async throws {
        let server = try await ScriptedPiBot()
        openMain(server, entries: [entry(1, "user", "hi")])
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        openMain(server, entries: [entry(1, "user", "hi"), entry(2, "assistant", "finished while away")])

        server.dropConnections()
        try await eventually("drop") { !controller.isReady }
        #expect(controller.state.entries.map(\.id) == [1])
        try await eventually("reopen") { controller.isReady }
        #expect(server.requests("conversation.open").count == 2)
        #expect(controller.state.entries.map(\.id) == [1, 2])
    }

    @Test func aRunThatEndedWhileAwayDoesNotLookRunning() async throws {
        let server = try await ScriptedPiBot()
        openMain(server, entries: [entry(1, "user", "hi")], running: true)
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        server.push(["type": "event", "botId": "a", "conversationId": 5, "event": ["kind": "assistant_start", "text": "partial"]])
        try await eventually("stream") { controller.state.streaming == "partial" }
        controller.detach()
        openMain(server, entries: [entry(1, "user", "hi"), entry(2, "assistant", "done")], running: false)

        controller.attach()
        try await eventually("reopen") { controller.state.entries.count == 2 }
        #expect(!controller.state.running)
        #expect(controller.state.streaming == nil)
    }

    @Test func aFailedOpenLeavesTheComposerOffAndRetries() async throws {
        let server = try await ScriptedPiBot()
        server.on("conversation.open") { _ in throw Rejected() }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("error") { controller.error == "The server refused it." }
        #expect(!controller.isReady)
        openMain(server)
        try await eventually("retry") { controller.isReady }
    }

    @Test func theOldSubscriptionsEventsDontJoinAReopen() async throws {
        let server = try await ScriptedPiBot()
        openMain(server, running: true)
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        controller.detach()
        controller.attach()
        // Still ahead of the queued close and open: it belongs to the old subscription.
        controller.receive(conversationID: 5, .delta("old"))
        try await eventually("reopen") { controller.isReady }
        #expect(controller.state.streaming == nil)
    }

    @Test func opensAndClosesRunInOrder() async throws {
        let server = try await ScriptedPiBot()
        openMain(server)
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        controller.detach()
        controller.attach()
        try await eventually("ready") { controller.isReady }
        // The first open never went out, so the only subscription is the one on screen.
        #expect(server.requests("conversation.open").count == 1)
        #expect(server.requests("conversation.close").isEmpty)
    }

    @Test func eventsThatOvertakeTheOpenAreKept() async throws {
        let server = try await ScriptedPiBot()
        server.on("conversation.open") { _ in
            Thread.sleep(forTimeInterval: 0.2)
            return ["subscriptionId": 9, "botId": "a", "conversationId": 5, "mainConversationId": 5,
                    "entries": [entry(1, "user", "hi")], "running": false]
        }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("open sent") { !server.requests("conversation.open").isEmpty }
        // Delivered while the open is still unanswered on this actor.
        controller.receive(conversationID: 5, .entry(PiBotDisplayEntry(id: 2, conversationId: 5, role: "assistant", text: "fast")))
        controller.receive(conversationID: 6, .entry(PiBotDisplayEntry(id: 3, conversationId: 6, role: "assistant", text: "elsewhere")))
        try await eventually("ready") { controller.isReady }
        #expect(controller.state.entries.map(\.id) == [1, 2])
    }

    @Test func aThreadShowsOnlyItsOwnEntriesAndItsOrigin() async throws {
        let server = try await ScriptedPiBot()
        server.on("conversation.open") { _ in
            ["botId": "a", "conversationId": 7, "mainConversationId": 5, "running": false,
             "threadOrigin": entry(2, "assistant", "origin"),
             "entries": [entry(2, "assistant", "origin"), entry(8, "user", "in thread", conversation: 7)]]
        }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: 7)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        #expect(controller.isThread)
        #expect(controller.origin?.id == 2)
        #expect(controller.visibleEntries.map(\.id) == [8])
    }

    @Test func startingAThreadForksFromTheViewedConversation() async throws {
        let server = try await ScriptedPiBot()
        openMain(server, entries: [entry(1, "assistant", "hi")])
        server.on("thread.fork") { _ in
            ["thread": ["conversationId": 7, "parentConversationId": 5, "forkedAt": 1, "createdAt": "2026-01-01T00:00:00Z"]]
        }
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
        try await eventually("ready") { controller.isReady }
        let thread = await controller.startThread(from: controller.state.entries[0])
        #expect(thread?.conversationId == 7)
        #expect(server.requests("thread.fork").first?["entryId"] as? Int == 1)
    }

    @Test func movingToAnotherServerForgetsConversations() async throws {
        let server = try await ScriptedPiBot()
        openMain(server)
        let bots = try await connected(server)
        let first = bots.conversation(botID: "a", conversationID: nil)
        first.attach()
        try await eventually("ready") { first.isReady }

        let other = try await ScriptedPiBot()
        openMain(other)
        other.on("bots.list") { _ in ["bots": []] }
        other.on("groups.list") { _ in ["groups": []] }
        other.on("onboarding.status") { _ in ["adminId": "x", "profileId": "d", "mainModel": "m", "mainModelAvailable": false, "signedIn": false, "needed": true] }
        // The same machine reached at a new socket is a different runtime.
        bots.apply(machine(server))
        bots.apply(machine(other))
        try await eventually("new connection") { bots.isConnected && bots.onboarding?.needed == true }
        #expect(bots.conversation(botID: "a", conversationID: nil) !== first)
    }

    @Test func theSocketCarriesTheMachinesBearer() async throws {
        let server = try await ScriptedPiBot()
        let bots = try await connected(server)
        #expect(bots.isConnected && bots.health?.environment == "mac-vm")
    }

    @Test func updateProgressReachesTheSession() async throws {
        let server = try await ScriptedPiBot()
        let bots = try await connected(server)
        server.on("runtime.status") { _ in ["version": "0.2.0", "environment": "mac-vm", "bots": 1] }
        server.on("runtime.update") { _ in ["started": true] }
        await bots.updateBots()
        #expect(bots.updating && server.requests("runtime.update").count == 1)
        server.push(["type": "runtime.update", "botId": "a", "phase": "updating"])
        try await eventually("progress") { bots.progress?.phase == "updating" }
        server.push(["type": "bots.environment.changed", "botId": "a", "state": "running"])
        try await eventually("environment") { bots.environmentStates["a"] == "running" }
        server.push(["type": "runtime.update", "phase": "done"])
        try await eventually("status") { !bots.updating && bots.runtimeStatus?.version == "0.2.0" }
    }

    @Test func memoryChangesReachObserversUntilTheyStop() async throws {
        let server = try await ScriptedPiBot()
        let bots = try await connected(server)
        var changed: [String] = []
        let token = bots.observeMemory { changed.append($0) }
        server.push(["type": "memory.changed", "botId": "a"])
        try await eventually("memory change") { changed == ["a"] }
        bots.stopObservingMemory(token)
        server.push(["type": "memory.changed", "botId": "b"])
        try await Task.sleep(for: .milliseconds(100))
        #expect(changed == ["a"])
    }
}

// MARK: - The Forum

private func forumPost(_ id: Int, _ author: String = "bot", _ text: String = "x", room: Int = 1, name: String = "Ada",
                       thread: [String: Any]? = nil) -> [String: Any] {
    var post: [String: Any] = ["id": id, "roomId": room, "author": author, "name": name, "text": text,
                               "createdAt": "2026-11-19T09:00:00.000Z"]
    if author == "bot" { post["botId"] = "a" }
    if let thread { post["thread"] = thread }
    return post
}

@MainActor
@Suite(.serialized)
struct ForumRoomControllerTests {
    private static let withForum = ["groups", "woven.mcp", "message.context", "forum", "user.name"]

    private func connected(_ server: ScriptedPiBot, forum: [String: Any]? = nil) async throws -> BotMachineSession {
        server.on("bots.list") { _ in ["bots": [["id": "a", "name": "Ada", "createdAt": "", "kind": "bot", "manager": false, "orchestrator": false]]] }
        server.on("groups.list") { _ in ["groups": []] }
        server.on("onboarding.status") { _ in
            ["adminId": "admin", "profileId": "default", "mainModel": "m", "mainModelAvailable": true, "signedIn": true, "needed": false]
        }
        nonisolated(unsafe) let state = forum ?? ["mainRoomId": 1, "paused": false, "latestPostId": 0,
                                                 "bots": [["botId": "a", "active": true]], "threads": []]
        server.on("forum.get") { _ in state }
        server.on("user.get") { _ in ["name": "Trey"] }
        let bots = BotMachineSession(machineID: "fixture", drafts: BotDraftStore())
        bots.apply(BotMachine(id: "fixture", name: "Fixture", kind: .thisMac, state: .ready,
                              socket: .init(url: URL(string: "ws://127.0.0.1:\(server.port)/ws")!, bearer: "fixture-token")))
        try await eventually("connection") { bots.isConnected && bots.health != nil }
        return bots
    }

    private func openForum(_ server: ScriptedPiBot, posts: [[String: Any]] = [], hasEarlier: Bool = false, thinking: [String] = []) {
        nonisolated(unsafe) let history = posts
        server.on("forum.open") { _ in
            ["subscriptionId": 9, "roomId": 1, "mainRoomId": 1, "posts": history, "hasEarlier": hasEarlier, "thinking": thinking]
        }
    }

    @Test func theSessionLoadsTheForumAndTheUsersName() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        let bots = try await connected(server)
        try await eventually("forum") { bots.forum != nil && bots.userName == "Trey" }
        #expect(bots.supportsForum && bots.supportsUserName)
        #expect(bots.forum?.isActive("a") == true)

        server.on("forum.get") { _ in ["mainRoomId": 1, "paused": true, "bots": [["botId": "a", "active": false]], "threads": []] }
        server.push(["type": "forum.changed"])
        try await eventually("changed") { bots.forum?.paused == true }
        #expect(bots.forum?.isActive("a") == false)
        server.on("user.get") { _ in ["name": "T"] }
        server.push(["type": "user.changed"])
        try await eventually("name") { bots.userName == "T" }
    }

    @Test func anOlderRuntimeIsNeverAskedAboutTheForum() async throws {
        let server = try await ScriptedPiBot()
        let bots = try await connected(server)
        try await eventually("bots") { bots.hasLoadedBots }
        await bots.refreshForum()
        await bots.refreshUserName()
        #expect(!bots.supportsForum && !bots.supportsUserName)
        #expect(bots.forum == nil && bots.userName.isEmpty)
        #expect(server.requests("forum.get").isEmpty && server.requests("user.get").isEmpty)
    }

    @Test func changesAnswerWithTheNewState() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        server.on("forum.setPaused") { _ in ["mainRoomId": 1, "paused": true, "bots": [["botId": "a", "active": true]], "threads": []] }
        server.on("forum.setBotActive") { _ in ["mainRoomId": 1, "paused": true, "bots": [["botId": "a", "active": false]], "threads": []] }
        server.on("user.setName") { body in ["name": body["name"] as? String ?? ""] }
        let bots = try await connected(server)
        try await eventually("forum") { bots.forum != nil }

        await bots.setForumPaused(true)
        #expect(bots.forum?.paused == true)
        #expect(server.requests("forum.setPaused").first?["paused"] as? Bool == true)
        await bots.setForumBotActive(botID: "a", active: false)
        #expect(bots.forum?.isActive("a") == false)
        let request = try #require(server.requests("forum.setBotActive").first)
        #expect(request["botId"] as? String == "a" && request["active"] as? Bool == false)
        #expect(await bots.setUserName("  Trey M  "))
        #expect(bots.userName == "Trey M")
        #expect(server.requests("user.setName").first?["name"] as? String == "Trey M")
    }

    @Test func historyThenPushedPostsAndWhoIsThinking() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        openForum(server, posts: [forumPost(1, "user", "hi", name: "Trey")], thinking: ["a"])
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        try await eventually("ready") { room.isReady }
        #expect(room.state.posts.map(\.id) == [1])
        #expect(room.state.thinking == ["a"])
        #expect(room.roomID == 1 && !room.isThread)
        #expect(server.requests("forum.open").first?["roomId"] == nil)

        server.push(["type": "forum.post", "post": forumPost(2, "bot", "hello")])
        server.push(["type": "forum.post", "post": forumPost(7, "bot", "elsewhere", room: 4)])
        server.push(["type": "forum.thinking", "roomId": 4, "botIds": ["a", "b"]])
        server.push(["type": "forum.thinking", "roomId": 1, "botIds": []])
        try await eventually("post and thinking") { room.state.posts.count == 2 && room.state.thinking.isEmpty }
        #expect(room.state.posts.map(\.id) == [1, 2])
        // A post is pushed again when it changes: its thread got a reply.
        server.push(["type": "forum.post", "post": forumPost(2, "bot", "hello", thread: ["roomId": 4, "replies": 1])])
        try await eventually("changed post") { room.state.posts.last?.thread?.replies == 1 }
        #expect(room.state.posts.map(\.id) == [1, 2])
    }

    @Test func aPushThatOvertakesTheOpenAnswerIsKept() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        server.on("forum.open") { _ in
            server.push(["type": "forum.post", "post": forumPost(2, "bot", "early")])
            server.push(["type": "forum.thinking", "roomId": 1, "botIds": ["a"]])
            return ["subscriptionId": 9, "roomId": 1, "mainRoomId": 1, "posts": [forumPost(1, "user", "hi")], "hasEarlier": false, "thinking": []]
        }
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        try await eventually("ready") { room.isReady }
        // Pushes and answers reach the room on separate paths, so either may land first.
        try await eventually("the early pushes") { room.state.posts.count == 2 && room.state.thinking == ["a"] }
        #expect(room.state.posts.map(\.id) == [1, 2])
    }

    @Test func aPostCarriesItsMentionsAndShowsOnce() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        openForum(server)
        server.on("forum.post") { body in
            let post = forumPost(3, "user", body["text"] as? String ?? "", name: "Trey")
            server.push(["type": "forum.post", "post": post])
            return ["post": post]
        }
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        try await eventually("ready") { room.isReady }

        #expect(await room.send(text: "@Ada status?", mentions: ["a"], everyone: false))
        #expect(room.pending.isEmpty)
        #expect(room.state.posts.map(\.id) == [3])
        let sent = try #require(server.requests("forum.post").first)
        #expect(sent["roomId"] as? Int == 1)
        #expect(sent["mentions"] as? [String] == ["a"])
        #expect(sent["everyone"] == nil)
        #expect(await room.send(text: "@everyone hi", mentions: [], everyone: true))
        let everyone = try #require(server.requests("forum.post").last)
        #expect(everyone["everyone"] as? Bool == true && everyone["mentions"] == nil)
    }

    /// A retry the runtime already took answers without the post, which then arrives as a push.
    @Test func anAcceptedPostWithoutItsBodyIsStillSent() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        openForum(server)
        server.on("forum.post") { _ in ["duplicate": true] }
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        try await eventually("ready") { room.isReady }
        #expect(await room.send(text: "hello", mentions: [], everyone: false))
        #expect(room.pending.isEmpty && room.state.posts.isEmpty && room.error == nil)
        server.push(["type": "forum.post", "post": forumPost(3, "user", "hello", name: "Trey")])
        try await eventually("push") { room.state.posts.map(\.id) == [3] }
    }

    /// The runtime says so after every thread post and every bot that comes or goes.
    @Test func aBurstOfForumChangesIsReadOnce() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        let bots = try await connected(server)
        try await eventually("forum") { bots.forum != nil }
        let before = server.requests("forum.get").count
        server.on("forum.get") { _ in ["mainRoomId": 1, "paused": true, "bots": [], "threads": []] }
        for _ in 0..<5 { server.push(["type": "forum.changed"]) }
        try await eventually("changed") { bots.forum?.paused == true }
        try await Task.sleep(for: .milliseconds(250))
        #expect(server.requests("forum.get").count - before <= 2)
    }

    @Test func aRefusedPostSaysWhyAndLeavesNothingPending() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        openForum(server)
        server.on("forum.post") { _ in throw Rejected() }
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        try await eventually("ready") { room.isReady }
        #expect(await room.send(text: "hello", mentions: [], everyone: false) == false)
        #expect(room.pending.isEmpty && room.state.posts.isEmpty)
        #expect(room.error == "The server refused it.")
        #expect(await room.send(text: String(repeating: "x", count: 100_001), mentions: [], everyone: false) == false)
        #expect(room.error?.contains("100,000") == true)
    }

    @Test func earlierPostsArriveInFront() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        openForum(server, posts: [forumPost(10), forumPost(11)], hasEarlier: true)
        server.on("forum.posts") { _ in ["posts": [forumPost(8), forumPost(9)], "hasEarlier": false] }
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        try await eventually("ready") { room.isReady }
        #expect(room.state.hasEarlier)
        await room.loadEarlier()
        #expect(room.state.posts.map(\.id) == [8, 9, 10, 11])
        #expect(!room.state.hasEarlier)
        let request = try #require(server.requests("forum.posts").first)
        #expect(request["roomId"] as? Int == 1 && request["before"] as? Int == 10)
        await room.loadEarlier()
        #expect(server.requests("forum.posts").count == 1)
    }

    @Test func aThreadOpensItsRoomAndFollowsItsStartingPost() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        server.on("forum.open") { body in
            ["subscriptionId": 4, "roomId": body["roomId"] ?? 1, "mainRoomId": 1, "parent": forumPost(2, "bot", "idea"),
             "posts": [forumPost(6, "user", "go on", room: 4, name: "Trey")], "hasEarlier": false, "thinking": []]
        }
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: 4)
        room.attach()
        try await eventually("ready") { room.isReady }
        #expect(room.isThread && room.roomID == 4)
        #expect(server.requests("forum.open").first?["roomId"] as? Int == 4)
        #expect(room.state.parent?.id == 2 && room.state.posts.map(\.id) == [6])
        server.push(["type": "forum.post", "post": forumPost(2, "bot", "idea", thread: ["roomId": 4, "replies": 2])])
        server.push(["type": "forum.post", "post": forumPost(3, "bot", "main room talk")])
        server.push(["type": "forum.post", "post": forumPost(7, "bot", "more", room: 4)])
        try await eventually("thread post") { room.state.posts.count == 2 }
        #expect(room.state.parent?.thread?.replies == 2)
        #expect(room.state.posts.map(\.id) == [6, 7])
        // The same room is one controller for every panel showing it.
        #expect(bots.forumRoom(roomID: 4) === room)
        #expect(bots.forumRoom(roomID: nil) !== room)
    }

    @Test func replyingInThreadCreatesOrFindsThePostsThread() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        openForum(server, posts: [forumPost(2, "bot", "idea")])
        server.on("forum.thread.create") { body in
            ["thread": ["roomId": 4, "parentPostId": body["postId"] ?? 0, "preview": "", "createdAt": "2026-11-19T10:00:00Z", "replies": 0, "botIds": ["a"]]]
        }
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        try await eventually("ready") { room.isReady }
        let post = try #require(room.state.posts.first)
        let thread = try #require(await room.startThread(from: post))
        #expect(thread.roomId == 4 && thread.parentPostId == 2 && thread.botIds == ["a"])
        #expect(server.requests("forum.thread.create").first?["postId"] as? Int == 2)
    }

    @Test func theLastViewerClosesTheSubscriptionAndAReconnectReopens() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        openForum(server, posts: [forumPost(1)])
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        room.attach()
        try await eventually("ready") { room.isReady }
        #expect(server.requests("forum.open").count == 1)

        openForum(server, posts: [forumPost(1), forumPost(2, "bot", "posted while away")])
        server.dropConnections()
        try await eventually("drop") { !room.isReady }
        #expect(room.state.posts.map(\.id) == [1])
        try await eventually("reopen") { room.isReady }
        #expect(server.requests("forum.open").count == 2)
        #expect(room.state.posts.map(\.id) == [1, 2])

        room.detach()
        #expect(server.requests("forum.close").isEmpty)
        room.detach()
        try await eventually("close") { !server.requests("forum.close").isEmpty }
        let close = try #require(server.requests("forum.close").first)
        #expect(close["roomId"] as? Int == 1 && close["subscriptionId"] as? Int == 9)
    }

    @Test func aFailedOpenLeavesTheComposerOffAndRetries() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        server.on("forum.open") { _ in throw Rejected() }
        let bots = try await connected(server)
        let room = bots.forumRoom(roomID: nil)
        room.attach()
        try await eventually("error") { room.error == "The server refused it." }
        #expect(!room.isReady)
        openForum(server)
        try await eventually("retry") { room.isReady }
    }

    @Test func scheduledPostsAreListedSavedAndRemoved() async throws {
        let server = try await ScriptedPiBot(capabilities: Self.withForum)
        nonisolated(unsafe) let saved: [String: Any] = ["id": "s1", "text": "Morning", "repeat": "daily", "time": "09:00", "timeZone": "UTC"]
        server.on("forum.schedules.list") { _ in ["schedules": []] }
        server.on("forum.schedules.save") { _ in ["schedules": [saved]] }
        server.on("forum.schedules.delete") { _ in ["schedules": []] }
        let bots = try await connected(server)
        #expect(bots.forumSchedules == nil)
        await bots.loadForumSchedules()
        #expect(bots.forumSchedules == [])
        var draft = PiBotForumScheduleDraft(date: Date(timeIntervalSince1970: 1_795_116_600), timeZone: TimeZone(identifier: "Europe/Berlin")!)
        draft.text = "Morning"
        #expect(await bots.saveForumSchedule(draft))
        #expect(bots.forumSchedules?.map(\.id) == ["s1"])
        let request = try #require(server.requests("forum.schedules.save").first?["schedule"] as? [String: Any])
        #expect(request["text"] as? String == "Morning" && request["repeat"] as? String == "daily")
        #expect(request["time"] as? String == "20:30" && request["timeZone"] as? String == "Europe/Berlin" && request["id"] == nil)
        await bots.deleteForumSchedule(id: "s1")
        #expect(bots.forumSchedules == [])
        #expect(server.requests("forum.schedules.delete").first?["scheduleId"] as? String == "s1")
    }
}

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

    init() async throws { port = try await start(on: .any) }

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
        write(connection, ["type": "hello", "version": "0.1.0", "protocol": 1, "installationId": "fixture",
                           "capabilities": ["groups", "woven.mcp", "message.context"]])
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
    private func connected(_ server: ScriptedPiBot) async throws -> BotsModel {
        server.on("bots.list") { _ in ["bots": []] }
        server.on("groups.list") { _ in ["groups": []] }
        server.on("threads.list") { _ in ["threads": []] }
        server.on("onboarding.status") { _ in
            ["adminId": "admin", "profileId": "default", "mainModel": "m", "mainModelAvailable": true, "signedIn": true, "needed": false]
        }
        let bots = BotsModel()
        bots.apply(PiBotRuntimeSnapshot(phase: .ready, baseURL: URL(string: "http://127.0.0.1:\(server.port)")!))
        try await eventually("connection") { bots.isConnected }
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
        openMain(server, entries: [entry(1, "user", "hi")])
        let bots = try await connected(server)
        let controller = bots.conversation(botID: "a", conversationID: nil)
        controller.attach()
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
        var moved = PiBotRuntimeSnapshot(phase: .ready, baseURL: URL(string: "http://127.0.0.1:\(other.port)")!)
        moved.target = PiBotDeploymentTarget(kind: .tailnet, peer: nil, sshUser: "someone")
        var before = bots.runtime
        before.target = .thisMac
        bots.apply(before)
        bots.apply(moved)
        try await eventually("new connection") { bots.isConnected && bots.onboarding?.needed == true }
        #expect(bots.conversation(botID: "a", conversationID: nil) !== first)
    }

    @Test func loginEventsThatBeatTheirResultAreStillDelivered() async throws {
        let server = try await ScriptedPiBot()
        let bots = try await connected(server)
        server.push(["type": "login", "loginId": "l1", "event": ["kind": "progress", "message": "early"]])
        try await Task.sleep(for: .milliseconds(100))
        var seen: [PiBotLoginEvent] = []
        bots.observeLogin("l1") { seen.append($0) }
        server.push(["type": "login", "loginId": "l1", "event": ["kind": "done"]])
        try await eventually("login events") { seen.count == 2 }
        #expect(seen == [.info("early"), .done])
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

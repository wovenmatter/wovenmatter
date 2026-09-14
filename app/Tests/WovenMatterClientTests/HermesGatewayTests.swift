import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct HermesGatewayTests {
    @Test func nativeRequestsUseResponseFramesAndKeepTheReaderAvailable() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let turn = Task {
            try await client.prompt(AgentMessageInput(text: "Hello"), onEvent: nil,
                onPermission: { _ in "once" }, onInteraction: { request in
                    switch request {
                    case .questions(let request):
                        return .answers(Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, .single("Yes")) }))
                    case .secret: return .secret("fixture-only-value")
                    default: return .cancelled
                    }
                })
        }
        try await transport.waitForSubmit()
        for (id, method, params) in [
            ("approval", "approval", ["request_id": "internal-approval-id", "choices": .array(["once", "deny"])] as HermesValue),
            ("single", "clarify", ["question": "Continue?"]),
            ("batch", "clarify", ["questions": .array([["qid": "q1", "question": "Continue?"]])]),
            ("password", "sudo", [:]),
            ("secret", "secret", ["prompt": "Token"]),
            ("unsupported", "window.read", [:])
        ] {
            await transport.request(id: id, method: method, params: params)
        }
        try await transport.waitForResponses(6)
        let responses = await transport.responses
        #expect(responses["approval"] == ["choice": "once"])
        #expect(responses["single"] == ["answer": "Yes"])
        #expect(responses["batch"] == ["answers": ["q1": "Yes"]])
        #expect(responses["password"] == ["value": "fixture-only-value"])
        #expect(responses["secret"] == ["value": "fixture-only-value"])
        #expect(responses["unsupported"] == [:])
        #expect(await transport.calls.allSatisfy { !$0.0.hasSuffix(".respond") })
        await transport.complete()
        #expect(try await turn.value == .endTurn)
        await client.shutdown()
    }

    @Test func cancelledNativeRequestCannotSendALateAnswer() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        let gate = HermesAnswerGate()
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let turn = Task {
            try await client.prompt(AgentMessageInput(text: "Hello"), onEvent: nil, onPermission: nil,
                onInteraction: { _ in await gate.answer() })
        }
        try await transport.waitForSubmit()
        await transport.request(id: "cancelled", method: "secret", params: ["prompt": "Token"])
        try await gate.waitUntilAsked()
        await transport.event(type: "request.cancel", payload: ["id": "cancelled"])
        await gate.resolve()
        await transport.complete()
        _ = try await turn.value
        #expect(await transport.responses["cancelled"] == nil)
        await client.shutdown()
    }

    @Test func changedEpochDoesNotResumeOrResubmitAnInterruptedTurn() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        let identity = HermesGatewayClient.identity(home: "/tmp/hermes-fixture", storedID: "stored")
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: identity, title: nil, systemPrompt: nil)
        #expect(await transport.calls.first { $0.0 == "session.resume" }?.1["defer_history"] == .bool(true))
        let turn = Task { try await client.prompt(AgentMessageInput(text: "Hello"), onEvent: nil, onPermission: nil, onInteraction: nil) }
        try await transport.waitForSubmit()
        await transport.restart()
        await #expect(throws: (any Error).self) { try await turn.value }
        #expect(await transport.calls.filter { $0.0 == "session.resume" }.count == 1)
        #expect(await transport.calls.filter { $0.0 == "prompt.submit" }.count == 1)
        #expect(await !transport.isConnected)
        await client.shutdown()
    }

    @Test func lostSubmitAcknowledgementRequiresRunningCheckBeforeNextSend() async throws {
        let transport = HermesTransportFixture()
        await transport.loseNextSubmit()
        let client = makeClient(transport)
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) {
                try await client.prompt(AgentMessageInput(text: "Hello"), onEvent: nil, onPermission: nil, onInteraction: nil)
            }
        }
        #expect(await transport.calls.filter { $0.0 == "prompt.submit" }.count == 1)
        #expect(await transport.calls.last { $0.0 == "session.resume" }?.1["defer_history"] == .bool(true))
        await client.shutdown()
    }

    @Test func sameEpochReplayRestoresOpenRequestsAndDeduplicatesEvents() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        let output = HermesOutputFixture()
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let turn = Task {
            try await client.prompt(AgentMessageInput(text: "Hello"), onEvent: { await output.record($0) },
                onPermission: { _ in "deny" }, onInteraction: nil)
        }
        try await transport.waitForSubmit()
        await transport.event(type: "message.delta", payload: ["text": "First"])
        await transport.reconnectWithReplay()
        try await transport.waitForResponses(1)
        #expect(await transport.responses["replayed-approval"] == ["choice": "deny"])
        await transport.complete()
        #expect(try await turn.value == .endTurn)
        #expect(await output.chunks == ["First", " second"])
        #expect(await transport.calls.filter { $0.0 == "prompt.submit" }.count == 1)
        await client.shutdown()
    }

    private func makeClient(_ transport: HermesTransportFixture) -> HermesGatewayClient {
        HermesGatewayClient(launch: LocalACPRuntimeLaunchConfiguration(runtimeKind: .hermes,
            executableURL: URL(fileURLWithPath: "/fixture/not-executed"), arguments: [], environment: [:]),
            transport: transport, home: "/tmp/hermes-fixture")
    }
}

private actor HermesTransportFixture: HermesGatewayTransport {
    var epoch: String? = "first"
    var isConnected = false
    var calls: [(String, HermesValue)] = []
    var responses: [String: HermesValue] = [:]
    private var onEvent: HermesGatewayRPC.EventHandler?
    private var onRequest: HermesGatewayRPC.EventHandler?
    private var onDisconnect: (@Sendable () async -> Void)?
    private var running = false
    private var loseSubmit = false
    private var sequence = 0
    private var replay: HermesValue?

    func setHandlers(event: HermesGatewayRPC.EventHandler?, disconnected: (@Sendable () async -> Void)?, request: HermesGatewayRPC.EventHandler?) {
        onEvent = event; onRequest = request; onDisconnect = disconnected
    }
    func connect() { isConnected = true }
    func disconnect() { isConnected = false }
    func call(_ method: String, _ params: HermesValue) throws -> HermesValue {
        calls.append((method, params))
        switch method {
        case "session.create", "session.resume":
            return ["session_id": "live", "stored_session_id": "stored", "running": .bool(running)]
        case "session.events.since": return replay ?? ["latest_seq": .number(Double(sequence)), "epoch": .string(epoch ?? "")]
        case "prompt.submit":
            running = true
            if loseSubmit { throw HermesGatewayError.message("Acknowledgement lost") }
            return [:]
        default: return [:]
        }
    }
    func respond(id: String, result: HermesValue) { responses[id] = result }
    func request(id: String, method: String, params: HermesValue) async {
        var params = params; params["session_id"] = "live"
        await onRequest?(["id": .string(id), "method": .string(method), "params": params])
    }
    func event(type: String, payload: HermesValue) async {
        sequence += 1
        await onEvent?(["session_id": "live", "seq": .number(Double(sequence)), "type": .string(type), "payload": payload])
    }
    func complete() async {
        running = false
        await event(type: "message.complete", payload: ["text": "Done"])
    }
    func restart() async { epoch = "second"; isConnected = false; await onDisconnect?() }
    func reconnectWithReplay() async {
        replay = ["epoch": .string(epoch!), "events": .array([
            ["session_id": "live", "seq": .number(1), "type": "message.delta", "payload": ["text": "First"]],
            ["session_id": "live", "seq": .number(2), "type": "message.delta", "payload": ["text": " second"]]
        ]), "open_requests": .array([
            ["id": "replayed-approval", "method": "approval", "params": ["session_id": "live", "choices": .array(["deny"])]]
        ])]
        sequence = 2
        isConnected = false
        await onDisconnect?()
    }
    func loseNextSubmit() { loseSubmit = true }
    func waitForSubmit() async throws {
        for _ in 0..<200 {
            if running { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HermesGatewayError.message("Fixture did not receive a prompt")
    }
    func waitForResponses(_ count: Int) async throws {
        for _ in 0..<200 {
            if responses.count == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HermesGatewayError.message("Fixture did not receive all responses")
    }
}

private actor HermesAnswerGate {
    private var continuation: CheckedContinuation<LocalACPInteractionResponse, Never>?
    func answer() async -> LocalACPInteractionResponse {
        await withCheckedContinuation { continuation = $0 }
    }
    func resolve() { continuation?.resume(returning: .secret("late-fixture-value")); continuation = nil }
    func waitUntilAsked() async throws {
        for _ in 0..<200 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HermesGatewayError.message("Fixture did not display the request")
    }
}

private actor HermesOutputFixture {
    var chunks: [String] = []
    func record(_ event: LocalACPEvent) {
        if case .assistantChunk(let text) = event { chunks.append(text) }
    }
}

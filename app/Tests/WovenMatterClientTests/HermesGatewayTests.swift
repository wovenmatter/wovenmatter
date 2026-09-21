import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct HermesGatewayTests {
    @Test func importedNativeDirectorySurvivesConfigurationRefresh() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        let identity = HermesGatewayClient.identity(home: "/tmp/hermes-fixture", storedID: "stored", imported: true)
        let initialized = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/different/app/workspace"),
            existingSessionID: identity, title: nil, systemPrompt: nil)
        #expect(initialized.configuration.workingDirectory == "/native/imported project")
        let updated = try await client.setSessionConfiguration(model: nil, thinking: nil)
        #expect(updated.workingDirectory == "/native/imported project")
        #expect(await !transport.calls.contains { $0.0 == "session.cwd.set" })
        await client.shutdown()
    }

    @Test func pinnedIdentityCannotResumeOnAnotherProfileOrWorkspace() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        let identity = HermesGatewayClient.identity(home: "/remote-workspaces/other/home/.hermes", storedID: "stored")
        await #expect(throws: (any Error).self) {
            try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"),
                existingSessionID: identity, title: nil, systemPrompt: nil)
        }
        #expect(await transport.calls.isEmpty)
        #expect(await !transport.isConnected)
        await client.shutdown()
    }

    @Test func createAndResumeUseTheirOwnNativeParameterSchemas() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        let created = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"),
            existingSessionID: nil, title: "A conversation", systemPrompt: nil)
        #expect(created.configuration.workingDirectory == "/tmp")
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"),
            existingSessionID: created.sessionID, title: "A conversation", systemPrompt: nil)
        #expect(await transport.calls.first { $0.0 == "session.create" }?.1["title"] == "A conversation")
        #expect(await transport.calls.first { $0.0 == "session.resume" }?.1["defer_history"] == .bool(true))
        await client.shutdown()
    }

    @Test func remoteWorkspaceAttachesTheStagedPathWithoutUploadingBytes() async throws {
        let transport = HermesTransportFixture()
        let client = try makeClient(transport, environment: remoteHermesEnvironment())
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let remotePath = "/home/.woven-matter/.wovenmatter/attachments/h/notes.txt"
        let file = AgentFileAttachmentDraft(kind: .file, fileName: "notes.txt", mimeType: "text/plain",
            sizeBytes: 1, contentHash: "h", localURL: URL(fileURLWithPath: "/tmp/notes.txt"), remotePath: remotePath)
        let input = AgentMessageInput(text: "Inspect this", attachments: [.file(file)])
        let turn = Task { try await client.prompt(input, onEvent: nil, onPermission: nil, onInteraction: nil) }
        try await transport.waitForSubmit()
        #expect(await transport.calls.first { $0.0 == "file.attach" }?.1["path"] == .string(remotePath))
        #expect(await transport.calls.contains { $0.0 == "prompt.submit" })
        await transport.complete()
        #expect(try await turn.value == .endTurn)
        await client.shutdown()
    }

    @Test func remoteWorkspaceRefusesAnUnstagedFileBeforeSubmitting() async throws {
        let transport = HermesTransportFixture()
        let client = try makeClient(transport, environment: remoteHermesEnvironment())
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let file = AgentFileAttachmentDraft(kind: .file, fileName: "notes.txt", mimeType: "text/plain",
            sizeBytes: 1, contentHash: "h", localURL: URL(fileURLWithPath: "/tmp/notes.txt"))
        await #expect(throws: HermesGatewayError.self) {
            try await client.prompt(AgentMessageInput(text: "Inspect this", attachments: [.file(file)]),
                onEvent: nil, onPermission: nil, onInteraction: nil)
        }
        #expect(await !transport.calls.contains { $0.0 == "file.attach" || $0.0 == "prompt.submit" })
        await client.shutdown()
    }

    @Test func attachmentsUseNativeSchemasAndRollBackImagesWhenStagingFails() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let image = AgentFileAttachmentDraft(kind: .image, fileName: "image.png", mimeType: "image/png",
            sizeBytes: 1, contentHash: "image", localURL: URL(fileURLWithPath: "/tmp/image.png"))
        let file = AgentFileAttachmentDraft(kind: .file, fileName: "file.txt", mimeType: "text/plain",
            sizeBytes: 1, contentHash: "file", localURL: URL(fileURLWithPath: "/tmp/file.txt"))
        let input = AgentMessageInput(text: "Inspect these", attachments: [.file(image), .file(file)])
        await transport.rejectFiles()
        await #expect(throws: (any Error).self) {
            try await client.prompt(input, onEvent: nil, onPermission: nil, onInteraction: nil)
        }
        #expect(await transport.calls.contains { $0.0 == "image.detach" })
        #expect(await !transport.calls.contains { $0.0 == "prompt.submit" })
        await transport.rejectFiles(false)
        let turn = Task { try await client.prompt(input, onEvent: nil, onPermission: nil, onInteraction: nil) }
        try await transport.waitForSubmit()
        await transport.complete()
        #expect(try await turn.value == .endTurn)
        await client.shutdown()
    }

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

    @Test func identityIsPublishedBeforeAnyProviderSubmission() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        await #expect(throws: (any Error).self) {
            try await client.prompt(AgentMessageInput(text: "Hello"), onEvent: { event in
                if case .sessionIdentity(let identity) = event {
                    #expect(HermesGatewayClient.parseIdentity(identity).storedID == "stored")
                    throw HermesGatewayError.message("Cannot persist the identity")
                }
            }, onPermission: nil, onInteraction: nil)
        }
        #expect(await !transport.calls.contains { $0.0 == "prompt.submit" })
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

    @Test func finalAssistantBoundaryPrecedesCompletionReasoning() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        let output = HermesEventFixture()
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let turn = Task { try await client.prompt(AgentMessageInput(text: "Hello"), onEvent: { await output.record($0) }, onPermission: nil, onInteraction: nil) }
        try await transport.waitForSubmit()
        await transport.event(type: "message.complete", payload: ["text": "Final", "reasoning": "Late reasoning"])
        #expect(try await turn.value == .endTurn)
        let events = await output.events.filter { event in
            if case .sessionIdentity = event { return false }
            return true
        }
        #expect(events.count == 3)
        if case .assistantSnapshot("Final") = events[0] {} else { Issue.record("Expected final snapshot first") }
        #expect(events[1] == .assistantBoundary)
        if case .activity(let activity, _) = events[2] { #expect(activity.kind == .thought); #expect(activity.content == "Late reasoning") }
        else { Issue.record("Expected reasoning after assistant boundary") }
        await client.shutdown()
    }

    @Test func completionReasoningDoesNotDuplicateStreamedReasoning() async throws {
        let transport = HermesTransportFixture()
        let client = makeClient(transport)
        let output = HermesEventFixture()
        _ = try await client.initializeSession(workingDirectory: URL(fileURLWithPath: "/tmp"), existingSessionID: nil, title: nil, systemPrompt: nil)
        let turn = Task { try await client.prompt(AgentMessageInput(text: "Hello"), onEvent: { await output.record($0) }, onPermission: nil, onInteraction: nil) }
        try await transport.waitForSubmit()
        await transport.event(type: "reasoning.delta", payload: ["text": "streamed reasoning"])
        await transport.event(type: "message.complete", payload: ["text": "Final", "reasoning": "streamed reasoning"])
        _ = try await turn.value
        let thoughts = await output.events.compactMap { event -> AgentRunActivity? in
            if case .activity(let activity, _) = event, activity.kind == .thought { return activity }
            return nil
        }
        #expect(thoughts.count == 1)
        #expect(thoughts[0].content == "streamed reasoning")
        await client.shutdown()
    }

    private func makeClient(_ transport: HermesTransportFixture, environment: [String: String] = [:]) -> HermesGatewayClient {
        HermesGatewayClient(launch: LocalACPRuntimeLaunchConfiguration(runtimeKind: .hermes,
            executableURL: URL(fileURLWithPath: "/fixture/not-executed"), arguments: [], environment: environment),
            transport: transport, home: "/tmp/hermes-fixture")
    }

    private func remoteHermesEnvironment() throws -> [String: String] {
        let connection = HermesGatewayConnection(home: "/tmp/hermes-fixture", port: 9, token: "fixture", pid: 1)
        return ["WOVENMATTER_HERMES_CONNECTION": try JSONEncoder().encode(connection).base64EncodedString()]
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
    private var rejectFile = false
    private var sequence = 0
    private var replay: HermesValue?

    func setHandlers(event: HermesGatewayRPC.EventHandler?, disconnected: (@Sendable () async -> Void)?, request: HermesGatewayRPC.EventHandler?) {
        onEvent = event; onRequest = request; onDisconnect = disconnected
    }
    func connect() { isConnected = true }
    func disconnect() { isConnected = false }
    func call(_ method: String, _ params: HermesValue) throws -> HermesValue {
        calls.append((method, params))
        // Allowed keys from installed Hermes d4063e62's strict Pydantic contracts.
        // Unlike the old permissive fixture, reject fields the real Gateway rejects.
        let fields: Set<String>?
        switch method {
        case "session.create": fields = ["profile", "cols", "source", "cwd", "messages", "parent_session_id", "title", "model", "provider", "reasoning_effort", "fast", "close_on_disconnect", "hidden", "room_plumbing", "follow_profile_config"]
        case "session.resume": fields = ["session_id", "cols", "source", "lazy", "defer_history", "omit_messages", "eager_build", "close_on_disconnect"]
        case "image.attach", "image.detach": fields = ["session_id", "path"]
        case "file.attach": fields = ["session_id", "path", "data_url", "name"]
        default: fields = nil
        }
        if let fields, !Set(params.object.keys).isSubset(of: fields) {
            throw HermesGatewayError.rpc(code: 4000, message: "Invalid parameters for " + method)
        }
        switch method {
        case "file.attach":
            if rejectFile { throw HermesGatewayError.rpc(code: 5028, message: "File could not be staged") }
            return ["attached": .bool(true), "ref_text": "@file:file.txt"]
        case "session.create", "session.resume":
            return ["session_id": "live", "stored_session_id": "stored", "running": .bool(running), "info": ["cwd": "/native/imported project"]]
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
    func rejectFiles(_ reject: Bool = true) { rejectFile = reject }
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

private actor HermesEventFixture {
    var events: [LocalACPEvent] = []
    func record(_ event: LocalACPEvent) { events.append(event) }
}

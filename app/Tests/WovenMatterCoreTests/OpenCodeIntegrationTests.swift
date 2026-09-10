import Foundation
import Testing
import SQLite3
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite(.serialized)
struct OpenCodeIntegrationTests {
    @Test func freshSessionShowsServerDefaultWithoutOverridingExplicitSelection() throws {
        let fallback: OpenCodeValue = ["id": "default-model", "providerID": "provider", "variants": .array([["id": "high"]])]
        let explicit: OpenCodeValue = ["id": "chosen", "providerID": "provider", "variant": "high"]
        let catalog: [OpenCodeValue] = [fallback, ["id": "chosen", "providerID": "provider", "variants": .array([["id": "high"]])]]
        let fresh = OpenCodeComposerMetadata.metadata(session: ["id": "ses_new"], models: catalog, defaultModel: fallback)
        #expect(fresh.model == "provider/default-model")
        #expect(fresh.thinking == "default")
        #expect(OpenCodeComposerMetadata.matchesSelection(["id": "chosen", "providerID": "provider", "variant": "default"], ["id": "chosen", "providerID": "provider"]))
        #expect(!OpenCodeComposerMetadata.matchesSelection(explicit, ["id": "chosen", "providerID": "provider"]))
        let selected = OpenCodeComposerMetadata.metadata(session: ["id": "ses_new", "model": explicit], models: catalog, defaultModel: fallback)
        #expect(selected.model == "provider/chosen")
        #expect(selected.thinking == "high")
        #expect(OpenCodeComposerMetadata.metadata(session: ["id": "ses_new"], models: []).model == nil)
    }

    @Test func durableStreamAllowsIdleTimeWithoutUsingTheSnapshotTimeout() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let client = OpenCodeHTTPClient(connection: try connection(), session: fixtureSession())
        // This stub intentionally returns JSON rather than SSE, ending the
        // request immediately after recording its actual transport timeout.
        await #expect(throws: OpenCodeError.malformedStream) {
            try await client.events("/api/experimental/session/ses_fixture/log") { _ in }
        }
        #expect(fixture.streamTimeout == 86_400)
    }
    @Test func existingComposerKeepsProviderIdentityAndModelSpecificThinking() throws {
        let catalog: [OpenCodeValue] = [
            ["id": "same", "providerID": "first", "variants": .array([["id": "low"], ["id": "high"]])],
            ["id": "same", "providerID": "second", "variants": .array([])]
        ]
        let session: OpenCodeValue = ["id": "ses_fixture", "model": ["id": "same", "providerID": "first", "variant": "high"]]
        let metadata = OpenCodeComposerMetadata.metadata(session: session, models: catalog)
        #expect(metadata.selectableModels == ["first/same", "second/same"])
        #expect(metadata.model == "first/same")
        #expect(metadata.thinking == "high")
        #expect(metadata.selectableThinkingLevels == ["default", "low", "high"])
        #expect(try OpenCodeComposerMetadata.selection(model: "first/same", thinking: "low", models: catalog)["model"]["variant"].text == "low")
        #expect(try OpenCodeComposerMetadata.selection(model: "first/same", thinking: "default", models: catalog)["model"]["variant"].isNull)
        // Switching models clears the old model's reasoning variant.
        let changed = try OpenCodeComposerMetadata.selection(model: "second/same", models: catalog)
        #expect(changed["model"]["providerID"].text == "second")
        #expect(changed["model"]["variant"].isNull)
        #expect(OpenCodeComposerMetadata.metadata(session: ["model": changed["model"]], models: catalog).selectableThinkingLevels.isEmpty)
        #expect(throws: OpenCodeError.self) { try OpenCodeComposerMetadata.selection(model: "second/same", thinking: "high", models: catalog) }
        #expect(!OpenCodeSessionSnapshot.presentsMessage(["type": "model-switched", "model": changed["model"]]))
        #expect(OpenCodeSessionSnapshot.presentsMessage(["type": "assistant", "content": .array([])]))
    }

    @Test func localServiceUsesStandardRegistrationAndAcceptsOfficialVersionBanner() {
        let home = URL(fileURLWithPath: "/fixture-home")
        #expect(OpenCodeConnection.registrationURL(environment: [:], home: home).path == "/fixture-home/.local/state/opencode/service.json")
        #expect(OpenCodeConnection.registrationURL(environment: ["XDG_STATE_HOME": "/custom/state"], home: home).path == "/custom/state/opencode/service.json")
        #expect(OpenCodeServiceLauncher.normalizedVersion("opencode2 v0.0.0-beta-19278\n") == OpenCodeConnection.supportedVersion)
        #expect(OpenCodeServiceLauncher.normalizedVersion("0.0.0-beta-19278\n") == OpenCodeConnection.supportedVersion)
        #expect(OpenCodeServiceLauncher.normalizedVersion("opencode2 v2.99.0") != OpenCodeConnection.supportedVersion)
    }

    @Test func connectReusesExistingLocalServiceAndNeverReplacesLiveIncompatibleService() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "service.json")
        let registration: OpenCodeValue = ["url": "http://127.0.0.1:1234", "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "password": "fixture"]
        let bytes = try JSONEncoder().encode(registration); try bytes.write(to: file)
        let session = fixtureSession()
        let connection = try await OpenCodeServiceLauncher.ensure(executable: nil, registration: file, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        #expect(connection.identity == "local:" + file.standardizedFileURL.path)
        #expect(try Data(contentsOf: file) == bytes)
        fixture.version = "2.99.0"
        await #expect(throws: OpenCodeError.incompatible("2.99.0")) {
            try await OpenCodeServiceLauncher.ensure(executable: URL(fileURLWithPath: "/never-run"), registration: file, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func fragmentedSSEAcceptsOnlyCompleteFrames() throws {
        var parser = OpenCodeSSEParser()
        let event: OpenCodeValue = ["type": "message.updated", "durable": ["seq": .number(91)], "text": "café 🧵"]
        let encoded = try JSONEncoder().encode(event)
        let doubleEncoded = try JSONEncoder().encode(String(decoding: encoded, as: UTF8.self))
        let wire = Data(": heartbeat\r\ndata: ".utf8) + doubleEncoded + Data("\r\n\r\n".utf8)
        var received: [OpenCodeValue] = []
        for byte in wire.dropLast(2) { received += try parser.append(byte) }
        #expect(received.isEmpty)
        #expect(parser.hasPartialFrame)
        for byte in wire.suffix(2) { received += try parser.append(byte) }
        #expect(received == [event])
        #expect(!parser.hasPartialFrame)
        for byte in Data("data: {\"unfinished\":".utf8) { _ = try parser.append(byte) }
        #expect(parser.hasPartialFrame)
    }

    @Test func serverOrderAndRevertOverrideTimestamps() {
        var snapshot = OpenCodeSessionSnapshot()
        let first = message("msg_z", time: 20), second = message("msg_a", time: 10), third = message("msg_b", time: 10)
        snapshot.mergeMessages([first, second, third])
        #expect(snapshot.messages.map { $0["id"].text } == ["msg_z", "msg_a", "msg_b"])
        snapshot.mergeMessages([second])
        #expect(snapshot.messages == [first, second])
        snapshot.mergeMessages([first, first], older: true)
        #expect(snapshot.messages == [first, second])
    }

    @Test func connectionRefusesWrongOriginsAndMalformedProcessIdentity() throws {
        #expect(throws: OpenCodeError.self) { try OpenCodeConnection(identity: "bad", url: URL(string: "https://user:secret@example.com")!, password: "fixture") }
        #expect(throws: OpenCodeError.self) { try OpenCodeConnection(identity: "bad", url: URL(string: "https://example.com/api")!, password: "fixture") }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"url\":\"http://127.0.0.1:1234\",\"pid\":1e100,\"password\":\"fixture\"}".utf8).write(to: file)
        #expect(throws: OpenCodeError.self) { try OpenCodeConnection.discover(file: file) }
        let client = OpenCodeHTTPClient(connection: try connection())
        let request = try client.request("POST", "/api/session/ses_fixture/prompt", query: ["location[directory]": "/tmp/a b"], body: ["text": "literal"])
        #expect(request.url?.query?.contains("a%20b") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic b3BlbmNvZGU6Zml4dHVyZQ==")
    }

    @Test func incompatibleServerCannotBecomeConnected() async throws {
        let fixture = OpenCodeFixture(); fixture.version = "2.99.0"
        FixtureProtocol.fixture = fixture
        let client = OpenCodeHTTPClient(connection: try connection(), session: fixtureSession())
        await #expect(throws: OpenCodeError.incompatible("2.99.0")) { try await client.health() }
    }

    @Test func missedPagesPendingInteractionsAndLostPromptResponseRecoverWithoutResend() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try database.createLocalACPSession(runtimeKind: .opencode, title: "fixture", ownerDeviceID: UUID())
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        try database.attachOpenCodeSession(link)
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        fixture.messages = [message("msg_original")]
        try await coordinator.refresh(link)
        // A second UI wrote more than two pages while this client was offline.
        fixture.messages += (0..<250).map { message("msg_other_\($0)", time: Double(250 - $0)) }
        try await coordinator.refresh(link)
        let recovered = try #require(try database.openCodeSnapshot(conversationID: id))
        #expect(recovered.messages.count == 251)
        #expect(recovered.messages.last?["id"].text == "msg_other_249")
        #expect(recovered.forms.map { $0["id"].text } == ["form_pending"])
        #expect(recovered.permissions.first?["id"].text == "perm_pending")
        #expect(recovered.olderCursor == nil)
        #expect(fixture.historyRequests >= 4)
        // Server accepts exactly once, then the HTTP response is lost.
        fixture.losePromptResponse = true
        try await coordinator.prompt(link, input: .init(text: "one input"))
        #expect(fixture.promptCount == 1)
        #expect(try database.openCodeUncertainSubmissions(conversationID: id).isEmpty)
        #expect(try database.openCodeSnapshot(conversationID: id)?.messages.last?["text"].text == "one input")
        await coordinator.disconnect(connectionID: "fixture")
        #expect(fixture.interruptCount == 0)
        let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        #expect(try reopened.openCodeLinks() == [link])
        #expect(try reopened.openCodeSnapshot(conversationID: id)?.messages.count == 252)
    }

    @Test func unknownAcceptanceBlocksNewInputWithoutTreating404AsRejection() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.losePromptResponse = true; fixture.acceptPrompt = false
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try database.createLocalACPSession(runtimeKind: .opencode, title: "fixture", ownerDeviceID: UUID())
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        try database.attachOpenCodeSession(link)
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        await #expect(throws: OpenCodeError.self) { try await coordinator.prompt(link, input: .init(text: "unknown")) }
        await #expect(throws: OpenCodeError.self) { try await coordinator.prompt(link, input: .init(text: "do not duplicate")) }
        #expect(fixture.promptCount == 1)
        #expect(try database.openCodeUncertainSubmissions(conversationID: id).count == 1)
        await coordinator.shutdown()
    }

    @Test func legacyTranscriptsCannotEnterACPAndOtherHarnessesCan() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let old = try database.createLocalACPSession(runtimeKind: .opencode, title: "Retained transcript", ownerDeviceID: UUID())
        #expect(throws: OpenCodeError.self) { try database.beginLocalACPRun(conversationID: old, input: .init(text: "blocked")) }
        #expect(try database.localACPSession(conversationID: old).title == "Retained transcript")
        #expect(try database.conversationContent(id: old).messages.isEmpty)
        let codex = try database.createLocalACPSession(runtimeKind: .codex, title: "Other harness", ownerDeviceID: UUID())
        _ = try database.beginLocalACPRun(conversationID: codex, input: .init(text: "allowed"))
        #expect(try database.conversationContent(id: codex).messages.count == 2)
    }

    @Test func disconnectDuringHealthCheckCannotReconnectAStaleClient() async throws {
        let fixture = OpenCodeFixture(); fixture.holdHealth = true; FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        let connection = try connection()
        let connecting = Task { try await coordinator.connect(connection) }
        await fixture.gate.waitForArrival()
        await coordinator.disconnect(connectionID: "fixture")
        fixture.gate.release()
        await #expect(throws: CancellationError.self) { try await connecting.value }
        await #expect(throws: OpenCodeError.self) { try await coordinator.call(connectionID: "fixture", path: "/api/health") }
    }

    @Test func richProjectionAndRecoveryCursorSurviveDatabaseReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "workspace.sqlite")
        let database = try WorkspaceDatabase(url: url)
        let id = try database.createLocalACPSession(runtimeKind: .opencode, title: "Rich fixture", ownerDeviceID: UUID())
        try database.attachOpenCodeSession(.init(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture"))
        var snapshot = OpenCodeSessionSnapshot()
        snapshot.info = ["id": "ses_fixture", "title": "Rich fixture"]
        snapshot.cursor = 874
        snapshot.messages = [
            ["id": "msg_file", "type": "user", "text": "Inspect", "time": ["created": .number(1)],
             "files": .array([["mime": "text/plain", "name": "fixture.txt", "data": "Zml4dHVyZQ=="]])],
            ["id": "msg_result", "type": "assistant", "time": ["created": .number(2), "completed": .number(3)],
             "content": .array([
                ["type": "text", "text": "Result"],
                ["type": "reasoning", "text": "Inspecting the fixture"],
                ["type": "tool", "id": "tool_1", "name": "read", "state": ["status": "completed", "input": ["path": "fixture.txt"], "content": .array([["type": "text", "text": "fixture"]])]]
             ])]
        ]
        try database.saveOpenCodeSnapshot(snapshot, conversationID: id)
        try database.saveOpenCodeSnapshot(snapshot, conversationID: id)
        let reopened = try WorkspaceDatabase(url: url)
        #expect(try reopened.openCodeSnapshot(conversationID: id) == snapshot)
        let content = try reopened.conversationContent(id: id)
        #expect(content.messages.count == 2)
        #expect(content.runs.count == 1)
        #expect(content.runs.first?.completedAt?.hasPrefix("1970-01-01T00:00:00.003") == true)
        #expect(try reopened.conversationHistoryPage(id: id, limit: 100).activities.count == 2)
    }

    @Test func existingV1MessageContentIsRetainedWhenContinuationIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "workspace.sqlite")
        let database = try WorkspaceDatabase(url: url)
        let id = try database.createLocalACPSession(runtimeKind: .codex, title: "Historical transcript", ownerDeviceID: UUID())
        _ = try database.beginLocalACPRun(conversationID: id, input: .init(text: "Historical message, retained verbatim"))
        // Represent an existing pre-upgrade OpenCode ACP row without starting ACP.
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "UPDATE desktop_local_acp_sessions SET runtime_kind='opencode' WHERE conversation_id=?", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        let before = try database.conversationContent(id: id).messages
        #expect(throws: OpenCodeError.self) { try database.beginLocalACPRun(conversationID: id, input: .init(text: "do not append")) }
        #expect(try database.conversationContent(id: id).messages == before)
        #expect(before.first?.content == "Historical message, retained verbatim")
    }

    @Test func repeatedSessionOpenReusesOneAtomicConversationAssociation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let owner = UUID()
        let first = try database.createLocalACPSession(runtimeKind: .opencode, title: "First", ownerDeviceID: owner, openCodeAssociation: ("server", "ses_same"))
        let second = try database.createLocalACPSession(runtimeKind: .opencode, title: "Second", ownerDeviceID: owner, openCodeAssociation: ("server", "ses_same"))
        #expect(first == second)
        #expect(try database.openCodeLinks().count == 1)
        #expect(try database.openCodeSnapshot(conversationID: first) == OpenCodeSessionSnapshot())
        #expect(try database.localACPSession(conversationID: first).title == "First")
    }

    @Test func largeCatchupPreservesOlderPageAnchorAndRefreshesLoadedHistory() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.messages = (0..<350).map { message("msg_history_\($0)") }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try database.createLocalACPSession(runtimeKind: .opencode, title: "Paging", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        try await coordinator.refresh(link)
        try await coordinator.loadOlder(link)
        try await coordinator.loadOlder(link)
        let originalCursor = try database.openCodeSnapshot(conversationID: id)?.olderCursor
        fixture.messages += (350..<800).map { message("msg_history_\($0)") }
        try await coordinator.refresh(link)
        #expect(try database.openCodeSnapshot(conversationID: id)?.olderCursor == originalCursor)
        try await coordinator.loadOlder(link)
        #expect(try database.openCodeSnapshot(conversationID: id)?.messages.map { $0["id"].text } == fixture.messages.map { $0["id"].text })
        // A reconnect must also refresh old loaded content, even when the new
        // messages alone exceed the previously loaded history length.
        fixture.messages[0]["text"] = "Updated by another client"
        fixture.messages += (800..<1700).map { message("msg_history_\($0)") }
        try await coordinator.refresh(link, recoverHistory: true)
        let recovered = try #require(try database.openCodeSnapshot(conversationID: id))
        #expect(recovered.messages.count == 1700)
        #expect(recovered.messages.first?["text"].text == "Updated by another client")
        #expect(recovered.olderCursor == nil)
        try await coordinator.refresh(link)
        #expect(try database.openCodeSnapshot(conversationID: id)?.olderCursor == nil)
        await coordinator.shutdown()
    }

    private func connection() throws -> OpenCodeConnection { try .init(identity: "fixture", url: URL(string: "http://fixture.invalid")!, password: "fixture") }
    private func fixtureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return URLSession(configuration: config)
    }
    private func message(_ id: String, time: Double = 1) -> OpenCodeValue { ["id": .string(id), "type": "user", "text": .string(id), "time": ["created": .number(time)]] }
}

private final class OpenCodeFixture: @unchecked Sendable {
    let lock = NSLock()
    let gate = FixtureHealthGate()
    var holdHealth = false
    var version = OpenCodeConnection.supportedVersion
    var messages: [OpenCodeValue] = []
    var losePromptResponse = false
    var acceptPrompt = true
    var promptCount = 0
    var interruptCount = 0
    var historyRequests = 0
    var streamTimeout: TimeInterval?
    func respond(_ request: URLRequest) throws -> (Int, OpenCodeValue) {
        try lock.withLock {
            let path = request.url!.path
            if path.hasSuffix("/log") { streamTimeout = request.timeoutInterval; return (200, [:]) }
            if path == "/api/health" { return (200, ["healthy": .bool(true), "version": .string(version), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))]) }
            if path == "/api/session/active" { return (200, ["data": [:]]) }
            if path.hasSuffix("/interrupt") { interruptCount += 1; return (200, [:]) }
            if path.hasSuffix("/prompt") {
                promptCount += 1
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
                }
                let input = try OpenCodeValue.decode(bytes)
                let message: OpenCodeValue = ["id": input["id"], "text": input["text"], "type": "user", "time": ["created": .number(900)]]
                if acceptPrompt { messages.append(message) }
                if losePromptResponse { throw URLError(.networkConnectionLost) }
                return (200, ["data": message])
            }
            if path.hasSuffix("/message") {
                historyRequests += 1
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                let descending = Array(messages.reversed())
                let cursor = query.first(where: { $0.name == "cursor" })?.value
                if cursor != nil && query.contains(where: { $0.name == "order" }) { return (400, ["message": "Cursor cannot be combined with order"]) }
                let offset = cursor.flatMap { id in descending.firstIndex(where: { $0["id"].text == id }).map { $0 + 1 } } ?? 0
                let values = Array(descending.dropFirst(offset).prefix(100))
                return (200, ["data": .array(values), "cursor": ["next": values.last?["id"] ?? .null]])
            }
            if path.contains("/message/") {
                guard let message = messages.first(where: { $0["id"].text == request.url!.lastPathComponent }) else { return (404, [:]) }
                return (200, ["data": message])
            }
            if path.hasSuffix("/permission") { return (200, ["data": .array([["id": "perm_pending", "sessionID": "ses_fixture", "action": "shell", "resources": .array(["ls"]) ]])]) }
            if path.hasSuffix("/form") { return (200, ["data": .array([["id": "form_pending"], ["id": "form_done"]])]) }
            if path.hasSuffix("/state") { return (200, ["data": ["status": path.contains("form_pending") ? "pending" : "answered"]]) }
            if path.hasSuffix("/inbox") { return (200, ["data": .array([])]) }
            if path == "/api/session/ses_fixture" { return (200, ["data": ["id": "ses_fixture", "title": "Shared fixture", "time": ["updated": .number(900)]]]) }
            return (404, [:])
        }
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture = OpenCodeFixture()
    override class func canInit(with request: URLRequest) -> Bool { ["fixture.invalid", "127.0.0.1"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/api/health", Self.fixture.holdHealth {
            let fixture = Self.fixture
            fixture.gate.arrive(self)
        } else { deliver() }
    }
    func deliver() {
        do {
            let (status, value) = try Self.fixture.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(value))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class FixtureHealthGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: FixtureProtocol?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func arrive(_ request: FixtureProtocol) {
        let ready = lock.withLock { pending = request; let result = waiters; waiters.removeAll(); return result }
        ready.forEach { $0.resume() }
    }
    func waitForArrival() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if pending != nil { return true }; waiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func release() { let request = lock.withLock { let result = pending; pending = nil; return result }; request?.deliver() }
}

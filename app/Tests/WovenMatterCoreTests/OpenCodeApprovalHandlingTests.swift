import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite(.serialized)
struct OpenCodeApprovalHandlingTests {
    @Test(arguments: [false, true])
    func connectionResetRetainsInflightReplyAndPrunesEndedRequest(shutdown: Bool) async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        let pending = request("per_a", "ses_a")
        await context.fixture.setRequests([pending], session: "ses_a")
        await context.fixture.setReplyDelay(.milliseconds(100))
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        let first = Task {
            try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "once")
        }
        try await context.fixture.waitForReplies(1)
        if shutdown { await coordinator.shutdown() }
        else { await coordinator.disconnect(connectionID: context.connection.identity) }
        try await coordinator.connect(context.connection)
        if shutdown {
            // Execution-owner shutdown fences every later response, even when
            // the HTTP client is reconnected. A new owner creates a coordinator.
            await #expect(throws: CancellationError.self) {
                try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "reject")
            }
            await #expect(throws: CancellationError.self) { try await first.value }
            #expect(await context.fixture.replies.count == 1)
            await coordinator.shutdown()
            return
        }
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "reject")
        }
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "reject")
        }
        #expect(await context.fixture.replies.count == 1)

        // An authoritative snapshot retires the guard once the native request
        // has ended; neither reconnect nor shutdown retains historical IDs.
        await context.fixture.setRequests([], session: "ses_a")
        try await coordinator.refresh(context.a)
        await context.fixture.setRequests([pending], session: "ses_a")
        try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "reject")
        #expect(await context.fixture.replies.count == 2)
        await coordinator.shutdown()
    }

    @Test func nativeRequestWithoutRunStillResolvesAfterAssistantProjectionArrives() async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        let pending = request("per_a", "ses_a")
        await context.fixture.setRequests([pending], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        try await coordinator.refresh(context.a)
        #expect(try await context.database.activeRunID(conversationID: context.a.conversationID) == nil)
        await context.fixture.setMessages([["id": "msg_assistant", "type": "assistant", "text": "Working",
            "time": ["created": .number(1000)]]], session: "ses_a", active: true)
        try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "once")
        #expect(try await context.database.activeRunID(conversationID: context.a.conversationID) != nil)
        #expect(await context.fixture.replies.count == 1)
        await coordinator.shutdown()
    }

    @Test func desktopCanAnswerNativePermissionsReservedForMac() async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        var pending = request("per_mac", "ses_a")
        pending["action"] = "credential.read"
        #expect(OpenCodePermissionHandling.companionRequestID(pending, sessionID: "ses_a") == nil)
        await context.fixture.setRequests([pending], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "once")
        #expect(await context.fixture.replies.count == 1)
        await coordinator.shutdown()
    }

    @Test func desktopNormalizedFormPreservesClearedDefaultsAndConditionalFields() async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        let fields: [OpenCodeValue] = [
            ["key": "amount", "type": "integer", "default": .number(2)],
            ["key": "amountDetail", "type": "string", "required": .bool(true),
             "when": .array([["key": "amount", "op": "eq", "value": .number(2)]])],
            ["key": "choice", "type": "string", "default": "suggested"],
            ["key": "enabled", "type": "boolean", "default": .bool(true)],
            ["key": "details", "type": "string", "required": .bool(true),
             "when": .array([["key": "enabled", "op": "eq", "value": .bool(true)]])],
            ["key": "choices", "type": "multiselect", "custom": .bool(true)],
            ["key": "ratio", "type": "number", "minimum": .number(0), "maximum": .number(5)],
            ["key": "verification", "type": "external"]
        ]
        let form: OpenCodeValue = ["id": "form_normalized", "fields": .array(fields)]
        let desktopAnswer = try OpenCodeFormAnswers.reply(fields: fields, answers: [
            "amount": "", "choice": .null, "enabled": .bool(false), "details": "hidden stale value",
            "choices": .array(["custom", "selected"]), "ratio": "2.75", "verification": .bool(true)
        ])
        #expect(desktopAnswer["amount"].isNull && desktopAnswer["choice"].isNull && desktopAnswer["details"].isNull)
        await context.fixture.setForms([form], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        try await coordinator.replyToForm(context.a, expectedRequest: form, expectedRunID: nil, answers: desktopAnswer)
        #expect(await context.fixture.replies.first?.1 == ["answer": desktopAnswer])
        await coordinator.shutdown()
    }

    @Test func nativeManualResponsesValidateCurrentRequestAndResolveOnlyOnce() async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        let pending = request("per_a", "ses_a")
        await context.fixture.setRequests([pending], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "always")
        }
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: "old-run", reply: "once")
        }
        var stale = pending
        stale["resources"] = .array(["different command"])
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.replyToPermission(context.a, expectedRequest: stale, expectedRunID: nil, reply: "once")
        }
        #expect(await context.fixture.replies.isEmpty)
        await context.fixture.setReplyDelay(.milliseconds(50))
        let wins = await withTaskGroup(of: Bool.self) { group in
            for reply in ["once", "reject"] {
                group.addTask {
                    do { try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: reply); return true }
                    catch { return false }
                }
            }
            var winners = 0
            for await succeeded in group where succeeded { winners += 1 }
            return winners
        }
        #expect(wins == 1)
        #expect(await context.fixture.replies.count == 1)
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.replyToPermission(context.a, expectedRequest: pending, expectedRunID: nil, reply: "once")
        }
        #expect(await context.fixture.replies.count == 1)
        await coordinator.shutdown()
    }

    @Test func nativeFormCancelAndDesktopReplyShareResolution() async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        let form: OpenCodeValue = ["id": "form_a", "fields": .array([["key": "answer", "type": "string", "required": .bool(true)]])]
        await context.fixture.setForms([form], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        try await coordinator.cancelForm(context.a, expectedRequest: form, expectedRunID: nil)
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.replyToForm(context.a, expectedRequest: form, expectedRunID: nil, answers: ["answer": "late"])
        }
        let replies = await context.fixture.replies
        #expect(replies.count == 1)
        #expect(replies.first?.0 == "/api/session/ses_a/form/form_a/cancel")
        #expect(replies.first?.1 == .null)
        await coordinator.shutdown()
    }

    @Test func stoppedSessionFencesPermissionAndFormAnswers() async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        _ = try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: "allow")
        await coordinator.cancelPendingInput(conversationID: context.a.conversationID)
        await context.fixture.setRequests([request("per_stopped", "ses_a")], session: "ses_a")
        try await coordinator.refresh(context.a)
        await #expect(throws: CancellationError.self) {
            try await coordinator.sessionCall(context.a, suffix: "/permission/per_stopped/reply", method: "POST", body: ["reply": "once"])
        }
        await #expect(throws: CancellationError.self) {
            try await coordinator.sessionCall(context.a, suffix: "/form/form_stopped/reply", method: "POST", body: ["answer": "yes"])
        }
        _ = try await coordinator.sessionCall(context.a, suffix: "/permission/per_stopped/reply", method: "POST", body: ["reply": "reject"])
        #expect(await context.fixture.replies.map { $0.1 } == [["reply": "reject"]])
        await coordinator.shutdown()
    }

    @Test(arguments: ["ask", "allow", "deny", "unconfirmed"])
    func nativePoliciesRequireCanonicalReadbackWithoutClientReplies(choice: String) async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        let effect = choice == "unconfirmed" ? "allow" : choice
        await context.fixture.setIgnoreNativeWrites(choice == "unconfirmed")
        let original: OpenCodeValue = ["action": "read", "resource": "/fixture/*", "effect": "allow"]
        await context.fixture.setNativeRules([original], session: "ses_a")
        await context.fixture.setRequests([request("per_manual", "ses_a"),
            request("per_auth", "ses_a", action: "auth.login")], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        if choice == "unconfirmed" {
            await #expect(throws: OpenCodeError.self) {
                try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: effect)
            }
            #expect(OpenCodePermissionHandling.nativeMode(session: try await context.database.openCodeSnapshot(conversationID: context.a.conversationID)?.info ?? .null) == nil)
            #expect(await context.fixture.replies.isEmpty)
            await coordinator.shutdown()
            return
        }
        #expect(try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: effect) == effect)
        try await coordinator.refresh(context.a)
        let saved = try #require(await context.database.openCodeSnapshot(conversationID: context.a.conversationID))
        #expect(saved.info["permissions"].array == [original, ["action": "*", "resource": "*", "effect": .string(effect)]])
        #expect(OpenCodeComposerMetadata.metadata(session: saved.info, models: []).permission == effect)
        let reopened = try await WorkspaceDatabase(url: context.directory.appending(path: "workspace.sqlite"))
        let stored = try #require(await reopened.openCodeSnapshot(conversationID: context.a.conversationID))
        #expect(OpenCodeComposerMetadata.metadata(session: stored.info, models: []).permission == effect)
        #expect(await context.fixture.nativeWrites.count == 1)
        #expect(await context.fixture.replies.isEmpty)
        #expect(OpenCodePermissionHandling.nativeMode(session: try await context.database.openCodeSnapshot(conversationID: context.b.conversationID)?.info ?? .null) == nil)
        await coordinator.shutdown()
    }

    @Test func onlyNativeWildcardEffectsArePresentedAsPolicies() throws {
        let custom: OpenCodeValue = ["permissions": .array([["action": "edit", "resource": "*", "effect": "allow"]])]
        #expect(OpenCodePermissionHandling.nativeMode(session: custom) == nil)
        #expect(OpenCodeComposerMetadata.metadata(session: custom, models: []).permission == nil)
        #expect(OpenCodePermissionHandling.options == ["ask", "allow", "deny"])
        for mode in ["full", "auto", "normal", "acceptEdits"] {
            #expect(throws: OpenCodeError.self) { try OpenCodePermissionHandling.validate(mode) }
        }
        for effect in OpenCodePermissionHandling.options {
            let policy = try OpenCodePermissionHandling.selectingNativePolicy(effect, session: custom)
            #expect(policy["permissions"].array.count == 2)
            #expect(OpenCodePermissionHandling.nativeMode(session: policy) == effect)
            let changed = try OpenCodePermissionHandling.selectingNativePolicy("ask", session: policy)
            #expect(changed["permissions"].array.count == 2)
        }
    }

    @Test func rejectedModeNeverIncreasesAuthority() async throws {
        let context = try await ApprovalContext()
        defer { context.clean() }
        await context.fixture.setRequests([request("per_a", "ses_a")], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        _ = try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: "ask")
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: "unknown")
        }
        try await coordinator.refresh(context.a)
        #expect(await context.fixture.replies.isEmpty)
        let saved = try #require(await context.database.openCodeSnapshot(conversationID: context.a.conversationID))
        #expect(OpenCodePermissionHandling.nativeMode(session: saved.info) == "ask")
        await coordinator.shutdown()
    }

    private func request(_ id: String, _ sessionID: String, action: String = "bash") -> OpenCodeValue {
        ["id": .string(id), "sessionID": .string(sessionID), "action": .string(action), "resources": .array(["fixture"])]
    }
}

private struct ApprovalContext {
    let directory: URL
    let database: WorkspaceDatabase
    let connection: OpenCodeConnection
    let fixture = ApprovalHTTPFixture()
    let session: URLSession
    let a: OpenCodeSessionLink
    let b: OpenCodeSessionLink

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        connection = try OpenCodeConnection(identity: "approval-fixture", url: URL(string: "http://127.0.0.1:1")!, username: "fixture", password: "fixture")
        let first = try await database.createLocalACPSession(runtimeKind: .opencode, title: "A", ownerDeviceID: UUID(), openCodeAssociation: (connection.identity, "ses_a"))
        let second = try await database.createLocalACPSession(runtimeKind: .opencode, title: "B", ownerDeviceID: UUID(), openCodeAssociation: (connection.identity, "ses_b"))
        a = .init(conversationID: first, connectionID: connection.identity, sessionID: "ses_a")
        b = .init(conversationID: second, connectionID: connection.identity, sessionID: "ses_b")
        ApprovalURLProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApprovalURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    func coordinator() -> OpenCodeSessionCoordinator {
        let session = session
        return .init(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
    }
    func clean() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
}

private actor ApprovalHTTPFixture {
    var replies: [(String, OpenCodeValue)] = []
    private var requests: [String: [OpenCodeValue]] = [:]
    private var forms: [String: [OpenCodeValue]] = [:]
    private var messages: [String: [OpenCodeValue]] = [:]
    private var activeSessions: Set<String> = []
    private var delay: Duration = .zero
    private var nativeRules: [String: [OpenCodeValue]] = [:]
    private var ignoreNativeWrites = false
    var nativeWrites: [OpenCodeValue] = []
    func setNativeRules(_ rules: [OpenCodeValue], session: String) { nativeRules[session] = rules }
    func setIgnoreNativeWrites(_ ignore: Bool) { ignoreNativeWrites = ignore }
    func setRequests(_ values: [OpenCodeValue], session: String) { requests[session] = values }
    func setForms(_ values: [OpenCodeValue], session: String) { forms[session] = values }
    func setMessages(_ values: [OpenCodeValue], session: String, active: Bool) {
        messages[session] = values
        if active { activeSessions.insert(session) } else { activeSessions.remove(session) }
    }
    func setReplyDelay(_ value: Duration) { delay = value }
    func waitForReplies(_ count: Int) async throws {
        for _ in 0..<100 {
            if replies.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Automatic reply did not arrive")
    }
    func response(_ request: URLRequest) async throws -> (Int, OpenCodeValue) {
        let path = request.url!.path
        if path == "/api/info" { return (200, ["version": .string("2.0.22"), "pid": .number(42)]) }
        if path == "/api/session/active" { return (200, ["data": .object(Dictionary(uniqueKeysWithValues: activeSessions.map { ($0, OpenCodeValue.bool(true)) }))]) }
        let parts = path.split(separator: "/").map(String.init)
        let sessionID = parts.count >= 3 ? parts[2] : ""
        if request.httpMethod == "POST", path.hasSuffix("/reply") || path.hasSuffix("/cancel") {
            let body = try requestBody(request)
            replies.append((path, body.isEmpty ? .null : try JSONDecoder().decode(OpenCodeValue.self, from: body)))
            if delay > .zero { try await Task.sleep(for: delay) }
            return (204, .null)
        }
        if request.httpMethod == "PATCH", parts.count == 3 {
            let body = try requestBody(request)
            let policy = try JSONDecoder().decode(OpenCodeValue.self, from: body)
            nativeWrites.append(policy)
            if !ignoreNativeWrites { nativeRules[sessionID] = policy["permissions"].array }
            return (204, .null)
        }
        if path.hasSuffix("/permission") { return (200, ["data": .array(requests[sessionID] ?? [])]) }
        if path.hasSuffix("/form") { return (200, ["data": .array(forms[sessionID] ?? [])]) }
        if path.hasSuffix("/message") { return (200, ["data": .array(Array((messages[sessionID] ?? []).reversed()))]) }
        if path.hasSuffix("/form/form_a") || path.hasSuffix("/form/form_normalized") { return (200, ["data": ["state": ["status": "pending"]]]) }
        if parts.count == 3 {
            var info: OpenCodeValue = ["id": .string(sessionID), "location": ["directory": "/fixture"]]
            if let rules = nativeRules[sessionID] { info["permissions"] = .array(rules) }
            return (200, ["data": info])
        }
        return (200, ["data": .array([])])
    }
    private func requestBody(_ request: URLRequest) throws -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var body = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { throw stream.streamError ?? OpenCodeError.message("Could not read fixture request body.") }
            if count == 0 { break }
            body.append(contentsOf: bytes.prefix(count))
        }
        return body
    }
}

private final class ApprovalURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture: ApprovalHTTPFixture!
    private var operation: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.fixture!
        operation = Task {
            do {
                let (status, payload) = try await fixture.response(request)
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                if status != 204 { client?.urlProtocol(self, didLoad: try JSONEncoder().encode(payload)) }
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { operation?.cancel() }
}

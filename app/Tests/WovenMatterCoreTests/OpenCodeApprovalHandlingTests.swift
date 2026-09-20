import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite(.serialized)
struct OpenCodeApprovalHandlingTests {
    @Test func automaticRepliesStayInOneSessionAndNeverHandleFormsOrAuthentication() async throws {
        let context = try ApprovalContext()
        defer { context.clean() }
        let fixture = context.fixture
        await fixture.setRequests([
            request("per_a", "ses_a"), request("per_other", "ses_b"),
            request("per_auth", "ses_a", action: "auth.login"),
            request("per_form", "ses_a", type: "form"),
            request("per_denied", "ses_a", effect: "deny")
        ], session: "ses_a")
        await fixture.setRequests([request("per_b", "ses_b")], session: "ses_b")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        _ = try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: "auto")
        try await coordinator.refresh(context.a)
        try await coordinator.refresh(context.b)
        try await fixture.waitForReplies(1)
        let replies = await fixture.replies
        #expect(replies.map(\.0) == ["/api/session/ses_a/permission/per_a/reply"])
        #expect(replies.allSatisfy { $0.1 == ["reply": "once"] })
        #expect(try context.database.openCodeSnapshot(conversationID: context.a.conversationID)?.approvalMode == "auto")
        #expect(try context.database.openCodeSnapshot(conversationID: context.b.conversationID)?.approvalMode == nil)
        await coordinator.shutdown()
    }

    @Test func repeatedSnapshotsDoNotRepeatAcceptedReplies() async throws {
        let context = try ApprovalContext()
        defer { context.clean() }
        await context.fixture.setRequests([request("per_a", "ses_a")], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        _ = try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: "auto")
        try await coordinator.refresh(context.a)
        try await context.fixture.waitForReplies(1)
        for _ in 0..<3 { try await coordinator.refresh(context.a) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await context.fixture.replies.count == 1)
        await coordinator.shutdown()
    }

    @Test func normalModeCancelsQueuedRepliesAndPersistsAcrossReopening() async throws {
        let context = try ApprovalContext()
        defer { context.clean() }
        await context.fixture.setReplyDelay(.milliseconds(200))
        await context.fixture.setRequests([request("per_a", "ses_a"), request("per_second", "ses_a")], session: "ses_a")
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        _ = try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: "auto")
        try await coordinator.refresh(context.a)
        try await context.fixture.waitForReplies(1)
        _ = try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: "normal")
        try await coordinator.refresh(context.a)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await context.fixture.replies.count == 1)
        let reopened = try WorkspaceDatabase(url: context.directory.appending(path: "workspace.sqlite"))
        #expect(try reopened.openCodeSnapshot(conversationID: context.a.conversationID)?.approvalMode == "normal")
        await coordinator.shutdown()
    }

    @Test func reconnectRestoresModeAndOnlyUsesFreshPendingRequests() async throws {
        let context = try ApprovalContext()
        defer { context.clean() }
        let first = context.coordinator()
        try await first.connect(context.connection)
        _ = try await first.setSessionPermission(conversationID: context.a.conversationID, permission: "auto")
        await first.disconnect(connectionID: context.connection.identity)
        await context.fixture.setRequests([request("per_reconnected", "ses_a")], session: "ses_a")
        // Reopening a coordinator also proves that mode is durable, not just an actor flag.
        let second = context.coordinator()
        try await second.connect(context.connection)
        try await second.refresh(context.a)
        try await context.fixture.waitForReplies(1)
        #expect(await context.fixture.replies.first?.0 == "/api/session/ses_a/permission/per_reconnected/reply")
        await first.shutdown(); await second.shutdown()
    }

    @Test func nativeDenyWithoutPendingRequestNeedsNoReplyAndOldSnapshotsStayNormal() async throws {
        let context = try ApprovalContext()
        defer { context.clean() }
        let coordinator = context.coordinator()
        try await coordinator.connect(context.connection)
        _ = try await coordinator.setSessionPermission(conversationID: context.a.conversationID, permission: "auto")
        try await coordinator.refresh(context.a)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await context.fixture.replies.isEmpty)
        let old = try JSONDecoder().decode(OpenCodeSessionSnapshot.self, from: JSONEncoder().encode(OpenCodeSessionSnapshot()))
        #expect(old.approvalMode == nil)
        let metadata = OpenCodeComposerMetadata.metadata(session: ["id": "ses_a"], models: [])
        #expect(metadata.permission == "normal")
        #expect(metadata.permissionOptions == ["normal", "auto"])
        await coordinator.shutdown()
    }

    private func request(_ id: String, _ sessionID: String, action: String = "bash", type: String? = nil, effect: String? = nil) -> OpenCodeValue {
        var result: OpenCodeValue = ["id": .string(id), "sessionID": .string(sessionID), "action": .string(action), "resources": .array(["fixture"])]
        if let type { result["type"] = .string(type) }
        if let effect { result["effect"] = .string(effect) }
        return result
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

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        connection = try OpenCodeConnection(identity: "approval-fixture", url: URL(string: "http://127.0.0.1:1")!, username: "fixture", password: "fixture")
        let first = try database.createLocalACPSession(runtimeKind: .opencode, title: "A", ownerDeviceID: UUID(), openCodeAssociation: (connection.identity, "ses_a"))
        let second = try database.createLocalACPSession(runtimeKind: .opencode, title: "B", ownerDeviceID: UUID(), openCodeAssociation: (connection.identity, "ses_b"))
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
    private var delay: Duration = .zero
    func setRequests(_ values: [OpenCodeValue], session: String) { requests[session] = values }
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
        if path == "/api/health" { return (200, ["version": .string(OpenCodeConnection.supportedVersion), "healthy": .bool(true)]) }
        if path == "/api/session/active" { return (200, ["data": [:]]) }
        let parts = path.split(separator: "/").map(String.init)
        let sessionID = parts.count >= 3 ? parts[2] : ""
        if request.httpMethod == "POST", path.hasSuffix("/reply") {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count))
                }
            }
            replies.append((path, try JSONDecoder().decode(OpenCodeValue.self, from: body)))
            if delay > .zero { try await Task.sleep(for: delay) }
            return (204, .null)
        }
        if path.hasSuffix("/permission") { return (200, ["data": .array(requests[sessionID] ?? [])]) }
        if parts.count == 3 { return (200, ["data": ["id": .string(sessionID), "location": ["directory": "/fixture"]]]) }
        return (200, ["data": .array([])])
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

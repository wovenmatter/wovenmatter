import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

@MainActor
struct WorkspaceAgentToolsServiceTests {
    @Test func folderSearchIgnoresItsOwnRequestJournalAndRetainsExplicitAuditAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let local = try database.createFolder(name: "Caller folder")
        let elsewhere = try database.createFolder(name: "Other folder")
        let caller = try database.createLocalACPSession(runtimeKind: .codex, title: "Caller", ownerDeviceID: UUID())
        let target = try database.createLocalACPSession(runtimeKind: .pi, title: "Relevant work", ownerDeviceID: UUID())
        _ = try database.moveConversation(id: caller, toFolderID: local)
        _ = try database.moveConversation(id: target, toFolderID: elsewhere)
        try database.recordHistory(.init(id: "actual-result", conversationID: target, harness: "pi",
            kind: "wire.in", payload: "rare-search-phrase in the other folder"))
        let service = try WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { service.stop() }
        let endpoint = try service.endpoint(for: caller)
        func request(_ arguments: [String]) async throws -> WovenMatterToolResponse {
            let data = try JSONEncoder().encode(WovenMatterToolRequest(arguments: arguments))
            let response = try await Task.detached { try WovenMatterCommandLine.forward(data, to: endpoint) }.value
            return try JSONDecoder().decode(WovenMatterToolResponse.self, from: response)
        }
        // Repeat through the actual bound socket handler: both this request and
        // earlier request journals must not manufacture a caller-folder hit.
        for _ in 0..<2 {
            let response = try await request(["history", "search", "rare-search-phrase"])
            #expect(response.success)
            #expect(response.result?.objectValue?["scope"]?.stringValue == "workspace")
            let rows = response.result?.objectValue?["rows"]?.arrayValue ?? []
            #expect(rows.count == 1)
            #expect(rows.first?.objectValue?["id"]?.stringValue == "actual-result")
        }
        let audit = try await request(["history", "events", "--conversation", caller, "--kind", "cli.request"])
        #expect(audit.success)
        #expect((audit.result?.objectValue?["rows"]?.arrayValue?.count ?? 0) >= 2)
        let explicitAudit = try await request(["history", "search", "rare-search-phrase", "--kind", "cli.request"])
        #expect(explicitAudit.result?.objectValue?["scope"]?.stringValue == "folder")
        #expect(explicitAudit.result?.objectValue?["rows"]?.arrayValue?.isEmpty == false)
        try database.recordHistory(.init(id: "local-result", conversationID: caller, harness: "codex",
            kind: "wire.in", payload: "rare-search-phrase now exists locally"))
        let localResponse = try await request(["history", "search", "rare-search-phrase"])
        #expect(localResponse.result?.objectValue?["scope"]?.stringValue == "folder")
        #expect(localResponse.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["id"]?.stringValue == "local-result")
    }
}

extension WorkspaceAgentToolsServiceTests {
    @Test(.timeLimit(.minutes(1)))
    func relayResponseCanHandItsSlotToTheNextRequestBeforeWriteReturns() async throws {
        let fixture = try RelayForwardingFixture()
        defer { fixture.stop() }
        let firstID = UUID().uuidString, replacementID = UUID().uuidString
        let replacement = try fixture.request(slow: false)
        let output = RelayOutputCapture()
        let holder = RelayForwarderReference()
        let forwarder = WovenMatterRelayForwarder(localSocket: fixture.endpoint.path, maximumConnections: 1,
            write: { data in
                output.append(data)
                if (try JSONDecoder().decode(GatewayJSONValue.self, from: data)).objectValue?["id"]?.stringValue == firstID {
                    // Model the remote reader releasing its slot as soon as it
                    // reads the newline, while the old write is still returning.
                    try holder.value?.submit(id: replacementID, request: replacement)
                }
            }, onFailure: { output.fail($0) })
        holder.value = forwarder
        defer { forwarder.stop() }
        try forwarder.submit(id: firstID, request: fixture.request(slow: false))
        await forwarder.waitUntilIdle()
        let ids = try output.lines.map { try JSONDecoder().decode(GatewayJSONValue.self, from: $0).objectValue?["id"]?.stringValue }
        #expect(ids == [firstID, replacementID])
        #expect(output.errors.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func stalledRelayCallDoesNotBlockAFastConcurrentReply() async throws {
        let fixture = try RelayForwardingFixture()
        defer { fixture.stop() }
        let slow = UUID().uuidString, fast = UUID().uuidString
        let fastReply = DispatchSemaphore(value: 0)
        let output = RelayOutputCapture()
        let forwarder = WovenMatterRelayForwarder(localSocket: fixture.endpoint.path, write: { data in
            output.append(data)
            if (try? JSONDecoder().decode(GatewayJSONValue.self, from: data))?.objectValue?["id"]?.stringValue == fast {
                fastReply.signal()
            }
        }, onFailure: { output.fail($0) })
        defer { forwarder.stop() }
        try forwarder.submit(id: slow, request: fixture.request(slow: true))
        await fixture.gate.waitUntilPaused()
        try forwarder.submit(id: fast, request: fixture.request(slow: false))
        let fastFinished = await Task.detached { waitForRelaySignal(fastReply) }.value
        #expect(fastFinished, "The fast request was held behind a stalled request")
        await fixture.gate.release()
        await forwarder.waitUntilIdle()
        let packets = try output.lines.map { try JSONDecoder().decode(GatewayJSONValue.self, from: $0) }
        #expect(packets.count == 2)
        #expect(packets.first?.objectValue?["id"]?.stringValue == fast)
        #expect(Set(packets.compactMap { $0.objectValue?["id"]?.stringValue }) == [slow, fast])
        #expect(output.errors.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func relayAdmissionIsBoundedAndShutdownInterruptsBlockedSockets() async throws {
        let fixture = try RelayForwardingFixture()
        defer { fixture.stop() }
        let output = RelayOutputCapture()
        let forwarder = WovenMatterRelayForwarder(localSocket: fixture.endpoint.path, maximumConnections: 1,
            write: { output.append($0) }, onFailure: { output.fail($0) })
        let id = UUID().uuidString
        try forwarder.submit(id: id, request: fixture.request(slow: true))
        await fixture.gate.waitUntilPaused()
        #expect(throws: (any Error).self) { try forwarder.submit(id: UUID().uuidString, request: fixture.request(slow: false)) }
        #expect(throws: (any Error).self) { try forwarder.submit(id: id, request: fixture.request(slow: false)) }
        forwarder.stop()
        await forwarder.waitUntilIdle()
        #expect(output.lines.isEmpty)
        #expect(throws: (any Error).self) { try forwarder.submit(id: UUID().uuidString, request: fixture.request(slow: false)) }
        await fixture.gate.release()
    }

    @Test(.timeLimit(.minutes(1)))
    func relayTimeoutRetainsRequestIdentityAndWriterFailureRetiresForwarder() async throws {
        let fixture = try RelayForwardingFixture()
        defer { fixture.stop() }
        let output = RelayOutputCapture()
        let forwarder = WovenMatterRelayForwarder(localSocket: fixture.endpoint.path, timeout: 0.05,
            write: { output.append($0) }, onFailure: { output.fail($0) })
        let requestID = UUID().uuidString
        try forwarder.submit(id: UUID().uuidString, request: fixture.request(slow: true, requestID: requestID))
        await forwarder.waitUntilIdle()
        let packet = try JSONDecoder().decode(GatewayJSONValue.self, from: #require(output.lines.first))
        let responseData = try #require(packet.objectValue?["payload"]?.stringValue.flatMap { Data(base64Encoded: $0) })
        let response = try JSONDecoder().decode(WovenMatterToolResponse.self, from: responseData)
        #expect(!response.success && response.requestID == requestID)
        forwarder.stop()
        await fixture.gate.release()
        let broken = WovenMatterRelayForwarder(localSocket: fixture.endpoint.path,
            write: { _ in throw CancellationError() }, onFailure: { output.fail($0) })
        try broken.submit(id: UUID().uuidString, request: fixture.request(slow: false))
        await broken.waitUntilIdle()
        #expect(output.errors.count == 1)
        #expect(throws: (any Error).self) { try broken.submit(id: UUID().uuidString, request: fixture.request(slow: false)) }
    }
}

private func waitForRelaySignal(_ signal: DispatchSemaphore) -> Bool {
    signal.wait(timeout: .now() + 3) == .success
}

private final class RelayForwarderReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var forwarder: WovenMatterRelayForwarder?
    var value: WovenMatterRelayForwarder? {
        get { lock.withLock { forwarder } }
        set { lock.withLock { forwarder = newValue } }
    }
}

private final class RelayOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    private var failures: [String] = []
    var lines: [Data] { lock.withLock { values } }
    var errors: [String] { lock.withLock { failures } }
    func append(_ data: Data) { lock.withLock { values.append(data) } }
    func fail(_ error: any Error) { lock.withLock { failures.append(error.localizedDescription) } }
}

private actor RelayServiceGate {
    private var paused = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        paused = true
        observers.forEach { $0.resume() }; observers.removeAll()
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
}

private struct RelayForwardingFixture {
    let root: URL
    let endpoint: URL
    let gate = RelayServiceGate()
    let service: WovenMatterToolService
    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/wmf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        endpoint = root.appending(path: "rpc.sock")
        let gate = gate
        service = WovenMatterToolService(socketURL: endpoint, maximumConnections: 4) { request in
            if request.arguments.contains("slow") { await gate.pause() }
            return WovenMatterToolResponse(result: .object(["ok": .bool(true)]), requestID: request.requestID)
        }
        try service.start()
    }
    func request(slow: Bool, requestID: String = UUID().uuidString) throws -> Data {
        try JSONEncoder().encode(WovenMatterToolRequest(arguments: [slow ? "slow" : "fast"], requestID: requestID))
    }
    func stop() {
        try? service.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

import Darwin
import Foundation
import Observation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor
struct WorkspaceAgentToolsServiceTests {
    @Test func folderSearchIgnoresItsOwnRequestJournalAndRetainsExplicitAuditAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let local = try await database.createFolder(name: "Caller folder")
        let elsewhere = try await database.createFolder(name: "Other folder")
        let caller = try await database.createLocalACPSession(runtimeKind: .codex, title: "Caller", ownerDeviceID: UUID())
        let target = try await database.createLocalACPSession(runtimeKind: .pi, title: "Relevant work", ownerDeviceID: UUID())
        _ = try await database.moveConversation(id: caller, toFolderID: local)
        _ = try await database.moveConversation(id: target, toFolderID: elsewhere)
        try await database.recordHistory(.init(id: "actual-result", conversationID: target, harness: "pi",
            kind: "wire.in", payload: "rare-search-phrase in the other folder"))
        let service = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { service.stop() }
        let endpoint = try await service.endpoint(for: caller)
        func request(_ arguments: [String]) async throws -> WovenMatterToolResponse {
            let data = try JSONEncoder().encode(WovenMatterToolRequest(arguments: arguments))
            let response = try await runBlockingToolFixture { try WovenMatterCommandLine.forward(data, to: endpoint) }
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
        #expect(audit.result?.objectValue?["rows"]?.arrayValue?.isEmpty == true)
        let reads = try await request(["history", "events", "--conversation", caller, "--kind", "cli.history.read"])
        #expect((reads.result?.objectValue?["rows"]?.arrayValue?.count ?? 0) >= 2)
        #expect(reads.result?.objectValue?["rows"]?.arrayValue?.allSatisfy {
            $0.objectValue?["payload"]?.stringValue?.contains("rare-search-phrase") == false
        } == true)
        let explicitAudit = try await request(["history", "search", "rare-search-phrase", "--kind", "cli.request"])
        #expect(explicitAudit.result?.objectValue?["rows"]?.arrayValue?.isEmpty == true)
        try await database.recordHistory(.init(id: "local-result", conversationID: caller, harness: "codex",
            kind: "wire.in", payload: "rare-search-phrase now exists locally"))
        let localResponse = try await request(["history", "search", "rare-search-phrase"])
        #expect(localResponse.result?.objectValue?["scope"]?.stringValue == "folder")
        #expect(localResponse.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["id"]?.stringValue == "local-result")
    }
}

extension WorkspaceAgentToolsServiceTests {
    @Test func policiesAreFailClosedUntilAsyncObservationAndRemovedPanelsStayRemoved() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        #expect(model.sessionPolicies[fixture.caller] == nil)
        #expect(model.policy(for: fixture.caller).enabled.isEmpty)
        let token = UUID()
        await model.observeSession(fixture.caller, token: token)
        #expect(model.policy(for: fixture.caller) == (try await fixture.database.sessionTools(fixture.caller)))
        let refresh = Task { try? await model.reload() }
        await model.observeSession(nil, token: token)
        await refresh.value
        #expect(model.receipts[fixture.caller] == nil)
        #expect(!model.hasOlderReceipts.contains(fixture.caller))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [1, 65_536])
    func localSocketOverloadReturnsStructuredBusyResponse(payloadBytes: Int) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/wm-overload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = root.appending(path: "rpc.sock")
        let gate = RelayServiceGate()
        let service = WovenMatterToolService(socketURL: endpoint, maximumConnections: 1) { request in
            if request.arguments.contains("slow") { await gate.pause() }
            return .init(result: .object(["ok": .bool(true)]), requestID: request.requestID)
        }
        try service.start(); defer { try? service.stop() }
        let slow = try JSONEncoder().encode(WovenMatterToolRequest(arguments: ["slow"]))
        let fast = try JSONEncoder().encode(WovenMatterToolRequest(arguments: [String(repeating: "f", count: payloadBytes)]))
        // This connection only occupies the server slot. It has no reply deadline:
        // parallel MainActor tests may delay this test after the handler is parked.
        // Only the second request's bounded overload reply is under test.
        let occupiedSocket = try await runBlockingToolFixture {
            try openParkedToolRequest(slow, to: endpoint.path)
        }
        defer { Darwin.close(occupiedSocket) }
        await gate.waitUntilPaused()
        let overloaded = try await runBlockingToolFixture {
            Result { try WovenMatterCommandLine.forward(fast, to: endpoint.path, timeout: 2) }
        }
        await gate.release()
        let response = try JSONDecoder().decode(WovenMatterToolResponse.self, from: overloaded.get())
        #expect(!response.success && response.code == "busy")
    }

    @Test func mutationHistoryIsMetadataOnlyAndNoteReadsAreChunked() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cli-hardening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try await database.createLocalACPSession(runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID())
        let historian = try await database.createLocalACPSession(runtimeKind: .pi, title: "Historian", ownerDeviceID: UUID())
        try await database.setSessionTools(.init(enabled: [.history]), sessionID: historian)
        let model = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { caller, request, id in
                switch request.command {
                case .read: return try await database.readNoteForEditing(id: request.noteID, callerConversationID: caller)
                case .apply: return try await database.applyNoteEdits(request, callerConversationID: caller, requestID: id)
                }
            },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { model.stop() }
        try await database.beginCoordination(sourceID: caller, targetID: historian, purpose: "Audit")
        let status = await model.handle(.init(arguments: ["sessions", "status", historian]), callerID: caller)
        #expect(status.result?.objectValue?["relationship"]?.objectValue?["coordinationEpoch"]?.stringValue != nil)
        let note = try await database.createNote(folderID: nil, title: "Private", callerConversationID: caller,
            requestID: UUID().uuidString)
        let missingRevision = await model.handle(.init(arguments: ["notes", "set-title", "--note-id", note,
            "--title", "Unsafe overwrite"]), callerID: caller)
        #expect(!missingRevision.success && missingRevision.code == "revision_required")
        let secret = "private-body-" + UUID().uuidString.lowercased() + String(repeating: "x", count: 100)
        let requestID = UUID().uuidString
        let arguments = ["notes", "append", "--note-id", note, "--text", secret]
        let first = await model.handle(.init(arguments: arguments, requestID: requestID), callerID: caller)
        let replay = await model.handle(.init(arguments: arguments, requestID: requestID.lowercased()), callerID: caller)
        #expect(first.success && replay.success)
        #expect(first.result?.objectValue?["document"] == nil)
        #expect(replay.result?.objectValue?["replayed"]?.boolValue == true)
        #expect(try await database.readNoteForEditing(id: note).document?.plainText
            .components(separatedBy: secret).count == 2)

        let mismatchedID = UUID().uuidString.lowercased()
        let mismatch = await model.handle(.init(arguments: arguments + ["--request-id", mismatchedID],
            requestID: UUID().uuidString), callerID: caller)
        #expect(!mismatch.success && mismatch.code == "invalid_request")
        #expect(mismatch.error?.contains("match the request envelope") == true)
        #expect(try await database.readNoteForEditing(id: note).document?.plainText
            .components(separatedBy: secret).count == 2)

        let read = await model.handle(.init(arguments: ["notes", "read", note,
            "--characters", "10"]), callerID: caller)
        #expect(read.result?.objectValue?["content"]?.stringValue?.count == 10)
        #expect(read.result?.objectValue?["hasMore"]?.boolValue == true)
        let audit = await model.handle(.init(arguments: ["history", "events", "--conversation", caller,
            "--kind", "cli.mutation"]), callerID: historian)
        let payloads = audit.result?.objectValue?["rows"]?.arrayValue?.compactMap {
            $0.objectValue?["payload"]?.stringValue
        } ?? []
        #expect(!payloads.isEmpty && payloads.allSatisfy { !$0.contains(secret) })
        let oldBodies = await model.handle(.init(arguments: ["history", "events", "--conversation", caller,
            "--kind", "cli.response"]), callerID: historian)
        #expect(oldBodies.result?.objectValue?["rows"]?.arrayValue?.isEmpty == true)

        let missing = await model.handle(.init(arguments: ["history", "message", UUID().uuidString]),
            callerID: historian)
        #expect(!missing.success && missing.code == "not_found")
    }

    @Test func oversizedResponsesFailStructurallyAndCanBeReadInSmallerPages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try await database.createLocalACPSession(runtimeKind: .codex, title: "Reader", ownerDeviceID: UUID())
        let model = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { model.stop() }
        for _ in 0..<20 {
            try await database.saveSessionTimer(.init(sessionID: caller, instruction: String(repeating: "x", count: 65_536),
                nextFireAt: Date(timeIntervalSince1970: 4_000_000_000)), callerID: caller)
        }
        let request = WovenMatterToolRequest(arguments: ["timers", "list"])
        let response = await model.handle(request, callerID: caller)
        #expect(!response.success && response.code == "response_too_large")
        #expect(response.requestID == request.requestID)
        #expect(try JSONEncoder().encode(response).count <= 1_048_576)
        let smaller = await model.handle(.init(arguments: ["timers", "list", "--limit", "2"]), callerID: caller)
        #expect(smaller.success && smaller.result?.objectValue?["hasMore"]?.boolValue == true)
        let missing = await model.handle(.init(arguments: ["sessions", "status", UUID().uuidString]), callerID: caller)
        #expect(!missing.success && missing.code == "not_found")
    }

    @Test func legacyNoteCLIUsesCurrentEnvironmentNameAndExplainsMalformedJSON() throws {
        let noteID = UUID().uuidString.lowercased()
        let read = try WovenNoteCommandLine.request(arguments: ["read"],
            environment: ["WOVENMATTER_NOTE_ID": noteID])
        #expect(read.noteID == noteID)
        do {
            _ = try WovenNoteCommandLine.request(arguments: ["apply", "--json", "{"],
                environment: ["WOVENMATTER_NOTE_ID": noteID])
            Issue.record("Expected malformed JSON to fail")
        } catch {
            #expect(error.localizedDescription.contains("Invalid operations JSON"))
        }
    }

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
        let fastFinished = await waitForRelaySignal(fastReply)
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
    func relayWriterFailureRetiresBeforeNotifyingObservers() async throws {
        let fixture = try RelayForwardingFixture()
        defer { fixture.stop() }
        let holder = RelayForwarderReference()
        let output = RelayOutputCapture()
        let replacement = try fixture.request(slow: false)
        let forwarder = WovenMatterRelayForwarder(localSocket: fixture.endpoint.path,
            write: { _ in throw CancellationError() }, onFailure: { error in
                output.fail(error)
                // A failure observer must never be able to queue another request
                // onto a writer that has already failed. Attempt it only once.
                if output.errors.count == 1 {
                    #expect(throws: CancellationError.self) {
                        try holder.value?.submit(id: UUID().uuidString, request: replacement)
                    }
                }
            })
        holder.value = forwarder
        defer { forwarder.stop() }
        try forwarder.submit(id: UUID().uuidString, request: replacement)
        // Idle ownership is released only after the failure observer returns.
        // Await that lifecycle boundary, not an unrelated wall-clock deadline.
        await forwarder.waitUntilIdle()
        #expect(output.errors.count == 1)
        #expect(throws: CancellationError.self) { try forwarder.submit(id: UUID().uuidString, request: replacement) }
    }

    @Test(.timeLimit(.minutes(1)))
    func relayTimeoutRetainsRequestIdentity() async throws {
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
        #expect(!response.success && response.requestID == requestID.lowercased())
        forwarder.stop()
        await fixture.gate.release()

    }
}

// Send a complete request and retain its socket without starting a response
// timeout. The caller closes it after the deliberately paused handler is released.
private func openParkedToolRequest(_ request: Data, to path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw WovenNoteSocketError.system(errno) }
    do {
        try configureSocket(descriptor)
        var address = try unixAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw WovenNoteSocketError.system(errno) }
            try waitForSocket(descriptor, events: POLLOUT, deadline: ProcessInfo.processInfo.systemUptime + 2)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
                throw WovenNoteSocketError.system(errno)
            }
            guard error == 0 else { throw WovenNoteSocketError.system(error) }
        }
        try writeMessage(request, to: descriptor, timeout: 2)
        guard Darwin.shutdown(descriptor, SHUT_WR) == 0 else { throw WovenNoteSocketError.system(errno) }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

// Socket reads and semaphore waits must not occupy Swift's cooperative workers:
// the server tasks being tested need those workers to produce their responses.
private func runBlockingToolFixture<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            do { continuation.resume(returning: try body()) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

private func waitForRelaySignal(_ signal: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "relay-fixture-reply").async {
            // Never occupy the cooperative executor while the reply handler
            // needs it. Allow CI scheduling latency, but still require the fast
            // reply before the deliberately held slow request is released.
            continuation.resume(returning: signal.wait(timeout: .now() + 30) == .success)
        }
    }
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

extension WorkspaceAgentToolsServiceTests {
    @Test func unchangedToolSnapshotsDoNotInvalidateConversationObservers() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        let token = UUID()
        await model.observeSession(fixture.caller, token: token)
        try await model.setEnabled(.calendar, enabled: false, sessionID: fixture.caller)
        let changes = observeToolSnapshotChanges {
            _ = model.settings
            _ = model.relationships
            _ = model.timers
            _ = model.sessionPolicies
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        // Exercise the actual one-second scheduler's refresh entry point without
        // a timer, provider service, or UI. An empty chat must stay quiet too.
        for _ in 0..<20 { try await model.reload() }
        await model.observeSession(fixture.caller, token: token)
        #expect(changes.count == 0)
        #expect(model.receipts[fixture.caller]?.isEmpty == true)
        #expect(!model.hasOlderReceipts.contains(fixture.caller))
    }

    @Test func receiptPayloadChangesPublishEvenWhenIDsAndCountsStayTheSame() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        await model.observeSession(fixture.caller, token: UUID())
        let inserted = observeToolSnapshotChanges { _ = model.receipts }
        let delivery = try await fixture.database.reserveToolDelivery(sourceID: fixture.caller,
            targetID: fixture.target, text: "Review the result", requestID: UUID().uuidString)
        try await model.reload()
        #expect(inserted.count == 1)
        #expect(model.receipts[fixture.caller]?.map(\.id) == [delivery.id])

        let statusChanged = observeToolSnapshotChanges { _ = model.receipts }
        try await fixture.database.setToolDeliveryStatus(id: delivery.id, status: "failed")
        try await model.reload()
        #expect(statusChanged.count == 1)
        #expect(model.receipts[fixture.caller]?.first?.status == "failed")

        // A payload change with the same status must not be hidden by an
        // identity/status-only comparison either.
        let payloadChanged = observeToolSnapshotChanges { _ = model.receipts }
        let messageID = UUID().uuidString
        try await fixture.database.setToolDeliveryStatus(id: delivery.id, status: "failed", messageID: messageID)
        try await model.reload()
        #expect(payloadChanged.count == 1)
        #expect(model.receipts[fixture.caller]?.first?.messageID == messageID)
        #expect(model.receipts[fixture.caller]?.map(\.id) == [delivery.id])

        let unchanged = observeToolSnapshotChanges {
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        for _ in 0..<5 { try await model.reload() }
        #expect(unchanged.count == 0)
    }

    @Test func receiptObservationRetainsPagedWindowsAndSharedPanelOwnership() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        var ids: [String] = []
        for index in 0..<205 {
            let delivery = try await fixture.database.reserveToolDelivery(sourceID: fixture.caller,
                targetID: fixture.target, text: "Instruction \(index)", requestID: UUID().uuidString)
            ids.append(delivery.id)
        }
        let firstPanel = UUID(), secondPanel = UUID()
        await model.observeSession(fixture.caller, token: firstPanel)
        #expect(model.receipts[fixture.caller]?.map(\.id) == Array(ids.suffix(200).reversed()))
        #expect(model.hasOlderReceipts.contains(fixture.caller))
        let unchanged = observeToolSnapshotChanges {
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        try await model.reload()
        await model.observeSession(fixture.caller, token: secondPanel)
        await model.observeSession(nil, token: firstPanel)
        #expect(unchanged.count == 0)

        let olderChanged = observeToolSnapshotChanges { _ = model.hasOlderReceipts }
        await model.loadOlderReceipts(sessionID: fixture.caller)
        #expect(olderChanged.count == 1)
        #expect(model.receipts[fixture.caller]?.map(\.id) == Array(ids.reversed()))
        #expect(!model.hasOlderReceipts.contains(fixture.caller))
        let exhausted = observeToolSnapshotChanges {
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        await model.loadOlderReceipts(sessionID: fixture.caller)
        try await model.reload()
        #expect(exhausted.count == 0)

        let newest = try await fixture.database.reserveToolDelivery(sourceID: fixture.caller,
            targetID: fixture.target, text: "Latest", requestID: UUID().uuidString)
        try await fixture.database.setToolDeliveryStatus(id: ids[0], status: "cancelled")
        try await model.reload()
        #expect(model.receipts[fixture.caller]?.map(\.id) == [newest.id] + ids.reversed())
        #expect(model.receipts[fixture.caller]?.last?.status == "cancelled")
        let removed = observeToolSnapshotChanges { _ = model.receipts }
        await model.observeSession(nil, token: secondPanel)
        #expect(removed.count == 1)
        #expect(model.receipts.isEmpty)
        #expect(model.hasOlderReceipts.isEmpty)
    }

    @Test func changedSettingsPoliciesAndTimersStillPublish() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        try await model.setEnabled(.calendar, enabled: false, sessionID: fixture.caller)
        let settingsChanged = observeToolSnapshotChanges { _ = model.settings }
        let policiesChanged = observeToolSnapshotChanges { _ = model.sessionPolicies }
        let timersChanged = observeToolSnapshotChanges { _ = model.timers }
        var settings = model.settings
        settings.maximumManagedSessions += 1
        try await fixture.database.saveToolSettings(settings)
        let policy = WorkspaceSessionTools(enabled: [.sessions, .timers])
        try await fixture.database.setSessionTools(policy, sessionID: fixture.caller)
        let timer = WorkspaceSessionTimer(sessionID: fixture.caller, instruction: "Check the result",
            nextFireAt: Date(timeIntervalSince1970: 4_000_000_000))
        try await fixture.database.saveSessionTimer(timer, callerID: fixture.caller)
        try await model.reload()
        #expect(settingsChanged.count == 1)
        #expect(policiesChanged.count == 1)
        #expect(timersChanged.count == 1)
        #expect(model.settings == settings)
        #expect(model.sessionPolicies[fixture.caller] == policy)
        #expect(model.timers == [timer])
        let unchanged = observeToolSnapshotChanges {
            _ = model.settings
            _ = model.relationships
            _ = model.timers
            _ = model.sessionPolicies
        }
        for _ in 0..<5 { try await model.reload() }
        #expect(unchanged.count == 0)
    }
}

@MainActor
private func observeToolSnapshotChanges(_ read: () -> Void) -> ToolSnapshotChanges {
    let changes = ToolSnapshotChanges()
    withObservationTracking(read, onChange: { changes.record() })
    return changes
}

private final class ToolSnapshotChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

@MainActor
private struct ToolSnapshotFixture {
    let root: URL
    let database: WorkspaceDatabase
    let caller: String
    let target: String
    let model: WorkspaceAgentToolsModel

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "wm-tool-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        caller = try await database.createLocalACPSession(runtimeKind: .codex, title: "Caller", ownerDeviceID: UUID())
        target = try await database.createLocalACPSession(runtimeKind: .pi, title: "Target", ownerDeviceID: UUID())
        model = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, onMutation: {})
    }

    func stop() {
        model.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

extension WorkspaceAgentToolsServiceTests {
    @Test func calendarCommandsShareNativeEventsAndKeepRetriesAndPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "calendar-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try await database.createLocalACPSession(runtimeKind: .codex, title: "Planner", ownerDeviceID: UUID())
        @MainActor final class ResolutionState {
            var count = 0
            var editsEvent = false
        }
        let resolution = ResolutionState()
        let service = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() },
            calendarTaskHandler: { _, command, existing in
                resolution.count += 1
                if resolution.editsEvent {
                    let event = try await database.calendarEvent(id: command.required("id", allowPositional: true), callerID: caller)
                    var draft = WorkspaceCalendarDraft(event); draft.details = "A newer user edit"
                    try await database.saveCalendarEvent(id: event.id, draft: draft, creating: false, expectedRevision: event.calendar.revision)
                }
                var task = existing ?? WorkspaceCalendarTask(prompt: "", configuration: .init(runtimeKind: .codex,
                    title: "Review", model: "fixture-model", thinking: "high", permission: "read-only", tools: .init(enabled: [.notes])))
                task.prompt = command.options["prompt"] ?? task.prompt
                if let mode = command.options["session-mode"].flatMap(WorkspaceCalendarTask.SessionMode.init(rawValue:)) { task.sessionMode = mode }
                return task
            }, onMutation: {})
        defer { service.stop() }
        let endpoint = try await service.endpoint(for: caller)
        func request(_ arguments: [String], id: String = UUID().uuidString.lowercased()) async throws -> WovenMatterToolResponse {
            let data = try JSONEncoder().encode(WovenMatterToolRequest(arguments: arguments, requestID: id))
            let response = try await runBlockingToolFixture { try WovenMatterCommandLine.forward(data, to: endpoint) }
            return try JSONDecoder().decode(WovenMatterToolResponse.self, from: response)
        }
        let id = UUID().uuidString.lowercased()
        let creation = ["calendar", "create", "--title", "Daily review", "--starts-at", "2026-09-01T13:00:00Z",
                        "--time-zone", "America/New_York", "--repeat-unit", "day", "--repeat-interval", "2",
                        "--prompt", "Review changes", "--session-mode", "new"]
        #expect(try await request(creation, id: id).success)
        let event = try await database.calendarEvent(id: id, callerID: caller)
        #expect(event.calendar.recurrence == .init(unit: .day, interval: 2))
        #expect(event.calendar.createdBy.agent == "codex")
        #expect(event.calendar.task?.sessionMode == .new)
        let listing = try await request(["calendar", "list", "--since", "2026-09-15T00:00:00Z"])
        #expect(listing.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["calendar"]?.objectValue?["task"] != nil)
        let occurrences = try await request(["calendar", "occurrences", id, "--since", "2026-09-01T00:00:00Z", "--until", "2026-09-08T00:00:00Z"])
        #expect(occurrences.result?.objectValue?["rows"]?.arrayValue?.count == 4)
        #expect(try await request(["calendar", "update", id, "--revision", String(event.calendar.revision),
            "--description", "Edited from a session"]).success)
        let updated = try await database.calendarEvent(id: id, callerID: caller)
        #expect(updated.calendar.task?.configuration.permission == "read-only")
        #expect(updated.calendar.task?.prompt == "Review changes")
        #expect(updated.calendar.recurrence == event.calendar.recurrence)
        #expect(updated.calendar.editedBy?.sessionID == caller)
        #expect(try await !request(["calendar", "update", id, "--revision", "0", "--title", "Stale edit"]).success)
        #expect(try await !request(["calendar", "update", id, "--occurrence", "1", "--title", "Linked exception"]).success)
        let detached = try await request(["calendar", "detach", id, "--occurrence", "1",
            "--revision", String(updated.calendar.revision), "--title", "Independent review"])
        #expect(detached.success)
        let detachedID = try #require(detached.result?.objectValue?["id"]?.stringValue)
        let independent = try await database.calendarEvent(id: detachedID, callerID: caller)
        #expect(independent.calendar.recurrence == nil)
        #expect(independent.calendar.task?.prompt == "Review changes")
        #expect(independent.calendar.task?.configuration.tools.enabled == [.notes])
        #expect(try await !request(["calendar", "remove", detachedID, "--occurrence", "1",
            "--revision", String(independent.calendar.revision)]).success)
        #expect(try await request(["calendar", "read", detachedID]).success)
        #expect(try await database.calendarEvent(id: id, callerID: caller).calendar.excludedOccurrences == [1])
        let copyID = UUID().uuidString.lowercased()
        let copy = ["calendar", "copy", detachedID, "--starts-at", "2026-09-20T13:00:00Z"]
        #expect(try await request(copy, id: copyID).success)
        let copied = try await database.calendarEvent(id: copyID, callerID: caller)
        #expect(try await request(["calendar", "remove", copyID,
            "--revision", String(copied.calendar.revision)]).success)
        // Replay succeeds even after the copy was deleted, without re-resolving defaults.
        let beforeReplay = resolution.count
        #expect(try await request(copy, id: copyID).result?.objectValue?["id"]?.stringValue == copyID)
        #expect(resolution.count == beforeReplay)
        #expect(try await !request(copy + ["--title", "Different input"], id: copyID).success)
        resolution.editsEvent = true
        let beforeRace = try await database.calendarEvent(id: id, callerID: caller)
        #expect(try await !request(["calendar", "update", id, "--revision", String(beforeRace.calendar.revision),
            "--description", "Stale agent edit"]).success)
        #expect(try await database.calendarEvent(id: id, callerID: caller).details == "A newer user edit")
        resolution.editsEvent = false
        var settings = try await database.toolSettings(); settings.calendarAccess = .readOnly
        try await database.saveToolSettings(settings)
        #expect(try await request(["calendar", "read", id]).success)
        #expect(try await !request(creation, id: id).success)
        #expect(try await !request(["calendar", "remove", id]).success)
        settings.calendarAccess = .full; try await database.saveToolSettings(settings)
        try await database.setSessionTools(.init(enabled: [.calendar]), sessionID: caller)
        #expect(try await !request(creation, id: UUID().uuidString.lowercased()).success)
        #expect(try await request(["calendar", "create", "--title", "Ordinary event", "--starts-at", "2026-09-22T13:00:00Z"]).success)
        try await database.setSessionTools(.init(enabled: []), sessionID: caller)
        #expect(try await !request(["calendar", "list"]).success)
    }

    @Test func librarySocketAcceptsReturnedDatesAndRejectsInvalidPagination() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let run = try await fixture.database.beginLocalACPRun(conversationID: fixture.caller, content: "https://example.com/shared")
        try await fixture.database.completeLocalACPRun(runID: run.runID)
        try await fixture.database.indexLibraryMessages()
        let item = try await #require(fixture.database.libraryItems().first)
        let endpoint = try await fixture.model.endpoint(for: fixture.caller)
        func request(_ arguments: [String]) async throws -> WovenMatterToolResponse {
            let data = try JSONEncoder().encode(WovenMatterToolRequest(arguments: ["library"] + arguments))
            let response = try await runBlockingToolFixture { try WovenMatterCommandLine.forward(data, to: endpoint) }
            return try JSONDecoder().decode(WovenMatterToolResponse.self, from: response)
        }
        let listed = try await request(["list", "--since", item.sentAt, "--sender", "me", "--workspace", "local"])
        #expect(listed.success)
        #expect(listed.result?.objectValue?["items"]?.arrayValue?.count == 1)
        let read = try await request(["read", item.id])
        #expect(read.success)
        #expect(read.result?.objectValue?["messageID"]?.stringValue == item.messageID)
        for option in ["limit", "offset"] {
            let malformed = try await request(["list", "--" + option, "invalid"])
            #expect(!malformed.success)
        }
        try await fixture.model.setEnabled(.library, enabled: false, sessionID: fixture.caller)
        let denied = try await request(["read", item.id])
        #expect(!denied.success)
    }
}

extension WorkspaceAgentToolsServiceTests {
    @Test func passiveToolsProjectionForwardsMutationsAndCannotServeTools() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try await database.createLocalACPSession(runtimeKind: .codex, title: "Caller", ownerDeviceID: UUID())
        let original = try await database.sessionTools(caller)
        var forwarded = 0
        let projection = try await WorkspaceAgentToolsModel(projection: database) { command in
            guard case .setEnabled(.timers, false, caller, false) = command else {
                throw WorkspaceToolError.invalid("Unexpected command")
            }
            forwarded += 1
            throw WorkspaceToolError.timerPauseConfirmation
        }
        defer { projection.stop() }
        await #expect(throws: (any Error).self) { try await projection.endpoint(for: caller) }
        await #expect(throws: (any Error).self) { try await projection.setEnabled(.timers, enabled: false, sessionID: caller) }
        do {
            try await projection.setEnabledFromUI(.timers, enabled: false, sessionID: caller)
            Issue.record("Expected timer confirmation")
        } catch WorkspaceToolError.timerPauseConfirmation { }
        #expect(forwarded == 1)
        #expect(try await database.sessionTools(caller) == original)
        let response = await projection.handle(.init(arguments: ["timers", "list"]), callerID: caller)
        #expect(!response.success)
    }
}

extension WorkspaceAgentToolsServiceTests {
    @Test(arguments: [false, true])
    func failedSettingsSaveRestoresTheCommittedProjection(replyLostAfterCommit: Bool) async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let original = try await fixture.database.toolSettings()
        let projection = try await WorkspaceAgentToolsModel(projection: fixture.database) { mutation in
            if replyLostAfterCommit, case let .saveSettings(value, _) = mutation {
                try await fixture.database.saveToolSettings(value)
            }
            throw ToolSettingsSaveFailure()
        }
        defer { projection.stop() }
        var edited = original
        edited.maximumManagedSessions = original.maximumManagedSessions == 16 ? 15 : original.maximumManagedSessions + 1
        await projection.saveSettings(edited)
        #expect(projection.settings == (replyLostAfterCommit ? edited : original))
        #expect(try await fixture.database.toolSettings() == projection.settings)
        #expect(projection.error == ToolSettingsSaveFailure().localizedDescription)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedQueuedSettingsSavePreservesNewerEditAndLastSuccessfulValue() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let gate = ToolSettingsSaveGate()
        let projection = try await WorkspaceAgentToolsModel(projection: fixture.database) { mutation in
            try await gate.pause()
            if case let .saveSettings(value, _) = mutation { try await fixture.database.saveToolSettings(value) }
        }
        defer { projection.stop(); gate.finishAll() }
        var first = projection.settings
        first.maximumManagedSessions = 7
        var latest = first
        latest.maximumManagedSessions = 9
        let oldSave = Task { await projection.saveSettings(first) }
        await gate.waitForStarts(1)
        let newestSave = Task { await projection.saveSettings(latest) }
        let deadline = ContinuousClock.now + .seconds(5)
        while projection.settings != latest, ContinuousClock.now < deadline { await Task.yield() }
        #expect(projection.settings == latest)
        gate.finish(1, failure: true)
        await gate.waitForStarts(2)
        #expect(projection.settings == latest)
        gate.finish(2, failure: false)
        await oldSave.value
        await newestSave.value
        #expect(projection.settings == latest)
        #expect(try await fixture.database.toolSettings() == latest)
        #expect(projection.error == nil)

        var rejected = latest
        rejected.maximumManagedSessions = 11
        let failedSave = Task { await projection.saveSettings(rejected) }
        await gate.waitForStarts(3)
        gate.finish(3, failure: true)
        await failedSave.value
        #expect(projection.settings == latest)
        #expect(projection.error == ToolSettingsSaveFailure().localizedDescription)
    }
}

private struct ToolSettingsSaveFailure: LocalizedError {
    var errorDescription: String? { "The fixture save failed." }
}

@MainActor
private final class ToolSettingsSaveGate {
    private var starts = 0
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func pause() async throws {
        starts += 1
        let id = starts
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let ready = observers.filter { $0.0 <= starts }
            observers.removeAll { $0.0 <= starts }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForStarts(_ count: Int) async {
        if starts >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func finish(_ id: Int, failure: Bool) {
        if failure { pending.removeValue(forKey: id)?.resume(throwing: ToolSettingsSaveFailure()) }
        else { pending.removeValue(forKey: id)?.resume() }
    }
    func finishAll() {
        let remaining = pending.values
        pending.removeAll()
        remaining.forEach { $0.resume(throwing: CancellationError()) }
    }
}


extension WorkspaceAgentToolsServiceTests {
    @Test func executorConnectionChangeFencesAdmissionsBeforeTheirJobExists() async throws {
        let runtime = ExecutorRuntime()
        let original = runtime.fence("admitting")
        #expect(runtime.sessions.isEmpty)
        runtime.cancelAll()
        #expect(throws: CancellationError.self) { try runtime.check("admitting", fence: original) }
        try runtime.check("admitting", fence: runtime.fence("admitting"))
        _ = try? await runtime.scopeEdits["admitting"]?.value
    }

    @Test func executorStopFencesQueuedAdmissionAndCancelsExistingDriver() async throws {
        let runtime = ExecutorRuntime()
        let gate = ToolSettingsSaveGate()
        defer { gate.finishAll() }
        let fence = runtime.fence("session")
        let first = runtime.serialized("session") { try await gate.pause() }
        var admitted = false
        let queued = runtime.serialized("session") {
            try runtime.check("session", fence: fence)
            admitted = true
        }
        let driver = Task<Void, Never> {}
        runtime.jobs["job"] = driver; runtime.sessions["job"] = "session"
        await gate.waitForStarts(1)
        runtime.cancel("session")
        #expect(driver.isCancelled)
        gate.finishAll()
        _ = try? await first.value
        do { try await queued.value; Issue.record("Stopped admission unexpectedly ran") }
        catch is CancellationError { }
        #expect(!admitted)
        _ = try? await runtime.scopeEdits["session"]?.value
    }

    @Test(arguments: AgentRuntimeKind.allCases)
    func executorUsesBoundCLIIdentityAndChecksMasterSwitch(runtime: AgentRuntimeKind) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try await database.createLocalACPSession(runtimeKind: runtime, title: "Caller", ownerDeviceID: UUID())
        var seen: [String] = []
        let service = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() }, noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() }, usageHandler: { _ in throw CancellationError() },
            executorHandler: { identity, command, _ in
                seen.append(identity)
                return .init(result: .object(["action": .string(command.action)]))
            }, onMutation: {})
        defer { service.stop() }
        let endpoint = try await service.endpoint(for: caller)
        func request(_ arguments: [String]) async throws -> WovenMatterToolResponse {
            let data = try JSONEncoder().encode(WovenMatterToolRequest(arguments: arguments))
            let result = try await runBlockingToolFixture { try WovenMatterCommandLine.forward(data, to: endpoint) }
            return try JSONDecoder().decode(WovenMatterToolResponse.self, from: result)
        }
        #expect(try await !request(["executor", "search", "--query", "fixture"]).success)
        #expect(seen.isEmpty)
        _ = try await database.setSessionToolEnabled(.executor, enabled: true, sessionID: caller)
        #expect(try await request(["executor", "search", "--query", "fixture"]).success)
        #expect(seen == [caller])
        #expect(try await !request(["executor", "execute", "--code", "return 1;", "--session", "other"]).success)
        #expect(seen == [caller])
        _ = try await database.setSessionToolEnabled(.executor, enabled: false, sessionID: caller)
        #expect(try await !request(["executor", "execute", "--code", "return 1;"]).success)
        #expect(seen == [caller])
    }
}


extension WorkspaceAgentToolsServiceTests {
    @Test func queuedSettingsToggleCanUndoItsPendingPredecessor() async throws {
        let fixture = try await ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        var enabled = model.settings; enabled.enabledByDefault.insert(.executor)
        model.saveSettingsFromUI(enabled)
        var disabled = enabled; disabled.enabledByDefault.remove(.executor)
        await model.saveSettings(disabled)
        #expect(!(try await fixture.database.toolSettings()).enabledByDefault.contains(.executor))
        #expect(!model.settings.enabledByDefault.contains(.executor))
    }
}

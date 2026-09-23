import Foundation
import Observation
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
        let notified = DispatchSemaphore(value: 0)
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
                notified.signal()
            })
        holder.value = forwarder
        defer { forwarder.stop() }
        try forwarder.submit(id: UUID().uuidString, request: replacement)
        let notificationFinished = await withCheckedContinuation { continuation in
            DispatchQueue(label: "relay-failure-notification").async {
                continuation.resume(returning: notified.wait(timeout: .now() + 30) == .success)
            }
        }
        #expect(notificationFinished)
        await forwarder.waitUntilIdle()
        #expect(output.errors.count == 1)
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

// Socket reads and semaphore waits must not occupy Swift's cooperative workers:
// the server tasks being tested need those workers to produce their responses.
private func runBlockingToolFixture<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
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
    @Test func unchangedToolSnapshotsDoNotInvalidateConversationObservers() throws {
        let fixture = try ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        let token = UUID()
        model.observeSession(fixture.caller, token: token)
        try model.setEnabled(.calendar, enabled: false, sessionID: fixture.caller)
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
        for _ in 0..<20 { try model.reload() }
        model.observeSession(fixture.caller, token: token)
        #expect(changes.count == 0)
        #expect(model.receipts[fixture.caller]?.isEmpty == true)
        #expect(!model.hasOlderReceipts.contains(fixture.caller))
    }

    @Test func receiptPayloadChangesPublishEvenWhenIDsAndCountsStayTheSame() throws {
        let fixture = try ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        model.observeSession(fixture.caller, token: UUID())
        let inserted = observeToolSnapshotChanges { _ = model.receipts }
        let delivery = try fixture.database.reserveToolDelivery(sourceID: fixture.caller,
            targetID: fixture.target, text: "Review the result", requestID: UUID().uuidString)
        try model.reload()
        #expect(inserted.count == 1)
        #expect(model.receipts[fixture.caller]?.map(\.id) == [delivery.id])

        let statusChanged = observeToolSnapshotChanges { _ = model.receipts }
        try fixture.database.setToolDeliveryStatus(id: delivery.id, status: "failed")
        try model.reload()
        #expect(statusChanged.count == 1)
        #expect(model.receipts[fixture.caller]?.first?.status == "failed")

        // A payload change with the same status must not be hidden by an
        // identity/status-only comparison either.
        let payloadChanged = observeToolSnapshotChanges { _ = model.receipts }
        let messageID = UUID().uuidString
        try fixture.database.setToolDeliveryStatus(id: delivery.id, status: "failed", messageID: messageID)
        try model.reload()
        #expect(payloadChanged.count == 1)
        #expect(model.receipts[fixture.caller]?.first?.messageID == messageID)
        #expect(model.receipts[fixture.caller]?.map(\.id) == [delivery.id])

        let unchanged = observeToolSnapshotChanges {
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        for _ in 0..<5 { try model.reload() }
        #expect(unchanged.count == 0)
    }

    @Test func receiptObservationRetainsPagedWindowsAndSharedPanelOwnership() throws {
        let fixture = try ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        var ids: [String] = []
        for index in 0..<205 {
            let delivery = try fixture.database.reserveToolDelivery(sourceID: fixture.caller,
                targetID: fixture.target, text: "Instruction \(index)", requestID: UUID().uuidString)
            ids.append(delivery.id)
        }
        let firstPanel = UUID(), secondPanel = UUID()
        model.observeSession(fixture.caller, token: firstPanel)
        #expect(model.receipts[fixture.caller]?.map(\.id) == Array(ids.suffix(200).reversed()))
        #expect(model.hasOlderReceipts.contains(fixture.caller))
        let unchanged = observeToolSnapshotChanges {
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        try model.reload()
        model.observeSession(fixture.caller, token: secondPanel)
        model.observeSession(nil, token: firstPanel)
        #expect(unchanged.count == 0)

        let olderChanged = observeToolSnapshotChanges { _ = model.hasOlderReceipts }
        model.loadOlderReceipts(sessionID: fixture.caller)
        #expect(olderChanged.count == 1)
        #expect(model.receipts[fixture.caller]?.map(\.id) == Array(ids.reversed()))
        #expect(!model.hasOlderReceipts.contains(fixture.caller))
        let exhausted = observeToolSnapshotChanges {
            _ = model.receipts
            _ = model.hasOlderReceipts
        }
        model.loadOlderReceipts(sessionID: fixture.caller)
        try model.reload()
        #expect(exhausted.count == 0)

        let newest = try fixture.database.reserveToolDelivery(sourceID: fixture.caller,
            targetID: fixture.target, text: "Latest", requestID: UUID().uuidString)
        try fixture.database.setToolDeliveryStatus(id: ids[0], status: "cancelled")
        try model.reload()
        #expect(model.receipts[fixture.caller]?.map(\.id) == [newest.id] + ids.reversed())
        #expect(model.receipts[fixture.caller]?.last?.status == "cancelled")
        let removed = observeToolSnapshotChanges { _ = model.receipts }
        model.observeSession(nil, token: secondPanel)
        #expect(removed.count == 1)
        #expect(model.receipts.isEmpty)
        #expect(model.hasOlderReceipts.isEmpty)
    }

    @Test func changedSettingsPoliciesAndTimersStillPublish() throws {
        let fixture = try ToolSnapshotFixture()
        defer { fixture.stop() }
        let model = fixture.model
        try model.setEnabled(.calendar, enabled: false, sessionID: fixture.caller)
        let settingsChanged = observeToolSnapshotChanges { _ = model.settings }
        let policiesChanged = observeToolSnapshotChanges { _ = model.sessionPolicies }
        let timersChanged = observeToolSnapshotChanges { _ = model.timers }
        var settings = model.settings
        settings.maximumManagedSessions += 1
        try fixture.database.saveToolSettings(settings)
        let policy = WorkspaceSessionTools(enabled: [.sessions, .timers])
        try fixture.database.setSessionTools(policy, sessionID: fixture.caller)
        let timer = WorkspaceSessionTimer(sessionID: fixture.caller, instruction: "Check the result",
            nextFireAt: Date(timeIntervalSince1970: 4_000_000_000))
        try fixture.database.saveSessionTimer(timer, callerID: fixture.caller)
        try model.reload()
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
        for _ in 0..<5 { try model.reload() }
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

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "wm-tool-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        caller = try database.createLocalACPSession(runtimeKind: .codex, title: "Caller", ownerDeviceID: UUID())
        target = try database.createLocalACPSession(runtimeKind: .pi, title: "Target", ownerDeviceID: UUID())
        model = try WorkspaceAgentToolsModel(database: database,
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
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try database.createLocalACPSession(runtimeKind: .codex, title: "Planner", ownerDeviceID: UUID())
        @MainActor final class ResolutionState {
            var count = 0
            var editsEvent = false
        }
        let resolution = ResolutionState()
        let service = try WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() },
            calendarTaskHandler: { _, command, existing in
                resolution.count += 1
                if resolution.editsEvent {
                    let event = try database.calendarEvent(id: command.required("id", allowPositional: true), callerID: caller)
                    var draft = WorkspaceCalendarDraft(event); draft.details = "A newer user edit"
                    try database.saveCalendarEvent(id: event.id, draft: draft, creating: false, expectedRevision: event.calendar.revision)
                }
                var task = existing ?? WorkspaceCalendarTask(prompt: "", configuration: .init(runtimeKind: .codex,
                    title: "Review", model: "fixture-model", thinking: "high", permission: "read-only", tools: .init(enabled: [.notes])))
                task.prompt = command.options["prompt"] ?? task.prompt
                if let mode = command.options["session-mode"].flatMap(WorkspaceCalendarTask.SessionMode.init(rawValue:)) { task.sessionMode = mode }
                return task
            }, onMutation: {})
        defer { service.stop() }
        let endpoint = try service.endpoint(for: caller)
        func request(_ arguments: [String], id: String = UUID().uuidString.lowercased()) async throws -> WovenMatterToolResponse {
            let data = try JSONEncoder().encode(WovenMatterToolRequest(arguments: arguments + ["--request-id", id], requestID: id))
            let response = try await Task.detached { try WovenMatterCommandLine.forward(data, to: endpoint) }.value
            return try JSONDecoder().decode(WovenMatterToolResponse.self, from: response)
        }
        let id = UUID().uuidString.lowercased()
        let creation = ["calendar", "create", "--title", "Daily review", "--starts-at", "2026-09-01T13:00:00Z",
                        "--time-zone", "America/New_York", "--repeat-unit", "day", "--repeat-interval", "2",
                        "--prompt", "Review changes", "--session-mode", "new"]
        #expect(try await request(creation, id: id).success)
        let event = try database.calendarEvent(id: id, callerID: caller)
        #expect(event.calendar.recurrence == .init(unit: .day, interval: 2))
        #expect(event.calendar.createdBy.agent == "codex")
        #expect(event.calendar.task?.sessionMode == .new)
        let listing = try await request(["calendar", "list", "--since", "2026-09-15T00:00:00Z"])
        #expect(listing.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["calendar"]?.objectValue?["task"] != nil)
        let occurrences = try await request(["calendar", "occurrences", id, "--since", "2026-09-01T00:00:00Z", "--until", "2026-09-08T00:00:00Z"])
        #expect(occurrences.result?.arrayValue?.count == 4)
        #expect(try await request(["calendar", "update", id, "--description", "Edited from a session"]).success)
        let updated = try database.calendarEvent(id: id, callerID: caller)
        #expect(updated.calendar.task?.configuration.permission == "read-only")
        #expect(updated.calendar.task?.prompt == "Review changes")
        #expect(updated.calendar.recurrence == event.calendar.recurrence)
        #expect(updated.calendar.editedBy?.sessionID == caller)
        #expect(try await !request(["calendar", "update", id, "--revision", "0", "--title", "Stale edit"]).success)
        #expect(try await !request(["calendar", "update", id, "--occurrence", "1", "--title", "Linked exception"]).success)
        let detached = try await request(["calendar", "detach", id, "--occurrence", "1", "--title", "Independent review"])
        #expect(detached.success)
        let detachedID = try #require(detached.result?.objectValue?["id"]?.stringValue)
        let independent = try database.calendarEvent(id: detachedID, callerID: caller)
        #expect(independent.calendar.recurrence == nil)
        #expect(independent.calendar.task?.prompt == "Review changes")
        #expect(independent.calendar.task?.configuration.tools.enabled == [.notes])
        #expect(try await !request(["calendar", "remove", detachedID, "--occurrence", "1"]).success)
        #expect(try await request(["calendar", "read", detachedID]).success)
        #expect(try database.calendarEvent(id: id, callerID: caller).calendar.excludedOccurrences == [1])
        let copyID = UUID().uuidString.lowercased()
        let copy = ["calendar", "copy", detachedID, "--starts-at", "2026-09-20T13:00:00Z"]
        #expect(try await request(copy, id: copyID).success)
        #expect(try await request(["calendar", "remove", copyID]).success)
        // Replay succeeds even after the copy was deleted, without re-resolving defaults.
        let beforeReplay = resolution.count
        #expect(try await request(copy, id: copyID).result?.objectValue?["id"]?.stringValue == copyID)
        #expect(resolution.count == beforeReplay)
        #expect(try await !request(copy + ["--title", "Different input"], id: copyID).success)
        resolution.editsEvent = true
        #expect(try await !request(["calendar", "update", id, "--description", "Stale agent edit"]).success)
        #expect(try database.calendarEvent(id: id, callerID: caller).details == "A newer user edit")
        resolution.editsEvent = false
        var settings = try database.toolSettings(); settings.calendarAccess = .readOnly
        try database.saveToolSettings(settings)
        #expect(try await request(["calendar", "read", id]).success)
        #expect(try await !request(creation, id: id).success)
        #expect(try await !request(["calendar", "remove", id]).success)
        settings.calendarAccess = .full; try database.saveToolSettings(settings)
        try database.setSessionTools(.init(enabled: [.calendar]), sessionID: caller)
        #expect(try await !request(creation, id: UUID().uuidString.lowercased()).success)
        #expect(try await request(["calendar", "create", "--title", "Ordinary event", "--starts-at", "2026-09-22T13:00:00Z"]).success)
        try database.setSessionTools(.init(enabled: []), sessionID: caller)
        #expect(try await !request(["calendar", "list"]).success)
    }

    @Test func librarySocketAcceptsReturnedDatesAndRejectsInvalidPagination() async throws {
        let fixture = try ToolSnapshotFixture()
        defer { fixture.stop() }
        let run = try fixture.database.beginLocalACPRun(conversationID: fixture.caller, content: "https://example.com/shared")
        try fixture.database.completeLocalACPRun(runID: run.runID)
        try fixture.database.indexLibraryMessages()
        let item = try #require(fixture.database.libraryItems().first)
        let endpoint = try fixture.model.endpoint(for: fixture.caller)
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
        try fixture.model.setEnabled(.library, enabled: false, sessionID: fixture.caller)
        let denied = try await request(["read", item.id])
        #expect(!denied.success)
    }
}

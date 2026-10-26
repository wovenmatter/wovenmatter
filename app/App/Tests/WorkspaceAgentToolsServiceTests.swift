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

    @Test(arguments: AgentRuntimeKind.allCases.filter { $0 != .opencode })
    func htmlPublicationUsesBoundConversationAndPersistsOutsideFoldedWork(runtime: AgentRuntimeKind) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try await database.createLocalACPSession(runtimeKind: runtime, title: "HTML", ownerDeviceID: UUID())
        let run = try await database.beginLocalACPRun(conversationID: caller, content: "Visual reply")
        let service = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() }, noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() }, usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { service.stop() }
        let endpoint = try await service.endpoint(for: caller)
        let html = "<button onclick='this.textContent=42'>Calculate</button>" + (runtime == .codex
            ? "<img src='data:image/png;base64," + String(repeating: "A", count: 5 * 1024 * 1024) + "'>" : "")
        let payload: GatewayJSONValue = .object(["action": .string("render"), "html": .string(html), "title": .string("Calculator"), "height": .number(160)])
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let request = WovenMatterToolRequest(arguments: ["html", "call", "--json", json])
        let data = try JSONEncoder().encode(request)
        let response = try await runBlockingToolFixture { try WovenMatterCommandLine.forward(data, to: endpoint) }
        let result = try JSONDecoder().decode(WovenMatterToolResponse.self, from: response)
        #expect(result.success)
        #expect(result.result?.objectValue?["htmlRender"]?.objectValue?["title"]?.stringValue == "Calculator")
        let history = try await database.conversationHistoryPage(id: caller, limit: 20, compactActivities: true)
        let timeline = ConversationWorkTimeline(records: history.activities, commentaryIDs: [])
        #expect(timeline.foldedEntries.count == 1)
        #expect(history.activities.contains { $0.runID == run.runID && $0.activity.htmlRender?.title == "Calculator" })
        if runtime == .codex {
            #expect(data.count > 4 * 1024 * 1024)
            let activity = try #require(history.activities.first { $0.activity.htmlRender != nil })
            let detail = try #require(try await database.conversationActivityDetails(conversationID: caller, runID: run.runID, activityID: activity.activity.id))
            #expect(try JSONDecoder().decode(ConversationHTMLPage.self, from: Data(try #require(detail.rawOutputJSON).utf8)).html == html)
        }
        let forged = await service.handle(.init(arguments: ["html", "call", "--json", json, "--session", "someone-else"]), callerID: caller)
        #expect(!forged.success)
    }

    @Test func executorConnectionChangeFencesAdmissionsBeforeTheirJobExists() async throws {
        let runtime = ExecutorRuntime()
        let original = runtime.fence("admitting")
        #expect(runtime.sessions.isEmpty)
        runtime.cancelAll()
        #expect(throws: CancellationError.self) { try runtime.check("admitting", fence: original) }
        try runtime.check("admitting", fence: runtime.fence("admitting"))
        _ = try? await runtime.scopeEdits["admitting"]?.value
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

}

extension WorkspaceAgentToolsServiceTests {

    @Test func mutationHistoryIsMetadataOnlyAndNoteReadsAreChunked() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cli-hardening-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let caller = try await database.createLocalACPSession(runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID())
        let historian = try await database.createLocalACPSession(runtimeKind: .claudeCode, title: "Historian", ownerDeviceID: UUID())
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
        target = try await database.createLocalACPSession(runtimeKind: .claudeCode, title: "Target", ownerDeviceID: UUID())
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
        #expect(independent.calendar.task?.configuration.tools.enabled == [.notes, .goals, .html])
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

}

extension WorkspaceAgentToolsServiceTests {
}

extension WorkspaceAgentToolsServiceTests {

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

}

extension WorkspaceAgentToolsServiceTests {
}

extension WorkspaceAgentToolsServiceTests {
    @Test func goalCommandsRunThroughTheBoundCLIAndPublishState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let caller = try await database.createLocalACPSession(runtimeKind: .defaultAgent, title: "Goals", ownerDeviceID: UUID())
        let service = try await WorkspaceAgentToolsModel(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() }, noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() }, usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { service.stop() }
        let endpoint = try await service.endpoint(for: caller)
        func request(_ arguments: [String], id: String = UUID().uuidString) async throws -> WovenMatterToolResponse {
            let data = try JSONEncoder().encode(WovenMatterToolRequest(arguments: arguments, requestID: id))
            let response = try await runBlockingToolFixture { try WovenMatterCommandLine.forward(data, to: endpoint) }
            return try JSONDecoder().decode(WovenMatterToolResponse.self, from: response)
        }
        let first = try await request(["goals", "set", "--objective", "Produce the verified artifact", "--turn-budget", "3"])
        #expect(first.success)
        let id = try #require(first.result?.objectValue?["id"]?.stringValue)
        #expect(service.goals[caller]?.id == id)
        let read = try await request(["goals", "get"])
        #expect(read.result?.objectValue?["objective"]?.stringValue == "Produce the verified artifact")
        let failed = try await request(["goals", "complete", "--id", id, "--evidence", " "])
        #expect(!failed.success)
        let done = try await request(["goals", "complete", "--id", id, "--evidence", "Artifact checked against the requirements"])
        #expect(done.success && service.goals[caller]?.status == .complete)
        _ = try await database.setSessionToolEnabled(.goals, enabled: false, sessionID: caller)
        let stillEnabled = try await request(["goals", "get"])
        #expect(stillEnabled.success)
    }
}

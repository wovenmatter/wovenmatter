import Foundation
import Testing
@testable import WovenMatterAppFacade
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

/// `woven_sessions_wait` and wake-ups through the Mac's own tool path
/// (`ApplicationModel+SessionWaits.swift`), against a Linux host that reports
/// its sessions' state. The destination's `workspace` stream items are handed
/// to `SessionWakeUps` as `CentralExecutionClient.onWorkspaceItem` hands them.
@Suite("Mac session waits", .serialized) @MainActor
struct SessionWaitTests {
    @MainActor final class Setup {
        let mac: FacadeFixture
        let linux: ReachLinuxHost
        let workspace: ExecutionWorkspace
        let tools: WorkspaceAgentToolsModel
        init() async throws {
            mac = try await FacadeFixture()
            let identity = try await mac.database.libraryIdentity()
            let signer = MemberIdentity(deviceID: identity.hostDeviceID, kind: .mac, key: .init())
            linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: identity.libraryID, members: [signer.deviceID: signer.publicKey])
            workspace = try await mac.database.receiveSyncedWorkspace(linux.descriptor)
            let linux = linux
            mac.model.federatedExecutionClient = try CentralExecutionClient(database: mac.database,
                commandJournalURL: mac.directory.appending(path: "commands.json"),
                provision: { _ in throw LibraryAPIError(code: "unauthorized", message: "No grants in this test.") },
                loadCredential: { _ in nil }, saveCredential: { _ in },
                makeSignedTransport: { workspace in try SignedExecutionWorkspaceTransport(workspace: workspace, signer: signer.signer, audience: linux.memberID, send: linux.send) })
            tools = try #require(mac.model.agentTools)
        }
        func call(_ caller: String, _ name: String, _ arguments: [String: GatewayJSONValue]) async throws -> WovenMatterToolResponse {
            await tools.handle(try WovenMCPCatalog.request(name: name, arguments: .object(arguments)), callerID: caller)
        }
        /// What the Linux host's `workspace` stream sends for its current state.
        func stream(snapshot: Bool = false) async throws {
            let wakeUps = try #require(tools.sessionWakeUps)
            let conversations = linux.created.compactMap(\.conversationID).map { id in
                LibraryConversation(id: id, title: "Build it", providerID: "codex", runtimeKind: "codex", activeRunID: linux.running[id],
                                    libraryID: workspace.libraryID, workspaceID: workspace.id)
            }
            await wakeUps.remoteItem(workspaceID: workspace.id, .conversations(.init(conversations: conversations, snapshot: snapshot)))
            await wakeUps.remoteItem(workspaceID: workspace.id, .pending(.init(interactions: linux.pending)))
            if snapshot { await wakeUps.remoteItem(workspaceID: workspace.id, .synchronized) }
            for _ in 0..<50 { await Task.yield() }
        }
        func remove() { mac.remove() }
    }

    /// Waits for `condition`; the 10 s bound is only a safety net.
    private func eventually(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline { if try await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Timed out: \(what)")
    }

    /// Waits until `count` wake-ups reached the caller and the last one was
    /// accepted: its run is recorded before the delivery is marked accepted,
    /// while the recorder sees the input before the run begins.
    private func woken(_ s: Setup, _ what: String, count: Int) async throws {
        try await eventually(what) {
            let deliveries = await s.mac.recorder.deliveries
            guard deliveries.count == count, let id = deliveries.last?.input.historyDeliveryID else { return false }
            return try await s.mac.database.toolDelivery(id: id)?.status == "accepted"
        }
    }

    @Test func aSessionWakesItsIdleCallerAndWaitsWhileTheCallerRuns() async throws {
        let s = try await Setup(); defer { s.remove() }
        let caller = try #require(await s.mac.model.createLocalACPSession(runtimeKind: .codex))
        let created = try await s.call(caller, "woven_sessions_create", ["title": .string("Build it"), "text": .string("Start here"),
            "purpose": .string("Fixture"), "harness": .string("codex"), "workspace": .string(s.workspace.id)])
        #expect(created.success, "\(created.error ?? "")")
        let id = try #require(created.result?.objectValue?["session"]?.objectValue?["id"]?.stringValue)
        #expect(created.result?.objectValue?["note"]?.stringValue?.contains("woven_sessions_wait") == true)
        let wakeUps = try #require(s.tools.sessionWakeUps)
        #expect(wakeUps.watched.map(\.id) == [id], "the session it created is watched")

        // Running, then finished: the idle caller is woken with a notification from that session.
        s.linux.running = [id: "run-1"]
        try await s.stream(snapshot: true)
        #expect(await s.mac.recorder.deliveries.isEmpty)
        s.linux.running = [:]
        try await s.stream()
        try await woken(s, "the idle caller was woken", count: 1)
        let first = try #require(await s.mac.recorder.deliveries.first)
        // The harness gets the wake-up text first, then this chat's usual guidance.
        #expect(first.input.text.hasPrefix(SessionWakeUp.text(kind: .finished, sessionID: id, title: "Build it", workspaceName: "Linux L")))
        let deliveryID = try #require(first.input.historyDeliveryID)
        let delivery = try #require(try await s.mac.database.toolDelivery(id: deliveryID))
        #expect(delivery.kind == .notification && delivery.sourceID == id && delivery.targetID == caller && delivery.sourceTitle == "Build it")
        let run = try #require(try await s.mac.database.activeRunID(conversationID: caller))
        try await s.mac.model.reconcileLocalRunState()

        // A question while the woken turn runs: held until that turn ends.
        let sent = try await s.call(caller, "woven_sessions_send", ["id": .string(id), "text": .string("Ask first")])
        #expect(sent.success, "\(sent.error ?? "")")
        s.linux.running = [id: "run-2"]
        s.linux.pending = [.init(id: "q1", conversationID: id, runID: "run-2", kind: .question, title: "Which log?")]
        try await s.stream()
        await wakeUps.deliverPending()
        #expect(await s.mac.recorder.deliveries.count == 1, "a running caller is not woken")
        #expect(wakeUps.pending(callerID: caller).map(\.kind) == [.needsInput])
        try await s.mac.database.completeLocalACPRun(runID: run)
        try await s.mac.model.reconcileLocalRunState()
        await wakeUps.deliverPending()
        try await woken(s, "woken once its turn ended", count: 2)
        #expect(await s.mac.recorder.deliveries.last?.input.text.contains("is waiting for your answer: Which log? Read it with woven_sessions_status") == true)
        // The second wake-up's run follows one a wake-up started: two in a row.
        #expect(try await s.mac.database.wakeUpRunsInARow(conversationID: caller) == 2)

        // A wait resolves from the stream: the session answers and finishes.
        let waiting = Task { try await s.call(caller, "woven_sessions_wait", ["id": .string(id), "until": .string("idle"), "timeoutSeconds": .number(10)]) }
        try await eventually("the wait began") { wakeUps.isTracking(workspaceID: s.workspace.id) }
        let changed = ContinuousClock.now
        s.linux.pending = []; s.linux.running = [:]
        try await s.stream()
        let waited = try await waiting.value
        #expect(ContinuousClock.now - changed < .seconds(8), "resolved by the change, not the timeout")
        #expect(waited.success, "\(waited.error ?? "")")
        #expect(waited.result?.objectValue?["state"] == .string("idle") && waited.result?.objectValue?["timedOut"] == .bool(false))
        #expect(waited.result?.objectValue?["session"]?.objectValue?["id"]?.stringValue == id, "the woven_sessions_status body")
        // The wait told the caller: no wake-up once its turn ends.
        let woken = try #require(try await s.mac.database.activeRunID(conversationID: caller))
        try await s.mac.database.completeLocalACPRun(runID: woken)
        try await s.mac.model.reconcileLocalRunState()
        await wakeUps.deliverPending()
        #expect(await s.mac.recorder.deliveries.count == 2)

        // A timeout says so, with the state it found.
        let late = try await s.call(caller, "woven_sessions_wait", ["id": .string(id), "until": .string("needsInput"), "timeoutSeconds": .number(1)])
        #expect(late.result?.objectValue?["state"] == .string("idle") && late.result?.objectValue?["timedOut"] == .bool(true))
    }

    @Test func aBotIsWokenThroughTheBotsRuntime() async throws {
        let s = try await Setup(); defer { s.remove() }
        let identity = try await s.mac.database.libraryIdentity()
        let botID = UUID().uuidString.lowercased()
        _ = try await s.tools.issueBotKey(machineID: identity.hostDeviceID, botID: botID, botName: "Builder")
        let caller = WovenMCPCaller.bot(machineID: identity.hostDeviceID, botID: botID)
        final class Sink { var notifications: [WovenBotNotification] = [] }
        let sink = Sink()
        s.tools.botNotificationSink = { sink.notifications.append($0) }
        let created = try await s.call(caller, "woven_sessions_create", ["title": .string("Build it"), "text": .string("Start here"),
            "purpose": .string("Fixture"), "harness": .string("codex"), "workspace": .string(s.workspace.id)])
        let id = try #require(created.result?.objectValue?["session"]?.objectValue?["id"]?.stringValue)
        s.linux.running = [id: "run-1"]
        try await s.stream(snapshot: true)
        s.linux.running = [:]
        try await s.stream()
        try await eventually("the bot was woken") { sink.notifications.count == 1 }
        #expect(sink.notifications.first?.botID == botID)
        #expect(sink.notifications.first?.text.hasPrefix("Your session \"Build it\" (\(id)) on Linux L finished.") == true)
    }

    @Test func aWaitOnThisMacsOwnSessionResolvesFromItsChanges() async throws {
        let s = try await Setup(); defer { s.remove() }
        let caller = try #require(await s.mac.model.createLocalACPSession(runtimeKind: .codex))
        let other = try #require(await s.mac.model.createLocalACPSession(runtimeKind: .codex))
        let idle = try await s.call(caller, "woven_sessions_wait", ["id": .string(other), "until": .string("idle"), "timeoutSeconds": .number(5)])
        #expect(idle.success, "\(idle.error ?? "")")
        #expect(idle.result?.objectValue?["state"] == .string("idle") && idle.result?.objectValue?["timedOut"] == .bool(false))
        #expect(idle.result?.objectValue?["rows"]?.arrayValue?.isEmpty == false, "this Mac's woven_sessions_status body")

        // Running: its turn ends while the call waits.
        let delivery = try await s.mac.database.reserveToolDelivery(sourceID: caller, targetID: other, text: "Work", requestID: UUID().uuidString.lowercased())
        #expect(try await s.mac.model.dispatchToolDelivery(delivery).success)
        let run = try #require(try await s.mac.database.activeRunID(conversationID: other))
        let waiting = Task { try await s.call(caller, "woven_sessions_wait", ["id": .string(other), "until": .string("idle"), "timeoutSeconds": .number(20)]) }
        let wakeUps = try #require(s.tools.sessionWakeUps)
        try await eventually("the wait began") { wakeUps.isTracking(workspaceID: ApplicationModel.sessionWaitThisMac) }
        let started = ContinuousClock.now
        try await s.mac.database.completeLocalACPRun(runID: run)
        try await s.mac.model.reconcileLocalRunState()
        let finished = try await waiting.value
        #expect(finished.result?.objectValue?["state"] == .string("idle") && finished.result?.objectValue?["timedOut"] == .bool(false))
        #expect(ContinuousClock.now - started < .seconds(10), "resolved by the change, not the timeout")
    }
}

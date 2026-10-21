import AppKit
import Foundation
import SQLite3
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct DesktopJourneyTests {
    private func conversation(_ f: FacadeFixture, _ id: String) async throws -> WorkspaceConversationRecord {
        try #require(try await f.database.workspaceOverview().conversations.first { $0.id == id })
    }
    private func reopen(_ f: FacadeFixture) async throws -> WorkspaceDatabase {
        #expect(await f.model.flushNoteDrafts())
        f.model.agentTools?.stop()
        return try await WorkspaceDatabase(url: f.directory.appending(path: "workspace.sqlite"))
    }
    private func rpc(_ command: BackendApplicationCommand, id: String = UUID().uuidString) throws -> BackendRPCRequest {
        .init(id: id, method: "application.command", payload: try JSONEncoder().encode(command))
    }
    private func sql(_ f: FacadeFixture, _ statement: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(f.directory.appending(path: "workspace.sqlite").path, &handle) == SQLITE_OK,
              let handle else { throw JourneyError.sqlite }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
            Issue.record("SQLite fixture failed: \(String(cString: sqlite3_errmsg(handle)))"); throw JourneyError.sqlite
        }
    }
    private func pendingConfiguration(_ f: FacadeFixture, _ id: String) {
        let saved = f.model.sessionSelectionPreferences.conversation(id: id)
        var desired = saved?.desiredSelections ?? SessionSelections()
        if desired.model == nil { desired.model = "fixture-model" }
        f.model.sessionSelectionPreferences.stageCalendarSelections(id: id, harness: "codex",
            workspace: saved?.workspace ?? "local:" + f.directory.path, selections: desired)
    }
    private enum JourneyError: Error { case sqlite }

    @Test func localChatMovesBeforeSendFreezesDefaultsSteersAndPersistsExactInput() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let a = try #require(await f.model.createFolder(name: "First"))
        let b = try #require(await f.model.createFolder(name: "Second"))
        f.model.sessionSelectionPreferences.saveDefaults(.init(model: "captured-model", permission: "agent-full-access", tools: ["notes"]), harness: "codex")
        let id = try #require(await f.model.createLocalACPSession(runtimeKind: .codex, folderID: a))
        #expect(await f.model.moveConversation(id: id, toFolderID: b))
        pendingConfiguration(f, id)
        let record = try await conversation(f, id)
        let text = "naïve\u{0}tail 🧵"
        #expect(await f.model.sendAgentMessage(conversation: record, input: .init(text: text)))
        let run = try #require(try await f.database.activeRunID(conversationID: id))
        f.model.sessionSelectionPreferences.saveDefaults(.init(model: "replacement-model", tools: ["history"]), harness: "codex")
        #expect(await f.model.sendAgentMessage(conversation: record, input: .init(text: "Follow-up")))
        #expect(try await f.database.activeRunID(conversationID: id) == run)
        #expect(await f.recorder.deliveries.compactMap(\.delivery) == [text, "Follow-up"])
        #expect(f.model.sessionSelectionPreferences.conversation(id: id)?.desiredSelections.model == "captured-model")
        let root = try #require(try await f.database.workspaceOverview().folders.first { $0.id == b }?.rootPath)
        #expect(await f.recorder.configurations.last?.directory == root)
        #expect(await !f.model.moveConversation(id: id, toFolderID: a))
        try await f.model.cancelCanonicalRun(conversationID: id, runID: run)
        try await f.model.waitForAgentStop(conversationID: id)
        let blocked = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        pendingConfiguration(f, blocked)
        await f.recorder.rejectConfiguration(true)
        #expect(await !f.model.sendAgentMessage(conversation: try await conversation(f, blocked), input: .init(text: "Must not send")))
        #expect(await f.recorder.deliveries.count == 2)
        let db = try await reopen(f)
        #expect(try await db.conversationContent(id: id).messages.filter { $0.role == "user" }.map(\.content) == [text, "Follow-up"])
        #expect(try await db.activeRunID(conversationID: id) == nil)
    }

    @Test func backendStopDuringConfigurationRejectsReplayAndOldAuthority() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let id = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        let backend = BackendApplicationService(model: f.model)
        f.model.backendApplicationService = backend
        defer { f.model.backendApplicationService = nil; f.recorder.configurationGate.open() }
        let client = UUID()
        let admission = AgentDispatchAdmission(instanceID: backend.instanceID, clientID: client, stopSequence: 0, observedStopRevision: 0)
        let request = try rpc(.sendMessageFenced(conversationID: id, input: .init(text: "Stopped"), noteID: nil, admission: admission))
        pendingConfiguration(f, id)
        await f.recorder.holdConfiguration()
        let sending = Task { await backend.handle(request) }
        await f.recorder.waitForConfiguration()
        let stop = try rpc(.cancelSessionFenced(conversationID: id, admission: .init(instanceID: backend.instanceID,
            clientID: UUID(), stopSequence: 1, observedStopRevision: 0)))
        #expect(await backend.handle(stop).error == nil)
        f.recorder.configurationGate.open()
        let rejected = await sending.value
        #expect(rejected.error != nil)
        #expect(await backend.handle(request).error == rejected.error)
        #expect(await f.recorder.deliveries.isEmpty)
        let changed = try rpc(.loadAgentDefaults(runtime: .codex, workspace: nil), id: request.id)
        #expect(await backend.handle(changed).error?.contains("identity was reused") == true)
        let restarted = BackendApplicationService(model: f.model)
        #expect(await restarted.handle(request).error?.localizedCaseInsensitiveContains("restart") == true)
        #expect(restarted.dispatchStopRevisions.isEmpty)
        let fresh = try rpc(.sendMessageFenced(conversationID: id, input: .init(text: "Current"), noteID: nil,
            admission: .init(instanceID: backend.instanceID, clientID: client, stopSequence: 0,
                observedStopRevision: try #require(backend.dispatchStopRevisions[id]))))
        let accepted = await backend.handle(fresh)
        #expect(accepted.error == nil, "\(accepted.error ?? "")")
        #expect(await backend.handle(fresh).result == accepted.result)
        #expect(await f.recorder.deliveries.count == 1)
        let db = try await reopen(f)
        #expect(try await db.conversationContent(id: id).messages.filter { $0.role == "user" }.map(\.content) == ["Current"])
    }

    @Test func noteActionsRespectFailedDraftBarrierThenRecoverAndRejectStaleWriter() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let id = try await f.database.createNote(folderID: nil, title: "Draft", content: "Original")
        await f.model.refreshWorkspace()
        let note = try #require(f.model.workspaceOverview?.notes.first { $0.id == id })
        let originalRevision = try await f.database.noteActionRevision(id: id)
        try sql(f, "CREATE TRIGGER reject_note BEFORE UPDATE ON notes BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END")
        defer { try? sql(f, "DROP TRIGGER IF EXISTS reject_note") }
        let content = "Acknowledged résumé 🧵\nsecond line"
        f.model.updateNoteDraft(note: note, content: content)
        await #expect(throws: ApplicationModelError.noteDraftSaveFailed) { try await f.model.mutateNote(id: id, mutation: .rename("Renamed")) }
        await #expect(throws: ApplicationModelError.noteDraftSaveFailed) { _ = try await f.model.exportNote(id: id) }
        let journal = DashboardNoteDraftJournal(fileURL: f.directory.appending(path: "fixture-drafts.ndjson"))
        #expect(try journal.entries().map(\.content) == [content])
        try sql(f, "DROP TRIGGER reject_note")
        f.model.retryNoteDraft(note: note)
        #expect(await f.model.flushNoteDrafts())
        #expect(try journal.entries().isEmpty)
        try await f.model.mutateNote(id: id, mutation: .rename("Renamed"))
        let export = try await f.model.exportNote(id: id)
        defer { try? FileManager.default.removeItem(at: export.url) }
        let exported = try String(contentsOf: export.url, encoding: .utf8)
        #expect(Data(exported.utf8) == Data(("# Renamed\n\n" + content + "\n").utf8))
        await #expect(throws: (any Error).self) {
            _ = try await f.database.updateNote(id: id, title: "Stale", content: "Lost edit", expectedRevision: originalRevision)
        }
        try await f.model.mutateNote(id: id, mutation: .moveToTrash)
        #expect(try await f.model.trashedNotes().map(\.id) == [id])
        try await f.model.mutateNote(id: id, mutation: .restore)
        let db = try await reopen(f)
        let saved = try #require(try await db.workspaceOverview().notes.first { $0.id == id })
        #expect(saved.title == "Renamed" && saved.content == content)
    }

    @Test func calendarDeletionDuringPreparationDoesNotResurrectOrConsumeOtherTask() async throws {
        let f = try await FacadeFixture(); defer { f.remove(); f.recorder.creationGate.open() }
        f.model.sessionSelectionPreferences.saveDefaults(.init(model: "scheduled-model", tools: ["notes"]), harness: "codex")
        var task = f.model.calendarTaskDefaults(runtime: .codex, workspaceID: nil, title: "Scheduled")
        task.prompt = "Calendar payload"
        #expect(await f.model.saveCalendarEvent(.init(title: "A", startsAt: Date().addingTimeInterval(-10), task: task)))
        #expect(await f.model.saveCalendarEvent(.init(title: "B", startsAt: Date().addingTimeInterval(-5), task: task)))
        let events = try await f.database.calendarItems()
        let a = try #require(events.first { $0.title == "A" })
        await f.recorder.holdCreation()
        let tick = Task { await f.model.runCalendarTasks() }
        try await f.recorder.waitForCreation()
        #expect(await f.model.deleteCalendarEvent(a))
        f.recorder.creationGate.open()
        await tick.value
        await f.model.runCalendarTasks()
        let runs = try await f.database.calendarRuns()
        let cancelled = try #require(runs.first { $0.eventID == a.id })
        #expect(cancelled.status == "cancelled")
        #expect(await f.recorder.deliveries.count == 1)
        #expect(await f.recorder.configurations.last?.selections.model == "scheduled-model")
        #expect(f.model.preparingAgentDispatchIDs.isEmpty)
        let db = try await reopen(f)
        #expect(try await db.calendarItems().map(\.title) == ["B"])
        #expect(try await db.calendarRuns().filter { $0.eventID == a.id }.allSatisfy { $0.status == "cancelled" })
        #expect(try await db.dueCalendarRuns().isEmpty)
    }

    @Test func passiveWorkspaceAndBackendMetadataNeverRequestUsageCredentialsOrDispatch() async throws {
        try #require(ProcessInfo.processInfo.environment["CODEX_HOME"] == nil,
            "Run tests with CODEX_HOME unset so fixtures cannot read inherited credentials.")
        let f = try await FacadeFixture(); defer { f.remove() }
        let id = try await f.database.createLocalACPSession(runtimeKind: .codex, title: "Passive", ownerDeviceID: UUID())
        let run = try await f.database.beginLocalACPRun(conversationID: id, content: "Retained private body")
        let capability = "/private/tmp/wmtools-" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 32) + ".sock"
        let native = "{\"token\":\"retained-protocol-token\",\"toolEndpoint\":\"\(capability)\"}"
        try await f.database.upsertDeviceOwnedRunActivity(runID: run.runID,
            activity: .init(id: "private-endpoint", kind: .tool, rawOutputJSON: native, rawPayloadJSON: native))
        try await f.database.completeLocalACPRun(runID: run.runID)
        try await f.database.write { db in
            try db.executeUnlocked("""
                WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 85)
                INSERT INTO dashboard_messages(id,conversation_id,role,content,created_at,updated_at,desktop_owned)
                SELECT printf('historical-%03d', x), '\(id)', 'user', 'Older body ' || x,
                  '2020-01-01', '2020-01-01', 1 FROM n
                """)
            try db.toolsExecuteUnlocked("UPDATE dashboard_messages SET content=? WHERE id='historical-085'",
                ["<wovenmatter-goal-continuation>\nPrivate continuation instructions"])
        }
        await f.model.refreshWorkspace()
        let trace = SQLTrace()
        try await f.database.inspectConnections { db in
            let statement = try db.prepareUnlocked("SELECT 1")
            defer { sqlite3_finalize(statement) }
            sqlite3_trace_v2(sqlite3_db_handle(statement), UInt32(SQLITE_TRACE_STMT), traceFacadeSQL, Unmanaged.passUnretained(trace).toOpaque())
        }
        defer {
            let database = f.database
            Task { [trace] in try? await database.inspectConnections { db in
                _ = trace
                let statement = try db.prepareUnlocked("SELECT 1")
                defer { sqlite3_finalize(statement) }
                sqlite3_trace_v2(sqlite3_db_handle(statement), 0, nil, nil)
            } }
        }
        _ = await f.model.canonicalActiveRunID(conversationID: id)
        _ = try await f.model.companionCommands.sessionCapabilities(conversationID: id)
        #expect(!trace.statements.contains { $0.contains("FROM dashboard_messages") })
        let backend = BackendApplicationService(model: f.model)
        #expect(await backend.handle(try rpc(.loadAgentDefaults(runtime: .codex, workspace: nil))).error == nil)
        #expect(await backend.handle(try rpc(.sessionMetadata(conversationID: id))).error == nil)
        let bodyQueryStart = trace.statements.count
        let page = try await f.model.companionCommands.transcript(conversationID: id)
        #expect(page.messages.count == 80)
        #expect(page.activeRunID == nil)
        let olderCursor = try #require(page.olderCursor)
        #expect(page.messages.first { $0.id == "historical-085" }?.content == "Continuing toward the goal.")
        let firstBodyQueries = trace.statements.dropFirst(bodyQueryStart).filter {
            $0.contains("FROM dashboard_messages") && $0.contains("message.content")
        }
        #expect(firstBodyQueries.count == 1)
        #expect(firstBodyQueries.allSatisfy { $0.contains("LIMIT 81") })
        let nextQueryStart = trace.statements.count
        let older = try await f.model.companionCommands.transcript(conversationID: id, before: olderCursor)
        #expect(!older.messages.isEmpty && older.olderCursor == nil)
        #expect(Set(page.messages.map(\.id)).isDisjoint(with: older.messages.map(\.id)))
        let messageIDs = Set((page.messages + older.messages).map(\.id))
        #expect(Set((1...85).map { String(format: "historical-%03d", $0) }).isSubset(of: messageIDs))
        let olderBodyQueries = trace.statements.dropFirst(nextQueryStart).filter {
            $0.contains("FROM dashboard_messages") && $0.contains("message.content")
        }
        #expect(olderBodyQueries.count == 1)
        #expect(olderBodyQueries.allSatisfy { $0.contains("LIMIT 81") })
        let invalidCursorStart = trace.statements.count
        let oversizedCursor = try JSONSerialization.data(withJSONObject: [
            "createdAt": "2020-01-01", "messageID": String(repeating: "x", count: 2049),
        ]).base64EncodedString()
        #expect(oversizedCursor.utf8.count > 2048)
        for invalid in [oversizedCursor, "not-base64!", Data("{}".utf8).base64EncodedString()] {
            await #expect(throws: (any Error).self) {
                try await f.model.companionCommands.transcript(conversationID: id, before: invalid)
            }
        }
        #expect(!trace.statements.dropFirst(invalidCursorStart).contains {
            $0.contains("FROM dashboard_messages") && $0.contains("message.content")
        })
        let providers = Set(ProviderKind.supportedAccounts)
        f.usageProbe.expectPassiveLimits(providers: providers)
        _ = try await f.usageService.snapshot(range: .today, refreshLimits: true,
            enabledProviders: providers, allowCredentialAccess: false)
        #expect(f.usageProbe.limitRequests.count == 1)
        let usageRequest = try #require(f.usageProbe.limitRequests.first)
        #expect(usageRequest.enabledProviders == providers && !usageRequest.allowCredentialAccess)
        #expect(usageRequest.keychainInteraction == .noninteractive && usageRequest.interactiveProvider == nil)
        #expect(usageRequest.openRouterAPIKey == nil)
        #expect(usageRequest.codexWorkspaceSource == nil && usageRequest.codexWorkspaceCount == 0)
        #expect(f.usageProbe.calls.isEmpty)
        #expect(await f.recorder.deliveries.isEmpty)
        #expect(await f.recorder.configurations.isEmpty)
        let export = try await f.model.exportConversation(id: id, format: .fullRun)
        defer { try? FileManager.default.removeItem(at: export) }
        let archive = try String(contentsOf: export, encoding: .utf8)
        #expect(archive.contains("Retained private body") && archive.contains("retained-protocol-token"))
        #expect(!archive.contains(String(repeating: "a", count: 32)) && !archive.contains(String(repeating: "b", count: 32)))
        let db = try await reopen(f)
        #expect(try await db.conversationContent(id: id).messages.contains { $0.content == "Retained private body" })
    }

    @Test func childCreationReplaysOnceAndRevokedCallerCannotDispatchAfterPreparation() async throws {
        let f = try await FacadeFixture(); defer { f.remove(); f.recorder.configurationGate.open() }
        let source = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        _ = try await f.database.setSessionToolEnabled(.sessions, enabled: true, sessionID: source)
        let tools = try #require(f.model.agentTools)
        let create = WovenMatterToolRequest(arguments: ["sessions", "create", "--title", "Child", "--text", "Initial work", "--purpose", "Fixture work", "--harness", "codex"])
        let result = await tools.handle(create, callerID: source)
        #expect(result.success, "\(result.error ?? "")")
        #expect(await tools.handle(create, callerID: source) == result)
        let child = try #require(try await f.database.workspaceOverview().conversations.first { $0.id != source })
        #expect(await f.recorder.deliveries.count == 1)
        let run = try #require(try await f.database.activeRunID(conversationID: child.id))
        try await f.model.cancelCanonicalRun(conversationID: child.id, runID: run)
        try await f.model.waitForAgentStop(conversationID: child.id)
        try await f.model.refreshClientExecutionState()
        let send = WovenMatterToolRequest(arguments: ["sessions", "send", child.id, "--text", "Revoked work"])
        pendingConfiguration(f, child.id)
        await f.recorder.holdConfiguration()
        let sending = Task { await tools.handle(send, callerID: source) }
        await f.recorder.waitForConfiguration()
        _ = try await f.database.setSessionToolEnabled(.sessions, enabled: false, sessionID: source)
        f.recorder.configurationGate.open()
        let rejected = await sending.value
        #expect(!rejected.success)
        #expect(await f.recorder.deliveries.count == 1)
        #expect(await !tools.handle(send, callerID: source).success)
        let db = try await reopen(f)
        #expect(try await db.workspaceOverview().conversations.count == 2)
        #expect(try await db.toolDelivery(id: send.requestID)?.status == "cancelled")
        #expect(try await db.conversationContent(id: child.id).messages.filter { $0.role == "user" }.map(\.content) == ["Initial work"])
    }

    @Test func boundGoalContinuationBlocksMissingUsageAndStoppedPreparationCannotCreateGoal() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let id = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        let tools = try #require(f.model.agentTools)
        let set = WovenMatterToolRequest(arguments: ["goals", "set", "--objective", "Verify the fixture", "--token-budget", "100"])
        let result = await tools.handle(set, callerID: id)
        #expect(result.success, "\(result.error ?? "")")
        #expect(await tools.handle(set, callerID: id) == result)
        let delivery = try #require(try await f.database.dueGoalDeliveries(running: []).first)
        #expect(try await f.model.dispatchToolDelivery(delivery).success)
        let run = try #require(try await f.database.activeRunID(conversationID: id))
        #expect(try await f.database.dueGoalDeliveries(running: [id]).isEmpty)
        try await f.database.completeLocalACPRun(runID: run)
        let goal = try #require(try await f.database.sessionGoals().first)
        _ = await tools.handle(.init(arguments: ["goals", "checkpoint", "--id", goal.id, "--evidence", "One step finished"]), callerID: id)
        #expect(try await f.database.dueGoalDeliveries(running: []).isEmpty)
        #expect(try await f.database.sessionGoals().first?.status == .blocked)
        #expect(try await f.database.sessionGoals().first?.tokensUsed == nil)
        let other = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        let stopped = f.model.beginAgentDispatch(conversationID: other)
        defer { f.model.finishAgentDispatch(conversationID: other, fence: stopped) }
        f.model.cancelPendingAgentDispatch(conversationID: other)
        await #expect(throws: CancellationError.self) {
            _ = try await f.database.mutateGoal(sessionID: other, mutation: .set(objective: "Never admitted", tokenBudget: nil, turnBudget: nil), dispatchFence: stopped)
        }
        let db = try await reopen(f)
        #expect(try await db.sessionGoals().count == 1)
        #expect(try await db.sessionGoals().first?.status == .blocked)
        #expect(await f.recorder.deliveries.count == 1)
    }

    @Test func conversationTrashRefusesActiveWorkAndPermanentlyCancelsUnsentDelivery() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let source = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        let id = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        let record = try await conversation(f, id)
        #expect(await f.model.sendAgentMessage(conversation: record, input: .init(text: "Oldest page")))
        await #expect(throws: (any Error).self) { try await f.model.mutateConversation(id: id, mutation: .moveToTrash) }
        let run = try #require(try await f.database.activeRunID(conversationID: id))
        try await f.model.cancelCanonicalRun(conversationID: id, runID: run)
        try await f.model.waitForAgentStop(conversationID: id)
        try await f.model.refreshClientExecutionState()
        let pending = UUID().uuidString.lowercased()
        _ = try await f.database.reserveToolDelivery(sourceID: source, targetID: id, text: "Never after trash", requestID: pending)
        #expect(try await f.database.claimToolDelivery(id: pending) != nil)
        try await f.model.mutateConversation(id: id, mutation: .moveToTrash)
        #expect(try await f.model.trashedConversations().map(\.id) == [id])
        try await f.model.mutateConversation(id: id, mutation: .restore)
        #expect(try await f.database.claimToolDelivery(id: pending) == nil)
        #expect(try await f.database.toolDelivery(id: pending)?.status == "cancelled")
        let export = try await f.model.exportConversation(id: id, format: .fullRun)
        defer { try? FileManager.default.removeItem(at: export) }
        #expect(try String(contentsOf: export, encoding: .utf8).contains("Oldest page"))
        let db = try await reopen(f)
        #expect(try await db.toolDelivery(id: pending)?.status == "cancelled")
        #expect(try await db.workspaceOverview().conversations.contains { $0.id == id })
        #expect(await f.recorder.deliveries.count == 1)
    }

    @Test func pagedHistoryDeduplicatesRefreshAndKeepsConversationGenerationsSeparate() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let id = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        // Fixture volume creates a genuine page boundary, not duplicate test cases.
        let file = f.directory.appending(path: "retained.txt")
        try Data("a".utf8).write(to: file)
        let attachments: [AgentMessageAttachmentDraft] = [
            .reference(.init(kind: .note, resourceID: "fixture-note", titleSnapshot: "Research", contentSnapshot: "Retained reference", revisionSnapshot: "1")),
            .file(.init(kind: .file, fileName: "retained.txt", mimeType: "text/plain", sizeBytes: 1,
                contentHash: String(repeating: "a", count: 64), localURL: file))
        ]
        for index in 0..<5 {
            let run = try await f.database.beginLocalACPRun(conversationID: id,
                input: .init(text: "Input \(index)", attachments: index == 0 ? attachments : []))
            try await f.database.upsertDeviceOwnedRunActivity(runID: run.runID,
                activity: .init(id: "activity-\(index)", kind: .tool, phase: "completed", title: "Read", content: "Output \(index)"))
            try await f.database.completeLocalACPRun(runID: run.runID)
        }
        let other = try #require(await f.model.createLocalACPSession(runtimeKind: .codex))
        let tail = try await f.database.conversationHistoryPage(id: id, limit: 4)
        let initial = DashboardConversationWindow(page: tail)
        let cursor = WorkspaceConversationHistoryCursor(createdAt: try #require(initial.messages.first).createdAt, messageID: try #require(initial.messages.first).id)
        let older = try await f.database.conversationHistoryPage(id: id, before: cursor, limit: 20)
        let expanded = initial.prepending(older, requestedFrom: initial)
        let refreshed = expanded.refreshing(with: tail, knownMessageIDs: Set(initial.messages.map(\.id)))
        #expect(Set(refreshed.messages.map(\.id)).count == refreshed.messages.count)
        #expect(refreshed.messages.filter { $0.role == "user" }.map(\.content) == (0..<5).map { "Input \($0)" })
        #expect(refreshed.runs.allSatisfy { $0.conversationID == id })
        let a = DashboardConversationState(conversationID: id), b = DashboardConversationState(conversationID: other)
        let stale = a.beginRefresh(); let current = a.beginRefresh(); let separate = b.beginRefresh()
        #expect(!a.isCurrentRefresh(stale) && a.isCurrentRefresh(current) && b.isCurrentRefresh(separate))
        let foreign = try await f.database.conversationHistoryPage(id: other, limit: 4)
        #expect(DashboardConversationWindow(page: foreign).messages.isEmpty)
        #expect(expanded.messages.count > initial.messages.count)
        #expect(expanded.activities.count == 5)
        let oldest = try #require(expanded.messages.first)
        #expect(expanded.attachments.map(\.messageID) == [oldest.id])
        #expect(expanded.references.map(\.messageID) == [oldest.id])
        let removedID = oldest.id
        try await f.database.write { try $0.toolsExecuteUnlocked("DELETE FROM dashboard_messages WHERE id=?", [removedID]) }
        let afterDelete = try await f.database.conversationHistoryPage(id: id, limit: 4,
            knownMessageIDs: expanded.messages.map(\.id))
        let reconciled = expanded.refreshing(with: afterDelete, knownMessageIDs: Set(expanded.messages.map(\.id)))
        let latePage = reconciled.prepending(older, requestedFrom: expanded)
        #expect(!latePage.messages.contains { $0.id == removedID })
        #expect(latePage.attachments.isEmpty && latePage.references.isEmpty)
        let db = try await reopen(f)
        #expect(try await db.conversationContent(id: id).messages.count == latePage.messages.count)
    }

    @Test func openCodeFrontendIgnoresLateCommandSnapshotAndKeepsCatalogsScoped() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let frontend = await OpenCodeModel(store: f.store, ownerDeviceID: UUID(), defaults: f.defaults, backendRequest: { _, _ in throw JourneyError.sqlite })
        var old = frontend.backendSnapshot(), latest = old
        old.catalogIncluded = true; old.models = ["chat-a": [["id": "old-model"]]]
        latest.catalogIncluded = true; latest.models = ["chat-b": [["id": "new-model"]]]
        latest.ready = true; latest.statuses = ["chat-b": "Connected"]
        let gate = FacadeGate(); gate.hold(); defer { gate.open() }
        var calls: [BackendOpenCodeCommand] = []
        frontend.backendRequest = { method, data in
            #expect(method == "opencode.command")
            let request = try JSONDecoder().decode(BackendOpenCodeRequest.self, from: data)
            calls.append(request.command)
            if calls.count == 1 { await gate.pass(); return try JSONEncoder().encode(BackendOpenCodeResponse(snapshot: old)) }
            return try JSONEncoder().encode(BackendOpenCodeResponse(snapshot: latest))
        }
        let first = Task { try await frontend.refreshCatalog("chat-a") }
        await gate.waitForArrival()
        try await frontend.refreshCatalog("chat-b")
        gate.open(); try await first.value
        #expect(frontend.backendSnapshot(catalogSessionID: "chat-b").models["chat-b"]?.first?["id"].text == "new-model")
        #expect(frontend.backendSnapshot(catalogSessionID: "chat-a").models["chat-a"] == nil)
        #expect(frontend.isReady && frontend.statuses["chat-b"] == "Connected")
        #expect(calls.count == 2)
        #expect(await f.recorder.deliveries.isEmpty)
        #expect(await f.recorder.configurations.isEmpty)
        _ = try await reopen(f)
    }


    @Test func stopOfClaimedCalendarDispatchPersistsCancellationInsteadOfRetry() async throws {
        let f = try await FacadeFixture(); defer { f.remove(); f.recorder.configurationGate.open() }
        var task = f.model.calendarTaskDefaults(runtime: .codex, workspaceID: nil, title: "Stopped occurrence")
        task.prompt = "Do not execute"
        #expect(await f.model.saveCalendarEvent(.init(title: "Stopped occurrence", startsAt: Date().addingTimeInterval(-1), task: task)))
        let run = try #require(try await f.database.dueCalendarRuns().first)
        _ = try #require(await f.model.createLocalACPSession(runtimeKind: .codex, requestedConversationID: UUID(uuidString: run.sessionID)))
        let delivery = try await f.database.prepareCalendarDelivery(runID: run.id)
        pendingConfiguration(f, run.sessionID)
        await f.recorder.holdConfiguration()
        let dispatching = Task { try await f.model.dispatchToolDelivery(delivery) }
        await f.recorder.waitForConfiguration()
        let stopping = f.model.beginAgentStop(conversationID: run.sessionID)
        try await stopping.value
        f.recorder.configurationGate.open()
        let response = try await dispatching.value
        #expect(!response.success && response.code == "delivery_cancelled")
        #expect(try await f.database.toolDelivery(id: delivery.id)?.status == "cancelled")
        #expect(try await f.database.toolDelivery(id: delivery.id)?.failureCode == "delivery_cancelled")
        await f.model.runCalendarTasks()
        #expect(await f.recorder.deliveries.isEmpty)
        let db = try await reopen(f)
        #expect(try await db.claimToolDelivery(id: delivery.id) == nil)
        #expect(try await db.toolDelivery(id: delivery.id)?.status == "cancelled")
    }

}

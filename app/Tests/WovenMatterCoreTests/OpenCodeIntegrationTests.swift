import WorkspaceFixtures
import Foundation
import Testing
import SQLite3
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite(.serialized)
struct OpenCodeIntegrationTests {

    @Test func durableEventsCoalesceAndRefreshAgainAfterAnInflightSnapshot() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Events", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        defer { session.invalidateAndCancel() }
        do {
            try await coordinator.connect(connection())
            let baseline = fixture.lock.withLock { fixture.historyRequests }
            fixture.messages = [message("first")]
            fixture.heldPath = "/api/session/ses_fixture/form/form_pending"
            await coordinator.receiveLogEvent(["type": "session.text.delta", "durable": ["seq": .number(1)]], link: link)
            try await fixture.gate.waitForArrival(timeout: .seconds(10))
            #expect(fixture.lock.withLock { fixture.historyRequests } == baseline + 2)
            // Hold a real refresh after its history requests, so this burst must
            // coalesce into one follow-up regardless of the debounce scheduler.
            for seq in 2...5 { await coordinator.receiveLogEvent(["type": "session.text.delta", "durable": ["seq": .number(Double(seq))]], link: link) }
            fixture.heldPath = nil
            fixture.gate.release()
            // History responses precede form resolution and the database commit.
            // Start the next phase only after the coordinator publishes cursor 5.
            _ = try await committedSnapshot(coordinator, conversationID: id, cursor: 5)
            // Initial refresh probes the end of history; its one follow-up
            // recognizes the same first message and needs only one history page.
            #expect(fixture.lock.withLock { fixture.historyRequests } == baseline + 3)

            fixture.heldPath = "/api/session/ses_fixture/form/form_pending"
            fixture.messages = [message("during-first")]
            await coordinator.receiveLogEvent(["type": "session.text.delta", "durable": ["seq": .number(6)]], link: link)
            try await fixture.gate.waitForArrival(timeout: .seconds(10))
            fixture.messages = [message("during-second")]
            await coordinator.receiveLogEvent(["type": "session.execution.failed", "durable": ["seq": .number(7)]], link: link)
            fixture.heldPath = nil
            fixture.gate.release()
            _ = try await committedSnapshot(coordinator, conversationID: id, cursor: 7)
            #expect(fixture.lock.withLock { fixture.historyRequests } == baseline + 7)
            let saved = try #require(try await database.openCodeSnapshot(conversationID: id))
            #expect(saved.messages.last?["id"].text == "during-second")
            #expect(saved.cursor == 7)
        } catch {
            fixture.heldPath = nil
            fixture.gate.release()
            await coordinator.shutdown()
            throw error
        }
        await coordinator.shutdown()
    }

    private func committedSnapshot(_ coordinator: OpenCodeSessionCoordinator, conversationID: String,
                                   cursor: Int64) async throws -> OpenCodeSessionSnapshot {
        try await withThrowingTaskGroup(of: OpenCodeSessionSnapshot.self) { group in
            group.addTask {
                for await update in coordinator.updates {
                    if update.conversationID == conversationID, let snapshot = update.snapshot,
                       snapshot.cursor == cursor { return snapshot }
                    if let error = update.error { throw OpenCodeError.message(error) }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw OpenCodeError.message("Fixture did not publish committed snapshot cursor \(cursor).")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    @Test(arguments: [false, true])
    func savedTranscriptsWithoutExecutionAuthorityRemainReadable(archived: Bool) async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Saved transcript", ownerDeviceID: UUID(),
            openCodeAssociation: ("fixture", "ses_fixture"))
        var saved = OpenCodeSessionSnapshot()
        saved.info = ["id": "ses_fixture", "title": "Saved transcript"]
        saved.messages = [message("Saved text")]
        try await database.saveOpenCodeSnapshot(saved, conversationID: id)
        if archived {
            try await database.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_archived=1 WHERE id=?", [id]) }
        } else {
            try await database.write { try $0.toolsExecuteUnlocked("INSERT INTO retained_execution_history(conversation_id) VALUES(?)", [id]) }
        }
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        await coordinator.watch(link)
        await coordinator.receiveLogEvent(["type": "session.text.delta", "durable": ["seq": .number(1)]], link: link)
        await #expect(throws: OpenCodeError.self) { try await coordinator.refresh(link) }
        await #expect(throws: OpenCodeError.self) {
            try await coordinator.sessionCall(link, suffix: "/interrupt", method: "POST", body: nil)
        }
        await #expect(throws: OpenCodeError.self) { try await coordinator.prompt(link, input: .init(text: "Do not send")) }
        #expect(try await database.resumableOpenCodeLinks().isEmpty)
        #expect(fixture.streamTimeout == nil && fixture.promptCount == 0 && fixture.interruptCount == 0)
        #expect(try await database.openCodeSnapshot(conversationID: id) == saved)
        let content = try await database.conversationContent(id: id)
        #expect(archived ? content.messages.isEmpty : content.messages.first?.content == "Saved text")
        await coordinator.shutdown()
    }


    @Test func importPageExcludesKnownAndNativeSessionsAndStopsAtOnePage() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.sessions = (0..<60).map { ["id": .string("ses_\($0)"), "title": .string("Session \($0)")] }
        fixture.sessions[1]["metadata"] = ["wovenmatter": ["origin": "created"]]
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        _ = try await db.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Known", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_0"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: db, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        let first = try await coordinator.importableSessions(connectionID: "fixture")
        #expect(first.sessions.count == 25)
        #expect(first.sessions.first?["id"].text == "ses_2")
        #expect(first.sessions.last?["id"].text == "ses_26")
        #expect(fixture.listedCount == 27)
        let second = try await coordinator.importableSessions(connectionID: "fixture", cursor: first.next)
        #expect(second.sessions.first?["id"].text == "ses_27")
        #expect(Set(first.sessions.map { $0["id"].text }).isDisjoint(with: second.sessions.map { $0["id"].text }))
        await coordinator.shutdown()
    }

    @Test func unifiedDiscoveryPreservesVisibleInputAndDurableAgentAttribution() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let source = try await database.createOpenCodeFixtureSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
        let target = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Work", ownerDeviceID: UUID())
        let link = OpenCodeSessionLink(conversationID: target, connectionID: "fixture", sessionID: "ses_fixture")
        try await database.attachOpenCodeSession(link)
        let deliveryID = UUID().uuidString.lowercased()
        _ = try await database.reserveToolDelivery(sourceID: source, targetID: target, text: "Build this", requestID: deliveryID)
        _ = try await database.claimToolDelivery(id: deliveryID)
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        try await coordinator.prompt(link, input: .init(text: "Build this", historyDeliveryID: deliveryID))
        let raw = try #require(try await database.openCodeSnapshot(conversationID: target))
        #expect(fixture.lastPrompt["delivery"].text == "steer")
        #expect(raw.messages.last?["text"].text == "Build this")
        let display = try await database.openCodeDisplaySnapshot(raw, conversationID: target)
        #expect(display.messages.last?["text"].text == "Build this")
        let content = try await database.conversationContent(id: target)
        let input = try #require(content.messages.first(where: { $0.role == "user" }))
        #expect(input.content == "Build this")
        #expect(input.senderSessionID == source)
        #expect(input.senderKind == .message)
        #expect(input.senderSessionTitle == "Coordinator")
        #expect(try await database.toolDelivery(id: deliveryID)?.messageID == input.id)
        let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        #expect(try await reopened.openCodeDisplaySnapshot(raw, conversationID: target).messages.last?["text"].text == "Build this")
        await coordinator.disconnect(connectionID: "fixture")
    }

    @Test func largeCatchupPreservesOlderPageAnchorAndRefreshesLoadedHistory() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.messages = (0..<350).map { message("msg_history_\($0)") }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Paging", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        try await coordinator.refresh(link)
        try await coordinator.loadOlder(link)
        try await coordinator.loadOlder(link)
        let originalCursor = try await database.openCodeSnapshot(conversationID: id)?.olderCursor
        fixture.messages += (350..<800).map { message("msg_history_\($0)") }
        try await coordinator.refresh(link)
        #expect(try await database.openCodeSnapshot(conversationID: id)?.olderCursor == originalCursor)
        try await coordinator.loadOlder(link)
        #expect(try await database.openCodeSnapshot(conversationID: id)?.messages.map { $0["id"].text } == fixture.messages.map { $0["id"].text })
        // A reconnect must also refresh old loaded content, even when the new
        // messages alone exceed the previously loaded history length.
        fixture.messages[0]["text"] = "Updated by another client"
        fixture.messages += (800..<1700).map { message("msg_history_\($0)") }
        try await coordinator.refresh(link, recoverHistory: true)
        let recovered = try #require(try await database.openCodeSnapshot(conversationID: id))
        #expect(recovered.messages.count == 1700)
        #expect(recovered.messages.first?["text"].text == "Updated by another client")
        #expect(recovered.olderCursor == nil)
        try await coordinator.refresh(link)
        #expect(try await database.openCodeSnapshot(conversationID: id)?.olderCursor == nil)
        await coordinator.shutdown()
    }

    @Test func creationModelSelectionRequiresServerConfirmation() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        let id = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Selection", ownerDeviceID: UUID(),
            openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let selection: OpenCodeValue = ["model": ["providerID": "provider", "id": "chosen", "variant": "high"]]
        let confirmed = try await coordinator.configureSelection(link, selection: selection)
        #expect(confirmed["model"] == selection["model"])
        #expect(fixture.modelWriteCount == 1)
        fixture.acceptModelSelection = false
        let changed: OpenCodeValue = ["model": ["providerID": "provider", "id": "chosen", "variant": "low"]]
        await #expect(throws: OpenCodeError.self) { try await coordinator.configureSelection(link, selection: changed) }
        let wrongModel: OpenCodeValue = ["model": ["providerID": "provider", "id": "different", "variant": "high"]]
        await #expect(throws: OpenCodeError.self) { try await coordinator.configureSelection(link, selection: wrongModel) }
        #expect(fixture.modelWriteCount == 3 && fixture.promptCount == 0)
        fixture.sessionExists = false
        await #expect(throws: OpenCodeError.http(404)) { try await coordinator.configureSelection(link, selection: changed) }
        await coordinator.shutdown()
    }

    @Test func formReplyRequiresExternalAcknowledgementAndPreservesCustomAnswers() throws {
        let fields: [OpenCodeValue] = [
            ["key": "verification", "type": "external", "url": "https://example.com/verify"],
            ["key": "choice", "type": "string", "required": .bool(true), "custom": .bool(true),
             "options": .array([["label": "Suggested", "value": "suggested"]])],
            ["key": "amount", "type": "integer", "minimum": .number(1), "maximum": .number(3)],
            ["key": "details", "type": "string", "when": .array([["key": "choice", "op": "eq", "value": "suggested"]])]
        ]
        var answers: [String: OpenCodeValue] = ["choice": "My own answer", "amount": "2", "details": "stale hidden answer"]
        #expect(throws: OpenCodeError.self) { try OpenCodeFormAnswers.reply(fields: fields, answers: answers) }
        answers["verification"] = .bool(false)
        #expect(throws: OpenCodeError.self) { try OpenCodeFormAnswers.reply(fields: fields, answers: answers) }
        answers["verification"] = .bool(true)
        let custom = try OpenCodeFormAnswers.reply(fields: fields, answers: answers)
        #expect(custom == ["verification": .bool(true), "choice": "My own answer", "amount": .number(2)])
        answers["choice"] = "suggested"
        #expect(try OpenCodeFormAnswers.reply(fields: fields, answers: answers)["details"] == "stale hidden answer")
        answers["amount"] = "2.5"
        #expect(throws: OpenCodeError.self) { try OpenCodeFormAnswers.reply(fields: fields, answers: answers) }
        answers["amount"] = "4"
        #expect(throws: OpenCodeError.self) { try OpenCodeFormAnswers.reply(fields: fields, answers: answers) }
    }


    @Test func fullImportPreservesDirectoryAndRecencyWithoutDuplicatingSessions() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.messages = (0..<250).map { message("msg_import_\($0)") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: db, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        let snapshot = try await coordinator.completeImportSnapshot(connectionID: "fixture", sessionID: "ses_fixture")
        #expect(snapshot.messages.map { $0["id"] } == fixture.messages.map { $0["id"] })
        #expect(snapshot.info["location"]["directory"].text == "/original/project")
        #expect(snapshot.olderCursor == nil)
        #expect(fixture.historyRequests == 4)
        #expect(fixture.createCount == 0)
        let id = try await db.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Imported", ownerDeviceID: UUID(),
            openCodeAssociation: ("fixture", "ses_fixture"), importedOpenCodeSnapshot: snapshot)
        let repeated = try await db.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Again", ownerDeviceID: UUID(),
            openCodeAssociation: ("fixture", "ses_fixture"), importedOpenCodeSnapshot: snapshot)
        #expect(repeated == id)
        #expect(try await db.knownOpenCodeSessionIDs(connectionID: "fixture") == ["ses_fixture"])
        try await db.saveOpenCodeSnapshot(snapshot, conversationID: id)
        let reopened = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        #expect(try await reopened.openCodeSnapshot(conversationID: id)?.messages.count == 250)
        #expect(try await reopened.conversationContent(id: id).messages.count == 250)
        let record = try #require(try await reopened.workspaceOverview().conversations.first { $0.id == id })
        #expect(record.importedAt != nil)
        #expect(record.lastMessageAt == record.importedAt)
        await coordinator.shutdown()
    }

    @Test func nativeCommandCatalogPreservesDescriptionsAndOnlyRoutesKnownCommands() {
        let catalog: [OpenCodeValue] = [
            ["name": "review", "description": "Review changes"], ["name": "review"],
            ["name": ""], ["name": "invalid command"], ["name": "help"]
        ]
        let metadata = OpenCodeComposerMetadata.metadata(session: ["id": "ses_fixture"], models: [], commands: catalog)
        #expect(metadata.slashCommands.map(\.name) == ["review", "help"])
        #expect(metadata.slashCommands.first?.detail == "Review changes")
        let command = OpenCodeComposerMetadata.invocation("/review  current changes\nincluding tests", commands: catalog)
        #expect(command?.name == "review")
        #expect(command?.arguments == "current changes\nincluding tests")
        #expect(OpenCodeComposerMetadata.invocation("/unknown text", commands: catalog) == nil)
        #expect(OpenCodeComposerMetadata.invocation("explain /review", commands: catalog) == nil)
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
        fixture.version = "1.18.29"
        await #expect(throws: OpenCodeError.incompatible("1.18.29")) {
            try await OpenCodeServiceLauncher.ensure(executable: URL(fileURLWithPath: "/never-run"), registration: file, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func richProjectionAndRecoveryCursorSurviveDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "workspace.sqlite")
        let database = try await WorkspaceDatabase(url: url)
        let id = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Rich fixture", ownerDeviceID: UUID())
        try await database.attachOpenCodeSession(.init(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture"))
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
        try await database.saveOpenCodeSnapshot(snapshot, conversationID: id)
        try await database.saveOpenCodeSnapshot(snapshot, conversationID: id)
        let reopened = try await WorkspaceDatabase(url: url)
        #expect(try await reopened.openCodeSnapshot(conversationID: id) == snapshot)
        let content = try await reopened.conversationContent(id: id)
        #expect(content.messages.count == 2)
        #expect(content.runs.count == 1)
        #expect(content.runs.first?.completedAt?.hasPrefix("1970-01-01T00:00:00.003") == true)
        #expect(try await reopened.conversationHistoryPage(id: id, limit: 100).activities.count == 3)
    }


    @Test func unknownAcceptanceBlocksNewInputWithoutTreating404AsRejection() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.losePromptResponse = true; fixture.acceptPrompt = false
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "fixture", ownerDeviceID: UUID())
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        try await database.attachOpenCodeSession(link)
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        let timer = WorkspaceSessionTimer(sessionID: id, instruction: "unknown", nextFireAt: .distantPast)
        try await database.saveSessionTimer(timer, callerID: id)
        let pending = try #require(try await database.dueSessionTimers().first?.pendingDeliveryID)
        _ = try await database.reserveToolDelivery(sourceID: id, targetID: id, text: timer.instruction, requestID: pending, kind: .timer)
        _ = try await database.claimToolDelivery(id: pending)
        let now = Date()
        // A disconnected native client fails before HTTP and keeps the one-shot.
        await #expect(throws: OpenCodeError.self) { try await coordinator.prompt(link, input: .init(text: timer.instruction, historyDeliveryID: pending)) }
        try await database.failToolDeliveryAttempt(id: pending, now: now)
        try await database.finishTimerOccurrence(id: timer.id, deliveryID: pending)
        #expect(try await database.toolDelivery(id: pending)?.status == "queued")
        #expect(try await database.sessionTimers().first?.pendingDeliveryID == pending)
        #expect(fixture.promptCount == 0)
        try await coordinator.connect(connection())
        _ = try #require(try await database.claimToolDelivery(id: pending, now: now.addingTimeInterval(30)))
        await #expect(throws: OpenCodeError.self) { try await coordinator.prompt(link, input: .init(text: timer.instruction, historyDeliveryID: pending)) }
        try await database.failToolDeliveryAttempt(id: pending)
        try await database.finishTimerOccurrence(id: timer.id, deliveryID: pending)
        #expect(try await database.toolDelivery(id: pending)?.status == "uncertain")
        #expect(try await database.sessionTimers().first?.pendingDeliveryID == pending)
        #expect(try await database.sessionTimers().first?.isPaused == false)
        #expect(try await database.claimToolDelivery(id: pending) == nil)
        await #expect(throws: OpenCodeError.self) { try await coordinator.prompt(link, input: .init(text: "do not duplicate")) }
        #expect(fixture.promptCount == 1)
        #expect(try await database.openCodeUncertainSubmissions(conversationID: id).count == 1)
        await coordinator.shutdown()
    }

    @Test func nativeCommandsAcceptNoContentAndNeverRetryLostResponsesAsPrompts() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Commands", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let source = try await database.createOpenCodeFixtureSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
        let deliveryID = UUID().uuidString.lowercased()
        _ = try await database.reserveToolDelivery(sourceID: source, targetID: id, text: "current changes", requestID: deliveryID)
        _ = try await database.claimToolDelivery(id: deliveryID)
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        let receipt = try await coordinator.command(link, name: "review", input: .init(text: "current changes", historyDeliveryID: deliveryID))
        #expect(receipt.nativeUserMessageID == nil)
        #expect(receipt.identifiers == nil)
        #expect(fixture.commandCount == 1)
        #expect(fixture.lastCommand["name"].text == "review")
        #expect(fixture.lastCommand["text"].text == "current changes")
        #expect(fixture.lastCommand["id"].isNull)
        #expect(fixture.lastCommand["delivery"].text == "steer")
        #expect(try await database.toolDelivery(id: deliveryID)?.status == "accepted")
        #expect(try await database.toolDelivery(id: deliveryID)?.nativeCommand == "review")
        #expect(try await database.toolDelivery(id: deliveryID)?.messageID == nil)
        #expect(try await database.openCodeUncertainSubmissions(conversationID: id).isEmpty)
        fixture.loseCommandResponse = true
        let uncertainID = UUID().uuidString.lowercased()
        _ = try await database.reserveToolDelivery(sourceID: source, targetID: id, text: "again", requestID: uncertainID)
        _ = try await database.claimToolDelivery(id: uncertainID)
        await #expect(throws: OpenCodeError.self) { try await coordinator.command(link, name: "review", input: .init(text: "again", historyDeliveryID: uncertainID)) }
        try await database.failToolDeliveryAttempt(id: uncertainID)
        #expect(try await database.toolDelivery(id: uncertainID)?.status == "uncertain")
        #expect(try await database.claimToolDelivery(id: uncertainID) == nil)
        #expect(fixture.commandCount == 2)
        #expect(fixture.promptCount == 0)
        #expect(try await database.openCodeUncertainSubmissions(conversationID: id).isEmpty)
        let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let incoming = try await reopened.sessionDeliveries(sessionID: id, activityOnly: true)
        #expect(incoming.count == 2)
        let timeline = WorkspaceConversationTimelineItem.weave(messages: [], receipts: incoming, sessionID: id)
        #expect(timeline.count == 2)
        #expect(timeline.allSatisfy { if case .incomingCommand(let receipt) = $0 { receipt.sourceID == source } else { false } })
        await coordinator.shutdown()
    }

    @Test func companionAdmissionChecksNativeActivityAndInterruptRejectsStaleRuns() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try await database.createOpenCodeFixtureSession(runtimeKind: .opencode, title: "Companion",
            ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database,
            clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())

        // Native execution may be active before it publishes an assistant row.
        fixture.active = true
        await #expect(throws: LocalACPSessionDatabaseError.runAlreadyActive) {
            try await coordinator.prompt(link, input: .init(text: "Do not queue"), requiresIdle: true)
        }
        await #expect(throws: LocalACPSessionDatabaseError.runAlreadyActive) {
            try await coordinator.command(link, name: "review", input: .init(text: ""), requiresIdle: true)
        }
        #expect(fixture.promptCount == 0 && fixture.commandCount == 0)

        fixture.messages = [["id": "msg_current", "type": "assistant", "text": "Working",
            "time": ["created": .number(900)]]]
        await #expect(throws: LocalACPSessionDatabaseError.runNotFound) {
            try await coordinator.interrupt(link, expectedRunID: "opencode:\(id):msg_previous:run")
        }
        #expect(fixture.interruptCount == 0)
        let currentRunID = try #require(try await database.activeRunID(conversationID: id))
        #expect(currentRunID == "opencode:\(id):msg_current:run")
        try await coordinator.interrupt(link, expectedRunID: currentRunID)
        #expect(fixture.interruptCount == 1)

        fixture.active = false
        let receipt = try await coordinator.prompt(link, input: .init(text: "Next"), requiresIdle: true)
        #expect(receipt.nativeUserMessageID == fixture.lastPrompt["id"].text)
        #expect(receipt.identifiers == nil)
        await coordinator.shutdown()
    }

    @Test func interruptedSessionCreationReusesThePendingIdentity() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.sessionExists = false
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        // A previous create did not reach the server. Recovery sees 404 and
        // safely submits that same identity instead of blocking all new chats.
        let created = try await coordinator.createSession(connectionID: "fixture", id: "ses_fixture", workspace: directory, recover: true, title: "Requested title", nativeWorkspaceID: "workspace_fixture")
        #expect(created["data"]["id"].text == "ses_fixture")
        #expect(fixture.createCount == 1)
        #expect(fixture.lastCreate["location"]["directory"].text == directory.path)
        #expect(fixture.lastCreate["location"]["workspaceID"].text == "workspace_fixture")
        #expect(fixture.lastCreate["title"].text == "Requested title")
        // If only the response was lost, recovery retrieves the existing session.
        let recovered = try await coordinator.createSession(connectionID: "fixture", id: "ses_fixture", workspace: directory, recover: true)
        #expect(recovered["data"]["id"].text == "ses_fixture")
        #expect(fixture.createCount == 1)
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
    var heldPath: String?
    var sessionExists = true
    var nativeDirectory = "/original/project"
    var createCount = 0
    var lastCreate: OpenCodeValue = .null
    var selectedModel: OpenCodeValue = .null
    var acceptModelSelection = true
    var modelWriteCount = 0
    var version = "2.0.22"
    var healthCount = 0
    var messages: [OpenCodeValue] = []
    var sessions: [OpenCodeValue] = []
    var listedCount = 0
    var losePromptResponse = false
    var acceptPrompt = true
    var promptCount = 0
    var lastPrompt: OpenCodeValue = .null
    var commandCount = 0
    var loseCommandResponse = false
    var lastCommand: OpenCodeValue = .null
    var interruptCount = 0
    var active = false
    var historyRequests = 0
    var streamTimeout: TimeInterval?
    private func requestBody(_ request: URLRequest) throws -> OpenCodeValue {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(n))
            }
        }
        return try OpenCodeValue.decode(bytes)
    }
    func respond(_ request: URLRequest) throws -> (Int, OpenCodeValue) {
        try lock.withLock {
            var path = request.url!.path
            let prefix = "/v1/workspace-instances/opencode"
            if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
            if path.hasSuffix("/log") { streamTimeout = request.timeoutInterval; return (200, [:]) }
            if path == "/api/info" || path == "/api/health" {
                healthCount += 1
                if path == "/api/info", version.hasPrefix("0.0.0-beta-") { return (404, [:]) }
                return (200, ["healthy": .bool(true), "version": .string(version), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))])
            }
            if path == "/api/session/active" {
                return (200, ["data": active ? ["ses_fixture": ["status": "running"]] : [:]])
            }
            if path.hasSuffix("/interrupt") { interruptCount += 1; return (200, [:]) }
            if path.hasSuffix("/prompt") || path.hasSuffix("/command") {
                var bytes = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
                }
                let input = try OpenCodeValue.decode(bytes)
                if path.hasSuffix("/command") {
                    commandCount += 1
                    lastCommand = input
                    if loseCommandResponse { throw URLError(.networkConnectionLost) }
                    return (204, .null)
                }
                promptCount += 1
                lastPrompt = input
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
            if path.contains("/form/") {
                if request.httpMethod == "DELETE" { return (204, .null) }
                return (200, ["data": ["state": ["status": path.contains("form_pending") ? "pending" : "answered"]]])
            }
            if path.hasSuffix("/inbox") { return (200, ["data": .array([])]) }
            if path == "/api/session", request.httpMethod == "GET" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                let offset = query.first { $0.name == "cursor" }?.value.flatMap(Int.init) ?? 0
                let limit = query.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? 25
                let rows = Array(sessions.dropFirst(offset).prefix(limit))
                listedCount += rows.count
                return (200, ["data": .array(rows), "cursor": ["next": offset + rows.count < sessions.count ? .string(String(offset + rows.count)) : .null]])
            }
            if path == "/api/session", request.httpMethod == "POST" {
                createCount += 1; sessionExists = true
                lastCreate = try requestBody(request)
                nativeDirectory = lastCreate["location"]["directory"].text
                return (200, ["data": ["id": "ses_fixture", "title": "Created fixture"]])
            }
            if path == "/api/session/ses_fixture/model" {
                guard sessionExists else { return (404, [:]) }
                modelWriteCount += 1
                let selection = try requestBody(request)
                if acceptModelSelection { selectedModel = selection["model"] }
                return (204, .null)
            }
            if path == "/api/session/ses_fixture", !sessionExists { return (404, [:]) }
            if path == "/api/session/ses_fixture" { return (200, ["data": ["id": "ses_fixture", "title": "Shared fixture", "model": selectedModel, "location": ["directory": .string(nativeDirectory)], "time": ["updated": .number(900)]]]) }
            return (404, [:])
        }
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture = OpenCodeFixture()
    override class func canInit(with request: URLRequest) -> Bool { ["fixture.invalid", "127.0.0.1"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if (request.url?.path == "/api/info" && Self.fixture.holdHealth) || request.url?.path == Self.fixture.heldPath {
            let fixture = Self.fixture
            fixture.gate.arrive(self)
        } else { deliver() }
    }
    func deliver() {
        do {
            let (status, value) = try Self.fixture.respond(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            if status != 204 { client?.urlProtocol(self, didLoad: try JSONEncoder().encode(value)) }
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class FixtureHealthGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: FixtureProtocol?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func arrive(_ request: FixtureProtocol) {
        let ready = lock.withLock { pending = request; let result = Array(waiters.values); waiters.removeAll(); return result }
        ready.forEach { $0.resume() }
    }
    func waitForArrival() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = lock.withLock {
                    if pending != nil || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
    func waitForArrival(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForArrival(); try Task.checkCancellation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw OpenCodeError.message("Fixture did not receive the held refresh request.")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
    func release() { let request = lock.withLock { let result = pending; pending = nil; return result }; request?.deliver() }
}

private extension WorkspaceDatabase {
    func createOpenCodeFixtureSession(runtimeKind: AgentRuntimeKind, title: String, ownerDeviceID: UUID,
        openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
        importedOpenCodeSnapshot: OpenCodeSessionSnapshot? = nil, requestedConversationID: UUID? = nil) async throws -> String {
        try await createFixtureLocalACPSession(runtimeKind: runtimeKind, title: title, ownerDeviceID: ownerDeviceID,
            openCodeAssociation: openCodeAssociation, importedOpenCodeSnapshot: importedOpenCodeSnapshot,
            requestedConversationID: requestedConversationID,
            fixtureLocation: .init(workspaceID: "device:test", rootPath: "/original/project", managed: false))
    }
}

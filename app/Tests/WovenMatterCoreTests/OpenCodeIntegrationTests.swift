import Foundation
import Testing
import SQLite3
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite(.serialized)
struct OpenCodeIntegrationTests {
    @Test func importPageExcludesKnownAndNativeSessionsAndStopsAtOnePage() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.sessions = (0..<60).map { ["id": .string("ses_\($0)"), "title": .string("Session \($0)")] }
        fixture.sessions[1]["metadata"] = ["wovenmatter": ["origin": "created"]]
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        _ = try db.createLocalACPSession(runtimeKind: .opencode, title: "Known", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_0"))
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

    @Test func fullImportPreservesDirectoryAndRecencyWithoutDuplicatingSessions() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.messages = (0..<250).map { message("msg_import_\($0)") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: db, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        let snapshot = try await coordinator.completeImportSnapshot(connectionID: "fixture", sessionID: "ses_fixture")
        #expect(snapshot.messages.map { $0["id"] } == fixture.messages.map { $0["id"] })
        #expect(snapshot.info["location"]["directory"].text == "/original/project")
        #expect(snapshot.olderCursor == nil)
        #expect(fixture.historyRequests == 4)
        #expect(fixture.createCount == 0)
        let id = try db.createLocalACPSession(runtimeKind: .opencode, title: "Imported", ownerDeviceID: UUID(),
            openCodeAssociation: ("fixture", "ses_fixture"), importedOpenCodeSnapshot: snapshot)
        let repeated = try db.createLocalACPSession(runtimeKind: .opencode, title: "Again", ownerDeviceID: UUID(),
            openCodeAssociation: ("fixture", "ses_fixture"), importedOpenCodeSnapshot: snapshot)
        #expect(repeated == id)
        #expect(try db.knownOpenCodeSessionIDs(connectionID: "fixture") == ["ses_fixture"])
        try db.saveOpenCodeSnapshot(snapshot, conversationID: id)
        let reopened = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        #expect(try reopened.openCodeSnapshot(conversationID: id)?.messages.count == 250)
        #expect(try reopened.conversationContent(id: id).messages.count == 250)
        let record = try #require(try reopened.workspaceOverview().conversations.first { $0.id == id })
        #expect(record.importedAt != nil)
        #expect(record.lastMessageAt == record.importedAt)
        await coordinator.shutdown()
    }

    @Test func openCodeDownloadUsesPinnedPackageAndVerifiesExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let npm = root.appending(path: "npm")
        let script = """
        #!/bin/sh
        test "$1" = install && test "$2" = --global && test "$3" = --prefix || exit 1
        test "$5" = '@opencode/cli@\(OpenCodeConnection.supportedVersion)' || exit 2
        mkdir -p "$4/bin"
        printf '#!/bin/sh\\necho "opencode2 v\(OpenCodeConnection.supportedVersion)"\\n' > "$4/bin/opencode2"
        chmod +x "$4/bin/opencode2"
        """
        try script.write(to: npm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: npm.path)
        let prefix = root.appending(path: "installed")
        let result = try await OpenCodeServiceLauncher.install(using: LocalACPRuntimeInstaller(installPrefix: prefix, npmExecutableURL: npm))
        #expect(result == prefix.appending(path: "bin/opencode2"))
        #expect(FileManager.default.isExecutableFile(atPath: result.path))
    }

    @Test func stopMissingServiceDoesNotStartAnything() async throws {
        let registration = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "/opencode/service.json")
        try await OpenCodeServiceLauncher.stop(registration: registration)
        #expect(!FileManager.default.fileExists(atPath: registration.path))
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

    @Test func nativeCommandsAcceptNoContentAndNeverRetryLostResponsesAsPrompts() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try database.createLocalACPSession(runtimeKind: .opencode, title: "Commands", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        try await coordinator.command(link, name: "review", input: .init(text: "current changes", historyDeliveryID: UUID().uuidString))
        #expect(fixture.commandCount == 1)
        #expect(fixture.lastCommand["command"].text == "review")
        #expect(fixture.lastCommand["text"].text == "current changes")
        #expect(fixture.lastCommand["id"].isNull)
        #expect(fixture.lastCommand["delivery"].text == "steer")
        #expect(try database.openCodeUncertainSubmissions(conversationID: id).isEmpty)
        fixture.loseCommandResponse = true
        await #expect(throws: OpenCodeError.self) { try await coordinator.command(link, name: "review", input: .init(text: "again")) }
        #expect(fixture.commandCount == 2)
        #expect(fixture.promptCount == 0)
        #expect(try database.openCodeUncertainSubmissions(conversationID: id).isEmpty)
        await coordinator.shutdown()
    }

    @Test func hiddenModelsLeaveSessionAndThinkingIntactButDisappearFromChoices() throws {
        let models: [OpenCodeValue] = [
            ["id": "chosen", "providerID": "one", "variants": .array([["id": "high"]])],
            ["id": "chosen", "providerID": "two"]
        ]
        let session: OpenCodeValue = ["id": "ses_test", "model": ["id": "chosen", "providerID": "one", "variant": "high"]]
        let metadata = OpenCodeComposerMetadata.metadata(session: session, models: models, hiddenModels: ["one/chosen"])
        #expect(metadata.model == "one/chosen")
        #expect(metadata.thinking == "high")
        #expect(metadata.selectableModels == ["two/chosen"])
        #expect(metadata.selectableThinkingLevels == ["default", "high"])
        #expect(OpenCodeComposerMetadata.metadata(session: session, models: models, hiddenModels: ["one/chosen", "two/chosen"]).selectableModels.isEmpty)
        #expect(try JSONDecoder().decode(LocalACPSessionMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
    }

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

    @Test func canonicalPartsKeepAssistantBoundariesAndNativeOrder() throws {
        let message: OpenCodeValue = ["id": "msg", "type": "assistant", "content": .array([
            ["type": "text", "text": "  commentary\n"],
            ["type": "reasoning", "text": "reason"],
            ["type": "tool", "id": "call", "name": "read", "state": ["status": "completed", "content": .array([["type": "text", "text": "ok"]])]],
            ["type": "text", "text": "final  "]
        ])]
        let activities = OpenCodeSessionSnapshot.activities(message, assistantMessageID: "stored-message")
        #expect(activities.map(\.kind) == [.assistant, .thought, .tool, .assistant])
        #expect(activities.map(\.position) == [0, 1, 2, 3])
        #expect(activities.first?.content == "  commentary\n\n\n")
        #expect(activities.last?.content == "final  ")
        #expect(activities.last?.assistantMessageID == "stored-message")
        #expect(activities.last?.assistantCheckpoint?.followingText(in: "  commentary\n\n\nfinal  ") == "")
    }

    @Test func durableEventsCoalesceAndRefreshAgainAfterAnInflightSnapshot() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try database.createLocalACPSession(runtimeKind: .opencode, title: "Events", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        let baseline = fixture.historyRequests
        fixture.messages = [message("first")]
        for seq in 1...5 { await coordinator.receiveLogEvent(["type": "session.text.delta", "durable": ["seq": .number(Double(seq))]], link: link) }
        try await fixture.waitForHistoryRequests(baseline + 1)
        try await Task.sleep(for: .milliseconds(125))
        #expect(fixture.historyRequests == baseline + 1)

        fixture.heldPath = "/api/session/ses_fixture/form/form_pending/state"
        fixture.messages = [message("during-first")]
        await coordinator.receiveLogEvent(["type": "session.text.delta", "durable": ["seq": .number(6)]], link: link)
        await fixture.gate.waitForArrival()
        fixture.messages = [message("during-second")]
        await coordinator.receiveLogEvent(["type": "session.execution.failed", "durable": ["seq": .number(7)]], link: link)
        fixture.heldPath = nil
        fixture.gate.release()
        try await fixture.waitForHistoryRequests(baseline + 3)
        for _ in 0..<400 {
            if try database.openCodeSnapshot(conversationID: id)?.cursor == 7 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let saved = try #require(try database.openCodeSnapshot(conversationID: id))
        #expect(saved.messages.last?["id"].text == "during-second")
        #expect(saved.cursor == 7)
        await coordinator.shutdown()
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

    @Test func unifiedDiscoveryPreservesVisibleInputAndDurableAgentAttribution() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let source = try database.createLocalACPSession(runtimeKind: .codex, title: "Coordinator", ownerDeviceID: UUID())
        let target = try database.createLocalACPSession(runtimeKind: .opencode, title: "Work", ownerDeviceID: UUID())
        let link = OpenCodeSessionLink(conversationID: target, connectionID: "fixture", sessionID: "ses_fixture")
        try database.attachOpenCodeSession(link)
        let deliveryID = UUID().uuidString.lowercased()
        _ = try database.reserveToolDelivery(sourceID: source, targetID: target, text: "Build this", requestID: deliveryID)
        _ = try database.claimToolDelivery(id: deliveryID)
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        try await coordinator.prompt(link, input: .init(text: "Build this", historyDeliveryID: deliveryID), discovery: "<wovenmatter-tools>session discovery</wovenmatter-tools>")
        let raw = try #require(try database.openCodeSnapshot(conversationID: target))
        #expect(fixture.lastPrompt["delivery"].text == "steer")
        #expect(raw.messages.last?["text"].text.contains("session discovery") == true)
        let display = try database.openCodeDisplaySnapshot(raw, conversationID: target)
        #expect(display.messages.last?["text"].text == "Build this")
        let content = try database.conversationContent(id: target)
        let input = try #require(content.messages.first(where: { $0.role == "user" }))
        #expect(input.content == "Build this")
        #expect(input.senderSessionID == source)
        #expect(input.senderKind == .message)
        #expect(input.senderSessionTitle == "Coordinator")
        #expect(try database.toolDelivery(id: deliveryID)?.messageID == input.id)
        let reopened = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        #expect(try reopened.openCodeDisplaySnapshot(raw, conversationID: target).messages.last?["text"].text == "Build this")
        await coordinator.disconnect(connectionID: "fixture")
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
        #expect(try reopened.conversationHistoryPage(id: id, limit: 100).activities.count == 3)
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

    @Test func disconnectedRefreshCannotPublishAnUnwatchedSnapshot() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try database.createLocalACPSession(runtimeKind: .opencode, title: "Original", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        fixture.heldPath = "/api/session/ses_fixture"
        let refresh = Task { try await coordinator.refresh(link) }
        await fixture.gate.waitForArrival()
        await coordinator.disconnect(connectionID: "fixture")
        // Even reconnecting under the same identity must retire the old request.
        try await coordinator.connect(connection())
        fixture.gate.release()
        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(try database.openCodeSnapshot(conversationID: id) == OpenCodeSessionSnapshot())
        #expect(try database.localACPSession(conversationID: id).title == "Original")
        await coordinator.shutdown()
    }

    @Test func loadingHistoryDuringRefreshPreservesBothPages() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.messages = (0..<250).map { message("msg_history_\($0)") }
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
        fixture.heldPath = "/api/session/ses_fixture/form/form_pending/state"
        let refresh = Task { try await coordinator.refresh(link) }
        await fixture.gate.waitForArrival()
        let older = Task { try await coordinator.loadOlder(link) }
        // Let the concurrent history request reach the refresh lock. Previously
        // it completed here and its page was overwritten when refresh resumed.
        try await Task.sleep(for: .milliseconds(100))
        fixture.gate.release()
        try await refresh.value
        try await older.value
        #expect(try database.openCodeSnapshot(conversationID: id)?.messages.map { $0["id"].text } == Array(fixture.messages.suffix(200)).map { $0["id"].text })
        await coordinator.shutdown()
    }

    @Test func creationModelSelectionRequiresServerConfirmation() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        let link = OpenCodeSessionLink(conversationID: "fixture", connectionID: "fixture", sessionID: "ses_fixture")
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

    @Test func interruptedSessionCreationReusesThePendingIdentity() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.sessionExists = false
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        // A previous create did not reach the server. Recovery sees 404 and
        // safely submits that same identity instead of blocking all new chats.
        let created = try await coordinator.createSession(connectionID: "fixture", id: "ses_fixture", workspace: directory, recover: true, title: "Requested title")
        #expect(created["data"]["id"].text == "ses_fixture")
        #expect(fixture.createCount == 1)
        #expect(fixture.lastCreate["location"]["directory"].text == directory.path)
        #expect(fixture.lastCreate["title"].text == "Requested title")
        // If only the response was lost, recovery retrieves the existing session.
        let recovered = try await coordinator.createSession(connectionID: "fixture", id: "ses_fixture", workspace: directory, recover: true)
        #expect(recovered["data"]["id"].text == "ses_fixture")
        #expect(fixture.createCount == 1)
        await coordinator.shutdown()
    }

    @Test func formConditionsUseSelectionsNumbersAndCascadeHiddenAnswers() {
        let fields: [OpenCodeValue] = [
            ["key": "choices", "type": "multiselect"],
            ["key": "details", "type": "string", "when": .array([["key": "choices", "op": "eq", "value": "custom"]])],
            ["key": "followup", "type": "string", "when": .array([["key": "details", "op": "neq", "value": "skip"]])],
            ["key": "number", "type": "integer"],
            ["key": "numeric", "type": "string", "when": .array([["key": "number", "op": "eq", "value": .number(2)]])]
        ]
        let shown = OpenCodeFormAnswers.activeFields(fields, answers: ["choices": .array(["custom"]), "details": "yes", "number": "2"])
        #expect(shown.map { $0["key"].text } == ["choices", "details", "followup", "number", "numeric"])
        let hidden = OpenCodeFormAnswers.activeFields(fields, answers: ["choices": .array([]), "details": "stale"])
        #expect(hidden.map { $0["key"].text } == ["choices", "number"])
        let unanswered = OpenCodeFormAnswers.activeFields(fields, answers: [:])
        #expect(unanswered.map { $0["key"].text } == ["choices", "number"])
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

    @Test func completeServerHistoryDoesNotResurrectRemovedCachedPrefix() async throws {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        fixture.messages = [message("msg_removed"), message("msg_kept"), message("msg_last")]
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try database.createLocalACPSession(runtimeKind: .opencode, title: "History", ownerDeviceID: UUID(), openCodeAssociation: ("fixture", "ses_fixture"))
        let link = OpenCodeSessionLink(conversationID: id, connectionID: "fixture", sessionID: "ses_fixture")
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(connection())
        try await coordinator.refresh(link)
        fixture.messages.removeFirst()
        try await coordinator.refresh(link, recoverHistory: true)
        let recovered = try #require(try database.openCodeSnapshot(conversationID: id))
        #expect(recovered.messages == fixture.messages)
        #expect(recovered.olderCursor == nil)
        // The saved transcript is retained, but the canonical visible projection
        // no longer includes content removed by another client.
        #expect(try database.conversationContent(id: id).messages.count == 3)
        await coordinator.shutdown()
    }

    @Test func stagedRemoteFilePromptUsesWorkspaceFileURI() async throws {
        let remote = try await remoteFixture(title: "Staged")
        defer { remote.cleanup() }
        let remotePath = "/home/.woven-matter/.wovenmatter/attachments/h/notes.txt"
        try await remote.coordinator.prompt(remote.link,
            input: .init(text: "Read notes", attachments: [.file(remote.draft(remotePath: remotePath))]))
        #expect(remote.fixture.promptCount == 1)
        let files = remote.fixture.lastPrompt["files"].array
        #expect(files.count == 1)
        #expect(files.first?["uri"].text == "file://" + remotePath)
        #expect(files.first?["name"].text == "notes.txt")
        await remote.coordinator.shutdown()
    }

    @Test func unstagedRemoteFilePromptThrowsBeforeSubmit() async throws {
        let remote = try await remoteFixture(title: "Unstaged")
        defer { remote.cleanup() }
        await #expect(throws: OpenCodeError.self) {
            try await remote.coordinator.prompt(remote.link,
                input: .init(text: "Read notes", attachments: [.file(remote.draft(remotePath: nil))]))
        }
        #expect(remote.fixture.promptCount == 0)
        #expect(remote.fixture.lastPrompt.isNull)
        await remote.coordinator.shutdown()
    }

    /// A connected coordinator whose link belongs to a remote workspace.
    private struct RemoteFixture {
        let fixture: OpenCodeFixture
        let coordinator: OpenCodeSessionCoordinator
        let link: OpenCodeSessionLink
        let directory: URL
        func draft(remotePath: String?) -> AgentFileAttachmentDraft {
            AgentFileAttachmentDraft(kind: .file, fileName: "notes.txt", mimeType: "text/plain",
                sizeBytes: 5, contentHash: "h", localURL: directory.appending(path: "notes.txt"), remotePath: remotePath)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func remoteFixture(title: String) async throws -> RemoteFixture {
        let fixture = OpenCodeFixture(); FixtureProtocol.fixture = fixture
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: directory.appending(path: "notes.txt"))
        let workspaceID = UUID()
        let identity = "remote-workspace:" + workspaceID.uuidString.lowercased()
        let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let id = try database.createRemoteACPSession(runtimeKind: .opencode, remoteWorkspaceID: workspaceID,
            remoteWorkspaceName: "Remote", title: title, ownerDeviceID: UUID(),
            openCodeAssociation: (identity, "ses_fixture"))
        let session = fixtureSession()
        let coordinator = OpenCodeSessionCoordinator(database: database, clientFactory: { OpenCodeHTTPClient(connection: $0, session: session) })
        try await coordinator.connect(try remoteConnection(identity: identity))
        return RemoteFixture(fixture: fixture, coordinator: coordinator,
            link: OpenCodeSessionLink(conversationID: id, connectionID: identity, sessionID: "ses_fixture"), directory: directory)
    }

    private func connection() throws -> OpenCodeConnection { try .init(identity: "fixture", url: URL(string: "http://fixture.invalid")!, password: "fixture") }
    private func remoteConnection(identity: String) throws -> OpenCodeConnection {
        try .init(identity: identity, url: URL(string: "http://127.0.0.1")!, password: "",
            servicePathPrefix: "/v1/workspace-instances/opencode", bearerToken: "fixture-token")
    }
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
    var createCount = 0
    var lastCreate: OpenCodeValue = .null
    var selectedModel: OpenCodeValue = .null
    var acceptModelSelection = true
    var modelWriteCount = 0
    var version = OpenCodeConnection.supportedVersion
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
    var historyRequests = 0
    var streamTimeout: TimeInterval?
    func waitForHistoryRequests(_ count: Int) async throws {
        for _ in 0..<400 {
            if lock.withLock({ historyRequests >= count }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw OpenCodeError.message("Fixture did not receive expected history refreshes.")
    }
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
            if path == "/api/health" { return (200, ["healthy": .bool(true), "version": .string(version), "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))]) }
            if path == "/api/session/active" { return (200, ["data": [:]]) }
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
            if path.hasSuffix("/state") { return (200, ["data": ["status": path.contains("form_pending") ? "pending" : "answered"]]) }
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
            if path == "/api/session/ses_fixture" { return (200, ["data": ["id": "ses_fixture", "title": "Shared fixture", "model": selectedModel, "location": ["directory": "/original/project"], "time": ["updated": .number(900)]]]) }
            return (404, [:])
        }
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fixture = OpenCodeFixture()
    override class func canInit(with request: URLRequest) -> Bool { ["fixture.invalid", "127.0.0.1"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if (request.url?.path == "/api/health" && Self.fixture.holdHealth) || request.url?.path == Self.fixture.heldPath {
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

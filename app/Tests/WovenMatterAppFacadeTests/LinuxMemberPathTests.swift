import CryptoKit
import Foundation
import LibraryClient
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

/// The Mac reaches a Linux host it added only through the host's server
/// (docs/architecture/WOVEN_EVERYWHERE.md, "Linux sessions"). These drive the
/// app's callers against a fake of that server's signed routes.
@MainActor @Suite(.serialized)
struct LinuxMemberPathTests {
    private func enrolled(_ fixture: FacadeFixture) async throws -> (ExecutionWorkspace, LinuxMemberFake) {
        try await fixture.enrollLinuxHost()
    }

    private func target(_ fixture: FacadeFixture, _ runtime: AgentRuntimeKind = .codex) throws -> RemoteHarnessChatTarget {
        try fixture.linuxTarget(runtime)
    }

    @Test func newChatIsCreatedByTheHostWithItsChoicesAndFolder() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (workspace, fake) = try await enrolled(fixture)
        let scope = ApplicationModel.remoteDatabaseSourceID(fixture.remote.id)
        fixture.model.sessionSelectionPreferences.saveDefaults(.init(model: "large", thinking: "high", permission: "read-only",
            tools: ["notes", "executor:fixture", "sessions"]), harness: "codex", workspace: scope)
        let root = "/srv/linked-project"
        let folder = try await fixture.store.createFolder(name: "Linked", location: .init(workspaceID: scope, rootPath: root, managed: false))

        let id = try #require(await fixture.model.createRemoteACPSession(target: try target(fixture), folderID: folder), "\(fixture.model.localRunError ?? "")")
        let create = try #require(await fake.commands.first { $0.kind == .createSession })
        #expect(create.conversationID == id && create.commandID == id)
        #expect(create.providerID == "codex" && create.runtimeKind == "codex" && create.folderID == folder)
        #expect(create.title == "New Codex chat")
        #expect(create.sessionOptions == LibrarySessionOptions(workingDirectory: root, model: "large", thinking: "high",
            permission: "read-only", enabledTools: ["notes", "sessions"]))
        // The library keeps the chat in its folder, owned and run by the host.
        #expect(try await fixture.database.libraryExecutionOwner(conversationID: id) == workspace.id)
        #expect(try await fixture.database.localACPSession(conversationID: id).remoteWorkspaceID == fixture.remote.id)
        #expect(try await fixture.database.sessionExecutionRoot(id: id)?.rootPath == root)
        let record = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == id })
        #expect(record.folderID == folder)
        #expect(fixture.model.federatedExecutionOwners[id] == workspace.id)

        // A chat in All Workspaces gets its own scratch folder on the host.
        let folderless = try #require(await fixture.model.createRemoteACPSession(target: try target(fixture)))
        let second = try #require(await fake.commands.last { $0.kind == .createSession })
        #expect(second.conversationID == folderless && second.folderID == nil && second.sessionOptions?.workingDirectory == nil)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }

    @Test func aScheduledTasksStagedChoicesAreTheNewSessionsOptions() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (workspace, fake) = try await enrolled(fixture)
        let id = UUID()
        let scope = ApplicationModel.remoteDatabaseSourceID(fixture.remote.id)
        fixture.model.sessionSelectionPreferences.stageCalendarSelections(id: id.uuidString.lowercased(), harness: "codex", workspace: scope,
            selections: .init(model: "small", thinking: "low", permission: "agent"))
        _ = try #require(await fixture.model.createRemoteACPSession(target: try target(fixture), requestedConversationID: id))
        let create = try #require(await fake.commands.first { $0.kind == .createSession })
        #expect(create.sessionOptions?.model == "small" && create.sessionOptions?.thinking == "low" && create.sessionOptions?.permission == "agent")
        #expect(fixture.model.sessionSelectionPreferences.conversation(id: id.uuidString.lowercased())?.requiresApplication == false)
        // A later change goes to the host's server as a configuration action.
        fixture.model.sessionSelectionPreferences.stageCalendarSelections(id: id.uuidString.lowercased(), harness: "codex", workspace: scope,
            selections: .init(model: "large"))
        try await fixture.model.applyStagedSessionSelections(conversationID: id.uuidString.lowercased())
        let configure = try #require(await fake.commands.last { $0.kind == .workspace })
        #expect(configure.workspaceAction == .configureSession(id: id.uuidString.lowercased(), model: "large", thinking: nil, permission: nil))
        #expect(configure.workspaceID == workspace.id)
        #expect(await fixture.recorder.configurations.isEmpty)
    }

    /// A Mac agent's `woven_sessions_create` on a Linux host this Mac added
    /// goes to the host's server, as for any other member.
    @Test func agentsReachAnEnrolledHostAsAMember() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = fixture.remote.id.uuidString.lowercased()
        #expect(try await fixture.model.resolveAgentToolDestination(id, callerWorkspace: nil) == .configured(fixture.remote.id))
        let (workspace, _) = try await enrolled(fixture)
        #expect(try await fixture.model.resolveAgentToolDestination(id, callerWorkspace: nil) == .member(workspace))
    }

    @Test func aChatOnAnUnenrolledHostIsNotCreatedOrLaunched() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        #expect(await fixture.model.createRemoteACPSession(target: try target(fixture)) == nil)
        #expect(fixture.model.localRunError?.contains("not in this library's workspaces") == true)
        #expect(try await fixture.database.workspaceOverview().conversations.isEmpty)
    }

    @Test func filesAreUploadedThenNamedWithTheContextAndNote() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (_, fake) = try await enrolled(fixture)
        let id = try #require(await fixture.model.createRemoteACPSession(target: try target(fixture)))
        let bytes = Data("fixture image bytes".utf8)
        let file = fixture.directory.appending(path: "diagram.png")
        try bytes.write(to: file)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let input = AgentMessageInput(text: "Look at this", attachments: [
            .file(.init(kind: .image, fileName: "diagram.png", mimeType: "image/png", sizeBytes: Int64(bytes.count), contentHash: digest, localURL: file)),
            .reference(.init(kind: .note, resourceID: "note-1", titleSnapshot: "Plan", contentSnapshot: "Ship it", revisionSnapshot: "3"))])
        let record = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == id })
        #expect(try await fixture.model.dispatchAgentMessage(conversation: record, input: input))

        let upload = try #require(await fake.uploads.first)
        #expect(upload.sha256 == digest && upload.name == "diagram.png" && upload.mimeType == "image/png" && upload.data == bytes)
        let send = try #require(await fake.commands.first { $0.kind == .send })
        #expect(send.conversationID == id && send.text == "Look at this")
        #expect(send.attachments == [LibraryAttachmentReference(id: digest, name: "diagram.png", mimeType: "image/png", byteCount: Int64(bytes.count))])
        #expect(send.promptContext?.contains(#"<wovenmatter-reference type="note" id="note-1""#) == true)
        #expect(send.promptContext?.contains("Ship it") == true)
        // Nothing was staged or launched over SSH.
        #expect(await fixture.recorder.deliveries.isEmpty)

        // Other members keep taking references inline.
        let text = ApplicationModel.federatedMessage(input, note: nil, linux: false)
        #expect(text.promptContext == nil && text.text == "Look at this\n\nReferenced content: Plan\nShip it")
    }

    @Test func tooManyFilesAreRefusedBeforeUpload() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "missing")
        let drafts = (0..<9).map { _ in AgentFileAttachmentDraft(kind: .file, fileName: "a", mimeType: "text/plain", sizeBytes: 1,
            contentHash: String(repeating: "a", count: 64), localURL: file) }
        #expect(throws: LibraryAPIError.self) { try MemberAttachmentLimits.check(drafts) }
        #expect(throws: LibraryAPIError.self) { try MemberAttachmentLimits.check([AgentFileAttachmentDraft(kind: .file, fileName: "big",
            mimeType: "text/plain", sizeBytes: 26 * 1_024 * 1_024, contentHash: String(repeating: "a", count: 64), localURL: file)]) }
    }

    /// Pi Durable settings on a host run its helper there; its session reads
    /// back as the lines the helper printed over SSH before.
    @Test func piSettingsSessionsReadAsTheHelpersLines() throws {
        let running = try JSONDecoder().decode(DefaultAgentControlSession.self, from: Data("""
            {"id":"00000000-0000-4000-8000-000000000001","action":"login","state":"running",
             "notifications":[{"url":"https://example.test/device","userCode":"ABCD-1234"}],"prompt":{"id":"q1","message":"Continue?","options":[{"id":"yes","label":"Yes"}]}}
            """.utf8))
        let lines = try running.lines(after: 0).map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect((lines[0]?["notification"] as? [String: Any])?["userCode"] as? String == "ABCD-1234")
        #expect(lines[1]?["id"] as? String == "q1" && (lines[1]?["prompt"] as? [String: Any])?["message"] as? String == "Continue?")
        #expect(running.promptID == "q1" && running.lines(after: 1).count == 1)
        let done = try JSONDecoder().decode(DefaultAgentControlSession.self, from: Data(#"{"id":"x","state":"succeeded","notifications":[],"result":{"connected":true}}"#.utf8))
        #expect(try JSONSerialization.jsonObject(with: done.lines(after: 0)[0]) as? [String: [String: Bool]] == ["result": ["connected": true]])
        let failed = try JSONDecoder().decode(DefaultAgentControlSession.self, from: Data(#"{"id":"x","state":"failed","notifications":[],"error":"Choose an enabled provider."}"#.utf8))
        #expect(try JSONSerialization.jsonObject(with: failed.lines(after: 0)[0]) as? [String: String] == ["error": "Choose an enabled provider."])
    }

    @Test func aLockedPiIsUnlockedWithThisMacsKeyAndRetried() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (workspace, fake) = try await enrolled(fixture)
        await fake.lockPi()
        let client = try #require(fixture.model.federatedExecutionClient)
        let id = UUID().uuidString.lowercased()
        _ = try await client.createSession(workspace: workspace, runtimeKind: .defaultAgent, conversationID: id, folderID: nil)
        #expect(await fake.unlocks.map(\.unlockKey) == ["fixture-key"])
        #expect(await fake.unlocks.map(\.workspace) == [workspace.id])
        #expect(await fake.commands.filter { $0.kind == .createSession }.map(\.providerID) == ["default_agent"])

        // A send refused as locked is unlocked and sent again as a new command.
        await fake.refuseNextSendAsLocked()
        let receipt = try await client.send(to: workspace, conversationID: id, text: "Hello")
        #expect(receipt.status == .accepted)
        let sends = await fake.commands.filter { $0.kind == .send }
        #expect(sends.count == 2 && sends[0].commandID != sends[1].commandID && sends.allSatisfy { $0.text == "Hello" })
        #expect(await fake.unlocks.count == 2)

        // A refused key, or none, configures the host as the SSH relay did.
        await fake.refuseKeys()
        await fake.lockPi()
        _ = try await client.createSession(workspace: workspace, runtimeKind: .defaultAgent, conversationID: UUID().uuidString.lowercased(), folderID: nil)
        let configured = try #require(await fake.configurations.last)
        #expect(try JSONDecoder().decode(DefaultAgentPayload.self, from: configured).workspace == workspace.id)
    }

    @Test func optionsWithoutASessionCarryTheirDescriptions() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (_, fake) = try await enrolled(fixture)
        let metadata = try await fixture.model.linuxSessionOptions(workspaceID: fixture.remote.id, runtime: .codex, directory: "/srv/project", model: "large")
        #expect(await fake.optionRequests.first?.providerID == "codex")
        #expect(await fake.optionRequests.first?.workingDirectory == "/srv/project")
        #expect(await fake.optionRequests.first?.model == "large")
        #expect(metadata.model == "large" && metadata.permissionOptions == ["agent-full-access", "agent"])
        #expect(metadata.permissionOptionMetadata?["agent"]?.description == "Only ask for actions detected as potentially unsafe.")
        #expect(metadata.permissionOptionMetadata?["agent"]?.name == "Approve for me")
        #expect(metadata.workingDirectory == "/srv/project")

        // A scheduled task's scratch folder that is not on the host yet still lists choices.
        await fake.refuseDirectories()
        let fallback = try await fixture.model.linuxSessionOptions(workspaceID: fixture.remote.id, runtime: .codex, directory: "/srv/missing", model: nil)
        #expect(await fake.optionRequests.last?.workingDirectory == nil)
        #expect(fallback.selectableModels == ["small", "large"])
    }

    @Test func libraryFilesAreReadThroughTheHostAndChecked() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (workspace, fake) = try await enrolled(fixture)
        let bytes = Data("report body".utf8)
        await fake.serve(file: bytes)
        let id = UUID().uuidString.lowercased()
        #expect(try await fixture.model.readLinuxLibraryFile(workspaceID: workspace.id, conversationID: id, path: "/srv/out/report.txt") == bytes)
        let request = await fake.fileRequests.first
        #expect(request?.conversationID == id && request?.path == "/srv/out/report.txt")
        // History that never moved to the host reads under the root this library recorded.
        await fake.forgetConversations()
        #expect(try await fixture.model.readLinuxLibraryFile(workspaceID: workspace.id, conversationID: id, path: "./report.txt",
            underRoot: "/srv/out/./report.txt") == bytes)
        let fallback = await fake.fileRequests.last
        #expect(fallback?.conversationID == nil && fallback?.path == "/srv/out/./report.txt")
        await fake.damageFiles()
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await fixture.model.readLinuxLibraryFile(workspaceID: workspace.id, conversationID: id, path: "/srv/out/report.txt")
        }
    }

    @Test func aChatThatRanOverSSHMovesToTheHostWithItsTranscript() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (workspace, fake) = try await enrolled(fixture)
        let id = try await fixture.createConversation()
        let run = try await fixture.database.beginLocalACPRun(conversationID: id, input: .init(text: "Earlier question"))
        try await fixture.database.write { connection in try connection.transaction {
            try connection.toolsExecuteUnlocked("UPDATE harness_sessions SET native_session_id='native-session' WHERE conversation_id=?", [id])
            try connection.toolsExecuteUnlocked("UPDATE messages SET content='Earlier answer' WHERE id=?", [run.assistantMessageID])
        } }
        let record = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == id })
        // Its run was left running when the app that ran it over SSH quit.
        #expect(try await fixture.database.activeRunID(conversationID: id) == run.runID)

        try await fixture.model.adoptRegisteredRemoteConversationIfNeeded(record)
        let body = try #require(await fake.adoptions.first)
        let adoption = try JSONDecoder().decode(ExecutionAdoption.self, from: body)
        #expect(adoption.nativeSessionID == "native-session" && adoption.workspaceID == workspace.id && adoption.conversation.id == id)
        #expect(adoption.transcript?.messages.map(\.content) == ["Earlier question", "Earlier answer"])
        #expect(adoption.knownRunIDs == [run.runID])
        #expect(try await fixture.database.libraryExecutionOwner(conversationID: id) == workspace.id)
        #expect(try await fixture.database.activeRunID(conversationID: id) == nil)
        // The saved adoption, retried after a lost reply, is the same request without the copied history.
        let saved = try await fixture.database.read { try $0.federationValuesUnlocked("SELECT payload FROM execution_adoptions WHERE conversation_id=?", bindings: [id], as: ExecutionAdoption.self) }
        #expect(saved.first?.transcript == nil)
        // The chat's history stays in the library.
        #expect(try await fixture.database.workspaceOverview().conversations.contains { $0.id == id })
        #expect(await fixture.recorder.deliveries.isEmpty)
    }

    @Test func aChatThatCannotMoveStaysAsReadOnlyHistory() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (_, fake) = try await enrolled(fixture)
        // It never started a session on the host, so there is nothing to adopt.
        let id = try await fixture.createConversation()
        let record = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == id })
        await #expect(throws: LegacyRemoteChatError.self) { try await fixture.model.adoptRegisteredRemoteConversationIfNeeded(record) }
        do {
            _ = try await fixture.model.dispatchAgentMessage(conversation: record, input: .init(text: "Continue"))
            Issue.record("A chat that could not move was sent to")
        } catch let error as LegacyRemoteChatError {
            #expect(error.localizedDescription.contains("read-only"))
            #expect(error.localizedDescription.contains(fixture.remote.name))
        }
        #expect(await fake.adoptions.isEmpty)
        #expect(await fake.commands.isEmpty)
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(try await fixture.database.libraryExecutionOwner(conversationID: id) == nil)
        #expect(try await fixture.database.workspaceOverview().conversations.contains { $0.id == id })

        // A host that refuses the adoption leaves the chat readable, with the reason.
        let adoptable = try await fixture.createConversation()
        try await fixture.database.write { connection in try connection.transaction {
            try connection.toolsExecuteUnlocked("UPDATE harness_sessions SET native_session_id='gone' WHERE conversation_id=?", [adoptable])
        } }
        await fake.refuseAdoptions()
        let second = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == adoptable })
        await #expect(throws: LegacyRemoteChatError.self) { try await fixture.model.adoptRegisteredRemoteConversationIfNeeded(second) }
        await fixture.model.refreshLocalACPSession(conversation: second)
        // The conversation view shows it as read-only history with the reason, without a composer.
        #expect(fixture.model.legacyRemoteChatReasons[adoptable]?.contains("could not move") == true)
        #expect(fixture.model.ensureConversationState(id: adoptable).error == nil)
        await fixture.model.refreshLocalACPSession(conversation: record)
        #expect(fixture.model.legacyRemoteChatReasons[id]?.contains("read-only") == true)
        #expect(try await fixture.database.workspaceOverview().conversations.contains { $0.id == adoptable })
    }

    /// The host deciding a chat cannot move is read-only history; anything
    /// that may pass by itself is tried again.
    @Test func onlyTheHostsRefusalMakesAMoveReadOnly() {
        func deferred(_ error: any Error) -> RemoteChatMoveDeferredError? {
            RemoteChatMoveDeferredError.classify(error, workspace: "Build server") as? RemoteChatMoveDeferredError
        }
        func permanent(_ error: any Error) -> Bool {
            RemoteChatMoveDeferredError.classify(error, workspace: "Build server") is LegacyRemoteChatError
        }
        // Not reachable, too slow, a server error, not yet a member there: tried again.
        for error: any Error in [URLError(.cannotConnectToHost), URLError(.timedOut), MobileConnectionError.invalidResponse,
                                  LibraryAPIError(code: "http_503", message: "Service unavailable"),
                                  LibraryAPIError(code: "internal_error", message: "internal_error"),
                                  LibraryAPIError(code: "unauthorized", message: "Build server does not recognize this Mac yet."),
                                  LibraryAPIError(code: "workspace_unavailable", message: "Build server is not connected.")] {
            let value = deferred(error)
            #expect(value != nil && value?.busy == false, "\(error)")
        }
        // The host's session was still working.
        for error in [LibraryAPIError(code: "http_409", message: "This session is not idle; client ownership was not changed"),
                      LibraryAPIError(code: "execution_busy", message: "Wait for the current run to settle.")] {
            #expect(deferred(error)?.busy == true, "\(error)")
        }
        // The host or the library refused it: read-only history.
        for error in [LibraryAPIError(code: "http_409", message: "This native session was interrupted. It cannot move until it is reopened where it last ran."),
                      LibraryAPIError(code: "adoption_unavailable", message: "This conversation has no known native session."),
                      LibraryAPIError(code: "wrong_owner", message: "This conversation was transferred to another execution workspace.")] {
            #expect(permanent(error), "\(error)")
        }
        let offline = RemoteChatMoveDeferredError(workspace: "Build server", reason: "The request timed out.")
        #expect(offline.localizedDescription == "This chat is moving to Build server's server, but Build server could not be reached: "
            + "The request timed out. Woven Matter tries again when you reopen this chat or send a message.")
        let busy = RemoteChatMoveDeferredError(workspace: "Build server", reason: "not idle", busy: true)
        #expect(busy.localizedDescription.hasPrefix("This chat moves to Build server's server once its current work there finishes."))
        #expect(!offline.localizedDescription.contains("read-only") && !busy.localizedDescription.contains("read-only"))
    }

    @Test func aMoveThatCouldNotReachTheHostIsNotReadOnlyAndIsTriedAgain() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (workspace, fake) = try await enrolled(fixture)
        let id = try await fixture.createConversation()
        _ = try await fixture.database.beginLocalACPRun(conversationID: id, input: .init(text: "Earlier question"))
        try await fixture.database.write { connection in try connection.transaction {
            try connection.toolsExecuteUnlocked("UPDATE harness_sessions SET native_session_id='native-session' WHERE conversation_id=?", [id])
        } }
        let record = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == id })

        // The host is offline when the chat opens: it keeps its composer and says it tries again.
        await fake.failAdoptions(URLError(.timedOut))
        await #expect(throws: RemoteChatMoveDeferredError.self) { try await fixture.model.adoptRegisteredRemoteConversationIfNeeded(record) }
        await fixture.model.refreshLocalACPSession(conversation: record)
        #expect(fixture.model.legacyRemoteChatReasons[id] == nil, "a host that could not be reached does not make the chat read-only")
        let shown = try #require(fixture.model.federatedExecutionSnapshots[id])
        #expect(!shown.online && shown.error?.contains("tries again") == true)
        #expect(await fake.adoptions.isEmpty)

        // The host is busy with the session: the same.
        await fake.failAdoptions(LibraryAPIError(code: "http_409", message: "This session is not idle; client ownership was not changed"))
        await fixture.model.refreshLocalACPSession(conversation: record)
        #expect(fixture.model.legacyRemoteChatReasons[id] == nil)
        #expect(fixture.model.remoteChatMoveRetries[id]?.contains("once its current work there finishes") == true)

        // Reopened once the host answers: the same adoption moves it.
        await fake.failAdoptions(nil)
        await fixture.model.refreshLocalACPSession(conversation: record)
        #expect(await fake.adoptions.count == 1)
        #expect(fixture.model.remoteChatMoveRetries[id] == nil && fixture.model.legacyRemoteChatReasons[id] == nil)
        #expect(try await fixture.database.libraryExecutionOwner(conversationID: id) == workspace.id)
    }
}

extension FacadeFixture {
    /// Enrolls the fixture's Linux host in the library and routes this Mac's
    /// signed execution calls to an in-memory fake of its server.
    func enrollLinuxHost() async throws -> (ExecutionWorkspace, LinuxMemberFake) {
        let identity = try await database.libraryIdentity()
        let workspace = try await database.registerExecutionWorkspace(.init(workspace: .init(
            id: remote.id.uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            kind: .linux, name: remote.name, endpoint: URL(string: "https://fixture.ts.net/wovenmatter"),
            executionDeviceID: UUID().uuidString.lowercased())), deviceID: identity.hostDeviceID)
        let fake = LinuxMemberFake(workspace: workspace)
        let client = try MemberExecutionClient(database: database,
            commandJournalURL: directory.appending(path: "member-commands-\(UUID()).json"),
            makeSignedTransport: { _ in fake })
        client.unlockDefaultAgentHandler = { workspace, routes in
            try await DefaultAgentHostUnlock.unlock(scope: workspace.id, routes: routes, existingKey: { _ in "fixture-key" },
                prepare: { scope in DefaultAgentPayload(config: .init(), credentials: [:], workspace: scope) })
        }
        model.federatedExecutionClient = client
        return (workspace, fake)
    }

    func linuxTarget(_ runtime: AgentRuntimeKind = .codex) throws -> RemoteHarnessChatTarget {
        .init(configuration: remote, harness: try #require(model.remoteWorkspaces.harnesses[remote.id]?.first { $0.id == runtime }))
    }
}

/// The Linux server's signed routes, in memory.
actor LinuxMemberFake: ExecutionWorkspaceTransport, MemberExecutionRoutes {
    struct Upload: Sendable { var data: Data; var sha256: String; var name: String; var mimeType: String }
    struct OptionRequest: Sendable { var providerID: String; var workingDirectory: String?; var model: String? }
    struct FileRequest: Sendable { var conversationID: String?; var path: String }
    struct Unlock: Sendable { var workspace: String; var unlockKey: String }
    let workspace: ExecutionWorkspace
    private(set) var commands: [LibraryCommand] = []
    private(set) var uploads: [Upload] = []
    private(set) var optionRequests: [OptionRequest] = []
    private(set) var fileRequests: [FileRequest] = []
    private(set) var adoptions: [Data] = []
    private(set) var unlocks: [Unlock] = []
    private(set) var configurations: [Data] = []
    private var receipts: [String: LibraryCommandReceipt] = [:]
    private var piLocked = false, keysRefused = false, lockedSend = false, directoriesRefused = false
    private var file = Data(), knowsConversations = true, damaged = false, adoptionsRefused = false
    /// Adoptions fail with this until cleared, as an unreachable or busy host does.
    private var adoptionFailure: (any Error)?

    init(workspace: ExecutionWorkspace) { self.workspace = workspace }
    func lockPi() { piLocked = true }
    func refuseKeys() { keysRefused = true }
    func refuseNextSendAsLocked() { lockedSend = true }
    func refuseDirectories() { directoriesRefused = true }
    func serve(file: Data) { self.file = file }
    func forgetConversations() { knowsConversations = false }
    func damageFiles() { damaged = true }
    func refuseAdoptions() { adoptionsRefused = true }
    func failAdoptions(_ error: (any Error)?) { adoptionFailure = error }

    func identity() -> ExecutionWorkspace { workspace }
    func providers() -> [HarnessCapabilities] {
        [.init(id: "codex", runtimeKind: "codex", displayName: "Codex", routeName: "This workspace", available: true, canSteer: true),
         .init(id: "default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", routeName: "This workspace",
               available: !piLocked, canStart: !piLocked, canSteer: true, locked: piLocked ? true : nil)]
    }
    func pending() -> [PendingInteraction] { [] }
    func receipt(_ id: String) -> LibraryCommandReceipt? { receipts[id] }
    func events(after: Int64) -> ExecutionJournalPage { .init(libraryID: workspace.libraryID, cursor: after, entries: []) }
    func conversations() -> [LibraryConversation] { [] }
    func transcript(_ id: String) -> LibraryTranscript { .init(conversationID: id) }
    func capabilities(_ id: String) -> HarnessCapabilities { providers()[0] }
    func command(_ command: LibraryCommand) -> LibraryCommandReceipt {
        if let saved = receipts[command.commandID] { return saved }
        commands.append(command)
        var receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID,
            status: command.kind == .send ? .accepted : .completed, conversationID: command.conversationID,
            runID: command.kind == .send ? UUID().uuidString.lowercased() : nil, workspaceID: workspace.id)
        if command.kind == .send, lockedSend {
            lockedSend = false
            receipt = .init(commandID: command.commandID, deviceID: command.deviceID, status: .rejected, conversationID: command.conversationID,
                message: "Pi Durable is locked.", workspaceID: workspace.id, code: "default_agent_locked")
        }
        receipts[command.commandID] = receipt
        return receipt
    }

    func uploadAttachment(_ data: Data, sha256: String, name: String, mimeType: String) -> LibraryAttachmentReference {
        uploads.append(.init(data: data, sha256: sha256, name: name, mimeType: mimeType))
        return .init(id: sha256, name: name, mimeType: mimeType, byteCount: Int64(data.count))
    }
    func sessionOptions(providerID: String, workingDirectory: String?, model: String?) throws -> SessionSettings {
        optionRequests.append(.init(providerID: providerID, workingDirectory: workingDirectory, model: model))
        if directoriesRefused, workingDirectory != nil {
            throw LibraryAPIError(code: "http_409", message: "The working directory does not exist on this workspace.")
        }
        return .init(conversationID: "", model: model ?? "small", thinking: "low",
            permission: "agent-full-access",
            models: [.init(id: "small", label: "Small"), .init(id: "large", label: "Large", description: "The larger model.")],
            thinkingLevels: [.init(id: "low", label: "Low")],
            permissions: [.init(id: "agent-full-access", label: "Full access"),
                          .init(id: "agent", label: "Approve for me", description: "Only ask for actions detected as potentially unsafe.")],
            availableTools: [], enabledTools: [], canConfigure: true)
    }
    func libraryFile(conversationID: String?, path: String) throws -> MemberLibraryFile {
        fileRequests.append(.init(conversationID: conversationID, path: path))
        if conversationID != nil, !knowsConversations { throw LibraryAPIError(code: "http_404", message: "Conversation not found in this workspace.") }
        let digest = SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
        return .init(name: "report.txt", mimeType: "text/plain", byteCount: Int64(file.count),
            sha256: damaged ? String(repeating: "0", count: 64) : digest, data: file.base64EncodedString())
    }
    func adopt(_ body: Data) throws {
        if adoptionsRefused { throw LibraryAPIError(code: "http_409", message: "The native session could not be reopened.") }
        if let adoptionFailure { throw adoptionFailure }
        adoptions.append(body)
    }
    func unlockDefaultAgent(workspace: String, unlockKey: String) -> Bool {
        unlocks.append(.init(workspace: workspace, unlockKey: unlockKey))
        if keysRefused { return false }
        piLocked = false
        return true
    }
    func configureDefaultAgent(_ payload: Data) throws -> DefaultAgentSyncReceipt {
        configurations.append(payload); piLocked = false
        return try JSONDecoder().decode(DefaultAgentSyncReceipt.self, from: Data(#"{"saved":true,"revision":"r","epoch":"e"}"#.utf8))
    }
    func startDefaultAgentControl(_ request: Data) throws -> DefaultAgentControlSession { throw LibraryAPIError(code: "unavailable", message: "") }
    func defaultAgentControl(id: String) throws -> DefaultAgentControlSession { throw LibraryAPIError(code: "unavailable", message: "") }
    func answerDefaultAgentControl(id: String, answerTo: String, answer: String) throws -> DefaultAgentControlSession { throw LibraryAPIError(code: "unavailable", message: "") }
    func cancelDefaultAgentControl(id: String) {}
}

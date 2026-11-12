import LibraryClient
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

/// A machine this Mac holds no stream to is never read on a timer: its
/// sessions show the history library sync brought, marked offline.
@MainActor @Suite(.serialized)
struct CentralExecutionClientTests {
    @MainActor private struct Setup {
        let fixture: FacadeFixture
        let workspace: ExecutionWorkspace
        let conversation: LibraryConversation
        let remote: CentralExecutionFixtureTransport
        let journal: URL
        func client() throws -> CentralExecutionClient {
            let workspace = workspace
            return try CentralExecutionClient(database: fixture.database, commandJournalURL: journal,
                provision: { _ in .init(workspace: workspace, deviceID: workspace.ownerDeviceID, token: "fixture-only") },
                makeTransport: { [remote] _ in remote }, loadCredential: { _ in nil }, saveCredential: { _ in })
        }
    }

    /// A workspace without a stream, whose history (a conversation and 100
    /// saved messages) reached this library by sync.
    private func setup() async throws -> Setup {
        let fixture = try await FacadeFixture()
        let identity = try await fixture.database.libraryIdentity()
        let workspace = try await fixture.database.registerExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            kind: .linux, name: "Build server", endpoint: URL(string: "https://fixture.ts.net/wovenmatter"),
            capabilities: ["execution.v1"], executionDeviceID: UUID().uuidString.lowercased())), deviceID: identity.hostDeviceID)
        let conversation = LibraryConversation(id: UUID().uuidString.lowercased(), title: "Remote", providerID: "pi-durable", routeID: workspace.id,
            libraryID: identity.libraryID, workspaceID: workspace.id)
        let origin = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: conversation.id,
            kind: .conversation, conversation: conversation)
        let history = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: conversation.id,
            kind: .transcript, transcript: .init(conversationID: conversation.id, messages: (0..<100).map { index in
                .init(id: UUID().uuidString.lowercased(), conversationID: conversation.id, role: "user", content: "Saved \(index)")
            }))
        _ = try await fixture.database.ingestExecutionJournal(.init(libraryID: identity.libraryID, entries: [origin, history]),
            deviceID: workspace.executionDeviceID!)
        let remote = CentralExecutionFixtureTransport(workspace: workspace, conversation: conversation)
        return Setup(fixture: fixture, workspace: workspace, conversation: conversation, remote: remote,
                     journal: fixture.directory.appending(path: "central-commands.json"))
    }

    @Test func aMachineWithoutAStreamShowsItsLibraryHistoryOfflineAndIsNeverRead() async throws {
        let setup = try await setup(); defer { setup.fixture.remove() }
        let (fixture, workspace, id) = (setup.fixture, setup.workspace, setup.conversation.id)
        let client = try setup.client()
        fixture.model.federatedExecutionClient = client

        try await client.refresh(conversationID: id)
        #expect(client.onlineWorkspaces.isEmpty)
        #expect(client.errors[workspace.id]?.contains("does not stream its sessions") == true)
        let saved = try #require(client.transcripts[id])
        let cursor = try #require(saved.olderCursor)
        #expect(cursor.hasPrefix("library:"))
        let earlier = try await client.earlierTranscript(conversationID: id, before: cursor)
        #expect(saved.messages.count + earlier.messages.count == 100)

        // The window's relay shows the same last known state with an offline notice.
        let snapshot = try await fixture.model.performFederatedExecution(.refresh(conversationID: id))
        #expect(!snapshot.online)
        #expect(snapshot.error?.contains("does not stream its sessions") == true)
        #expect(snapshot.transcript?.messages.count == saved.messages.count)
        #expect(snapshot.session == nil)

        // Opening the chat in a window reads it once; nothing reads it again later.
        let source = BackendWindowStreamSource(model: fixture.model)
        try await source.conversationOpened(id)
        let relay = await source.conversationRelay(conversationID: id)
        #expect(relay?.owner.online == false && relay?.owner.error != nil)
        #expect(source.polledConversationIDs.isEmpty)

        // Neither registry changes nor time make anything read the workspace.
        await client.connectRegisteredWorkspaces()
        await client.connectRegisteredWorkspaces()
        try await Task.sleep(for: .milliseconds(1_200))
        try? await client.refresh(conversationID: id)
        #expect(source.polledConversationIDs.isEmpty)
        #expect(await setup.remote.reads == 0, "History, questions, transcripts and settings are never read from it")
        #expect(!client.isStreamed(workspace.id))
        await source.conversationClosed(id)
    }

    @Test func aCommandToAWorkspaceWithoutAStreamRunsOnceAcrossALostAcknowledgement() async throws {
        let setup = try await setup(); defer { setup.fixture.remove() }
        let (workspace, id) = (setup.workspace, setup.conversation.id)
        await setup.remote.loseNextAcknowledgement()
        await #expect(throws: (any Error).self) { _ = try await setup.client().send(to: workspace, conversationID: id, text: "Exactly once") }
        // A new client (a restart) resolves the same command by its receipt.
        let receipt = try await setup.client().send(to: workspace, conversationID: id, text: "Exactly once")
        #expect(receipt.status == .completed)
        #expect(await setup.remote.executions == 1)
        let journal = try WorkspaceJournal(file: setup.journal)
        #expect(await journal.commandRecords(workspaceID: workspace.id).count == 1)
        #expect(await journal.snapshot().entries.isEmpty, "The command journal holds commands, not history")
        #expect(await setup.remote.reads == 0)
        #expect(await setup.fixture.recorder.deliveries.isEmpty)
    }

    @Test func aSessionJustCreatedOnAWorkspaceIsFoundByItsCreationCommand() async throws {
        let setup = try await setup(); defer { setup.fixture.remove() }
        let client = try setup.client()
        let created = UUID().uuidString.lowercased()
        #expect(try await client.workspace(conversationID: created) == nil)
        let identity = try await setup.fixture.database.libraryIdentity()
        _ = try await client.submit(.init(commandID: created, deviceID: identity.hostDeviceID, kind: .createSession,
            conversationID: created, providerID: "pi-durable", runtimeKind: "default_agent",
            libraryID: setup.workspace.libraryID, workspaceID: setup.workspace.id), workspace: setup.workspace)
        // Before its history reaches this library, the recorded command names its workspace.
        #expect(try await client.workspace(conversationID: created)?.id == setup.workspace.id)
    }
}

private actor CentralExecutionFixtureTransport: ExecutionWorkspaceTransport {
    let workspace: ExecutionWorkspace
    let conversation: LibraryConversation
    var receipts: [String: LibraryCommandReceipt] = [:]
    var executions = 0
    /// Every read of live state or history: none may happen.
    var reads = 0
    var lostACK = false
    init(workspace: ExecutionWorkspace, conversation: LibraryConversation) {
        self.workspace = workspace; self.conversation = conversation
    }
    func identity() -> ExecutionWorkspace { workspace }
    func providers() -> [HarnessCapabilities] { [] }
    func pending() -> [PendingInteraction] { reads += 1; return [] }
    func receipt(_ id: String) -> LibraryCommandReceipt? { receipts[id] }
    func conversations() -> [LibraryConversation] { reads += 1; return [conversation] }
    func capabilities(_ id: String) -> HarnessCapabilities {
        reads += 1
        return .init(id: "pi-durable", runtimeKind: "defaultAgent", displayName: "Pi Durable", available: true, canSteer: true, canStop: true)
    }
    func transcript(_ id: String) -> LibraryTranscript { reads += 1; return .init(conversationID: id) }
    func readWorkspace(_ request: LibraryWorkspaceRead) throws -> LibraryWorkspaceResult {
        reads += 1
        throw LibraryAPIError(code: "unavailable", message: "Not in this fixture.")
    }
    func events(after: Int64) -> ExecutionJournalPage { reads += 1; return .init(libraryID: workspace.libraryID, cursor: after) }
    func command(_ command: LibraryCommand) throws -> LibraryCommandReceipt {
        if let saved = receipts[command.commandID] { return saved }
        executions += 1
        let receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID,
            status: .completed, conversationID: command.conversationID, workspaceID: workspace.id)
        receipts[command.commandID] = receipt
        if lostACK { lostACK = false; throw URLError(.networkConnectionLost) }
        return receipt
    }
    func loseNextAcknowledgement() { lostACK = true }
}

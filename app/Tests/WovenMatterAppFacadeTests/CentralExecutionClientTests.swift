import CompanionClient
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CentralExecutionClientTests {
    @Test func importedConversationRoutesThroughBackendAndRetainsLostAcknowledgement() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.companionLibraryIdentity()
        let workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            kind: .linux, name: "Independent owner", endpoint: URL(string: "https://fixture.ts.net/wovenmatter"))), deviceID: identity.hostDeviceID)
        let conversation = CompanionConversation(id: UUID().uuidString.lowercased(), title: "Remote", providerID: "pi-durable", routeID: workspace.id,
            libraryID: identity.libraryID, workspaceID: workspace.id)
        let origin = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: conversation.id,
            kind: .conversation, conversation: conversation)
        _ = try await fixture.database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: [origin]), deviceID: identity.hostDeviceID)
        let remote = CentralExecutionFixtureTransport(workspace: workspace, conversation: conversation, entries: [origin])
        let journal = fixture.directory.appending(path: "central-commands.json")
        func make() throws -> CentralExecutionClient {
            try CentralExecutionClient(database: fixture.database, commandJournalURL: journal,
                provision: { _ in .init(workspace: workspace, deviceID: identity.hostDeviceID, token: "fixture-only") },
                makeTransport: { _ in remote }, loadCredential: { _ in nil }, saveCredential: { _ in })
        }
        fixture.model.federatedExecutionClient = try make()
        await remote.loseNextAcknowledgement()
        let record = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id == conversation.id })
        await #expect(throws: (any Error).self) { _ = try await fixture.model.dispatchAgentMessage(conversation: record, input: .init(text: "Exactly once")) }
        fixture.model.federatedExecutionClient = try make()
        await fixture.model.federatedExecutionClient?.refreshRegisteredWorkspaces()
        #expect(try await fixture.database.companionFederatedTranscript(conversationID: conversation.id)?.messages.map(\.content) == ["Exactly once"])
        let backend = BackendApplicationService(model: fixture.model)
        let request = BackendRPCRequest(method: "application.command", payload: try JSONEncoder().encode(
            BackendApplicationCommand.sendMessageFenced(conversationID: conversation.id, input: .init(text: "Exactly once"), noteID: nil,
                admission: .init(instanceID: backend.instanceID, clientID: UUID(), stopSequence: 0, observedStopRevision: 0))))
        let response = await backend.handle(request)
        #expect(response.error == nil, "\(response.error ?? "")")
        #expect(await remote.executions == 1)
        let stoppedPreparation = AgentDispatchFence(); stoppedPreparation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await fixture.model.federatedExecutionClient?.send(conversationID: conversation.id, text: "Stopped before transport",
                beforeDispatch: { try stoppedPreparation.claimDispatch() })
        }
        #expect(await remote.executions == 1)
        #expect(await fixture.recorder.deliveries.isEmpty)
        let state = try await fixture.model.performFederatedExecution(.refresh(conversationID: conversation.id))
        #expect(state.online)
        #expect(state.transcript?.messages.map(\.content) == ["Exactly once"])
        #expect(try await fixture.database.companionFederatedTranscript(conversationID: conversation.id)?.messages.map(\.content) == ["Exactly once"])
        #expect(try await fixture.database.companionExecutionOriginCursor(workspaceID: workspace.id) == 2)
    }

    @Test func malformedReplayCannotAdvanceAuthoritativeOrigin() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.companionLibraryIdentity()
        let workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            kind: .linux, name: "Independent owner", endpoint: URL(string: "https://fixture.ts.net/wovenmatter"))), deviceID: identity.hostDeviceID)
        let conversation = CompanionConversation(id: UUID().uuidString.lowercased(), title: "Remote", providerID: "pi-durable", routeID: workspace.id,
            libraryID: identity.libraryID, workspaceID: workspace.id)
        let origin = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: conversation.id,
            kind: .conversation, conversation: conversation)
        _ = try await fixture.database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: [origin]), deviceID: identity.hostDeviceID)
        let history = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: conversation.id,
            kind: .transcript, transcript: .init(conversationID: conversation.id, messages: (0..<100).map { index in
                .init(id: UUID().uuidString.lowercased(), conversationID: conversation.id, role: "user", content: "Saved \(index)")
            }))
        _ = try await fixture.database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: [history]), deviceID: identity.hostDeviceID)
        let remote = CentralExecutionFixtureTransport(workspace: workspace, conversation: conversation, entries: [origin, history])
        await remote.breakReplay()
        let client = try CentralExecutionClient(database: fixture.database, commandJournalURL: fixture.directory.appending(path: "commands.json"),
            provision: { _ in .init(workspace: workspace, deviceID: identity.hostDeviceID, token: "fixture-only") },
            makeTransport: { _ in remote }, loadCredential: { _ in nil }, saveCredential: { _ in })
        await #expect(throws: (any Error).self) { try await client.refresh(conversationID: conversation.id) }
        #expect(try await fixture.database.companionExecutionOriginCursor(workspaceID: workspace.id) == 2)
        #expect(client.onlineWorkspaces.isEmpty)
        let saved = try #require(client.transcripts[conversation.id])
        let cursor = try #require(saved.olderCursor)
        #expect(cursor.hasPrefix("library:"))
        let earlier = try await client.earlierTranscript(conversationID: conversation.id, before: cursor)
        #expect(saved.messages.count + earlier.messages.count == 100)
        await client.refreshRegisteredWorkspaces()
        let attempts = await remote.eventRequests
        await client.refreshRegisteredWorkspaces()
        #expect(await remote.eventRequests == attempts)
        #expect(client.errors[workspace.id] != nil)
        #expect(await fixture.recorder.deliveries.isEmpty)
    }
}

private actor CentralExecutionFixtureTransport: ExecutionWorkspaceTransport {
    let workspace: CompanionExecutionWorkspace
    let conversation: CompanionConversation
    var entries: [CompanionJournalEntry]
    var receipts: [String: CompanionCommandReceipt] = [:]
    var executions = 0
    var eventRequests = 0
    var lostACK = false
    var broken = false
    init(workspace: CompanionExecutionWorkspace, conversation: CompanionConversation, entries: [CompanionJournalEntry]) {
        self.workspace = workspace; self.conversation = conversation; self.entries = entries
    }
    func identity() -> CompanionExecutionWorkspace { workspace }
    func providers() -> [CompanionProvider] { [] }
    func pending() -> [CompanionPendingInteraction] { [] }
    func receipt(_ id: String) -> CompanionCommandReceipt? { receipts[id] }
    func conversations() -> [CompanionConversation] { [conversation] }
    func capabilities(_ id: String) -> CompanionProvider { .init(id: "pi-durable", runtimeKind: "defaultAgent", displayName: "Pi Durable", available: true, canSteer: true, canStop: true) }
    func transcript(_ id: String) -> CompanionTranscript {
        entries.last(where: { $0.transcript != nil })?.transcript ?? .init(conversationID: id)
    }
    func events(after: Int64) -> CompanionJournalPage {
        eventRequests += 1
        let available = entries.filter { $0.originSequence > after }
        return .init(libraryID: workspace.libraryID, cursor: after + Int64(available.count) + (broken ? 1 : 0), entries: available)
    }
    func command(_ command: CompanionCommand) throws -> CompanionCommandReceipt {
        if let saved = receipts[command.commandID] { return saved }
        executions += 1
        let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID,
            status: .completed, conversationID: conversation.id, workspaceID: workspace.id)
        receipts[command.commandID] = receipt
        entries.append(.init(workspaceID: workspace.id, originSequence: Int64(entries.count + 1), conversationID: conversation.id,
            kind: .transcript, transcript: .init(conversationID: conversation.id, messages: [
                .init(id: UUID().uuidString.lowercased(), conversationID: conversation.id, role: "user", content: command.text ?? "")
            ])))
        if lostACK { lostACK = false; throw URLError(.networkConnectionLost) }
        return receipt
    }
    func loseNextAcknowledgement() { lostACK = true }
    func breakReplay() { broken = true }
}

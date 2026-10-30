import CompanionClient
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CentralExecutionClientTests {
    @Test(.timeLimit(.minutes(1))) func registryStatusDoesNotWaitForAgentDiscoveryAndCachesTheResult() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.companionLibraryIdentity()
        let id = UUID().uuidString.lowercased()
        let workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: id, libraryID: identity.libraryID, ownerDeviceID: id, kind: .mac, name: "Other Mac",
            endpoint: URL(string: "https://fixture.ts.net/wovenmatter"))), deviceID: identity.hostDeviceID)
        let remote = CentralExecutionFixtureTransport(workspace: workspace,
            conversation: .init(id: UUID().uuidString.lowercased(), title: "Fixture"), entries: [])
        remote.providerGate.hold(); defer { remote.providerGate.open() }
        fixture.model.federatedExecutionClient = try CentralExecutionClient(database: fixture.database,
            commandJournalURL: fixture.directory.appending(path: "catalog-commands.json"),
            provision: { _ in .init(workspace: workspace, deviceID: identity.hostDeviceID, token: "fixture-only") },
            makeTransport: { _ in remote }, loadCredential: { _ in nil }, saveCredential: { _ in })
        let host = CompanionHostController(model: fixture.model, defaults: fixture.defaults, supportDirectory: fixture.directory)
        defer { host.stop() }
        await host.refreshStatus()
        #expect(host.snapshot.executionWorkspaces.contains { $0.id == id })
        await remote.providerGate.waitForArrival()
        #expect(host.workspaceProviders[id] == nil)
        remote.providerGate.open()
        for _ in 0..<100 {
            if host.workspaceProviders[id] != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.workspaceProviders[id]?.map(\.id) == ["pi-durable"])
        await host.refreshStatus()
        #expect(await remote.providerRequests == 1)
    }

    @Test func phoneHistoryRejectsCommandsBeforeJournalingOrTransport() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.companionLibraryIdentity()
        let phoneID = UUID().uuidString.lowercased()
        let workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: phoneID, libraryID: identity.libraryID, ownerDeviceID: phoneID,
            kind: .ios, name: "iPhone", endpoint: URL(string: "https://fixture.ts.net/wovenmatter"))), deviceID: identity.hostDeviceID)
        let conversation = CompanionConversation(id: UUID().uuidString.lowercased(), title: "Quick Chat", providerID: "pi-durable-device", workspaceID: phoneID)
        _ = try await fixture.database.ingestCompanionJournal(.init(libraryID: identity.libraryID, entries: [
            .init(workspaceID: phoneID, originSequence: 1, conversationID: conversation.id, kind: .conversation, conversation: conversation)
        ]), deviceID: phoneID)
        let remote = CentralExecutionFixtureTransport(workspace: workspace, conversation: conversation, entries: [])
        let journal = fixture.directory.appending(path: "phone-commands.json")
        var provisioned = false
        let client = try CentralExecutionClient(database: fixture.database, commandJournalURL: journal,
            provision: { _ in provisioned = true; return .init(workspace: workspace, deviceID: identity.hostDeviceID, token: "fixture-only") },
            makeTransport: { _ in remote }, loadCredential: { _ in nil }, saveCredential: { _ in })
        await #expect(throws: (any Error).self) { _ = try await client.send(conversationID: conversation.id, text: "Do not execute") }
        await #expect(throws: (any Error).self) { _ = try await client.stop(conversationID: conversation.id, runID: UUID().uuidString.lowercased()) }
        #expect(!provisioned)
        #expect(await remote.executions == 0)
        let saved = try WorkspaceJournal(file: journal)
        #expect(await saved.snapshot().commands.isEmpty)
    }

    @Test func importedConversationRoutesThroughBackendAndRetainsLostAcknowledgement() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.companionLibraryIdentity()
        let workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            kind: .linux, name: "Independent owner", endpoint: URL(string: "https://fixture.ts.net/wovenmatter"), executionDeviceID: UUID().uuidString.lowercased())), deviceID: identity.hostDeviceID)
        let conversation = CompanionConversation(id: UUID().uuidString.lowercased(), title: "Remote", providerID: "pi-durable", routeID: workspace.id,
            libraryID: identity.libraryID, workspaceID: workspace.id)
        let origin = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: conversation.id,
            kind: .conversation, conversation: conversation)
        let publisher = try await fixture.database.issueCompanionWorkspacePublisher(workspaceID: workspace.id,
            endpoint: URL(string: "https://central.ts.net/wovenmatter")!, deviceID: identity.hostDeviceID)
        try await publish([origin], grant: publisher, database: fixture.database)
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
        #expect(fixture.model.federatedExecutionClient?.transcripts[conversation.id]?.messages.map(\.content) == ["Exactly once"])
        #expect(try await fixture.database.companionFederatedTranscript(conversationID: conversation.id)?.messages.isEmpty != false)
        #expect(try await fixture.database.companionExecutionOriginCursor(workspaceID: workspace.id) == 1)
        let observer = try WorkspaceJournal(file: journal)
        #expect(await observer.snapshot().directCursors[workspace.id] == 2)
        #expect(await observer.snapshot().pendingEntries.isEmpty)
        #expect(await observer.snapshot().pendingRegistrations.isEmpty)
        await remote.setOffline(true)
        fixture.model.federatedExecutionClient = try make()
        await #expect(throws: (any Error).self) { try await fixture.model.federatedExecutionClient?.refresh(conversationID: conversation.id) }
        #expect(fixture.model.federatedExecutionClient?.transcripts[conversation.id]?.messages.map(\.content) == ["Exactly once"])
        await remote.setOffline(false)
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
        #expect(try await fixture.database.companionExecutionOriginCursor(workspaceID: workspace.id) == 1)
        #expect(await remote.requestedCursors.last == 2)
        try await publish(await remote.entries, grant: publisher, database: fixture.database)
        #expect(try await fixture.database.companionFederatedTranscript(conversationID: conversation.id)?.messages.map(\.content) == ["Exactly once"])
        #expect(try await fixture.database.companionExecutionOriginCursor(workspaceID: workspace.id) == 2)
    }

    @Test func malformedReplayCannotAdvanceAuthoritativeOrigin() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.companionLibraryIdentity()
        let workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            kind: .linux, name: "Independent owner", endpoint: URL(string: "https://fixture.ts.net/wovenmatter"), executionDeviceID: UUID().uuidString.lowercased())), deviceID: identity.hostDeviceID)
        let conversation = CompanionConversation(id: UUID().uuidString.lowercased(), title: "Remote", providerID: "pi-durable", routeID: workspace.id,
            libraryID: identity.libraryID, workspaceID: workspace.id)
        let origin = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: conversation.id,
            kind: .conversation, conversation: conversation)
        let publisher = try await fixture.database.issueCompanionWorkspacePublisher(workspaceID: workspace.id,
            endpoint: URL(string: "https://central.ts.net/wovenmatter")!, deviceID: identity.hostDeviceID)
        try await publish([origin], grant: publisher, database: fixture.database)
        let history = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: conversation.id,
            kind: .transcript, transcript: .init(conversationID: conversation.id, messages: (0..<100).map { index in
                .init(id: UUID().uuidString.lowercased(), conversationID: conversation.id, role: "user", content: "Saved \(index)")
            }))
        try await publish([history], grant: publisher, database: fixture.database)
        let remote = CentralExecutionFixtureTransport(workspace: workspace, conversation: conversation, entries: [origin, history])
        await remote.breakReplay()
        let client = try CentralExecutionClient(database: fixture.database, commandJournalURL: fixture.directory.appending(path: "commands.json"),
            provision: { _ in .init(workspace: workspace, deviceID: identity.hostDeviceID, token: "fixture-only") },
            makeTransport: { _ in remote }, loadCredential: { _ in nil }, saveCredential: { _ in })
        await #expect(throws: (any Error).self) { try await client.refresh(conversationID: conversation.id) }
        #expect(try await fixture.database.companionExecutionOriginCursor(workspaceID: workspace.id) == 2)
        #expect(client.onlineWorkspaces.isEmpty)
        let observer = try WorkspaceJournal(file: fixture.directory.appending(path: "commands.json"))
        #expect(await observer.snapshot().directCursors[workspace.id] == nil)
        #expect(await observer.snapshot().entries.isEmpty)
        #expect(await observer.snapshot().pendingEntries.isEmpty)
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
    private func publish(_ entries: [CompanionJournalEntry], grant: CompanionWorkspacePublisherGrant, database: WorkspaceDatabase) async throws {
        let path = "/v1/federation/publisher/journal"
        let request = CompanionHTTPRequest(method: "POST", target: path,
            headers: ["authorization": "Bearer " + grant.token, "x-woven-workspace": grant.libraryID],
            body: try JSONEncoder().encode(CompanionJournalBatch(libraryID: grant.libraryID, entries: entries)))
        let response = try await CompanionWorkspacePublisherAPI.handle(request, path: path, database: database)
        #expect(response.status == 200)
    }

}

private actor CentralExecutionFixtureTransport: ExecutionWorkspaceTransport {
    let workspace: CompanionExecutionWorkspace
    let conversation: CompanionConversation
    var entries: [CompanionJournalEntry]
    var receipts: [String: CompanionCommandReceipt] = [:]
    var receivedCommands: [CompanionCommand] = []
    var executions = 0
    var eventRequests = 0
    var providerRequests = 0
    nonisolated let providerGate = FacadeGate()
    var requestedCursors: [Int64] = []
    var offline = false
    func setOffline(_ value: Bool) { offline = value }
    var lostACK = false
    var broken = false
    init(workspace: CompanionExecutionWorkspace, conversation: CompanionConversation, entries: [CompanionJournalEntry]) {
        self.workspace = workspace; self.conversation = conversation; self.entries = entries
    }
    func identity() throws -> CompanionExecutionWorkspace { if offline { throw MobileConnectionError.offline }; return workspace }
    func providers() async throws -> [CompanionProvider] {
        providerRequests += 1
        await providerGate.pass()
        if offline { throw MobileConnectionError.offline }
        return [.init(id: "pi-durable", runtimeKind: "defaultAgent", displayName: "Pi Durable", available: true)]
    }
    func pending() -> [CompanionPendingInteraction] { [] }
    func receipt(_ id: String) -> CompanionCommandReceipt? { receipts[id] }
    func conversations() -> [CompanionConversation] { [conversation] }
    func capabilities(_ id: String) -> CompanionProvider { .init(id: "pi-durable", runtimeKind: "defaultAgent", displayName: "Pi Durable", available: true, canSteer: true, canStop: true) }
    func transcript(_ id: String) -> CompanionTranscript {
        entries.last(where: { $0.transcript != nil })?.transcript ?? .init(conversationID: id)
    }
    func events(after: Int64) throws -> CompanionJournalPage {
        if offline { throw MobileConnectionError.offline }
        eventRequests += 1; requestedCursors.append(after)
        let available = entries.filter { $0.originSequence > after }
        return .init(libraryID: workspace.libraryID, cursor: after + Int64(available.count) + (broken ? 1 : 0), entries: available)
    }
    func command(_ command: CompanionCommand) throws -> CompanionCommandReceipt {
        if let saved = receipts[command.commandID] { return saved }
        executions += 1; receivedCommands.append(command)
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
    func startRun(_ id: String) {
        entries.append(.init(workspaceID: workspace.id, originSequence: Int64(entries.count + 1), conversationID: conversation.id,
            kind: .transcript, transcript: .init(conversationID: conversation.id, activeRunID: id)))
    }
    func loseNextAcknowledgement() { lostACK = true }
    func breakReplay() { broken = true }
}

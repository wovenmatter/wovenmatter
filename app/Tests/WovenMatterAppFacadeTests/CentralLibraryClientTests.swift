import Foundation
import Testing
import CompanionClient
import WovenMatterCompanion
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CentralLibraryClientTests {
    @Test func desktopProjectionRoutesForeignExecutionWithoutImportingItsSession() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let store = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let central = MacClientFakeCentral()
        let client = CentralLibraryClientModel(store: store, transport: central)
        await client.initialize(); await client.refresh()
        let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(),
            libraryID: "00000000-0000-4000-8000-000000000001", ownerDeviceID: UUID().uuidString.lowercased(),
            kind: .mac, name: "Other development build")
        let direct = MacClientFakeExecution(workspace: workspace)
        try await client.attachExecutionWorkspace(workspace, transport: direct)
        await client.selectExecutionWorkspace(workspace.id)
        client.composer = "Fixture first message"; await client.send()
        let id = try #require(client.selectedConversationID)
        fixture.model.liveLibraryClient = client
        await fixture.model.refreshWorkspace()
        #expect(fixture.model.workspaceOverview?.conversations.contains { $0.id == id } == true)
        #expect(fixture.model.federatedExecutionOwners[id] == workspace.id)
        #expect(try await fixture.database.companionSnapshot().conversations.isEmpty)
        let revision = fixture.model.workspaceListRevision
        await fixture.model.refreshWorkspace()
        #expect(fixture.model.workspaceListRevision == revision)
        let wire = try JSONEncoder().encode(DevelopmentReplicaSnapshot(client))
        let projection = try JSONDecoder().decode(DevelopmentReplicaSnapshot.self, from: wire)
        #expect(projection.owners[id] == workspace.id)
        fixture.model.liveLibraryClient = nil
        await fixture.model.updateDevelopmentReplica(projection)
        #expect(fixture.model.workspaceOverview?.conversations.contains { $0.id == id } == true)
        #expect(fixture.model.federatedExecutionOwners[id] == workspace.id)
        #expect(try await fixture.database.companionSnapshot().conversations.isEmpty)
        fixture.model.liveLibraryClient = client
        try await client.desktopSend(id: id, text: "Fixture second message")
        #expect(await direct.sendCount == 2)
        #expect(await central.sendCount == 0)
        #expect(try await client.desktopExecution(.refresh(conversationID: id)).workspace.id == workspace.id)
        let backend = BackendApplicationService(model: fixture.model)
        let request = BackendRPCRequest(method: "application.command", payload: try JSONEncoder().encode(
            BackendApplicationCommand.sendMessageFenced(conversationID: id, input: .init(text: "From the app window"), noteID: nil,
                admission: .init(instanceID: backend.instanceID, clientID: UUID(), stopSequence: 0, observedStopRevision: 0))))
        let response = await backend.handle(request)
        #expect(response.error == nil, "\(response.error ?? "")")
        #expect(await direct.sendCount == 3)
        #expect(await central.sendCount == 0)
    }

    @Test func serverOwnedReplicaSynchronizesNativeDatabaseEditsWithoutWindowOwnership() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        try await replica.bindWorkspace("00000000-0000-4000-8000-000000000001")
        fixture.defaults.set(false, forKey: "wovenmatter.client.share-execution")
        let central = MacClientFakeCentral()
        let client = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            preferences: fixture.defaults, makeLocalExecution: { directory, store in
                try await SecondaryMacExecutionWorkspace.create(directory: directory, replica: store,
                    executionModel: fixture.model)
            })
        await client.initializeClientWorkspace()
        let execution = try #require(client.localExecution)
        #expect(execution.model === fixture.model)
        let noteID = try await fixture.store.createNote(folderID: nil, kind: .note)
        try await execution.capture()
        await client.refresh()
        #expect(await central.notes[noteID] != nil)
        let originalDeviceID = client.state.deviceID
        await central.setOffline(true)
        let offlineNoteID = try await fixture.store.createNote(folderID: nil, kind: .note)
        try await execution.capture()
        await client.refresh()
        #expect(!client.online)
        #expect(fixture.model.state == .ready)
        #expect(client.localExecution === execution)
        #expect(await central.notes[offlineNoteID] == nil)
        #expect(await replica.snapshot().outbox.contains { $0.mutation.resourceID == offlineNoteID })
        let offlineRestored = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        #expect(await offlineRestored.snapshot().outbox.contains { $0.mutation.resourceID == offlineNoteID })
        let local = try #require(await replica.snapshot().notes[noteID])
        var inbound = local; inbound.title = "Changed on production"; inbound.revision += 1
        await central.publishNote(inbound)
        await central.setOffline(false)
        // The normal refresh loop reconnects using the existing transport and identity;
        // no disconnect, pairing link, enrollment, or executor replacement is needed.
        await client.refresh()
        try await execution.capture()
        #expect(client.online)
        #expect(client.localExecution === execution)
        #expect(client.state.deviceID == originalDeviceID)
        #expect(await central.notes[offlineNoteID] != nil)
        #expect(await replica.snapshot().outbox.isEmpty)
        #expect(try await fixture.database.companionNote(id: noteID)?.title == "Changed on production")
        let restored = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        #expect(await restored.snapshot().notes[noteID]?.title == "Changed on production")
        #expect(await central.sendCount == 0)
    }

    @Test func olderActivityStaysWithItsConversationWhenNavigationChangesDuringLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacClient-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MobileStore(file: root.appending(path: "library.json"))
        try await store.cache(.init(conversationID: "A", messages: [.init(id: "latest-a", conversationID: "A", role: "assistant", content: "A")],
            activities: (5..<45).map { .init(id: "tool-\($0)", runID: "run", title: "Recent", status: "running") }, olderCursor: "older"))
        try await store.cache(.init(conversationID: "B", messages: [.init(id: "latest-b", conversationID: "B", role: "assistant", content: "B")]))
        let transport = MacClientFakeCentral()
        let model = CentralLibraryClientModel(store: store, transport: transport)
        await model.initialize(); model.selectedConversationID = "A"
        let loading = Task { await model.olderMessages() }
        for _ in 0..<100 { if await transport.historyWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(await transport.historyWaiting)
        model.selectedConversationID = "B"
        await transport.releaseHistory(); await loading.value
        #expect(model.transcript?.messages.map(\.id) == ["latest-b"])
        model.selectedConversationID = "A"
        #expect(model.transcript?.messages.map(\.id) == ["older-a", "latest-a"])
        #expect(model.transcript?.activities.map(\.id) == (0..<45).map { "tool-\($0)" })
        try await store.cache(.init(conversationID: "A", activities: (5..<45).map { .init(id: "tool-\($0)", runID: "run", title: "Recent", status: "completed") }))
        await model.reload()
        #expect(model.transcript?.activities.map(\.id) == (0..<45).map { "tool-\($0)" })
        #expect(model.transcript?.activities.last?.status == "completed")
    }

    @Test func secondaryMacAlwaysStartsItsOwnWorkspaceAndKeepsItAfterDisconnect() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let library = "00000000-0000-4000-8000-000000000001"
        try await replica.bindWorkspace(library)
        let owner = await replica.snapshot().deviceID
        fixture.defaults.set(false, forKey: "wovenmatter.client.share-execution")
        fixture.defaults.set(false, forKey: "wovenmatter.client.local-execution")
        let central = MacClientFakeCentral(); await central.setOffline(true)
        var created = 0, cleared = 0
        var clearedWorkspaceIDs: [String] = []
        let model = CentralLibraryClientModel(store: replica, transport: central, executionDirectory: fixture.directory,
            preferences: fixture.defaults, makeLocalExecution: { directory, store in
                created += 1
                return try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: library,
                    ownerDeviceID: owner, kind: .mac, name: "This Mac", executionDeviceID: owner),
                    model: fixture.model, replica: store, directory: directory)
            }, clearCentralCredential: { cleared += 1 }, clearWorkspaceCredential: { clearedWorkspaceIDs.append($0) })
        await model.initialize()
        #expect(created == 0) // Opening central pairing settings does not start another executor.
        await model.initializeClientWorkspace()
        await model.initializeClientWorkspace()
        #expect(created == 1)
        #expect(model.localExecution?.descriptor.id == owner)
        #expect(model.canControl(workspaceID: owner))
        #expect(!model.sharingLocalExecution)
        let remote = CompanionExecutionWorkspace(id: "remote", libraryID: library, ownerDeviceID: "linux", kind: .linux, name: "Linux")
        try await model.attachExecutionWorkspace(remote, transport: MacClientFakeExecution(workspace: remote))
        await model.refresh()
        #expect(model.canControl(workspaceID: remote.id))
        await model.createNote()
        let note = try #require(model.selectedNote)
        model.editNote(note, title: "Keep offline", content: "Pending writing")
        model.composer = "Keep draft"
        await model.disconnectCentralLibrary()
        #expect(cleared == 1)
        #expect(clearedWorkspaceIDs == ["remote"])
        #expect(!model.canControl(workspaceID: remote.id))
        #expect(model.localExecution != nil)
        #expect(model.canControl(workspaceID: owner))
        #expect(model.state.notes[note.id]?.content == "Pending writing")
        #expect(model.state.chatDrafts["new-chat"]?.text == "Keep draft")
        #expect(model.synchronization.lanes[.library]?.pendingCount == 1)
        let reopened = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        #expect(await reopened.snapshot().workspaceID == library)
        #expect(await reopened.snapshot().notes[note.id]?.title == "Keep offline")
        #expect(await reopened.snapshot().outbox.count == 1)
    }

    @Test func lostLaunchAcknowledgementKeepsStableIDsAndDoesNotDuplicateExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacClient-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MobileStore(file: root.appending(path: "library.json"))
        let transport = MacClientFakeCentral()
        let model = CentralLibraryClientModel(store: store, transport: transport)
        await model.initialize(); await model.refresh()
        model.composer = "One logical turn"
        await transport.dropNextSendAcknowledgement()
        await model.send()
        let launch = try #require(model.pendingLaunches.first)
        #expect(launch.create.conversationID == launch.initialSend.conversationID)
        #expect(model.composer == "One logical turn")
        await model.continueLaunch(launch)
        #expect(await transport.sendCount == 1)
        #expect(model.pendingLaunches.isEmpty)
        #expect(model.selectedConversationID == launch.create.conversationID)
    }

}

private actor MacClientFakeCentral: CompanionTransport {
    var historyWaiting = false
    var historyContinuation: CheckedContinuation<Void, Never>?
    func releaseHistory() { historyContinuation?.resume(); historyContinuation = nil }
    func transcript(_ id: String, before: String) async -> CompanionTranscript {
        historyWaiting = true
        await withCheckedContinuation { historyContinuation = $0 }
        return .init(conversationID: id, messages: [.init(id: "older-a", conversationID: id, role: "assistant", content: "Older A")],
            activities: (0..<5).map { .init(id: "tool-\($0)", runID: "run", title: "Older", status: "completed") })
    }
    var notes: [String: CompanionNote] = [:]
    var folders: [String: CompanionFolder] = [:]
    var publishedChanges: [CompanionChange] = []
    func publishNote(_ note: CompanionNote) {
        notes[note.id] = note
        publishedChanges.append(.init(cursor: Int64(publishedChanges.count + 1), resourceKind: .note,
            resourceID: note.id, operation: .upsert, revision: note.revision, note: note))
    }
    var receipts: [String: CompanionCommandReceipt] = [:]
    var sendCount = 0
    var offline = false
    var dropSend = false
    var mutationFailure = false
    func setMutationFailure(_ value: Bool) { mutationFailure = value }
    func setOffline(_ value: Bool) { offline = value }
    func dropNextSendAcknowledgement() { dropSend = true }
    func workspaceIdentity() throws -> String { if offline { throw MobileConnectionError.offline }; return "00000000-0000-4000-8000-000000000001" }
    func snapshot() -> CompanionSnapshot { .init(workspaceID: "00000000-0000-4000-8000-000000000001", cursor: Int64(publishedChanges.count), folders: Array(folders.values), notes: Array(notes.values)) }
    func changes(after: Int64) -> CompanionChangePage { .init(workspaceID: "00000000-0000-4000-8000-000000000001", cursor: Int64(publishedChanges.count), changes: publishedChanges.filter { $0.cursor > after }) }
    func mutate(_ mutation: CompanionMutation) throws -> CompanionMutationResult {
        if mutationFailure { throw CompanionAPIError(code: "temporary", message: "Fixture mutation failed") }
        if mutation.kind == .createFolder {
            let folder = CompanionFolder(id: mutation.resourceID, name: mutation.title ?? "", revision: 1)
            folders[folder.id] = folder
            return .init(operationID: mutation.operationID, status: .accepted, folder: folder)
        }
        let note = CompanionNote(id: mutation.resourceID, folderID: mutation.folderID, title: mutation.title ?? "", content: mutation.content ?? "", revision: 1)
        notes[note.id] = note
        return .init(operationID: mutation.operationID, status: .accepted, note: note)
    }
    func note(_ id: String) throws -> CompanionNote { try #require(notes[id]) }
    func providers() -> [CompanionProvider] { [.init(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)] }
    func pending() -> [CompanionPendingInteraction] { [] }
    func transcript(_ id: String) -> CompanionTranscript { .init(conversationID: id) }
    func command(_ command: CompanionCommand) throws -> CompanionCommandReceipt {
        if let receipt = receipts[command.commandID] { return receipt }
        let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: command.conversationID)
        receipts[command.commandID] = receipt
        if command.kind == .send {
            sendCount += 1
            if dropSend { dropSend = false; throw MobileConnectionError.offline }
        }
        return receipt
    }
    func receipt(_ id: String) -> CompanionCommandReceipt? { receipts[id] }
}

private actor MacClientFakeExecution: ExecutionWorkspaceTransport {
    let workspace: CompanionExecutionWorkspace
    var entries: [CompanionJournalEntry] = []
    var receiptValues: [String: CompanionCommandReceipt] = [:]
    var sendCount = 0
    init(workspace: CompanionExecutionWorkspace) { self.workspace = workspace }
    var revoked = false
    func setRevoked(_ value: Bool) { revoked = value }
    func identity() throws -> CompanionExecutionWorkspace {
        if revoked { throw MobileConnectionError.http(401, "Revoked") }; return workspace
    }
    func providers() -> [CompanionProvider] { [.init(id: "default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", routeName: "Linux", available: true)] }
    func pending() -> [CompanionPendingInteraction] { [] }
    func command(_ command: CompanionCommand) -> CompanionCommandReceipt {
        if let receipt = receiptValues[command.commandID] { return receipt }
        let id = command.conversationID ?? "invalid"
        let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed, conversationID: id)
        receiptValues[command.commandID] = receipt
        if command.kind == .createSession {
            entries.append(.init(workspaceID: workspace.id, originSequence: Int64(entries.count + 1), conversationID: id,
                kind: .conversation, conversation: .init(id: id, title: "Direct chat", providerID: "default_agent")))
        }
        if command.kind == .send {
            sendCount += 1
            entries.append(.init(workspaceID: workspace.id, originSequence: Int64(entries.count + 1), conversationID: id,
                kind: .transcript, transcript: .init(conversationID: id, messages: [.init(id: "message", conversationID: id, role: "assistant", content: "Direct result")])))
        }
        return receipt
    }
    func receipt(_ id: String) -> CompanionCommandReceipt? { receiptValues[id] }
    func events(after: Int64) -> CompanionJournalPage { .init(libraryID: workspace.libraryID, cursor: Int64(entries.count), entries: Array(entries.dropFirst(Int(after)))) }
    func conversations() -> [CompanionConversation] { entries.compactMap(\.conversation) }
    func transcript(_ id: String) -> CompanionTranscript { entries.last(where: { $0.conversationID == id && $0.transcript != nil })?.transcript ?? .init(conversationID: id) }
}

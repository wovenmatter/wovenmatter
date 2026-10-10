import Foundation
import Testing
import CompanionClient
import WovenMatterCompanion
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct CentralLibraryClientTests {
    @Test func offlineReplicaEditsSurviveRelaunchAndSync() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacClient-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "library.json")
        let store = try MobileStore(file: file)
        let transport = MacClientFakeCentral()
        let model = CentralLibraryClientModel(store: store, transport: transport)
        await model.initialize(); await model.refresh()
        await transport.setOffline(true)
        await model.createFolder("Offline work")
        await model.createNote()
        let note = try #require(model.selectedNote)
        model.editNote(note, title: "Retained title", content: "Retained writing")
        model.composer = "Draft survives restart"
        try await model.flushLocalWrites()
        let reopened = try MobileStore(file: file)
        #expect(await reopened.snapshot().notes[note.id]?.content == "Retained writing")
        #expect(await reopened.snapshot().chatDrafts["new-chat"]?.text == "Draft survives restart")
        #expect(await reopened.snapshot().outbox.count == 2)
        await transport.setOffline(false)
        await model.refresh()
        #expect(model.online)
        #expect(model.state.outbox.isEmpty)
        #expect(await transport.notes[note.id]?.title == "Retained title")
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

    @Test func directExecutionWorksWhileCentralIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacClient-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MobileStore(file: root.appending(path: "library.json"))
        let central = MacClientFakeCentral()
        let model = CentralLibraryClientModel(store: store, transport: central)
        await model.initialize(); await model.refresh()
        let workspace = CompanionExecutionWorkspace(id: "00000000-0000-4000-8000-000000000002", libraryID: "00000000-0000-4000-8000-000000000001", ownerDeviceID: "00000000-0000-4000-8000-000000000003", kind: .linux, name: "Linux", revision: 1)
        let direct = MacClientFakeExecution(workspace: workspace)
        try await model.attachExecutionWorkspace(workspace, transport: direct)
        await model.selectExecutionWorkspace(workspace.id)
        await central.setOffline(true)
        await model.refresh()
        #expect(!model.online)
        #expect(model.canControl)
        model.composer = "Runs directly"
        await model.send()
        #expect(await direct.sendCount == 1)
        let id = try #require(model.selectedConversationID)
        #expect(model.executionOwner(for: id) == workspace.id)
        #expect(model.state.transcripts[id]?.messages.last?.content == "Direct result")
        #expect(await central.sendCount == 0)
    }
}

private actor MacClientFakeCentral: CompanionTransport {
    var notes: [String: CompanionNote] = [:]
    var folders: [String: CompanionFolder] = [:]
    var receipts: [String: CompanionCommandReceipt] = [:]
    var sendCount = 0
    var offline = false
    var dropSend = false
    func setOffline(_ value: Bool) { offline = value }
    func dropNextSendAcknowledgement() { dropSend = true }
    func workspaceIdentity() throws -> String { if offline { throw MobileConnectionError.offline }; return "00000000-0000-4000-8000-000000000001" }
    func snapshot() -> CompanionSnapshot { .init(workspaceID: "00000000-0000-4000-8000-000000000001", cursor: 0) }
    func changes(after: Int64) -> CompanionChangePage { .init(workspaceID: "00000000-0000-4000-8000-000000000001", cursor: after) }
    func mutate(_ mutation: CompanionMutation) -> CompanionMutationResult {
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
    func identity() -> CompanionExecutionWorkspace { workspace }
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

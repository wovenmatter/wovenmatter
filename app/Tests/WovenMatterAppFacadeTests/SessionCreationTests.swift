import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct SessionCreationTests {
    nonisolated private static let runtimes = AgentRuntimeKind.allCases.filter { $0 != .opencode }

    private func create(_ f: FacadeFixture, runtime: AgentRuntimeKind, remote: Bool, id: UUID? = nil) async throws -> String {
        let owner = try await f.model.executionWorkspaceIdentity(workspaceID: remote ? f.remote.id : nil)
        let existing = try await f.database.workspaceOverview().folders.first { $0.executionWorkspaceID == owner }
        let folder: String
        if let existing { folder = existing.id }
        else { folder = try await f.database.createFolder(name: "Chats", location: .init(workspaceID: owner, rootPath: f.directory.path, managed: false)) }
        if remote {
            let harness = try #require(f.model.remoteWorkspaces.harnesses[f.remote.id]?.first { $0.id == runtime })
            return try #require(await f.model.createRemoteACPSession(target: .init(configuration: f.remote, harness: harness), requestedConversationID: id, folderID: folder))
        }
        return try #require(await f.model.createLocalACPSession(runtimeKind: runtime, requestedConversationID: id, folderID: folder))
    }

    private func record(_ f: FacadeFixture, _ id: String) async throws -> WorkspaceConversationRecord {
        try #require(try await f.database.workspaceOverview().conversations.first { $0.id == id })
    }

    @Test(arguments: runtimes, [false, true])
    func capturesSavedDefaultsOnceAndOpeningOnlyReads(runtime: AgentRuntimeKind, remote: Bool) async throws {
        let f = try await FacadeFixture(); defer { f.remove(); f.recorder.configurationGate.open() }
        let saved = SessionSelectionPreferences(defaults: f.defaults)
        saved.saveDefaults(.init(model: "saved-model", thinking: "saved-thinking", tools: ["notes"]), harness: runtime.rawValue)
        await f.recorder.holdConfiguration()
        let uuid = UUID()
        let creation = Task { try await create(f, runtime: runtime, remote: remote, id: uuid) }
        await f.recorder.waitForConfiguration()
        let id = uuid.uuidString.lowercased()
        let chat = try await record(f, id)
        // Even if the row becomes visible during creation, opening is read-only.
        await f.model.refreshLocalACPSession(conversation: chat)
        #expect(await f.recorder.configurations.isEmpty)
        saved.saveDefaults(.init(model: "newer-model"), harness: runtime.rawValue)
        f.recorder.configurationGate.open()
        #expect(try await creation.value == id)
        let captured = try #require(f.model.sessionSelectionPreferences.conversation(id: id))
        #expect(!captured.requiresApplication)
        #expect(captured.selections.model == "saved-model")
        await f.model.refreshLocalACPSession(conversation: chat)
        await f.model.refreshLocalACPSession(conversation: chat)
        #expect(await f.model.sendAgentMessage(conversation: chat, input: .init(text: "First message")))
        #expect(await f.recorder.configurations.count == 1)
        let next = try await create(f, runtime: runtime, remote: remote)
        #expect(f.model.sessionSelectionPreferences.conversation(id: next)?.selections.model == "newer-model")
        #expect(await f.recorder.configurations.count == 2)
    }

    @Test(arguments: runtimes, [false, true])
    func rejectedInitialSettingsDoNotBlockOpeningSendingOrDropdownCorrections(runtime: AgentRuntimeKind, remote: Bool) async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        f.model.sessionSelectionPreferences.saveDefaults(.init(model: "unavailable-model", thinking: "obsolete-thinking"), harness: runtime.rawValue)
        await f.recorder.rejectConfiguration(true)
        let id = try await create(f, runtime: runtime, remote: remote)
        let chat = try await record(f, id)
        #expect(f.model.localRunError == nil)
        #expect(f.model.sessionSelectionPreferences.conversation(id: id)?.requiresApplication == false)
        #expect(f.model.sessionSelectionPreferences.conversation(id: id)?.selections.model == nil)
        await f.model.refreshLocalACPSession(conversation: chat)
        #expect(await f.model.sendAgentMessage(conversation: chat, input: .init(text: "Use native settings")))
        #expect(await f.recorder.configurations.count == 1)
        try await f.model.cancelCanonicalRun(conversationID: id, runID: try #require(try await f.database.activeRunID(conversationID: id)))
        try await f.model.waitForAgentStop(conversationID: id)
        try await f.model.refreshClientExecutionState()
        await f.recorder.rejectConfiguration(false)
        await f.model.updateLocalACPSession(conversation: chat, model: "chosen-in-dropdown")
        _ = try await pollUntil(attempts: 1_000, interval: .milliseconds(10)) { f.model.localACPSessionMetadata[id]?.model == "chosen-in-dropdown" }
        #expect(f.model.localACPSessionMetadata[id]?.model == "chosen-in-dropdown")
        #expect(await f.recorder.configurations.count == 2)
        #expect(await f.recorder.configurations.last?.selections.thinking == nil)
    }

    /// The backend RPC's `title` and a member's `createSession` title name the
    /// session as it is created, on this Mac and on a Linux host it manages.
    @Test(arguments: [false, true])
    func requestedTitleNamesTheNewSession(remote: Bool) async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let owner = try await f.model.executionWorkspaceIdentity(workspaceID: remote ? f.remote.id : nil)
        let folder = try await f.database.createFolder(name: "Chats", location: .init(workspaceID: owner, rootPath: f.directory.path, managed: false))
        let named: String?
        if remote {
            let harness = try #require(f.model.remoteWorkspaces.harnesses[f.remote.id]?.first { $0.id == .codex })
            named = await f.model.createRemoteACPSession(target: .init(configuration: f.remote, harness: harness), initialTitle: "  Release notes  ", folderID: folder)
        } else {
            named = await f.model.createLocalACPSession(runtimeKind: .codex, initialTitle: "  Release notes  ", folderID: folder)
        }
        #expect(try await record(f, try #require(named)).title == "Release notes")
        let untitled = try await create(f, runtime: .codex, remote: remote)
        #expect(try await record(f, untitled).title == "New \(AgentRuntimeKind.codex.displayName) chat")

        let id = UUID().uuidString.lowercased()
        let providerID = remote ? "remote:\(f.remote.id.uuidString.lowercased()):codex" : "local:codex"
        let receipt = try await f.model.companionCommands.execute(.init(deviceID: f.device, kind: .createSession,
            conversationID: id, providerID: providerID, folderID: folder, title: "From a member"), deviceID: f.device)
        #expect(receipt.status == .completed, "\(receipt.message ?? "")")
        #expect(try await record(f, id).title == "From a member")
    }

    @Test func legacyUnappliedDefaultsAreNotRetriedWhenOpeningOrSending() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let id = try await create(f, runtime: .codex, remote: false)
        let chat = try await record(f, id)
        let count = await f.recorder.configurations.count
        f.model.sessionSelectionPreferences.stageCalendarSelections(id: id, harness: "codex", workspace: "local:" + f.directory.path,
            selections: .init(model: "old-unapplied-default"))
        await f.recorder.rejectConfiguration(true)
        await f.model.refreshLocalACPSession(conversation: chat)
        #expect(await f.model.sendAgentMessage(conversation: chat, input: .init(text: "No initial settings replay")))
        #expect(await f.recorder.configurations.count == count)
    }
}

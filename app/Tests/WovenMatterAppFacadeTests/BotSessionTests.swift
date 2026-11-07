import CompanionClient
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct BotSessionTests {
    @Test func botCreatesCoordinatesAndSendsWithoutASourceConversation() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let tools = try #require(fixture.model.agentTools)
        let installation = UUID().uuidString.lowercased()
        _ = try await tools.issueBotGrant(installationID: installation)
        let caller = WovenMCPCaller.bot(installationID: installation, botID: UUID().uuidString)
        try await fixture.database.registerBotCaller(caller, displayName: "Builder")
        let request = WovenMatterToolRequest(arguments: ["sessions", "create", "--title", "Bot child", "--text", "Initial work", "--purpose", "Fixture work", "--harness", "codex"])
        let result = await tools.handle(request, callerID: caller)
        #expect(result.success, "\(result.error ?? "")")
        #expect(await tools.handle(request, callerID: caller) == result)
        let child = try #require(try await fixture.database.workspaceOverview().conversations.first)
        #expect(child.title == "Bot child")
        #expect(try await fixture.database.workspaceOverview().conversations.count == 1)
        #expect(try await fixture.database.sessionRelationship(child.id).coordinatorID == caller)
        #expect(try await fixture.database.sessionRelationship(child.id).createdBy == caller)
        #expect(await fixture.recorder.deliveries.count == 1)
        let run = try #require(try await fixture.database.activeRunID(conversationID: child.id))
        try await fixture.database.completeLocalACPRun(runID: run)
        let notifications = try await fixture.database.collectCoordinationTurnNotifications()
        #expect(notifications.count == 1 && notifications.first?.targetID == caller)
        #expect(notifications.first?.text.contains("completed") == true)
        #expect(try await fixture.database.collectCoordinationTurnNotifications().isEmpty)
        try await fixture.database.setCoordinationNotifications(sourceID: caller, targetID: child.id, enabled: false)
        let independent = await tools.handle(.init(arguments: ["sessions", "create", "--title", "Independent", "--text", "Own work", "--purpose", "Fixture", "--harness", "codex", "--independent"]), callerID: caller)
        #expect(independent.success, "\(independent.error ?? "")")
        let other = try #require(try await fixture.database.workspaceOverview().conversations.first { $0.id != child.id })
        #expect(try await fixture.database.sessionRelationship(other.id).coordinatorID == nil)
        let context = await tools.handle(.init(arguments: ["context"]), callerID: caller)
        #expect(context.success && context.result == .null)
    }

    @Test(arguments: 0..<5) func revokingBotDuringSendPreparationPreventsProviderSubmission(attempt: Int) async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let tools = try #require(fixture.model.agentTools)
        let installation = UUID().uuidString.lowercased()
        _ = try await tools.issueBotGrant(installationID: installation)
        let caller = WovenMCPCaller.bot(installationID: installation, botID: UUID().uuidString)
        try await fixture.database.registerBotCaller(caller, displayName: "Builder")
        let target = try #require(await fixture.model.createLocalACPSession(runtimeKind: .codex))
        let gate = FacadeGate(); gate.hold(); defer { gate.open() }
        tools.companionFixtureMCPConnection = { _, local, _ in await gate.pass(); return local }
        let request = WovenMatterToolRequest(arguments: ["sessions", "send", target, "--text", "Revoked work"])
        let sending = Task { await tools.handle(request, callerID: caller) }
        await gate.waitForArrival()
        tools.revokeBotGrants(installationID: installation)
        gate.open()
        let result = await sending.value
        #expect(!result.success)
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(try await fixture.database.toolDelivery(id: request.requestID)?.status == "cancelled")
    }

    @Test func pairedMacDiscoveryResolvesForBotsOutsideAndConversationCallers() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.companionLibraryIdentity()
        let peer = UUID().uuidString.lowercased()
        let workspace = try await fixture.database.registerCompanionExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: peer,
            kind: .mac, name: "Paired Mac", endpoint: URL(string: "https://paired.fixture.ts.net/wovenmatter"))), deviceID: peer)
        let agent = try #require(try await fixture.database.dashboardAgents().first { $0.runtimeKind == .codex })
        try await fixture.database.write { connection in
            try connection.toolsExecuteUnlocked("UPDATE paired_agent_owners SET device_id=? WHERE id=?", [peer, agent.id.uuidString.lowercased()])
        }
        let bot = WovenMCPCaller.bot(installationID: UUID().uuidString, botID: UUID().uuidString)
        let command = try WovenMatterToolCommand(["sessions", "create", "--title", "Child", "--harness", "codex", "--workspace", workspace.id])
        for source in [WorkspaceToolCallerSource(callerID: bot), WorkspaceToolCallerSource(), WorkspaceToolCallerSource(callerID: UUID().uuidString)] {
            let configuration = try await fixture.model.resolveToolSessionCreation(source: source, command: command, title: "Child")
            #expect(configuration.pairedAgentID == agent.id)
            #expect(configuration.workspaceID == nil && configuration.nativeWorkingDirectory == nil)
            #expect(configuration.selectionWorkspace == workspace.id)
        }
        let installation = try #require(WovenMCPCaller.parseBot(bot)?.installationID)
        _ = try await fixture.model.agentTools?.issueBotGrant(installationID: installation)
        try await fixture.database.registerBotCaller(bot, displayName: "Cross-device bot")
        let discovery = try await fixture.model.handleSessionTool(callerID: bot, command: .init(["sessions", "harnesses"]), request: .init(arguments: ["sessions", "harnesses"]))
        #expect(discovery.result?.objectValue?["rows"]?.arrayValue?.contains { $0.objectValue?["workspace"] == .string(workspace.id) && $0.objectValue?["harness"] == .string("codex") } == true)
        let transport = BotPairedTransport(workspace: workspace)
        fixture.model.federatedExecutionClient = try CentralExecutionClient(database: fixture.database,
            commandJournalURL: fixture.directory.appending(path: "paired-bot-commands.json"),
            provision: { _ in .init(workspace: workspace, deviceID: identity.hostDeviceID, token: "fixture-only") },
            makeTransport: { _ in transport }, loadCredential: { _ in nil }, saveCredential: { _ in })
        let create = WovenMatterToolRequest(arguments: command.operationArguments + ["--text", "Remote work", "--purpose", "Cross-device fixture", "--model", "fixture-model"])
        let result = await fixture.model.agentTools?.handle(create, callerID: bot)
        #expect(result?.success == true, "\(result?.error ?? "")")
        let child = try #require(try await fixture.database.workspaceOverview().conversations.first)
        #expect(try await fixture.database.companionExecutionOwner(conversationID: child.id) == workspace.id)
        #expect(try await fixture.database.sessionRelationship(child.id).coordinatorID == bot)
        #expect(try await fixture.database.sessionRelationship(child.id).createdBy == bot)
        let commands = await transport.commands
        #expect(commands.map(\.kind) == [.createSession, .workspace, .workspace, .send])
        #expect(commands.last?.text == "Remote work")
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(try await fixture.database.workspaceOverview().conversations.count == 1)
        let status = await fixture.model.agentTools?.handle(.init(arguments: ["sessions", "status", child.id]), callerID: bot)
        #expect(status?.success == true, "\(status?.error ?? "")")
        let override = try WovenMatterToolCommand(command.operationArguments + ["--directory", "/unsupported"])
        await #expect(throws: (any Error).self) { _ = try await fixture.model.resolveToolSessionCreation(source: .init(callerID: bot), command: override, title: "Child") }
    }
}


private actor BotPairedTransport: ExecutionWorkspaceTransport {
    let workspace: CompanionExecutionWorkspace
    var commands: [CompanionCommand] = []
    var saved: [String: CompanionCommandReceipt] = [:]
    var chats: [CompanionConversation] = []
    init(workspace: CompanionExecutionWorkspace) { self.workspace = workspace }
    func identity() -> CompanionExecutionWorkspace { workspace }
    func providers() -> [CompanionProvider] { [.init(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true)] }
    func pending() -> [CompanionPendingInteraction] { [] }
    func receipt(_ id: String) -> CompanionCommandReceipt? { saved[id] }
    func conversations() -> [CompanionConversation] { chats }
    func capabilities(_ id: String) -> CompanionProvider { providers()[0] }
    func transcript(_ id: String) -> CompanionTranscript { .init(conversationID: id) }
    func events(after: Int64) -> CompanionJournalPage { .init(libraryID: workspace.libraryID, cursor: after, entries: []) }
    func command(_ command: CompanionCommand) throws -> CompanionCommandReceipt {
        if let prior = saved[command.commandID] { return prior }
        commands.append(command)
        if command.kind == .createSession, let id = command.conversationID {
            chats.append(.init(id: id, title: "Remote child", providerID: "local:codex", runtimeKind: "codex", libraryID: workspace.libraryID, workspaceID: workspace.id))
        }
        let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID,
            status: .completed, conversationID: command.conversationID, workspaceID: workspace.id)
        saved[command.commandID] = receipt
        return receipt
    }
}

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
        let machine = UUID().uuidString.lowercased(), botID = UUID().uuidString
        _ = try await tools.issueBotKey(machineID: machine, botID: botID, botName: "Builder")
        let caller = WovenMCPCaller.bot(machineID: machine, botID: botID)
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
        #expect(context.success && context.result == JSONValue.null)
    }

    /// A bot's own timers appear under the bot (its principal), never under a chat.
    @Test func aBotsOwnTimersAreListedUnderTheBotOnly() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let tools = try #require(fixture.model.agentTools)
        let machine = UUID().uuidString.lowercased(), botID = UUID().uuidString.lowercased()
        _ = try await tools.issueBotKey(machineID: machine, botID: botID, botName: "Builder")
        let caller = WovenMCPCaller.bot(machineID: machine, botID: botID)
        let formatter = ISO8601DateFormatter()
        for (text, offset) in [("Later", 7_200.0), ("Sooner", 600.0)] {
            let created = await tools.handle(.init(arguments: ["timers", "create", "--text", text, "--at",
                formatter.string(from: Date().addingTimeInterval(offset))]), callerID: caller)
            #expect(created.success, "\(created.error ?? "")")
        }
        try await tools.reload()
        #expect(tools.timers(forBot: botID, on: machine).map(\.instruction) == ["Sooner", "Later"])
        #expect(tools.timers(forBot: UUID().uuidString.lowercased(), on: machine).isEmpty)
        let chat = try #require(await fixture.model.createLocalACPSession(runtimeKind: .codex))
        #expect(!tools.timers.contains { $0.sessionID == chat })
        let paused = try #require(tools.timers(forBot: botID, on: machine).first)
        await tools.pauseTimer(paused, paused: true)
        #expect(tools.timers(forBot: botID, on: machine).map(\.instruction) == ["Later", "Sooner"])
    }

    @Test(arguments: 0..<5) func revokingBotDuringSendPreparationPreventsProviderSubmission(attempt: Int) async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let tools = try #require(fixture.model.agentTools)
        let machine = UUID().uuidString.lowercased(), botID = UUID().uuidString
        _ = try await tools.issueBotKey(machineID: machine, botID: botID, botName: "Builder")
        let caller = WovenMCPCaller.bot(machineID: machine, botID: botID)
        let target = try #require(await fixture.model.createLocalACPSession(runtimeKind: .codex))
        let gate = FacadeGate(); gate.hold(); defer { gate.open() }
        tools.facadeFixtureMCPConnection = { _, local in await gate.pass(); return local }
        let request = WovenMatterToolRequest(arguments: ["sessions", "send", target, "--text", "Revoked work"])
        let sending = Task { await tools.handle(request, callerID: caller) }
        await gate.waitForArrival()
        try tools.revokeBotKey(callerID: caller, sticky: true)
        gate.open()
        let result = await sending.value
        #expect(!result.success)
        #expect(await fixture.recorder.deliveries.isEmpty)
        #expect(try await fixture.database.toolDelivery(id: request.requestID)?.status == "cancelled")
    }
}

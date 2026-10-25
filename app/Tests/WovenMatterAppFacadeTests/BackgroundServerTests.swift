import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct BackgroundServerTests {
    @Test func legacyOffPreferenceCannotMakeTheProductionUIAnExecutionOwner() {
        #expect(LocalExecutionRole.resolve(arguments: [], backgroundEnabled: false) == .frontend)
        #expect(!LocalExecutionRole.frontend.ownsExecution)
        #expect(LocalExecutionRole.resolve(arguments: ["--backend"], backgroundEnabled: false) == .backend)
    }

    @Test func unconfirmedStopRechecksCurrentWorkWithoutCancellingIt() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let id = try await fixture.createConversation()
        let fence = fixture.model.beginAgentDispatch(conversationID: id)
        let response = await fixture.model.handleBackendRequest(.init(method: "server.stop",
            payload: try JSONEncoder().encode(BackgroundServerStopRequest())))
        #expect(response.error == nil)
        let result = try JSONDecoder().decode(BackgroundServerStopResult.self, from: #require(response.result))
        #expect(result.confirmationRequired)
        #expect(result.activeWorkCount > 0)
        #expect(!fixture.model.backendStopping)
        try fence.check()
        fixture.model.finishAgentDispatch(conversationID: id, fence: fence)
    }

    @Test func confirmedStopFencesPreparationBeforeShutdown() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        fixture.model.backgroundServerTermination = {}
        let id = try await fixture.createConversation()
        let fence = fixture.model.beginAgentDispatch(conversationID: id)
        let response = await fixture.model.handleBackendRequest(.init(method: "server.stop",
            payload: try JSONEncoder().encode(BackgroundServerStopRequest(confirmed: true))))
        #expect(response.error == nil)
        #expect(fixture.model.backendStopping)
        #expect(throws: (any Error).self) { try fence.check() }
        let refused = await fixture.model.handleBackendRequest(.init(method: "application.command"))
        #expect(refused.error != nil)
        fixture.model.finishAgentDispatch(conversationID: id, fence: fence)
    }
}

import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct BackgroundServerTests {

    @Test func confirmedStopFencesPreparationBeforeShutdown() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        #expect(fixture.model.readyForBackendClients)
        fixture.model.backgroundServerTermination = {}
        let id = try await fixture.createConversation()
        let fence = fixture.model.beginAgentDispatch(conversationID: id)
        let response = await fixture.model.handleBackendRequest(.init(method: "server.stop",
            payload: try JSONEncoder().encode(BackgroundServerStopRequest(confirmed: true))))
        #expect(response.error == nil)
        #expect(fixture.model.backendStopping)
        #expect(!fixture.model.readyForBackendClients)
        #expect(throws: (any Error).self) { try fence.check() }
        let refused = await fixture.model.handleBackendRequest(.init(method: "application.command"))
        #expect(refused.error != nil)
        fixture.model.finishAgentDispatch(conversationID: id, fence: fence)
    }
}

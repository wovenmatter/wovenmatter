import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore

struct ACPStopFailureTests {
    @Test func losingClientAfterFailedStopDoesNotAcknowledgeNativeCancellation() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare()
        await #expect(throws: Failure.self) { try await fixture.coordinator.stop(conversationID: fixture.id) }
        await fixture.coordinator.shutdown()
        do {
            try await fixture.coordinator.stop(conversationID: fixture.id)
            Issue.record("Missing native client must not clear an unconfirmed Stop")
        } catch {
            #expect(error.localizedDescription.contains("previous Stop was not confirmed"))
        }
        #expect(await fixture.state.attempts == 1)
    }

    private enum Failure: Error { case rejected }
    private actor State {
        var attempts = 0
        func stop() throws {
            attempts += 1
            if attempts == 1 { throw Failure.rejected }
        }
    }
    private struct Fixture {
        let persistence: PersistenceFixture
        let id: String
        let state: State
        let coordinator: LocalACPSessionCoordinator
        init() async throws {
            persistence = try PersistenceFixture()
            let database = try await persistence.openDatabase()
            id = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Stop fixture", ownerDeviceID: UUID())
            let state = State()
            self.state = state
            coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in
                LocalACPSessionDriver(
                    initializeSession: { _, existing, _, _ in
                        LocalACPInitializedSession(sessionID: existing ?? "fixture-native", loadedExistingSession: existing != nil,
                            configuration: LocalACPSessionConfiguration())
                    },
                    prompt: { _, _, _, _ in .endTurn },
                    configuration: { LocalACPSessionConfiguration() },
                    setConfiguration: { _, _ in LocalACPSessionConfiguration() },
                    cancel: { try await state.stop() }, shutdown: {}
                )
            })
        }
        func prepare() async throws {
            _ = try await coordinator.configuration(conversationID: id,
                launch: .init(runtimeKind: .codex, executableURL: URL(filePath: "/nonexistent-stop-fixture"), arguments: []),
                workspace: .init(rootURL: persistence.directory))
        }
        func cleanUp() { persistence.remove() }
    }
}

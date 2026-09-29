import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPStopFailureTests {
    @Test func sameNativeClientCanRetryARejectedStop() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.prepare()
        await #expect(throws: Failure.self) { try await fixture.coordinator.stop(conversationID: fixture.id) }
        try await fixture.coordinator.stop(conversationID: fixture.id)
        #expect(await fixture.state.attempts == 2)
        await fixture.coordinator.shutdown()
        // A confirmed stop can subsequently be idle without a retained client.
        try await fixture.coordinator.stop(conversationID: fixture.id)
    }

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
        let directory: URL
        let id: String
        let state: State
        let coordinator: LocalACPSessionCoordinator
        init() async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
            id = try await database.createLocalACPSession(runtimeKind: .codex, title: "Stop fixture", ownerDeviceID: UUID())
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
                workspace: .init(rootURL: directory, repositoriesURL: directory))
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}

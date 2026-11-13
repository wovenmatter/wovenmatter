#if os(macOS)
import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite(.timeLimit(.minutes(1)))
struct ACPSteeringLifecycleTests {

    @Test(arguments: ["uncertain", "uncertain-acp-relay", "uncertain-native-relay"])
    func uncertainNativeReceiptKeepsTheDurableInput(text: String) async throws {
        let f = try await SteeringFixture()
        defer { f.remove() }
        _ = try await f.start()
        await f.driver.waitForPrompt()
        await f.driver.setBeforeAdmission {
            let messages = try await f.messages()
            #expect(messages.last(where: { $0.role == "user" })?.content == text)
        }
        let input = try await f.coordinator.sendActiveInput(conversationID: f.id, input: .init(text: text))
        #expect(try await f.messages().contains { $0.id == input.userMessageID })
        await f.driver.finishInitial()
        try await f.waitForTerminal()
        #expect(try await f.messages().last?.status == "failed")
        await f.coordinator.shutdown()
    }

}

private struct SteeringFixture {
    let persistence: PersistenceFixture
    let database: WorkspaceDatabase
    let id: String
    let driver = SteeringDriver()
    let coordinator: LocalACPSessionCoordinator
    init() async throws {
        persistence = try PersistenceFixture()
        database = try await persistence.openDatabase()
        id = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Steering", ownerDeviceID: UUID())
        let driver = driver
        coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in driver.makeDriver() })
    }
    func start() async throws -> LocalACPRunIdentifiers {
        try await coordinator.accept(conversationID: id, input: .init(text: "start"),
            launch: .init(runtimeKind: .codex, executableURL: URL(filePath: "/fixture"), arguments: []),
            workspace: .init(rootURL: persistence.directory), onPermission: { _ in "allow" })
    }
    func messages() async throws -> [WorkspaceMessageRecord] { try await database.conversationContent(id: id).messages }
    func waitForTerminal() async throws {
        let settled = try await pollUntil(attempts: 500, interval: .milliseconds(10)) {
            try await !database.activeLocalConversationIDs().contains(id)
        }
        if !settled { Issue.record("The steered run did not settle") }
    }
    func remove() { persistence.remove() }
}

private actor SteeringDriver {
    let ready = AsyncStream<Void>.makeStream()
    let initial = AsyncStream<Void>.makeStream()
    var event: LocalACPClient.EventHandler?
    var beforeAdmission: (@Sendable () async throws -> Void)?
    func setBeforeAdmission(_ action: @escaping @Sendable () async throws -> Void) { beforeAdmission = action }
    nonisolated func makeDriver() -> LocalACPSessionDriver {
        LocalACPSessionDriver(
            initializeSession: { _, _, _, _ in .init(sessionID: "native", loadedExistingSession: false, configuration: .init()) },
            prompt: { _, event, _, _ in try await self.prompt(event) },
            configuration: { .init() }, setConfiguration: { _, _ in .init() },
            activeInput: { input in try await self.steer(input.text) },
            cancel: {}, shutdown: { await self.finishInitial() })
    }
    func prompt(_ event: LocalACPClient.EventHandler?) async throws -> LocalACPStopReason {
        self.event = event
        try await event?(.assistantChunk("before"))
        ready.continuation.yield(())
        for await _ in initial.stream { break }
        return .endTurn
    }
    func steer(_ text: String) async throws -> LocalACPActiveInputReceipt {
        try await beforeAdmission?()
        if text == "uncertain-acp-relay" { throw LocalACPClientError.deliveryUncertain("Lost receipt") }
        if text == "uncertain-native-relay" { throw LocalACPClientError.deliveryUncertain("Lost receipt") }
        if text == "uncertain" { throw LocalACPClientError.processExited }
        return .init(completion: Task { nil })
    }
    func waitForPrompt() async { for await _ in ready.stream { break } }
    func finishInitial() { initial.continuation.yield(()) }
}
#endif

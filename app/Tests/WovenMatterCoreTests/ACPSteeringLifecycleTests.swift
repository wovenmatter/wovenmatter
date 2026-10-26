import WorkspaceFixtures
import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

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
        let input = try await f.coordinator.sendActiveInput(conversationID: f.id, content: text)
        #expect(try await f.messages().contains { $0.id == input.userMessageID })
        await f.driver.finishInitial()
        try await f.waitForTerminal()
        #expect(try await f.messages().last?.status == "failed")
        await f.coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func toolDeliveryAuthorityIsCheckedBeforeNativeSteering(revoked: Bool) async throws {
        let f = try await SteeringFixture()
        defer { f.remove() }
        _ = try await f.start()
        await f.driver.waitForPrompt()
        let source = try await f.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Source", ownerDeviceID: UUID())
        try await f.database.setSessionTools(.init(enabled: [.sessions]), sessionID: source)
        let deliveryID = UUID().uuidString.lowercased()
        _ = try await f.database.reserveToolDelivery(sourceID: source, targetID: f.id, text: "correction", requestID: deliveryID)
        _ = try await f.database.claimToolDelivery(id: deliveryID)
        if revoked { try await f.database.setSessionTools(.init(enabled: []), sessionID: source) }
        let input = AgentMessageInput(text: "correction", historyDeliveryID: deliveryID)
        if revoked {
            await #expect(throws: WorkspaceToolError.self) {
                try await f.coordinator.sendActiveInput(conversationID: f.id, input: input)
            }
            #expect(await f.driver.received.isEmpty)
        } else {
            _ = try await f.coordinator.sendActiveInput(conversationID: f.id, input: input)
            #expect(await f.driver.received == ["correction"])
            #expect(try await f.database.toolDelivery(id: deliveryID)?.status == "accepted")
        }
        await f.driver.finishInitial()
        try await f.waitForTerminal()
        await f.coordinator.shutdown()
    }
}

private struct SteeringFixture {
    let root: URL
    let database: WorkspaceDatabase
    let id: String
    let driver = SteeringDriver()
    let coordinator: LocalACPSessionCoordinator
    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "steering-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        id = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Steering", ownerDeviceID: UUID())
        let driver = driver
        coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in driver.makeDriver() })
    }
    func start() async throws -> LocalACPRunIdentifiers {
        try await coordinator.accept(conversationID: id, content: "start",
            launch: .init(runtimeKind: .codex, executableURL: URL(filePath: "/fixture"), arguments: []),
            workspace: .init(rootURL: root), onPermission: { _ in "allow" })
    }
    func messages() async throws -> [WorkspaceMessageRecord] { try await database.conversationContent(id: id).messages }
    func execute(_ sql: String) throws {
        var connection: OpaquePointer?
        #expect(sqlite3_open(root.appending(path: "workspace.sqlite").path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw WorkspaceDatabaseError.execute("Fixture SQL failed")
        }
    }
    func waitForTerminal() async throws {
        for _ in 0..<500 {
            if try await !database.activeDeviceOwnedConversationIDs().contains(id) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The steered run did not settle")
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor SteeringDriver {
    let ready = AsyncStream<Void>.makeStream()
    let initial = AsyncStream<Void>.makeStream()
    let continuation = AsyncStream<Void>.makeStream()
    var event: LocalACPClient.EventHandler?
    var permission: LocalACPClient.PermissionHandler?
    var received: [String] = []
    var beforeAdmission: (@Sendable () async throws -> Void)?
    func setBeforeAdmission(_ action: @escaping @Sendable () async throws -> Void) { beforeAdmission = action }
    nonisolated func makeDriver() -> LocalACPSessionDriver {
        LocalACPSessionDriver(
            initializeSession: { _, _, _, _ in .init(sessionID: "native", loadedExistingSession: false, configuration: .init()) },
            prompt: { _, event, permission, _ in try await self.prompt(event, permission: permission) },
            configuration: { .init() }, setConfiguration: { _, _ in .init() },
            activeInput: { input in try await self.steer(input.text) },
            cancel: {}, shutdown: { await self.finishInitial(); await self.finishContinuation() })
    }
    func prompt(_ event: LocalACPClient.EventHandler?, permission: LocalACPClient.PermissionHandler?) async throws -> LocalACPStopReason {
        self.event = event
        self.permission = permission
        try await event?(.assistantChunk("before"))
        ready.continuation.yield(())
        for await _ in initial.stream { break }
        return .endTurn
    }
    func steer(_ text: String) async throws -> LocalACPActiveInputReceipt {
        try await beforeAdmission?()
        received.append(text)
        if text == "uncertain-acp-relay" { throw LocalACPClientError.deliveryUncertain("Lost receipt") }
        if text == "uncertain-native-relay" { throw LocalACPClientError.deliveryUncertain("Lost receipt") }
        if text == "uncertain" { throw LocalACPClientError.processExited }
        if text.hasPrefix("preflight") {
            try await event?(.assistantChunk(text == "preflight" ? "accepted output" : "rejected output"))
            let answer = await permission?(.init(title: "Native decision", options: [.init(id: "allow", name: "Allow", kind: "allow_once")]))
            #expect(answer == "allow")
            if text == "preflight-reject" { throw LocalACPSessionDatabaseError.steeringUnsupported }
        }
        if text == "reject" { throw LocalACPSessionDatabaseError.steeringUnsupported }
        if text == "continuation" {
            return .init(completion: Task { for await _ in self.continuation.stream { break }; return .endTurn })
        }
        return .init(completion: Task { nil })
    }
    func emit(_ value: LocalACPEvent) async throws { try await event?(value) }
    func waitForPrompt() async { for await _ in ready.stream { break } }
    func finishInitial() { initial.continuation.yield(()) }
    func finishContinuation() { continuation.continuation.yield(()) }
}

import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite(.timeLimit(.minutes(1)))
struct ACPSteeringLifecycleTests {
    @Test func outputAndDecisionBeforeAdmissionDoNotDeadlockOrLeakAcrossSegments() async throws {
        let f = try SteeringFixture()
        defer { f.remove() }
        _ = try await f.start()
        await f.driver.waitForPrompt()
        _ = try await f.coordinator.sendActiveInput(conversationID: f.id, content: "preflight")
        await #expect(throws: LocalACPSessionDatabaseError.steeringUnsupported) {
            try await f.coordinator.sendActiveInput(conversationID: f.id, content: "preflight-reject")
        }
        await f.driver.finishInitial()
        try await f.waitForTerminal()
        #expect(try f.messages().filter { $0.role == "user" }.map(\.content) == ["start", "preflight"])
        #expect(try f.messages().filter { $0.role == "assistant" }.map(\.content) == ["before", "accepted outputrejected output"])
        await f.coordinator.shutdown()
    }
    @Test func repeatedSteersKeepOneRunAndRejectedInputDoesNotEnterHistory() async throws {
        let f = try SteeringFixture()
        defer { f.remove() }
        let run = try await f.start()
        await f.driver.waitForPrompt()
        await #expect(throws: LocalACPSessionDatabaseError.steeringUnsupported) {
            try await f.coordinator.sendActiveInput(conversationID: f.id, content: "reject")
        }
        #expect(try f.messages().filter { $0.role == "user" }.map(\.content) == ["start"])
        // A rejected boundary must leave cumulative snapshot replacement intact.
        try await f.driver.emit(.assistantSnapshot("before continued"))
        for text in ["first", "second", "third"] {
            let input = try await f.coordinator.sendActiveInput(conversationID: f.id, content: text)
            #expect(input.runID == run.runID)
            try await f.driver.emit(.assistantChunk("reply to \(text)"))
        }
        await f.driver.finishInitial()
        try await f.waitForTerminal()
        #expect(try f.messages().filter { $0.role == "user" }.map(\.content) == ["start", "first", "second", "third"])
        #expect(try f.messages().filter { $0.role == "assistant" }.map(\.content) == ["before continued", "reply to first", "reply to second", "reply to third"])
        #expect(Set(try f.messages().compactMap(\.runID)) == [run.runID])
        await f.coordinator.shutdown()
    }

    @Test func originalCompletionDoesNotCloseAnAcceptedContinuation() async throws {
        let f = try SteeringFixture()
        defer { f.remove() }
        _ = try await f.start()
        await f.driver.waitForPrompt()
        _ = try await f.coordinator.sendActiveInput(conversationID: f.id, content: "continuation")
        await f.driver.finishInitial()
        try await f.driver.emit(.assistantChunk("continued work"))
        #expect(try f.database.activeDeviceOwnedConversationIDs().contains(f.id))
        await f.driver.finishContinuation()
        try await f.waitForTerminal()
        #expect(try f.messages().last?.content == "continued work")
        await f.coordinator.shutdown()
    }

    @Test func stopRejectsFurtherSteeringWithoutPersistingIt() async throws {
        let f = try SteeringFixture()
        defer { f.remove() }
        _ = try await f.start()
        await f.driver.waitForPrompt()
        await f.coordinator.cancel(conversationID: f.id)
        await #expect(throws: LocalACPSessionDatabaseError.steeringUnsupported) {
            try await f.coordinator.sendActiveInput(conversationID: f.id, content: "after stop")
        }
        #expect(try f.messages().filter { $0.role == "user" }.map(\.content) == ["start"])
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
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "steering-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        id = try database.createLocalACPSession(runtimeKind: .codex, title: "Steering", ownerDeviceID: UUID())
        let driver = driver
        coordinator = LocalACPSessionCoordinator(database: database, clientFactory: { _, _ in driver.makeDriver() })
    }
    func start() async throws -> LocalACPRunIdentifiers {
        try await coordinator.accept(conversationID: id, content: "start",
            launch: .init(runtimeKind: .codex, executableURL: URL(filePath: "/fixture"), arguments: []),
            workspace: .init(rootURL: root, repositoriesURL: root), onPermission: { _ in "allow" })
    }
    func messages() throws -> [WorkspaceMessageRecord] { try database.conversationContent(id: id).messages }
    func waitForTerminal() async throws {
        for _ in 0..<500 {
            if try !database.activeDeviceOwnedConversationIDs().contains(id) { return }
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

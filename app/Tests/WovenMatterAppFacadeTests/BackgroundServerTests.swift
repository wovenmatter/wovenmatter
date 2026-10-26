import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct BackgroundServerTests {
    @Test func missingLeaseDoesNotCreateAnOwnerOrAFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(try !WovenMatterBackendProcess.executionOwnerIsPresent(leaseURL: file))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unresponsiveOwnerStaysPresentUntilItsProcessReleasesTheLease() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let owner = Process(), input = Pipe(), output = Pipe()
        owner.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        owner.arguments = ["-c", """
        import fcntl, sys
        with open(sys.argv[1], 'w+') as file:
            fcntl.lockf(file, fcntl.LOCK_EX)
            print('ready', flush=True)
            sys.stdin.read(1)
        """, file.path]
        owner.standardInput = input; owner.standardOutput = output
        try owner.run()
        defer { if owner.isRunning { owner.terminate(); owner.waitUntilExit() } }
        #expect(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).contains("ready"))
        // No RPC endpoint exists, but another process still owns execution.
        #expect(try WovenMatterBackendProcess.executionOwnerIsPresent(leaseURL: file))
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        owner.waitUntilExit()
        #expect(try !WovenMatterBackendProcess.executionOwnerIsPresent(leaseURL: file))
        #expect(FileManager.default.fileExists(atPath: file.path))
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

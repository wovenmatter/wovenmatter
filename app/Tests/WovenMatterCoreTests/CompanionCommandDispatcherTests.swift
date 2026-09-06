import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct CompanionCommandDispatcherTests {
    @Test @MainActor func changedPayloadRejectedBeforeAndAfterFinishAndLostAckRetryDoesNotExecute() async throws {
        let fixture = try CompanionCommandFixture()
        defer { fixture.remove() }
        let dispatcher = CompanionCommandDispatcher(database: fixture.database)
        let request = CompanionCommand(deviceID: UUID().uuidString, kind: .send,
            conversationID: UUID().uuidString, text: "First")
        let gate = CompanionCommandGate()
        let first = Task { try await dispatcher.execute(request) { receipt in
            await gate.wait()
            var result = receipt
            result.runID = "only-run"
            return result
        } }
        for _ in 0..<200 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started)
        var changed = request; changed.text = "Different request under the same ID"
        let during = try await dispatcher.execute(changed) { _ in
            Issue.record("Changed request executed")
            return .init(commandID: changed.commandID, deviceID: changed.deviceID, status: .completed)
        }
        #expect(during.status == .rejected)
        #expect(try dispatcher.receipt(commandID: request.commandID, deviceID: request.deviceID)?.status == .accepted)
        first.cancel() // The HTTP caller went away; the command itself must keep running.
        await gate.release()
        let accepted = try await first.value
        #expect(accepted.status == .completed)
        #expect(accepted.runID == "only-run")
        let after = try await dispatcher.execute(changed) { _ in
            Issue.record("Changed request executed after completion")
            return during
        }
        #expect(after.status == .rejected)
        let retry = try await dispatcher.execute(request) { receipt in
            Issue.record("Lost-ack retry executed twice")
            return receipt
        }
        #expect(retry == accepted)
        let reopened = try WorkspaceDatabase(url: fixture.url)
        let restarted = CompanionCommandDispatcher(database: reopened)
        let recovered = try await restarted.execute(request) { receipt in
            Issue.record("Restart reexecuted completed command")
            return receipt
        }
        #expect(recovered == accepted)
    }

    @Test @MainActor func interruptedAcceptanceIsVisibleAndNeverRedispatched() async throws {
        let fixture = try CompanionCommandFixture()
        defer { fixture.remove() }
        let request = CompanionCommand(deviceID: UUID().uuidString, kind: .send,
            conversationID: UUID().uuidString, text: "May have run")
        #expect(try fixture.database.reserveCompanionCommand(request).isNew)
        let restarted = CompanionCommandDispatcher(database: try WorkspaceDatabase(url: fixture.url))
        #expect(try restarted.receipt(commandID: request.commandID, deviceID: request.deviceID)?.status == .outcomeUnknown)
        let retry = try await restarted.execute(request) { receipt in
            Issue.record("Indeterminate command was reexecuted")
            return receipt
        }
        #expect(retry.status == .outcomeUnknown)
    }
}

private struct CompanionCommandFixture {
    let directory: URL
    let url: URL
    let database: WorkspaceDatabase
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "workspace.sqlite")
        database = try WorkspaceDatabase(url: url)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor CompanionCommandGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

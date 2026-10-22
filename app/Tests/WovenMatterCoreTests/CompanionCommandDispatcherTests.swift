import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct CompanionCommandDispatcherTests {
    @Test @MainActor func interruptedAcceptanceIsVisibleAndNeverRedispatched() async throws {
        let fixture = try await CompanionCommandFixture()
        defer { fixture.remove() }
        let request = CompanionCommand(deviceID: UUID().uuidString, kind: .send,
            conversationID: UUID().uuidString, text: "May have run")
        #expect(try await fixture.database.reserveCompanionCommand(request).isNew)
        let restarted = CompanionCommandDispatcher(database: try await WorkspaceDatabase(url: fixture.url))
        #expect(try await restarted.receipt(commandID: request.commandID, deviceID: request.deviceID)?.status == .outcomeUnknown)
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
    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "workspace.sqlite")
        database = try await WorkspaceDatabase(url: url)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

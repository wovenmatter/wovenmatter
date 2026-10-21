import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

struct ExecutorTests {
    @Test func appSelectionPreservesToolRevocationDuringScopeSynchronization() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let session = try await database.createLocalACPSession(runtimeKind: .codex, title: "Scope edit", ownerDeviceID: UUID())
        // The selection request captures its policy, then waits for the server.
        let before = try await database.sessionTools(session)
        #expect(before.enabled.contains(.library))
        _ = try await database.setSessionToolEnabled(.library, enabled: false, sessionID: session)
        try await database.setSessionExecutorProfiles(["app:profile"], sessionID: session)
        let after = try await database.sessionTools(session)
        #expect(!after.enabled.contains(.library))
        #expect(after.executorProfiles == ["app:profile"])
    }
    @Test func conversationAppsSnapshotDefaultsAndPersistAcrossReload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let existing = try await database.createLocalACPSession(runtimeKind: .codex, title: "Existing", ownerDeviceID: UUID())
        var settings = try await database.toolSettings()
        var config = ExecutorConfiguration(); config.defaultProfiles = ["a:profile"]
        settings.executor = config; settings.enabledByDefault.insert(.executor)
        try await database.saveToolSettings(settings)
        let first = try await database.createLocalACPSession(runtimeKind: .claudeCode, title: "First", ownerDeviceID: UUID())
        #expect(try await database.sessionTools(existing).executorProfiles == [])
        #expect(try await database.sessionTools(first).executorProfiles == ["a:profile"])
        settings.executor?.defaultProfiles = ["b:profile"]
        try await database.saveToolSettings(settings)
        #expect(try await database.sessionTools(first).executorProfiles == ["a:profile"])
        var policy = try await database.sessionTools(first); policy.executorProfiles = []
        try await database.setSessionTools(policy, sessionID: first)
        try await database.applyInitialSessionTools(.init(enabled: [.executor], executorProfiles: ["b:profile"]), sessionID: first)
        #expect(try await database.sessionTools(first).executorProfiles == [])
        let second = try await database.createLocalACPSession(runtimeKind: .codex, title: "Second", ownerDeviceID: UUID())
        #expect(try await database.sessionTools(second).executorProfiles == ["b:profile"])
    }
    @Test func executorCLIHasNoAuthorityOrResumeOptions() throws {
        #expect(try WovenMatterToolCommand(["executor", "execute", "--code", "return 1;"]).isMutation)
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["executor", "execute", "--code", "return 1;", "--permission", "full"]) }
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["executor", "resume", "secret"]) }
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["executor", "execute", "--code", "return 1;", "--file", "/tmp/code.js"]) }
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["executor", "status", "id", "--session", "other"]) }
    }

}

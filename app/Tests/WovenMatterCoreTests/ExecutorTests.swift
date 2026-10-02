import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

struct ExecutorTests {
    @Test func confirmedHarnessModesPreserveTheirMeaning() {
        let full: [(AgentRuntimeKind, String)] = [(.defaultAgent, "full"), (.codex, "agent-full-access"), (.claudeCode, "bypassPermissions"), (.grokBuild, "bypassPermissions"), (.cursor, "auto"), (.opencode, "full"), (.hermes, "full"), (.openclaw, "full")]
        for (runtime, mode) in full {
            #expect(ExecutorApprovalPolicy.resolve(runtime: runtime, mode: mode) == .full)
            #expect(ExecutorApprovalPolicy.resolve(runtime: runtime, mode: mode, confirmed: false) == .ask)
        }
        for (runtime, mode) in [(AgentRuntimeKind.claudeCode, "auto"), (.claudeCode, "acceptEdits"), (.grokBuild, "auto"), (.grokBuild, "acceptEdits"), (.codex, "agent"), (.hermes, "default"), (.openclaw, "workspace"), (.opencode, "acceptEdits"), (.pi, "full")] {
            #expect(ExecutorApprovalPolicy.resolve(runtime: runtime, mode: mode) == .ask)
        }
        #expect(ExecutorApprovalPolicy.resolve(runtime: .claudeCode, mode: "dontAsk") == .deny)
        #expect(ExecutorApprovalPolicy.resolve(runtime: .codex, mode: "read-only") == .ask)
        #expect(ExecutorApprovalPolicy.resolve(runtime: .openclaw, mode: "read-only") == .deny)
    }
    @Test func legacyPreferencesDecodeWithoutEnablingExecutor() throws {
        let old = Data(#"{"enabledByDefault":["notes","library"],"calendarAccess":"full","maximumManagedSessions":4,"maximumRunningSessions":16}"#.utf8)
        let settings = try JSONDecoder().decode(WorkspaceToolSettings.self, from: old)
        #expect(settings.executor == nil)
        #expect(!WorkspaceToolSettings().enabledByDefault.contains(.executor))
        let defaults = DefaultAgentSettings()
        var saved = try JSONEncoder().encode(defaults)
        var value = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        value.removeValue(forKey: "codeMode")
        saved = try JSONSerialization.data(withJSONObject: value)
        #expect(try JSONDecoder().decode(DefaultAgentSettings.self, from: saved).resolvedCodeMode == .on)
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
        let first = try await database.createLocalACPSession(runtimeKind: .hermes, title: "First", ownerDeviceID: UUID())
        #expect(try await database.sessionTools(existing).executorProfiles == [])
        #expect(try await database.sessionTools(first).executorProfiles == ["a:profile"])
        settings.executor?.defaultProfiles = ["b:profile"]
        try await database.saveToolSettings(settings)
        #expect(try await database.sessionTools(first).executorProfiles == ["a:profile"])
        var policy = try await database.sessionTools(first); policy.executorProfiles = []
        try await database.setSessionTools(policy, sessionID: first)
        try await database.applyInitialSessionTools(.init(enabled: [.executor], executorProfiles: ["b:profile"]), sessionID: first)
        #expect(try await database.sessionTools(first).executorProfiles == [])
        let second = try await database.createLocalACPSession(runtimeKind: .pi, title: "Second", ownerDeviceID: UUID())
        #expect(try await database.sessionTools(second).executorProfiles == ["b:profile"])
    }
    @Test func executorCLIHasNoAuthorityOrResumeOptions() throws {
        #expect(try WovenMatterToolCommand(["executor", "execute", "--code", "return 1;"]).isMutation)
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["executor", "execute", "--code", "return 1;", "--permission", "full"]) }
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["executor", "resume", "secret"]) }
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["executor", "execute", "--code", "return 1;", "--file", "/tmp/code.js"]) }
        #expect(throws: (any Error).self) { try WovenMatterToolCommand(["executor", "status", "id", "--session", "other"]) }
    }
    @Test func staleDefaultsEditPreservesCurrentSetupAndInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        var config = ExecutorConfiguration()
        let first = ExecutorAppProfile(id: "first:p", app: "first", name: "First", profile: "p", profileName: "Default")
        let second = ExecutorAppProfile(id: "second:p", app: "second", name: "Second", profile: "p", profileName: "Default")
        config.apps = [first]
        try await database.updateExecutor(configuration: config)
        let base = try await database.toolSettings()
        var edited = base; edited.executor?.defaultProfiles = [first.id]; edited.maximumManagedSessions = 6
        try await database.updateExecutor(apps: [first, second], setup: .init(configuration: config, running: true))
        try await database.saveToolSettings(edited, from: base)
        let saved = try await database.toolSettings()
        #expect(saved.executor?.apps == [first, second])
        #expect(saved.executor?.defaultProfiles == [first.id])
        #expect(saved.executorSetup?.running == true)
        #expect(saved.maximumManagedSessions == 6)
        var replacement = ExecutorConfiguration(); replacement.apps = [second]
        try await database.updateExecutor(configuration: replacement)
        try await database.saveToolSettings(edited, from: base)
        #expect(try await database.toolSettings().executor?.id == replacement.id)
        #expect(try await database.toolSettings().executor?.defaultProfiles == [])
    }

}

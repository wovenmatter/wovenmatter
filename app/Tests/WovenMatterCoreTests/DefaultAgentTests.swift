import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Built-in settings and recovery")
struct DefaultAgentTests {
    @Test func modelChoicesAreOptInAndDefaultRemainsAvailable() {
        let catalog = ["openai/gpt", "openrouter/anthropic/claude", "opencode-go/glm"]
        #expect(DefaultAgentModelCatalog.visibleIDs(explicit: [], defaultModel: catalog[1], catalog: catalog) == [catalog[1]])
        #expect(DefaultAgentModelCatalog.visibleIDs(explicit: [catalog[2]], defaultModel: catalog[1], catalog: catalog) == [catalog[1], catalog[2]])
        #expect(DefaultAgentModelCatalog.visibleIDs(explicit: [], defaultModel: nil, catalog: catalog) == [catalog[0]])
        #expect(DefaultAgentModelCatalog.visibleIDs(explicit: [catalog[2], catalog[1]], defaultModel: catalog[1], catalog: catalog) == [catalog[2], catalog[1]])
    }
    @Test func labsAreSharedAcrossConnectionTypes() {
        for id in ["anthropic/claude-sonnet-4", "claude-subscription/sonnet", "openrouter/anthropic/claude-sonnet", "opencode-go/claude-sonnet-4"] {
            #expect(DefaultAgentModelCatalog.lab(id: id, name: "Claude Sonnet") == "Anthropic")
        }
        for id in ["openai-codex/gpt-5", "openai/o3", "openrouter/openai/gpt-5", "opencode-go/gpt-5"] {
            #expect(DefaultAgentModelCatalog.lab(id: id, name: "Reasoning model") == "OpenAI")
        }
        #expect(DefaultAgentModelCatalog.lab(id: "openrouter/google/gemini-3", name: "Gemini") == "Google")
        #expect(DefaultAgentModelCatalog.lab(id: "opencode-go/glm-5", name: "GLM") == "Z.ai")
        #expect(DefaultAgentModelCatalog.lab(id: "openrouter/unknown/model", name: "Unknown") == "Other")
    }
    @Test func workspaceOverridesRemainIndependent() throws {
        var settings = DefaultAgentSettingsScope()
        settings.global.defaultModel = "openai-codex/primary"
        settings.global.fallbackModels = ["openrouter/fallback"]
        settings.workspaces["remote"] = settings.global
        settings.workspaces["remote"]?.defaultModel = "opencode-go/other"
        settings.global.defaultModel = "openai/new"
        let restored = try JSONDecoder().decode(DefaultAgentSettingsScope.self, from: JSONEncoder().encode(settings))
        #expect(restored.resolved("local").defaultModel == "openai/new")
        #expect(restored.resolved("remote").defaultModel == "opencode-go/other")
        #expect(restored.resolved("remote").fallbackModels == ["openrouter/fallback"])
        settings.workspaces.removeValue(forKey: "remote")
        #expect(settings.resolved("remote") == settings.global)
    }

    @Test func completedRemoteRunsRecoverOnlyTheirOwnConversationOnce() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "woven-default-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let owner = UUID()
        let first = try database.createLocalACPSession(runtimeKind: .defaultAgent, title: "First", ownerDeviceID: owner)
        let second = try database.createLocalACPSession(runtimeKind: .defaultAgent, title: "Second", ownerDeviceID: owner)
        let run = try database.beginLocalACPRun(conversationID: first, content: "Work remotely")
        try database.completeLocalACPRun(runID: run.runID, error: "Disconnected")
        let snapshot = DefaultAgentRunSnapshot(runID: run.runID, content: "Finished remotely", model: "openrouter/fallback")
        try database.recoverRemoteAgentRuns(conversationID: second, snapshots: [snapshot])
        #expect(try database.conversationHistoryPage(id: first, limit: 20).runs.first?.status == "failed")
        try database.recoverRemoteAgentRuns(conversationID: first, snapshots: [snapshot])
        let recovered = try database.conversationHistoryPage(id: first, limit: 20)
        #expect(recovered.runs.first?.status == "completed")
        #expect(recovered.messages.first { $0.id == run.assistantMessageID }?.content == "Finished remotely")
        try database.recoverRemoteAgentRuns(conversationID: first, snapshots: [.init(runID: run.runID, content: "stale")])
        #expect(try database.conversationHistoryPage(id: first, limit: 20) == recovered)
        let external = try database.createLocalACPSession(runtimeKind: .pi, title: "External Pi", ownerDeviceID: owner)
        #expect(throws: (any Error).self) { try database.recoverRemoteAgentRuns(conversationID: external, snapshots: [snapshot]) }
    }
}

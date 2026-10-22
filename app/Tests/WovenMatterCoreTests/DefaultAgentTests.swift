import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Built-in settings and recovery")
struct DefaultAgentTests {
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

}

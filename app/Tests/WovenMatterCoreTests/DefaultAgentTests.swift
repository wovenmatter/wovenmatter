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
}

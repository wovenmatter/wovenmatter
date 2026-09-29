import Testing
import WovenMatterCore

@Suite("Concurrent Built-in settings edits")
struct DefaultAgentSettingsMergeTests {
    @Test func settingsEditPreservesConcurrentServerAdditionAndItsModel() {
        var base = DefaultAgentSettings()
        base.models = ["openai/one"]
        var saved = base
        saved.providers.append("local-new")
        saved.models.append("local-new/model")
        var edited = base
        edited.providers.removeAll { $0 == "anthropic" }
        edited.models.append("openai/two")
        edited.defaultModel = "openai/two"
        let merged = saved.applyingChanges(from: base, to: edited)
        #expect(merged.providers.contains("local-new"))
        #expect(!merged.providers.contains("anthropic"))
        #expect(merged.models == ["openai/one", "openai/two", "local-new/model"])
        #expect(merged.defaultModel == "openai/two")
    }
    @Test func settingsEditDoesNotRestoreRemovedServerOrItsModelChoices() {
        var base = DefaultAgentSettings()
        base.providers.append("local-old")
        base.models = ["openai/one", "local-old/model", "openai/two"]
        base.fallbackModels = ["local-old/model", "openai/one", "openai/two"]
        base.defaultModel = "local-old/model"
        var saved = base
        saved.providers.removeAll { $0 == "local-old" }
        saved.models.removeAll { $0.hasPrefix("local-old/") }
        saved.fallbackModels.removeAll { $0.hasPrefix("local-old/") }
        saved.defaultModel = nil
        var edited = base
        edited.providers.removeAll { $0 == "anthropic" }
        edited.models.swapAt(0, 2)
        edited.fallbackModels.swapAt(1, 2)
        let merged = saved.applyingChanges(from: base, to: edited)
        #expect(!merged.providers.contains("local-old"))
        #expect(!merged.providers.contains("anthropic"))
        #expect(merged.models == ["openai/two", "openai/one"])
        #expect(merged.fallbackModels == ["openai/two", "openai/one"])
        #expect(merged.defaultModel == nil)
    }
    @Test func staleSettingsEditPreservesOtherFieldsAndExplicitRemoval() {
        var base = DefaultAgentSettings()
        base.models = ["openai/one", "openai/two"]
        var saved = base
        saved.defaultModel = "openai/two"
        saved.searchProvider = "brave"
        var edited = base
        edited.models.removeAll { $0 == "openai/one" }
        let merged = saved.applyingChanges(from: base, to: edited)
        #expect(merged.models == ["openai/two"])
        #expect(merged.defaultModel == "openai/two")
        #expect(merged.searchProvider == "brave")
    }
}

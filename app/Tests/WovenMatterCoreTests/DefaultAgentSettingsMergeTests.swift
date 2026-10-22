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

}

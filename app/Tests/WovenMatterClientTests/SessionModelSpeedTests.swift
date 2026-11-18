import Testing
@testable import WovenMatterClient

struct SessionModelSpeedTests {
  private let options = [
    "claude-subscription/opus", "claude-subscription/opus#fast", "claude-subscription/sonnet",
    "openai-codex/gpt-6.2-sol", "openai-codex/gpt-6.2-sol#fast", "openai-codex/gpt-6.2-sol#ultrafast",
    "openai-codex/gpt-6.2-astra", "openai-codex/gpt-6.2-astra#fast",
  ]

  private func metadata(_ model: String) -> LocalACPSessionMetadata {
    LocalACPSessionMetadata(sessionKey: "fixture", model: model, thinking: nil, modelOptions: options)
  }

  @Test func speedVariantsParseOnlyForSubscriptionModels() {
    let ultrafast = SessionModelSpeed.split("openai-codex/gpt-6.2-sol#ultrafast")
    #expect(ultrafast.model == "openai-codex/gpt-6.2-sol" && ultrafast.speed == "ultrafast")
    let fast = SessionModelSpeed.split("claude-subscription/opus#fast")
    #expect(fast.model == "claude-subscription/opus" && fast.speed == "fast")
    for id in ["openai/gpt#fast", "claude-subscription/opus#priority", "opus#fast", "claude-subscription/opus"] {
      let parts = SessionModelSpeed.split(id)
      #expect(parts.model == id && parts.speed == nil)
    }
    #expect(SessionModelSpeed.label("openai-codex/gpt-6.2-sol#ultrafast") == "Ultrafast")
    #expect(SessionModelSpeed.label("openai-codex/gpt-6.2-sol") == "Standard")
  }

  @Test func modelMenuShowsEachModelOnceAndKeepsTheSelectedSpeed() {
    let standard = metadata("openai-codex/gpt-6.2-sol")
    #expect(standard.selectableModels == ["claude-subscription/opus", "claude-subscription/sonnet",
      "openai-codex/gpt-6.2-sol", "openai-codex/gpt-6.2-astra"])
    #expect(standard.selectableSpeeds == ["openai-codex/gpt-6.2-sol", "openai-codex/gpt-6.2-sol#fast", "openai-codex/gpt-6.2-sol#ultrafast"])
    let fast = metadata("claude-subscription/opus#fast")
    #expect(fast.selectableModels.first == "claude-subscription/opus#fast")
    #expect(fast.selectableSpeeds == ["claude-subscription/opus", "claude-subscription/opus#fast"])
    #expect(metadata("claude-subscription/sonnet").selectableSpeeds.isEmpty)
  }

  @Test func choosingAnotherModelCarriesSpeedOnlyWhereOffered() {
    let ultrafast = metadata("openai-codex/gpt-6.2-sol#ultrafast")
    #expect(ultrafast.modelChoice("openai-codex/gpt-6.2-astra") == "openai-codex/gpt-6.2-astra")
    #expect(ultrafast.modelChoice("openai-codex/gpt-6.2-sol#ultrafast") == "openai-codex/gpt-6.2-sol#ultrafast")
    let fast = metadata("openai-codex/gpt-6.2-sol#fast")
    #expect(fast.modelChoice("openai-codex/gpt-6.2-astra") == "openai-codex/gpt-6.2-astra#fast")
    #expect(fast.modelChoice("claude-subscription/sonnet") == "claude-subscription/sonnet")
    #expect(metadata("openai-codex/gpt-6.2-sol").modelChoice("claude-subscription/opus") == "claude-subscription/opus")
  }
}

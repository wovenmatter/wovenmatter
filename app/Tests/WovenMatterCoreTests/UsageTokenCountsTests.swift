import Testing
import WovenMatterCore

@Suite("Usage token counts")
struct UsageTokenCountsTests {
  @Test("total input includes uncached, cache reads, and cache writes")
  func totalInput() {
    let tokens = UsageTokenCounts(
      inputTokens: 100,
      cachedInputTokens: 300,
      cacheCreationTokens: 25,
      outputTokens: 50
    )

    #expect(tokens.totalInputTokens == 425)
    #expect(tokens.totalTokens == 475)
  }
}

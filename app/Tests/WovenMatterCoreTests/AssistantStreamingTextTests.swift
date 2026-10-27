import Testing
import WovenMatterCore

struct AssistantStreamingTextTests {
  @Test func terminalRunFlushesStaleStreamingMessage() {
    #expect(AssistantStreamingText.isStreaming(messageStatus: "streaming", runStatus: "running"))
    #expect(AssistantStreamingText.isStreaming(messageStatus: "streaming", runStatus: nil))
    for terminal in ["completed", "cancelled", "failed", "uncertain"] {
      #expect(!AssistantStreamingText.isStreaming(messageStatus: "streaming", runStatus: terminal))
    }
    #expect(!AssistantStreamingText.isStreaming(messageStatus: "complete", runStatus: "running"))
  }
  @Test func stableMarkdownBoundaries() {
    for (input, ready) in [
      ("partial", ""),
      ("First\n\nSec", "First\n\n"),
      ("Intro\n\n```swift\nx()\n\n", "Intro\n\n"),
      ("```swift\nx()\n```\nrest", "```swift\nx()\n```\n"),
      ("- One\n- Two", "- One\n"),
      ("### Title\n\n", ""),
      ("### Title\n\nBody\n\nunfinished", "### Title\n\nBody\n\n"),
      ("Café 🧵\n\u{a0}\nunfinished", ""),
      ("    ~~~swift\nx()\n        ~~~\n", ""),
      ("    ~~~swift\nx()\n    ~~~\nrest", "    ~~~swift\nx()\n    ~~~\n"),
    ] { #expect(AssistantStreamingText.readyPrefix(of: input) == ready) }
  }

  @Test func liveReasoningPreviewKeepsProviderHeadingOrFirstSentence() {
    for (source, expected) in [
      ("**Checking the stream**\n\nI will inspect the events.", "Checking the stream"),
      ("Inspecting `events` and **tool calls**. Then I will compare them.", "Inspecting events and tool calls."),
      ("### Comparing models\n- OpenAI and [Anthropic](https://example.com)", "Comparing models OpenAI and Anthropic"),
      ("A Unicode trace 🧵 stays intact! Another thought.", "A Unicode trace 🧵 stays intact!"),
      ("  \n\t", ""),
    ] {
      #expect(AssistantStreamingText.reasoningPreview(of: source) == expected)
    }
    #expect(AssistantStreamingText.reasoningPreview(of: String(repeating: "x", count: 100_000)).count == 2_000)
  }

}

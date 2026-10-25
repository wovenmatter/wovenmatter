import Testing
import WovenMatterCore

struct AssistantStreamingTextTests {
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

}

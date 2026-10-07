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

  @Test func replacementsAreAtomicAndResettable() {
    var assembler = NativeTextSnapshotAssembler()
    #expect(assembler.receive("orphan", starts: false, ends: true) == nil)
    #expect(assembler.receive("Café ", starts: true, ends: false) == nil)
    #expect(assembler.receive("🧵", starts: false, ends: true) == "Café 🧵")
    #expect(assembler.receive("unfinished", starts: true, ends: false) == nil)
    assembler.reset()
    #expect(assembler.receive("tail", starts: false, ends: true) == nil)
    #expect(assembler.receive("", starts: true, ends: true) == "")
  }
}

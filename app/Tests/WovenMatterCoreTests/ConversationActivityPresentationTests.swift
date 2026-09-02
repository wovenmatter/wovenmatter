import Testing
import WovenMatterCore

@Suite("Conversation activity presentation")
struct ConversationActivityPresentationTests {
  @Test("running state follows the live conversation ID set")
  func runningStatePropagation() {
    let runningIDs: Set<String> = ["running-chat"]

    #expect(ConversationActivityPresentation.resolve(
      conversationID: "running-chat",
      runningConversationIDs: runningIDs,
      reduceMotion: false
    ) == .animatedTint)
    #expect(ConversationActivityPresentation.resolve(
      conversationID: "idle-chat",
      runningConversationIDs: runningIDs,
      reduceMotion: false
    ) == .inactive)
  }

  @Test("reduced motion retains the static active tint")
  func reducedMotionUsesStaticTint() {
    let presentation = ConversationActivityPresentation.resolve(
      conversationID: "running-chat",
      runningConversationIDs: ["running-chat"],
      reduceMotion: true
    )

    #expect(presentation == .staticTint)
    #expect(presentation.isActive)
    #expect(!presentation.allowsMotion)
  }
}

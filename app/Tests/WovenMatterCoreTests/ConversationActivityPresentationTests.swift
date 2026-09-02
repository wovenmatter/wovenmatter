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

@Suite("Conversation bottom overlay layout")
struct ConversationBottomOverlayLayoutTests {
  @Test("clearance tracks the complete live bottom stack")
  func liveStackClearance() {
    #expect(ConversationBottomOverlayLayout.scrollClearance(stackHeight: 112) == 156)
    #expect(ConversationBottomOverlayLayout.scrollClearance(stackHeight: 188) == 232)
  }

  @Test("invalid measurements cannot remove the fixed clearance")
  func measurementClamping() {
    #expect(ConversationBottomOverlayLayout.scrollClearance(stackHeight: -1) == 44)
    #expect(ConversationBottomOverlayLayout.scrollClearance(
      stackHeight: 80,
      bottomOffset: -8,
      breathingRoom: -4
    ) == 80)
  }
}

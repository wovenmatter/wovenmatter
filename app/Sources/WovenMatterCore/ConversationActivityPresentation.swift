public enum ConversationActivityPresentation: Equatable, Sendable {
  case inactive
  case staticTint
  case animatedTint

  public static func resolve(
    conversationID: String,
    runningConversationIDs: Set<String>,
    reduceMotion: Bool
  ) -> Self {
    resolve(
      isRunning: runningConversationIDs.contains(conversationID),
      reduceMotion: reduceMotion
    )
  }

  public static func resolve(isRunning: Bool, reduceMotion: Bool) -> Self {
    guard isRunning else { return .inactive }
    return reduceMotion ? .staticTint : .animatedTint
  }

  public var isActive: Bool {
    self != .inactive
  }

  public var allowsMotion: Bool {
    self == .animatedTint
  }
}

public enum ConversationBottomOverlayLayout {
  public static let bottomOffset = 24.0
  public static let breathingRoom = 20.0

  public static func scrollClearance(
    stackHeight: Double,
    bottomOffset: Double = bottomOffset,
    breathingRoom: Double = breathingRoom
  ) -> Double {
    max(0, stackHeight) + max(0, bottomOffset) + max(0, breathingRoom)
  }
}

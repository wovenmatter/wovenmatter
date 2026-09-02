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

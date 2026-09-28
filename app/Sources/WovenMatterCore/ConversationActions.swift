import Foundation

public enum WorkspaceConversationMutation: Codable, Sendable {
  case setPinned(Bool)
  case rename(String)
  case moveToTrash
  case restore
}

public enum WorkspaceConversationExportFormat: String, Codable, Sendable {
  case messages
  case fullRun

  public var fileExtension: String { self == .messages ? "md" : "json" }

  public func suggestedFilename(title: String) -> String {
    let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")
      .union(.controlCharacters)).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    // Bound bytes as well as visible characters, including filesystem normalization.
    var basename = ""
    var byteCount = 0
    for character in clean.prefix(100) {
      let bytes = String(character).decomposedStringWithCanonicalMapping.utf8.count
      guard byteCount + bytes <= 200 else { break }
      basename.append(character)
      byteCount += bytes
    }
    return (basename.isEmpty ? "Chat" : basename)
      + (self == .fullRun ? "-full-run" : "-messages") + "." + fileExtension
  }
}

public struct WorkspaceTrashedConversation: Codable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let deletedAt: String

  public init(id: String, title: String, deletedAt: String) {
    self.id = id
    self.title = title
    self.deletedAt = deletedAt
  }
}

public enum WorkspaceConversationActionError: LocalizedError {
  case unavailable, emptyTitle, running

  public var errorDescription: String? {
    switch self {
    case .unavailable: "This chat is no longer available. Refresh and try again."
    case .emptyTitle: "Enter a name for this chat."
    case .running: "Stop this chat before moving it to Trash."
    }
  }
}

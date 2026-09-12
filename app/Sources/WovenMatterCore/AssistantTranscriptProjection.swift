import Foundation
import CryptoKit

/// Keeps frozen commentary in the work timeline while leaving the final (or live)
/// reply outside it. Canonical replacement text wins over a damaged live prefix.
public struct AssistantTranscriptProjection: Sendable {
  public let body: String
  public let commentary: [AgentRunActivity]

  public init(messageID: String, content: String, activities: [AgentRunActivity]) {
    var segments = activities.filter {
      $0.kind == .assistant && $0.assistantMessageID == messageID
    }
    let prefix = segments.compactMap(\.content).joined()
    let tail = segments.last?.assistantCheckpoint?.followingText(in: content)
      ?? (segments.last?.assistantCheckpoint == nil && !prefix.isEmpty && content.hasPrefix(prefix)
        ? String(content.dropFirst(prefix.count)) : nil)
    var remaining = content
    if let tail {
      remaining = tail
      // A message boundary may be the final answer, not commentary. Keep that
      // last segment visible even if no further text ever arrives (abort/tools-only).
      if remaining.isEmpty, let last = segments.last,
         let position = activities.lastIndex(where: { $0.id == last.id }),
         !activities.suffix(from: position + 1).contains(where: { $0.kind != .assistant && $0.phase != "clear" }) {
        segments.removeLast()
        remaining = last.content ?? ""
      }
    } else if let last = segments.last, last.content == content {
      segments.removeLast()
    }
    body = remaining
    commentary = segments
  }
}

/// A bounded checkpoint for a cumulative snapshot. This avoids storing the full
/// prefix at every boundary and distinguishes a replacement from an append,
/// including repeated words, Unicode, whitespace and partial code fences.
public struct AssistantTextCheckpoint: Codable, Equatable, Sendable {
  public let byteCount: Int
  private let digest: Data

  public init(_ text: String) {
    let bytes = Data(text.utf8)
    byteCount = bytes.count
    digest = Data(SHA256.hash(data: bytes))
  }

  public func followingText(in text: String) -> String? {
    let bytes = Data(text.utf8)
    guard byteCount >= 0, bytes.count >= byteCount,
          Data(SHA256.hash(data: bytes.prefix(byteCount))) == digest else { return nil }
    return String(data: bytes.dropFirst(byteCount), encoding: .utf8)
  }
}

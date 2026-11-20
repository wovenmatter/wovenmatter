import Foundation

/// A completed dictation. Its identity survives save retries.
public struct DictationRecord: Equatable, Identifiable, Sendable {
  public var id: String
  public var text: String
  public var createdAt: Date
  public init(id: String = UUID().uuidString.lowercased(), text: String, createdAt: Date = Date()) {
    self.id = id; self.text = text; self.createdAt = createdAt
  }
}

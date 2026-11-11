import Foundation

/// An immutable completed dictation. Its identity survives upload retries.
public struct DictationRecord: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var text: String
  public var createdAt: Date
  public init(id: String = UUID().uuidString.lowercased(), text: String, createdAt: Date = Date()) {
    self.id = id; self.text = text; self.createdAt = createdAt
  }
  public func validate() throws {
    guard UUID(uuidString: id) != nil, createdAt.timeIntervalSince1970.isFinite,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !text.contains("\0"), text.utf8.count <= 1_048_576 else { throw DictationHistoryError.invalidRecord }
  }
}
public struct DictationHistoryPage: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var cursor: Int64
  public var records: [DictationRecord]
  public var hasMore: Bool
  public init(workspaceID: String, cursor: Int64, records: [DictationRecord], hasMore: Bool) {
    self.workspaceID = workspaceID; self.cursor = cursor; self.records = records; self.hasMore = hasMore
  }
}
public enum DictationHistoryError: Error, LocalizedError {
  case invalidRecord, identityConflict, wrongWorkspace, invalidPage
  public var errorDescription: String? {
    switch self {
    case .invalidRecord: "This dictation could not be saved."
    case .identityConflict: "A different dictation already uses this history entry’s identity."
    case .wrongWorkspace: "Dictation history belongs to a different central database. Local dictations have been kept."
    case .invalidPage: "The central database returned incomplete dictation history."
    }
  }
}

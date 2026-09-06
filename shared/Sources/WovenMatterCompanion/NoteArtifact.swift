import Foundation

/// A durable pointer from a note artifact to data inside a registered database.
/// Source and database IDs remain path-free so documents can move between Macs
/// without persisting an absolute host path.
public struct DatabaseArtifactLink: Codable, Equatable, Sendable {
  public var sourceID: String
  public var databaseID: String
  public var relativePath: String
  public var sqliteQuery: String?

  public init(
    sourceID: String,
    databaseID: String,
    relativePath: String,
    sqliteQuery: String? = nil
  ) {
    self.sourceID = sourceID
    self.databaseID = databaseID
    self.relativePath = relativePath
    self.sqliteQuery = sqliteQuery
  }
}

public enum NoteArtifactKind: String, Codable, CaseIterable, Sendable {
  case note
  case spreadsheet
  case html

  public var displayName: String {
    switch self {
    case .note: "Note"
    case .spreadsheet: "Spreadsheet"
    case .html: "HTML artifact"
    }
  }
}

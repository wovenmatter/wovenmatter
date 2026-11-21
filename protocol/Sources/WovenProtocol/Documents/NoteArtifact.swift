import Foundation

/// A durable pointer from a note artifact to data inside a registered database.
/// Source and database IDs remain path-free so documents can move between Macs
/// without persisting an absolute path on a machine.
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

/// Cases are in the order New Asset offers them.
public enum NoteArtifactKind: String, Codable, CaseIterable, Sendable {
  case note
  case canvas
  case spreadsheet
  case html

  public var displayName: String {
    switch self {
    case .note: "Note"
    case .spreadsheet: "Sheet"
    case .html: "App"
    case .canvas: "Page"
    }
  }
}

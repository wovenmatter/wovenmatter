import Foundation

/// An online read of a document's registered database link. This is a preview,
/// never a write to the note or a query/path supplied by the phone.
public struct CompanionLinkedData: Codable, Equatable, Sendable {
  public var noteID: String
  public var noteRevision: Int64
  public var tableID: String?
  public var columns: [String]
  public var rows: [[String]]
  public var json: String

  public init(noteID: String, noteRevision: Int64, tableID: String? = nil,
              columns: [String], rows: [[String]], json: String) {
    self.noteID = noteID; self.noteRevision = noteRevision; self.tableID = tableID
    self.columns = columns; self.rows = rows; self.json = json
  }
}

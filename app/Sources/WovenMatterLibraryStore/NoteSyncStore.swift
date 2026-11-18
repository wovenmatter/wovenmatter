import Foundation
import WovenMatterShared

extension WorkspaceDatabaseConnection {
  /// The content to store for a local write of one note. A Page or an Artifact gets the
  /// causal clocks paired replicas use to merge concurrent versions; see `NoteSync`. They
  /// come from what this write changed in the stored row, so a client cannot supply them.
  /// `title` and `folderID` default to the stored row's.
  func syncedNoteContentUnlocked(id: String, content: String, title: String? = nil, folderID: String?? = nil) throws -> String {
    let previous = try historyRowsUnlocked("SELECT title,content,folder_id FROM notes WHERE id=?", values: [id]).first?.objectValue
    let priorTitle = previous?["title"]?.stringValue, priorFolder = previous?["folder_id"]?.stringValue
    let prior = previous.flatMap { row in row["content"]?.stringValue.map { (content: $0, title: priorTitle ?? "", folderID: priorFolder) } }
    return NoteSync.stamp(content: content, title: title ?? priorTitle ?? "", folderID: folderID ?? priorFolder,
                          previous: prior, previousRecord: try storedNoteRecordUnlocked(id: id))
  }

  /// The stored content, clocks included, for a write that changes only the row around it.
  func storedNoteContentUnlocked(id: String) throws -> String {
    try historyRowsUnlocked("SELECT content FROM notes WHERE id=?", values: [id]).first?.objectValue?["content"]?.stringValue ?? ""
  }

  /// Origin and counter of the synchronization version that wrote the stored row, if any:
  /// the winner among the versions this replica applied.
  private func storedNoteRecordUnlocked(id: String) throws -> NoteSyncDot? {
    guard let key = String(data: try JSONEncoder().encode([id]), encoding: .utf8),
          let winner = PairedLibraryRecord.winner(try frontierMembersUnlocked(table: "notes", key: key)) else { return nil }
    return NoteSyncDot(r: winner.origin, n: winner.clock)
  }
}

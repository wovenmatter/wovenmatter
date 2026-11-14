#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension WorkspaceDatabaseConnection {
    /// A recovery copy has a new stable identity, allowing acknowledgement-loss
    /// retries without duplicating writing or reviving the original deleted note.
    public static func recoveryCopyID(sourceID: String, title: String, content: String) -> String {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode([sourceID, title, content])) ?? Data()
        let hex = SHA256.hash(data: data).prefix(16).hexString
        let pieces = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return pieces.joined(separator: "-")
    }

    /// This copies exact preserved bytes, including an unsupported future format.
    /// It grants no permission to edit or decode that unsupported format.
    public func preserveRecoveryCopy(sourceID: String, title: String, content: String, folderID: String?) throws -> String {
        let id = Self.recoveryCopyID(sourceID: sourceID, title: title, content: content)
        let recoveredTitle = title + " (Recovered)"
        return try transaction {
            if let existing = try libraryNoteUnlocked(id: id) {
                guard existing.content == content, existing.title == recoveredTitle else {
                    throw WorkspaceNoteMutationError.revisionConflict
                }
                return id
            }
            if try libraryVersionUnlocked(kind: "note", id: id) != nil {
                throw WorkspaceNoteMutationError.noteNotFound
            }
            let destination = try folderID.flatMap { try libraryFolderUnlocked(id: $0) }?.id
            let timestamp = Self.timestamp(Date())
            try toolsExecuteUnlocked("""
                INSERT INTO notes(id, folder_id, title, content, snippet, position, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                """, [id, destination, recoveredTitle,
                    try syncedNoteContentUnlocked(id: id, content: content, title: recoveredTitle, folderID: .some(destination)),
                    Self.noteSnippet(content), timestamp, timestamp])
            try checkpointNoteUnlocked(id: id, source: "recovered", force: true)
            return id
        }
    }
}

extension WorkspaceDatabase {
  public static func recoveryCopyID(sourceID: String, title: String, content: String) -> String { WorkspaceDatabaseConnection.recoveryCopyID(sourceID: sourceID, title: title, content: content) }
  public func preserveRecoveryCopy(sourceID: String, title: String, content: String, folderID: String?) async throws -> String {
    try await write { try $0.preserveRecoveryCopy(sourceID: sourceID, title: title, content: content, folderID: folderID) }
  }
}

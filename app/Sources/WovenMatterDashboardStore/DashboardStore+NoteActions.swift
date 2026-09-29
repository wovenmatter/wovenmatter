import Foundation
import WovenMatterCore

extension DashboardStore {
  public func mutateNote(id: String, mutation: WorkspaceNoteMutation, expectedRevision: String) async throws {
    try await database.mutateNote(id: id, mutation: mutation, expectedRevision: expectedRevision)
  }

  public func trashedNotes() async throws -> [WorkspaceTrashedNote] {
    try await database.trashedNotes()
  }

  public func exportNote(id: String, format: WorkspaceNoteExportFormat, expectedRevision: String) async throws -> WorkspaceNoteExport {
    let content = try await database.noteExport(id: id, format: format, expectedRevision: expectedRevision)
    let url = FileManager.default.temporaryDirectory
      .appending(path: "wovenmatter-note-export-" + UUID().uuidString + "." + content.fileExtension)
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try content.data.write(to: url, options: [.atomic, .completeFileProtection])
          continuation.resume()
        } catch {
          try? FileManager.default.removeItem(at: url)
          continuation.resume(throwing: error)
        }
      }
    }
    do { try Task.checkCancellation() }
    catch { try? FileManager.default.removeItem(at: url); throw error }
    return WorkspaceNoteExport(url: url, suggestedFilename: content.suggestedFilename, fileExtension: content.fileExtension)
  }
}

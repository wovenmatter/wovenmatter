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
    let stagedURL = FileManager.default.temporaryDirectory
      .appending(path: "wovenmatter-note-export-" + UUID().uuidString + "." + content.fileExtension)
    try Task.checkCancellation()
    do {
      try await WorkspaceExportFileIO.perform {
        try content.data.write(to: stagedURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
      }
    } catch {
      // This path was generated above exclusively for this temporary snapshot.
      try? FileManager.default.removeItem(at: stagedURL)
      throw error
    }
    do { try Task.checkCancellation() }
    catch { try? FileManager.default.removeItem(at: stagedURL); throw error }
    return WorkspaceNoteExport(url: stagedURL, suggestedFilename: content.suggestedFilename, fileExtension: content.fileExtension)
  }
}

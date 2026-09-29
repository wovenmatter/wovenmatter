import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Note menu revisions, retention and export")
struct WorkspaceNoteActionsTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "note-actions-" + UUID().uuidString)
    let db: WorkspaceDatabase
    init() async throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      db = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    }
    func close() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func staleRevisionCannotRenameTrashOrExportNewerContent() async throws {
    let f = try await Fixture(); defer { f.close() }
    let id = try await f.db.createNote(folderID: nil, title: "Original", content: "Original content")
    let stale = try await f.db.noteActionRevision(id: id)
    _ = try await f.db.updateNote(id: id, title: "Newer title", content: "Newer content")
    for mutation in [WorkspaceNoteMutation.rename("Stale name"), .moveToTrash] {
      await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
        try await f.db.mutateNote(id: id, mutation: mutation, expectedRevision: stale)
      }
    }
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      try await f.db.noteExport(id: id, format: .standard, expectedRevision: stale)
    }
    let saved = try await f.db.readNoteForEditing(id: id)
    #expect(saved.title == "Newer title" && saved.document?.plainText == "Newer content")
    #expect(try await f.db.trashedNotes().isEmpty)
  }

  @Test func trashRestorePreservesEveryDocumentKindPinAndFolder() async throws {
    let f = try await Fixture(); defer { f.close() }
    let folder = try await f.db.createFolder(name: "Retained")
    for kind in NoteArtifactKind.allCases {
      let document = NoteDocument(kind: kind, blocks: [.richText(.init(text: "Retained content"))], html: "<h1>Original HTML</h1>")
      let content = try document.encoded()
      let id = try await f.db.createNote(folderID: folder, title: kind.displayName, content: content, kind: kind)
      try await f.db.mutateNote(id: id, mutation: .setPinned(true), expectedRevision: f.db.noteActionRevision(id: id))
      let before = try await f.db.readNoteForEditing(id: id)
      let versions = try await f.db.noteAssetVersions(id: id)
      try await f.db.mutateNote(id: id, mutation: .moveToTrash, expectedRevision: f.db.noteActionRevision(id: id))
      #expect(try await f.db.workspaceOverview().notes.allSatisfy { $0.id != id })
      let hidden = try #require(try await f.db.trashedNotes().first { $0.id == id })
      #expect(hidden.isPinned && hidden.title == kind.displayName)
      await #expect(throws: WorkspaceNoteMutationError.noteNotFound) {
        try await f.db.noteActionRevision(id: id)
      }
      try await f.db.mutateNote(id: id, mutation: .restore, expectedRevision: f.db.noteActionRevision(id: id, trashed: true))
      let restored = try #require(try await f.db.workspaceOverview().notes.first { $0.id == id })
      #expect(restored.content == content && restored.folderID == folder && restored.isPinned)
      #expect(try await f.db.readNoteForEditing(id: id).document == before.document)
      #expect(try await f.db.noteAssetVersions(id: id).map(\.id) == versions.map(\.id))
    }
  }

  @Test func moveRejectsForeignFolderAndRestoreFallsBackAfterFolderRemoval() async throws {
    let f = try await Fixture(); defer { f.close() }
    let folder = try await f.db.createFolder(name: "Previous folder")
    let id = try await f.db.createNote(folderID: folder, title: "Retained")
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("INSERT INTO folders(id,user_id,name) VALUES('foreign','someone-else','Foreign')", [])
    } }
    await #expect(throws: WorkspaceNoteMutationError.folderNotFound) {
      try await f.db.mutateNote(id: id, mutation: .moveToFolder("foreign"), expectedRevision: f.db.noteActionRevision(id: id))
    }
    #expect(try await f.db.workspaceOverview().notes.first?.folderID == folder)
    try await f.db.mutateNote(id: id, mutation: .moveToTrash, expectedRevision: f.db.noteActionRevision(id: id))
    _ = try await f.db.deleteFolder(id: folder)
    try await f.db.mutateNote(id: id, mutation: .restore, expectedRevision: f.db.noteActionRevision(id: id, trashed: true))
    #expect(try await f.db.workspaceOverview().notes.first?.folderID == nil)
  }

  @Test func readableExportsEscapeContentAndDocumentExportRetainsStructure() throws {
    let rich = NoteRichTextBlock(style: .heading2, runs: [
      .init(text: "A [link]", bold: true, link: "https://example.org/a(b)?q=two words")
    ])
    let note = NoteDocument(blocks: [.richText(rich)])
    let markdown = try note.exported(title: "Title *literal*", format: .standard)
    let text = String(decoding: markdown.data, as: UTF8.self)
    #expect(markdown.fileExtension == "md")
    #expect(text.contains("Title \\*literal\\*"))
    #expect(text.contains("## [**A \\[link\\]**](https://example.org/a%28b%29?q=two%20words)"))
    let table = NoteTableBlock(columns: [.init(), .init(), .init()], rows: [
      .init(cells: [.init(text: "A, \"quote\""), .init(text: "line\nbreak"), .init(text: " =1+1")])
    ])
    let sheet = NoteDocument(kind: .spreadsheet, blocks: [.table(table)])
    let csv = try sheet.exported(title: "Sheet", format: .standard)
    #expect(csv.fileExtension == "csv")
    #expect(String(decoding: csv.data, as: UTF8.self) == "\"A, \"\"quote\"\"\",\"line\nbreak\",\"' =1+1\"\r\n")
    let original = try sheet.exported(title: "Sheet", format: .document)
    #expect(original.fileExtension == "json")
    #expect(try JSONDecoder().decode(NoteDocument.self, from: original.data) == sheet)
    let html = "<!doctype html><title>Retained</title><script>const text = '<literal>';</script>"
    let artifact = try NoteDocument(kind: .html, html: html).exported(title: "HTML", format: .standard)
    #expect(artifact.fileExtension == "html" && String(decoding: artifact.data, as: UTF8.self) == html)
    let bounded = try note.exported(title: String(repeating: "界🙂", count: 300) + "/:\\\n", format: .standard)
    #expect(bounded.suggestedFilename.decomposedStringWithCanonicalMapping.utf8.count <= 255)
    #expect(!bounded.suggestedFilename.contains("/") && !bounded.suggestedFilename.contains(":"))
  }
}

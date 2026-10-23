import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Note menu revisions, retention and export")
struct WorkspaceNoteActionsTests {

  @Test func nestedListsPersistAndStaleMenuActionsCannotOverwriteTheirNewRevision() async throws {
    let f = try await Fixture(); defer { f.close() }
    let parent = NoteTextList(id: "parent-list", markerFormat: "{decimal}.", startingItemNumber: 5)
    let child = NoteTextList(id: "child-list", markerFormat: "{hyphen}")
    let nested = NoteListFormatting(levels: [parent, child], headIndent: 72, firstLineHeadIndent: 0,
                                    tabStops: [.init(alignment: 0, location: 47), .init(alignment: 4, location: 72)])
    let document = NoteDocument(blocks: [
      .richText(.init(id: "parent", style: .numberedList, text: "Abstraction",
                     list: .init(levels: [parent], headIndent: 28, firstLineHeadIndent: 6))),
      .richText(.init(id: "child", style: .numberedList, text: "Layers", list: nested))
    ])
    let original = NoteDocument(blocks: [.richText(.init(id: "original", text: "Original content"))])
    let id = try await f.db.createNote(folderID: nil, title: "Original", content: original.encoded())
    let stale = try await f.db.noteActionRevision(id: id)
    _ = try await f.db.updateNote(id: id, title: "Nested", content: document.encoded())
    let stored = try await f.db.readNoteForEditing(id: id)
    #expect(stored.document == document && stored.title == "Nested")
    for mutation in [WorkspaceNoteMutation.rename("Stale name"), .moveToTrash] {
      await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
        try await f.db.mutateNote(id: id, mutation: mutation, expectedRevision: stale)
      }
    }
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      try await f.db.noteExport(id: id, format: .standard, expectedRevision: stale)
    }
    let after = try await f.db.readNoteForEditing(id: id)
    #expect(after.title == "Nested" && after.document == document)
    #expect(try await f.db.trashedNotes().isEmpty)
    let exported = try document.exported(title: "Nested", format: .document)
    #expect(try JSONDecoder().decode(NoteDocument.self, from: exported.data) == document)

    var styled = document
    _ = try styled.apply([.setParagraphStyle(blockID: "child", style: .numberedList)])
    #expect(styled == document)
    _ = try styled.apply([.setParagraphStyle(blockID: "child", style: .bulletedList)])
    guard case .richText(let changed) = styled.blocks[1] else { Issue.record("Missing child"); return }
    #expect(changed.style == .bulletedList && changed.list == nil)
    guard case .richText(let unchanged) = styled.blocks[0] else { Issue.record("Missing parent"); return }
    #expect(unchanged.list?.levels == [parent])

    let old = #"{"version":2,"kind":"note","blocks":[{"type":"richText","value":{"id":"old","style":"numberedList","runs":[]}}],"html":""}"#
    let decoded = try JSONDecoder().decode(NoteDocument.self, from: Data(old.utf8))
    guard case .richText(let oldList) = decoded.blocks[0] else { Issue.record("Missing old list"); return }
    #expect(oldList.style == .numberedList && oldList.list == nil)
    #expect(NoteDocument.decode(try decoded.encoded()) == decoded)
  }

  @Test func inlineValueLinksSurviveStorageAndUseExistingEditExportBounds() throws {
    let link = DatabaseArtifactLink(sourceID: "device:test", databaseID: "sales", relativePath: "data.sqlite",
                                   sqliteQuery: "SELECT sum(amount) FROM sales")
    var wireRun = NoteTextRun(text: "", databaseLink: link)
    wireRun.databaseValueID = nil // Agents may omit identity in their JSON edits.
    let document = NoteDocument(blocks: [.richText(.init(id: "summary", runs: [.init(text: "Total: "), wireRun]))])
    let stored = NoteDocument.decode(try document.encoded())
    guard case .richText(let text) = stored.blocks[0], let value = text.runs.last else {
      Issue.record("Missing inline value"); return
    }
    #expect(value.databaseLink == link && value.databaseValueID != nil && value.text.isEmpty)
    #expect(NoteDocument.decode(try stored.encoded()) == stored)
    #expect(stored.plainText == "Total: ")

    var excessive = value
    excessive.databaseLink?.sqliteQuery = String(repeating: "x", count: 64 * 1_024 + 1)
    #expect(throws: RemoteNoteEditError.operationTooLarge) {
      try RemoteNoteEditEnvelope.validate(operations: [.replaceBlock(id: "summary", block: .richText(.init(runs: [excessive])))],
                                          noteKind: .note)
    }
    excessive.databaseLink?.sqliteQuery = String(repeating: "x", count: WorkspaceExportBudget.maximumStoredBytes + 1)
    let oversized = NoteDocument(blocks: [.richText(.init(runs: [excessive]))])
    #expect(throws: WorkspaceExportError.tooLarge) { try oversized.exported(title: "Inline", format: .document) }
  }

  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "note-actions-" + UUID().uuidString)
    let db: WorkspaceDatabase
    init() async throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      db = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    }
    func close() { try? FileManager.default.removeItem(at: root) }
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

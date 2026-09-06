import AppKit
import SwiftUI
import WovenMatterCore

// The actual editor compiles unchanged. Only unrelated theme values used by
// its formatting toolbar are supplied here; no parsing or storage is mocked.
struct DashboardPalette {
    static let mutedForeground = Color.secondary
    static let background = Color.white
    let themeSoft = Color.clear
}
struct NoteTestTheme {
    let palette = DashboardPalette()
}
private struct NoteTestThemeKey: EnvironmentKey {
    static let defaultValue = NoteTestTheme()
}
extension EnvironmentValues {
    var dashboardTheme: NoteTestTheme {
        get { self[NoteTestThemeKey.self] }
        set { self[NoteTestThemeKey.self] = newValue }
    }
}

@main
@MainActor
struct DashboardNoteEditorTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wovenmatter-note-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let link = DatabaseArtifactLink(
            sourceID: "test-source",
            databaseID: "test-database",
            relativePath: "records.sqlite",
            sqliteQuery: "SELECT title FROM records"
        )
        var cases = 0
        for kind in NoteArtifactKind.allCases {
            for documentLink in [link, nil] {
                var table = NoteTableBlock(rows: 2, columns: 2, headerRow: true)
                table.databaseLink = link
                table.rows[0].cells[0].runs = [NoteTextRun(text: "Column")]
                table.rows[1].cells[0].runs = [NoteTextRun(text: "Stored cell")]
                let original = NoteDocument(
                    version: 1,
                    kind: kind,
                    blocks: [
                        .richText(NoteRichTextBlock(id: "paragraph", text: "Original text")),
                        .table(table),
                    ],
                    html: "<section data-test='metadata'>Retain me</section>",
                    databaseLink: documentLink
                )
                var saved = original
                let controller = DashboardNoteEditorController()
                let editor = DashboardNoteEditor(
                    document: Binding(get: { saved }, set: { saved = $0 }),
                    controller: controller
                )
                let coordinator = editor.makeCoordinator()
                let textView = NSTextView()
                coordinator.bind(textView)
                coordinator.apply(original, to: textView)

                // A native text-storage edit follows the same notification path
                // as typing. The real coordinator invokes the real parser.
                let range = (textView.string as NSString).range(of: "Original text")
                try require(range.location != NSNotFound, "Rendered paragraph missing")
                textView.textStorage!.replaceCharacters(in: range, with: "Edited text")
                coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                try verifyMetadata(saved, original: original, label: "after edit")
                try require(saved.blocks.first?.plainText == "Edited text", "Edit was not parsed")

                let path = directory.appendingPathComponent("\(kind.rawValue)-\(cases).json")
                try saved.encoded().write(to: path, atomically: true, encoding: .utf8)
                let reopened = NoteDocument.decode(try String(contentsOf: path, encoding: .utf8))
                try verifyMetadata(reopened, original: original, label: "after reopen")
                try require(reopened.blocks.first?.plainText == "Edited text", "Edit lost on reopen")
                guard case .table(let reopenedTable) = reopened.blocks.last else {
                    throw Failure(description: "Table lost on reopen")
                }
                try require(reopenedTable.databaseLink == link, "Table link lost on reopen")
                try require(reopenedTable.id == table.id, "Table identity changed")
                try require(reopenedTable.rows[1].cells[0].plainText == "Stored cell", "Unedited cell changed")

                // Reopen in the actual renderer, then clear all text. Metadata
                // must survive normalization creating an empty content block.
                coordinator.apply(reopened, to: textView)
                textView.textStorage!.replaceCharacters(
                    in: NSRange(location: 0, length: textView.textStorage!.length),
                    with: ""
                )
                coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                try verifyMetadata(saved, original: original, label: "after clearing")
                try require(!saved.blocks.isEmpty, "Empty content was not normalized")
                let cleared = NoteDocument.decode(try saved.encoded())
                try verifyMetadata(cleared, original: original, label: "cleared reopen")
                cases += 1
            }
        }
        print("PASS: \(cases) actual AppKit edit/parse/save/reopen and clear/reopen cases preserve document metadata and table links")
    }

    static func verifyMetadata(_ document: NoteDocument, original: NoteDocument, label: String) throws {
        try require(document.databaseLink == original.databaseLink, "Database link lost \(label)")
        try require(document.kind == original.kind, "Artifact kind lost \(label)")
        try require(document.html == original.html, "HTML metadata lost \(label)")
        try require(document.version == NoteDocument.currentVersion, "Version not normalized \(label)")
    }
}

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
        try verifyDocumentBindingCache()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wovenmatter-note-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try verifyNativeListPersistence(in: directory)

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

    struct NativeListSnapshot: Equatable {
        var formats: [String]
        var identities: [Int]
        var startingNumbers: [Int]
        var options: [UInt]
        var headIndent: CGFloat
        var firstLineHeadIndent: CGFloat
        var tabLocations: [CGFloat]
        var tabAlignments: [Int]
        var defaultTabInterval: CGFloat
    }

    static func listSnapshots(_ textView: NSTextView) -> [NativeListSnapshot] {
        let string = textView.string as NSString
        var identities: [ObjectIdentifier: Int] = [:]
        var snapshots: [NativeListSnapshot] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let paragraph = textView.textStorage!.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                as? NSParagraphStyle ?? .default
            snapshots.append(NativeListSnapshot(
                formats: paragraph.textLists.map { $0.markerFormat.rawValue },
                identities: paragraph.textLists.map {
                    let key = ObjectIdentifier($0)
                    if let existing = identities[key] { return existing }
                    let identity = identities.count
                    identities[key] = identity
                    return identity
                },
                startingNumbers: paragraph.textLists.map(\.startingItemNumber),
                options: paragraph.textLists.map { $0.listOptions.rawValue },
                headIndent: paragraph.headIndent, firstLineHeadIndent: paragraph.firstLineHeadIndent,
                tabLocations: paragraph.tabStops.map(\.location),
                tabAlignments: paragraph.tabStops.map { $0.alignment.rawValue },
                defaultTabInterval: paragraph.defaultTabInterval
            ))
            location = NSMaxRange(range)
        }
        return snapshots
    }

    static func nativeEditor(_ document: Binding<NoteDocument>) -> (NSTextView, DashboardNoteEditor.Coordinator) {
        let editor = DashboardNoteEditor(document: document, controller: DashboardNoteEditorController())
        let coordinator = editor.makeCoordinator()
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = true
        textView.delegate = coordinator
        coordinator.bind(textView)
        coordinator.apply(document.wrappedValue, to: textView)
        return (textView, coordinator)
    }

    static func verifyNativeListPersistence(in directory: URL) throws {
        _ = NSApplication.shared
        let parents = ["One", "Two", "Three", "Four", "Abstraction"]
        var saved = NoteDocument(blocks: parents.map {
            .richText(NoteRichTextBlock(style: .numberedList, text: $0))
        })
        let (textView, coordinator) = nativeEditor(Binding(get: { saved }, set: { saved = $0 }))
        let children = ["To abstract", "Levels", "Layers"]
        for child in children {
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count - 1, length: 0))
            textView.doCommand(by: #selector(NSTextView.insertNewline(_:)))
            try require(listSnapshots(textView).last?.formats == ["{decimal}."],
                        "Enter must keep creating a numbered item")
            textView.doCommand(by: #selector(NSTextView.insertTab(_:)))
            try require(listSnapshots(textView).last?.formats == ["{decimal}.", "{hyphen}"],
                        "Tab must keep creating a nested dash item")
            textView.insertText(child, replacementRange: textView.selectedRange())
        }
        let before = listSnapshots(textView)
        try require(before.count == 8 && before.suffix(3).allSatisfy { $0.headIndent > before[4].headIndent },
                    "The three children must be indented under item 5")
        try require(before.allSatisfy { $0.identities.first == before[0].identities.first },
                    "Parent numbering must share one list across nested children")
        try require(saved.blocks.count == 8 && saved.blocks.suffix(3).allSatisfy {
            if case .richText(let text) = $0 { return text.list?.levels.last?.markerFormat == "{hyphen}" }
            return false
        }, "Native edits must publish nesting through the normal notification path")

        let path = directory.appendingPathComponent("native-nested-list.json")
        try saved.encoded().write(to: path, atomically: true, encoding: .utf8)
        var reopened = NoteDocument.decode(try String(contentsOf: path, encoding: .utf8))
        let (reopenedView, reopenedCoordinator) = nativeEditor(Binding(get: { reopened }, set: { reopened = $0 }))
        try require(listSnapshots(reopenedView) == before,
                    "Fresh editor must restore markers, hierarchy, identities, indents, and native tab stops")
        let persisted = reopened
        reopenedCoordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: reopenedView))
        try require(reopened == persisted, "A no-op parse must preserve saved list identities")

        // A further Tab and Shift-Tab must still use native editing after reopening.
        let layers = (reopenedView.string as NSString).range(of: "Layers")
        reopenedView.setSelectedRange(NSRange(location: layers.location, length: 0))
        reopenedView.doCommand(by: #selector(NSTextView.insertTab(_:)))
        let deeper = listSnapshots(reopenedView)
        try require(deeper.last?.formats.count == 3, "A second Tab must retain deeper native nesting")
        reopenedCoordinator.apply(NoteDocument.decode(try reopened.encoded()), to: reopenedView)
        try require(listSnapshots(reopenedView) == deeper, "Deeper nesting must survive reopening")
        reopenedView.setSelectedRange(NSRange(location: layers.location, length: 0))
        reopenedView.doCommand(by: #selector(NSTextView.insertBacktab(_:)))
        try require(listSnapshots(reopenedView) == before, "Shift-Tab must restore the previous nesting")

        // Continue the user's Enter/Tab workflow from a restored child item.
        reopenedView.setSelectedRange(NSRange(location: reopenedView.string.utf16.count - 1, length: 0))
        reopenedView.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        try require(listSnapshots(reopenedView).last?.formats == ["{decimal}."],
                    "Enter after reopening must still create a numbered item")
        reopenedView.doCommand(by: #selector(NSTextView.insertTab(_:)))
        let emptyNested = listSnapshots(reopenedView)
        reopenedCoordinator.apply(NoteDocument.decode(try reopened.encoded()), to: reopenedView)
        try require(listSnapshots(reopenedView) == emptyNested && emptyNested.last?.formats.last == "{hyphen}",
                    "An empty nested item must retain its dash and indentation on reopen")

        // Earlier documents have no list metadata; native rendering remains flat.
        coordinator.apply(NoteDocument(blocks: [.richText(.init(style: .bulletedList, text: "Old bullet"))]), to: textView)
        try require(listSnapshots(textView).first?.formats == ["{disc}"], "Old bulleted lists must render unchanged")
        print("PASS: native Enter/Tab lists, nested dash save/fresh reopen, deeper nesting, Shift-Tab, empty items, and stable list identities")
    }

    static func verifyDocumentBindingCache() throws {
        var decodes = 0
        let cache = DashboardNoteDocumentCache { source in
            decodes += 1
            return NoteDocument.decode(source)
        }
        let first = cache.value(noteID: "first", source: "Legacy note")
        for _ in 0..<100 {
            try require(cache.value(noteID: "first", source: "Legacy note") == first,
                "Repeated reads must preserve legacy block identity")
        }
        try require(decodes == 1, "Unchanged binding reads decoded the document again")

        var table = NoteTableBlock(rows: 100, columns: 8, headerRow: true)
        table.rows[99].cells[7].runs = [NoteTextRun(text: "Last cell")]
        let edited = NoteDocument(kind: .spreadsheet, blocks: [.table(table)], html: "metadata")
        let saved = try cache.encode(edited, noteID: "first")
        try require(cache.value(noteID: "first", source: saved) == NoteDocument.decode(saved),
            "Local edits and persisted document differ")
        try require(decodes == 1, "A local edit was decoded immediately after encoding")

        let external = try NoteDocument(kind: .html, html: "Fresh external update").encoded()
        try require(cache.value(noteID: "first", source: external).html == "Fresh external update",
            "An external edit with no timestamp change stayed stale")
        try require(decodes == 2, "Changed source was not decoded exactly once")
        try require(cache.value(noteID: "first", source: saved) == edited.normalized(),
            "Returning to a prior source did not refresh the single-entry cache")
        _ = cache.value(noteID: "second", source: saved)
        try require(decodes == 4, "Switching notes must not reuse the prior note's entry")
        print("PASS: bounded document reuse preserves edits, fresh external source, note identity, and normalized persistence")
    }

    static func verifyMetadata(_ document: NoteDocument, original: NoteDocument, label: String) throws {
        try require(document.databaseLink == original.databaseLink, "Database link lost \(label)")
        try require(document.kind == original.kind, "Artifact kind lost \(label)")
        try require(document.html == original.html, "HTML metadata lost \(label)")
        try require(document.version == NoteDocument.currentVersion, "Version not normalized \(label)")
    }
}

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
        try verifyTextStatistics()
        try verifyNativeEditingControls()
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

    static func verifyTextStatistics() throws {
        func counts(_ text: String) -> DashboardNoteTextStatistics {
            DashboardNoteTextStatistics(document: NoteDocument(blocks: [.richText(NoteRichTextBlock(text: text))]))
        }
        try require(counts("").words == 0 && counts("").characters == 0, "Empty note counts must be zero")
        try require(counts("Hello, world! Don't stop.").words == 4,
                    "Words must follow native boundaries, including apostrophes and punctuation")
        try require(counts("... 🐈").words == 0, "Punctuation and emoji are not words")
        let unicode = counts("café 👨‍👩‍👧‍👦 e\u{301}")
        try require(unicode.words == 2 && unicode.characters == 8,
                    "Characters must count visible Unicode characters, including joined emoji and combining marks")
        let whitespace = counts("one  two\nthree")
        try require(whitespace.words == 3 && whitespace.characters == 14,
                    "Counts must include spaces and line breaks in characters, not words")
        var table = NoteTableBlock(rows: 2, columns: 2)
        table.rows[0].cells[0].runs = [NoteTextRun(text: "Apple pie")]
        table.rows[1].cells[0].runs = [NoteTextRun(text: "Second cell")]
        let document = NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "One two")), .table(table)])
        let statistics = DashboardNoteTextStatistics(document: document)
        try require(statistics.words == 6 && statistics.characters == 31,
                    "The entire note must count table cells and block/cell separators, without generated list markers")
        print("PASS: note counts handle empty content, word boundaries, Unicode, whitespace, and table content")
    }

    static func verifyNativeEditingControls() throws {
        _ = NSApplication.shared
        var saved = NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Original text"))])
        let controller = DashboardNoteEditorController()
        let editor = DashboardNoteEditor(document: Binding(get: { saved }, set: { saved = $0 }), controller: controller)
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        defer { window.close() }
        guard let textView = controller.textView, let manager = textView.undoManager else {
            throw Failure(description: "Native editor did not bind its text view and undo manager")
        }
        try require(textView.isContinuousSpellCheckingEnabled, "Spell checking must be on when the note opens")
        try require(!textView.isAutomaticSpellingCorrectionEnabled, "Spell checking must not silently replace words")
        try require(manager !== window.undoManager, "Note actions must not use the window's shared edit history")
        try require(!controller.canUndo && !controller.canRedo, "Opening a note must start with disabled undo/redo")
        window.makeFirstResponder(textView)
        manager.groupsByEvent = false

        func type(_ text: String, replacing range: NSRange) {
            manager.beginUndoGrouping()
            textView.insertText(text, replacementRange: range)
            manager.endUndoGrouping()
            textView.breakUndoCoalescing()
        }
        type("Edited text", replacing: NSRange(location: 0, length: 13))
        try require(saved.blocks.first?.plainText == "Edited text", "Native typing did not update the note document")
        try require(controller.canUndo && !controller.canRedo, "Typing must enable Undo and disable Redo")
        controller.undo()
        try require(saved.blocks.first?.plainText == "Original text", "Toolbar Undo did not restore typed content")
        try require(!controller.canUndo && controller.canRedo, "Undo must update both button states")
        controller.redo()
        try require(saved.blocks.first?.plainText == "Edited text", "Toolbar Redo did not reapply typed content")
        try require(controller.canUndo && !controller.canRedo, "Redo must update both button states")

        // Menu validation and responder-chain actions must find the note's
        // history rather than the window's manager.
        let undoItem = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        try require(textView.validateUserInterfaceItem(undoItem), "Edit-menu Undo must be enabled for the note")
        try require(!textView.validateUserInterfaceItem(redoItem), "Edit-menu Redo must reflect current history")
        try require(textView.tryToPerform(undoItem.action!, with: nil), "Responder chain did not handle Undo")
        try require(saved.blocks.first?.plainText == "Original text", "Menu Undo did not update the stored note")
        try require(textView.validateUserInterfaceItem(redoItem), "Edit-menu Redo must enable after Undo")
        try require(controller.canRedo && !controller.canUndo, "Native Undo left stale toolbar states")
        type("Fresh text", replacing: NSRange(location: 0, length: 13))
        try require(!controller.canRedo, "Typing after undo must discard the old redo branch")
        try require(DashboardNoteTextStatistics(document: saved).words == 2, "Live counts did not follow native edits")

        manager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        manager.beginUndoGrouping()
        controller.toggleBold()
        manager.endUndoGrouping()
        try require(controller.canUndo, "Formatting must enable Undo")
        controller.undo()
        guard case .richText(let block) = saved.blocks.first else { throw Failure(description: "Formatted block missing") }
        try require(block.runs.allSatisfy { !$0.bold }, "Undo did not restore the prior font formatting")
        controller.redo()
        guard case .richText(let boldBlock) = saved.blocks.first else { throw Failure(description: "Formatted block missing") }
        try require(boldBlock.runs.first?.bold == true, "Redo did not restore bold formatting")

        manager.removeAllActions()
        manager.beginUndoGrouping()
        controller.insertTable(rows: 1, columns: 1)
        manager.endUndoGrouping()
        try require(saved.blocks.contains { if case .table = $0 { return true }; return false }, "Insert table failed")
        controller.undo()
        try require(!saved.blocks.contains { if case .table = $0 { return true }; return false }, "Undo did not remove inserted table")
        controller.redo()
        try require(saved.blocks.contains { if case .table = $0 { return true }; return false }, "Redo did not restore inserted table")

        manager.removeAllActions()
        let dictation = DictationEditor()
        dictation.bind(textView, identity: "note-test")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let beforeDictation = saved
        try require(dictation.ticket()?.insert("Spoken words ") == true, "Dictation fixture could not insert text")
        try require(controller.canUndo, "Dictation must enable Undo")
        controller.undo()
        try require(saved == beforeDictation, "Undo did not restore the note before dictation")
        controller.redo()
        try require(saved.plainText.hasPrefix("Spoken words "), "Redo did not reapply dictated content")

        manager.removeAllActions()
        guard let coordinator = textView.delegate as? DashboardNoteEditor.Coordinator else {
            throw Failure(description: "Real editor coordinator missing")
        }
        let beforeAgentEdit = saved
        let agentEdit = NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "An external revision"))])
        manager.beginUndoGrouping()
        coordinator.apply(agentEdit, to: textView)
        // apply is the renderer side of a document binding update.
        saved = agentEdit
        manager.endUndoGrouping()
        controller.undo()
        try require(saved == beforeAgentEdit, "Undo did not restore an external document edit")
        controller.redo()
        try require(saved == agentEdit, "Redo did not reapply an external document edit")

        let otherController = DashboardNoteEditorController()
        let otherHost = NSHostingView(rootView: DashboardNoteEditor(document: .constant(NoteDocument()), controller: otherController))
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        otherWindow.contentView = otherHost
        otherHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        defer { otherWindow.close() }
        try require(otherController.textView?.undoManager !== manager,
                    "Different notes must not share their undo managers")
        try require(!otherController.canUndo && !otherController.canRedo,
                    "Opening another note must not inherit undo/redo availability")

        textView.isEditable = false
        controller.refreshUndoState()
        let locked = saved
        controller.undo()
        try require(!textView.validateUserInterfaceItem(undoItem) && !textView.validateUserInterfaceItem(redoItem),
                    "Read-only notes must reject Edit-menu Undo/Redo")
        try require(!controller.canUndo && !controller.canRedo && saved == locked,
                    "Read-only notes must disable and reject editing actions")
        controller.unbind(textView)
        try require(!controller.canUndo && !controller.canRedo, "Detached editor must clear toolbar availability")
        print("PASS: actual hosted Notes editor enables spelling and isolates native undo/redo for typing, formatting, tables, dictation, external edits, separate notes, keyboard actions, and read-only states")
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

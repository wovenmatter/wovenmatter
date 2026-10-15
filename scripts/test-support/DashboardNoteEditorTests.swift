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
        try verifyInlineDatabaseValues()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wovenmatter-note-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try verifyNativeListPersistence(in: directory)
        try verifyDarkAppearancePersistence(in: directory)

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
        var validations = 0
        let cache = DashboardNoteDocumentCache(validateEditable: { source in
            validations += 1
            return (try? NoteDocument.editableDocument(from: source)) != nil
        }) { source in
            decodes += 1
            return NoteDocument.decode(source)
        }
        let first = cache.value(noteID: "first", source: "Legacy note")
        for _ in 0..<100 {
            try require(cache.value(noteID: "first", source: "Legacy note") == first,
                "Repeated reads must preserve legacy block identity")
            try require(cache.isEditable(noteID: "first", source: "Legacy note"),
                "Legacy note should remain editable")
        }
        try require(decodes == 1, "Unchanged binding reads decoded the document again")
        try require(validations == 1, "Unchanged binding reads validated the document again")

        var table = NoteTableBlock(rows: 100, columns: 8, headerRow: true)
        table.rows[99].cells[7].runs = [NoteTextRun(text: "Last cell")]
        let edited = NoteDocument(kind: .spreadsheet, blocks: [.table(table)], html: "metadata")
        let saved = try cache.encode(edited, noteID: "first")
        try require(cache.value(noteID: "first", source: saved) == NoteDocument.decode(saved),
            "Local edits and persisted document differ")
        try require(cache.isEditable(noteID: "first", source: saved), "A valid local edit became read-only")
        try require(decodes == 1, "A local edit was decoded immediately after encoding")
        try require(validations == 1, "A typed local edit was re-decoded for validation")

        let external = try NoteDocument(kind: .html, html: "Fresh external update").encoded()
        try require(cache.value(noteID: "first", source: external).html == "Fresh external update",
            "An external edit with no timestamp change stayed stale")
        try require(decodes == 2, "Changed source was not decoded exactly once")
        try require(cache.value(noteID: "first", source: saved) == edited.normalized(),
            "Returning to a prior source did not refresh the single-entry cache")
        _ = cache.value(noteID: "second", source: saved)
        try require(decodes == 4, "Switching notes must not reuse the prior note's entry")
        try require(validations == 4, "External sources and note switches must validate exactly once")

        let unsupported = "{\"version\":999,\"blocks\":[]}"
        for _ in 0..<100 {
            _ = cache.value(noteID: "second", source: unsupported)
            try require(!cache.isEditable(noteID: "second", source: unsupported),
                "An unsupported document became editable")
        }
        try require(decodes == 4, "An unsupported document reached the forgiving decoder")
        try require(validations == 5, "An unsupported source was validated repeatedly")
        try require(cache.isEditable(noteID: "second", source: saved),
            "A recovered supported version remained read-only")
        try require(decodes == 5 && validations == 6, "Recovering a version must refresh once")
        print("PASS: bounded document reuse preserves edits, external updates, note identity, normalized persistence, and read-only recovery")
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
        // List objects are recreated when rendering: redo must retain the
        // exact document snapshot rather than parse defaults into its runs.
        let agentEdit = NoteDocument(blocks: [.richText(NoteRichTextBlock(style: .numberedList, text: "An external revision"))])
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

    static func verifyInlineDatabaseValues() throws {
        let link = DatabaseArtifactLink(sourceID: "device:test", databaseID: "scalar", relativePath: "data.sqlite",
                                       sqliteQuery: "SELECT sum(amount) FROM sales")
        let inline = NoteTextRun(text: "12", bold: true, databaseLink: link, databaseValueID: "revenue")
        let original = NoteDocument(blocks: [.richText(.init(id: "summary", runs: [
            .init(text: "Revenue: "), inline, .init(text: " EUR today", italic: true)
        ]))])
        var saved = original
        let controller = DashboardNoteEditorController()
        let editor = DashboardNoteEditor(document: Binding(get: { saved }, set: { saved = $0 }), controller: controller)
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        defer { window.close() }
        guard let textView = controller.textView,
              let coordinator = textView.delegate as? DashboardNoteEditor.Coordinator else {
            throw Failure(description: "Hosted inline-value editor missing")
        }
        coordinator.apply(original, to: textView)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        guard case .richText(var text) = saved.blocks[0] else { throw Failure(description: "Inline paragraph missing") }
        var linked = text.runs.filter { $0.databaseValueID == "revenue" }
        try require(linked.count == 1 && linked[0].databaseLink == link && linked[0].bold,
                    "Inline link, identity or formatting was lost in native attributed roundtrip")
        let selected = (textView.string as NSString).range(of: "EUR")
        textView.setSelectedRange(selected)
        try require(text.refreshDatabaseValue(id: "revenue", expectedRuns: linked, value: "6789"), "Scalar did not refresh")
        saved.blocks[0] = .richText(text)
        coordinator.apply(saved, to: textView)
        try require(textView.selectedRange() == (textView.string as NSString).range(of: "EUR"),
                    "Native selection moved away from surrounding prose after a scalar changed width")
        try require(saved.plainText == "Revenue: 6789 EUR today", "Scalar refresh rewrote surrounding prose")

        let valueRange = (textView.string as NSString).range(of: "6789")
        textView.textStorage!.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue,
                                          range: NSRange(location: valueRange.location + 1, length: 3))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        guard case .richText(let formatted) = saved.blocks[0] else { throw Failure(description: "Formatted scalar missing") }
        text = formatted
        linked = text.runs.filter { $0.databaseValueID == "revenue" }
        try require(linked.count == 2 && linked.allSatisfy { $0.databaseLink == link },
                    "Native formatting lost the shared inline-value metadata")
        try require(text.refreshDatabaseValue(id: "revenue", expectedRuns: linked, value: "12345"), "Formatted scalar did not refresh")
        try require(text.runs.filter { $0.databaseValueID == "revenue" }.map(\.text).joined() == "12345",
                    "Formatted fragments duplicated the linked value")
        try require(text.runs.last?.italic == true && text.runs.last?.text == " EUR today", "Prose formatting changed")
        saved.blocks[0] = .richText(text)
        coordinator.apply(saved, to: textView)

        linked = text.runs.filter { $0.databaseValueID == "revenue" }
        var edited = linked
        edited[0].text = "User edit"
        try require(!text.refreshDatabaseValue(id: "revenue", expectedRuns: edited, value: "999"),
                    "A stale refresh overwrote changed linked text")
        try require(text.refreshDatabaseValue(id: "revenue", expectedRuns: linked, value: ""), "Empty scalar did not refresh")
        saved.blocks[0] = .richText(text)
        coordinator.apply(saved, to: textView)
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        guard case .richText(let empty) = saved.blocks[0] else { throw Failure(description: "Empty scalar missing") }
        try require(empty.runs.contains { $0.databaseValueID == "revenue" && $0.databaseLink == link && $0.text.isEmpty },
                    "An empty SQL value lost its live link in the native editor")
        try require(saved.plainText == "Revenue:  EUR today", "Empty scalar leaked its editor placeholder into saved text")

        text = empty
        linked = text.runs.filter { $0.databaseValueID == "revenue" }
        try require(text.refreshDatabaseValue(id: "revenue", expectedRuns: linked, value: "123"), "Empty scalar could not become nonempty")
        saved.blocks[0] = .richText(text)
        coordinator.apply(saved, to: textView)
        let middle = (textView.string as NSString).range(of: "2")
        textView.undoManager?.removeAllActions()
        textView.undoManager?.beginUndoGrouping()
        try require(!coordinator.textView(textView, shouldChangeTextIn: middle, replacementString: "x"),
                    "Editing a live value should use one native undoable edit")
        textView.undoManager?.endUndoGrouping()
        guard case .richText(let detached) = saved.blocks[0] else { throw Failure(description: "Detached scalar missing") }
        try require(detached.runs.allSatisfy { $0.databaseLink == nil && $0.databaseValueID == nil },
                    "Editing live text left a link that would overwrite the user edit")
        try require(saved.plainText == "Revenue: 1x3 EUR today", "Detaching a scalar changed other text")
        controller.undo()
        guard case .richText(let restored) = saved.blocks[0] else { throw Failure(description: "Undo lost inline paragraph") }
        try require(saved.plainText == "Revenue: 123 EUR today" && restored.runs.contains { $0.databaseLink == link },
                    "Undo did not restore linked-value text and metadata together")
        controller.redo()
        try require(saved.plainText == "Revenue: 1x3 EUR today", "Redo did not restore explicit inline unlinking")

        coordinator.apply(original, to: textView)
        let copied = textView.textStorage!.attributedSubstring(from: (textView.string as NSString).range(of: "12"))
        textView.insertText(copied, replacementRange: NSRange(location: textView.string.utf16.count - 1, length: 0))
        guard case .richText(let pasted) = saved.blocks[0] else { throw Failure(description: "Paste lost inline paragraph") }
        let pastedIDs = Set(pasted.runs.compactMap(\.databaseValueID))
        try require(pastedIDs.count == 2 && pasted.plainText == "Revenue: 12 EUR today12",
                    "Pasting a live value reused the original identity or lost its content")

        let adjacent = NoteRichTextBlock(runs: [.init(text: "2", databaseLink: link), .init(text: "2", databaseLink: link)]).normalized()
        try require(adjacent.runs.count == 2 && adjacent.runs[0].databaseValueID != adjacent.runs[1].databaseValueID,
                    "Adjacent independent values merged into one live value")
        let raw = try JSONEncoder().encode(NoteTextRun(text: "0", databaseLink: link))
        let reopened = try JSONDecoder().decode(NoteTextRun.self, from: raw)
        try require(reopened.databaseLink == link && reopened.databaseValueID != nil, "JSON discarded inline metadata")
        print("PASS: inline database values preserve metadata, formatting, prose, native selection, empty results and explicit text-edit unlinking")
    }

    static func verifyDarkAppearancePersistence(in directory: URL) throws {
        var table = NoteTableBlock(rows: 1, columns: 1, headerRow: false)
        table.rows[0].cells[0].backgroundHex = "#FFFFFF"
        table.rows[0].cells[0].runs = [NoteTextRun(text: "Stored cell", foregroundHex: "#004225")]
        let original = NoteDocument(blocks: [
            .richText(NoteRichTextBlock(id: "dark-ink", runs: [
                NoteTextRun(text: "Legacy dark ink", foregroundHex: "#111827", highlightHex: "#FFEB94")
            ])), .table(table)
        ])
        var saved = original
        let controller = DashboardNoteEditorController()
        let editor = DashboardNoteEditor(document: Binding(get: { saved }, set: { saved = $0 }), controller: controller)
        let host = NSHostingView(rootView: editor.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        defer { window.close() }
        guard let textView = controller.textView, let manager = textView.undoManager else {
            throw Failure(description: "Dark appearance fixture did not attach the native editor")
        }
        manager.removeAllActions()
        let selection = NSRange(location: 0, length: 6)
        textView.setSelectedRange(selection)
        for scheme in [ColorScheme.dark, .light, .dark] {
            host.rootView = editor.environment(\.colorScheme, scheme)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            try require(saved == original, "Switching appearance changed the stored note")
            try require(!manager.canUndo, "Switching appearance added an undo operation")
            try require(textView.selectedRange() == selection, "Switching appearance lost note selection")
            try require(DashboardColors.isDark(textView.effectiveAppearance) == (scheme == .dark),
                        "The native editor did not follow the selected theme")
            if scheme == .light {
                let nativeLinks = NSTextView().linkTextAttributes
                let expected = DashboardColors.documentColorHex(nativeLinks?[.foregroundColor] as? NSColor)
                let actual = DashboardColors.documentColorHex(textView.linkTextAttributes?[.foregroundColor] as? NSColor)
                try require(actual == expected, "Returning to Light changed the native Notes link color")
            }
        }
        let ink = textView.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        let highlight = textView.textStorage!.attribute(.backgroundColor, at: 0, effectiveRange: nil) as! NSColor
        var darkInk: NSColor?, darkHighlight: NSColor?
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            darkInk = ink.usingColorSpace(.sRGB)
            darkHighlight = highlight.usingColorSpace(.sRGB)
        }
        try require(darkInk!.redComponent > 0.5 && darkHighlight!.redComponent < 0.4,
                    "Dark notes retained dark ink or a glaring light highlight")
        guard let coordinator = textView.delegate as? DashboardNoteEditor.Coordinator else {
            throw Failure(description: "Dark appearance fixture lost its real coordinator")
        }
        textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 6), with: "Edited")
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        guard case .richText(let block) = saved.blocks[0], case .table(let storedTable) = saved.blocks[1] else {
            throw Failure(description: "Dark edit lost note structure")
        }
        try require(block.runs.first?.foregroundHex == "#111827", "Dark edit persisted bright display ink")
        try require(block.runs.first?.highlightHex == "#FFEB94", "Dark edit persisted the dimmed highlight")
        try require(storedTable.rows[0].cells[0].backgroundHex == "#FFFFFF", "Dark edit changed the authored table fill")
        try require(storedTable.rows[0].cells[0].runs.first?.foregroundHex == "#004225", "Dark edit changed authored cell ink")
        let path = directory.appendingPathComponent("dark-note.json")
        try saved.encoded().write(to: path, atomically: true, encoding: .utf8)
        let reopened = NoteDocument.decode(try String(contentsOf: path, encoding: .utf8))
        try require(reopened == saved, "Dark note formatting did not survive save and reopen")
        print("PASS: native light/dark switching preserves note selection, undo history, authored ink, highlights and table fills through edit/save/reopen")
    }

    static func verifyMetadata(_ document: NoteDocument, original: NoteDocument, label: String) throws {
        try require(document.databaseLink == original.databaseLink, "Database link lost \(label)")
        try require(document.kind == original.kind, "Artifact kind lost \(label)")
        try require(document.html == original.html, "HTML metadata lost \(label)")
        try require(document.version == NoteDocument.currentVersion, "Version not normalized \(label)")
    }
}

import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor struct AssetToolbarHistoryTests {
    private func page() throws -> NoteDocument {
        var page = NoteDocument(kind: .canvas)
        _ = try page.apply([.page(.init(action: .add, id: "intro", patch: .init(text: "Intro")))])
        _ = try page.apply([.page(.init(action: .add, id: "plan", kind: .section, patch: .init(title: "Plan")))])
        return page
    }

    @Test func addComponentInsertsAtTheCursorThenTheSelection() throws {
        let page = try page()
        var state = CanvasViewState()
        #expect(state.insertionPosition(in: page) == PagePosition())
        state.selected = ["intro"]
        state.cursor = .init(selection: ["intro"], position: .init(afterID: "intro"))
        #expect(state.insertionPosition(in: page) == PagePosition(afterID: "intro"))
        // Selecting a section moves insertion inside it, ignoring the old cursor.
        state.selected = ["plan"]
        #expect(state.insertionPosition(in: page) == PagePosition(parentID: "plan"))
        // A cursor whose paragraph is gone falls back to the selection.
        state.selected = ["intro"]
        state.cursor = .init(selection: ["intro"], position: .init(afterID: "removed"))
        #expect(state.insertionPosition(in: page) == PagePosition(afterID: "intro"))
    }

    private static let grid: NoteDocument = {
        var document = NoteDocument(kind: .spreadsheet)
        document.blocks = []
        document.ensureSpreadsheetTable()
        return document
    }()

    private func sheet(_ text: String) -> NoteDocument {
        var document = Self.grid
        document.mutateSpreadsheetTable { $0.rows[0].cells[0].runs = text.isEmpty ? [] : [NoteTextRun(text: text)] }
        return document
    }

    @Test func sheetUndoMergesQuickTypingAndStopsAtOutsideChanges() {
        let history = SheetUndoHistory()
        let start = Date(timeIntervalSince1970: 1_000)
        var empty = NoteDocument(kind: .spreadsheet)
        empty.blocks = []
        let grid = sheet("")
        history.recordLocal(from: empty, to: grid, at: start)
        #expect(!history.canUndo)
        history.recordLocal(from: grid, to: sheet("a"), at: start.addingTimeInterval(0.1))
        history.recordLocal(from: sheet("a"), to: sheet("ab"), at: start.addingTimeInterval(0.4))
        history.recordLocal(from: sheet("ab"), to: sheet("abc"), at: start.addingTimeInterval(3))
        #expect(history.undo(current: sheet("abc"))?.spreadsheetTable.rows[0].cells[0].plainText == "ab")
        #expect(history.undo(current: sheet("ab"))?.spreadsheetTable.rows[0].cells[0].plainText == "")
        #expect(!history.canUndo)
        #expect(history.redo(current: grid)?.spreadsheetTable.rows[0].cells[0].plainText == "ab")
        // Someone else changed the Sheet: undo refuses and clears its history.
        #expect(history.undo(current: sheet("agent")) == nil)
        #expect(!history.canUndo && !history.canRedo)
    }

    @Test func artifactUndoStepsThroughCodeChanges() {
        let history = ArtifactCodeHistory()
        history.observe(old: "<p>v1</p>", new: "<p>v2</p>")
        history.observe(old: "<p>v2</p>", new: "<p>v3</p>")
        let undone = history.undo(current: "<p>v3</p>")
        #expect(undone == "<p>v2</p>")
        // Restoring is not itself a new change.
        history.observe(old: "<p>v3</p>", new: "<p>v2</p>")
        #expect(history.canUndo && history.canRedo)
        #expect(history.redo(current: "<p>v2</p>") == "<p>v3</p>")
        history.observe(old: "<p>v2</p>", new: "<p>v3</p>")
        history.observe(old: "<p>v3</p>", new: "<p>v4</p>")
        #expect(!history.canRedo)
        #expect(history.undo(current: "<p>v4</p>") == "<p>v3</p>")
    }
}

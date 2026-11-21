import Foundation
import Observation
import WovenProtocol

// Compiled by both apps: what an artifact's editor counts and remembers,
// whatever draws it.

struct NoteTextStatistics: Equatable {
    let words: Int
    let characters: Int

    init(document: NoteDocument) {
        let text = document.plainText
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        self.words = words
        characters = text.count
    }
}

/// Sheet undo: each local edit is a step, with typing in quick succession
/// merged into one. A change from elsewhere clears the history, so undo never
/// restores an old Sheet over someone else's work.
@MainActor @Observable final class SheetUndoHistory {
    private var undoStack: [NoteDocument] = []
    private var redoStack: [NoteDocument] = []
    @ObservationIgnored private var current: NoteDocument?
    @ObservationIgnored private var lastEdit = Date.distantPast
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func recordLocal(from before: NoteDocument, to after: NoteDocument, at now: Date = .now) {
        guard before.normalized() != after.normalized() else { return }
        // Creating the Sheet's grid when it first opens is not an edit.
        guard before.blocks.contains(where: { if case .table = $0 { true } else { false } }) else { current = after; return }
        if !matches(before) { undoStack.removeAll(); redoStack.removeAll() }
        if undoStack.isEmpty || now.timeIntervalSince(lastEdit) > 1 {
            undoStack.append(before)
            if undoStack.count > 50 { undoStack.removeFirst() }
        }
        lastEdit = now
        redoStack.removeAll()
        current = after
    }

    func undo(current document: NoteDocument) -> NoteDocument? {
        guard matches(document) else { undoStack.removeAll(); redoStack.removeAll(); return nil }
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(document); current = previous; lastEdit = .distantPast
        return previous
    }

    func redo(current document: NoteDocument) -> NoteDocument? {
        guard matches(document) else { undoStack.removeAll(); redoStack.removeAll(); return nil }
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(document); current = next; lastEdit = .distantPast
        return next
    }

    private func matches(_ document: NoteDocument) -> Bool {
        current.map { $0.normalized() == document.normalized() } ?? true
    }
}

/// Artifact undo steps through code changes seen while the Artifact is open,
/// usually an agent's edits. Saved inputs are not part of it.
@MainActor @Observable final class ArtifactCodeHistory {
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    @ObservationIgnored private var restoring: String?
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func observe(old: String, new: String) {
        guard old != new else { return }
        if restoring == new { restoring = nil; return }
        restoring = nil
        undoStack.append(old)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo(current: String) -> String? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current); restoring = previous
        return previous
    }

    func redo(current: String) -> String? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current); restoring = next
        return next
    }
}

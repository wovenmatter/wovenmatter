import Foundation
import WovenMatterCore

struct PageCursor: Equatable {
    var selection: Set<String>
    var position: PagePosition
}

/// Page view state: the selected component, the details panel, and the component undo
/// history that incoming work fences.
struct CanvasViewState {
    var selected = Set<String>()
    var error: String?
    var showsInspector = false
    var revealCardID: String?
    /// Where the text cursor last was, for Add component. It applies only while
    /// the selection it was recorded with is still the selection.
    var cursor: PageCursor?
    /// Set while the Existing asset picker is open: where the chosen asset goes.
    var assetPickerPosition: PagePosition?
    var importingImage = false
    /// Incremented to place the cursor at the end of the Page's last text.
    var focusEndRequest = 0
    var undoStack: [NoteDocument] = []
    var redoStack: [NoteDocument] = []
    private var pendingLocalDocument: NoteDocument?
    private var lastKnownDocument: NoteDocument?

    /// Where Add component inserts: at the cursor, else after the selected
    /// component (inside it for a section), else at the end of the Page.
    func insertionPosition(in page: NoteDocument) -> PagePosition {
        let ids = Set(page.blocks.map(\.id))
        func exists(_ id: String?) -> Bool { id.map(ids.contains) ?? true }
        if let cursor, cursor.selection == selected, exists(cursor.position.parentID), exists(cursor.position.afterID) {
            return cursor.position
        }
        guard let id = selected.first, ids.contains(id) else { return .init() }
        return page.pageComponentKind(for: id) == .section ? .init(parentID: id)
            : .init(parentID: page.pageParentID(for: id), afterID: id)
    }

    @discardableResult mutating func observe(_ old: NoteDocument, _ new: NoteDocument) -> Bool {
        selected.formIntersection(Set(new.blocks.map(\.id)))
        if pendingLocalDocument.map({ sameContent($0, new) }) == true || sameContent(old, new) {
            pendingLocalDocument = nil
            lastKnownDocument = new
            return false
        }
        // Incoming work is a history boundary. Undo must never restore an old
        // whole-document snapshot over another participant's changes.
        undoStack.removeAll(); redoStack.removeAll()
        pendingLocalDocument = nil
        lastKnownDocument = new
        return true
    }
    mutating func recordLocalChange(from old: NoteDocument, to new: NoteDocument, undoable: Bool = true) {
        // The binding saves a normalized document. Track that exact shape so
        // merging adjacent text runs is never mistaken for incoming work.
        let before = old.normalized(), after = new.normalized()
        guard !sameContent(before, after) else { return }
        if let lastKnownDocument, !sameContent(lastKnownDocument, before) {
            undoStack.removeAll(); redoStack.removeAll()
        }
        if undoable {
            undoStack.append(before)
            if undoStack.count > 30 { undoStack.removeFirst() }
        } else {
            // Native text has its own shared Page undo manager. A later whole-
            // document component undo must not erase edits in another text flow.
            undoStack.removeAll()
        }
        redoStack.removeAll()
        pendingLocalDocument = after; lastKnownDocument = after
    }
    mutating func undo(_ document: inout NoteDocument) {
        guard historyMatches(document), let previous = undoStack.last,
              let restored = restored(previous, from: document) else { return }
        undoStack.removeLast(); redoStack.append(document)
        pendingLocalDocument = restored; lastKnownDocument = restored; document = restored
    }
    mutating func redo(_ document: inout NoteDocument) {
        guard historyMatches(document), let next = redoStack.last,
              let restored = restored(next, from: document) else { return }
        redoStack.removeLast(); undoStack.append(document)
        pendingLocalDocument = restored; lastKnownDocument = restored; document = restored
    }
    private mutating func historyMatches(_ document: NoteDocument) -> Bool {
        guard lastKnownDocument.map({ sameContent($0, document) }) ?? true else {
            undoStack.removeAll(); redoStack.removeAll(); pendingLocalDocument = nil
            lastKnownDocument = document
            error = "The Page changed. Local undo history has been cleared to preserve incoming work."
            return false
        }
        return true
    }
    private func sameContent(_ lhs: NoteDocument, _ rhs: NoteDocument) -> Bool {
        func content(_ source: NoteDocument) -> NoteDocument {
            var value = source.normalized()
            var items: [String: BoardItem] = [:]
            for (id, original) in value.boardItems ?? [:] {
                var item = original
                item.createdBy = nil; item.createdAt = nil; item.updatedBy = nil; item.updatedAt = nil
                if item != BoardItem() { items[id] = item }
            }
            value.boardItems = items.isEmpty ? nil : items
            return value
        }
        return content(lhs) == content(rhs)
    }
    private mutating func restored(_ snapshot: NoteDocument, from current: NoteDocument) -> NoteDocument? {
        do {
            var value = snapshot
            value.stampBoardChanges(from: current, actor: .init(kind: .user))
            value = value.normalized()
            try value.validateEditableShape()
            let bytes = try value.encoded().utf8.count, previousBytes = try current.encoded().utf8.count
            guard bytes <= NoteDocument.maximumBoardBytes || bytes < previousBytes else { throw NoteDocumentSafetyError.tooLarge }
            error = nil
            return value
        } catch { self.error = error.localizedDescription; return nil }
    }
}

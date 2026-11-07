import SwiftUI
import WovenMatterCore

struct DashboardCanvasViewState {
    enum NavigatorFilter: String, CaseIterable { case all = "All items", tasks = "Tasks", review = "Needs review", instructions = "Instructions" }
    var zoom = 1.0
    var isPanning = false
    var origin = CGPoint(x: -24, y: -24)
    var viewport = CGSize(width: 1000, height: 700)
    var selected = Set<String>()
    var error: String?
    var showsInspector = false
    var showsNavigator = false
    var navigatorFilter = NavigatorFilter.all
    var revealCardID: String?
    var undoStack: [NoteDocument] = []
    var redoStack: [NoteDocument] = []
    private var pendingLocalDocument: NoteDocument?
    private var lastKnownDocument: NoteDocument?

    var context: CanvasViewportContext {
        .init(x: origin.x, y: origin.y, width: viewport.width / zoom, height: viewport.height / zoom,
              zoom: zoom, selectedCardIDs: Array(selected))
    }
    var visibleRect: CGRect { CGRect(x: origin.x, y: origin.y, width: viewport.width / zoom, height: viewport.height / zoom) }
    mutating func setZoom(_ value: Double) {
        let next = min(4, max(0.1, value))
        origin.x += viewport.width / 2 / zoom - viewport.width / 2 / next
        origin.y += viewport.height / 2 / zoom - viewport.height / 2 / next
        zoom = next
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
    mutating func fit(_ document: NoteDocument, selectionOnly: Bool = false) {
        let cards = document.blocks.filter { !selectionOnly || selected.contains($0.id) }
        let placements = document.canvasPlacements
        let rects = cards.compactMap { placements[$0.id]?.rect }
        guard var bounds = rects.first else { origin = CGPoint(x: -24, y: -24); zoom = 1; return }
        for rect in rects.dropFirst() { bounds = bounds.union(rect) }
        bounds = bounds.insetBy(dx: -48, dy: -48)
        zoom = min(2, max(0.1, min(viewport.width / bounds.width, viewport.height / bounds.height)))
        origin = CGPoint(x: bounds.midX - viewport.width / zoom / 2, y: bounds.midY - viewport.height / zoom / 2)
    }
}

extension CanvasCardPlacement {
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

func canvasColor(_ name: String?) -> Color {
    switch name {
    case "green": DashboardPalette.success
    case "blue": .blue
    case "purple": .purple
    case "orange": .orange
    case "pink": .pink
    default: DashboardPalette.mutedForeground
    }
}

/// Shared UI mutations use the same validator and edit semantics as agent batches.
func commitCanvas(_ edits: [CanvasEdit], document: Binding<NoteDocument>, state: Binding<DashboardCanvasViewState>) {
    do {
        let before = document.wrappedValue
        var value = before
        let operations = edits.map(NoteEditOperation.canvas)
        // A retained development Board may predate the shared byte limit. Let
        // its user shrink it in steps; new Boards keep the transport limit.
        guard !operations.isEmpty, operations.count <= RemoteNoteEditEnvelope.maximumOperationCount else {
            throw RemoteNoteEditError.invalidEnvelope
        }
        let previousBytes = try before.encoded().utf8.count
        if previousBytes <= NoteDocument.maximumBoardBytes {
            try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: value)
        }
        _ = try value.apply(operations)
        value.stampBoardChanges(from: before, actor: .init(kind: .user))
        try value.validateEditableShape()
        let bytes = try value.encoded().utf8.count
        guard bytes <= NoteDocument.maximumBoardBytes || bytes < previousBytes else { throw NoteDocumentSafetyError.tooLarge }
        state.wrappedValue.recordLocalChange(from: before, to: value)
        document.wrappedValue = value
        state.wrappedValue.error = nil
    } catch { state.wrappedValue.error = error.localizedDescription }
}

/// Read the current value for each focused edit; never save an inspector snapshot.
func commitBoard(document: Binding<NoteDocument>, state: Binding<DashboardCanvasViewState>,
                 change: (inout NoteDocument) -> Void) {
    do {
        let before = document.wrappedValue
        var value = before
        change(&value)
        value.stampBoardChanges(from: before, actor: .init(kind: .user))
        try value.validateEditableShape()
        let bytes = try value.encoded().utf8.count
        let previousBytes = try before.encoded().utf8.count
        guard bytes <= NoteDocument.maximumBoardBytes || bytes < previousBytes else {
            throw NoteDocumentSafetyError.tooLarge
        }
        state.wrappedValue.recordLocalChange(from: before, to: value)
        document.wrappedValue = value
        state.wrappedValue.error = nil
    } catch { state.wrappedValue.error = error.localizedDescription }
}

func addBoardTask(document: Binding<NoteDocument>, state: Binding<DashboardCanvasViewState>) {
    let block = NoteRichTextBlock(text: "New task")
    let placement = document.wrappedValue.nextBoardPlacement()
    commitBoard(document: document, state: state) { value in
        value.blocks.append(.richText(block))
        if value.canvas == nil { value.canvas = [:] }
        value.canvas?[block.id] = placement
        if value.boardItems == nil { value.boardItems = [:] }
        var item = BoardItem()
        item.task = BoardTask()
        value.boardItems?[block.id] = item
    }
    if state.wrappedValue.error == nil {
        state.wrappedValue.selected = [block.id]
        state.wrappedValue.revealCardID = block.id
        state.wrappedValue.showsInspector = true
    }
}

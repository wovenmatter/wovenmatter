import SwiftUI
import WovenMatterCore

struct DashboardCanvasViewState {
    var zoom = 1.0
    var isPanning = false
    var origin = CGPoint(x: -24, y: -24)
    var viewport = CGSize(width: 1000, height: 700)
    var selected = Set<String>()
    var error: String?
    var showsInspector = false
    var showsNavigator = false
    var revealCardID: String?
    var undoStack: [NoteDocument] = []
    var redoStack: [NoteDocument] = []
    var restoring = false

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
    mutating func observe(_ old: NoteDocument, _ new: NoteDocument) {
        selected.formIntersection(Set(new.blocks.map(\.id)))
        if restoring { restoring = false; return }
        undoStack.append(old)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    mutating func undo(_ document: inout NoteDocument) {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document); restoring = true; document = previous
    }
    mutating func redo(_ document: inout NoteDocument) {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document); restoring = true; document = next
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
        var value = document.wrappedValue
        let operations = edits.map(NoteEditOperation.canvas)
        try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: value)
        _ = try value.apply(operations)
        document.wrappedValue = value
        state.wrappedValue.error = nil
    } catch { state.wrappedValue.error = error.localizedDescription }
}

import SwiftUI
import WovenMatterCore

struct DashboardPageTextFlow: View {
    @Binding var document: NoteDocument
    @Binding var viewState: DashboardCanvasViewState
    let blockIDs: [String]
    let parentID: String?
    let afterID: String?
    let flowID: String
    let undoManager: UndoManager
    var onFocus: ((DashboardNoteEditorController) -> Void)?
    @State private var controller = DashboardNoteEditorController()
    @State private var dictationEditor = DictationEditor()
    @State private var editContext = PageFlowEditingContext()

    var body: some View {
        let base = document.materializedPage()
        DashboardNoteEditor(document: flowBinding(base: base), controller: controller,
            dictationEditor: dictationEditor, dictationIdentity: "page:\(flowID)",
            sizesToContent: true, editsPageFlow: true, onFocus: { controller in
                if let id = controller.selectedBlockID, document.blocks.contains(where: { $0.id == id }) {
                    viewState.selected = [id]
                } else { viewState.selected = Set(parentID.map { [$0] } ?? []) }
                onFocus?(controller)
            }, onSynchronize: { editContext.base = document.materializedPage() }, sharedUndoManager: undoManager)
            .frame(minHeight: 40)
            .accessibilityLabel("Page document text")
            .accessibilityHint("Use Component actions to change task state or move the selected component.")
            .onAppear { focusRequestedComponent() }
            .onChange(of: viewState.revealCardID) { _, _ in focusRequestedComponent() }
    }

    private func liveIDs(in page: NoteDocument) -> [String] {
        for segment in page.pageSegments {
            if case let .flow(id, _, _, _, ids) = segment, id == flowID { return ids }
        }
        return blockIDs
    }

    private func flowBinding(base: NoteDocument) -> Binding<NoteDocument> {
        Binding(get: {
            let page = document.materializedPage()
            let ids = liveIDs(in: page)
            var flow = page.pageFlowDocument(blockIDs: ids)
            // Page text uses the same native editor, adding only task metadata
            // and gutter actions. This small projection is never saved itself.
            flow.kind = .canvas
            if ids.isEmpty { flow.blocks = [.richText(.init(id: editContext.emptyBlockID(in: page), text: ""))] }
            let items = (page.boardItems ?? [:]).filter { ids.contains($0.key) }.mapValues { source in
                var item = source
                item.createdBy = nil; item.createdAt = nil; item.updatedBy = nil; item.updatedAt = nil
                return item
            }.filter { $0.value != BoardItem() }
            flow.boardItems = items.isEmpty ? nil : items
            return flow
        }, set: { updated in
            do {
                let base = editContext.base ?? base
                var local = base
                try local.spliceFlow(liveIDs(in: base), with: updated.blocks, parentID: parentID, afterID: afterID)
                let included = Set(local.blocks.map(\.id))
                for block in updated.blocks where included.contains(block.id) {
                    if let changed = updated.boardItems?[block.id] {
                        if var item = local.boardItems?[block.id] {
                            // Text editing only starts, ends or checks off a task. Details
                            // belong to Component details, so restored text attributes
                            // (such as from undo) cannot revert them.
                            if let task = changed.task {
                                if item.task == nil { item.task = task } else { item.task?.status = task.status }
                            } else { item.task = nil }
                            local.boardItems?[block.id] = item
                        } else {
                            var item = BoardItem()
                            item.task = changed.task; item.review = changed.review; item.role = changed.role
                            item.lastChange = changed.lastChange; item.sessions = changed.sessions
                            if local.boardItems == nil { local.boardItems = [:] }
                            local.boardItems?[block.id] = item
                        }
                    } else if let previous = local.boardItems?[block.id], previous.task != nil {
                        local.boardItems?[block.id]?.task = nil
                    }
                }
                let remote = document.materializedPage()
                let merged = try NoteDocument.mergePage(base: base, local: local, remote: remote)
                commitPage(document: $document, state: $viewState, recordsComponentUndo: false) { $0 = merged.document }
                editContext.base = document.materializedPage()
                if !merged.conflictedIDs.isEmpty {
                    viewState.error = "Concurrent edits were retained as separate components and marked for review."
                }
            } catch { viewState.error = error.localizedDescription }
        })
    }

    private func focusRequestedComponent() {
        guard let id = viewState.revealCardID, liveIDs(in: document.materializedPage()).contains(id) else { return }
        DispatchQueue.main.async { controller.focus(blockID: id, atEnd: true) }
    }
}

@MainActor final class PageFlowEditingContext {
    var base: NoteDocument?
    private var emptyID = UUID().uuidString.lowercased()
    func emptyBlockID(in page: NoteDocument) -> String {
        if page.blocks.contains(where: { $0.id == emptyID }) { emptyID = UUID().uuidString.lowercased() }
        return emptyID
    }
}

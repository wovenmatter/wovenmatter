import SwiftUI
import WovenMatterCore

struct DashboardPageComponentMenu: View {
    @Binding var document: NoteDocument
    @Binding var viewState: DashboardCanvasViewState
    let componentID: String
    private var page: NoteDocument { document.materializedPage() }

    var body: some View {
        let page = self.page
        Menu {
            Button("Component details") { viewState.selected = [componentID]; viewState.showsInspector = true }
            if let task = page.boardItems?[componentID]?.task {
                Button(task.status == .done ? "Reopen task" : "Complete task") {
                    apply(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
                        patch: .init(status: task.status == .done ? .todo : .done)))
                }
            }
            if page.pageComponentKind(for: componentID) != .section {
              Button(page.boardItems?[componentID]?.task == nil ? "Turn into task" : "Remove task state") {
                apply(.init(action: .update, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
                    patch: page.boardItems?[componentID]?.task == nil ? .init(status: .todo) : .init(clearTask: true)))
            }
            }
            Divider()
            Button("Move up") { move(direction: -1) }.disabled(siblingIndex == 0)
            Button("Move down") { move(direction: 1) }.disabled(siblingIndex >= siblings.count - 1)
            if let parent = page.pageParentID(for: componentID) {
                Button("Move out of section") { move(to: .init(parentID: page.pageParentID(for: parent), afterID: parent)) }
            }
            Menu("Move into section") {
                let subtree = Set(page.pageSubtreeIDs(of: componentID))
                ForEach(page.blocks.filter { page.pageNodes?[$0.id]?.isSection == true && !subtree.contains($0.id) }, id: \.id) { block in
                    Button(block.plainText.isEmpty ? "Untitled section" : block.plainText) { move(to: .init(parentID: block.id)) }
                }
                Button("Page root") { move(to: .init()) }
            }
            Divider()
            if page.pageComponentKind(for: componentID) == .section {
                Button("Remove section, keep content") { remove(.promoteChildren) }
                Button("Remove section and content", role: .destructive) { remove(.removeSubtree) }
            } else {
                Button("Remove component", role: .destructive) { remove(nil) }
            }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Component actions")
    }

    private var siblings: [String] { page.pageChildren(of: page.pageParentID(for: componentID)) }
    private var siblingIndex: Int { siblings.firstIndex(of: componentID) ?? 0 }
    private func move(direction: Int) {
        let destination = siblingIndex + direction
        guard siblings.indices.contains(destination) else { return }
        let position: PagePosition
        if direction < 0 {
            position = .init(parentID: page.pageParentID(for: componentID),
                afterID: destination > 0 ? siblings[destination - 1] : nil, atStart: destination == 0)
        } else { position = .init(parentID: page.pageParentID(for: componentID), afterID: siblings[destination]) }
        move(to: position)
    }
    private func move(to position: PagePosition) {
        apply(.init(action: .move, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
            expectedSubtreeRevision: page.pageSubtreeRevision(for: componentID), position: position))
    }
    private func remove(_ removal: PageEdit.Removal?) {
        apply(.init(action: .remove, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
            expectedSubtreeRevision: removal == .removeSubtree ? page.pageSubtreeRevision(for: componentID) : nil, removal: removal))
    }
    private func apply(_ edit: PageEdit) { commitPage(document: $document, state: $viewState) { try $0.applyPageEdit(edit) } }
}

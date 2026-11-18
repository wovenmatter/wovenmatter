import AppKit
import SwiftUI
import WovenMatterCore

/// One entry in a Page menu, rendered by SwiftUI menus and AppKit context menus alike.
indirect enum PageMenuEntry {
    case button(String, destructive: Bool = false, enabled: Bool = true, action: () -> Void)
    case divider
    case submenu(String, [PageMenuEntry])

    @MainActor var menuItem: NSMenuItem {
        switch self {
        case let .button(title, _, enabled, action):
            let item = ClosureMenuItem(title, handler: action)
            if !enabled { item.action = nil }
            return item
        case .divider: return .separator()
        case let .submenu(title, entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for entry in entries { menu.addItem(entry.menuItem) }
            item.submenu = menu
            return item
        }
    }
}

struct PageMenuEntries: View {
    let entries: [PageMenuEntry]
    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case let .button(title, destructive, enabled, action):
                Button(title, role: destructive ? .destructive : nil, action: action).disabled(!enabled)
            case .divider: Divider()
            case let .submenu(title, entries): Menu(title) { PageMenuEntries(entries: entries) }
            }
        }
    }
}

struct PageComponentMenu: View {
    @Binding var document: NoteDocument
    @Binding var viewState: CanvasViewState
    let componentID: String

    var body: some View {
        Menu {
            PageMenuEntries(entries: PageComponentActions(document: $document, viewState: $viewState, componentID: componentID).entries)
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Component actions")
    }
}

/// Review, task state, moving and removing one component.
@MainActor struct PageComponentActions {
    @Binding var document: NoteDocument
    @Binding var viewState: CanvasViewState
    let componentID: String
    private var page: NoteDocument { document.materializedPage() }

    var entries: [PageMenuEntry] {
        let page = self.page
        guard page.blocks.contains(where: { $0.id == componentID }) else { return [] }
        let id = componentID
        let item = page.boardItems?[id]
        var result: [PageMenuEntry] = []
        // An agent can ask the person to look at a component it added or changed.
        if item?.review == .needed {
            result.append(.button("Mark reviewed") { setReview(.approved) })
            result.append(.button("Dismiss review") { setReview(.dismissed) })
        }
        let isSection = page.pageComponentKind(for: id) == .section
        if !isSection && item?.task == nil {
            result.append(.button("Turn into task") {
                apply(.init(action: .update, id: id, expectedRevision: page.boardItemRevision(for: id), patch: .init(status: .todo)))
            })
        }
        let siblings = page.pageChildren(of: page.pageParentID(for: id))
        let index = siblings.firstIndex(of: id) ?? 0
        result.append(.divider)
        result.append(.button("Move up", enabled: index > 0) { move(direction: -1) })
        result.append(.button("Move down", enabled: index < siblings.count - 1) { move(direction: 1) })
        if let parent = page.pageParentID(for: id) {
            result.append(.button("Move out of section") { move(to: .init(parentID: page.pageParentID(for: parent), afterID: parent)) })
        }
        let subtree = Set(page.pageSubtreeIDs(of: id))
        let sections = page.blocks.filter { page.pageNodes?[$0.id]?.isSection == true && !subtree.contains($0.id) }
        result.append(.submenu("Move into section", sections.map { block in
            .button(block.plainText.isEmpty ? "Untitled section" : block.plainText) { move(to: .init(parentID: block.id)) }
        } + [.button("Page root") { move(to: .init()) }]))
        result.append(.divider)
        if isSection {
            result.append(.button("Remove section, keep content") { remove(.promoteChildren) })
            result.append(.button("Remove section and content", destructive: true) { remove(.removeSubtree) })
        } else {
            result.append(.button("Remove component", destructive: true) { remove(nil) })
        }
        return result
    }

    private func move(direction: Int) {
        let page = self.page
        let siblings = page.pageChildren(of: page.pageParentID(for: componentID))
        guard let index = siblings.firstIndex(of: componentID) else { return }
        let destination = index + direction
        guard siblings.indices.contains(destination) else { return }
        let position: PagePosition
        if direction < 0 {
            position = .init(parentID: page.pageParentID(for: componentID),
                afterID: destination > 0 ? siblings[destination - 1] : nil, atStart: destination == 0)
        } else { position = .init(parentID: page.pageParentID(for: componentID), afterID: siblings[destination]) }
        move(to: position)
    }
    private func move(to position: PagePosition) {
        let page = self.page
        apply(.init(action: .move, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
            expectedSubtreeRevision: page.pageSubtreeRevision(for: componentID), position: position))
    }
    private func remove(_ removal: PageEdit.Removal?) {
        let page = self.page
        apply(.init(action: .remove, id: componentID, expectedRevision: page.boardItemRevision(for: componentID),
            expectedSubtreeRevision: removal == .removeSubtree ? page.pageSubtreeRevision(for: componentID) : nil, removal: removal))
    }
    private func setReview(_ review: BoardReviewState) {
        commitPage(document: $document, state: $viewState) { page in
            guard var item = page.boardItems?[componentID] else { return }
            item.review = review
            page.boardItems?[componentID] = item
        }
    }
    private func apply(_ edit: PageEdit) { commitPage(document: $document, state: $viewState) { try $0.applyPageEdit(edit) } }
}

/// Adds Page components from the toolbar's plus, a section's plus, and the
/// right-click menu, so every entry point offers the same choices.
@MainActor struct PageComponentInserter {
    let model: ApplicationModel
    @Binding var document: NoteDocument
    @Binding var viewState: CanvasViewState
    let folderID: String?

    var cursorPosition: PagePosition { viewState.insertionPosition(in: document.materializedPage()) }

    func menu(position: @escaping () -> PagePosition) -> some View {
        PageMenuEntries(entries: addEntries(position: position))
    }

    /// Task, section, table, an existing artifact or image, or a new Note, Sheet or App.
    /// Text needs no entry: typing on the Page writes text. A Page never holds a Page.
    func addEntries(position: @escaping () -> PagePosition) -> [PageMenuEntry] {
        var entries: [PageMenuEntry] = [("Task", PageComponentKind.task), ("Section", .section), ("Table", .table)]
            .map { title, kind in .button(title) { add(kind: kind, position: position()) } }
        entries += [.divider, .button("Existing artifact…") { viewState.assetPickerPosition = position() },
            .submenu("Image", PageImageImport.sources(model: model).map { source in
                .button(source.menuTitle, enabled: !viewState.importingImage) { importImage(source, position: position()) }
            })]
        entries += NoteArtifactKind.allCases.filter { $0 != .canvas }.map { kind in
            .button("New \(kind.displayName)") { createAsset(kind, position: position()) }
        }
        return entries
    }

    /// The same choices for a native text view's context menu, followed by
    /// the selected component's actions.
    func menuItems(position: @escaping () -> PagePosition) -> [NSMenuItem] {
        var items = [PageMenuEntry.submenu("Add component", addEntries(position: position)).menuItem]
        if let id = viewState.selected.first {
            let actions = PageComponentActions(document: $document, viewState: $viewState, componentID: id).entries
            if !actions.isEmpty { items.append(PageMenuEntry.submenu("Component actions", actions).menuItem) }
        }
        return items
    }

    func add(kind: PageComponentKind, assetID: String? = nil, position: PagePosition) {
        let id = UUID().uuidString.lowercased()
        commitPage(document: $document, state: $viewState) {
            try $0.applyPageEdit(.init(action: .add, id: id, kind: kind, assetID: assetID, position: position))
        }
        if viewState.error == nil { viewState.selected = [id]; viewState.revealCardID = id }
    }

    private func importImage(_ source: PageImageImport.Source, position: PagePosition) {
        if source == .photos { viewState.photoPickerPosition = position; return }
        if source == .library { viewState.libraryImagePickerPosition = position; return }
        viewState.importingImage = true
        Task {
            defer { viewState.importingImage = false }
            do {
                if let image = try await PageImageImport.chooseFile() { addImage(image, position: position) }
            } catch { viewState.error = PageImageImport.failure(error) }
        }
    }

    /// Stores the image in the Page itself.
    func addImage(_ image: PageImage, position: PagePosition) {
        let id = UUID().uuidString.lowercased()
        commitPage(document: $document, state: $viewState) {
            try $0.applyPageEdit(.init(action: .add, id: id, kind: .image, position: position, image: image))
        }
        if viewState.error == nil { viewState.selected = [id] }
    }

    private func createAsset(_ kind: NoteArtifactKind, position: PagePosition) {
        Task {
            guard let id = await model.createNote(folderID: folderID, kind: kind) else { return }
            add(kind: .asset, assetID: id, position: position)
        }
    }
}

/// A menu item that runs a closure, for adding SwiftUI actions to AppKit menus.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func run() { handler() }
}

/// The toolbar's Add component button. It is an ordinary toolbar icon button
/// that opens the add menu below itself at the cursor's position.
struct PageAddComponentButton: View {
    let inserter: PageComponentInserter
    @State private var anchor = MenuAnchorHolder()

    var body: some View {
        Button {
            anchor.popUp(inserter.addEntries { inserter.cursorPosition }.map(\.menuItem))
        } label: {
            Image(systemName: "plus").font(.system(size: 14)).frame(width: 32, height: 32)
        }
        .buttonStyle(WovenIconButtonStyle())
        .background(MenuAnchor(holder: anchor))
        .help("Add component").accessibilityLabel("Add component")
    }
}

@MainActor final class MenuAnchorHolder {
    weak var view: NSView?
    func popUp(_ items: [NSMenuItem]) {
        guard let view else { return }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
    }
}

private struct MenuAnchor: NSViewRepresentable {
    let holder: MenuAnchorHolder
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { holder.view = view }
}

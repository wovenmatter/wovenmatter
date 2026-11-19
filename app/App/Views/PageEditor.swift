import SwiftUI
import WovenMatterCore

/// A Page is a document. Rich text stays in ordinary contiguous Notes editors;
/// sections, tasks, images and embedded artifacts provide the boundaries between those flows.
struct PageEditor: View {
    @Bindable var model: ApplicationModel
    @Binding var document: NoteDocument
    @Binding var viewState: CanvasViewState
    let noteID: String
    let folderID: String?
    var onOpenAsset: (String) -> Void
    var onOpenSession: ((String) -> Void)?
    var onFocus: ((NoteEditorController) -> Void)?
    var onSectionFocus: (() -> Void)?
    @State private var textUndoManager = UndoManager()
    @State private var collapsed = Set<String>()
    @State private var projectionCache = PageProjectionCache()

    private var projection: PageProjection { projectionCache.value(document) }
    private var page: NoteDocument { projection.document }
    private var inserter: PageComponentInserter {
        PageComponentInserter(model: model, document: $document, viewState: $viewState, folderID: folderID)
    }

    var body: some View {
        VStack(spacing: 0) {
            let attention = page.boardItems?.values.filter { $0.review == .needed }.count ?? 0
            if attention > 0 {
                HStack {
                    Spacer()
                    Menu {
                        ForEach(page.blocks.filter { page.boardItems?[$0.id]?.review == .needed }, id: \.id) { block in
                            Button(block.plainText.isEmpty ? "Review component" : String(block.plainText.prefix(80))) {
                                viewState.selected = [block.id]; viewState.revealCardID = block.id
                            }
                        }
                    } label: { Label("\(attention) to review", systemImage: "tray") }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.vertical, 6)
            }
            if let error = viewState.error {
                HStack {
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { viewState.error = nil }.buttonStyle(WovenQuietButtonStyle())
                }.foregroundStyle(WovenPalette.warning).padding(.horizontal, 24).padding(.vertical, 8)
            }
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        let segments = editorSegments.filter { visible($0) }
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(segments) { segment in
                                segmentView(segment, isLast: segment.id == segments.last?.id)
                                    .padding(.leading, CGFloat(segment.depth) * 20)
                                    .id(segment.id)
                            }
                            // The rest of the Page is part of its last line: clicking puts
                            // the cursor there, and right-clicking adds a component.
                            Color.clear.frame(maxWidth: .infinity, minHeight: 240).contentShape(Rectangle())
                                .onTapGesture { viewState.focusEndRequest += 1 }
                                .contextMenu { inserter.menu { .init() } }
                        }
                        .padding(.horizontal, 24).padding(.top, 8)
                    }.scrollIndicators(.never)
                    .onChange(of: viewState.revealCardID) { _, id in
                        guard let id else { return }
                        guard let segment = projection.segments.first(where: { segmentContains($0, id: id) }) else {
                            viewState.revealCardID = nil
                            return
                        }
                        var parent = page.pageParentID(for: id)
                        while let id = parent { collapsed.remove(id); parent = page.pageParentID(for: id) }
                        withAnimation { proxy.scrollTo(segment.id, anchor: .center) }
                        // A text flow or task clears the request after focusing its text.
                        // Sections and embeds have nothing more to do.
                        if case .flow = segment { return }
                        if case .task = segment { return }
                        DispatchQueue.main.async { if viewState.revealCardID == id { viewState.revealCardID = nil } }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { viewState.assetPickerPosition != nil },
                                    set: { if !$0 { viewState.assetPickerPosition = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Embed an artifact").font(.headline); Spacer(); Button("Done") { viewState.assetPickerPosition = nil } }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        // A Page holds Notes, Sheets and Apps; never another Page.
                        ForEach((model.workspaceOverview?.notes ?? []).filter {
                            $0.id != noteID && NoteDocument.decode($0.content).kind != .canvas
                        }, id: \.id) { asset in
                            Button {
                                let position = viewState.assetPickerPosition ?? .init()
                                viewState.assetPickerPosition = nil
                                inserter.add(kind: .asset, assetID: asset.id, position: position)
                            } label: {
                                HStack {
                                    Text(asset.title.isEmpty ? "Untitled artifact" : asset.title)
                                    Spacer()
                                    Text(NoteDocument.decode(asset.content).kind.displayName).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(WovenQuietButtonStyle())
                        }
                    }
                }
            }.padding(24).frame(width: 480, height: 420)
        }
        .modifier(PageImagePickers(model: model, viewState: $viewState, inserter: inserter))
        .onChange(of: document) { old, new in
            if viewState.observe(old, new) { textUndoManager.removeAllActions() }
        }
    }

    @ViewBuilder private func segmentView(_ segment: PageSegment, isLast: Bool) -> some View {
        switch segment {
        case let .flow(id, parent, after, _, ids):
            PageTextFlow(document: $document, viewState: $viewState,
                blockIDs: ids, parentID: parent, afterID: after, flowID: id, pageID: noteID, undoManager: textUndoManager,
                isLast: isLast, inserter: inserter, onFocus: onFocus)
        case let .section(id, _, _):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Button {
                    if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                } label: { Image(systemName: collapsed.contains(id) ? "chevron.right" : "chevron.down").font(.system(size: 10)) }
                .buttonStyle(WovenIconButtonStyle()).frame(width: 20)
                .accessibilityLabel(collapsed.contains(id) ? "Expand section" : "Collapse section")
                TextField("Section", text: Binding(get: { projection.blocks[id]?.plainText ?? "" }, set: { text in
                    update(.init(action: .update, id: id, expectedRevision: page.boardItemRevision(for: id), patch: .init(title: text)))
                }), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 19, weight: .semibold))
                .onTapGesture { viewState.selected = [id]; onSectionFocus?() }
                Menu {
                    inserter.menu { .init(parentID: id) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Add inside section").help("Add inside section")
                PageComponentMenu(document: $document, viewState: $viewState, componentID: id)
            }.padding(.top, 14).padding(.bottom, 3)
            .contextMenu {
                Menu("Add component") { inserter.menu { .init(parentID: id) } }
                Menu("Component actions") {
                    PageMenuEntries(entries: PageComponentActions(document: $document, viewState: $viewState, componentID: id).entries)
                }
            }
        case let .task(id, _, _):
            PageTaskRow(model: model, document: $document, viewState: $viewState, componentID: id,
                        pageFolderID: folderID, onOpenSession: onOpenSession)
                .simultaneousGesture(TapGesture().onEnded { viewState.selected = [id]; onSectionFocus?() })
                .contextMenu { componentContextMenu(id) }
        case let .image(id, _, _):
            PageImageView(image: page.canvas?[id]?.image)
                .onTapGesture { viewState.selected = [id]; onSectionFocus?() }
                .contextMenu { componentContextMenu(id) }
                .padding(.vertical, 6)
        case let .asset(id, assetID, _, _):
            PageAssetEmbed(model: model, pageDocument: $document, viewState: $viewState,
                componentID: id, assetID: assetID, onOpenAsset: onOpenAsset, onOpenSession: onOpenSession, onFocus: onFocus,
                onNonTextFocus: onSectionFocus)
                .id(assetID)
                .contextMenu {
                    Menu("Add component") { inserter.menu { .init(parentID: page.pageParentID(for: id), afterID: id) } }
                    Menu("Component actions") {
                        PageMenuEntries(entries: PageComponentActions(document: $document, viewState: $viewState, componentID: id).entries)
                    }
                }
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder private func componentContextMenu(_ id: String) -> some View {
        Menu("Add component") { inserter.menu { .init(parentID: page.pageParentID(for: id), afterID: id) } }
        Menu("Component actions") {
            PageMenuEntries(entries: PageComponentActions(document: $document, viewState: $viewState, componentID: id).entries)
        }
    }

    private func update(_ edit: PageEdit) { commitPage(document: $document, state: $viewState) { try $0.applyPageEdit(edit) } }
    /// Empty paragraph slots let users type before and between embedded objects,
    /// without persisting empty components merely by opening the document.
    private var editorSegments: [PageSegment] {
        var result: [PageSegment] = []
        // Keyed by parent, with nil for the Page itself, so no component ID can collide with it.
        var previous: [String?: (flow: Bool, id: String?)] = [:]
        for segment in projection.segments {
            let container = segment.parentID
            if case .flow = segment { previous[container] = (true, nil) }
            else {
                if previous[container]?.flow != true {
                    let after = previous[container]?.id
                    result.append(.flow(id: PageSegment.flowID(parentID: container, afterID: after), parentID: segment.parentID,
                        afterID: after, depth: segment.depth, blockIDs: []))
                }
                previous[container] = (false, segment.id)
            }
            result.append(segment)
        }
        return result
    }
    private func visible(_ segment: PageSegment) -> Bool {
        var parent = segment.parentID
        while let id = parent { if collapsed.contains(id) { return false }; parent = page.pageParentID(for: id) }
        return true
    }
    private func segmentContains(_ segment: PageSegment, id: String) -> Bool {
        if case .flow(_, _, _, _, let ids) = segment { return ids.contains(id) }
        return segment.id == id
    }
}

private struct PageProjection {
    let document: NoteDocument
    let blocks: [String: NoteBlock]
    let segments: [PageSegment]
}

@MainActor private final class PageProjectionCache {
    private var source: NoteDocument?
    private var projection: PageProjection?
    func value(_ source: NoteDocument) -> PageProjection {
        if self.source == source, let projection { return projection }
        let result = PageProjection(document: source,
            blocks: Dictionary(source.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            segments: source.pageSegments)
        self.source = source
        projection = result
        return result
    }
}

func commitPage(document: Binding<NoteDocument>, state: Binding<CanvasViewState>,
                recordsComponentUndo: Bool = true,
                change: (inout NoteDocument) throws -> Void) {
    do {
        let before = document.wrappedValue
        var value = before
        try change(&value)
        value.stampBoardChanges(from: before, actor: .init(kind: .user))
        try value.validateEditableShape()
        guard try value.encoded().utf8.count <= NoteDocument.maximumBoardBytes else { throw NoteDocumentSafetyError.tooLarge }
        state.wrappedValue.recordLocalChange(from: before, to: value, undoable: recordsComponentUndo)
        document.wrappedValue = value
        state.wrappedValue.error = nil
    } catch { state.wrappedValue.error = error.localizedDescription }
}

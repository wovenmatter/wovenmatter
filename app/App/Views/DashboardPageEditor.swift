import SwiftUI
import WovenMatterCore

/// A Page is a document. Rich text stays in ordinary contiguous Notes editors;
/// sections and original assets provide the boundaries between those flows.
struct DashboardPageEditor: View {
    @Bindable var model: ApplicationModel
    @Binding var document: NoteDocument
    @Binding var viewState: DashboardCanvasViewState
    let noteID: String
    let folderID: String?
    var onOpenAsset: (String) -> Void
    var onOpenSession: ((String) -> Void)?
    var onFocus: ((DashboardNoteEditorController) -> Void)?
    var onSectionFocus: (() -> Void)?
    @State private var textUndoManager = UndoManager()
    @State private var collapsed = Set<String>()
    @State private var showsAssets = false
    @State private var assetInsertionPosition = PagePosition()
    @State private var importingImage = false
    @State private var showsSharing = false
    @State private var projectionCache = DashboardPageProjectionCache()

    private var projection: DashboardPageProjection { projectionCache.value(document) }
    private var page: NoteDocument { projection.document }
    private var selectedID: String? { viewState.selected.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    addActions(position: insertionPosition)
                } label: { Label("Add component", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                if let id = selectedID, page.blocks.contains(where: { $0.id == id }) {
                    DashboardPageComponentMenu(document: $document, viewState: $viewState, componentID: id)
                    Button("Details") { viewState.showsInspector.toggle() }
                        .buttonStyle(DashboardQuietButtonStyle())
                }
                Spacer(minLength: 4)
                Button { showsSharing = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(DashboardIconButtonStyle()).help("Page sharing")
                    .accessibilityLabel("Page sharing and permissions")
                    .popover(isPresented: $showsSharing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Page sharing").font(.headline)
                            Text("This Page follows your library’s existing sync. Agents connected to one Mac share revision checks.")
                            Text("Different Macs sync whole documents. Concurrent edits can create a recovered copy; review it before continuing. Task assignment is a label, not a distributed lock.")
                            Text("Page content and linked instructions never grant extra tool permissions.")
                        }.font(.callout).padding(16).frame(width: 310)
                    }
                let attention = page.boardItems?.values.filter { $0.review == .needed }.count ?? 0
                if attention > 0 {
                    Menu {
                        ForEach(page.blocks.filter { page.boardItems?[$0.id]?.review == .needed }, id: \.id) { block in
                            Button(block.plainText.isEmpty ? "Review component" : String(block.plainText.prefix(80))) {
                                viewState.selected = [block.id]; viewState.revealCardID = block.id; viewState.showsInspector = true
                            }
                        }
                    } label: { Label("\(attention) to review", systemImage: "tray") }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 24).padding(.vertical, 8)
            if let error = viewState.error {
                HStack {
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { viewState.error = nil }.buttonStyle(DashboardQuietButtonStyle())
                }.foregroundStyle(DashboardPalette.warning).padding(.horizontal, 24).padding(.bottom, 8)
            }
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Add a description…", text: Binding(get: { page.boardPurpose ?? "" }, set: { value in
                                commitPage(document: $document, state: $viewState) { $0.boardPurpose = value.isEmpty ? nil : value }
                            }), axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
                            .padding(.leading, 24).padding(.bottom, 10).onTapGesture { onSectionFocus?() }
                            ForEach(editorSegments.filter { visible($0) }) { segment in
                                segmentView(segment)
                                    .padding(.leading, CGFloat(segment.depth) * 20)
                                    .id(segment.id)
                            }
                            legacyConnections
                        }
                        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 60)
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
                        // A text flow clears the request after focusing its text.
                        // Sections and embeds have nothing more to do.
                        if case .flow = segment { return }
                        DispatchQueue.main.async { if viewState.revealCardID == id { viewState.revealCardID = nil } }
                    }
                }
                if viewState.showsInspector, let id = selectedID, page.blocks.contains(where: { $0.id == id }) {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Component details").font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Button { viewState.showsInspector = false } label: { Image(systemName: "xmark") }
                                    .buttonStyle(DashboardIconButtonStyle()).accessibilityLabel("Close component details")
                            }
                            DashboardBoardItemInspector(document: $document, viewState: $viewState, itemID: id,
                                conversations: model.workspaceOverview?.conversations ?? [],
                                onSend: { id, chat in try await model.sendBoardItem(boardID: noteID, itemID: id, to: chat) },
                                onOpenSession: onOpenSession)
                            // Each component's details start from its own values.
                            .id(id)
                        }.padding(16)
                    }.frame(width: 270).scrollIndicators(.never)
                        .simultaneousGesture(TapGesture().onEnded { onSectionFocus?() })
                }
            }
        }
        .sheet(isPresented: $showsAssets) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Embed an original asset").font(.headline); Spacer(); Button("Done") { showsAssets = false } }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach((model.workspaceOverview?.notes ?? []).filter { $0.id != noteID }, id: \.id) { asset in
                            Button {
                                add(kind: .asset, assetID: asset.id, position: assetInsertionPosition)
                                showsAssets = false
                            } label: {
                                HStack {
                                    Text(asset.title.isEmpty ? "Untitled asset" : asset.title)
                                    Spacer()
                                    Text(NoteDocument.decode(asset.content).kind.displayName).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(DashboardQuietButtonStyle())
                        }
                    }
                }
            }.padding(24).frame(width: 480, height: 420)
        }
        .onChange(of: document) { old, new in
            if viewState.observe(old, new) { textUndoManager.removeAllActions() }
        }
    }

    @ViewBuilder private func segmentView(_ segment: PageSegment) -> some View {
        switch segment {
        case let .flow(id, parent, after, _, ids):
            DashboardPageTextFlow(document: $document, viewState: $viewState,
                blockIDs: ids, parentID: parent, afterID: after, flowID: id, undoManager: textUndoManager, onFocus: onFocus)
        case let .section(id, _, _):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Button {
                    if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                } label: { Image(systemName: collapsed.contains(id) ? "chevron.right" : "chevron.down").font(.system(size: 10)) }
                .buttonStyle(DashboardIconButtonStyle()).frame(width: 20)
                .accessibilityLabel(collapsed.contains(id) ? "Expand section" : "Collapse section")
                TextField("Section", text: Binding(get: { projection.blocks[id]?.plainText ?? "" }, set: { text in
                    update(.init(action: .update, id: id, expectedRevision: page.boardItemRevision(for: id), patch: .init(title: text)))
                }), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 19, weight: .semibold))
                .onTapGesture { viewState.selected = [id]; onSectionFocus?() }
                Menu {
                    addActions(position: .init(parentID: id))
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Add inside section")
                DashboardPageComponentMenu(document: $document, viewState: $viewState, componentID: id)
            }.padding(.top, 14).padding(.bottom, 3)
        case let .asset(id, assetID, _, _):
            DashboardPageAssetEmbed(model: model, pageDocument: $document, viewState: $viewState,
                componentID: id, assetID: assetID, onOpenAsset: onOpenAsset, onFocus: onFocus, onNonTextFocus: onSectionFocus)
                .id(assetID)
                .padding(.vertical, 10)
        }
    }

    private var insertionPosition: PagePosition {
        guard let id = selectedID else { return .init() }
        return page.pageComponentKind(for: id) == .section ? .init(parentID: id)
            : .init(parentID: page.pageParentID(for: id), afterID: id)
    }

    @ViewBuilder private func addActions(position: PagePosition) -> some View {
        Button("Text") { add(kind: .text, position: position) }
        Button("Task") { add(kind: .task, position: position) }
        Button("Section") { add(kind: .section, position: position) }
        Button("Table") { add(kind: .table, position: position) }
        Divider()
        Button("Existing asset…") { assetInsertionPosition = position; showsAssets = true }
        Button("Image…") {
            importingImage = true
            Task {
                defer { importingImage = false }
                do {
                    if let id = try await DashboardPageImageImport.importImage(model: model, folderID: folderID) {
                        add(kind: .asset, assetID: id, position: position)
                    }
                } catch { viewState.error = "The image could not be prepared. Choose a PNG, JPEG, or GIF smaller than 20 MB." }
            }
        }.disabled(importingImage)
        ForEach(NoteArtifactKind.allCases, id: \.self) { kind in
            Button("New \(kind.displayName)") {
                Task {
                    guard let id = await model.createNote(folderID: folderID, kind: kind) else { return }
                    add(kind: .asset, assetID: id, position: position)
                }
            }
        }
    }

    private func add(kind: PageComponentKind, assetID: String? = nil, position: PagePosition) {
        let id = UUID().uuidString.lowercased()
        update(.init(action: .add, id: id, kind: kind, assetID: assetID, position: position))
        if viewState.error == nil { viewState.selected = [id]; viewState.revealCardID = id }
    }
    private func update(_ edit: PageEdit) { commitPage(document: $document, state: $viewState) { try $0.applyPageEdit(edit) } }
    /// Empty paragraph slots let users type before and between embedded objects,
    /// without persisting empty components merely by opening the document.
    private var editorSegments: [PageSegment] {
        var result: [PageSegment] = []
        var previous: [String: (flow: Bool, id: String?)] = [:]
        for segment in projection.segments {
            let container = segment.parentID ?? "root"
            if case .flow = segment { previous[container] = (true, nil) }
            else {
                if previous[container]?.flow != true {
                    let after = previous[container]?.id
                    result.append(.flow(id: "flow:\(container):\(after ?? "start")", parentID: segment.parentID,
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
    @ViewBuilder private var legacyConnections: some View {
        if let connections = page.canvasConnections, !connections.isEmpty {
            DisclosureGroup("Retained connections") {
                ForEach(connections) { connection in
                    Text("\(projection.blocks[connection.from]?.plainText.prefix(60) ?? "Component") → \(projection.blocks[connection.to]?.plainText.prefix(60) ?? "Component"): \(connection.label)")
                        .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(.top, 20)
        }
    }
}

private struct DashboardPageProjection {
    let document: NoteDocument
    let blocks: [String: NoteBlock]
    let segments: [PageSegment]
}

@MainActor private final class DashboardPageProjectionCache {
    private var source: NoteDocument?
    private var projection: DashboardPageProjection?
    func value(_ source: NoteDocument) -> DashboardPageProjection {
        if self.source == source, let projection { return projection }
        let page = source.materializedPage()
        let result = DashboardPageProjection(document: page,
            blocks: Dictionary(page.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            segments: page.pageSegments)
        self.source = source
        projection = result
        return result
    }
}

func commitPage(document: Binding<NoteDocument>, state: Binding<DashboardCanvasViewState>,
                recordsComponentUndo: Bool = true,
                change: (inout NoteDocument) throws -> Void) {
    do {
        let before = document.wrappedValue
        var value = before.materializedPage()
        try change(&value)
        value.stampBoardChanges(from: before.materializedPage(), actor: .init(kind: .user))
        try value.validateEditableShape()
        guard try value.encoded().utf8.count <= NoteDocument.maximumBoardBytes else { throw NoteDocumentSafetyError.tooLarge }
        state.wrappedValue.recordLocalChange(from: before, to: value, undoable: recordsComponentUndo)
        document.wrappedValue = value
        state.wrappedValue.error = nil
    } catch { state.wrappedValue.error = error.localizedDescription }
}

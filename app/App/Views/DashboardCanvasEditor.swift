import SwiftUI
import WovenMatterCore
import CompanionClient

/// A Canvas uses the same document binding as the note editor. Layout changes
/// commit once at the end of a drag; transient zoom never enters shared content.
struct DashboardCanvasEditor: View {
    @Environment(\.dashboardTheme) private var theme
    @Binding var document: NoteDocument
    var assets: [WorkspaceNoteRecord] = []
    var onOpenAsset: ((String) -> Void)?
    @Binding var viewState: DashboardCanvasViewState

    private var boardSize: CGSize {
        let placements = document.blocks.map { document.canvasPlacement(for: $0.id) }
        return CGSize(width: max(1200, placements.map { $0.x + $0.width + 80 }.max() ?? 0),
                      height: max(800, placements.map { $0.y + $0.height + 80 }.max() ?? 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewState.error {
                Text(error).font(.caption).foregroundStyle(DashboardPalette.danger).padding(8)
            }
            ScrollViewReader { reader in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        ForEach(document.blocks, id: \.id) { block in
                            let placement = document.canvasPlacement(for: block.id)
                            DashboardCanvasCard(
                                block: block, placement: placement, zoom: viewState.zoom,
                                asset: assets.first { $0.id == placement.assetID },
                                canOpenAsset: onOpenAsset != nil,
                                tableDocument: blockDocument(block),
                                onText: { updateText($0, blockID: block.id) },
                                onMove: { x, y in move(block.id, x: x, y: y) },
                                onResize: { resize(block.id, large: $0) },
                                onDelete: { remove(block.id) },
                                onOpen: { if let id = placement.assetID { onOpenAsset?(id) } }
                            )
                            .frame(width: placement.width, height: placement.height)
                            .offset(x: placement.x, y: placement.y)
                            .id(block.id)
                        }
                    }
                    .frame(width: boardSize.width, height: boardSize.height, alignment: .topLeading)
                    .scaleEffect(viewState.zoom, anchor: .topLeading)
                    .frame(width: boardSize.width * viewState.zoom, height: boardSize.height * viewState.zoom, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                .background(theme.palette.themeWhisper)
                .coordinateSpace(name: "canvas-viewport")
                .onChange(of: viewState.revealCardID) { _, id in
                    if let id { reader.scrollTo(id, anchor: .topLeading) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commit(_ value: NoteDocument) {
        do {
            try value.validateEditableShape()
            guard try value.encoded().utf8.count <= CompanionProtocol.maximumNoteBytes else {
                throw NoteDocumentSafetyError.tooLarge
            }
            document = value
            viewState.error = nil
        } catch { viewState.error = error.localizedDescription }
    }

    private func move(_ id: String, x: Double, y: Double) {
        guard document.blocks.contains(where: { $0.id == id }) else { return }
        var value = document
        var placement = value.canvasPlacement(for: id)
        placement.x = min(20_000, max(0, x)); placement.y = min(20_000, max(0, y))
        if value.canvas == nil { value.canvas = [:] }
        value.canvas?[id] = placement
        commit(value)
    }

    private func resize(_ id: String, large: Bool) {
        var value = document
        var placement = value.canvasPlacement(for: id)
        placement.width = large ? 720 : 360; placement.height = large ? 500 : 300
        if value.canvas == nil { value.canvas = [:] }
        value.canvas?[id] = placement
        commit(value)
    }

    private func remove(_ id: String) {
        var value = document
        value.blocks.removeAll { $0.id == id }; value.canvas?.removeValue(forKey: id)
        commit(value)
    }

    private func blockDocument(_ block: NoteBlock) -> Binding<NoteDocument> {
        Binding(get: {
            NoteDocument(kind: .spreadsheet, blocks: [document.blocks.first { $0.id == block.id } ?? block])
        }, set: { updated in
            guard let replacement = updated.blocks.first,
                  let index = document.blocks.firstIndex(where: { $0.id == block.id }) else { return }
            var value = document; value.blocks[index] = replacement; commit(value)
        })
    }

    private func updateText(_ text: String, blockID: String) {
        guard let index = document.blocks.firstIndex(where: { $0.id == blockID }),
              case .richText(let block) = document.blocks[index] else { return }
        // Apply only the changed character range, retaining agent-authored links
        // and formatting outside the edit instead of flattening all text runs.
        let before = Array(block.plainText), after = Array(text)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        let start = String(before.prefix(prefix)).utf16.count
        let length = String(before[prefix..<(before.count - suffix)]).utf16.count
        do {
            let source = try NoteDocument(blocks: [.richText(block)]).encoded()
            let edited = try RichDocumentEditing.replacingText(in: source, blockID: blockID,
                range: NSRange(location: start, length: length),
                replacement: String(after[prefix..<(after.count - suffix)]))
            var value = document
            value.blocks[index] = try NoteDocument.editableDocument(from: edited).blocks[0]
            commit(value)
        } catch { viewState.error = error.localizedDescription }
    }
}

struct DashboardCanvasViewState {
    var zoom = 1.0
    var error: String?
    var revealCardID: String?
}

struct DashboardCanvasControls: View {
    @Binding var document: NoteDocument
    @Binding var viewState: DashboardCanvasViewState
    var assets: [WorkspaceNoteRecord] = []
    var canOpenAssets = false

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Text card") { add(.richText(NoteRichTextBlock())) }
                Button("Table card") { add(.table(NoteTableBlock(rows: 4, columns: 3, headerRow: true))) }
                if canOpenAssets {
                    Menu("Existing asset") {
                        if assets.isEmpty { Text("No other assets in this workspace") }
                        ForEach(assets, id: \.id) { asset in
                            Button(asset.title.isEmpty ? "Untitled asset" : asset.title) {
                                add(.richText(NoteRichTextBlock(text: asset.title)), assetID: asset.id)
                            }
                        }
                    }
                }
            } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
            .accessibilityLabel("Add card").help("Add card · \(document.blocks.count) / \(NoteDocument.maximumCanvasCards) cards")
            .disabled(document.blocks.count >= NoteDocument.maximumCanvasCards)
            Button { arrange() } label: { Image(systemName: "square.grid.2x2").frame(width: 28, height: 28) }
                .accessibilityLabel("Arrange cards").help("Arrange cards in a grid")
            Button { viewState.zoom = max(0.5, viewState.zoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 28, height: 28) }
                .accessibilityLabel("Zoom out").disabled(viewState.zoom <= 0.5)
            Button("\(Int(viewState.zoom * 100))%") { viewState.zoom = 1 }.monospacedDigit().help("Reset zoom")
            Button { viewState.zoom = min(1.5, viewState.zoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 28, height: 28) }
                .accessibilityLabel("Zoom in").disabled(viewState.zoom >= 1.5)
        }
        .buttonStyle(DashboardIconButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func commit(_ value: NoteDocument) {
        do {
            try value.validateEditableShape()
            guard try value.encoded().utf8.count <= CompanionProtocol.maximumNoteBytes else {
                throw NoteDocumentSafetyError.tooLarge
            }
            document = value
            viewState.error = nil
        } catch { viewState.error = error.localizedDescription }
    }

    private func add(_ block: NoteBlock, assetID: String? = nil) {
        guard document.blocks.count < NoteDocument.maximumCanvasCards else { return }
        var value = document
        // New cards start beneath the existing content, including manually moved cards.
        let bottom = value.blocks.map { value.canvasPlacement(for: $0.id) }.map { $0.y + $0.height }.max() ?? -8
        var placement = CanvasCardPlacement(x: 24, y: min(20_000, bottom + 32), assetID: assetID)
        if value.blocks.count == 1, value.blocks[0].plainText.isEmpty, value.canvas?[value.blocks[0].id]?.assetID == nil {
            value.canvas?.removeValue(forKey: value.blocks[0].id)
            value.blocks.removeAll()
            placement.y = 24
        }
        value.blocks.append(block)
        if value.canvas == nil { value.canvas = [:] }
        value.canvas?[block.id] = placement
        commit(value)
        if viewState.error == nil { viewState.revealCardID = block.id }
    }

    private func arrange() {
        var value = document
        if value.canvas == nil { value.canvas = [:] }
        for (index, block) in value.blocks.enumerated() {
            var placement = CanvasCardPlacement.automatic(index: index)
            placement.assetID = value.canvas?[block.id]?.assetID
            value.canvas?[block.id] = placement
        }
        commit(value)
    }

}

private struct DashboardCanvasCard: View {
    @Environment(\.dashboardTheme) private var theme
    let block: NoteBlock
    let placement: CanvasCardPlacement
    let zoom: Double
    let asset: WorkspaceNoteRecord?
    let canOpenAsset: Bool
    @Binding var tableDocument: NoteDocument
    let onText: (String) -> Void
    let onMove: (Double, Double) -> Void
    let onResize: (Bool) -> Void
    let onDelete: () -> Void
    let onOpen: () -> Void
    @GestureState private var translation = CGSize.zero

    private var label: String {
        if placement.assetID != nil { return "Asset reference" }
        if case .table = block { return "Table" }
        return "Text"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(label, systemImage: "hand.draw").font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .named("canvas-viewport")).updating($translation) { value, state, _ in state = value.translation }
                        .onEnded { value in onMove(placement.x + value.translation.width / zoom, placement.y + value.translation.height / zoom) })
                    .help("Drag to move this card")
                Menu {
                    Button("Move left") { onMove(placement.x - 40, placement.y) }
                    Button("Move right") { onMove(placement.x + 40, placement.y) }
                    Button("Move up") { onMove(placement.x, placement.y - 40) }
                    Button("Move down") { onMove(placement.x, placement.y + 40) }
                    Divider()
                    Button("Standard size") { onResize(false) }
                    Button("Large size") { onResize(true) }
                    Divider()
                    Button("Remove card", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Card actions")
            }.padding(.horizontal, 12).frame(height: 38)
            Divider()
            if placement.assetID != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text(asset?.title ?? block.plainText).font(.headline)
                    Text(asset == nil ? "This reference is unavailable here. Its original asset ID is retained." : "Opens the original asset. Changes stay in one place.")
                        .font(.callout).foregroundStyle(DashboardPalette.mutedForeground)
                    Button("Open asset", action: onOpen).buttonStyle(DashboardQuietButtonStyle())
                        .disabled(asset == nil || !canOpenAsset)
                    Spacer(minLength: 0)
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                switch block {
                case .richText:
                    TextEditor(text: Binding(get: { tableDocument.blocks.first?.plainText ?? "" }, set: { onText($0) }))
                        .font(.system(size: 14)).scrollContentBackground(.hidden)
                        .scrollIndicators(.never).padding(10).accessibilityLabel("Canvas text card")
                case .table:
                    DashboardSpreadsheetEditor(document: $tableDocument)
                }
            }
        }
        .background(theme.palette.workspace)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(theme.palette.border, lineWidth: 1) }
        .offset(x: translation.width / zoom, y: translation.height / zoom)
    }
}

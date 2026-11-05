import AppKit
import SwiftUI
import WovenMatterCore

struct DashboardCanvasCard: View {
    @Environment(\.dashboardTheme) private var theme
    let block: NoteBlock
    let placement: CanvasCardPlacement
    let zoom: Double
    let selected: Bool
    let asset: WorkspaceNoteRecord?
    @Binding var tableDocument: NoteDocument
    let onText: (String) -> Void
    let onSelect: (Bool) -> Void
    let onMove: (Double, Double) -> Void
    let onResize: (Double, Double) -> Void
    let onDelete: () -> Void
    let onOpen: () -> Void
    let onEditAsset: (NoteDocument) -> Void
    let canEditAsset: Bool
    let onInspect: () -> Void
    var item: BoardItem?
    var onSetStatus: ((BoardTaskStatus) -> Void)?
    @GestureState private var translation = CGSize.zero
    @GestureState private var resizeTranslation = CGSize.zero

    private var label: String {
        if let title = placement.title, !title.isEmpty { return title }
        if let asset { return asset.title.isEmpty ? "Untitled asset" : asset.title }
        if placement.assetID != nil { return block.plainText.isEmpty ? "Unavailable asset" : block.plainText }
        if case .table = block { return "Table" }
        if item?.task != nil { return block.plainText.isEmpty ? "New task" : String(block.plainText.prefix(80)) }
        return "Text"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let task = item?.task {
                    Button { onSetStatus?(task.status == .done ? .todo : .done) } label: {
                        Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(task.status == .done ? DashboardPalette.success : DashboardPalette.mutedForeground)
                    }.buttonStyle(.plain).accessibilityLabel(task.status == .done ? "Reopen task" : "Complete task")
                }
                if item?.role == .instructions {
                    Image(systemName: "book.closed").help("Instructions or skill reference; nothing runs automatically")
                }
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture { onSelect(NSEvent.modifierFlags.contains(.shift)) }
                    .gesture(DragGesture(coordinateSpace: .named("canvas-viewport"))
                        .updating($translation) { value, state, _ in state = value.translation }
                        .onChanged { _ in if !selected { onSelect(false) } }
                        .onEnded { value in onMove(value.translation.width / zoom, value.translation.height / zoom) })
                    .help("Drag to move. Shift-click to select multiple cards.")
                if placement.assetID != nil {
                    Label("Original", systemImage: "link")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .help("This card references the original library asset. Editing its note or sheet updates every reference.")
                    Button(action: onOpen) { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).help("Open original asset").accessibilityLabel("Open original asset").disabled(asset == nil)
                }
                if item?.review == .needed {
                    Button(action: onInspect) { Image(systemName: "tray") }
                        .buttonStyle(.plain).help("Needs review").accessibilityLabel("Review this item")
                }
                Menu {
                    Button("Customize card", action: onInspect)
                    Button("Move left") { onMove(-40, 0) }
                    Button("Move right") { onMove(40, 0) }
                    Button("Move up") { onMove(0, -40) }
                    Button("Move down") { onMove(0, 40) }
                    Divider()
                    Button("Standard size") { onResize(360, 300) }
                    Button("Large size") { onResize(720, 500) }
                    Divider()
                    Button("Remove card", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Card actions")
            }.padding(.horizontal, 12).frame(height: 38)
                .background(canvasColor(placement.color).opacity(placement.color == nil || placement.color == "neutral" ? 0 : 0.10))
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let task = item?.task {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Menu(task.status.boardTitle) {
                            ForEach([BoardTaskStatus.todo, .doing, .blocked, .done, .canceled], id: \.self) { status in
                                Button(status.boardTitle) { onSetStatus?(status) }
                            }
                        }.fixedSize().accessibilityLabel("Task state: \(task.status.boardTitle)")
                        Spacer(minLength: 0)
                        if !task.assignee.isEmpty { Text(task.assignee).lineLimit(1).foregroundStyle(.secondary) }
                    }
                    if !task.outcome.isEmpty {
                        Text(task.outcome).lineLimit(3).textSelection(.enabled).foregroundStyle(.secondary)
                            .help("Outcome: \(task.outcome)")
                    }
                }.font(.system(size: 11)).padding(10)
            }
        }
        .frame(width: max(200, placement.width + resizeTranslation.width / zoom),
               height: max(120, placement.height + resizeTranslation.height / zoom), alignment: .topLeading)
        .background(theme.palette.workspace)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(selected ? DashboardPalette.success : theme.palette.border, lineWidth: selected ? 2 : 1) }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10)).padding(7)
                .foregroundStyle(.secondary).contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .named("canvas-viewport"))
                    .updating($resizeTranslation) { value, state, _ in state = value.translation }
                    .onEnded { value in onResize(placement.width + value.translation.width / zoom, placement.height + value.translation.height / zoom) })
                .help("Drag to resize card").accessibilityLabel("Resize card")
        }
        .offset(x: translation.width / zoom, y: translation.height / zoom)
    }
    @ViewBuilder private var content: some View {
        if placement.assetID != nil {
            if let asset, let source = try? NoteDocument.editableDocument(from: asset.content) {
                DashboardCanvasAssetPreview(document: Binding(get: { source }, set: { onEditAsset($0) }), editable: canEditAsset)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Asset unavailable").font(.headline)
                    Text("The original asset may be deleted or unavailable in this workspace. Its reference is retained.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            switch block {
            case .richText:
                TextEditor(text: Binding(get: { tableDocument.blocks.first?.plainText ?? "" }, set: { onText($0) }))
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .scrollIndicators(.never).padding(10).accessibilityLabel("Board text card")
            case .table: DashboardSpreadsheetEditor(document: $tableDocument)
            }
        }
    }
}

struct DashboardCanvasAssetPreview: View {
    @Binding var document: NoteDocument
    var editable: Bool
    @State private var controller = DashboardNoteEditorController()
    private var hasLinkedData: Bool {
        document.databaseLink != nil || document.blocks.contains { block in
            switch block {
            case .table(let table): table.databaseLink != nil
            case .richText(let text): text.runs.contains { $0.databaseLink != nil }
            }
        }
    }
    var body: some View {
      if hasLinkedData {
        VStack(alignment: .leading, spacing: 10) {
            Label("Linked data", systemImage: "externaldrive")
            Text("Open the original to refresh its database data. The board keeps the same asset reference.")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        switch document.kind {
        case .html:
            DashboardHTMLArtifactView(html: document.html, linkedDataJSON: nil)
        case .spreadsheet:
            DashboardSpreadsheetEditor(document: $document).disabled(!editable)
        case .note:
            DashboardNoteEditor(document: $document, controller: controller).disabled(!editable)
        case .canvas:
            VStack(alignment: .leading, spacing: 8) {
                Label("Board", systemImage: "square.grid.2x2")
                Text("\(document.blocks.count) cards · \(document.canvasSections?.count ?? 0) sections")
                Text("Open the original to explore this board.").foregroundStyle(.secondary)
                Spacer()
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
    }
}

struct DashboardCanvasSectionHeader: View {
    let section: CanvasSection
    let zoom: Double
    let onChange: (CanvasSection) -> Void
    let onRemove: () -> Void
    @State private var title = ""
    var body: some View {
        HStack {
            Image(systemName: "rectangle.3.group").contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .named("canvas-viewport")).onEnded { value in
                    var updated = section; updated.x += value.translation.width / zoom; updated.y += value.translation.height / zoom; onChange(updated)
                }).help("Drag to move section and its cards")
            TextField("Section title", text: $title).textFieldStyle(.plain).font(.system(size: 12, weight: .semibold))
                .onSubmit { var value = section; value.title = title; onChange(value) }
            Menu {
                ForEach(CanvasStyle.colors, id: \.self) { color in
                    Button(color.capitalized) { var value = section; value.color = color; onChange(value) }
                }
                Divider()
                Button("Remove section (keep cards)", action: onRemove)
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }.padding(.horizontal, 12).foregroundStyle(canvasColor(section.color))
            .onAppear { title = section.title }.onChange(of: section.title) { _, value in title = value }
    }
}

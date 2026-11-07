import SwiftUI
import WovenMatterCore

struct DashboardPageAssetEmbed: View {
    @Bindable var model: ApplicationModel
    @Binding var pageDocument: NoteDocument
    @Binding var viewState: DashboardCanvasViewState
    let componentID: String
    let assetID: String
    let onOpenAsset: (String) -> Void
    var onFocus: ((DashboardNoteEditorController) -> Void)?
    var onNonTextFocus: (() -> Void)?
    @State private var documentCache = DashboardNoteDocumentCache()
    private var asset: WorkspaceNoteRecord? { model.workspaceOverview?.notes.first { $0.id == assetID } }
    private var sourceDocument: NoteDocument? {
        guard let asset else { return nil }
        let source = model.noteDraft(for: asset).content
        guard documentCache.isEditable(noteID: asset.id, source: source) else { return nil }
        return documentCache.value(noteID: asset.id, source: source)
    }

    var body: some View {
        let source = sourceDocument
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let task = pageDocument.boardItems?[componentID]?.task {
                    Button {
                        commitPage(document: $pageDocument, state: $viewState) {
                            try $0.applyPageEdit(.init(action: .update, id: componentID,
                                expectedRevision: $0.boardItemRevision(for: componentID),
                                patch: .init(status: task.status == .done ? .todo : .done)))
                        }
                    } label: { Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle") }
                    .buttonStyle(.plain).accessibilityLabel(task.status == .done ? "Reopen task" : "Complete task")
                }
                Text(asset?.title.isEmpty == false ? asset!.title : "Original asset")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Label("Original", systemImage: "link").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let source, source.kind != .note, source.kind != .canvas {
                    Menu {
                        ForEach([360, 540, 720], id: \.self) { height in
                            Button("\(height) points") {
                                commitPage(document: $pageDocument, state: $viewState) { value in
                                    var placement = value.canvasPlacement(for: componentID)
                                    placement.height = Double(height)
                                    if value.canvas == nil { value.canvas = [:] }
                                    value.canvas?[componentID] = placement
                                }
                            }
                        }
                    } label: { Image(systemName: "arrow.up.and.down") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Embedded asset height")
                }
                Button { onOpenAsset(assetID) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(DashboardIconButtonStyle()).accessibilityLabel("Open original asset").disabled(asset == nil)
                DashboardPageComponentMenu(document: $pageDocument, viewState: $viewState, componentID: componentID)
            }.contentShape(Rectangle()).onTapGesture { viewState.selected = [componentID] }
            if let asset, let source {
                if source.kind == .canvas {
                    Button { onOpenAsset(assetID) } label: {
                        Label("Open nested Page · \(source.blocks.count) components", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(DashboardQuietButtonStyle())
                } else {
                    DashboardNotePane(model: model, note: asset, focusesTitleOnAppear: false,
                        onInitialFocusHandled: {}, onOpenNote: onOpenAsset, embedded: true,
                        onEditorFocus: { viewState.selected = [componentID]; onFocus?($0) })
                        .frame(height: source.kind == .note ? nil : embedHeight)
                        .frame(minHeight: source.kind == .note ? 40 : 240)
                        .simultaneousGesture(TapGesture().onEnded {
                            viewState.selected = [componentID]
                            if source.kind != .note { onNonTextFocus?() }
                        })
                }
            } else {
                Text("The original asset is unavailable. Its reference is retained.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(DashboardPalette.muted.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var embedHeight: CGFloat { max(360, min(900, pageDocument.canvasPlacement(for: componentID).height)) }
}

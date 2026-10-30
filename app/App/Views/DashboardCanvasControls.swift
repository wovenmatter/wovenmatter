import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterCore

struct DashboardCanvasControls: View {
    @Binding var document: NoteDocument
    @Binding var viewState: DashboardCanvasViewState
    var assets: [WorkspaceNoteRecord] = []
    var canOpenAssets = false
    var compact = true
    var onCreateAsset: ((NoteArtifactKind, String, String?) async -> String?)?
    @State private var creating = false

    private var fullControls: some View {
        HStack(spacing: 2) {
            control("Undo Canvas change", "arrow.uturn.backward") { viewState.undo(&document) }
                .disabled(viewState.undoStack.isEmpty).keyboardShortcut("z", modifiers: .command)
            control("Redo Canvas change", "arrow.uturn.forward") { viewState.redo(&document) }
                .disabled(viewState.redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
            addMenu
            organizeMenu
            control("Pan tool · drag across cards", "hand.draw") { viewState.isPanning.toggle() }
                .background(viewState.isPanning ? Color.secondary.opacity(0.12) : .clear).clipShape(RoundedRectangle(cornerRadius: 6))
            control("Canvas navigator", "list.bullet.rectangle") { viewState.showsNavigator.toggle() }
                .popover(isPresented: $viewState.showsNavigator) { navigator }
            control("Customize selection", "slider.horizontal.3") { viewState.showsInspector.toggle() }
                .popover(isPresented: $viewState.showsInspector) {
                    DashboardCanvasInspector(document: $document, viewState: $viewState).frame(width: 300).padding(16)
                }
            control("Zoom out", "minus.magnifyingglass") { viewState.setZoom(viewState.zoom / 1.25) }
            Menu {
                Button("Fit all") { viewState.fit(document) }
                Button("Fit selection") { viewState.fit(document, selectionOnly: true) }.disabled(viewState.selected.isEmpty)
                Button("Actual size") { viewState.setZoom(1) }
                Button("Return to origin") { viewState.origin = CGPoint(x: -24, y: -24); viewState.zoom = 1 }
            } label: { Text("\(Int(viewState.zoom * 100))%").monospacedDigit() }
            .accessibilityLabel("Canvas zoom and fit")
            control("Zoom in", "plus.magnifyingglass") { viewState.setZoom(viewState.zoom * 1.25) }
        }.buttonStyle(DashboardIconButtonStyle()).fixedSize(horizontal: true, vertical: false)
    }
    var body: some View {
        Group {
            if !compact { fullControls }
            else { HStack(spacing: 2) {
                addMenu
                Menu {
                    Button("Undo Canvas change") { viewState.undo(&document) }.disabled(viewState.undoStack.isEmpty).keyboardShortcut("z", modifiers: .command)
                    Button("Redo Canvas change") { viewState.redo(&document) }.disabled(viewState.redoStack.isEmpty).keyboardShortcut("z", modifiers: [.command, .shift])
                    Divider()
                    organizeMenu
                    Button("Customize selection") { viewState.showsInspector = true }
                    Button("Find a card") { viewState.showsNavigator = true }
                    Button(viewState.isPanning ? "Use selection tool" : "Use pan tool") { viewState.isPanning.toggle() }
                    Divider()
                    Button("Zoom in") { viewState.setZoom(viewState.zoom * 1.25) }
                    Button("Zoom out") { viewState.setZoom(viewState.zoom / 1.25) }
                    Button("Fit all") { viewState.fit(document) }
                    Button("Fit selection") { viewState.fit(document, selectionOnly: true) }.disabled(viewState.selected.isEmpty)
                    Button("Actual size") { viewState.setZoom(1) }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .accessibilityLabel("Canvas controls")
            }.buttonStyle(DashboardIconButtonStyle()).fixedSize()
                .popover(isPresented: $viewState.showsNavigator) { navigator }
                .popover(isPresented: $viewState.showsInspector) {
                    DashboardCanvasInspector(document: $document, viewState: $viewState).frame(width: 300).padding(16)
                }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var addMenu: some View {
            Menu {
                Button("Text card") { add(.richText(NoteRichTextBlock())) }
                Button("Table card") { add(.table(NoteTableBlock(rows: 4, columns: 3, headerRow: true))) }
                if onCreateAsset != nil {
                    Divider()
                    Button("New document") { create(.note, title: "Canvas document") }
                    Button("New spreadsheet") { create(.spreadsheet, title: "Canvas spreadsheet") }
                    Button("New HTML artifact") { create(.html, title: "Canvas artifact") }
                    Button("Image from file…", action: importImage)
                }
                if canOpenAssets {
                    Menu("Existing asset") {
                        ForEach(assets, id: \.id) { asset in
                            Button(asset.title.isEmpty ? "Untitled asset" : asset.title) { add(.richText(NoteRichTextBlock(text: asset.title)), assetID: asset.id) }
                        }
                    }
                }
                Divider()
                Button("Section around selection") { groupSelection() }
                Button("Empty section") {
                    apply([.init(action: .section, section: .init(title: "New section", x: viewState.origin.x + 40, y: viewState.origin.y + 40))])
                }
            } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
            .accessibilityLabel("Add card").help("Add cards, assets, images, or sections").disabled(creating)
    }
    private var organizeMenu: some View {
            Menu {
                ForEach(["grid", "row", "column"], id: \.self) { layout in
                    Button("Arrange \(viewState.selected.isEmpty ? "all" : "selection") in \(layout)") {
                        apply([.init(action: .arrange, ids: viewState.selected.isEmpty ? nil : document.blocks.map(\.id).filter(viewState.selected.contains), layout: layout)])
                    }
                }
                Divider()
                Button(document.blocks.count > 128 ? "Select first 128 cards" : "Select all cards") { viewState.selected = Set(document.blocks.prefix(128).map(\.id)) }
                Button("Clear selection") { viewState.selected.removeAll() }
                Button("Group selection in section", action: groupSelection).disabled(viewState.selected.isEmpty)
                Button("Connect selected cards") { connectSelection() }.disabled(viewState.selected.count < 2)
                Button("Remove selected cards", role: .destructive) {
                    apply(viewState.selected.sorted().map { .init(action: .remove, id: $0) })
                }.disabled(viewState.selected.isEmpty)
            } label: { Image(systemName: "square.grid.2x2").frame(width: 28, height: 28) }
                .accessibilityLabel("Arrange and organize")
    }
    private func control(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 28, height: 28) }.help(title).accessibilityLabel(title)
    }
    private var navigator: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Canvas · \(document.blocks.count) cards").font(.headline)
            Text("Shift-click card headers to select a group.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(document.blocks, id: \.id) { block in
                        Button {
                            viewState.selected = [block.id]; viewState.fit(document, selectionOnly: true); viewState.showsNavigator = false
                        } label: {
                            let placement = document.canvasPlacement(for: block.id)
                            Text(placement.title ?? assets.first(where: { $0.id == placement.assetID })?.title ?? (block.plainText.isEmpty ? "Untitled card" : String(block.plainText.prefix(80))))
                                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
            }.scrollIndicators(.never).frame(height: 280)
        }.padding(16).frame(width: 280)
    }
    private func apply(_ edits: [CanvasEdit]) { commitCanvas(edits, document: $document, state: $viewState) }
    private func add(_ block: NoteBlock, assetID: String? = nil) {
        var placement = CanvasCardPlacement(x: viewState.origin.x + 48, y: viewState.origin.y + 48,
                                            width: assetID == nil ? 360 : 560, height: assetID == nil ? 300 : 420, assetID: assetID)
        let existing = document.blocks.map { document.canvasPlacement(for: $0.id).rect }
        let columns = max(1, Int(viewState.visibleRect.width / (placement.width + 32)))
        for index in 0...document.blocks.count {
            placement.x = viewState.origin.x + 48 + Double(index % columns) * (placement.width + 32)
            placement.y = viewState.origin.y + 48 + Double(index / columns) * (placement.height + 32)
            if !existing.contains(where: { $0.intersects(placement.rect) }) { break }
        }
        apply([.init(action: .add, block: block, placement: placement)])
        if viewState.error == nil { viewState.selected = [block.id]; viewState.revealCardID = block.id }
    }
    private func create(_ kind: NoteArtifactKind, title: String, html: String? = nil) {
        guard let onCreateAsset else { return }
        creating = true
        Task { @MainActor in
            defer { creating = false }
            if let id = await onCreateAsset(kind, title, html) { add(.richText(NoteRichTextBlock(text: title)), assetID: id) }
            else { viewState.error = "The asset could not be created. Please try again." }
        }
    }
    private func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .gif]; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let metadata = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (metadata.fileSize ?? Int.max) <= 20_000_000 else { throw NoteDocumentSafetyError.tooLarge }
                let original = try Data(contentsOf: url)
                let type = url.pathExtension.lowercased()
                var bytes = original
                var mime = type == "png" ? "image/png" : type == "gif" ? "image/gif" : "image/jpeg"
                if bytes.count > 650_000 {
                    guard let source = CGImageSourceCreateWithData(original as CFData, nil) else { throw NoteDocumentSafetyError.unsupportedFormat }
                    for size in [1600, 1000, 600] {
                        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary
                        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { continue }
                        let output = NSMutableData()
                        let format = type == "png" ? UTType.png : UTType.jpeg
                        guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { continue }
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                        if CGImageDestinationFinalize(destination) {
                            bytes = output as Data; mime = type == "png" ? "image/png" : "image/jpeg"
                            if bytes.count <= 650_000 { break }
                        }
                    }
                }
                guard bytes.count <= 650_000 else { throw NoteDocumentSafetyError.tooLarge }
                create(.html, title: url.deletingPathExtension().lastPathComponent,
                       html: "<style>body{padding:0;display:grid;place-items:center}img{max-width:100%;height:auto}</style><img alt=\"Canvas image\" src=\"data:\(mime);base64,\(bytes.base64EncodedString())\">")
            } catch { viewState.error = "This image could not be prepared. Choose a PNG, JPEG, or GIF smaller than 20 MB." }
        }
    }
    private func groupSelection() {
        let ids = viewState.selected.sorted()
        guard !ids.isEmpty else { viewState.error = "Select cards to put in a section."; return }
        let rect = ids.map { document.canvasPlacement(for: $0).rect }.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -32, dy: -48)
        let section = CanvasSection(title: "New section", x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        apply([.init(action: .section, section: section, ids: ids)])
    }
    private func connectSelection() {
        let ids = document.blocks.map(\.id).filter(viewState.selected.contains)
        apply(zip(ids, ids.dropFirst()).map { .init(action: .connect, connection: .init(from: $0.0, to: $0.1)) })
    }
}

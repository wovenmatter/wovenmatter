import SwiftUI
import WovenMatterCore
import CompanionClient

struct DashboardCanvasEditor: View {
    @Environment(\.dashboardTheme) private var theme
    @Binding var document: NoteDocument
    var assets: [WorkspaceNoteRecord] = []
    var onOpenAsset: ((String) -> Void)?
    var onEditAsset: ((String, NoteDocument) -> Void)?
    @Binding var viewState: DashboardCanvasViewState
    var onContext: ((CanvasViewportContext) -> Void)?

    private func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - viewState.origin.x) * viewState.zoom, y: (point.y - viewState.origin.y) * viewState.zoom)
    }
    var body: some View {
        let placements = document.canvasPlacements
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                theme.palette.themeWhisper
                DashboardCanvasInput(pan: { delta in
                    viewState.origin.x -= delta.width / viewState.zoom
                    viewState.origin.y -= delta.height / viewState.zoom
                }, zoom: { viewState.setZoom(viewState.zoom * $0) }, select: { viewState.selected.removeAll() })
                    .accessibilityLabel("Canvas board. Drag or scroll to pan; pinch or Command-scroll to zoom.")
                decorations(placements)
                    .allowsHitTesting(false)
                ForEach(document.canvasSections ?? []) { section in
                    let point = screen(CGPoint(x: section.x, y: section.y))
                    if CGRect(x: section.x, y: section.y, width: section.width, height: section.height).intersects(viewState.visibleRect) {
                        DashboardCanvasSectionHeader(section: section, zoom: viewState.zoom,
                            onChange: { apply([.init(action: .section, section: $0)]) },
                            onRemove: { apply([.init(action: .removeSection, id: section.id)]) })
                            .frame(width: section.width * viewState.zoom, height: 32)
                            .offset(x: point.x, y: point.y)
                    }
                }
                ForEach(document.blocks.filter { placements[$0.id]?.rect.intersects(viewState.visibleRect.insetBy(dx: -200, dy: -200)) == true }, id: \.id) { block in
                    if let placement = placements[block.id] { card(block, placement: placement) }
                }
                if viewState.isPanning {
                    DashboardCanvasInput(pan: { delta in
                        viewState.origin.x -= delta.width / viewState.zoom
                        viewState.origin.y -= delta.height / viewState.zoom
                    }, zoom: { viewState.setZoom(viewState.zoom * $0) }, select: {})
                        .accessibilityLabel("Pan tool active. Drag anywhere to move around the canvas.")
                }
                if document.blocks.isEmpty {
                    VStack(spacing: 8) {
                        Text("Room for your next idea").font(.title3)
                        Text("Add an asset or ask your agent to create and arrange work here.\nDrag the background to explore. Pinch to zoom.")
                            .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }.frame(width: geometry.size.width, height: geometry.size.height).allowsHitTesting(false)
                }
                if let error = viewState.error {
                    Text(error).font(.caption).padding(10).background(theme.palette.workspace)
                        .foregroundStyle(DashboardPalette.danger).padding(12)
                }
            }
            .clipped()
            .coordinateSpace(name: "canvas-viewport")
            .onAppear { viewState.viewport = geometry.size; onContext?(viewState.context) }
            .onChange(of: geometry.size) { _, size in viewState.viewport = size }
            .onChange(of: viewState.context) { _, context in onContext?(context) }
            .onChange(of: document) { old, new in viewState.observe(old, new) }
            .onChange(of: viewState.revealCardID) { _, id in
                if let id {
                    viewState.selected = [id]
                    let rect = document.canvasPlacement(for: id).rect
                    viewState.origin = CGPoint(x: rect.midX - viewState.viewport.width / viewState.zoom / 2,
                                               y: rect.midY - viewState.viewport.height / viewState.zoom / 2)
                }
            }
        }
    }

    private func card(_ block: NoteBlock, placement: CanvasCardPlacement) -> some View {
        let point = screen(CGPoint(x: placement.x, y: placement.y))
        return DashboardCanvasCard(block: block, placement: placement, zoom: viewState.zoom,
            selected: viewState.selected.contains(block.id), asset: assets.first { $0.id == placement.assetID },
            tableDocument: blockDocument(block), onText: { updateText($0, blockID: block.id) },
            onSelect: { extend in
                if extend {
                    if viewState.selected.contains(block.id) { viewState.selected.remove(block.id) }
                    else if viewState.selected.count < 128 { viewState.selected.insert(block.id) }
                    else { viewState.error = "Select up to 128 cards for one action." }
                } else if !viewState.selected.contains(block.id) { viewState.selected = [block.id] }
            }, onMove: { dx, dy in move(block.id, dx: dx, dy: dy) }, onResize: { w, h in
                var value = document.canvasPlacement(for: block.id)
                value.width = min(4000, max(200, w)); value.height = min(4000, max(120, h))
                apply([.init(action: .place, id: block.id, placement: value)])
            }, onDelete: { apply([.init(action: .remove, id: block.id)]) },
            onOpen: { if let id = placement.assetID { onOpenAsset?(id) } },
            onEditAsset: { value in if let id = placement.assetID { onEditAsset?(id, value) } },
            canEditAsset: onEditAsset != nil, onInspect: { viewState.selected = [block.id]; viewState.showsInspector = true })
            .frame(width: placement.width, height: placement.height)
            .scaleEffect(viewState.zoom, anchor: .topLeading)
            .frame(width: placement.width * viewState.zoom, height: placement.height * viewState.zoom, alignment: .topLeading)
            .offset(x: point.x, y: point.y)
    }

    private func decorations(_ placements: [String: CanvasCardPlacement]) -> some View {
        Canvas { context, size in
            // A screen-space grid stays cheap even when zoomed far out.
            let spacing = max(24, 48 * viewState.zoom)
            let offsetX = (-viewState.origin.x * viewState.zoom).truncatingRemainder(dividingBy: spacing)
            let offsetY = (-viewState.origin.y * viewState.zoom).truncatingRemainder(dividingBy: spacing)
            for x in stride(from: offsetX, through: size.width, by: spacing) {
                for y in stride(from: offsetY, through: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(theme.palette.border.opacity(0.7)))
                }
            }
            for section in document.canvasSections ?? [] {
                let point = screen(CGPoint(x: section.x, y: section.y))
                let rect = CGRect(origin: point, size: CGSize(width: section.width * viewState.zoom, height: section.height * viewState.zoom))
                context.fill(Path(roundedRect: rect, cornerRadius: 12), with: .color(canvasColor(section.color).opacity(0.06)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 12), with: .color(canvasColor(section.color).opacity(0.3)), lineWidth: 1)
            }
            for connection in document.canvasConnections ?? [] {
                guard let from = placements[connection.from]?.rect, let to = placements[connection.to]?.rect,
                      from.union(to).intersects(viewState.visibleRect) else { continue }
                let dx = to.midX - from.midX, dy = to.midY - from.midY
                let startScale = min(dx == 0 ? Double.infinity : from.width / 2 / abs(dx), dy == 0 ? Double.infinity : from.height / 2 / abs(dy))
                let endScale = min(dx == 0 ? Double.infinity : to.width / 2 / abs(dx), dy == 0 ? Double.infinity : to.height / 2 / abs(dy))
                guard dx != 0 || dy != 0 else { continue }
                let a = screen(CGPoint(x: from.midX + dx * startScale, y: from.midY + dy * startScale))
                let b = screen(CGPoint(x: to.midX - dx * endScale, y: to.midY - dy * endScale))
                var path = Path(); path.move(to: a); path.addLine(to: b)
                let angle = atan2(b.y - a.y, b.x - a.x)
                path.move(to: CGPoint(x: b.x - 10 * cos(angle - 0.4), y: b.y - 10 * sin(angle - 0.4)))
                path.addLine(to: b)
                path.addLine(to: CGPoint(x: b.x - 10 * cos(angle + 0.4), y: b.y - 10 * sin(angle + 0.4)))
                context.stroke(path, with: .color(canvasColor(connection.color).opacity(0.7)), style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                if !connection.label.isEmpty {
                    context.draw(Text(connection.label).font(.system(size: 12)).foregroundColor(canvasColor(connection.color)),
                                 at: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 10))
                }
            }
        }
    }
    private func apply(_ edits: [CanvasEdit]) { commitCanvas(edits, document: $document, state: $viewState) }
    private func move(_ id: String, dx: Double, dy: Double) {
        let ids = viewState.selected.contains(id) ? viewState.selected.sorted() : [id]
        apply(ids.map { id in
            var placement = document.canvasPlacement(for: id); placement.x += dx; placement.y += dy
            return .init(action: .place, id: id, placement: placement)
        })
    }
    private func commit(_ value: NoteDocument) {
        do {
            try value.validateEditableShape()
            guard try value.encoded().utf8.count <= CompanionProtocol.maximumNoteBytes else { throw NoteDocumentSafetyError.tooLarge }
            document = value; viewState.error = nil
        } catch { viewState.error = error.localizedDescription }
    }
    private func blockDocument(_ block: NoteBlock) -> Binding<NoteDocument> {
        Binding(get: { NoteDocument(kind: .spreadsheet, blocks: [document.blocks.first { $0.id == block.id } ?? block]) }, set: { updated in
            guard let replacement = updated.blocks.first, let index = document.blocks.firstIndex(where: { $0.id == block.id }) else { return }
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

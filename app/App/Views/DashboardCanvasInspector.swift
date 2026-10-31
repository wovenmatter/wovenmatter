import SwiftUI
import WovenMatterCore

struct DashboardCanvasInspector: View {
    @Binding var document: NoteDocument
    @Binding var viewState: DashboardCanvasViewState
    @State private var title = ""
    @State private var width = ""
    @State private var height = ""
    @State private var connectionLabel = ""
    private var ids: [String] { viewState.selected.sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ids.isEmpty ? "Select a card to customize" : "\(ids.count) selected").font(.headline)
            if !ids.isEmpty {
                if ids.count == 1 {
                    TextField("Card title", text: $title).dashboardQuietTextInput()
                    Button("Set title") { change { $0.title = title } }
                }
                HStack {
                    TextField("Width", text: $width).dashboardQuietTextInput()
                    TextField("Height", text: $height).dashboardQuietTextInput()
                    Button("Resize") {
                        guard let w = Double(width), let h = Double(height), w.isFinite, h.isFinite else { return }
                        change { $0.width = w; $0.height = h }
                    }
                }
                Text("Card color").font(.caption)
                HStack {
                    ForEach(CanvasStyle.colors, id: \.self) { color in
                        Button { change { $0.color = color } } label: {
                            Circle().fill(canvasColor(color)).frame(width: 22, height: 22)
                        }.buttonStyle(.plain).accessibilityLabel(color.capitalized)
                    }
                }
                Menu("Assign to section") {
                    Button("No section") { change { $0.sectionID = nil } }
                    ForEach(document.canvasSections ?? []) { section in
                        Button(section.title) { change { $0.sectionID = section.id } }
                    }
                }
                Divider()
                Text("Connections").font(.caption)
                TextField("Connection label", text: $connectionLabel).dashboardQuietTextInput()
                if ids.count == 2 {
                    Button("Connect selection") {
                        apply([.init(action: .connect, connection: .init(from: ids[0], to: ids[1], label: connectionLabel))])
                    }
                }
                ScrollView {
                    ForEach((document.canvasConnections ?? []).filter { ids.contains($0.from) || ids.contains($0.to) }) { connection in
                        HStack {
                            Text(connection.label.isEmpty ? "Connection" : connection.label).lineLimit(1)
                            Spacer()
                            Button("Rename") { var value = connection; value.label = connectionLabel; apply([.init(action: .connect, connection: value)]) }
                            Button("Remove") { apply([.init(action: .disconnect, id: connection.id)]) }
                        }.font(.caption)
                    }
                }.scrollIndicators(.never).frame(maxHeight: 100)
            }
        }.buttonStyle(DashboardQuietButtonStyle())
            .onAppear { load() }.onChange(of: ids) { _, _ in load() }
    }
    private func load() {
        guard let id = ids.first else { return }
        let value = document.canvasPlacement(for: id)
        title = value.title ?? ""; width = String(Int(value.width)); height = String(Int(value.height))
    }
    private func change(_ update: (inout CanvasCardPlacement) -> Void) {
        apply(ids.map { id in var value = document.canvasPlacement(for: id); update(&value); return .init(action: .place, id: id, placement: value) })
    }
    private func apply(_ edits: [CanvasEdit]) { commitCanvas(edits, document: $document, state: $viewState) }
}

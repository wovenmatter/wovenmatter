import AppKit
import SwiftUI
import WovenMatterDashboardStore

struct DashboardSavedArtifactsView: View {
    @Bindable var model: SavedArtifactsModel
    @State private var search = ""
    @State private var workspaceID: String?

    private var filtered: [SavedArtifactLibraryItem] {
        model.items.filter { item in
            (workspaceID == nil || item.manifest.workspaceID == workspaceID)
                && (search.isEmpty || item.manifest.title.localizedStandardContains(search)
                    || item.workspaceName.localizedStandardContains(search))
        }
    }
    private var workspaces: [(String, String)] {
        Dictionary(model.items.map { ($0.manifest.workspaceID, $0.workspaceName) }, uniquingKeysWith: { first, _ in first })
            .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DashboardSearchField(text: $search, prompt: "Search saved artifacts")
                HStack {
                    Menu {
                        Button("All workspaces") { workspaceID = nil }
                        ForEach(workspaces, id: \.0) { workspace in
                            Button(workspace.1) { workspaceID = workspace.0 }
                        }
                    } label: {
                        Text(workspaces.first { $0.0 == workspaceID }?.1 ?? "All workspaces")
                            .font(.system(size: 12, weight: .medium))
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Workspaces")
                    Spacer()
                    Text("\(filtered.count) \(filtered.count == 1 ? "artifact" : "artifacts")")
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                    if !search.isEmpty || workspaceID != nil {
                        Button("Clear filters") { search = ""; workspaceID = nil }
                            .buttonStyle(DashboardQuietButtonStyle())
                    }
                }
                if let error = model.error {
                    HStack {
                        Text(error).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        Button("Dismiss") { model.error = nil }.buttonStyle(DashboardQuietButtonStyle())
                    }
                }
            }.padding(.horizontal, 32).padding(.bottom, 12)
            if model.loading && model.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                DashboardConversationEmptyState(
                    icon: .libraryBigControl,
                    title: model.items.isEmpty ? "No saved artifacts yet" : "No matching artifacts",
                    detail: model.items.isEmpty
                        ? "Outputs saved from your devices and workspaces will appear here."
                        : "Adjust your workspace filter or search to find an artifact."
                ).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { item in SavedArtifactRow(item: item, model: model) }
                    }.padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 32)
                }.scrollIndicators(.never)
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}

private struct SavedArtifactRow: View {
    @Environment(\.dashboardTheme) private var theme
    let item: SavedArtifactLibraryItem
    @Bindable var model: SavedArtifactsModel
    @State private var shareRequest: SavedArtifactShareRequest?
    private var busy: Bool { model.preparing.contains(item.id) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { details; Spacer(minLength: 10); actions }
            VStack(alignment: .leading, spacing: 12) { details; actions }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.themeWhisper).clipShape(DashboardShapes.card)
        .contextMenu {
            Button("Open") { Task { await model.open(item) } }.disabled(busy)
            Button("Reveal in Finder") {
                Task {
                    if let url = await model.prepare(item) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }.disabled(busy)
        }
    }
    private var details: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.manifest.mediaType.hasPrefix("image/") ? "photo" : "doc")
                .font(.system(size: 20)).foregroundStyle(DashboardPalette.primary).frame(width: 36, height: 40)
            VStack(alignment: .leading, spacing: 5) {
                Button { Task { await model.open(item) } } label: {
                    Text(item.manifest.title).font(.system(size: 13, weight: .semibold))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }.buttonStyle(.plain).disabled(busy)
                Text(item.workspaceName).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                Text("\(ByteCountFormatter.string(fromByteCount: item.manifest.byteCount, countStyle: .file)) · \(item.manifest.mediaType)")
                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground).lineLimit(1)
            }
        }
    }
    private var actions: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Preparing saved artifact") }
            Button("Open") { Task { await model.open(item) } }
                .buttonStyle(DashboardQuietButtonStyle()).disabled(busy)
            Button("Share") {
                Task {
                    if let url = await model.prepare(item) { shareRequest = .init(url: url) }
                }
            }
            .buttonStyle(DashboardQuietButtonStyle()).disabled(busy)
            .background(SavedArtifactShareAnchor(request: shareRequest))
        }.fixedSize()
    }
}

private struct SavedArtifactShareRequest {
    let id = UUID()
    let url: URL
}

/// The picker needs a real view anchor after the verified file is ready.
/// Its lifetime stays in the representable; the observable model contains no AppKit objects.
private struct SavedArtifactShareAnchor: NSViewRepresentable {
    let request: SavedArtifactShareRequest?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard let request, context.coordinator.presentedID != request.id else { return }
        context.coordinator.presentedID = request.id
        let picker = NSSharingServicePicker(items: [request.url])
        context.coordinator.picker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
    final class Coordinator {
        var presentedID: UUID?
        var picker: NSSharingServicePicker?
    }
}

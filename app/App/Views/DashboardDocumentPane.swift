import AppKit
import QuickLookUI
import SwiftUI

private struct OpenDocumentPreviewKey: EnvironmentKey {
    static let defaultValue: (@MainActor (URL, String?) -> Void)? = nil
}

extension EnvironmentValues {
    /// The containing workspace owns navigation; file services own URL preparation.
    var openDocumentPreview: (@MainActor (URL, String?) -> Void)? {
        get { self[OpenDocumentPreviewKey.self] }
        set { self[OpenDocumentPreviewKey.self] = newValue }
    }
}

struct DashboardDocumentPane: View {
    let url: URL
    @Environment(\.dashboardTheme) private var theme
    @State private var refreshID = UUID()
    @State private var available = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    .help("Read-only preview of \(url.lastPathComponent)")
                Spacer(minLength: 4)
                control("Reload preview", symbol: "arrow.clockwise") { refreshID = UUID() }
                control("Reveal in Finder", symbol: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }.disabled(!available)
                control("Open in default app", symbol: "arrow.up.forward.square") {
                    if !NSWorkspace.shared.open(url) { error = "No application could open this file." }
                }.disabled(!available)
            }
            .padding(.horizontal, 10)
            .frame(height: DashboardMetrics.assetToolbarControlHeight)
            .padding(.vertical, DashboardMetrics.assetToolbarVerticalPadding)
            Rectangle().fill(theme.palette.border).frame(height: 1)
            if available {
                DocumentQuickLookView(url: url).id(refreshID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Preview of \(url.lastPathComponent)")
            } else {
                ContentUnavailableView("File unavailable", systemImage: "doc",
                    description: Text("Open this item again from the conversation or Library to prepare a new preview."))
            }
        }
        .background(theme.palette.workspace)
        .task(id: refreshID) { available = FileManager.default.isReadableFile(atPath: url.path) }
        .onChange(of: url) { refreshID = UUID() }
        .alert("Could not open file", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    private func control(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: DashboardMetrics.assetToolbarControlWidth,
                       height: DashboardMetrics.assetToolbarControlHeight)
        }.buttonStyle(DashboardIconButtonStyle()).help(title).accessibilityLabel(title)
    }
}

/// Quick Look loads asynchronously and supplies its own fallback for unsupported formats.
/// Each mounted view owns one preview; teardown releases its file and rendering resources.
struct DocumentQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenMatterCore

/// Resolve only retained message identities, never read paths directly from agent text.
struct ConversationFilePreviews: View {
    let content: String
    let messageID: String
    let resolveFile: (String) async throws -> URL

    private var files: [LibraryAsset] {
        LibraryLinkDiscovery.links(in: content).filter { LibraryFileReference.path($0.source) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files, id: \.source) { file in
                ConversationFileAttachment(file: file, identity: WorkspaceLibraryItem.identifier(
                    messageID: messageID, source: file.source), resolve: { try await resolveFile(file.source) })
            }
        }
    }
}

private struct ConversationFileAttachment: View {
    @Environment(\.openDocumentPreview) private var openPreview
    let file: LibraryAsset
    let identity: String
    let resolve: () async throws -> URL
    @State private var url: URL?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let url {
                    Button { openPreview?(url, "library:" + identity) } label: { label }
                        .buttonStyle(DashboardQuietButtonStyle())
                        .help("Preview \(url.lastPathComponent). Drag to copy the file.")
                        .accessibilityLabel("Preview \(url.lastPathComponent)")
                        .onDrag { NSItemProvider(object: url as NSURL) }
                    Button { Task { await save(url) } } label: {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help("Save \(url.lastPathComponent)…")
                    .accessibilityLabel("Save \(url.lastPathComponent)")
                    Menu {
                        Button("Save As…") { Task { await save(url) } }
                        Button("Open in Default App") {
                            if !NSWorkspace.shared.open(url) { error = "No application could open this file." }
                        }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("File actions for \(url.lastPathComponent)")
                } else {
                    label.foregroundStyle(DashboardPalette.mutedForeground)
                    if loading { ProgressView().controlSize(.small) }
                    else {
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(DashboardQuietButtonStyle())
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
        }
        .task(id: identity) { await load() }
    }

    private var label: some View {
        Label(url?.lastPathComponent ?? file.title, systemImage: file.kind == .photo ? "photo" : "doc.richtext")
            .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        // Library indexes completed messages asynchronously. Give that bounded
        // background pass time to retain the file before presenting Retry.
        for attempt in 0..<4 {
            do {
                try Task.checkCancellation()
                let resolved = try await resolve()
                try Task.checkCancellation()
                guard resolved.isFileURL else { throw WorkspaceToolError.invalid("This attachment is not a local file.") }
                url = resolved
                return
            } catch is CancellationError { return }
            catch {
                if attempt == 3 { self.error = error.localizedDescription; return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func save(_ source: URL) async {
        let panel = NSSavePanel()
        panel.title = "Save Attachment"
        panel.nameFieldStringValue = source.lastPathComponent
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        let result = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard result == .OK, let destination = panel.url else { return }
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        do {
            if source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() {
                try Data(contentsOf: source).write(to: destination, options: .atomic)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

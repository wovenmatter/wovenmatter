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
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { perform { openPreview?($0, "library:" + identity) } } label: {
                    Label(url?.lastPathComponent ?? file.title,
                          systemImage: file.kind == .photo ? "photo" : "doc.richtext")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(DashboardQuietButtonStyle())
                .help("Preview \(file.title). Drag to copy the file.")
                .accessibilityLabel("Preview \(file.title)")
                .onDrag { dragProvider() }
                Button { perform { await save($0) } } label: { Image(systemName: "arrow.down.to.line") }
                    .buttonStyle(DashboardIconButtonStyle())
                    .help("Save \(file.title)…")
                    .accessibilityLabel("Save \(file.title)")
                Menu {
                    Button("Save As…") { perform { await save($0) } }
                    Button(DocumentExternalApplication.openTitle(for: applicationLookupURL)) {
                        perform {
                            if !NSWorkspace.shared.open($0) { error = "No application could open this file." }
                        }
                    }
                    Button("Reveal in Finder") { perform { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("File actions for \(file.title)")
                if loading { ProgressView().controlSize(.small) }
            }
            .disabled(loading)
            if let error { Text(error).font(.caption).foregroundStyle(DashboardPalette.mutedForeground) }
        }
    }

    // Launch Services can identify the associated app from the filename without
    // downloading or reading the attachment. This URL is never opened.
    private var applicationLookupURL: URL {
        url ?? URL(fileURLWithPath: LibraryFileReference.path(file.source) ?? file.title)
    }

    private func perform(_ action: @escaping @MainActor (URL) async -> Void) {
        Task {
            do { await action(try await preparedURL()) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func preparedURL() async throws -> URL {
        if let url, FileManager.default.isReadableFile(atPath: url.path) { return url }
        loading = true
        error = nil
        defer { loading = false }
        // Retention may still be finishing when the user first clicks a reply.
        for attempt in 0..<4 {
            do {
                try Task.checkCancellation()
                let resolved = try await resolve()
                try Task.checkCancellation()
                guard resolved.isFileURL else { throw WorkspaceToolError.invalid("This attachment is not a local file.") }
                url = resolved
                return resolved
            } catch is CancellationError { throw CancellationError() }
            catch {
                if attempt == 3 { throw error }
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw CancellationError()
    }

    private func dragProvider() -> NSItemProvider {
        DocumentAttachmentDrag.provider(
            filename: url?.lastPathComponent ?? applicationLookupURL.lastPathComponent,
            type: UTType(filenameExtension: applicationLookupURL.pathExtension) ?? .data,
            resolve: { try await preparedURL() }, onError: { error = $0.localizedDescription })
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

/// A promised file is transferred only when the drop destination requests it.
@MainActor
enum DocumentAttachmentDrag {
    static func provider(filename: String, type: UTType,
                         resolve: @escaping @MainActor () async throws -> URL,
                         onError: @escaping @MainActor (Error) -> Void) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = filename
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task { @MainActor in
                do {
                    let file = try await resolve()
                    try Task.checkCancellation()
                    completion(file, false, nil)
                    progress.completedUnitCount = 1
                } catch {
                    onError(error)
                    completion(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WovenProtocol

/// The files a reply refers to, as chips in its action row after Copy.
/// Resolve only retained message identities, never read paths directly from agent text.
@MainActor
struct ConversationFileRow {
    let messageID: String
    let resolveFile: (String) async throws -> URL

    static func files(in content: String) -> [LibraryAsset] {
        LibraryLinkDiscovery.links(in: content).filter { LibraryFileReference.path($0.source) != nil }
    }

    /// One chip per file, each with its own actions. A link in the reply's
    /// text to a file opens the first chip for that file's path.
    func chips(_ files: [LibraryAsset], opening request: ConversationFileOpenRequest? = nil) -> some View {
        let target = request.flatMap { request in files.first { LibraryFileReference.path($0.source) == request.path }?.source }
        return ForEach(files, id: \.source) { file in
            ConversationFileAttachment(file: file, identity: WorkspaceLibraryItem.identifier(
                messageID: messageID, source: file.source), resolve: { try await resolveFile(file.source) },
                openRequest: file.source == target ? request : nil)
        }
    }
}

/// A link in a reply's text asking its file's chip to do what clicking the
/// chip does. Each click is a new request.
struct ConversationFileOpenRequest: Equatable {
    let path: String
    let id = UUID()
}

struct ConversationFileAttachment: View {
    /// A chip never takes more than this; its name truncates in the middle.
    private static let maximumNameWidth: CGFloat = 240
    @Environment(\.openDocumentPreview) private var openPreview
    @Environment(\.wovenTheme) private var theme
    let file: LibraryAsset
    let identity: String
    let resolve: () async throws -> URL
    var openRequest: ConversationFileOpenRequest?
    @State private var url: URL?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: ConversationMetrics.tight) {
            HStack(spacing: ConversationMetrics.hair) {
                Button { preview() } label: {
                    Label(url?.lastPathComponent ?? file.title,
                          systemImage: file.kind == .photo ? "photo" : "doc.richtext")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(WovenPalette.foreground)
                        .frame(maxWidth: Self.maximumNameWidth, alignment: .leading)
                        .padding(.leading, ConversationMetrics.labelGap + ConversationMetrics.hair)
                        // The reply's action row height, so Copy and the chips share one line.
                        .frame(height: ConversationMetrics.actionRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Preview \(file.title). Drag to copy the file.")
                .accessibilityLabel("Preview \(file.title)")
                .onDrag { dragProvider() }
                Button { perform { await save($0) } } label: {
                    Image(systemName: "arrow.down.to.line")
                        .frame(width: ConversationMetrics.actionRowHeight, height: ConversationMetrics.actionRowHeight)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(WovenIconButtonStyle())
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
            .padding(.trailing, ConversationMetrics.hair)
            .background(theme.palette.themeSoft.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .disabled(loading)
            if let error { Text(error).font(.caption).foregroundStyle(WovenPalette.mutedForeground) }
        }
        .onChange(of: openRequest) { _, request in if request != nil { preview() } }
    }

    private func preview() {
        perform { openPreview?($0, "library:" + identity) }
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

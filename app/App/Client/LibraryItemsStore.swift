import Foundation
import Observation

/// Files, links and saved artifacts agents produced, as the Library page lists them.
@MainActor
@Observable
final class LibraryItemsStore {
    /// The items that match the last query, newest first unless it asked otherwise.
    private(set) var items: [WorkspaceLibraryItem] = []
    /// Every machine and agent that has items, for the filters.
    private(set) var facets: [LibraryFacet] = []
    private(set) var hasMore = false
    private(set) var loading = false
    /// The last command that failed, until dismissed.
    private(set) var error: String?
    /// Why the list could not be read.
    private(set) var loadError: String?

    let savedArtifacts = SavedArtifactsStore()

    init() {}

    /// The day the date filters count from.
    var today: Date { Date() }

    /// Reads items matching `query`. `more` asks for the next page; `preserveCount`
    /// keeps as many items as are already shown.
    func load(query: LibraryQuery, more: Bool = false, preserveCount: Bool = false) async {}

    /// Asks the owning machine to fetch an item whose file could not be saved.
    func retry(_ item: WorkspaceLibraryItem) {
        error = ClientError.notConnected.localizedDescription
    }

    /// Opens a web link in the browser, or the item's file in the preview.
    func open(_ item: WorkspaceLibraryItem, onOpenFile: @escaping @MainActor (URL, String?) -> Void) {
        error = ClientError.notConnected.localizedDescription
    }

    func dismissError() {
        error = nil
        loadError = nil
    }

    /// The message an item was sent in, for a chat that is no longer listed.
    func sourceMessage(id: String) async throws -> String {
        throw ClientError.notConnected
    }

    /// A local copy of an item's file, fetched by its content.
    func fileURL(id: String) async throws -> URL {
        throw ClientError.notConnected
    }

    /// A local copy of a message attachment, fetched by its content digest.
    func attachmentURL(contentHash: String, fileName: String, mimeType: String,
                       remoteConversationID: String? = nil) async throws -> URL {
        throw ClientError.notConnected
    }
}

/// Files agents saved on any machine, as Saved Artifacts lists them.
@MainActor
@Observable
final class SavedArtifactsStore {
    private(set) var items: [SavedArtifactLibraryItem] = []
    private(set) var loading = false
    /// Items whose file is being fetched to this Mac.
    private(set) var preparing: Set<String> = []
    var error: String?

    init() {}

    func refresh() async {}

    /// A local copy of the item's file, or `nil` with `error` set.
    func prepare(_ item: SavedArtifactLibraryItem) async -> URL? {
        error = ClientError.notConnected.localizedDescription
        return nil
    }

    func open(_ item: SavedArtifactLibraryItem, onOpenFile: @escaping @MainActor (URL, String?) -> Void) async {
        guard let url = await prepare(item) else { return }
        onOpenFile(url, "saved-artifact:" + item.id)
    }
}

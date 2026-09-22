import AppKit
import Foundation
import Observation
import WovenMatterCore
import WovenMatterDashboardStore

@MainActor @Observable
final class LibraryModel {
    private(set) var items: [WorkspaceLibraryItem] = []
    private(set) var facets: [LibraryFacet] = []
    private(set) var hasMore = false
    private(set) var loading = false
    private(set) var today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    private(set) var revision: Int64 = -1
    var error: String?
    private(set) var loadError: String?

    private static let pageSize = 100
    private var query = LibraryQuery()
    private var requestID = UUID()
    private var service: LibraryService?
    private var syncTask: Task<Void, Never>?
    private var locations: [LibraryLocation] = []
    private var remoteWorkspace: LibraryService.RemoteWorkspaceLookup = { _ in nil }

    init(service: LibraryService? = nil) {
        self.service = service
    }

    isolated deinit { syncTask?.cancel() }

    func dismissError() {
        error = nil
        loadError = nil
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    func synchronize(
        service: LibraryService, locations: [LibraryLocation],
        remoteWorkspace: @escaping LibraryService.RemoteWorkspaceLookup
    ) {
        self.service = service
        self.locations = locations
        self.remoteWorkspace = remoteWorkspace
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.synchronizeOnce()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func synchronizeOnce() async {
        guard let service else { return }
        today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        do {
            try await service.synchronize(locations: locations, remoteWorkspace: remoteWorkspace)
            revision = try await service.revision()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func load(query: LibraryQuery, more: Bool = false, preserveCount: Bool = false) async {
        guard let service else { return }
        if more && (loading || !hasMore || self.query != query) { return }
        let sameQuery = self.query == query
        let count =
            more
            ? items.count + Self.pageSize
            : preserveCount && sameQuery ? max(Self.pageSize, items.count) : Self.pageSize
        if !sameQuery {
            items = []
            hasMore = false
        }

        let identity = UUID()
        requestID = identity
        self.query = query
        loading = true
        defer { if identity == requestID { loading = false } }
        do {
            // Reload the visible prefix in one snapshot. Appending an offset page
            // can duplicate or skip exchanges when the catalog changes meanwhile.
            let page = try await service.page(query: query, count: count)
            guard identity == requestID, !Task.isCancelled else { return }
            items = page.items
            facets = page.facets
            hasMore = page.hasMore
            loadError = nil
        } catch {
            if identity == requestID, !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    func open(_ item: WorkspaceLibraryItem) {
        Task {
            do {
                guard let url = try await service?.openURL(id: item.id) else { return }
                if !NSWorkspace.shared.open(url) { error = "No application could open this item." }
            } catch { self.error = error.localizedDescription }
        }
    }

    func retry(_ item: WorkspaceLibraryItem) {
        Task {
            do {
                try await service?.retry(id: item.id)
                await synchronizeOnce()
            } catch { self.error = error.localizedDescription }
        }
    }
}

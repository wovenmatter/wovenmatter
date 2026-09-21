import AppKit
import Foundation
import Observation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

@MainActor @Observable
final class LibraryModel {
    private(set) var items: [WorkspaceLibraryItem] = []
    private(set) var facets: [LibraryFacet] = []
    private(set) var hasMore = false
    private(set) var loading = false
    private(set) var revision: Int64 = -1
    var error: String?
    private var query = LibraryQuery()
    private var requestID = UUID()
    private var service: LibraryService?
    private var syncTask: Task<Void, Never>?
    private var locations: [LibraryLocation] = []
    private var workspaces: [WovenMatterClient.RemoteWorkspaceConfiguration] = []

    isolated deinit { syncTask?.cancel() }

    func stop() { syncTask?.cancel(); syncTask = nil }

    func synchronize(store: DashboardStore, locations: [LibraryLocation], workspaces: [WovenMatterClient.RemoteWorkspaceConfiguration]) {
        service = store.library
        self.locations = locations
        self.workspaces = workspaces
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronizeOnce()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
            }
        }
    }
    private func synchronizeOnce() async {
        guard let service else { return }
        do {
            try await service.synchronize(locations: locations, workspaces: workspaces)
            revision = try await service.revision()
        } catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
    func load(query: LibraryQuery, more: Bool = false, preserveCount: Bool = false) async {
        guard let service else { return }
        if more && (loading || !hasMore || self.query != query) { return }
        let pageCount = preserveCount && self.query == query ? max(1, (items.count + 99) / 100) : 1
        let identity = UUID(); requestID = identity; self.query = query; loading = true
        defer { if identity == requestID { loading = false } }
        let offset = more ? items.count : 0
        do {
            async let choices = service.facets()
            var rows: [WorkspaceLibraryItem] = []
            for pageIndex in 0..<pageCount {
                let page = try await service.items(query: query, offset: offset + pageIndex * 100)
                rows += page.prefix(100)
                if pageIndex == pageCount - 1, page.count > 100 { rows.append(page[100]) }
                if page.count <= 100 { break }
            }
            let facets = try await choices
            guard identity == requestID, !Task.isCancelled else { return }
            let limit = pageCount * 100
            self.items = more ? items + rows.prefix(limit) : Array(rows.prefix(limit))
            self.facets = facets; hasMore = rows.count > limit; error = nil
        } catch { if identity == requestID { self.error = error.localizedDescription } }
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
            }
            catch { self.error = error.localizedDescription }
        }
    }
}

import AppKit
import Foundation
import Observation
import WovenMatterDashboardStore

@MainActor @Observable
final class SavedArtifactsModel {
    private(set) var items: [SavedArtifactLibraryItem] = []
    var replicaItems: [SavedArtifactLibraryItem] = []
    private(set) var loading = false
    private(set) var preparing: Set<String> = []
    var error: String?
    private var service: LibraryService?
    private var backendExecutor: LibraryModel.BackendExecutor?
    private var generation = UUID()

    func configure(service: LibraryService?, backendExecutor: LibraryModel.BackendExecutor? = nil) {
        self.service = service
        self.backendExecutor = backendExecutor
        generation = UUID()
    }

    func refresh() async {
        guard let service else { return }
        let request = generation
        loading = true
        defer { if request == generation { loading = false } }
        do {
            let items = try await service.savedArtifactItems()
            guard request == generation, !Task.isCancelled else { return }
            let replicaIDs = Set(replicaItems.map(\.id))
            self.items = (items.filter { !replicaIDs.contains($0.id) } + replicaItems)
                .sorted { $0.manifest.title.localizedStandardCompare($1.manifest.title) == .orderedAscending }
        } catch {
            if request == generation, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func prepare(_ item: SavedArtifactLibraryItem) async -> URL? {
        guard !preparing.contains(item.id) else { return nil }
        preparing.insert(item.id)
        defer { preparing.remove(item.id) }
        do {
            if let backendExecutor {
                return try await backendExecutor(.openSavedArtifact(id: item.id, revision: item.manifest.revision)).url
            }
            return try await service?.openSavedArtifactURL(id: item.id, revision: item.manifest.revision)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
            return nil
        }
    }

    func open(_ item: SavedArtifactLibraryItem, onOpenFile: @MainActor (URL, String?) -> Void) async {
        guard let url = await prepare(item) else { return }
        onOpenFile(url, "artifact:" + item.id)
    }
}

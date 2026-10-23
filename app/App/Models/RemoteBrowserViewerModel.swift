import AppKit
import Observation
import WovenMatterClient

/// Frames are ephemeral, tied to the selected tab and the lifetime of this viewer.
@MainActor @Observable
final class RemoteBrowserViewerModel {
    private(set) var tabs: [RemoteBrowserTab] = []
    private(set) var selectedID: String?
    private(set) var image: NSImage?
    private(set) var error: String?
    private(set) var hasLoaded = false
    private(set) var updatedAt: Date?
    var paused = false {
        didSet {
            if paused { revision = UUID(); needsRefresh = false }
            else { needsRefresh = true }
        }
    }
    private(set) var needsRefresh = true
    private var revision = UUID()
    private var refreshing = false
    private let loadTabs: () async throws -> RemoteBrowserTabs
    private let loadFrame: (String) async throws -> RemoteBrowserFrame

    init(loadTabs: @escaping () async throws -> RemoteBrowserTabs,
         loadFrame: @escaping (String) async throws -> RemoteBrowserFrame) {
        self.loadTabs = loadTabs; self.loadFrame = loadFrame
    }

    var selectedTab: RemoteBrowserTab? { tabs.first { $0.id == selectedID } }

    func select(_ id: String) {
        guard id != selectedID else { return }
        selectedID = id
        needsRefresh = true
        image = nil
        updatedAt = nil
        error = nil
    }

    func clear() {
        revision = UUID()
        needsRefresh = true
        tabs = []; selectedID = nil; image = nil; updatedAt = nil; error = nil; hasLoaded = false
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let requestRevision = revision
        do {
            let result = try await loadTabs()
            guard !Task.isCancelled, requestRevision == revision else { return }
            tabs = result.running ? Array(result.tabs.prefix(64)) : []
            hasLoaded = true
            if !tabs.contains(where: { $0.id == selectedID }) {
                selectedID = tabs.first?.id; image = nil; updatedAt = nil
            }
            error = nil
            guard let id = selectedID else { image = nil; needsRefresh = false; return }
            do {
                let frame = try await loadFrame(id)
                guard !Task.isCancelled, requestRevision == revision, selectedID == id else { return }
                guard frame.tabID == id, frame.imageBase64.utf8.count <= 2 * 1024 * 1024,
                      let bytes = Data(base64Encoded: frame.imageBase64), let decoded = NSImage(data: bytes),
                      decoded.size.width > 0, decoded.size.height > 0,
                      decoded.size.width <= 1920, decoded.size.height <= 1200 else {
                    throw RemoteWorkspaceClientError.invalidResponse("The workspace returned an invalid browser image.")
                }
                image = decoded; updatedAt = .now; needsRefresh = false
            } catch {
                guard !Task.isCancelled, requestRevision == revision, selectedID == id else { return }
                image = nil; updatedAt = nil; self.error = error.localizedDescription; needsRefresh = false
            }
        } catch {
            guard !Task.isCancelled, requestRevision == revision else { return }
            tabs = []; selectedID = nil; image = nil; updatedAt = nil; hasLoaded = true
            self.error = error.localizedDescription; needsRefresh = false
        }
    }
}

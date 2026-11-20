import Foundation
import Observation
import WovenProtocol

/// One SessionStore per open chat, created on demand.
@MainActor
@Observable
final class SessionsStore {
    /// Created while a view draws, so not itself observed; each store is.
    @ObservationIgnored private var stores: [String: SessionStore] = [:]
    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var workspace: WorkspaceStore?

    init() {}

    func attach(_ server: ServerConnection, workspace: WorkspaceStore) {
        self.server = server
        self.workspace = workspace
        for store in stores.values { store.attach(server, workspace: workspace) }
    }

    /// The store for a chat, created the first time it is opened.
    func session(for sessionID: String) -> SessionStore {
        if let store = stores[sessionID] { return store }
        let store = SessionStore(sessionID: sessionID)
        if let workspace { store.attach(server, workspace: workspace) }
        stores[sessionID] = store
        return store
    }

    /// How many views follow each chat's live view now, and the one task that follows it for them.
    @ObservationIgnored private var followers: [String: Int] = [:]
    @ObservationIgnored private var following: [String: Task<Void, Never>] = [:]

    /// Follows a chat's live view until the task is cancelled. Views share one
    /// subscription per chat; when no view follows it any more, its store is let go.
    func follow(_ sessionID: String) async {
        let store = session(for: sessionID)
        followers[sessionID, default: 0] += 1
        if following[sessionID] == nil { following[sessionID] = Task { await store.follow() } }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        followers[sessionID, default: 1] -= 1
        if followers[sessionID] == 0 {
            followers[sessionID] = nil
            following.removeValue(forKey: sessionID)?.cancel()
            if stores[sessionID] === store { stores[sessionID] = nil }
        }
    }

    /// The store of a chat that has been opened, if any.
    func conversationState(for sessionID: String) -> SessionStore? {
        stores[sessionID]
    }

    // MARK: Used by shell

    /// Pi Durable answered with another model than the one chosen; the window shows it once.
    var defaultAgentFallbackNotice: String?

    /// Uploads files to be attached to a message and returns their composer chips.
    /// Each file goes into this Mac's server's content store; a turn to another
    /// machine's session puts it into that machine's store too (`SessionStore.send`).
    func stageMessageAttachments(_ files: [(url: URL, mimeType: String)]) async throws -> [AgentMessageAttachmentDraft] {
        guard let server, server.isConnected else { throw ClientError.notConnected }
        var drafts: [AgentMessageAttachmentDraft] = []
        for file in files {
            let data = try await Task.detached { try Data(contentsOf: file.url) }.value
            let stored = try await server.call(PutContent(data: data))
            drafts.append(.file(AgentFileAttachmentDraft(
                kind: file.mimeType.hasPrefix("image/") ? .image : .file, fileName: file.url.lastPathComponent,
                mimeType: file.mimeType, sizeBytes: stored.size, contentHash: stored.digest, localURL: file.url)))
        }
        return drafts
    }
}

import Foundation
import Observation

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

    /// The store of a chat that has been opened, if any.
    func conversationState(for sessionID: String) -> SessionStore? {
        stores[sessionID]
    }

    // MARK: Used by shell

    /// Pi Durable answered with another model than the one chosen; the window shows it once.
    var defaultAgentFallbackNotice: String?

    /// Uploads files to be attached to a message and returns their composer chips.
    func stageMessageAttachments(_ files: [(url: URL, mimeType: String)]) async throws -> [AgentMessageAttachmentDraft] {
        throw ClientError.notConnected
    }
}

import Foundation

public enum BackendInvalidationScope: String, Codable, Sendable, Hashable, CaseIterable {
    case openCode, workspace, calendar, runtime, remoteWorkspaces, permissions, settings, usage, databases, bots
}

/// What changed in the background server, published as it happens. Its one
/// listener is the windows' `server.state` stream; windows read only the
/// affected surfaces again from their read-only projections. It is not a
/// second copy of chat history, and nothing waits on it or reads it back.
public actor BackendInvalidationJournal {
    /// The windows' `server.state` stream: every publication, in order.
    public typealias Listener = @Sendable (Set<BackendInvalidationScope>, Set<String>) async -> Void
    private var listener: Listener?

    public init() {}

    public func setListener(_ listener: Listener?) { self.listener = listener }

    public func publish(scopes: Set<BackendInvalidationScope> = [], conversationIDs: Set<String> = []) async {
        guard !scopes.isEmpty || !conversationIDs.isEmpty else { return }
        await listener?(scopes, conversationIDs)
    }
}

import Foundation

/// Opaque cursor is tied to one service lifetime. A reconnect never mistakes a
/// restarted service's lower revision for an up-to-date projection.
public struct BackendInvalidationCursor: Codable, Equatable, Sendable {
    public let instanceID: UUID
    public let revision: UInt64
    public init(instanceID: UUID, revision: UInt64) {
        self.instanceID = instanceID
        self.revision = revision
    }
}

public enum BackendInvalidationScope: String, Codable, Sendable, Hashable {
    case cron, gatewaySettings, openCode, workspace, calendar, runtime, remoteWorkspaces, permissions, settings, usage, databases
}

public struct BackendInvalidations: Codable, Equatable, Sendable {
    public let cursor: BackendInvalidationCursor
    public let requiresReload: Bool
    public let scopes: Set<BackendInvalidationScope>
    public let conversationIDs: Set<String>
}

/// Bounded invalidation log, not a second copy of chat history. Clients use their
/// existing read-only projections and reload only visible/affected surfaces.
/// Publication is event driven; requesting unchanged state performs no DB reads,
/// renders, or serialization of message bodies.
public actor BackendInvalidationJournal {
    private struct Entry {
        let revision: UInt64
        let scopes: Set<BackendInvalidationScope>
        let conversationIDs: Set<String>
    }
    private let instanceID: UUID
    private let capacity: Int
    private var revision: UInt64 = 0
    private var entries: [Entry] = []
    private struct Waiter {
        let cursor: BackendInvalidationCursor
        let continuation: CheckedContinuation<BackendInvalidations, Never>
        let timeout: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    public init(instanceID: UUID = UUID(), capacity: Int = 512) {
        self.instanceID = instanceID
        self.capacity = max(1, capacity)
    }

    public func publish(scopes: Set<BackendInvalidationScope> = [], conversationIDs: Set<String> = []) {
        guard !scopes.isEmpty || !conversationIDs.isEmpty else { return }
        revision += 1
        entries.append(.init(revision: revision, scopes: scopes, conversationIDs: conversationIDs))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        for id in Array(waiters.keys) { finishWaiter(id) }
    }

    /// An idle client holds one waiter rather than polling or touching the database.
    /// Cancellation removes it immediately; bounded timeouts recover lost connections.
    public func waitForChanges(after cursor: BackendInvalidationCursor?, timeoutSeconds: Double = 20) async -> BackendInvalidations {
        let current = changes(after: cursor)
        guard let cursor, !current.requiresReload, current.cursor == cursor,
              !Task.isCancelled, waiters.count < 64 else { return current }
        let id = UUID()
        let seconds = timeoutSeconds.isFinite ? min(20, max(0, timeoutSeconds)) : 20
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: current); return }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    await self?.finishWaiter(id)
                }
                waiters[id] = .init(cursor: cursor, continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { await self.finishWaiter(id) }
        }
    }

    private func finishWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: changes(after: waiter.cursor))
    }

    public func changes(after cursor: BackendInvalidationCursor?) -> BackendInvalidations {
        let next = BackendInvalidationCursor(instanceID: instanceID, revision: revision)
        guard let cursor, cursor.instanceID == instanceID, cursor.revision <= revision,
              cursor.revision >= (entries.first?.revision ?? 1) - 1 else {
            return .init(cursor: next, requiresReload: true, scopes: [], conversationIDs: [])
        }
        var scopes: Set<BackendInvalidationScope> = []
        var conversations: Set<String> = []
        for entry in entries where entry.revision > cursor.revision {
            scopes.formUnion(entry.scopes)
            conversations.formUnion(entry.conversationIDs)
        }
        return .init(cursor: next, requiresReload: false, scopes: scopes, conversationIDs: conversations)
    }
}

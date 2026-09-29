import Foundation

/// Serializes native Stop completion before another input enters preparation.
/// The owner invalidates old input fences synchronously before calling begin.
@MainActor
public final class AgentStopCoordinator {
    private struct Barrier {
        let id: UUID
        let task: Task<Void, any Error>
    }
    private var barriers: [String: Barrier] = [:]

    public init() {}

    @discardableResult
    public func begin(conversationID: String, retainFailure: Bool = true,
                      operation: @escaping @MainActor @Sendable () async throws -> Void) -> Task<Void, any Error> {
        let previous = barriers[conversationID]?.task
        let id = UUID()
        let task = Task {
            if let previous { _ = try? await previous.value }
            try await operation()
        }
        barriers[conversationID] = Barrier(id: id, task: task)
        Task {
            do {
                try await task.value
                if barriers[conversationID]?.id == id { barriers[conversationID] = nil }
            } catch {
                if !retainFailure, barriers[conversationID]?.id == id { barriers[conversationID] = nil }
                // Failure blocks new input. A new explicit Stop retries it.
            }
        }
        return task
    }

    public func wait(conversationID: String) async throws {
        while let barrier = barriers[conversationID] {
            try await barrier.task.value
            try Task.checkCancellation()
            if barriers[conversationID]?.id == barrier.id { return }
        }
    }
}

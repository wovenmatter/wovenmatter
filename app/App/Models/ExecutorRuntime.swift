import Foundation
import WovenMatterCore
import WovenMatterClient

@MainActor
final class ExecutorRuntime {
    var setupTask: Task<Void, Never>?
    var setupStarting = false
    var isSettingUp: Bool { setupStarting || setupTask != nil }
    private var fences: [String: UUID] = [:]
    func fence(_ session: String) -> UUID {
        if let value = fences[session] { return value }
        let value = UUID(); fences[session] = value; return value
    }
    func check(_ session: String, fence: UUID) throws {
        guard fences[session] == fence else { throw CancellationError() }
        try Task.checkCancellation()
    }
    var client: ExecutorBrokerClient?
    var configured: ExecutorConfiguration?
    var jobs: [String: Task<Void, Never>] = [:]
    var sessions: [String: String] = [:]
    var scopeEdits: [String: Task<Void, any Error>] = [:]
    func serialized<Value: Sendable>(_ session: String, operation: @escaping @MainActor () async throws -> Value) -> Task<Value, any Error> {
        let previous = scopeEdits[session]
        let work = Task { _ = try? await previous?.value; return try await operation() }
        scopeEdits[session] = Task { _ = try await work.value }
        return work
    }
    func cancel(_ session: String) {
        fences[session] = UUID()
        for (id, owner) in sessions where owner == session { jobs[id]?.cancel(); jobs[id] = nil }
        let manager = client
        _ = serialized(session) { _ = try? await manager?.call(.object(["operation": .string("cancelSession"), "session": .string(session)])) }
    }
    func cancelAll() {
        // Admission can be awaiting the database or manager before it has a job.
        for session in Set(fences.keys).union(sessions.values) { cancel(session) }
    }
}


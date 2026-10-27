import Foundation
import WovenMatterClient

/// Each projection owns its cursor. A slow settings/inventory request must not
/// hold back a saved prompt or response in the transcript projection.
@MainActor
enum BackendInvalidationConsumer {
    static func run(
        receive: (BackendInvalidationCursor?) async throws -> BackendInvalidations,
        apply: (BackendInvalidations) async throws -> Void,
        failed: (any Error) -> Void
    ) async {
        var cursor: BackendInvalidationCursor?
        while !Task.isCancelled {
            do {
                let change = try await receive(cursor)
                try Task.checkCancellation()
                try await apply(change)
                try Task.checkCancellation()
                cursor = change.cursor
            } catch is CancellationError {
                return
            } catch {
                // Reconnect with a full reload after an incomplete projection.
                // Never acknowledge an invalidation whose apply failed.
                cursor = nil
                failed(error)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

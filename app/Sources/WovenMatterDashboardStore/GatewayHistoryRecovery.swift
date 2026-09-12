import Foundation
import WovenMatterClient

/// Terminal publication can precede transcript persistence. A successful RPC
/// with no exactly-correlated reply is still a miss, not completed recovery.
enum GatewayHistoryRecovery {
  static func assistantText(
    remoteRunID: String,
    fetch: @Sendable () async throws -> GatewayJSONValue,
    pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async -> String? {
    for delay in [0, 100, 400, 1_500, 3_000] {
      do {
        try Task.checkCancellation()
        if delay > 0 { try await pause(.milliseconds(delay)) }
        if let text = OpenClawGatewayCoordinator.assistantText(
          history: try await fetch(), idempotencyKey: remoteRunID
        ) { return text }
      } catch {
        if error is CancellationError || Task.isCancelled { return nil }
      }
    }
    return nil
  }
}

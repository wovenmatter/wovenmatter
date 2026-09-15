import Foundation
import WovenMatterClient

/// Terminal publication can precede canonical transcript persistence. An empty
/// successful history response is a miss and is retried without resending input.
enum GatewayHistoryRecovery {
  static func assistantMessage(
    remoteRunID: String,
    knownInputIDs: Set<String>,
    fetch: @Sendable () async throws -> GatewayJSONValue,
    pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async -> OpenClawGatewayHistoryMessage? {
    for delay in [0, 100, 400, 1_500, 3_000] {
      do {
        try Task.checkCancellation()
        if delay > 0 { try await pause(.milliseconds(delay)) }
        if let message = OpenClawGatewayCoordinator.assistantMessage(
          history: try await fetch(),
          idempotencyKey: remoteRunID,
          knownInputIDs: knownInputIDs
        ) { return message }
      } catch {
        if error is CancellationError || Task.isCancelled { return nil }
      }
    }
    return nil
  }

}

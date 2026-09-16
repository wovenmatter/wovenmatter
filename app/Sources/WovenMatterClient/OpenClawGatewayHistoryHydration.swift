import Foundation

/// Pages and session.message carry display previews. Hydrate sequentially (one
/// outstanding request) so cold history cannot create an unbounded request fanout.
public enum OpenClawGatewayHistoryHydration {
  public static func hydrate(
    _ payload: GatewayJSONValue,
    fetch: @Sendable (String) async throws -> GatewayJSONValue
  ) async throws -> GatewayJSONValue {
    guard var row = payload.objectValue, var messages = row["messages"]?.arrayValue else { return payload }
    for index in messages.indices {
      try Task.checkCancellation()
      guard let preview = OpenClawGatewayHistoryMessage(payload: messages[index]),
            preview.isTruncated, let id = preview.nativeMessageID else { continue }
      let response: GatewayJSONValue
      do { response = try await fetch(id) }
      catch {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        // Keep the marked preview when the native record is unavailable. It
        // remains ineligible to replace an already complete assistant response.
        continue
      }
      try Task.checkCancellation()
      guard let value = response.objectValue?["message"],
            let full = OpenClawGatewayHistoryMessage(payload: value),
            !full.isTruncated, full.transcriptIdentity == preview.transcriptIdentity,
            full.gatewayRunID == preview.gatewayRunID else { continue }
      messages[index] = value
    }
    row["messages"] = .array(messages)
    return .object(row)
  }
}

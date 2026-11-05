import Foundation
import WovenMatterCore

/// Reads usage from Pi Durable records that iPhones and iPads have already synced
/// to this Mac. Only token counts and model names leave the record.
enum PiDurableUsageRecords {
  static let format = "pi-durable.entry.v1"

  static func records(from stored: [CompanionStoredNativeRecord]) -> [UsageDeviceRecord] {
    // A later revision of an entry replaces an earlier one, so the newest row wins.
    var byMessage: [String: UsageDeviceRecord] = [:]
    for record in stored {
      guard let root = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any],
            let entry = root["id"] as? Int,
            let conversation = root["conversationId"] as? Int,
            let messages = root["model"] as? [[String: Any]] else { continue }
      for (index, message) in messages.enumerated() {
        guard message["role"] as? String == "assistant",
              let usage = message["usage"] as? [String: Any],
              let milliseconds = message["timestamp"] as? Double, milliseconds.isFinite else { continue }
        let tokens = UsageTokenCounts(
          inputTokens: count(usage["input"]),
          cachedInputTokens: count(usage["cacheRead"]),
          cacheCreationTokens: count(usage["cacheWrite"]),
          outputTokens: count(usage["output"]),
          reportedTotalTokens: usage["totalTokens"] == nil ? nil : count(usage["totalTokens"])
        )
        guard tokens.totalTokens > 0 else { continue }
        let route = LocalUsageTranscriptParser.billingRoute(message["provider"] as? String ?? "Unknown")
        let id = "\(record.conversationID):\(conversation):\(entry):\(index)"
        byMessage[id] = UsageDeviceRecord(sample: UsageSample(
          id: id,
          provider: route.provider,
          timestamp: Date(timeIntervalSince1970: milliseconds / 1_000),
          sessionID: record.conversationID,
          accountLabel: "Unknown",
          model: message["model"] as? String ?? "Unknown model",
          billingProvider: route.billingProvider,
          billingRoute: route.billingRoute,
          harness: AgentRuntimeKind.defaultAgent.displayName,
          application: "Woven Matter",
          tokens: tokens,
          sourceID: "pi-durable",
          sourceEventID: id
        ))
      }
    }
    return byMessage.values.sorted { $0.timestamp < $1.timestamp }
  }

  private static func count(_ value: Any?) -> Int64 {
    guard let number = value as? NSNumber, number.int64Value >= 0 else { return 0 }
    return number.int64Value
  }
}

public extension UsageDeviceEndpoint {
  /// Usage from an iPhone or iPad, read from records already on this Mac.
  static func piDurableHistory(identity: UsageDeviceIdentity, database: WorkspaceDatabase) -> Self {
    .init(identity: identity, alwaysFull: true) { request in
      let stored = try await database.companionNativeRecords(
        workspaceID: identity.id,
        format: PiDurableUsageRecords.format
      )
      return .paged(PiDurableUsageRecords.records(from: stored), request: request)
    }
  }
}

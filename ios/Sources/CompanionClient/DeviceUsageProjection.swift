import Foundation
import CryptoKit
import WovenMatterCompanion

/// Reads immutable Pi entries already saved for synchronization. It never opens a
/// runtime, refreshes a provider, or combines central usage with device usage.
public enum DeviceUsageProjection {
  public static func samples(in journal: WorkspaceJournalState, workspaceID: String, from: Date, to: Date) throws -> [CompanionUsageSample] {
    let entries = journal.entries.values.filter {
      $0.workspaceID == workspaceID && $0.kind == .nativeRecord && $0.nativeRecord?.format == "pi-durable.entry.v1"
    }
    let records = Dictionary(grouping: entries, by: { $0.nativeRecord!.recordID })
    var latest: [String: (sequence: Int64, conversation: String, record: [String: Any])] = [:]
    for parts in records.values {
      let parts = parts.sorted { $0.nativeRecord!.partIndex < $1.nativeRecord!.partIndex }
      guard let first = parts.first, let metadata = first.nativeRecord, metadata.partCount == parts.count else { continue }
      guard metadata.byteCount >= 0, metadata.byteCount <= 32 * 1_024 * 1_024,
        parts.enumerated().allSatisfy({ index, entry in
          guard let part = entry.nativeRecord else { return false }
          return part.partIndex == index && part.partCount == metadata.partCount && part.sha256 == metadata.sha256
            && part.byteCount == metadata.byteCount && entry.conversationID == first.conversationID
        }) else { throw MobileConnectionError.invalidResponse }
      var data = Data()
      for entry in parts {
        data.append(entry.nativeRecord!.data)
        guard data.count <= metadata.byteCount else { throw MobileConnectionError.invalidResponse }
      }
      guard data.count == metadata.byteCount, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256,
        let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let id = record["id"] as? Int, let nativeConversation = record["conversationId"] as? Int else { throw MobileConnectionError.invalidResponse }
      let key = "\(workspaceID):\(first.conversationID):\(nativeConversation):\(id)"
      let sequence = parts.map(\.originSequence).max() ?? first.originSequence
      if latest[key]?.sequence ?? -1 < sequence { latest[key] = (sequence, first.conversationID, record) }
    }
    var samples: [CompanionUsageSample] = []
    for (key, value) in latest {
      for (index, message) in (value.record["model"] as? [[String: Any]] ?? []).enumerated() {
        guard message["role"] as? String == "assistant", let usage = message["usage"] as? [String: Any],
          let timestamp = message["timestamp"] as? Double, timestamp.isFinite else { continue }
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        guard date >= from, date <= to else { continue }
        func count(_ field: String) throws -> Int64 {
          guard let number = usage[field] else { return 0 }
          guard let value = number as? Int64, value >= 0 else { throw MobileConnectionError.invalidResponse }
          return value
        }
        let input = try count("input"), output = try count("output"), read = try count("cacheRead"), write = try count("cacheWrite")
        var total: Int64 = 0
        for value in [input, output, read, write] {
          let (sum, overflow) = total.addingReportingOverflow(value)
          guard !overflow else { throw MobileConnectionError.invalidResponse }; total = sum
        }
        if usage["totalTokens"] != nil { total = try count("totalTokens") }
        samples.append(.init(id: "\(key):\(index)", timestamp: date, provider: message["provider"] as? String ?? "Unknown provider",
          model: message["model"] as? String ?? "Unknown model", account: "", workspace: "This device", sessionID: value.conversation,
          inputTokens: input, outputTokens: output, cacheTokens: read, totalTokens: total, requests: 1, costUSD: nil))
      }
    }
    return samples.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
  }
}

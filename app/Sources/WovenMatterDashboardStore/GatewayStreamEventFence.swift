import CryptoKit
import Foundation
import WovenMatterClient

/// Fences replayed and mirrored Gateway frames within one remote run. Sequence
/// numbers advance across agent streams; chat snapshots intentionally skip
/// intermediate values. Keep per-source replay watermarks, but do not infer
/// packet loss from their spacing. `session.tool` mirrors `agent/tool`.
struct GatewayStreamEventFence: Sendable {
  enum Decision: Equatable, Sendable {
    case accept
    case duplicate
  }

  private var sequences: [String: Int] = [:]

  mutating func evaluate(
    _ event: OpenClawGatewayEvent,
    remoteRunID: String
  ) -> Decision {
    let payload = event.payload?.objectValue
    let name = event.name == "session.tool" ? "agent" : event.name
    let stream = payload?["stream"]?.stringValue
      ?? (event.name == "session.tool" ? "tool" : "")
    let key = "\(remoteRunID):\(name):\(stream)"
    if let sequence = payload?["seq"]?.intValue {
      if let previous = sequences[key] {
        if sequence <= previous { return .duplicate }
      }
      sequences[key] = sequence
    }
    return .accept
  }
}

/// OpenClaw can publish the same assistant stream on `agent` and `chat`.
/// Keep ordered deltas from the first source until a cumulative snapshot makes
/// `chat` authoritative. Repeated text on the owning source remains meaningful.
struct GatewayAssistantStreamSource: Sendable {
  private enum Owner { case agent, chat }
  private var owners: [String: Owner] = [:]
  private var terminalRuns: Set<String> = []

  mutating func accepts(
    _ event: OpenClawGatewayEvent,
    runID: String,
    update: OpenClawGatewayEventProjection.AssistantUpdate,
    terminal: Bool
  ) -> Bool {
    guard !terminalRuns.contains(runID) else { return false }
    if terminal {
      terminalRuns.insert(runID)
      return true
    }
    let source: Owner = event.name == "chat" ? .chat : .agent
    switch (owners[runID], source, update) {
    case (nil, _, _):
      owners[runID] = source
      return true
    case (.agent, .agent, _), (.chat, .chat, _):
      return true
    case (.agent, .chat, .replace):
      owners[runID] = .chat
      return true
    case (.agent, .chat, .append), (.chat, .agent, _):
      return false
    }
  }

  mutating func finish(runID: String) {
    terminalRuns.insert(runID)
  }
}

/// The native audit ledger hashes provider call IDs, not Woven's run-scoped IDs.
/// A digest match proves equivalence; tool names and text never do.
enum GatewayAuditToolIdentity {
  static func ledgerID(nativeCallID: String) -> String {
    "sha256:" + SHA256.hash(data: Data(nativeCallID.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func matches(_ auditID: String, scopedID: String, remoteRunID: String) -> Bool {
    let prefix = remoteRunID + ":"
    guard scopedID.hasPrefix(prefix) else { return false }
    let nativeID = String(scopedID.dropFirst(prefix.count))
    return auditID == nativeID || auditID == ledgerID(nativeCallID: nativeID)
  }
}

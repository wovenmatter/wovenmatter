import CryptoKit
import Foundation
import WovenMatterCore

/// A native session offered by the Gateway import library.
public struct OpenClawGatewaySession: Identifiable, Equatable, Codable, Sendable {
  public let key: String
  public let title: String
  public var id: String { key }

  public init?(payload: GatewayJSONValue) {
    guard let row = payload.objectValue,
          let key = row["key"]?.stringValue ?? row["sessionKey"]?.stringValue,
          !key.isEmpty else { return nil }
    self.key = key
    title = row["displayName"]?.stringValue ?? row["title"]?.stringValue
      ?? row["label"]?.stringValue ?? key
  }

  public static func agentID(for key: String) -> String? {
    let parts = key.split(separator: ":", maxSplits: 2)
    return parts.count == 3 && parts[0] == "agent" ? String(parts[1]) : nil
  }
}

public struct OpenClawGatewayHistoryMessage: Codable, Equatable, Sendable {
  public let id: String
  public let role: String
  public let nativeRole: String
  public let isAssistantResponse: Bool
  public let text: String
  public let runID: String?
  public let gatewayRunID: String?
  public let transcriptIdentity: String?
  public let date: Date
  public let raw: Data
  public let terminalError: String?

  public var isTruncated: Bool {
    metadata?["truncated"]?.boolValue == true
  }

  public var isCommentary: Bool {
    guard let row = (try? JSONDecoder().decode(GatewayJSONValue.self, from: raw))?.objectValue else { return false }
    return row["openclawStreamFallback"]?.objectValue?["phase"]?.stringValue == "commentary"
      || (metadata?["idempotencyKey"]?.stringValue ?? row["idempotencyKey"]?.stringValue ?? "").contains(":commentary:")
  }

  public var commentaryItemID: String? {
    guard isCommentary else { return nil }
    return (try? JSONDecoder().decode(GatewayJSONValue.self, from: raw))?.objectValue?["openclawStreamFallback"]?.objectValue?["itemId"]?.stringValue
  }

  public var transcriptSequence: Int? {
    metadata?["transcriptPosition"]?.objectValue?["rawSeq"]?.intValue ?? metadata?["seq"]?.intValue
  }

  public var toolActivities: [AgentRunActivity] {
    guard let row = (try? JSONDecoder().decode(GatewayJSONValue.self, from: raw))?.objectValue else { return [] }
    func json(_ value: GatewayJSONValue?) -> String? {
      value.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    }
    let blocks = row["content"]?.arrayValue ?? []
    let result = nativeRole == "tool" || nativeRole == "toolResult"
    let candidates = result ? [GatewayJSONValue.object(row)] : blocks
    return candidates.enumerated().compactMap { index, value in
      guard let block = value.objectValue,
            result || ["toolCall", "tool_use"].contains(block["type"]?.stringValue ?? "") else { return nil }
      let toolID = block["toolCallId"]?.stringValue ?? block["id"]?.stringValue ?? "\(id):tool:\(index)"
      let name = block["toolName"]?.stringValue ?? block["name"]?.stringValue
      let output = result ? (block["content"] ?? block["text"]) : nil
      let content = result ? blocks.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n") : nil
      return AgentRunActivity(id: "\(gatewayRunID ?? runID ?? id):\(toolID)", kind: .tool,
        phase: result ? "result" : "start", title: name, status: result ? (row["isError"]?.boolValue == true ? "failed" : "completed") : "unknown",
        toolName: name, content: content, rawInputJSON: result ? nil : json(block["arguments"] ?? block["input"]),
        rawOutputJSON: json(output), rawPayloadJSON: String(decoding: raw, as: UTF8.self))
    }
  }

  public var nativeMessageID: String? {
    metadata?["id"]?.stringValue
      ?? (try? JSONDecoder().decode(GatewayJSONValue.self, from: raw))?.objectValue?["id"]?.stringValue
  }

  private var metadata: [String: GatewayJSONValue]? {
    (try? JSONDecoder().decode(GatewayJSONValue.self, from: raw))?.objectValue?["__openclaw"]?.objectValue
  }

  public init?(payload: GatewayJSONValue) {
    guard let row = payload.objectValue, let role = row["role"]?.stringValue,
          ["user", "assistant", "toolResult", "tool"].contains(role) else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let raw = try? encoder.encode(payload) else { return nil }
    self.raw = raw
    nativeRole = role
    let synthetic = row["__openclaw"]?.objectValue?["kind"]?.stringValue
    let commentary = row["openclawStreamFallback"]?.objectValue?["phase"]?.stringValue == "commentary"
      || (row["__openclaw"]?.objectValue?["idempotencyKey"]?.stringValue ?? row["idempotencyKey"]?.stringValue ?? "").contains(":commentary:")
    isAssistantResponse = role == "assistant" && synthetic == nil && !commentary
      && !["toolUse", "tool_use"].contains(row["stopReason"]?.stringValue ?? "")
    let stopReason = row["stopReason"]?.stringValue
    terminalError = ["error", "aborted", "cancelled"].contains(stopReason ?? "")
      ? (row["errorMessage"]?.stringValue ?? "OpenClaw ended this response: \(stopReason ?? "error").") : nil
    self.role = role == "user" ? "user" : "assistant"
    let metadata = row["__openclaw"]?.objectValue ?? [:]
    // One transcript record can project multiple roles/blocks. Retain siblings.
    let key = metadata["id"]?.stringValue ?? row["id"]?.stringValue
      ?? SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    // A byte-bounded page can begin halfway through a record's projected siblings.
    // Page-local ordinals are not identities. Include the canonical content so a
    // sibling keeps the same identity in tail pages and complete/overlapping pages.
    let projection = GatewayJSONValue.object([
      "content": row["content"] ?? row["text"] ?? .null,
      "toolCallId": row["toolCallId"] ?? .null,
      "kind": metadata["kind"] ?? .null,
    ])
    let projectionData = (try? encoder.encode(projection)) ?? raw
    let projectionID = SHA256.hash(data: projectionData).map { String(format: "%02x", $0) }.joined()
    id = key + ":" + role + ":" + projectionID
    // Native record identity survives content revisions; synthetic siblings retain
    // their own kind/tool identity. No content-only identity is repair authority.
    transcriptIdentity = (metadata["id"]?.stringValue ?? row["id"]?.stringValue).map {
      $0 + ":" + role + ":" + (metadata["kind"]?.stringValue ?? "") + ":" + (row["toolCallId"]?.stringValue ?? "")
    }
    gatewayRunID = metadata["runId"]?.stringValue
    let idempotencyKey = metadata["idempotencyKey"]?.stringValue ?? row["idempotencyKey"]?.stringValue
    runID = idempotencyKey.map {
      var value = $0
      for suffix in [":assistant-media", ":assistant", ":user"] where value.hasSuffix(suffix) {
        value.removeLast(suffix.count)
      }
      return value.hasPrefix("cli-assistant:") ? String(value.dropFirst(14)) : value
    } ?? metadata["runId"]?.stringValue
    if let milliseconds = row["timestamp"]?.intValue {
      date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    } else if let timestamp = row["timestamp"]?.stringValue {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) ?? .distantPast
    } else { date = .distantPast }
    text = Self.text(row)
  }

  /// The Gateway persists its final text under this idempotent suffix. Other
  /// transcript records retain whole-message replacement semantics.
  public var isFinalOnlyAssistantTranscript: Bool {
    guard isAssistantResponse,
          let payload = try? JSONDecoder().decode(GatewayJSONValue.self, from: raw),
          let row = payload.objectValue else { return false }
    let key = row["__openclaw"]?.objectValue?["idempotencyKey"]?.stringValue
      ?? row["idempotencyKey"]?.stringValue
    return key?.hasSuffix(":assistant") == true
  }

  public func correlatedRunID(knownInputIDs: Set<String>) -> String? {
    if let runID, knownInputIDs.contains(runID) { return runID }
    return gatewayRunID ?? runID
  }

  public static func text(_ row: [String: GatewayJSONValue]) -> String {
    if let text = row["text"]?.stringValue ?? row["content"]?.stringValue { return text }
    return (row["content"]?.arrayValue ?? []).compactMap { part -> String? in
      guard let block = part.objectValue else { return nil }
      switch block["type"]?.stringValue {
      case "text": return block["text"]?.stringValue
      case "thinking", "reasoning":
        return (block["thinking"]?.stringValue ?? block["text"]?.stringValue).map { "**Thinking**\n\n" + $0 }
      case "toolCall", "tool_use": return nil
      case "image", "audio", "video", "file":
        let label = block["alt"]?.stringValue ?? block["fileName"]?.stringValue ?? block["type"]?.stringValue ?? "Attachment"
        let source = block["url"]?.stringValue ?? block["path"]?.stringValue ?? block["source"]?.objectValue?["url"]?.stringValue
        if let source { return "[" + label.replacingOccurrences(of: "]", with: "") + "](" + source + ")" }
        return "[Attachment: " + label + " — open in OpenClaw Control UI]"
      default: return nil
      }
    }.joined(separator: "\n\n")
  }
}

public struct OpenClawGatewayHistory: Codable, Sendable {
  public let messages: [OpenClawGatewayHistoryMessage]
  public let sessionID: String?
  public let hasActiveRun: Bool
  public let isIdle: Bool
  public let inFlightRunID: String?
  public let inFlightText: String?
  public let inFlightIsTruncated: Bool
  public let nextOffset: Int?
  public let totalMessages: Int?

  public init(payload: GatewayJSONValue) throws {
    guard let row = payload.objectValue, let messages = row["messages"]?.arrayValue else {
      throw OpenClawGatewayClientError.malformedFrame
    }
    var seen: Set<String> = []
    self.messages = messages.compactMap { value in
      guard let first = OpenClawGatewayHistoryMessage(payload: value) else { return nil }
      return seen.insert(first.id).inserted ? first : nil
    }
    let session = row["sessionInfo"]?.objectValue ?? [:]
    sessionID = row["sessionId"]?.stringValue ?? session["sessionId"]?.stringValue
    let activeRunIDs = session["activeRunIds"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
    hasActiveRun = session["hasActiveRun"]?.boolValue == true || activeRunIDs?.isEmpty == false
    let flight = row["inFlightRun"]?.objectValue
    inFlightRunID = flight?["runId"]?.stringValue
    inFlightText = flight?["text"]?.stringValue
    // Current Gateway budgeting keeps the whole in-flight text or omits it.
    // Respect explicit preview metadata as well, if present on another version.
    inFlightIsTruncated = flight?["truncated"]?.boolValue == true
      || flight?["__openclaw"]?.objectValue?["truncated"]?.boolValue == true
    isIdle = !hasActiveRun && inFlightRunID == nil && (session["hasActiveRun"]?.boolValue == false
      || session["activeRunIds"]?.arrayValue?.isEmpty == true)
    if row["hasMore"]?.boolValue == true {
      guard let next = row["nextOffset"]?.intValue, next > 0 else {
        throw OpenClawGatewayClientError.malformedFrame
      }
      nextOffset = next
    } else { nextOffset = nil }
    totalMessages = row["totalMessages"]?.intValue
  }
}

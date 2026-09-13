import CryptoKit
import Foundation

/// Small, typed projections of the 2026.9.4 Gateway v4 contract. Keep the raw
/// message alongside its projection so additive content blocks remain recoverable.
public struct OpenClawGatewaySession: Identifiable, Equatable, Sendable {
  public let key: String
  public let title: String
  public let agentID: String
  public let isActive: Bool
  public let updatedAt: Date?
  public var id: String { key }

  public init?(payload: GatewayJSONValue) {
    guard let row = payload.objectValue,
          let key = row["key"]?.stringValue ?? row["sessionKey"]?.stringValue,
          !key.isEmpty else { return nil }
    self.key = key
    title = row["displayName"]?.stringValue ?? row["title"]?.stringValue
      ?? row["label"]?.stringValue ?? key
    agentID = row["agentId"]?.stringValue ?? Self.agentID(for: key) ?? "main"
    isActive = row["hasActiveRun"]?.boolValue == true
    updatedAt = row["updatedAt"]?.intValue.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
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
  public let date: Date
  public let raw: Data
  public let terminalError: String?

  public init?(payload: GatewayJSONValue) {
    guard let row = payload.objectValue, let role = row["role"]?.stringValue,
          ["user", "assistant", "toolResult", "tool"].contains(role) else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let raw = try? encoder.encode(payload) else { return nil }
    self.raw = raw
    nativeRole = role
    let synthetic = row["__openclaw"]?.objectValue?["kind"]?.stringValue
    isAssistantResponse = role == "assistant" && synthetic == nil
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

  public static func text(_ row: [String: GatewayJSONValue]) -> String {
    if let text = row["text"]?.stringValue ?? row["content"]?.stringValue { return text }
    return (row["content"]?.arrayValue ?? []).compactMap { part -> String? in
      guard let block = part.objectValue else { return nil }
      switch block["type"]?.stringValue {
      case "text": return block["text"]?.stringValue
      case "thinking", "reasoning":
        return (block["thinking"]?.stringValue ?? block["text"]?.stringValue).map { "**Thinking**\n\n" + $0 }
      case "toolCall", "tool_use": return "**Tool:** " + (block["name"]?.stringValue ?? "Tool call")
      case "image", "audio", "video", "file":
        return "[Attachment: \(block["alt"]?.stringValue ?? block["fileName"]?.stringValue ?? block["type"]?.stringValue ?? "file") — open in OpenClaw Control UI]"
      default: return nil
      }
    }.joined(separator: "\n\n")
  }
}

public struct OpenClawGatewayHistory: Codable, Sendable {
  public let messages: [OpenClawGatewayHistoryMessage]
  public let sessionID: String?
  public let activeRunIDs: Set<String>?
  public let hasActiveRun: Bool
  public let isIdle: Bool
  public let inFlightRunID: String?
  public let inFlightText: String?
  public let nextOffset: Int?
  public let cursor: String?
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
    activeRunIDs = session["activeRunIds"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
    hasActiveRun = session["hasActiveRun"]?.boolValue == true || activeRunIDs?.isEmpty == false
    let flight = row["inFlightRun"]?.objectValue
    inFlightRunID = flight?["runId"]?.stringValue
    inFlightText = flight?["text"]?.stringValue
    isIdle = !hasActiveRun && inFlightRunID == nil && (session["hasActiveRun"]?.boolValue == false
      || session["activeRunIds"]?.arrayValue?.isEmpty == true)
    if row["hasMore"]?.boolValue == true {
      guard let next = row["nextOffset"]?.intValue, next > 0 else {
        throw OpenClawGatewayClientError.malformedFrame
      }
      nextOffset = next
    } else { nextOffset = nil }
    totalMessages = row["totalMessages"]?.intValue
    cursor = row["deltaCursor"]?.stringValue
  }
}

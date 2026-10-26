import Foundation
import CryptoKit
import WovenMatterCompanion

public struct MobileToolContext: Sendable {
  public var sessionID: String
  public var workspaceID: String
  public var folderID: String?
  public var enabled: Set<WorkspaceToolGroup>
  public var nativeToolIDs: [String]?
  public var calendarReadOnly: Bool
  public init(sessionID: String, workspaceID: String, folderID: String? = nil,
              enabled: Set<WorkspaceToolGroup> = Set(WorkspaceToolGroup.allCases.filter { $0 != .computer }), calendarReadOnly: Bool = false, nativeToolIDs: [String]? = nil) {
    self.sessionID = sessionID; self.workspaceID = workspaceID; self.folderID = folderID
    self.enabled = enabled.union([.html]); self.calendarReadOnly = calendarReadOnly; self.nativeToolIDs = nativeToolIDs
  }
  public func authorize(_ command: WovenMatterToolCommand) throws {
    guard let group = command.group, !command.wantsHelp else { return }
    if group.isAutomation, command.action == "cancel" { return }
    guard enabled.contains(group) else { throw WorkspaceToolError.disabled(group) }
    if group == .calendar, command.isMutation, calendarReadOnly { throw WorkspaceToolError.invalid("Calendar is read only for this session.") }
  }
}

public struct MobileToolReceipt: Codable, Equatable, Sendable {
  public var requestID: String
  public var sessionID: String
  public var arguments: [String]
  public var response: WovenMatterToolResponse
}
public struct MobileToolNoteVersion: Codable, Equatable, Sendable {
  public var id: String
  public var note: CompanionNote
  public var savedAt: String
}
public struct MobileToolTimer: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var sessionID: String
  public var instruction: String
  public var nextFireAt: Date
  public var intervalSeconds: Double?
  public var isPaused: Bool
  public var removed: Bool = false
  public var pendingFireID: String?
  public var pendingFireAt: Date?
}

public enum MobileToolSupport {
  public static func fingerprint(_ note: CompanionNote) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(note)).map { String(format: "%02x", $0) }.joined()
  }
  public static func value<T: Encodable>(_ value: T) throws -> GatewayJSONValue {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    return try JSONDecoder().decode(GatewayJSONValue.self, from: encoder.encode(value))
  }
  public static func date(_ string: String) throws -> Date {
    let parser = ISO8601DateFormatter()
    if let date = parser.date(from: string) { return date }
    parser.formatOptions.insert(.withFractionalSeconds)
    guard let date = parser.date(from: string) else { throw WorkspaceToolError.invalid("Use an ISO8601 date with a time zone.") }
    return date
  }
  public static func page(_ rows: [GatewayJSONValue], command: WovenMatterToolCommand, offsetKey: String = "after") throws -> GatewayJSONValue {
    let offset = try command.integer(offsetKey, default: 0, range: 0...Int.max)
    let limit = try command.integer("limit", default: 100, range: 1...200)
    let page = Array(rows.dropFirst(offset).prefix(limit)), end = min(rows.count, offset > rows.count ? rows.count : offset + page.count)
    return .object(["rows": .array(page), "hasMore": .bool(end < rows.count), "nextCursor": end < rows.count ? .string(String(end)) : .null])
  }
  public static func chunk(_ text: String, command: WovenMatterToolCommand) throws -> [String: GatewayJSONValue] {
    let offset = min(text.count, try command.integer("offset", default: 0, range: 0...Int.max))
    let count = try command.integer("characters", default: 65_536, range: 1...65_536)
    let start = text.index(text.startIndex, offsetBy: offset), end = text.index(start, offsetBy: min(count, text.distance(from: start, to: text.endIndex)))
    let next = text.distance(from: text.startIndex, to: end)
    return ["content": .string(String(text[start..<end])), "contentCharacters": .number(Double(text.count)), "offset": .number(Double(offset)), "nextOffset": .number(Double(next)), "hasMore": .bool(next < text.count)]
  }
  public static func response(error: any Error, requestID: String?) -> WovenMatterToolResponse {
    let code: String
    switch error {
    case WorkspaceToolError.disabled: code = "tool_disabled"
    case WorkspaceToolError.notFound: code = "not_found"
    case WorkspaceToolError.revisionRequired: code = "revision_required"
    case WorkspaceToolError.revisionConflict: code = "revision_conflict"
    case WorkspaceToolError.accessRequired: code = "access_required"
    default: code = "invalid_request"
    }
    return .init(success: false, error: error.localizedDescription, code: code, requestID: requestID)
  }
}

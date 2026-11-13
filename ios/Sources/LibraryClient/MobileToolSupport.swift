import Foundation
import CryptoKit
import WovenMatterShared

public struct MobileToolContext: Sendable {
  public var sessionID: String
  public var workspaceID: String
  public var folderID: String?
  public var enabled: Set<WorkspaceToolGroup>
  public var nativeToolIDs: [String]?
  /// The calling chat's title, shown on the Page components it changes.
  public var sessionTitle: String?
  public init(sessionID: String, workspaceID: String, folderID: String? = nil,
              enabled: Set<WorkspaceToolGroup> = Set(WorkspaceToolGroup.allCases.filter { $0 != .computer }), nativeToolIDs: [String]? = nil,
              sessionTitle: String? = nil) {
    self.sessionID = sessionID; self.workspaceID = workspaceID; self.folderID = folderID
    self.enabled = enabled.union([.html]); self.nativeToolIDs = nativeToolIDs; self.sessionTitle = sessionTitle
  }
  /// Who a Page write from this caller is attributed to. It comes from the
  /// authorized context, never from tool arguments.
  public var pageActor: BoardActor {
    BoardActor(kind: .session, sessionID: sessionID, label: sessionTitle.map { String($0.prefix(160)) })
  }
  public func authorize(_ command: WovenMatterToolCommand) throws {
    guard let group = command.group else { return }
    if group.isAutomation, command.action == "cancel" { return }
    guard enabled.contains(group) else { throw WorkspaceToolError.disabled(group) }
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
  public var note: LibraryNote
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
  /// Migrate persisted capability selections, not executable legacy tool names.
  /// Individual note grants stay individual rather than enabling the whole group.
  public static func migratedMCPSelection(_ selection: [String]?) -> [String]? {
    selection.map { values in
      Set(values.flatMap { value -> [String] in
        switch value {
        case "list_notes": return ["woven_notes_list"]
        case "read_note": return ["woven_notes_read"]
        case "save_note": return ["woven_notes_create", "woven_notes_apply"]
        case "woven_browser_cancel": return ["woven_browser_use_cancel"]
        case "woven_computer_cancel": return ["woven_computer_use_cancel"]
        default:
          if value.hasPrefix("wovenmatter_"), let group = WorkspaceToolGroup(rawValue: String(value.dropFirst("wovenmatter_".count))) {
            return ["woven_" + group.rawValue]
          }
          return [value]
        }
      }).sorted()
    }
  }
  public static func permittedMCPTools(selection: [String], available: [String]) -> [String] {
    let selected = Set(migratedMCPSelection(selection) ?? [])
    return available.filter { name in
      if selected.contains(name) { return true }
      guard let group = WovenMCPCatalog.tools.first(where: { $0.name == name })?.group else { return false }
      return selected.contains("woven_" + group.rawValue)
    }.sorted()
  }
  public static func fingerprint(_ note: LibraryNote) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(note)).hexString
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
    case ArtifactStateError.conflict: code = "revision_conflict"
    default: code = "invalid_request"
    }
    return .init(success: false, error: error.localizedDescription, code: code, requestID: requestID)
  }
}

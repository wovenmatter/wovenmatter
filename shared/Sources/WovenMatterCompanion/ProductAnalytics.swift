import Foundation

/// Analytics identities are independent of operational library/device/account IDs.
public struct ProductAnalyticsPreference: Codable, Equatable, Sendable {
  public var analyticsID: String
  public var enabled: Bool
  public var revision: Int64
  public var disclosedAt: Date?
  public init(
    analyticsID: String, enabled: Bool = true, revision: Int64 = 1, disclosedAt: Date? = nil
  ) {
    self.analyticsID = analyticsID
    self.enabled = enabled
    self.revision = revision
    self.disclosedAt = disclosedAt
  }
  public var collects: Bool { enabled && disclosedAt != nil }
}
public struct ProductAnalyticsPreferenceChange: Codable, Sendable {
  public var enabled: Bool
  public var expectedRevision: Int64
  public var acknowledgeDisclosure: Bool
  public init(enabled: Bool, expectedRevision: Int64, acknowledgeDisclosure: Bool = false) {
    self.enabled = enabled
    self.expectedRevision = expectedRevision
    self.acknowledgeDisclosure = acknowledgeDisclosure
  }
}
public struct ProductAnalyticsEvent: Codable, Equatable, Identifiable, Sendable {
  public enum Name: String, Codable, Sendable {
    case appOpened = "app_opened"
    case contentChanged = "content_changed"
    case sessionCreated = "session_created"
    case messageSubmitted = "message_submitted"
    case agentRunCompleted = "agent_run_completed"
    case updateCheckClicked = "update_check_clicked"
    case updateDownloadClicked = "update_download_clicked"
    case updateDownloadCompleted = "update_download_completed"
    case updateDownloadFailed = "update_download_failed"
    case updateInstallClicked = "update_install_clicked"
    case updateInstallCompleted = "update_install_completed"
    case updateInstallFailed = "update_install_failed"
  }
  public var id: String
  public var timestamp: Date
  public var preferenceRevision: Int64
  public var name: Name
  public var properties: [String: String]
  public init(
    id: String = UUID().uuidString.lowercased(), timestamp: Date = Date(),
    preferenceRevision: Int64, name: Name, properties: [String: String] = [:]
  ) {
    self.id = id
    self.timestamp = timestamp
    self.preferenceRevision = preferenceRevision
    self.name = name
    self.properties = Self.sanitize(properties)
  }
  public var qualifying: Bool {
    name == .contentChanged || name == .sessionCreated || name == .messageSubmitted
  }
  /// Re-applied at the central ingestion boundary, including decoded remote input.
  public static func sanitize(_ values: [String: String]) -> [String: String] {
    let enums: [String: Set<String>] = [
      "platform": ["macos", "ios", "ipados"],
      "action": ["create", "edit", "move", "delete", "restore"],
      "item_category": [
        "folder", "note", "document", "spreadsheet", "database", "presentation", "asset",
        "calendar", "session", "other",
      ],
      "outcome": ["success", "failure", "cancelled"],
      "harness": ["pi", "claude", "codex", "opencode", "openclaw", "hermes", "cursor", "other"],
      "provider": ["openai", "anthropic", "google", "xai", "openrouter", "other"],
      "duration_range": ["under_10s", "10s_1m", "1m_5m", "5m_30m", "over_30m"],
      "token_range": ["under_1k", "1k_10k", "10k_100k", "over_100k"],
      "error_class": ["network", "authentication", "rate_limit", "runtime", "other"],
    ]
    var result: [String: String] = [:]
    for (key, value) in values {
      if enums[key]?.contains(value) == true { result[key] = value }
      if key == "app_version" || key == "target_version",
        value.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil
      {
        result[key] = value
      }
      if key == "os_major", let major = Int(value), (1...99).contains(major) {
        result[key] = String(major)
      }
      // Do not send user-configured model labels or endpoint names. Model metadata
      // can be added later through a reviewed public-catalog allowlist.
    }
    return result
  }
  public func postHogObject(analyticsID: String) -> [String: Any] {
    var values: [String: Any] = Self.sanitize(properties)
    values["distinct_id"] = analyticsID
    values["$process_person_profile"] = false
    values["source"] = "app"
    values["qualifying_activity"] = qualifying
    return [
      "event": name.rawValue, "uuid": id,
      "timestamp": ISO8601DateFormatter().string(from: timestamp), "properties": values,
    ]
  }
  public func inspectionJSON(analyticsID: String) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: postHogObject(analyticsID: analyticsID),
        options: [.prettyPrinted, .sortedKeys])
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
  public static func durationRange(_ seconds: TimeInterval) -> String {
    switch seconds {
    case ..<10: "under_10s"
    case ..<60: "10s_1m"
    case ..<300: "1m_5m"
    case ..<1800: "5m_30m"
    default: "over_30m"
    }
  }
  public func validated(preference: ProductAnalyticsPreference, now: Date = Date())
    -> ProductAnalyticsEvent?
  {
    guard UUID(uuidString: id) != nil, preference.collects,
      preferenceRevision == preference.revision,
      let start = preference.disclosedAt, timestamp >= start,
      timestamp > now.addingTimeInterval(-7 * 86400), timestamp <= now.addingTimeInterval(300)
    else { return nil }
    var value = self
    value.properties = Self.sanitize(properties)
    return value
  }
}
public struct ProductAnalyticsBatch: Codable, Sendable {
  public var events: [ProductAnalyticsEvent]
  public init(events: [ProductAnalyticsEvent]) { self.events = events }
}
public struct ProductAnalyticsAcknowledgement: Codable, Sendable {
  public var acceptedEventIDs: [String]
  public var discardedEventIDs: [String]
  public var preference: ProductAnalyticsPreference
  public init(
    acceptedEventIDs: [String], preference: ProductAnalyticsPreference,
    discardedEventIDs: [String] = []
  ) {
    self.acceptedEventIDs = acceptedEventIDs
    self.preference = preference
    self.discardedEventIDs = discardedEventIDs
  }
}
public struct ProductAnalyticsLogEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String { event.id }
  public var event: ProductAnalyticsEvent
  public var status: String
  public init(event: ProductAnalyticsEvent, status: String) {
    self.event = event
    self.status = status
  }
}
public enum ProductAnalyticsPolicy {
  public static let url = URL(string: "https://wovenmatter.com/privacy")!
  public static let disclosure =
    "Woven Matter shares limited product analytics by default to help improve the app. We record app opens, actions such as creating or editing content and sending messages, app update clicks and outcomes, coarse technical metadata, and approximate country. A random ID belongs to your central library and is shared across its connected devices. We do not collect your notes, messages, files, account identities, or precise location. You can turn analytics off for the whole library in General Settings and inspect the analytics log."
}

extension CompanionWorkspaceAction {
  /// Explicit editor/controller actions only. No request payload is retained.
  public var analyticsProperties: [String: String]? {
    let category: String
    let action: String
    switch self {
    case .note(_, let operation, _, _, _):
      category = "note"
      action = operation
    case .conversation(_, let operation, _, _):
      category = "session"
      action = operation
    case .saveCalendar(_, let revision, _):
      return ["item_category": "calendar", "action": revision == nil ? "create" : "edit"]
    case .deleteCalendar: return ["item_category": "calendar", "action": "delete"]
    default: return nil
    }
    let coarse: String
    switch action {
    case "trash", "delete": coarse = "delete"
    case "restore": coarse = "restore"
    case "move": coarse = "move"
    case "rename", "pin", "unpin": coarse = "edit"
    default: return nil
    }
    return ["item_category": category, "action": coarse]
  }
}

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
    case active = "app_active"
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
  public static let signalInterval: TimeInterval = 6 * 60 * 60
  public var rateLimited: Bool { name == .appOpened || name == .active }
  public var qualifying: Bool {
    name == .active
  }
  /// Re-applied at the central ingestion boundary, including decoded remote input.
  public static func sanitize(_ values: [String: String]) -> [String: String] {
    let enums: [String: Set<String>] = [
      "platform": ["macos", "ios", "ipados"],
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
  public func validated(preference: ProductAnalyticsPreference, now: Date = Date())
    -> ProductAnalyticsEvent?
  {
    guard UUID(uuidString: id) != nil, preference.collects,
      preferenceRevision == preference.revision,
      let start = preference.disclosedAt, timestamp >= start,
      timestamp > now.addingTimeInterval(-60), timestamp <= now.addingTimeInterval(60)
    else { return nil }
    var value = self
    value.properties = Self.sanitize(properties)
    return value
  }
}
public struct ProductAnalyticsBatch: Codable, Sendable {
  public var events: [ProductAnalyticsEvent]
  public var analyticsID: String
  public init(events: [ProductAnalyticsEvent], analyticsID: String) {
    self.events = events
    self.analyticsID = analyticsID
  }
}
public struct ProductAnalyticsAcknowledgement: Codable, Sendable {
  public var acceptedEventIDs: [String]
  public var discardedEventIDs: [String]
  public var preference: ProductAnalyticsPreference
  public var nextSignalAt: [String: Date]
  public init(
    acceptedEventIDs: [String], preference: ProductAnalyticsPreference,
    discardedEventIDs: [String] = [], nextSignalAt: [String: Date] = [:]
  ) {
    self.acceptedEventIDs = acceptedEventIDs
    self.preference = preference
    self.discardedEventIDs = discardedEventIDs
    self.nextSignalAt = nextSignalAt
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
    "Woven Matter shares limited product analytics by default to help improve the app. We send an app-open signal and a generic active-use signal, each at most once every six hours per library, plus app update clicks and outcomes, basic technical metadata, and approximate country. We do not report which content you change or which qualifying action you perform. Offline activity and failed sends are dropped without replay. A random ID belongs to your central library and is shared across its connected devices. We do not collect your notes, messages, files, account identities, or precise location. You can turn analytics off for the whole library in General Settings and inspect the analytics log."
}

extension CompanionWorkspaceAction {
  /// Recognize deliberate actions locally; never serialize their kind or content.
  public var qualifiesForAnalytics: Bool {
    switch self {
    case .note(_, let operation, _, _, _), .conversation(_, let operation, _, _):
      return ["trash", "delete", "restore", "move", "rename", "pin", "unpin"].contains(operation)
    case .saveCalendar, .deleteCalendar: return true
    default: return false
    }
  }
}

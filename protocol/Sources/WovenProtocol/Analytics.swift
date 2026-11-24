import Foundation

// Anonymous usage statistics. A server sends them; the UI only says what
// happened that the server cannot see: the app opening and its updater's steps.

/// What the UI reports. Each is the name of its event in the statistics.
public enum AppEvent: String, Codable, Sendable, Hashable {
  case opened = "app_opened"
  case updateCheckClicked = "update_check_clicked"
  case updateDownloadStarted = "update_download_started"
  case updateDownloadCompleted = "update_download_completed"
  case updateDownloadFailed = "update_download_failed"
  case updateInstallStarted = "update_install_started"
  case updateInstallFailed = "update_install_failed"
  case updateInstallCancelled = "update_install_cancelled"
}

/// Tells this machine's server something the UI saw, for anonymous usage
/// statistics. `targetVersion` is the release an update step is for.
public struct RecordAppEvent: Request {
  public static let method = "analytics.record"
  public typealias Reply = Done
  public var event: AppEvent
  public var targetVersion: String?
  public init(_ event: AppEvent, targetVersion: String? = nil) {
    self.event = event
    self.targetVersion = targetVersion
  }
}

/// The synced settings anonymous usage statistics keep.
public enum AnalyticsSettings {
  /// `false` when the person turned the statistics off; unset means on.
  public static let enabled = "analytics.enabled"
  /// One machine's candidate for the library's anonymous identifier, as
  /// `{"id": …, "created": ms}`. The earliest candidate is the identifier.
  public static let candidatePrefix = "analytics.id."
  /// Where the statistics are described, and who answers questions about them.
  public static let policy = URL(string: "https://wovenmatter.com/privacy")!
  public static let contact = URL(string: "mailto:privacy@wovenmatter.com")!
}

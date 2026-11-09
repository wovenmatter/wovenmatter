import Foundation

/// One Mac's one-time access setup (Settings → General on that Mac), published
/// with its execution workspace so every paired device can explain a session
/// that cannot use something it needs. Transport-agnostic: plain Codable
/// values with no credentials, paths or timestamps, so a status change is the
/// only thing that changes the record.
public struct CompanionMacAccessStatus: Codable, Equatable, Sendable {
  public enum Item: String, Codable, CaseIterable, Sendable {
    case keychain, fullDiskAccess, accessibility, screenRecording, automation, microphone

    public var displayName: String {
      switch self {
      case .keychain: "Keychain access"
      case .fullDiskAccess: "Full Disk Access"
      case .accessibility: "Accessibility"
      case .screenRecording: "Screen Recording"
      case .automation: "Automation"
      case .microphone: "Microphone"
      }
    }
  }

  public enum State: String, Codable, Sendable {
    case ready, needsAttention, unknown
    /// A state added by a newer Mac decodes as unknown instead of failing the record.
    public init(from decoder: any Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
  }

  /// Items every session may need: saved credentials and files in protected folders.
  public static let sessionRequirements: [Item] = [.fullDiskAccess, .keychain]
  /// Items Computer Use needs in addition.
  public static let computerUseRequirements: [Item] = [.accessibility, .screenRecording]

  /// Keys are `Item` raw values; unknown future items decode and are ignored.
  public var items: [String: State]
  /// The app name macOS lists in Privacy & Security, e.g. "Woven Matter".
  public var appName: String

  public init(items: [Item: State] = [:], appName: String = "Woven Matter") {
    self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.key.rawValue, $0.value) })
    self.appName = appName
  }

  public func state(_ item: Item) -> State { items[item.rawValue] ?? .unknown }

  /// Required items known to be missing. Unknown items are not reported, so an
  /// older Mac that never checked does not produce a false warning.
  public func missing(computerUse: Bool = false) -> [Item] {
    (Self.sessionRequirements + (computerUse ? Self.computerUseRequirements : []))
      .filter { state($0) == .needsAttention }
  }

  /// A message for a session that runs on this Mac, shown on whichever device
  /// views the session. Nil when nothing it needs is known to be missing.
  public func sessionNotice(deviceName: String, isThisDevice: Bool, computerUse: Bool = false) -> String? {
    let names = missing(computerUse: computerUse).map(\.displayName)
    guard !names.isEmpty else { return nil }
    let list = names.count <= 2 ? names.joined(separator: " and ")
      : names.dropLast().joined(separator: ", ") + ", and " + names.last!
    let subject = isThisDevice ? "This Mac" : deviceName
    let action = isThisDevice ? "Open Settings → General to set it up." : "Open Settings → General on that Mac."
    return "\(subject) is missing \(list) for \(appName). \(action)"
  }
}

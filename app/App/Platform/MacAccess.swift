import Foundation

/// One Mac's one-time permission setup (Settings → Permissions & Access on that
/// Mac). Each Mac's server reports it, so any machine can explain a session that
/// cannot use something it needs. No credentials, paths or timestamps.
struct MacAccessStatus: Codable, Hashable, Sendable {
    enum Item: String, Codable, CaseIterable, Hashable, Sendable {
        case fullDiskAccess, accessibility, screenRecording, automation, microphone

        var displayName: String {
            switch self {
            case .fullDiskAccess: "Full Disk Access"
            case .accessibility: "Accessibility"
            case .screenRecording: "Screen Recording"
            case .automation: "Automation"
            case .microphone: "Microphone"
            }
        }
    }

    enum State: String, Codable, Hashable, Sendable {
        case ready, needsAttention, unknown
    }

    /// Items every session may need: files in protected folders.
    static let sessionRequirements: [Item] = [.fullDiskAccess]
    /// Items Computer Use needs in addition.
    static let computerUseRequirements: [Item] = [.accessibility, .screenRecording]

    var items: [Item: State]
    /// The app name macOS lists in Privacy & Security, e.g. "Woven Matter".
    var appName: String

    init(items: [Item: State] = [:], appName: String = "Woven Matter") {
        self.items = items
        self.appName = appName
    }

    /// The display name, else the bundle name; blank values are skipped.
    static func appName(displayName: String?, bundleName: String?) -> String {
        [displayName, bundleName].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Woven Matter"
    }

    func state(_ item: Item) -> State { items[item] ?? .unknown }

    /// Required items known to be missing. Unknown items are not reported.
    func missing(computerUse: Bool = false) -> [Item] {
        (Self.sessionRequirements + (computerUse ? Self.computerUseRequirements : []))
            .filter { state($0) == .needsAttention }
    }

    /// A message for a session that runs on this Mac, shown wherever the session
    /// is viewed. Nil when nothing it needs is known to be missing.
    func sessionNotice(deviceName: String, isThisDevice: Bool, computerUse: Bool = false) -> String? {
        let names = missing(computerUse: computerUse).map(\.displayName)
        guard let last = names.last else { return nil }
        let list = names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + ", and " + last
        let subject = isThisDevice ? "This Mac" : deviceName
        let action = isThisDevice ? "Open Settings → Permissions & Access to set it up." : "Open Settings → Permissions & Access on that Mac."
        return "\(subject) is missing \(list) for \(appName). \(action)"
    }
}

import Foundation

public struct RemoteBrowserTab: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public init(id: String, title: String, url: String) { self.id = id; self.title = title; self.url = url }
}

public struct RemoteBrowserTabs: Codable, Equatable, Sendable {
    public let running: Bool
    public let tabs: [RemoteBrowserTab]
    public let profiles: [String]?
    public let profile: String?
    public init(running: Bool, tabs: [RemoteBrowserTab], profiles: [String]? = nil, profile: String? = nil) {
        self.running = running; self.tabs = tabs; self.profiles = profiles; self.profile = profile
    }
}

public struct RemoteBrowserFrame: Codable, Equatable, Sendable {
    public let tabID: String
    public let imageBase64: String
    public let frameID: String?
    public let imageID: String?
    public init(tabID: String, imageBase64: String, frameID: String? = nil, imageID: String? = nil) {
        self.tabID = tabID; self.imageBase64 = imageBase64; self.frameID = frameID; self.imageID = imageID
    }
}

/// An explicit user gesture, bound to the page image the user actually saw.
public struct RemoteBrowserAction: Codable, Equatable, Sendable {
    public var actionID = UUID().uuidString.lowercased()
    public var tabID = ""
    public var frameID = ""
    public var gestureID: String?
    public var kind: String
    public var x: Double?
    public var y: Double?
    public var endX: Double?
    public var endY: Double?
    public var deltaX: Double?
    public var deltaY: Double?
    public var button: String?
    public var clickCount: Int?
    public var modifiers: Int?
    public var key: String?
    public var text: String?
    public init(kind: String) { self.kind = kind }
}

public struct RemoteBrowserActionResult: Codable, Sendable {
    public let tabID: String
    public let accepted: Bool
    public let text: String?
    public init(tabID: String, accepted: Bool, text: String? = nil) { self.tabID = tabID; self.accepted = accepted; self.text = text }
}

public struct RemoteBrowserActionBatchResult: Codable, Sendable {
    public let results: [RemoteBrowserActionResult]
    public init(results: [RemoteBrowserActionResult]) { self.results = results }
}

enum RemoteBrowserError: LocalizedError {
    case invalidImage
    case inputRejected

    var errorDescription: String? {
        switch self {
        case .invalidImage: "The machine returned an invalid browser image."
        case .inputRejected: "The machine did not accept this input."
        }
    }
}

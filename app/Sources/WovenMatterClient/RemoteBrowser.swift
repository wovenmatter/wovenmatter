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
    public init(running: Bool, tabs: [RemoteBrowserTab]) { self.running = running; self.tabs = tabs }
}

public struct RemoteBrowserFrame: Codable, Equatable, Sendable {
    public let tabID: String
    public let imageBase64: String
    public let frameID: String?
    public init(tabID: String, imageBase64: String, frameID: String? = nil) {
        self.tabID = tabID; self.imageBase64 = imageBase64; self.frameID = frameID
    }
}

/// An explicit user gesture, bound to the page image the user actually saw.
public struct RemoteBrowserAction: Codable, Equatable, Sendable {
    public var actionID = UUID().uuidString.lowercased()
    public var tabID = ""
    public var frameID = ""
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

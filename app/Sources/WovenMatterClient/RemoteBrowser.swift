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
    public init(tabID: String, imageBase64: String) { self.tabID = tabID; self.imageBase64 = imageBase64 }
}

import Foundation

/// An OpenAI Responses-compatible model server that Pi Durable on one machine
/// uses. It belongs to that machine and its key stays there; it never syncs.
public struct LocalModelServer: Codable, Sendable, Hashable {
  /// `local-server-<uuid>`, the provider Pi Durable's settings name it by.
  public var id: String
  public var url: String
  public var models: [String]
  /// When the machine last checked it.
  public var verifiedAt: Date

  public init(id: String, url: String, models: [String], verifiedAt: Date) {
    self.id = id
    self.url = url
    self.models = models
    self.verifiedAt = verifiedAt
  }
}

/// The model servers of the machine asked.
public struct ListLocalModelServers: Request {
  public static let method = "localModelServers.list"
  public typealias Reply = [LocalModelServer]
  public init() {}
}

/// Checks a model server from the machine asked and saves it there. With
/// `replacing`, that server is checked again with its URL; an empty key keeps
/// its saved one.
public struct ConnectLocalModelServer: Request {
  public static let method = "localModelServers.connect"
  public typealias Reply = LocalModelServer
  public var url: String
  public var key: String
  public var replacing: String?

  public init(url: String, key: String, replacing: String? = nil) {
    self.url = url
    self.key = key
    self.replacing = replacing
  }
}

/// Removes a model server from the machine asked.
public struct RemoveLocalModelServer: Request {
  public static let method = "localModelServers.remove"
  public typealias Reply = Done
  public var id: String
  public init(id: String) { self.id = id }
}

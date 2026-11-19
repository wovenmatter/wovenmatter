import Foundation

/// A request with a typed reply. Adding one to the protocol is one struct
/// conforming to this and one handler on the server.
public protocol Request: Codable, Sendable {
  associatedtype Reply: Codable, Sendable
  static var method: String { get }
}

/// A request whose reply opens a stream of events, delivered until the client
/// unsubscribes, the connection closes or the server ends it.
public protocol Subscription: Request {
  associatedtype Event: Codable, Sendable
}

/// The reply of a request that answers with nothing but success.
public struct Done: Codable, Sendable, Hashable {
  public init() {}
}

/// What each side says first. The server answers a client's hello with its own.
public struct Hello: Codable, Sendable, Hashable {
  public enum Role: String, Codable, Sendable {
    case ui
    case server
  }

  public var role: Role
  public var machine: Machine
  public var appVersion: String

  public init(role: Role, machine: Machine, appVersion: String) {
    self.role = role
    self.machine = machine
    self.appVersion = appVersion
  }
}

/// Every frame on a connection is one of these, as one JSON text message.
public enum Message: Codable, Sendable {
  case hello(Hello)
  case request(id: String, method: String, params: JSONValue)
  case reply(id: String, result: Result<JSONValue, ProtocolError>)
  case event(subscription: String, data: JSONValue)
  /// The server ended a subscription; `error` says why when it was not asked to.
  case end(subscription: String, error: ProtocolError?)

  private enum Kind: String, CodingKey {
    case hello, request, reply, event, end
  }

  private enum Field: String, CodingKey {
    case id, method, params, result, error, subscription, data
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Kind.self)
    guard let kind = container.allKeys.first, container.allKeys.count == 1 else {
      throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A message has exactly one kind"))
    }
    if kind == .hello {
      self = .hello(try container.decode(Hello.self, forKey: .hello))
      return
    }
    let body = try container.nestedContainer(keyedBy: Field.self, forKey: kind)
    switch kind {
    case .hello:
      fatalError("handled above")
    case .request:
      self = .request(id: try body.decode(String.self, forKey: .id),
                      method: try body.decode(String.self, forKey: .method),
                      params: try body.decodeIfPresent(JSONValue.self, forKey: .params) ?? .object([:]))
    case .reply:
      let id = try body.decode(String.self, forKey: .id)
      if let error = try body.decodeIfPresent(ProtocolError.self, forKey: .error) {
        self = .reply(id: id, result: .failure(error))
      } else {
        self = .reply(id: id, result: .success(try body.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null))
      }
    case .event:
      self = .event(subscription: try body.decode(String.self, forKey: .subscription),
                    data: try body.decode(JSONValue.self, forKey: .data))
    case .end:
      self = .end(subscription: try body.decode(String.self, forKey: .subscription),
                  error: try body.decodeIfPresent(ProtocolError.self, forKey: .error))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Kind.self)
    switch self {
    case .hello(let hello):
      try container.encode(hello, forKey: .hello)
    case .request(let id, let method, let params):
      var body = container.nestedContainer(keyedBy: Field.self, forKey: .request)
      try body.encode(id, forKey: .id)
      try body.encode(method, forKey: .method)
      try body.encode(params, forKey: .params)
    case .reply(let id, let result):
      var body = container.nestedContainer(keyedBy: Field.self, forKey: .reply)
      try body.encode(id, forKey: .id)
      switch result {
      case .success(let value): try body.encode(value, forKey: .result)
      case .failure(let error): try body.encode(error, forKey: .error)
      }
    case .event(let subscription, let data):
      var body = container.nestedContainer(keyedBy: Field.self, forKey: .event)
      try body.encode(subscription, forKey: .subscription)
      try body.encode(data, forKey: .data)
    case .end(let subscription, let error):
      var body = container.nestedContainer(keyedBy: Field.self, forKey: .end)
      try body.encode(subscription, forKey: .subscription)
      try body.encodeIfPresent(error, forKey: .error)
    }
  }

  public func text() throws -> String {
    String(decoding: try Wire.encoder.encode(self), as: UTF8.self)
  }

  public init(text: String) throws {
    self = try Wire.decoder.decode(Message.self, from: Data(text.utf8))
  }
}

/// Why a request failed. `code` is for code to act on; `message` is for people.
public struct ProtocolError: Error, Codable, Sendable, Hashable {
  public struct Code: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
      rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }

    /// The request could not be read.
    public static let badRequest = Code(rawValue: "badRequest")
    /// No such method on this server.
    public static let unknownMethod = Code(rawValue: "unknownMethod")
    /// The thing named does not exist (or was deleted).
    public static let notFound = Code(rawValue: "notFound")
    /// It runs on another machine; ask that machine's server. `machineID` names it.
    public static let notOwner = Code(rawValue: "notOwner")
    /// The owning machine could not be reached.
    public static let ownerUnreachable = Code(rawValue: "ownerUnreachable")
    /// The two machines run different app releases. `machineID` names the other one.
    public static let versionMismatch = Code(rawValue: "versionMismatch")
    /// The caller is not a machine of this tailnet.
    public static let refused = Code(rawValue: "refused")
    /// The runtime no longer has the native session behind this chat.
    public static let nativeSessionGone = Code(rawValue: "nativeSessionGone")
    /// A turn is already running.
    public static let busy = Code(rawValue: "busy")
    /// Anything else that went wrong on the server.
    public static let failed = Code(rawValue: "failed")
  }

  public var code: Code
  public var message: String
  /// The machine the error points at, for `notOwner` and `versionMismatch`.
  public var machineID: String?

  public init(_ code: Code, _ message: String, machineID: String? = nil) {
    self.code = code
    self.message = message
    self.machineID = machineID
  }
}

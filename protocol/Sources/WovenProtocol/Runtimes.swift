import Foundation

// The runtimes on one machine and the sign-ins they use. Each request is
// answered by the server of the machine asked, about that machine only.

/// One runtime on the machine asked.
public struct RuntimeStatus: Codable, Sendable, Hashable {
  public var runtime: RuntimeKind
  public var name: String
  /// Everything the runtime needs is here (its CLI and, where it has one, its adapter).
  public var installed: Bool
  /// The CLI's or SDK's version, as it reports it.
  public var version: String?
  /// Whether the CLI reports a sign-in; nil when the runtime has no sign-in
  /// of its own (Pi Durable's are listed by `ListSignIns`) or it could not tell.
  public var signedIn: Bool?
  /// What is missing or what went wrong, for people.
  public var detail: String?

  public init(runtime: RuntimeKind, name: String, installed: Bool, version: String? = nil, signedIn: Bool? = nil,
              detail: String? = nil) {
    self.runtime = runtime
    self.name = name
    self.installed = installed
    self.version = version
    self.signedIn = signedIn
    self.detail = detail
  }
}

/// Every runtime this server knows, with what is installed and signed in here.
public struct ListRuntimes: Request {
  public static let method = "runtimes.list"
  public typealias Reply = [RuntimeStatus]
  public init() {}
}

/// Installs a runtime, or updates it to the latest release: its CLI with the
/// vendor's installer or updater, its adapter, or Pi Durable's SDK. Replies
/// once it is done, with the runtime's status after.
public struct InstallRuntime: Request {
  public static let method = "runtimes.install"
  public typealias Reply = RuntimeStatus
  public var runtime: RuntimeKind
  public init(runtime: RuntimeKind) { self.runtime = runtime }
}

/// One way Pi Durable reaches a model provider, on the machine asked.
public struct SignIn: Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable, Hashable {
    /// A subscription (ChatGPT, Claude, Grok). Kept on this machine only.
    case subscription
    /// An API key. Synced, sealed separately for each machine.
    case apiKey
  }

  public var provider: String
  public var name: String
  public var kind: Kind
  public var connected: Bool

  public init(provider: String, name: String, kind: Kind, connected: Bool) {
    self.provider = provider
    self.name = name
    self.kind = kind
    self.connected = connected
  }
}

public struct ListSignIns: Request {
  public static let method = "signIns.list"
  public typealias Reply = [SignIn]
  public init() {}
}

/// What a sign-in flow shows the person while it runs.
public enum SignInEvent: Codable, Sendable, Hashable {
  /// Open this address; `code` is what to enter there, when there is one.
  case open(url: String, code: String?, instructions: String?)
  /// The flow needs text from the person (`AnswerSignIn`).
  case prompt(id: String, message: String)
  case finished(SignIn)
  case failed(message: String)

  private enum Key: String, CodingKey { case type, url, code, instructions, id, message, signIn }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(String.self, forKey: .type) {
    case "open":
      self = .open(url: try container.decode(String.self, forKey: .url),
                   code: try container.decodeIfPresent(String.self, forKey: .code),
                   instructions: try container.decodeIfPresent(String.self, forKey: .instructions))
    case "prompt":
      self = .prompt(id: try container.decode(String.self, forKey: .id), message: try container.decode(String.self, forKey: .message))
    case "finished": self = .finished(try container.decode(SignIn.self, forKey: .signIn))
    case "failed": self = .failed(message: try container.decode(String.self, forKey: .message))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown sign-in event \(other)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .open(let url, let code, let instructions):
      try container.encode("open", forKey: .type)
      try container.encode(url, forKey: .url)
      try container.encodeIfPresent(code, forKey: .code)
      try container.encodeIfPresent(instructions, forKey: .instructions)
    case .prompt(let id, let message):
      try container.encode("prompt", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(message, forKey: .message)
    case .finished(let signIn):
      try container.encode("finished", forKey: .type)
      try container.encode(signIn, forKey: .signIn)
    case .failed(let message):
      try container.encode("failed", forKey: .type)
      try container.encode(message, forKey: .message)
    }
  }
}

/// Runs a subscription's sign-in flow on the machine asked. The reply is the
/// flow's identifier (for `AnswerSignIn`); events follow until it finishes
/// or fails. Unsubscribing cancels it.
public struct StartSignIn: Subscription {
  public static let method = "signIns.start"
  public typealias Reply = String
  public typealias Event = SignInEvent
  public var provider: String
  public init(provider: String) { self.provider = provider }
}

public struct AnswerSignIn: Request {
  public static let method = "signIns.answer"
  public typealias Reply = Done
  public var flowID: String
  public var promptID: String
  public var answer: String
  public init(flowID: String, promptID: String, answer: String) {
    self.flowID = flowID
    self.promptID = promptID
    self.answer = answer
  }
}

/// Sets an API key for every machine, sealed separately for each with that
/// machine's public key; nil removes it everywhere.
public struct SetAPIKey: Request {
  public static let method = "signIns.setKey"
  public typealias Reply = Done
  public var provider: String
  public var key: String?
  public init(provider: String, key: String?) {
    self.provider = provider
    self.key = key
  }
}

/// Removes a subscription's sign-in from the machine asked.
public struct SignOut: Request {
  public static let method = "signIns.signOut"
  public typealias Reply = Done
  public var provider: String
  public init(provider: String) { self.provider = provider }
}

import Foundation

// The runtimes on one machine and the sign-ins they use. Each request is
// answered by the server of the machine asked, about that machine only.

/// One runtime on the machine asked.
public struct RuntimeStatus: Codable, Sendable, Hashable {
  public var runtime: RuntimeKind
  public var name: String
  /// Its CLI or SDK is here.
  public var installed: Bool
  /// Whether its ACP adapter is here; nil for a runtime without one.
  public var adapterInstalled: Bool?
  /// The server is installing its adapter now.
  public var installingAdapter: Bool
  /// The CLI's or SDK's version number, as it reports it.
  public var version: String?
  /// Whether the CLI reports a sign-in; nil when the runtime has no sign-in
  /// of its own (Pi Durable's are listed by `ListSignIns`) or it could not tell.
  public var signedIn: Bool?
  /// The accounts the CLI reports, when it names them.
  public var accounts: [RuntimeAccount]
  /// What is missing or what went wrong, for people.
  public var detail: String?
  /// The newest release, when the request asked for it and it could be found.
  public var latestVersion: String?

  public init(runtime: RuntimeKind, name: String, installed: Bool, adapterInstalled: Bool? = nil,
              installingAdapter: Bool = false, version: String? = nil, signedIn: Bool? = nil,
              accounts: [RuntimeAccount] = [], detail: String? = nil, latestVersion: String? = nil) {
    self.runtime = runtime
    self.name = name
    self.installed = installed
    self.adapterInstalled = adapterInstalled
    self.installingAdapter = installingAdapter
    self.version = version
    self.signedIn = signedIn
    self.accounts = accounts
    self.detail = detail
    self.latestVersion = latestVersion
  }

  /// A session can start with it: the CLI and, where it has one, the adapter are here.
  public var isReady: Bool { installed && adapterInstalled != false }
}

/// One account a harness CLI is signed in with.
public struct RuntimeAccount: Codable, Sendable, Hashable {
  /// How it signs in ("API key", "OAuth", "Claude subscription").
  public var method: String
  public var name: String?
  /// What `SignOut` names to remove this account alone (OpenCode keeps several);
  /// nil when signing out removes the CLI's one sign-in.
  public var credential: String?

  public init(method: String, name: String?, credential: String? = nil) {
    self.method = method
    self.name = name
    self.credential = credential
  }
}

extension RuntimeStatus {
  /// A newer release than the installed one is published.
  public var updateAvailable: Bool {
    guard installed, let version, let latestVersion else { return false }
    return Self.isNewer(latestVersion, than: version)
  }

  /// Compares dotted version numbers part by part; text after a part's digits is ignored.
  public static func isNewer(_ candidate: String, than current: String) -> Bool {
    func parts(_ text: String) -> [Int] {
      text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    let a = parts(candidate), b = parts(current)
    for index in 0..<max(a.count, b.count) {
      let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
      if x != y { return x > y }
    }
    return false
  }
}

/// Every runtime this server knows, with what is installed and signed in here.
/// `checkForUpdates` also looks up each one's newest release.
public struct ListRuntimes: Request {
  public static let method = "runtimes.list"
  public typealias Reply = [RuntimeStatus]
  public var checkForUpdates: Bool
  public init(checkForUpdates: Bool = false) { self.checkForUpdates = checkForUpdates }
}

/// The options a runtime last reported on the machine asked (its models,
/// thinking levels and permission modes), or nil before it has run there
/// since the server started.
public struct GetRuntimeConfiguration: Request {
  public static let method = "runtimes.configuration"
  public typealias Reply = SessionConfiguration?
  public var runtime: RuntimeKind
  public init(runtime: RuntimeKind) { self.runtime = runtime }
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

/// Runs a sign-in flow on the machine asked: a Pi Durable subscription's
/// (`provider`), or a harness CLI's own sign-in (`runtime`, with the catalog's
/// `signInMethod` and, for a key method, the `key`). The reply is the flow's
/// identifier (for `AnswerSignIn`); events follow until it finishes or fails.
/// Unsubscribing cancels it.
public struct StartSignIn: Subscription {
  public static let method = "signIns.start"
  public typealias Reply = String
  public typealias Event = SignInEvent
  public var provider: String
  public var runtime: RuntimeKind?
  public var signInMethod: String?
  public var key: String?
  public init(provider: String) { self.provider = provider }
  public init(runtime: RuntimeKind, signInMethod: String, key: String? = nil) {
    self.provider = runtime.rawValue
    self.runtime = runtime
    self.signInMethod = signInMethod
    self.key = key
  }
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

/// One model Pi Durable can use, from its provider's catalog.
public struct ProviderModel: Codable, Sendable, Hashable {
  /// `provider/model`, as Pi Durable's settings name it.
  public var id: String
  public var name: String
  public var provider: String
  public var providerName: String

  public init(id: String, name: String, provider: String, providerName: String) {
    self.id = id
    self.name = name
    self.provider = provider
    self.providerName = providerName
  }
}

/// The models of every provider Pi Durable is connected to on the machine
/// asked. `refresh` fetches the providers' catalogs again first.
public struct ListProviderModels: Request {
  public static let method = "signIns.models"
  public typealias Reply = [ProviderModel]
  public var refresh: Bool
  public init(refresh: Bool = false) { self.refresh = refresh }
}

/// Removes a subscription's sign-in from the machine asked, or signs a harness
/// CLI out there (`runtime`; `credential` removes one OpenCode account).
public struct SignOut: Request {
  public static let method = "signIns.signOut"
  public typealias Reply = Done
  public var provider: String
  public var runtime: RuntimeKind?
  public var credential: String?
  public init(provider: String) { self.provider = provider }
  public init(runtime: RuntimeKind, credential: String? = nil) {
    self.provider = runtime.rawValue
    self.runtime = runtime
    self.credential = credential
  }
}

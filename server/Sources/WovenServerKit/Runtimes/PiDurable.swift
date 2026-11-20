import Foundation
import Synchronization
import WovenProtocol

/// Where Pi Durable's credentials come from: the server's own secrets. Set
/// once the server has opened them.
final class PiCredentialSource: Sendable {
  private let secrets = Mutex<Secrets?>(nil)

  func attach(_ secrets: Secrets) { self.secrets.withLock { $0 = secrets } }
  var current: Secrets? { secrets.withLock { $0 } }
}

/// Pi Durable: `default-agent/` run with Node as one child process per
/// session, spoken to over ACP like the other harnesses. Its SDK keeps its
/// stock SQLite storage in `pi-durable/pi-durable.sqlite` under the data
/// folder, a file of its own; it is never given the library.
public final class PiDurableRuntime: Runtime {
  public var kind: RuntimeKind { .piDurable }
  /// The subscriptions Pi Durable signs in to, whose credentials stay on this machine.
  static let subscriptions = ["openai-codex", "claude-subscription", "xai"]

  let data: URL
  let credentials = PiCredentialSource()
  private let logs: URL
  /// `default-agent/`; a test gives a stand-in.
  private let agent: URL

  public init(dataFolder: URL) {
    data = dataFolder.appendingPathComponent("pi-durable", isDirectory: true)
    logs = dataFolder.appendingPathComponent("logs", isDirectory: true)
    agent = Resources.defaultAgent
  }

  init(dataFolder: URL, agent: URL) {
    data = dataFolder.appendingPathComponent("pi-durable", isDirectory: true)
    logs = dataFolder.appendingPathComponent("logs", isDirectory: true)
    self.agent = agent
  }

  private var entry: URL { agent.appendingPathComponent("src/main.mjs") }
  private var environment: [String: String] { ["WOVEN_PI_DATA": data.path] }

  public func open(_ start: RuntimeStart) async throws -> any RuntimeSession {
    guard let node = Resources.node else { throw RuntimeError.failed("Pi Durable needs Node, which is not on this machine.") }
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let credentials = credentials
    let profile = ACPProfile(
      kind: .piDurable, executable: node, arguments: [entry.path], environment: environment,
      handleRequest: { method, _ in
        let secrets = credentials.current
        switch method {
        case "woven/credentials":
          return .object(["credentials": await secrets?.piCredentials(subscriptions: Self.subscriptions) ?? .object([:])])
        case "woven/settings":
          return .object(["settings": await secrets?.piSettings() ?? .object([:])])
        default:
          throw RuntimeError.failed("Woven Matter does not offer \(method).")
        }
      },
      handleNotification: { method, params in
        // A subscription the SDK renewed: keep the new credential.
        guard method == "woven/credentials/update", let provider = params["provider"]?.string,
              Self.subscriptions.contains(provider), let credential = params["credential"] else { return }
        try? await credentials.current?.setSubscription(provider, credential)
      },
      ownTurnsEndQuietly: true, logFile: logs.appendingPathComponent("piDurable-\(start.sessionID).log"), tools: start.tools)
    return try await ACPSession.open(profile: profile, start: start)
  }

  public func status() async -> RuntimeStatus {
    let name = "Pi Durable"
    guard Resources.node != nil else { return RuntimeStatus(runtime: kind, name: name, installed: false, detail: "Node is not installed.") }
    // An SDK update installed with `update-sdk` is what new sessions load.
    let package = "node_modules/@earendil-works/pi-durable/package.json"
    let manifests = [data.appendingPathComponent("sdk/current").appendingPathComponent(package),
                     agent.appendingPathComponent(package)]
    guard let version = manifests.lazy.compactMap({ try? Data(contentsOf: $0) })
            .compactMap({ (try? JSONDecoder().decode([String: JSONValue].self, from: $0))?["version"]?.string }).first else {
      return RuntimeStatus(runtime: kind, name: name, installed: false, detail: "Its SDK is not installed.")
    }
    let signIns = await self.signIns()
    return RuntimeStatus(runtime: kind, name: name, installed: true, version: version,
                         signedIn: signIns.map { $0.contains { $0.connected } })
  }

  /// Installs Pi Durable's packages when they are missing, or the latest SDK
  /// for new sessions when they are there.
  public func install() async throws {
    let modules = agent.appendingPathComponent("node_modules")
    if !FileManager.default.fileExists(atPath: modules.path) {
      guard let npm = ChildProcess.find("npm") else { throw RuntimeError.failed("Installing Pi Durable needs npm.") }
      let result = await ChildProcess.run(npm, ["ci", "--omit=dev", "--no-audit", "--no-fund"],
                                          directory: agent.path, timeout: .seconds(900))
      guard result.status == 0 else { throw RuntimeError.failed("npm ci failed: \(result.output.suffix(2000))") }
      return
    }
    _ = try await control(.object(["action": .string("update-sdk")]), events: { _ in }, answers: nil)
  }

  // MARK: Sign-ins

  /// Every provider Pi Durable reaches, with whether this machine is connected.
  func signIns() async -> [SignIn]? {
    guard let result = try? await control(.object(["action": .string("providers")]), events: { _ in }, answers: nil),
          let providers = result["providers"]?.array else { return nil }
    let secrets = credentials.current
    let keys = (try? await secrets?.apiKeys()) ?? [:]
    var list: [SignIn] = []
    for provider in providers {
      guard let id = provider["id"]?.string else { continue }
      let kind: SignIn.Kind = provider["kind"]?.string == "subscription" ? .subscription : .apiKey
      let connected = kind == .apiKey ? keys[id] != nil : ((try? await secrets?.subscription(id)) ?? nil) != nil
      list.append(SignIn(provider: id, name: provider["name"]?.string ?? id, kind: kind, connected: connected))
    }
    return list
  }

  /// The models of every provider and model server this machine's credentials reach.
  func models(refresh: Bool) async throws -> [ProviderModel] {
    let secrets = credentials.current
    let credentials = await secrets?.piCredentials(subscriptions: Self.subscriptions) ?? .object([:])
    let servers = await secrets?.piLocalServers() ?? .array([])
    let result = try await control(.object(["action": .string("models"), "credentials": credentials, "refresh": .bool(refresh),
                                            "localServers": servers]),
                                   events: { _ in }, answers: nil)
    return try (result["models"] ?? .array([])).decode([ProviderModel].self)
  }

  /// Runs one control request (`node main.mjs --control`): its events go to
  /// `events`, prompts are answered from `answers`, and its result is returned.
  func control(_ request: JSONValue, events: @escaping @Sendable (JSONValue) async -> Void,
               answers: AsyncStream<(id: String, answer: String)>?) async throws -> JSONValue {
    guard let node = Resources.node else { throw RuntimeError.failed("Pi Durable needs Node, which is not on this machine.") }
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    let child = try ChildProcess(executable: node, arguments: [entry.path, "--control"], directory: data.path,
                                 environment: environment)
    child.send(String(decoding: try Wire.encoder.encode(request), as: UTF8.self))
    let answering = answers.map { answers in
      Task {
        for await (id, answer) in answers {
          if let line = try? Wire.encoder.encode(JSONValue.object(["answerTo": .string(id), "answer": .string(answer)])) {
            child.send(String(decoding: line, as: UTF8.self))
          }
        }
      }
    }
    defer { answering?.cancel() }
    do {
      for await line in child.lines {
        guard let message = try? Wire.decoder.decode(JSONValue.self, from: Data(line.utf8)) else { continue }
        if let event = message["event"] {
          await events(event)
        } else if let result = message["result"] {
          await child.stop()
          return result
        } else if let error = message["error"]?.string {
          await child.stop()
          throw RuntimeError.failed(error)
        }
      }
    }
    await child.stop()
    throw RuntimeError.failed("Pi Durable ended without an answer.")
  }
}

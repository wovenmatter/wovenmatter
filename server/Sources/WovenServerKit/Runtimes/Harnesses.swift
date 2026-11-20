import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WovenProtocol

/// Where the server finds what ships beside it: `harnesses/` (the catalog and
/// the adapter installer) and `default-agent/` (Pi Durable). The app points
/// `WOVEN_RESOURCES` at its bundled copy; a development build uses the
/// source tree it was built from.
public enum Resources {
  public static var root: URL {
    if let path = ProcessInfo.processInfo.environment["WOVEN_RESOURCES"] { return URL(fileURLWithPath: path, isDirectory: true) }
    // server/Sources/WovenServerKit/Runtimes/Harnesses.swift → the repository.
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }
    return url
  }

  static var harnesses: URL { root.appendingPathComponent("harnesses", isDirectory: true) }
  static var defaultAgent: URL { root.appendingPathComponent("default-agent", isDirectory: true) }

  /// Node for the adapters and Pi Durable: `WOVEN_NODE`, else the one on the path.
  static var node: String? { ProcessInfo.processInfo.environment["WOVEN_NODE"] ?? ChildProcess.find("node") }

  /// The npm that ships beside the server, run with `node`: the Mac app's in
  /// `default-agent/lib/npm`, a Linux release's in its Node. Nil without either.
  static var npm: [String]? {
    guard let node else { return nil }
    let scripts = [defaultAgent.appendingPathComponent("lib/npm/bin/npm-cli.js"),
                   root.appendingPathComponent("node/lib/node_modules/npm/bin/npm-cli.js")]
    return scripts.first { FileManager.default.fileExists(atPath: $0.path) }.map { [node, $0.path] }
  }
}

/// One harness as `harnesses/catalog.json` describes it: the one description
/// of the harnesses.
struct Harness: Decodable, Sendable {
  struct Install: Decodable, Sendable {
    var command: String
  }

  struct Authentication: Decodable, Sendable {
    struct Method: Decodable, Sendable {
      var id: String
      var command: String
      var acceptsInput: Bool?
      var inputSecret: Bool?
    }

    var statusCommands: [String]
    var signOutCommand: String?
    var methods: [Method]?
  }

  struct Mode: Decodable, Sendable {
    var id: String
    var name: String
  }

  var id: String
  var runtime: String
  var displayName: String
  var command: String
  var arguments: [String]
  var cliCommand: String?
  var adapterPackage: String?
  /// The npm package whose published version is the newest release.
  var latestPackage: String?
  var install: Install?
  var update: Install?
  var authentication: Authentication?
  var permissionModes: [Mode]?
  var defaultPermission: String?

  static func catalog() -> [Harness] {
    struct File: Decodable { var harnesses: [Harness] }
    guard let data = try? Data(contentsOf: Resources.harnesses.appendingPathComponent("catalog.json")),
          let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
    return file.harnesses
  }

  static func named(_ runtime: RuntimeKind) -> Harness? {
    catalog().first { $0.runtime == runtime.rawValue }
  }
}

/// The runtimes this machine offers: Codex, Claude Code and Grok Build over
/// ACP, OpenCode over its HTTP API, and Pi Durable as a Node child process.
/// Adapters, Pi Durable's data and runtime logs live under `dataFolder`.
public func standardRuntimes(dataFolder: URL) -> [any Runtime] {
  [
    acpHarness(.codex, dataFolder: dataFolder, cliVariable: "CODEX_PATH") { error in
      error.code == ACPError.notFound || (error.code == -32603 && error.message.localizedCaseInsensitiveContains("no rollout found"))
    },
    acpHarness(.claudeCode, dataFolder: dataFolder, cliVariable: "CLAUDE_CODE_EXECUTABLE") { $0.code == ACPError.notFound },
    grokBuild(dataFolder: dataFolder),
    OpenCodeRuntime(dataFolder: dataFolder),
    PiDurableRuntime(dataFolder: dataFolder),
  ]
}

private func logFile(_ dataFolder: URL, _ kind: RuntimeKind, _ sessionID: String) -> URL {
  let folder = dataFolder.appendingPathComponent("logs", isDirectory: true)
  try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  return folder.appendingPathComponent("\(kind.rawValue)-\(sessionID).log")
}

/// A harness whose ACP adapter (installed under the data folder) drives the
/// person's own CLI. The server installs the adapter itself, with the npm that
/// ships beside it, as soon as it sees the CLI without one, and a session that
/// starts meanwhile waits for it. Installing an adapter never touches the CLI.
func acpHarness(_ kind: RuntimeKind, dataFolder: URL, cliVariable: String, npm: [String]? = Resources.npm,
                findCLI: @escaping @Sendable (String) -> String? = { ChildProcess.find($0) },
                missing: @escaping @Sendable (ACPError) -> Bool) -> ACPRuntime {
  let prefix = dataFolder.appendingPathComponent("harnesses", isDirectory: true)
  let harness = Harness.named(kind)
  let name = harness?.displayName ?? kind.rawValue
  let adapter = prefix.appendingPathComponent("bin").appendingPathComponent(harness?.command ?? "")
  let key = adapter.path
  @Sendable func cli() -> String? { harness?.cliCommand.flatMap(findCLI) }
  @Sendable func hasAdapter() -> Bool { FileManager.default.isExecutableFile(atPath: adapter.path) }
  @Sendable func installTask(_ cli: String) async -> Task<Void, any Error> {
    await AdapterInstalls.shared.start(key) {
      guard let package = harness?.adapterPackage else { throw RuntimeError.failed("\(name) has no adapter in the harness catalog.") }
      try await installAdapter(package, prefix: prefix, cli: cli, npm: npm)
    }
  }
  return ACPRuntime(kind: kind, profile: { start in
    guard let harness, let cli = cli() else {
      throw RuntimeError.failed("\(name) is not installed on this machine.")
    }
    if !hasAdapter() { try await installTask(cli).value }
    return ACPProfile(kind: kind, executable: adapter.path, arguments: harness.arguments, environment: [cliVariable: cli],
                      isMissingSession: missing, logFile: logFile(dataFolder, kind, start.sessionID), tools: start.tools)
  }, statusCheck: {
    guard let harness else { return RuntimeStatus(runtime: kind, name: name, installed: false, detail: "Not in the harness catalog.") }
    let cli = cli()
    var installing = false, failure: String?
    if let cli, !hasAdapter() {
      failure = await AdapterInstalls.shared.failure(key)
      if failure == nil { _ = await installTask(cli) }
      installing = await AdapterInstalls.shared.isRunning(key)
    }
    let adapterHere = hasAdapter()
    var status = await cliStatus(kind, harness, cli: cli,
                                 missing: cli == nil ? "\(harness.cliCommand ?? harness.command) is not installed."
                                   : adapterHere || installing ? nil : failure ?? "Its ACP adapter is not installed.")
    status.adapterInstalled = adapterHere
    status.installingAdapter = installing && !adapterHere
    return status
  }, installer: {
    guard let harness else { throw RuntimeError.failed("\(name) is not in the harness catalog.") }
    // The CLI is installed when it is missing and updated only when everything
    // is here already (the person asked for an update); a missing adapter is
    // installed alone.
    if cli() == nil || hasAdapter() { try await installCLI(harness) }
    guard let cli = cli() else { throw RuntimeError.failed("\(name) is not installed on this machine.") }
    await AdapterInstalls.shared.forget(key)
    try await installTask(cli).value
  })
}

/// Adapter installs in progress, and the last one that failed, by adapter path.
/// A failed install is not retried by itself; `InstallRuntime` or a new
/// session tries again.
actor AdapterInstalls {
  static let shared = AdapterInstalls()
  private var running: [String: Task<Void, any Error>] = [:]
  private var failures: [String: String] = [:]

  func isRunning(_ key: String) -> Bool { running[key] != nil }
  func failure(_ key: String) -> String? { failures[key] }
  func forget(_ key: String) { failures[key] = nil }

  /// The install running for `key`, or a new one running `body`.
  func start(_ key: String, _ body: @escaping @Sendable () async throws -> Void) -> Task<Void, any Error> {
    if let task = running[key] { return task }
    failures[key] = nil
    let task = Task {
      do {
        try await body()
        self.finish(key, nil)
      } catch {
        self.finish(key, "\(error)")
        throw error
      }
    }
    running[key] = task
    return task
  }

  private func finish(_ key: String, _ failure: String?) {
    running[key] = nil
    failures[key] = failure
  }
}

private func grokBuild(dataFolder: URL) -> ACPRuntime {
  let kind = RuntimeKind.grokBuild
  let harness = Harness.named(kind)
  let name = harness?.displayName ?? "Grok Build"
  let modes = (harness?.permissionModes ?? []).map { SessionOption(id: $0.id, name: $0.name) }
  return ACPRuntime(kind: kind, profile: { start in
    guard let harness, let grok = ChildProcess.find(harness.command) else {
      throw RuntimeError.failed("\(name) is not installed on this machine.")
    }
    // Grok takes its permission mode as a launch flag.
    let permission = start.choices.permission.flatMap { choice in modes.contains { $0.id == choice } ? choice : nil }
      ?? harness.defaultPermission ?? "auto"
    return ACPProfile(kind: kind, executable: grok, arguments: ["--permission-mode", permission] + harness.arguments,
                      environment: [:], launchPermissions: modes, logFile: logFile(dataFolder, kind, start.sessionID),
                      tools: start.tools)
  }, statusCheck: {
    guard let harness else { return RuntimeStatus(runtime: kind, name: name, installed: false, detail: "Not in the harness catalog.") }
    let cli = ChildProcess.find(harness.command)
    return await cliStatus(kind, harness, cli: cli, missing: cli == nil ? "grok is not installed." : nil)
  }, installer: {
    guard let harness else { throw RuntimeError.failed("\(name) is not in the harness catalog.") }
    try await installCLI(harness)
  })
}

/// What the CLI reports about itself: its version and whether it is signed in.
private func cliStatus(_ kind: RuntimeKind, _ harness: Harness, cli: String?, missing: String?) async -> RuntimeStatus {
  guard let cli else { return RuntimeStatus(runtime: kind, name: harness.displayName, installed: false, detail: missing) }
  let version = await ChildProcess.run(cli, ["--version"], timeout: .seconds(20))
  var signedIn: Bool?
  var accounts: [RuntimeAccount] = []
  if let commands = harness.authentication?.statusCommands, !commands.isEmpty {
    var all = true
    for command in commands {
      let result = await harnessShell(command, cli: cli, timeout: .seconds(30))
      if result.status != 0 { all = false }
      accounts += reportedAccounts(kind, result.output)
    }
    signedIn = all
  }
  return RuntimeStatus(runtime: kind, name: harness.displayName, installed: true,
                       version: version.status == 0 ? versionNumber(version.output) : nil,
                       signedIn: signedIn, accounts: signedIn == true ? accounts : [], detail: missing)
}

/// The version number in what a `--version` prints ("codex-cli 0.170.0" → "0.170.0").
func versionNumber(_ text: String) -> String? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let range = trimmed.range(of: #"[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else {
    return trimmed.isEmpty ? nil : trimmed
  }
  return String(trimmed[range])
}

/// The newest published release of a runtime, from the npm registry.
func latestRelease(_ kind: RuntimeKind) async -> String? {
  guard let package = Harness.named(kind)?.latestPackage,
        let url = URL(string: "https://registry.npmjs.org/\(package)/latest") else { return nil }
  let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
  guard let (data, response) = try? await URLSession.shared.data(for: request),
        (response as? HTTPURLResponse)?.statusCode == 200,
        let version = (try? JSONDecoder().decode([String: JSONValue].self, from: data))?["version"]?.string else { return nil }
  return version
}

/// Installs the CLI with the vendor's installer when it is missing, or runs
/// its updater when it is there. Always the latest release.
private func installCLI(_ harness: Harness) async throws {
  let present = (harness.cliCommand ?? harness.command).isEmpty ? false
    : ChildProcess.find(harness.cliCommand ?? harness.command) != nil
  guard let command = present ? harness.update?.command : harness.install?.command else { return }
  let result = await ChildProcess.shell(command, timeout: .seconds(600))
  guard result.status == 0 else {
    throw RuntimeError.failed("\(command) failed: \(result.output.suffix(2000))")
  }
}

/// Installs the latest release of an ACP adapter into `prefix`, verified,
/// with `harnesses/install-adapter.mjs` and the npm that ships beside the server.
private func installAdapter(_ package: String, prefix: URL, cli: String, npm: [String]?) async throws {
  guard let node = Resources.node, let npm, let first = npm.first else {
    throw RuntimeError.failed("Installing an adapter needs the Node and npm that ship with Woven Matter.")
  }
  let latest = await ChildProcess.run(first, Array(npm.dropFirst()) + ["view", package, "version"], mergeErrors: false,
                                      timeout: .seconds(60))
  let version = latest.output.trimmingCharacters(in: .whitespacesAndNewlines)
  guard latest.status == 0, !version.isEmpty else {
    throw RuntimeError.failed("npm could not find \(package): \(latest.output + latest.errors)")
  }
  let selection: JSONValue = .object(["prefix": .string(prefix.path), "adapter": .string(package), "adapterVersion": .string(version),
                                      "npm": .array(npm.map { .string($0) }), "cli": .string(cli)])
  let text = String(decoding: try Wire.encoder.encode(selection), as: UTF8.self)
  let result = await ChildProcess.run(node, [Resources.harnesses.appendingPathComponent("install-adapter.mjs").path, text],
                                      timeout: .seconds(600))
  guard result.status == 0 else { throw RuntimeError.failed("Installing \(package) failed: \(result.output.suffix(2000))") }
}

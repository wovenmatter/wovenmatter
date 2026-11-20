import Foundation
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
}

/// One harness as `harnesses/catalog.json` describes it: the one description
/// of the harnesses.
struct Harness: Decodable, Sendable {
  struct Install: Decodable, Sendable {
    var command: String
  }

  struct Authentication: Decodable, Sendable {
    var statusCommands: [String]
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
/// person's own CLI.
private func acpHarness(_ kind: RuntimeKind, dataFolder: URL, cliVariable: String,
                        missing: @escaping @Sendable (ACPError) -> Bool) -> ACPRuntime {
  let prefix = dataFolder.appendingPathComponent("harnesses", isDirectory: true)
  let harness = Harness.named(kind)
  let name = harness?.displayName ?? kind.rawValue
  let adapter = prefix.appendingPathComponent("bin").appendingPathComponent(harness?.command ?? "")
  return ACPRuntime(kind: kind, profile: { start in
    guard let harness, let cli = harness.cliCommand.flatMap({ ChildProcess.find($0) }) else {
      throw RuntimeError.failed("\(name) is not installed on this machine.")
    }
    guard FileManager.default.isExecutableFile(atPath: adapter.path) else {
      throw RuntimeError.failed("\(name)'s adapter is not installed on this machine.")
    }
    return ACPProfile(kind: kind, executable: adapter.path, arguments: harness.arguments, environment: [cliVariable: cli],
                      isMissingSession: missing, logFile: logFile(dataFolder, kind, start.sessionID))
  }, statusCheck: {
    guard let harness else { return RuntimeStatus(runtime: kind, name: name, installed: false, detail: "Not in the harness catalog.") }
    let cli = harness.cliCommand.flatMap { ChildProcess.find($0) }
    let hasAdapter = FileManager.default.isExecutableFile(atPath: adapter.path)
    return await cliStatus(kind, harness, cli: cli,
                           missing: cli == nil ? "\(harness.cliCommand ?? harness.command) is not installed."
                             : hasAdapter ? nil : "Its ACP adapter is not installed.")
  }, installer: {
    guard let harness else { throw RuntimeError.failed("\(name) is not in the harness catalog.") }
    try await installCLI(harness)
    guard let package = harness.adapterPackage, let cli = harness.cliCommand.flatMap({ ChildProcess.find($0) }) else { return }
    try await installAdapter(package, prefix: prefix, cli: cli)
  })
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
                      environment: [:], launchPermissions: modes, logFile: logFile(dataFolder, kind, start.sessionID))
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
  if let commands = harness.authentication?.statusCommands, !commands.isEmpty {
    var all = true
    for command in commands where await ChildProcess.shell(command, timeout: .seconds(30)).status != 0 { all = false }
    signedIn = all
  }
  return RuntimeStatus(runtime: kind, name: harness.displayName, installed: missing == nil,
                       version: version.status == 0 ? version.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                       signedIn: signedIn, detail: missing)
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
/// with `harnesses/install-adapter.mjs`.
private func installAdapter(_ package: String, prefix: URL, cli: String) async throws {
  guard let node = Resources.node, let npm = ChildProcess.find("npm") else {
    throw RuntimeError.failed("Installing an adapter needs Node and npm on this machine.")
  }
  let latest = await ChildProcess.run(npm, ["view", package, "version"], timeout: .seconds(60))
  let version = latest.output.trimmingCharacters(in: .whitespacesAndNewlines)
  guard latest.status == 0, !version.isEmpty else { throw RuntimeError.failed("npm could not find \(package): \(latest.output)") }
  let selection: JSONValue = .object(["prefix": .string(prefix.path), "adapter": .string(package), "adapterVersion": .string(version),
                                      "npm": .array([.string(npm)]), "cli": .string(cli)])
  let text = String(decoding: try Wire.encoder.encode(selection), as: UTF8.self)
  let result = await ChildProcess.run(node, [Resources.harnesses.appendingPathComponent("install-adapter.mjs").path, text],
                                      timeout: .seconds(600))
  guard result.status == 0 else { throw RuntimeError.failed("Installing \(package) failed: \(result.output.suffix(2000))") }
}

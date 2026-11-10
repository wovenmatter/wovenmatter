import Darwin
import Foundation
import WovenMatterClient

/// `node bots/src/cli.ts serve --config <file>` reads this. Field names are the
/// runtime's contract (docs/architecture/WOVEN_EVERYWHERE.md, "Bots on a Mac").
struct BotsRuntimeConfig: Codable, Equatable, Sendable {
    struct Listen: Codable, Equatable, Sendable { var host = "127.0.0.1"; var port: Int }
    struct Engine: Codable, Equatable, Sendable { var socket: String; var kind = "mac-vm" }
    struct Image: Codable, Equatable, Sendable { var tag: String }
    struct Limits: Codable, Equatable, Sendable {
        var botMemoryBytes: Int64?
        init(botMemoryBytes: Int64?) { self.botMemoryBytes = botMemoryBytes }
        // The runtime distinguishes "no cap" (null) from a missing field.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let botMemoryBytes { try container.encode(botMemoryBytes, forKey: .botMemoryBytes) }
            else { try container.encodeNil(forKey: .botMemoryBytes) }
        }
    }
    struct Host: Codable, Equatable, Sendable { var url: String; var token: String }
    struct Machine: Codable, Equatable, Sendable { var deviceID: String; var name: String }
    /// The default agent's Claude runtime, so `Resources/bots` ships no second copy.
    struct Claude: Codable, Equatable, Sendable { var executable: String }

    var dataDir: String
    var listen: Listen
    var runtimeToken: String
    var engine: Engine
    var image: Image
    var limits: Limits
    var host: Host
    var machine: Machine
    var claude: Claude? = nil
}

/// Where the bundled runtime lives: `<Resources>/bots` beside the Node the app
/// already ships in `<Resources>/default-agent/bin/node`.
struct BotsRuntimeBundle: Equatable, Sendable {
    let node: URL
    let root: URL
    /// Anthropic's signed Claude binary in the default agent's dependencies, shared with
    /// the bots runtime (nil when this build has none, such as a checkout without it).
    var claudeExecutable: URL? = nil
    var entry: URL { root.appending(path: "src/cli.ts") }

    static func locate() -> BotsRuntimeBundle? {
        guard let node = DefaultAgentSupport.resources?.appending(path: "bin/node"),
              FileManager.default.isExecutableFile(atPath: node.path) else { return nil }
        let roots = [Bundle.main.resourceURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                     URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()]
            .compactMap { $0?.appending(path: "bots") }
        guard let root = roots.first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "src/cli.ts").path) }) else { return nil }
        return .init(node: node, root: root, claudeExecutable: DefaultAgentSupport.resources.flatMap(Self.claudeExecutable(defaultAgent:)))
    }

    /// `<default-agent>/node_modules/@anthropic-ai/claude-agent-sdk-darwin-<arch>/claude`, when it is there.
    static func claudeExecutable(defaultAgent: URL) -> URL? {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let binary = defaultAgent.appending(path: "node_modules/@anthropic-ai/claude-agent-sdk-darwin-\(architecture)/claude")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? binary : nil
    }

    /// The package version, which also names the bot image it was tested with.
    var version: String? {
        guard let data = try? Data(contentsOf: root.appending(path: "package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["version"] as? String
    }

    /// An untagged name: the runtime tags it with the content hash of `bots/image` and
    /// builds it through the Engine API when missing.
    var imageTag: String { "wovenmatter-bots" }
}

@MainActor
protocol BotsRuntimeChild: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }
    func terminate()
    func kill()
}

@MainActor
private final class NativeBotsRuntimeChild: BotsRuntimeChild {
    let process: Process
    init(_ process: Process) { self.process = process }
    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }
    func terminate() { process.terminate() }
    func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
}

/// Keeps one runtime process alive while bots are on, restarting it with backoff.
/// It owns only the child it started; it never signals any other process.
@MainActor
final class BotsRuntimeSupervisor {
    enum Phase: Equatable, Sendable { case stopped, starting, running, failed(String) }
    typealias Launch = @MainActor (_ executable: URL, _ arguments: [String], _ environment: [String: String], _ log: URL,
                                   _ onExit: @escaping @MainActor (Int32) -> Void) throws -> any BotsRuntimeChild
    typealias Probe = @Sendable (_ port: Int, _ token: String) async -> Bool

    private(set) var phase = Phase.stopped { didSet { if phase != oldValue { onChange?() } } }
    private(set) var config: BotsRuntimeConfig?
    var onChange: (@MainActor () -> Void)?
    private let directory: URL
    private let bundle: BotsRuntimeBundle
    private let launch: Launch
    private let probe: Probe
    private var child: (any BotsRuntimeChild)?
    private var generation = 0
    private var failures = 0
    private var restartTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?

    init(directory: URL, bundle: BotsRuntimeBundle, launch: Launch? = nil, probe: Probe? = nil) {
        self.directory = directory; self.bundle = bundle
        self.launch = launch ?? Self.nativeLaunch
        self.probe = probe ?? Self.healthProbe
    }

    var configURL: URL { directory.appending(path: "runtime.json") }
    var logURL: URL { directory.appending(path: "runtime.log") }

    /// Writes `config` and starts the runtime, or restarts it when the config changed.
    func run(_ config: BotsRuntimeConfig) throws {
        if config == self.config, child?.isRunning == true { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: config.dataDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // The config holds both bearers, so it is private to this user from the first byte.
        let data = try encoder.encode(config)
        let staged = directory.appending(path: ".runtime.json.tmp")
        FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: staged)
        guard Darwin.rename(staged.path, configURL.path) == 0 else {
            throw BotsError.unavailable("The bots runtime configuration could not be saved.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        self.config = config
        stopChild()
        failures = 0
        spawn()
    }

    func stop() async {
        config = nil
        restartTask?.cancel(); restartTask = nil
        healthTask?.cancel(); healthTask = nil
        generation += 1
        guard let child else { phase = .stopped; return }
        self.child = nil
        child.terminate()
        for _ in 0..<50 where child.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        child.kill()
        phase = .stopped
    }

    /// For immediate app termination: no waiting.
    func terminateImmediately() {
        config = nil
        generation += 1
        restartTask?.cancel(); healthTask?.cancel()
        child?.terminate(); child = nil
        phase = .stopped
    }

    private func stopChild() {
        generation += 1
        restartTask?.cancel(); restartTask = nil
        healthTask?.cancel(); healthTask = nil
        if let child { child.terminate(); self.child = nil }
    }

    private func spawn() {
        guard let config else { return }
        generation += 1
        let current = generation
        phase = .starting
        rotateLog()
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "NODE_ENV": "production",
            "LANG": "en_US.UTF-8",
        ]
        do {
            child = try launch(bundle.node, [bundle.entry.path, "serve", "--config", configURL.path], environment, logURL) { [weak self] status in
                guard let self, self.generation == current else { return }
                self.child = nil
                self.scheduleRestart(after: status)
            }
        } catch {
            phase = .failed("The bots runtime could not start: " + error.localizedDescription)
            scheduleRestart(after: -1)
            return
        }
        healthTask = Task { [weak self, probe] in
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.generation == current else { return }
                if await probe(config.listen.port, config.runtimeToken) {
                    guard self.generation == current else { return }
                    self.phase = .running
                    self.failures = 0
                    return
                }
            }
        }
    }

    private func scheduleRestart(after status: Int32) {
        guard config != nil else { phase = .stopped; return }
        failures += 1
        let delay = min(pow(2, Double(failures - 1)), 30)
        phase = .failed(status < 0 ? "The bots runtime could not start." : "The bots runtime stopped (exit \(status)). Restarting…")
        let current = generation
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.generation == current, self.config != nil else { return }
            self.spawn()
        }
    }

    private func rotateLog() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        if let size = attributes?[.size] as? Int, size > 10 * 1_024 * 1_024 {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    var processIdentifier: Int32? { child?.processIdentifier }

    private static let nativeLaunch: Launch = { executable, arguments, environment, log, onExit in
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            try? handle.close()
            Task { @MainActor in onExit(status) }
        }
        try process.run()
        return NativeBotsRuntimeChild(process)
    }

    private static let healthProbe: Probe = { port, token in
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

import Foundation
import WovenMatterClient
import WovenMatterCore

enum BotsCommand: Codable, Sendable {
    case status
    case discoverDevices
    case inspect(PiBotDeploymentTarget)
    case deploy(PiBotDeploymentTarget)
    case attach(PiBotDeploymentTarget)
    case start, stop, restart, update
    /// Stop using this deployment. Its data stays on that device.
    case forget
    /// Remove a managed deployment from its device.
    case remove(deleteData: Bool)
    case applyMCPPolicy
}

struct BotsCommandResult: Codable, Sendable {
    var snapshot: PiBotRuntimeSnapshot
    var devices: [PiBotTailnetPeer]?
    var inspection: PiBotHostInspection?
}

/// Owns the one Pi Bot deployment for this Woven Matter instance, inside the process
/// that owns execution, so closing the window never stops bots. Pi Bot itself owns
/// its data; this type owns only where it runs and how Woven Matter reaches it.
@MainActor @Observable
final class PiBotRuntimeSupervisor {
    struct Persisted: Codable, Equatable {
        var target: PiBotDeploymentTarget?
        var stopped = false
        var installedCommit: String?
        var serverPort: Int?
        var tunnelPort: Int?
        var mcpRemotePort: Int?
        var lingeringDisabled = false
    }

    private(set) var snapshot = PiBotRuntimeSnapshot()
    var onChange: (@MainActor () -> Void)?
    /// Issues a fresh grant; returns the loopback endpoint and plaintext token once.
    var issueMCPGrant: (@MainActor (String) async throws -> WovenBotMCPGrant)?
    var revokeMCPGrants: (@MainActor (String) -> Void)?
    var mcpEnabled: (@MainActor () async -> Bool)?

    private let root: URL
    private let stateDirectory: URL
    private let stateFile: URL
    private let runner: PiBotHostRunner
    private let bundleLoader: () throws -> PiBotBundle
    private let healthProbe: @Sendable (URL) async -> PiBotHealth?
    private var persisted = Persisted()
    private var supervision: Task<Void, Never>?
    private var server: Process?
    private var expectedExit = false
    private let tunnel = PiBotTunnel()
    private var control: PiBotClient?
    private var controlBase: URL?
    private var started = false

    init(supportDirectory: URL, instance: String,
         bundleLoader: @escaping () throws -> PiBotBundle = { try PiBotBundle.bundled() },
         healthProbe: @escaping @Sendable (URL) async -> PiBotHealth? = { await PiBotHealthProbe.check($0) }) {
        // The host script requires its root to be its own, so this type's files sit beside it.
        root = supportDirectory.appending(path: "PiBot", directoryHint: .isDirectory)
        stateDirectory = supportDirectory.appending(path: "PiBotRuntime", directoryHint: .isDirectory)
        stateFile = stateDirectory.appending(path: "deployment.json")
        runner = PiBotHostRunner(instance: instance, localRoot: root)
        self.bundleLoader = bundleLoader
        self.healthProbe = healthProbe
        if let data = try? Data(contentsOf: stateFile), let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            persisted = saved
        }
        snapshot.target = persisted.target
        snapshot.installedCommit = persisted.installedCommit
        snapshot.lingeringDisabled = persisted.lingeringDisabled
        if let bundle = try? bundleLoader() {
            snapshot.bundleAvailable = true
            snapshot.bundledCommit = bundle.selection.commit
        }
        snapshot.phase = persisted.target == nil ? .notConfigured : persisted.stopped ? .stopped : .starting
    }

    func start() {
        guard !started else { return }
        started = true
        if persisted.target != nil, !persisted.stopped { supervise() }
    }

    func perform(_ command: BotsCommand) async throws -> BotsCommandResult {
        switch command {
        case .status: break
        case .discoverDevices:
            let peers = try await Task.detached(priority: .userInitiated) { try PiBotTailnet.peers() }.value
            return .init(snapshot: snapshot, devices: peers)
        case .inspect(let target):
            return .init(snapshot: snapshot, inspection: try await runner.inspect(target, script: try scriptData()))
        case .deploy(var target):
            target.ownership = .managed
            target.remotePort = nil
            await switchTarget(to: target)
            persisted.installedCommit = nil
            persisted.serverPort = nil
            supervise(install: true)
        case .attach(var target):
            target.ownership = .attached
            guard target.remotePort != nil else { throw PiBotHostError.command("Choose which Pi Bot server to connect to.") }
            await switchTarget(to: target)
            persisted.installedCommit = nil
            persisted.serverPort = target.remotePort
            supervise()
        case .start:
            persisted.stopped = false
            save()
            if let target = persisted.target, target.kind == .tailnet, target.ownership == .managed {
                try await runner.lifecycle("start", target, script: try scriptData())
            }
            supervise()
        case .stop:
            persisted.stopped = true
            save()
            await halt()
            if let target = persisted.target, target.kind == .tailnet, target.ownership == .managed {
                try await runner.lifecycle("stop", target, script: try scriptData())
            }
            update(.stopped, message: nil)
        case .restart:
            await halt()
            if let target = persisted.target, target.kind == .tailnet, target.ownership == .managed {
                try await runner.lifecycle("restart", target, script: try scriptData())
            }
            persisted.stopped = false
            save()
            supervise()
        case .update:
            await halt()
            persisted.stopped = false
            supervise(install: true)
        case .forget:
            await leaveCurrentTarget()
            persisted = Persisted()
            save()
            snapshot = PiBotRuntimeSnapshot(bundledCommit: snapshot.bundledCommit, bundleAvailable: snapshot.bundleAvailable)
            onChange?()
        case .remove(let deleteData):
            guard let target = persisted.target, target.ownership == .managed else {
                throw PiBotHostError.command("Woven Matter did not install this Pi Bot, so it cannot remove it.")
            }
            await halt()
            try await runner.uninstall(target, deleteData: deleteData, script: try scriptData())
            if let installation = snapshot.health?.installationId { revokeMCPGrants?(installation) }
            persisted = Persisted()
            save()
            snapshot = PiBotRuntimeSnapshot(bundledCommit: snapshot.bundledCommit, bundleAvailable: snapshot.bundleAvailable)
            onChange?()
        case .applyMCPPolicy:
            await ensureWovenConnection()
        }
        return .init(snapshot: snapshot)
    }

    /// A completed or blocked session a bot coordinates. Throwing retries the delivery.
    func deliver(_ notification: WovenBotNotification) async throws {
        guard snapshot.phase == .ready, let control,
              snapshot.health?.installationId == notification.installationID else {
            throw PiBotHostError.command("Pi Bot is not connected.")
        }
        try await control.send(botID: notification.botID, text: notification.text)
    }

    /// The process is exiting. Pi Bot resumes live work when it next opens its bots.
    func shutdown() async {
        supervision?.cancel(); supervision = nil
        await halt(graceSeconds: 15)
    }

    /// Last resort from synchronous termination paths.
    func terminateImmediately() {
        supervision?.cancel(); supervision = nil
        expectedExit = true
        server?.terminate()
    }

    private func scriptData() throws -> Data { try Data(contentsOf: try bundleLoader().script) }

    private func switchTarget(to target: PiBotDeploymentTarget) async {
        if let current = persisted.target, !current.isSameDevice(as: target) || current.ownership != target.ownership {
            await leaveCurrentTarget()
        } else {
            await halt()
        }
        persisted.target = target
        persisted.stopped = false
        persisted.tunnelPort = nil
        persisted.mcpRemotePort = nil
        persisted.lingeringDisabled = false
        snapshot = PiBotRuntimeSnapshot(phase: .starting, target: target, bundledCommit: snapshot.bundledCommit, bundleAvailable: snapshot.bundleAvailable)
        save()
    }

    /// Bots keep their data where they are. A managed remote service is stopped so the
    /// old device does not keep running bots nobody can see.
    private func leaveCurrentTarget() async {
        await halt()
        guard let target = persisted.target else { return }
        if target.kind == .tailnet, target.ownership == .managed, let script = try? scriptData() {
            try? await runner.lifecycle("stop", target, script: script)
        }
    }

    private func halt(graceSeconds: Int = 15) async {
        supervision?.cancel(); supervision = nil
        if let control { await control.invalidate() }
        control = nil; controlBase = nil
        await tunnel.stop()
        guard let process = server else { return }
        expectedExit = true
        if process.isRunning {
            process.terminate()
            for _ in 0..<(graceSeconds * 10) where process.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        server = nil
        expectedExit = false
        removePIDFile()
    }

    private func supervise(install: Bool = false) {
        supervision?.cancel()
        update(install ? .installing : .starting, message: install ? "Preparing Pi Bot…" : "Starting Pi Bot…")
        supervision = Task { [weak self] in
            await self?.run(installRequested: install)
        }
    }

    private func run(installRequested: Bool) async {
        guard let target = persisted.target else { return }
        var delay: Duration = .seconds(1)
        var needsInstall = installRequested
        while !Task.isCancelled {
            do {
                if target.ownership == .managed {
                    let bundled = try? bundleLoader()
                    // This Mac follows the app's delivered revision. A remote device
                    // updates when the user asks, since it can outlive this app version.
                    if needsInstall || persisted.installedCommit == nil
                        || (target.kind == .thisMac && bundled != nil && persisted.installedCommit != bundled?.selection.commit) {
                        try await install(target)
                        needsInstall = false
                    }
                }
                let base = try await connect(target)
                delay = .seconds(1)
                try await watch(base: base, target: target)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error.localizedDescription
                if needsInstall {
                    update(.failed, message: nil, error: failure)
                    return
                }
                update(.reconnecting, message: "Reconnecting to Pi Bot…", error: failure)
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(30))
            }
        }
    }

    private func install(_ target: PiBotDeploymentTarget) async throws {
        update(.installing, message: "Checking \(target.displayName)…")
        let bundle = try bundleLoader()
        let script = try Data(contentsOf: bundle.script)
        if target.kind == .thisMac {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            await stopStrayServer()
            if let process = server, process.isRunning {
                expectedExit = true
                process.terminate()
                for _ in 0..<150 where process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
                expectedExit = false
                server = nil
            }
        }
        let inspection = try await runner.inspect(target, script: script)
        let progress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.update(.installing, message: message) }
        }
        let result = try await runner.install(target, bundle: bundle, inspection: inspection,
            service: target.kind == .tailnet, port: persisted.serverPort ?? inspection.managed.port, progress: progress)
        persisted.installedCommit = result.commit
        persisted.serverPort = result.port
        persisted.lingeringDisabled = result.lingering == false
        snapshot.installedCommit = result.commit
        snapshot.lingeringDisabled = persisted.lingeringDisabled
        save()
    }

    /// Reaches the server and returns its loopback base URL.
    private func connect(_ target: PiBotDeploymentTarget) async throws -> URL {
        update(.starting, message: "Starting Pi Bot…")
        switch target.kind {
        case .thisMac:
            guard let port = persisted.serverPort else { throw PiBotHostError.command("Pi Bot has not been installed on this Mac.") }
            if target.ownership == .managed, server?.isRunning != true { try await launchLocalServer() }
            let base = Self.baseURL(port: port)
            try await waitForHealth(base, seconds: 60)
            return base
        case .tailnet:
            guard let peer = target.peer else { throw PiBotHostError.invalidConnection }
            guard let remotePort = persisted.serverPort else { throw PiBotHostError.command("Pi Bot has not been installed on \(peer.name).") }
            guard let localPort = PiBotLoopback.freePort(preferred: persisted.tunnelPort) else {
                throw PiBotHostError.command("No free local port is available.")
            }
            let local = await localMCPPort()
            let reverse = local == nil ? nil : (persisted.mcpRemotePort ?? Int.random(in: 47_400...48_400))
            try await tunnel.start(peer: peer, user: target.sshUser,
                forward: .init(localPort: localPort, remotePort: remotePort, mcpRemotePort: reverse, mcpLocalPort: local))
            persisted.tunnelPort = localPort
            persisted.mcpRemotePort = reverse
            save()
            let base = Self.baseURL(port: localPort)
            do {
                try await waitForHealth(base, seconds: 30)
            } catch {
                if let detail = await tunnel.failureDetail() {
                    // A taken reverse port is the only forward failure a new port can fix.
                    if detail.contains("remote port forwarding failed") { persisted.mcpRemotePort = nil; save() }
                    throw PiBotHostError.command(detail)
                }
                throw error
            }
            return base
        }
    }

    private func waitForHealth(_ base: URL, seconds: Int) async throws {
        for _ in 0..<(seconds * 2) {
            try Task.checkCancellation()
            if await healthProbe(base) != nil { return }
            if let target = persisted.target, target.kind == .tailnet, await !tunnel.isRunning { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw PiBotHostError.command("Pi Bot did not answer on \(persisted.target?.displayName ?? "this device").")
    }

    /// Stay connected until the server or transport goes away.
    private func watch(base: URL, target: PiBotDeploymentTarget) async throws {
        var health = await healthProbe(base)
        snapshot.baseURL = base
        snapshot.health = health
        await openControl(base)
        await ensureWovenConnection()
        update(.ready, message: nil)
        var misses = 0
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(10))
            if target.kind == .tailnet, await !tunnel.isRunning {
                snapshot.baseURL = nil
                throw PiBotHostError.command(await tunnel.failureDetail() ?? "The connection to \(target.displayName) was lost.")
            }
            if target.kind == .thisMac, target.ownership == .managed, server?.isRunning != true {
                snapshot.baseURL = nil
                throw PiBotHostError.command("Pi Bot stopped on this Mac.")
            }
            let latest = await healthProbe(base)
            if let latest {
                misses = 0
                if latest != health {
                    health = latest
                    snapshot.health = latest
                    onChange?()
                }
            } else {
                misses += 1
                if misses >= 3 {
                    snapshot.baseURL = nil
                    throw PiBotHostError.command("Pi Bot stopped answering on \(target.displayName).")
                }
            }
        }
    }

    private func openControl(_ base: URL) async {
        if controlBase == base, control != nil { return }
        if let control { await control.invalidate() }
        let client = PiBotClient(baseURL: base) { _ in }
        await client.connect()
        control = client
        controlBase = base
    }

    /// The reverse forward needs this before the server's installation ID is known.
    var mcpLocalPort: (@MainActor () async -> Int?)?

    private func localMCPPort() async -> Int? {
        guard await mcpEnabled?() == true else { return nil }
        return await mcpLocalPort?()
    }

    /// Bots keep working if this fails; only Woven tools are unavailable, and the next
    /// reconnect or policy change retries.
    private func ensureWovenConnection() async {
        guard let control, let health = snapshot.health, health.supports("woven.mcp"),
              let installation = health.installationId else { return }
        // The socket may still be completing its hello.
        for _ in 0..<40 where await control.state != .open { try? await Task.sleep(for: .milliseconds(100)) }
        do {
            guard await mcpEnabled?() == true else {
                snapshot.woven = try await control.wovenDisconnect()
                revokeMCPGrants?(installation)
                onChange?()
                return
            }
            let status = try await control.wovenStatus()
            let expected = expectedMCPEndpoint()
            if let expected, status.endpointURL == expected, status.state == "ready" || status.state == "connecting" {
                snapshot.woven = status
                onChange?()
                return
            }
            guard let issue = issueMCPGrant else { return }
            let grant = try await issue(installation)
            snapshot.woven = try await control.wovenConnect(endpointURL: expected ?? grant.endpointURL, bearerToken: grant.bearerToken)
        } catch {
            snapshot.woven = PiBotWovenStatus(state: "unavailable", error: error.localizedDescription)
        }
        onChange?()
    }

    /// nil means this Mac: the grant's own loopback endpoint is reachable from the server.
    private func expectedMCPEndpoint() -> String? {
        guard persisted.target?.kind == .tailnet, let port = persisted.mcpRemotePort else { return nil }
        return "http://127.0.0.1:\(port)/mcp"
    }

    private static func baseURL(port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

    private func update(_ phase: PiBotRuntimeSnapshot.Phase, message: String?, error: String? = nil) {
        snapshot.phase = phase
        snapshot.message = message
        snapshot.error = error
        snapshot.target = persisted.target
        snapshot.installedCommit = persisted.installedCommit
        if phase != .ready { snapshot.baseURL = phase == .reconnecting ? nil : snapshot.baseURL }
        onChange?()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(persisted).write(to: stateFile, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        } catch {
            NSLog("Pi Bot deployment state could not be saved: %@", error.localizedDescription)
        }
    }

    // MARK: This Mac's server process

    private var pidFile: URL { stateDirectory.appending(path: "server.pid") }
    private var logFile: URL { stateDirectory.appending(path: "logs/server.log") }

    private func launchLocalServer() async throws {
        await stopStrayServer()
        let runner = root.appending(path: "run-server")
        guard FileManager.default.isExecutableFile(atPath: runner.path) else {
            persisted.installedCommit = nil
            save()
            throw PiBotHostError.command("The Pi Bot install on this Mac is incomplete.")
        }
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Self.rotateLog(logFile)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let log = try FileHandle(forWritingTo: logFile)
        try log.seekToEnd()
        let process = Process()
        // The host script's runner follows `current`, including that release's Node.
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [runner.path]
        process.currentDirectoryURL = root
        process.environment = Self.serverEnvironment(home: FileManager.default.homeDirectoryForCurrentUser.path)
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in self?.serverExited(finished, status: status) }
        }
        try process.run()
        server = process
        try? Data(String(process.processIdentifier).utf8).write(to: pidFile, options: [.atomic])
    }

    private func serverExited(_ process: Process, status: Int32) {
        guard server === process else { return }
        server = nil
        removePIDFile()
        guard !expectedExit, !persisted.stopped, persisted.target?.kind == .thisMac else { return }
        // Pi Bot's Settings → Restart exits 75 on purpose; `watch` notices and relaunches.
        NSLog("Pi Bot exited with status %d", status)
    }

    /// A previous backend that crashed can leave its server holding the port and database.
    private func stopStrayServer() async {
        guard server == nil, let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        defer { removePIDFile() }
        let probe = Process()
        let pipe = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-p", String(pid), "-o", "command="]
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()
        // Only ever signal this instance's own server, never a reused PID.
        guard output.contains(root.path), output.contains("serve") else { return }
        kill(pid, SIGTERM)
        for _ in 0..<150 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    private func removePIDFile() { try? FileManager.default.removeItem(at: pidFile) }

    private static func rotateLog(_ url: URL, limit: UInt64 = 8 * 1024 * 1024) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size > limit else { return }
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    /// Provider credentials live in Pi Bot's own store; nothing is inherited from this app's environment.
    static func serverEnvironment(home: String) -> [String: String] {
        ["HOME": home,
         "PATH": ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"].joined(separator: ":"),
         "LANG": "en_US.UTF-8"]
    }
}

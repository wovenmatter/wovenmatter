import Darwin
import Foundation
import Observation
import Security
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// Window → owner-of-execution commands for bots. The background server runs them.
enum BotsCommand: Codable, Sendable {
    case status
    /// Bots on this Mac: starts or stops the VM and the runtime.
    case setEnabled(Bool)
    /// Bots run on one machine: turns them on or off on any machine, this Mac included.
    /// Bots, their files and conversations stay where they are.
    case setMachineEnabled(machineID: String, Bool)
    case setResources(machineID: String, BotResourceSettings)
    /// Pause-all for this Mac's bots: their Woven MCP keys stop working until resumed.
    case setPaused(Bool)
    case revokeBot(callerID: String)
    case reinstateBot(callerID: String)
    case discoverDevices
    /// Starts installing bots on a Linux peer, or turning them on for its Woven server.
    /// It runs as a job: the reply comes at once, and progress and the outcome reach the
    /// window through `jobs` and the device's state.
    case installBots(hostName: String, userName: String?)
    /// Starts updating a Linux host, as a job like `installBots`.
    case updateLinuxHost(machineID: String)
    /// Starts updating a Mac's bots engine (the Woven VM). Progress and the outcome show on
    /// that machine: `updating`, then `engineUpdateFailure` if it was rolled back.
    case updateEngine(machineID: String)
    case restartRuntime
    /// Fresh headers for one signed upgrade of another member's bots socket or
    /// live stream (`…/v1/stream?protocol=1`; `audience`: its member device ID).
    /// The window process holds no member key.
    case signSocket(url: URL, audience: String)
}

struct BotsCommandResult: Codable, Sendable {
    var machines: [BotMachine] = []
    var thisMachineID: String?
    var thisMacVersion: String?
    var callers: [WovenBotCaller] = []
    var devices: [BotDiscoveredDevice]?
    var syncErrors: [String] = []
    var botMCP: WorkspaceExternalMCPSettings?
    /// The reply to `signSocket`.
    var socketHeaders: [String: String]?
    /// Long bots commands running in the process that owns execution, and how the last
    /// one for each target ended.
    var jobs: [BotsJob] = []
}

/// A bots command that outlasts one window round trip (the background server answers
/// each within 30 s): installing bots on a Linux host takes minutes, updating one up to
/// fifteen. It runs where execution lives; its progress, and the error when it fails,
/// travel in every snapshot until the next run for the same target.
struct BotsJob: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case installBots, updateLinuxHost }
    var kind: Kind
    /// The Tailscale host name for an install, the machine ID for an update.
    var target: String
    var running: Bool
    /// The current step while running.
    var progress: String?
    /// Why it failed, once it has finished.
    var error: String?

    var key: String { kind.rawValue + ":" + target.lowercased() }
}

/// What the bots host needs from the rest of the app, so it can be tested alone.
struct BotsHostDependencies {
    var identity: @MainActor () async throws -> (deviceID: String, name: String)
    var appVersion: String?
    var issueKey: @MainActor (_ machineID: String, _ botID: String, _ botName: String) async throws -> WovenBotMCPGrant
    var revokeKey: @MainActor (_ callerID: String, _ sticky: Bool) throws -> Void
    var reinstate: @MainActor (_ callerID: String) async throws -> Void
    var setPaused: @MainActor (_ machineID: String, _ paused: Bool) async throws -> Void
    var callers: @MainActor () async throws -> [WovenBotCaller]
    var isPaused: @MainActor (_ machineID: String) async -> Bool = { _ in false }
    var botMCP: @MainActor () async -> WorkspaceExternalMCPSettings?
    var recordConversation: @MainActor (_ machineID: String, _ batch: BotConversationMirror) async throws -> Void
    var deleteConversations: @MainActor (_ machineID: String, _ botID: String) async throws -> Void
    var inferenceCredential: @MainActor (_ provider: String) async throws -> BotsHostAPI.CredentialReply
    var remoteMachines: @MainActor (_ thisMacVersion: String?) async -> [BotMachine] = { _ in [] }
    var setRemoteResources: @MainActor (_ machineID: String, _ resources: BotResourceSettings) async throws -> Void = { _, _ in
        throw BotsError.unavailable("That machine is unavailable.")
    }
    /// Another machine's `POST /v1/bots/enabled`.
    var setRemoteEnabled: @MainActor (_ machineID: String, _ enabled: Bool) async throws -> Void = { _, _ in
        throw BotsError.unavailable("That machine is unavailable.")
    }
    var discover: @MainActor () async throws -> [BotDiscoveredDevice] = { [] }
    var installBots: @MainActor (_ hostName: String, _ userName: String?, _ progress: @escaping @MainActor (String) -> Void) async throws -> Void = { _, _, _ in
        throw BotsError.unavailable("Installing bots on Linux is unavailable.")
    }
    var updateLinuxHost: @MainActor (_ machineID: String, _ progress: @escaping @MainActor (String) -> Void) async throws -> Void = { _, _ in }
    /// Another Mac's `POST /v1/bots/engine/update`.
    var updateRemoteEngine: @MainActor (_ machineID: String) async throws -> Void = { _ in
        throw BotsError.unavailable("That machine is unavailable.")
    }
    var syncErrors: @MainActor () -> [String] = { [] }
    var signSocket: @MainActor (_ url: URL, _ audience: String) async throws -> [String: String] = { _, _ in
        throw BotsError.unavailable("This Mac cannot sign bots connections yet.")
    }
    var capacity: @MainActor (_ directory: URL) async -> BotMachineCapacity = BotsHostController.localCapacity
}

/// Owns bots on this Mac inside the process that owns execution: the VM, the runtime
/// child, the Runtime host API, and this Mac's side of `/v1/bots/*` for other members.
@MainActor @Observable
final class BotsHostController {
    struct Persisted: Codable, Equatable {
        var enabled = false
        var resources: BotResourceSettings?
        var runtimePort: Int?
        var runtimeToken: String
        var hostToken: String
    }

    private(set) var persisted: Persisted
    private(set) var engineStatus = BotEngineStatus(state: .stopped)
    private(set) var lastError: String?
    /// Why the last engine update was rolled back; cleared when the next one starts.
    private(set) var engineUpdateFailure: String?
    var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let engine: any BotEngineHost
    @ObservationIgnored private let bundle: BotsRuntimeBundle?
    @ObservationIgnored private var dependencies: BotsHostDependencies
    @ObservationIgnored private(set) var supervisor: BotsRuntimeSupervisor?
    @ObservationIgnored private let previews: BotPreviewPublisher
    @ObservationIgnored private var hostServer: LibraryHTTPServer?
    @ObservationIgnored private var hostPort: UInt16?
    @ObservationIgnored private var identity: (deviceID: String, name: String)?
    @ObservationIgnored private var notifier: PiBotClient?
    @ObservationIgnored private var bringUpTask: Task<Void, Never>?
    @ObservationIgnored private(set) var engineUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var lastDevices: [BotDiscoveredDevice]?
    @ObservationIgnored private var jobs: [String: BotsJob] = [:]
    @ObservationIgnored private(set) var jobTasks: [String: Task<Void, Never>] = [:]
    /// Other machines answer slowly; a status refresh reuses a recent probe.
    @ObservationIgnored private var remoteCache: (at: Date, machines: [BotMachine])?
    static let remoteCacheLifetime: TimeInterval = 20

    init(directory: URL, engine: any BotEngineHost, bundle: BotsRuntimeBundle? = BotsRuntimeBundle.locate(),
         dependencies: BotsHostDependencies, supervisor: BotsRuntimeSupervisor? = nil) {
        self.directory = directory
        self.engine = engine
        self.bundle = bundle
        self.dependencies = dependencies
        previews = BotPreviewPublisher()
        if let data = try? Data(contentsOf: directory.appending(path: "host.json")),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            persisted = saved
        } else {
            persisted = Persisted(runtimeToken: Self.randomToken(), hostToken: Self.randomToken())
        }
        self.supervisor = supervisor ?? bundle.map { BotsRuntimeSupervisor(directory: directory, bundle: $0) }
        self.supervisor?.onChange = { [weak self] in self?.changed() }
        engine.onStatusChange = { [weak self] status in
            guard let self, self.persisted.enabled || status.state == .stopped else { return }
            self.engineStatus = status
            self.changed()
        }
    }

    var isEnabled: Bool { persisted.enabled }
    var resources: BotResourceSettings { persisted.resources ?? .defaults }

    /// Starts bots if they were on when the server last ran.
    func start() {
        guard persisted.enabled else { return }
        bringUp()
    }

    func shutdown() async {
        bringUpTask?.cancel()
        await previews.removeAll()
        if let notifier { await notifier.invalidate() }
        notifier = nil
        await supervisor?.stop()
        hostServer?.stop(); hostServer = nil; hostPort = nil
        await engine.stop()
    }

    func terminateImmediately() {
        supervisor?.terminateImmediately()
        hostServer?.stop(); hostServer = nil
    }

    // MARK: Commands

    func perform(_ command: BotsCommand) async throws -> BotsCommandResult {
        // Signing is not a state change: no snapshot, no remote probes.
        if case let .signSocket(url, audience) = command {
            return BotsCommandResult(socketHeaders: try await dependencies.signSocket(url, audience))
        }
        var devices: [BotDiscoveredDevice]?
        if case .status = command {} else { remoteCache = nil }
        switch command {
        case .status: break
        case .setEnabled(let enabled):
            persisted.enabled = enabled
            try save()
            if enabled { bringUp() } else { await bringDown() }
        case let .setMachineEnabled(machineID, enabled):
            if try await isThisMac(machineID) {
                return try await perform(.setEnabled(enabled))
            }
            try await dependencies.setRemoteEnabled(machineID, enabled)
        case let .setResources(machineID, settings):
            if try await isThisMac(machineID) {
                let capacity = await dependencies.capacity(directory)
                persisted.resources = BotResourcePolicy.validated(settings, capacity.with(used: await engine.diskUsedByBots()))
                try save()
                if persisted.enabled {
                    try await engine.apply(resources: resources)
                    try startRuntime()
                }
            } else {
                try await dependencies.setRemoteResources(machineID, settings)
            }
        case .setPaused(let paused):
            let identity = try await resolveIdentity()
            try await dependencies.setPaused(identity.deviceID, paused)
        case .revokeBot(let callerID):
            try dependencies.revokeKey(callerID, true)
        case .reinstateBot(let callerID):
            try await dependencies.reinstate(callerID)
        case .discoverDevices:
            devices = try await dependencies.discover()
            lastDevices = devices
            // A fresh look replaces how earlier installs ended.
            jobs = jobs.filter { $0.value.kind != .installBots || $0.value.running }
        case let .installBots(hostName, userName):
            let host = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { throw BotsError.unavailable("Choose a device to install bots on.") }
            let install = dependencies.installBots
            try startJob(.installBots, target: host, progress: "Starting…") { progress in
                try await install(host, userName, progress)
            }
        case .updateLinuxHost(let machineID):
            let update = dependencies.updateLinuxHost
            try startJob(.updateLinuxHost, target: machineID.lowercased(), progress: "Starting the update…") { progress in
                try await update(machineID, progress)
            }
        case .updateEngine(let machineID):
            if try await isThisMac(machineID) { try startEngineUpdate() }
            else { try await dependencies.updateRemoteEngine(machineID) }
        case .restartRuntime:
            if persisted.enabled { await supervisor?.stop(); bringUp() }
        case .signSocket: break
        }
        return await snapshot(devices: devices ?? lastDevices)
    }

    func snapshot(devices: [BotDiscoveredDevice]? = nil) async -> BotsCommandResult {
        let identity = try? await resolveIdentity()
        var machines: [BotMachine] = []
        if let identity { machines.append(await thisMachine(identity)) }
        machines += await remoteMachines().filter { $0.id != identity?.deviceID }
        for index in machines.indices where jobs[BotsJob(kind: .updateLinuxHost, target: machines[index].id, running: true).key]?.running == true {
            machines[index].updating = true
        }
        return BotsCommandResult(machines: machines, thisMachineID: identity?.deviceID, thisMacVersion: dependencies.appVersion,
                                 callers: (try? await dependencies.callers()) ?? [], devices: Self.devices(devices, showing: Array(jobs.values)),
                                 syncErrors: dependencies.syncErrors(), botMCP: await dependencies.botMCP(),
                                 jobs: jobs.values.sorted { $0.key < $1.key })
    }

    /// Discovered devices with each install's progress or failure in place of their state.
    /// A host being installed that discovery has not listed is shown too.
    static func devices(_ devices: [BotDiscoveredDevice]?, showing jobs: [BotsJob]) -> [BotDiscoveredDevice]? {
        let installs = jobs.filter { $0.kind == .installBots && ($0.running || $0.error != nil) }.sorted { $0.key < $1.key }
        guard devices != nil || !installs.isEmpty else { return devices }
        var result = devices ?? []
        for job in installs {
            let state: BotDiscoveredDevice.State = job.running ? .installing(job.progress ?? "Installing…") : .failed(job.error ?? "The install failed.")
            if let index = result.firstIndex(where: { $0.hostName.lowercased() == job.target.lowercased() }) {
                result[index].state = state
            } else {
                result.append(.init(hostName: job.target, displayName: job.target, dnsName: nil, system: .linux, state: state))
            }
        }
        return result
    }

    /// Runs a long command in the background. Its progress and outcome are recorded and
    /// announced; the error is kept, so no failure goes unseen when nobody is waiting.
    private func startJob(_ kind: BotsJob.Kind, target: String, progress: String,
                          _ work: @escaping @MainActor (_ progress: @escaping @MainActor (String) -> Void) async throws -> Void) throws {
        let job = BotsJob(kind: kind, target: target, running: true, progress: progress)
        guard jobs[job.key]?.running != true else { throw BotsError.unavailable("That is already running.") }
        jobs[job.key] = job
        changed()
        let key = job.key
        jobTasks[key] = Task { [weak self] in
            var failure: String?
            do {
                try await work { [weak self] message in
                    guard let self, self.jobs[key]?.running == true, self.jobs[key]?.progress != message else { return }
                    self.jobs[key]?.progress = message
                    self.changed()
                }
            } catch {
                failure = error is CancellationError ? "It was stopped before it finished." : error.localizedDescription
            }
            guard let self else { return }
            self.jobs[key] = BotsJob(kind: kind, target: target, running: false, progress: nil, error: failure)
            self.jobTasks[key] = nil
            self.remoteCache = nil
            if kind == .installBots {
                if let devices = try? await self.dependencies.discover() { self.lastDevices = devices }
                else if failure == nil, let index = self.lastDevices?.firstIndex(where: { $0.hostName.lowercased() == target.lowercased() }) {
                    self.lastDevices?[index].state = .ready
                }
            }
            self.changed()
        }
    }

    private func remoteMachines() async -> [BotMachine] {
        if let remoteCache, Date().timeIntervalSince(remoteCache.at) < Self.remoteCacheLifetime { return remoteCache.machines }
        let machines = await dependencies.remoteMachines(dependencies.appVersion)
        remoteCache = (Date(), machines)
        return machines
    }

    /// This Mac as other members and the window see it.
    func remoteStatus() async throws -> BotsRemoteStatus {
        let identity = try await resolveIdentity()
        let machine = await thisMachine(identity)
        let state: String = switch machine.state { case .ready: "ready"; case .starting: "starting"; case .failed: "failed"; default: "off" }
        var status = BotsRemoteStatus(machine: .init(deviceID: identity.deviceID, name: identity.name, kind: "mac"), enabled: persisted.enabled,
                                      state: state, message: machine.message, versions: machine.versions, resources: machine.resources,
                                      capacity: machine.capacity, paused: machine.paused)
        status.updating = machine.updating
        status.engineUpdateFailure = machine.engineUpdateFailure
        return status
    }

    private func thisMachine(_ identity: (deviceID: String, name: String)) async -> BotMachine {
        let capacity = await dependencies.capacity(directory).with(used: await engine.diskUsedByBots())
        let paused = await dependencies.isPaused(identity.deviceID)
        let state: BotMachine.State
        var message: String? = lastError
        if !persisted.enabled { state = .off; message = nil }
        else if bundle == nil { state = .failed; message = "This build doesn't include the bots runtime. Rebuild Woven Matter with its bots resources." }
        else {
            switch supervisor?.phase ?? .stopped {
            // A running engine can still have something to say: a pending restart, a rolled-back update.
            case .running: state = .ready; message = engineStatus.message
            case .starting, .stopped: state = engineStatus.state == .failed || engineStatus.state == .unavailable ? .failed : .starting
                // While starting, the engine's progress (download, first boot) is the message.
                message = state == .failed ? engineStatus.message ?? message : lastError ?? engineStatus.message
            case .failed(let reason): state = .failed; message = reason
            }
        }
        let socket: BotSocketEndpoint? = persisted.runtimePort.flatMap { port in
            URL(string: "ws://127.0.0.1:\(port)/ws").map { BotSocketEndpoint(url: $0, bearer: persisted.runtimeToken) }
        }
        var machine = BotMachine(id: identity.deviceID, name: identity.name, kind: .thisMac, state: state, message: message,
                                 socket: persisted.enabled ? socket : nil,
                                 versions: .init(app: dependencies.appVersion, runtime: bundle?.version, protocol: 1),
                                 resources: resources, capacity: capacity, paused: paused,
                                 updating: engineUpdateTask != nil || engineStatus.state == .updating)
        machine.engineUpdateFailure = engineUpdateFailure
        return machine
    }

    /// Updates the VM in the background: it can take many minutes, longer than any command
    /// round trip. The guest reboots, so running containers stop; volumes and images stay,
    /// and the runtime starts a bot's container again on its next tool call.
    private func startEngineUpdate() throws {
        guard persisted.enabled else { throw BotsError.unavailable("Bots are off on this Mac.") }
        guard engineUpdateTask == nil else { return }
        engineUpdateFailure = nil
        engineUpdateTask = Task { [weak self] in
            guard let self else { return }
            do { try await engine.update() }
            catch is CancellationError { return }
            catch { engineUpdateFailure = error.localizedDescription }
            guard !Task.isCancelled else { return }
            engineStatus = await engine.status()
            engineUpdateTask = nil
            changed()
        }
        changed()
    }

    // MARK: Bring up and down

    private func bringUp() {
        bringUpTask?.cancel()
        bringUpTask = Task { [weak self] in
            guard let self else { return }
            do {
                lastError = nil
                guard bundle != nil else { throw BotsError.unavailable("This build doesn't include the bots runtime.") }
                try await startHostAPI()
                engineStatus = .init(state: .starting)
                changed()
                engineStatus = try await engine.ensureRunning(resources: resources)
                try Task.checkCancellation()
                try startRuntime()
            } catch is CancellationError {
            } catch {
                lastError = error.localizedDescription
                engineStatus = await engine.status()
            }
            changed()
        }
    }

    private func bringDown() async {
        bringUpTask?.cancel(); bringUpTask = nil
        // Stop following a VM update; turning bots off stops the VM itself below.
        engineUpdateTask?.cancel(); engineUpdateTask = nil
        await previews.removeAll()
        if let notifier { await notifier.invalidate() }
        notifier = nil
        await supervisor?.stop()
        await engine.stop()
        engineStatus = await engine.status()
        lastError = nil
        changed()
    }

    private func startRuntime() throws {
        guard let supervisor, let bundle, let hostPort, let identity, let socket = engineStatus.socketPath else { return }
        let port = try persisted.runtimePort.flatMap { Self.isFree($0) ? $0 : nil } ?? Self.freeLoopbackPort()
        if persisted.runtimePort != port { persisted.runtimePort = port; try save() }
        let config = BotsRuntimeConfig(
            dataDir: directory.appending(path: "data").path,
            listen: .init(port: port), runtimeToken: persisted.runtimeToken,
            engine: .init(socket: socket), image: .init(tag: bundle.imageTag),
            limits: .init(botMemoryBytes: resources.perBotBytes),
            host: .init(url: "http://127.0.0.1:\(hostPort)/", token: persisted.hostToken),
            machine: .init(deviceID: identity.deviceID, name: identity.name),
            claude: bundle.claudeExecutable.map { .init(executable: $0.path) })
        try supervisor.run(config)
    }

    private func startHostAPI() async throws {
        let identity = try await resolveIdentity()
        guard hostServer == nil else { return }
        let api = makeHostAPI(machineID: identity.deviceID)
        let server = LibraryHTTPServer { request in await api.handle(request) }
        hostServer = server
        do { hostPort = try await server.start() }
        catch { hostServer = nil; throw error }
    }

    func makeHostAPI(machineID: String) -> BotsHostAPI {
        let dependencies = dependencies
        let previews = previews
        return BotsHostAPI(
            token: persisted.hostToken,
            issueKey: { botID, name in try await dependencies.issueKey(machineID, botID, name) },
            // Sent when the user purges a bot: its key and its library conversations go.
            revokeKey: { botID in
                try dependencies.revokeKey(WovenMCPCaller.bot(machineID: machineID, botID: botID), false)
                try await dependencies.deleteConversations(machineID, botID)
            },
            publishPreview: { botID, port, containerPort in try await previews.publish(botID: botID, port: port, containerPort: containerPort) },
            removePreview: { botID, port in await previews.remove(botID: botID, port: port) },
            inferenceCredential: { provider in try await dependencies.inferenceCredential(provider) },
            recordConversation: { _, batch in try await dependencies.recordConversation(machineID, batch) })
    }

    // MARK: Delivery to bots

    /// Woven MCP deliveries (session events, timers) become messages on the bot's main
    /// channel. The delivery ID makes a retry after a lost acknowledgement safe.
    func deliver(_ notification: WovenBotNotification) async throws {
        let identity = try await resolveIdentity()
        guard notification.machineID == identity.deviceID else { throw BotsError.unavailable("That bot runs on another machine.") }
        let client = try await notifierClient()
        try await client.send(botID: notification.botID, text: notification.text, deliveryID: notification.id)
    }

    private func notifierClient() async throws -> PiBotClient {
        guard persisted.enabled, supervisor?.phase == .running, let port = persisted.runtimePort,
              let url = URL(string: "ws://127.0.0.1:\(port)/ws") else { throw BotsError.unavailable("Bots on this Mac are not running.") }
        if let notifier, await notifier.state == .open { return notifier }
        if let notifier { await notifier.invalidate() }
        let client = PiBotClient(socketURL: url, bearer: persisted.runtimeToken) { _ in }
        notifier = client
        await client.connect()
        for _ in 0..<50 {
            if await client.state == .open { return client }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BotsError.unavailable("Bots on this Mac did not answer.")
    }

    // MARK: Other members (`/v1/bots/*` on this Mac's library server)

    /// The caller is already authorized as a member by the library server.
    func remoteUpgrade(_ request: LibraryHTTPRequest) -> WebSocketUpgradeDecision {
        guard persisted.enabled, supervisor?.phase == .running, let port = persisted.runtimePort.flatMap(UInt16.init(exactly:)),
              let head = WebSocketUpgradeDecision.webSocketHead(for: request, port: port, path: "/ws", bearer: persisted.runtimeToken) else {
            return .reject(.error("unavailable", "Bots on this Mac are not running.", status: 503))
        }
        return .tunnel(port: port, head: head)
    }

    func remoteRequest(_ request: LibraryHTTPRequest, path: String) async -> LibraryHTTPResponse {
        do {
            switch (request.method, path) {
            case ("GET", "/v1/bots/status"):
                return try .json(try await remoteStatus())
            case ("POST", "/v1/bots/engine/update"):
                let identity = try await resolveIdentity()
                _ = try await perform(.updateEngine(machineID: identity.deviceID))
                return try .json(try await remoteStatus())
            case ("POST", "/v1/bots/enabled"):
                struct Body: Decodable { let enabled: Bool }
                let body = try JSONDecoder().decode(Body.self, from: request.body)
                _ = try await perform(.setEnabled(body.enabled))
                return try .json(try await remoteStatus())
            case ("POST", "/v1/bots/resources"):
                struct Body: Decodable { let resources: BotResourceSettings }
                let body = try JSONDecoder().decode(Body.self, from: request.body)
                let identity = try await resolveIdentity()
                _ = try await perform(.setResources(machineID: identity.deviceID, body.resources))
                return try .json(try await remoteStatus())
            default:
                return .error("not_found", "Unknown bots route.", status: 404)
            }
        } catch {
            return .error("failed", error.localizedDescription, status: 400)
        }
    }

    // MARK: Helpers

    private func isThisMac(_ machineID: String) async throws -> Bool {
        try await resolveIdentity().deviceID == machineID.lowercased()
    }

    private func resolveIdentity() async throws -> (deviceID: String, name: String) {
        if let identity { return identity }
        let resolved = try await dependencies.identity()
        let value = (resolved.deviceID.lowercased(), resolved.name)
        identity = value
        return value
    }

    private func changed() { onChange?() }

    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "host.json")
        let data = try JSONEncoder().encode(persisted)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func freeLoopbackPort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw BotsError.unavailable("No loopback port is free for the bots runtime.") }
        defer { close(socket) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw BotsError.unavailable("No loopback port is free for the bots runtime.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func isFree(_ port: Int) -> Bool {
        guard let value = UInt16(exactly: port), value >= 1024 else { return false }
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: value.bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    /// Total memory, and the size and free space of the volume that holds bot storage.
    static func localCapacity(_ directory: URL) async -> BotMachineCapacity {
        let values = try? directory.deletingLastPathComponent().resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return BotMachineCapacity(memoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
                                  diskTotalBytes: Int64(values?.volumeTotalCapacity ?? 0),
                                  diskFreeBytes: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

extension BotMachineCapacity {
    func with(used: Int64?) -> BotMachineCapacity {
        var copy = self; copy.diskUsedByBotsBytes = used ?? copy.diskUsedByBotsBytes; return copy
    }
}

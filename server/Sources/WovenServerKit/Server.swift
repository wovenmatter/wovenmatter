import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol
@_exported import WovenServerCore
#if canImport(Glibc)
import Glibc
#endif

/// The background server of one machine: the only thing that touches its
/// library, the owner of everything that runs there, and the end of every
/// connection from its UI and from other machines.
public final class WovenServer: Sendable {
  public struct Options: Sendable {
    /// Holds `library.sqlite` and the content store.
    public var dataFolder: URL
    /// The Unix socket for the UI on this machine, or nil for none.
    public var socketPath: String?
    /// The TCP address for other machines, or nil for none. Port 0 picks one.
    public var listen: (host: String, port: Int)?
    public var appVersion: String
    /// This machine's name the first time the library is created.
    public var machineName: String
    public var tailnet: any Tailnet
    public var runtimes: [any Runtime]
    /// How often the tailnet is looked at for new machines.
    public var discoveryInterval: Duration
    /// Where new blank folders are made.
    public var foldersRoot: URL
    /// Where this machine's private key and subscription sign-ins are kept;
    /// nil for the Keychain on a Mac and a private file on Linux.
    public var secretStore: (any SecretStore)?
    /// How this machine runs the bots when it is their host; tests give a stand-in.
    var botsHosting: BotsHosting = .standard
    /// The scheduler's clock; tests move it.
    var schedulerClock: @Sendable () -> Date = { Date() }
    /// The runtime that names new chats.
    var titleRuntime: RuntimeKind = .codex
    /// A development instance's name: servers it installs elsewhere are that instance too.
    public var instance: String?
    /// It offers the stand-in runtime, and so do servers it installs.
    public var offersStandIn = false
    /// The home folder whose harness histories (Codex, Claude Code, Grok
    /// Build, OpenCode, the Pi CLI) this server counts usage from; nil for none.
    public var harnessHome: URL?

    public init(dataFolder: URL, socketPath: String?, listen: (host: String, port: Int)?, appVersion: String,
                machineName: String, tailnet: any Tailnet, runtimes: [any Runtime], discoveryInterval: Duration = .seconds(30),
                foldersRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Woven Matter")) {
      self.dataFolder = dataFolder
      self.socketPath = socketPath
      self.listen = listen
      self.appVersion = appVersion
      self.machineName = machineName
      self.tailnet = tailnet
      self.runtimes = runtimes
      self.discoveryInterval = discoveryInterval
      self.foldersRoot = foldersRoot
      self.secretStore = nil
    }
  }

  private let core: ServerCore
  var library: Library { core.library }
  public var hello: Hello { core.hello }
  /// The TCP port other machines reach this server on, when it listens.
  public let port: Int?
  var secretsForTests: Secrets { secrets }
  /// This machine's permanent identifier.
  public var machineID: String { library.machineID }
  private var sessions: SessionManager { core.sessions }
  private let peers: PeerSync
  private let secrets: Secrets
  private let github: GitHub
  let bots: BotsHost
  private let listeners: [Listener]
  private let endpoint: MCPEndpoint
  private let scheduler: Scheduler
  private let keepAwake: KeepAwake
  private let usage: UsageScanner?
  private let connections = Mutex<[UUID: any MessageTransport]>([:])
  private let removal = Mutex<(removed: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
  private let watcher = Mutex<Task<Void, Never>?>(nil)
  let dataFolder: URL
  let socketPath: String?

  public static func start(_ options: Options) async throws -> WovenServer {
    let library = try await Library.open(folder: options.dataFolder, machineName: options.machineName)
    guard let machine = try await library.machine(library.machineID) else {
      throw ProtocolError(.failed, "The library has no row for this machine.")
    }
    let secrets = try await Secrets.open(library: library, store: options.secretStore ?? standardSecretStore(
      dataFolder: options.dataFolder, machineID: library.machineID))
    for runtime in options.runtimes { (runtime as? PiDurableRuntime)?.credentials.attach(secrets) }
    // Before any runtime starts, so every one inherits the git environment.
    let github = try await GitHub.start(library: library, secrets: secrets, dataFolder: options.dataFolder)
    let hello = Hello(role: .server, machine: machine, appVersion: options.appVersion)
    let toolKeys = ToolKeys(socketPath: try SocketFolder.path("tools.sock", for: options.dataFolder))
    let scratch = options.dataFolder.appendingPathComponent("scratch", isDirectory: true)
    let sessions = SessionManager(library: library, runtimes: options.runtimes, scratch: scratch,
                                  toolAccess: toolKeys.access)
    await sessions.start()
    let scheduler = Scheduler(library: library, sessions: sessions, now: options.schedulerClock)
    let peers = PeerSync(library: library, tailnet: options.tailnet, hello: hello, interval: options.discoveryInterval)
    var routes = Router()
    registerDirectories(&routes)
    registerRuntimes(&routes, sessions: sessions, secrets: secrets)
    registerLocalModelServers(&routes, sessions: sessions, secrets: secrets)
    registerSchedules(&routes, library: library, sessions: sessions)
    let databases = Databases(library: library, peers: peers,
                              folder: options.dataFolder.appendingPathComponent("databases", isDirectory: true))
    registerDatabases(&routes, databases: databases)
    registerGitHub(&routes, github: github)
    registerUsage(&routes, library: library, secrets: secrets)
    let bots = BotsHost(library: library, secrets: secrets, peers: peers, dataFolder: options.dataFolder,
                        instance: options.instance, hosting: options.botsHosting)
    registerBots(&routes, bots: bots, library: library, sessions: sessions)
    registerBotsTransfer(&routes, bots: bots)
    let ui = UIToolBroker()
    let tools = WovenTools(library: library, sessions: sessions,
                           catalog: wovenToolCatalog(databases: databases, peers: peers, bots: bots, ui: ui),
                           host: MachineToolsHost(peers: peers, databaseList: databases))
    registerTools(&routes, tools: tools, ui: ui)
    registerOutsideAgents(&routes, keys: toolKeys, library: library)
    await bots.offerTools(tools)
    let endpoint = MCPEndpoint(keys: toolKeys, tools: tools)
    try endpoint.start()
    #if os(macOS)
    let install: LinuxInstall? = LinuxInstall(bundle: LinuxInstall.standardBundle, instance: options.instance,
                                              port: options.listen?.port ?? wovenPort, appVersion: options.appVersion,
                                              standIn: options.offersStandIn)
    #else
    let install: LinuxInstall? = nil
    #endif
    registerMachineInstall(&routes, library: library, peers: peers, tailnet: options.tailnet, install: install)
    registerServerControl(&routes, library: library, sessions: sessions, peers: peers, tailnet: options.tailnet,
                          dataFolder: options.dataFolder, instance: options.instance, install: install)
    let keepAwake = KeepAwake(library: library)
    let usage = options.harnessHome.map { UsageScanner(library: library, home: $0) }
    let core = ServerCore(library: library, hello: hello, sessions: sessions, peers: peers, scratch: scratch,
                          foldersRoot: options.foldersRoot, titleRuntime: options.titleRuntime, routes: routes)
    let pending = PendingServer()
    let tailnet = options.tailnet

    var listeners: [Listener] = []
    do {
      if let path = options.socketPath {
        listeners.append(try await Listener.start(.unix(path: path)) { transport, _ in
          await pending.accept(transport, origin: .local)
        })
      }
      if let listen = options.listen {
        let listener = try await Listener.start(.tcp(host: listen.host, port: listen.port)) { transport, address in
          guard let address, let name = await tailnet.caller(at: address) else {
            transport.close()
            return
          }
          await pending.accept(transport, origin: .tailnet(name: name))
        }
        listeners.append(listener)
        core.listening.address.withLock { $0 = (listen.host, listener.port ?? listen.port) }
      }
    } catch {
      for listener in listeners { await listener.stop() }
      endpoint.stop()
      await sessions.closeAll()
      await github.stop()
      await library.close()
      throw error
    }
    let server = WovenServer(core: core, dataFolder: options.dataFolder, socketPath: options.socketPath,
                             port: listeners.compactMap(\.port).first,
                             peers: peers, secrets: secrets, github: github, bots: bots, listeners: listeners,
                             endpoint: endpoint, scheduler: scheduler, keepAwake: keepAwake, usage: usage)
    pending.server.withLock { $0 = server }
    await peers.start()
    await bots.start()
    await scheduler.start()
    await keepAwake.start(board: sessions.board)
    await usage?.start()
    server.watchLibrary()
    return server
  }

  private init(core: ServerCore, dataFolder: URL, socketPath: String?, port: Int?, peers: PeerSync, secrets: Secrets,
               github: GitHub, bots: BotsHost, listeners: [Listener], endpoint: MCPEndpoint, scheduler: Scheduler,
               keepAwake: KeepAwake, usage: UsageScanner?) {
    self.core = core
    self.keepAwake = keepAwake
    self.usage = usage
    self.dataFolder = dataFolder
    self.socketPath = socketPath
    self.endpoint = endpoint
    self.scheduler = scheduler
    self.port = port
    self.peers = peers
    self.secrets = secrets
    self.github = github
    self.bots = bots
    self.listeners = listeners
  }

  /// Looks at the tailnet for machines now, instead of at the next interval.
  public func discoverMachines() async {
    await peers.discover()
  }

  /// Returns once another machine has removed this one. The server has
  /// stopped serving by then; the caller should stop it and exit. The next
  /// start erases the library and begins as a new machine.
  public func waitUntilRemoved() async {
    await withCheckedContinuation { continuation in
      let done = removal.withLock { state in
        if state.removed { return true }
        state.waiters.append(continuation)
        return false
      }
      if done { continuation.resume() }
    }
  }

  /// Stops listening, closes every connection, stops every runtime process,
  /// and closes the library.
  public func stop() async {
    watcher.withLock { $0?.cancel() }
    await scheduler.stop()
    await keepAwake.stop()
    await usage?.stop()
    for listener in listeners { await listener.stop() }
    endpoint.stop()
    await bots.stop()
    await peers.stop()
    for transport in connections.withLock({ Array($0.values) }) { transport.close() }
    await sessions.closeAll()
    await github.stop()
    // While the library is still held, so no next server has made its sockets yet.
    if let socketPath { unlink(socketPath) }
    SocketFolder.remove(["server.sock", "tools.sock", "agent.sock", "runtime.sock"], for: dataFolder)
    await library.close()
  }

  /// Seals API keys for machines that lack a copy, and notices when this
  /// machine has been removed.
  private func watchLibrary() {
    let changes = library.changes()
    let task = Task { [weak self] in
      await self?.secrets.sealForEveryMachine()
      for await _ in changes { await self?.secrets.sealForEveryMachine() }
      guard let self, self.library.isRemoved else { return }
      for listener in self.listeners { await listener.stop() }
      for transport in self.connections.withLock({ Array($0.values) }) { transport.close() }
      let waiters = self.removal.withLock { state in
        state.removed = true
        defer { state.waiters.removeAll() }
        return state.waiters
      }
      for waiter in waiters { waiter.resume() }
    }
    watcher.withLock { $0 = task }
  }

  fileprivate func serve(_ transport: any MessageTransport, origin: Caller.Origin) async {
    let id = UUID()
    connections.withLock { $0[id] = transport }
    await core.serve(transport, origin: origin)
    _ = connections.withLock { $0.removeValue(forKey: id) }
  }
}

/// Lets listeners started before the server exists hand it connections.
private final class PendingServer: Sendable {
  let server = Mutex<WovenServer?>(nil)

  func accept(_ transport: any MessageTransport, origin: Caller.Origin) async {
    guard let server = server.withLock({ $0 }) else {
      transport.close()
      return
    }
    await server.serve(transport, origin: origin)
  }
}

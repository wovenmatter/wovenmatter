import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol
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
    /// The shape this server says its library has; tests give another.
    var libraryShape = Schema.shape
    /// A development instance's name: servers it installs elsewhere are that instance too.
    public var instance: String?
    /// It offers the stand-in runtime, and so do servers it installs.
    public var offersStandIn = false
    /// The home folder whose harness histories (Codex, Claude Code, Grok
    /// Build, OpenCode, the Pi CLI) this server counts usage from; nil for none.
    public var harnessHome: URL?
    /// It sends anonymous usage statistics. Only a release server does.
    public var sendsAnalytics = false
    /// Where those statistics go; tests give a stand-in.
    var analyticsDelivery: (any AnalyticsDelivery)?

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

  let library: Library
  public let hello: Hello
  /// The TCP port other machines reach this server on, when it listens.
  public let port: Int?
  var secretsForTests: Secrets { secrets }
  var toolKeysForTests: ToolKeys { endpoint.keys }
  /// This machine's permanent identifier.
  public var machineID: String { library.machineID }
  private let sessions: SessionManager
  private let peers: PeerSync
  private let secrets: Secrets
  private let github: GitHub
  let bots: BotsHost
  private let listeners: [Listener]
  private let endpoint: MCPEndpoint
  private let scheduler: Scheduler
  private let titles: Titles
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
    let hello = Hello(role: .server, machine: machine, appVersion: options.appVersion, libraryShape: options.libraryShape)
    let toolKeys = ToolKeys(socketPath: try SocketFolder.path("tools.sock", for: options.dataFolder))
    let sessions = SessionManager(library: library, runtimes: options.runtimes,
                                  scratch: options.dataFolder.appendingPathComponent("scratch", isDirectory: true),
                                  toolKeys: toolKeys)
    await sessions.start()
    let titles = Titles(library: library, sessions: sessions, runtime: options.titleRuntime,
                        scratch: options.dataFolder.appendingPathComponent("scratch", isDirectory: true))
    let scheduler = Scheduler(library: library, sessions: sessions, now: options.schedulerClock)
    let peers = PeerSync(library: library, tailnet: options.tailnet, hello: hello, interval: options.discoveryInterval)
    var routes = makeRouter(library: library, sessions: sessions, peers: peers, appVersion: options.appVersion,
                            libraryShape: options.libraryShape)
    registerFolders(&routes, library: library, root: options.foldersRoot)
    registerRuntimes(&routes, sessions: sessions, secrets: secrets)
    registerLocalModelServers(&routes, sessions: sessions, secrets: secrets)
    registerArtifacts(&routes, library: library, sessions: sessions)
    registerLibraryItems(&routes, library: library)
    registerSchedules(&routes, library: library, sessions: sessions)
    registerGoals(&routes, library: library, sessions: sessions)
    let databases = Databases(library: library, peers: peers,
                              folder: options.dataFolder.appendingPathComponent("databases", isDirectory: true))
    registerDatabases(&routes, databases: databases)
    registerGitHub(&routes, github: github)
    registerUsage(&routes, library: library, secrets: secrets)
    let bots = BotsHost(library: library, secrets: secrets, peers: peers, dataFolder: options.dataFolder,
                        instance: options.instance, hosting: options.botsHosting)
    registerBots(&routes, bots: bots, library: library, sessions: sessions)
    registerBotsTransfer(&routes, bots: bots)
    let tools = WovenTools(library: library, sessions: sessions, databases: databases, peers: peers, bots: bots)
    registerTools(&routes, tools: tools)
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
    let analytics = Analytics(library: library,
                              delivery: options.analyticsDelivery ?? (options.sendsAnalytics ? PostHogDelivery() : nil),
                              appVersion: options.appVersion, settled: { await peers.firstRoundDone })
    registerAnalytics(&routes, analytics: analytics)
    routes.handled = { method, params, caller in analytics.handled(method, params, caller) }
    let router = routes
    let pending = PendingServer()
    let tailnet = options.tailnet

    var listeners: [Listener] = []
    do {
      if let path = options.socketPath {
        listeners.append(try await Listener.start(.unix(path: path)) { transport, _ in
          await pending.accept(transport, origin: .local, router: router, hello: hello)
        })
      }
      if let listen = options.listen {
        listeners.append(try await Listener.start(.tcp(host: listen.host, port: listen.port)) { transport, address in
          guard let address, let name = await tailnet.caller(at: address) else {
            transport.close()
            return
          }
          await pending.accept(transport, origin: .tailnet(name: name), router: router, hello: hello)
        })
      }
    } catch {
      for listener in listeners { await listener.stop() }
      endpoint.stop()
      await sessions.closeAll()
      await github.stop()
      await library.close()
      throw error
    }
    let server = WovenServer(library: library, dataFolder: options.dataFolder, socketPath: options.socketPath,
                             hello: hello, port: listeners.compactMap(\.port).first,
                             sessions: sessions, peers: peers, secrets: secrets, github: github, bots: bots, listeners: listeners,
                             endpoint: endpoint, scheduler: scheduler, titles: titles, keepAwake: keepAwake, usage: usage)
    pending.server.withLock { $0 = server }
    await peers.start()
    await bots.start()
    await scheduler.start()
    await keepAwake.start(board: sessions.board)
    await usage?.start()
    await analytics.start()
    server.watchLibrary()
    return server
  }

  private init(library: Library, dataFolder: URL, socketPath: String?, hello: Hello, port: Int?, sessions: SessionManager, peers: PeerSync, secrets: Secrets,
               github: GitHub, bots: BotsHost, listeners: [Listener], endpoint: MCPEndpoint, scheduler: Scheduler,
               titles: Titles, keepAwake: KeepAwake, usage: UsageScanner?) {
    self.keepAwake = keepAwake
    self.usage = usage
    self.dataFolder = dataFolder
    self.socketPath = socketPath
    self.endpoint = endpoint
    self.scheduler = scheduler
    self.titles = titles
    self.library = library
    self.hello = hello
    self.port = port
    self.sessions = sessions
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

  fileprivate func serve(_ transport: any MessageTransport, origin: Caller.Origin, router: Router, hello: Hello) async {
    let id = UUID()
    connections.withLock { $0[id] = transport }
    await ServerConnection(transport: transport, router: router, origin: origin, hello: hello).run()
    _ = connections.withLock { $0.removeValue(forKey: id) }
  }
}

/// Lets listeners started before the server exists hand it connections.
private final class PendingServer: Sendable {
  let server = Mutex<WovenServer?>(nil)

  func accept(_ transport: any MessageTransport, origin: Caller.Origin, router: Router, hello: Hello) async {
    guard let server = server.withLock({ $0 }) else {
      transport.close()
      return
    }
    await server.serve(transport, origin: origin, router: router, hello: hello)
  }
}

// MARK: Handlers

private func makeRouter(library: Library, sessions: SessionManager, peers: PeerSync, appVersion: String,
                        libraryShape: String) -> Router {
  var router = Router()
  let thisMachine = library.machineID

  router.on(ListMachines.self) { _, _ in
    let statuses = await peers.statuses
    let known = try await library.machines()
    // A machine linked but never synced here (its library has another shape)
    // is listed as it described itself, so it still shows online. One that was
    // removed keeps its deleted row and stays out.
    var linkedOnly: [Machine] = []
    for (id, status) in statuses where status.online && !known.contains(where: { $0.id == id }) {
      if try await library.row("machines", id: id) == nil { linkedOnly.append(status.described) }
    }
    linkedOnly.sort { $0.name < $1.name }
    return (known + linkedOnly).map { machine in
      if machine.id == thisMachine {
        return MachineStatus(machine: machine, isThisMachine: true, online: true, appVersion: appVersion)
      }
      let status = statuses[machine.id]
      return MachineStatus(machine: machine, isThisMachine: false, online: status?.online ?? false,
                           syncs: status?.syncs ?? true, appVersion: status?.appVersion, address: status?.machine.host, port: status?.machine.port)
    }
  }
  router.on(RenameMachine.self) { request, _ in
    try await library.renameMachine(request.machineID ?? thisMachine, to: request.name)
  }

  router.on(ListSessions.self) { request, _ in
    try await library.sessions(machineID: request.machineID, includeArchived: request.includeArchived)
  }
  router.on(CreateSession.self) { request, _ in
    try await sessions.create(runtime: request.runtime, title: request.title, folderID: request.folderID)
  }
  router.on(UpdateSession.self) { request, _ in
    let folder: String?? = request.removeFromFolder == true ? .some(nil) : request.folderID.map { .some($0) }
    return try await library.updateSession(request.sessionID, title: request.title, archived: request.archived,
                                           pinned: request.pinned, read: request.read, folderID: folder)
  }
  router.on(DeleteSession.self) { request, _ in
    await sessions.close(request.sessionID)
    try await library.deleteSession(request.sessionID)
    return Done()
  }
  router.on(SessionItems.self) { request, _ in
    // Every page stops once its size is large, with or without a limit.
    try await library.items(sessionID: request.sessionID, afterSequence: request.afterSequence,
                            beforeSequence: request.beforeSequence, limit: request.limit ?? .max)
  }
  router.subscription(SubscribeSession.self) { request, _ in
    try await sessions.host(for: request.sessionID).subscribe()
  }
  router.subscription(SubscribeRunStates.self) { _, _ in
    let (current, changes) = sessions.board.subscribe()
    return (current, changes.throwing)
  }
  router.on(SendTurn.self) { request, _ in
    // The person's open artifacts and tabs reach the runtime only; the text alone is saved.
    let context = request.context.flatMap { $0.isEmpty ? nil : $0 }
    if let context, context.utf16.count > SendTurn.maximumContextLength {
      throw ProtocolError(.badRequest, "The message context is longer than \(SendTurn.maximumContextLength) characters.")
    }
    try await sessions.host(for: request.sessionID).send(request.text, attachments: request.attachments,
                                                         delivered: context.map { "\($0)\n\n\(request.text)" })
    return Done()
  }
  router.on(ConfigureSession.self) { request, _ in
    try await sessions.host(for: request.sessionID).configure(
      SessionChoices(model: request.model, thinking: request.thinking, permission: request.permission))
  }
  router.on(AnswerPrompt.self) { request, _ in
    try await sessions.host(for: request.sessionID).answer(promptID: request.promptID, with: request.answer)
    return Done()
  }
  router.on(InterruptTurn.self) { request, _ in
    try await sessions.host(for: request.sessionID).interrupt()
    return Done()
  }
  router.on(StopSession.self) { request, _ in
    await sessions.close(request.sessionID)
    return Done()
  }

  router.on(ListSettings.self) { _, _ in
    try await library.settings()
  }
  router.on(SetSetting.self) { request, _ in
    // Only `ChooseBotsHost` and a transfer write where the bots live.
    guard request.key != botsHostSetting else {
      throw ProtocolError(.badRequest, "The bots' host is chosen once, then changed by moving the bots.")
    }
    return try await library.setSetting(request.key, to: request.value)
  }

  router.subscription(SubscribeLibrary.self) { _, _ in
    let changes = library.changes()
    let (events, continuation) = AsyncStream<LibraryEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let first = library.changed
    let forward = Task {
      var last = first
      for await changed in changes {
        let tables = (try? await library.tablesChanged(after: last)) ?? Schema.synced.map(\.name)
        last = changed
        continuation.yield(LibraryEvent(changed: changed, tables: tables))
      }
      continuation.finish()
    }
    continuation.onTermination = { _ in forward.cancel() }
    return (LibraryEvent(changed: first, tables: Schema.synced.map(\.name)), events.throwing)
  }
  router.on(SyncPull.self) { request, caller in
    // Libraries of different shapes do not sync, whatever the releases.
    guard caller.hello.libraryShape == libraryShape else {
      throw ProtocolError(.librariesDiffer, "This machine runs \(appVersion), with a library of another shape.",
                          machineID: thisMachine)
    }
    return try await library.pull(after: request.after, limit: min(max(request.limit, 1), 2000))
  }
  router.on(PutContent.self) { request, _ in
    ContentRef(digest: try await library.storeContent(request.data), size: Int64(request.data.count))
  }
  router.on(FetchContent.self) { request, caller in
    if let chunk = try await library.content(request.digest, offset: request.offset, length: min(request.length, 16 << 20)) {
      return chunk
    }
    // The local UI may ask for content another machine holds.
    if case .local = caller.origin, await peers.fetchContent(request.digest),
       let chunk = try await library.content(request.digest, offset: request.offset, length: min(request.length, 16 << 20)) {
      return chunk
    }
    throw ProtocolError(.notFound, "No content \(request.digest).")
  }
  return router
}

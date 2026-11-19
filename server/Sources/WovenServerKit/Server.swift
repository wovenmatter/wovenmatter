import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

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

    public init(dataFolder: URL, socketPath: String?, listen: (host: String, port: Int)?, appVersion: String,
                machineName: String, tailnet: any Tailnet, runtimes: [any Runtime], discoveryInterval: Duration = .seconds(30)) {
      self.dataFolder = dataFolder
      self.socketPath = socketPath
      self.listen = listen
      self.appVersion = appVersion
      self.machineName = machineName
      self.tailnet = tailnet
      self.runtimes = runtimes
      self.discoveryInterval = discoveryInterval
    }
  }

  public let library: Library
  public let hello: Hello
  /// The TCP port other machines reach this server on, when it listens.
  public let port: Int?
  private let sessions: SessionManager
  private let peers: PeerSync
  private let listeners: [Listener]
  private let connections = Mutex<[UUID: any MessageTransport]>([:])

  public static func start(_ options: Options) async throws -> WovenServer {
    let library = try await Library.open(folder: options.dataFolder, machineName: options.machineName)
    guard let machine = try await library.machine(library.machineID) else {
      throw ProtocolError(.failed, "The library has no row for this machine.")
    }
    let hello = Hello(role: .server, machine: machine, appVersion: options.appVersion)
    let sessions = SessionManager(library: library, runtimes: options.runtimes)
    let peers = PeerSync(library: library, tailnet: options.tailnet, hello: hello, interval: options.discoveryInterval)
    let router = makeRouter(library: library, sessions: sessions, peers: peers, appVersion: options.appVersion)
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
      await library.close()
      throw error
    }
    let server = WovenServer(library: library, hello: hello, port: listeners.compactMap(\.port).first,
                             sessions: sessions, peers: peers, listeners: listeners)
    pending.server.withLock { $0 = server }
    await peers.start()
    return server
  }

  private init(library: Library, hello: Hello, port: Int?, sessions: SessionManager, peers: PeerSync, listeners: [Listener]) {
    self.library = library
    self.hello = hello
    self.port = port
    self.sessions = sessions
    self.peers = peers
    self.listeners = listeners
  }

  /// Looks at the tailnet for machines now, instead of at the next interval.
  public func discoverMachines() async {
    await peers.discover()
  }

  /// Stops listening, closes every connection, stops every runtime process,
  /// and closes the library.
  public func stop() async {
    for listener in listeners { await listener.stop() }
    await peers.stop()
    for transport in connections.withLock({ Array($0.values) }) { transport.close() }
    await sessions.closeAll()
    await library.close()
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

private func makeRouter(library: Library, sessions: SessionManager, peers: PeerSync, appVersion: String) -> Router {
  var router = Router()
  let thisMachine = library.machineID

  router.on(ListMachines.self) { _, _ in
    let statuses = await peers.statuses
    return try await library.machines().map { machine in
      if machine.id == thisMachine {
        return MachineStatus(machine: machine, isThisMachine: true, online: true, appVersion: appVersion)
      }
      let status = statuses[machine.id]
      return MachineStatus(machine: machine, isThisMachine: false, online: status?.online ?? false,
                           appVersion: status?.appVersion)
    }
  }
  router.on(RenameMachine.self) { request, _ in
    try await library.renameMachine(thisMachine, to: request.name)
  }

  router.on(ListSessions.self) { request, _ in
    try await library.sessions(machineID: request.machineID, includeArchived: request.includeArchived)
  }
  router.on(CreateSession.self) { request, _ in
    guard await sessions.supports(request.runtime) else {
      throw ProtocolError(.badRequest, "This machine has no \(request.runtime.rawValue) runtime.")
    }
    if let folderID = request.folderID {
      guard let folder = try await library.folder(folderID) else { throw ProtocolError(.notFound, "No folder \(folderID).") }
      guard folder.machineID == thisMachine else {
        throw ProtocolError(.notOwner, "That folder is on another machine.", machineID: folder.machineID)
      }
    }
    return try await library.createSession(runtime: request.runtime, title: request.title, folderID: request.folderID)
  }
  router.on(UpdateSession.self) { request, _ in
    let folder: String?? = request.removeFromFolder == true ? .some(nil) : request.folderID.map { .some($0) }
    return try await library.updateSession(request.sessionID, title: request.title, archived: request.archived, folderID: folder)
  }
  router.on(DeleteSession.self) { request, _ in
    await sessions.close(request.sessionID)
    try await library.deleteSession(request.sessionID)
    return Done()
  }
  router.on(SessionItems.self) { request, _ in
    try await library.items(sessionID: request.sessionID, afterSequence: request.afterSequence, limit: request.limit)
  }
  router.subscription(SubscribeSession.self) { request, _ in
    try await sessions.host(for: request.sessionID).subscribe()
  }
  router.on(SendTurn.self) { request, _ in
    try await sessions.host(for: request.sessionID).send(request.text)
    return Done()
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

  router.on(ListFolders.self) { request, _ in
    try await library.folders(machineID: request.machineID)
  }
  router.on(CreateFolder.self) { request, _ in
    try await library.createFolder(name: request.name, path: request.path)
  }
  router.on(RenameFolder.self) { request, _ in
    try await library.renameFolder(request.folderID, to: request.name)
  }
  router.on(DeleteFolder.self) { request, _ in
    try await library.deleteFolder(request.folderID)
    return Done()
  }

  router.on(ListSettings.self) { _, _ in
    try await library.settings()
  }
  router.on(SetSetting.self) { request, _ in
    try await library.setSetting(request.key, to: request.value)
  }

  router.subscription(SubscribeLibrary.self) { _, _ in
    let changes = library.changes()
    let (events, continuation) = AsyncStream<LibraryEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let forward = Task {
      for await changed in changes { continuation.yield(LibraryEvent(changed: changed)) }
      continuation.finish()
    }
    continuation.onTermination = { _ in forward.cancel() }
    return (LibraryEvent(changed: library.changed), events)
  }
  router.on(SyncPull.self) { request, caller in
    // Two machines on different app releases do not sync.
    guard caller.hello.appVersion == appVersion else {
      throw ProtocolError(.versionMismatch, "This machine runs \(appVersion).", machineID: thisMachine)
    }
    return try await library.pull(after: request.after, limit: min(max(request.limit, 1), 2000))
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

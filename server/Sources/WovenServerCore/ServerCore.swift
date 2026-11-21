import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

/// Where the core finds the other machines. On a machine these are its links
/// to the other servers; on a device, the connections it opened to servers.
public protocol Peers: Sendable {
  /// Each other machine reached, by its identifier, as it was last reached.
  func reached() async -> [String: PeerStatus]
  /// Fetches a file this library lacks from a machine that holds it, into
  /// the content store; true when it did.
  func fetchContent(_ digest: String) async -> Bool
}

/// Another machine as a host last reached it.
public struct PeerStatus: Sendable, Hashable {
  public var online: Bool
  public var appVersion: String
  /// Where its server answered on the tailnet.
  public var address: String
  public var port: Int

  public init(online: Bool, appVersion: String, address: String, port: Int) {
    self.online = online
    self.appVersion = appVersion
    self.address = address
    self.port = port
  }
}

/// Where this server listens on the tailnet, once it does.
package final class Listening: Sendable {
  package let address = Mutex<(host: String, port: Int)?>(nil)
  package init() {}
}

/// The server's portable core: it serves connections, the library and the
/// sessions this host owns, behind the runtime interface. A machine's server
/// is this core with the parts that need a machine added; a device runs it
/// in the app, listening on nothing, and hands it each connection.
public final class ServerCore: Sendable {
  public let library: Library
  /// What it says first to every client: role `server`, this host's row in
  /// `machines` and the app version.
  public let hello: Hello
  package let sessions: SessionManager
  package let listening = Listening()
  private let router: Router
  private let titles: Titles

  /// Starts the core alone, as a device runs it. `library` is opened by the
  /// caller (on a device with the device's platform) and closed by it after
  /// `stop`. Scratch directories and new folders go in `dataFolder`. With
  /// `titleRuntime`, new chats are named by that runtime when titles are on.
  /// `routes` are the host's own, served on top of the core's: one for a
  /// method the core also serves replaces the core's, as on a machine.
  public static func start(library: Library, appVersion: String, runtimes: [any Runtime], dataFolder: URL,
                           peers: any Peers, titleRuntime: RuntimeKind? = nil,
                           routes: Router = Router()) async throws -> ServerCore {
    guard let machine = try await library.machine(library.machineID) else {
      throw ProtocolError(.failed, "The library has no row for this machine.")
    }
    let scratch = dataFolder.appendingPathComponent("scratch", isDirectory: true)
    let sessions = SessionManager(library: library, runtimes: runtimes, scratch: scratch)
    // No bridge here: each session's runtime takes the core's tools in this process.
    sessions.inProcessTools.attach(WovenTools(library: library, sessions: sessions, catalog: coreTools + goalTools, host: nil))
    await sessions.start()
    return ServerCore(library: library, hello: Hello(role: .server, machine: machine, appVersion: appVersion),
                      sessions: sessions, peers: peers, scratch: scratch,
                      foldersRoot: dataFolder.appendingPathComponent("folders", isDirectory: true),
                      titleRuntime: titleRuntime, routes: routes)
  }

  /// The core with `routes`, a machine's own, served beside the core's. A
  /// handler in `routes` for a method the core also serves replaces the core's.
  package init(library: Library, hello: Hello, sessions: SessionManager, peers: any Peers, scratch: URL, foldersRoot: URL,
               titleRuntime: RuntimeKind?, routes: Router) {
    self.library = library
    self.hello = hello
    self.sessions = sessions
    var all = Router()
    registerCore(&all, library: library, sessions: sessions, peers: peers, appVersion: hello.appVersion,
                 listening: listening)
    registerFolders(&all, library: library, root: foldersRoot)
    registerArtifacts(&all, library: library, sessions: sessions)
    registerLibraryItems(&all, library: library)
    registerGoals(&all, library: library, sessions: sessions)
    registerRuntimeList(&all, sessions: sessions)
    registerUsageHistory(&all, library: library)
    all.add(routes)
    router = all
    titles = Titles(library: library, sessions: sessions, runtime: titleRuntime, scratch: scratch)
  }

  /// Serves one connection until it closes: the client's hello, then its
  /// requests and subscriptions. `origin` is `.local` for the UI on this host.
  public func serve(_ transport: any MessageTransport, origin: Caller.Origin) async {
    await ServerConnection(transport: transport, router: router, origin: origin, hello: hello).run()
  }

  /// Stops every runtime process. The library stays open.
  public func stop() async {
    await sessions.closeAll()
  }
}

// MARK: Handlers

/// The routes every host serves the same way: the library, sessions on this
/// host, sync and content.
private func registerCore(_ router: inout Router, library: Library, sessions: SessionManager, peers: any Peers,
                          appVersion: String, listening: Listening) {
  let thisMachine = library.machineID
  /// Two machines on different app releases do not sync.
  @Sendable func checkRelease(_ caller: Caller) throws {
    guard caller.hello.appVersion == appVersion else {
      throw ProtocolError(.versionMismatch, "This machine runs \(appVersion).", machineID: thisMachine)
    }
  }
  /// The device on the other end, for the requests only a device makes.
  @Sendable func device(_ caller: Caller) throws -> String {
    guard caller.hello.role == .device, caller.hello.machine.id != thisMachine else {
      throw ProtocolError(.refused, "Only an iPhone or iPad hands its rows to a server.")
    }
    try checkRelease(caller)
    return caller.hello.machine.id
  }

  router.on(ListMachines.self) { _, _ in
    let statuses = await peers.reached()
    return try await library.machines().map { machine in
      if machine.id == thisMachine {
        let address = listening.address.withLock { $0 }
        return MachineStatus(machine: machine, isThisMachine: true, online: true, appVersion: appVersion,
                             address: address?.host, port: address?.port)
      }
      let status = statuses[machine.id]
      return MachineStatus(machine: machine, isThisMachine: false, online: status?.online ?? false,
                           appVersion: status?.appVersion, address: status?.address, port: status?.port)
    }
  }
  router.on(ListDevices.self) { _, _ in
    var devices: [DeviceStatus] = []
    for device in try await library.devices() {
      devices.append(DeviceStatus(device: device, lastSyncedAt: try await library.lastReceived(from: device.id)))
    }
    return devices
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
                                           pinned: request.pinned, read: request.read, folderID: folder,
                                           tools: request.tools)
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

  // The bots' chats and Forum as saved in the library, for reading while
  // their host is away.
  router.on(ListSavedBots.self) { _, _ in
    try await library.savedBots()
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
    try checkRelease(caller)
    return try await library.pull(after: request.after, limit: min(max(request.limit, 1), 2000))
  }
  // A device cannot be dialed, so it hands its rows over its own connection.
  // The server keeps the cursor, as it does for what it pulls, and announces
  // what changed exactly as after a pull.
  router.on(SyncCursor.self) { _, caller in
    try await library.cursor(for: try device(caller))
  }
  router.on(SyncPush.self) { request, caller in
    try await library.apply(request.page, from: try device(caller))
    return Done()
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
}

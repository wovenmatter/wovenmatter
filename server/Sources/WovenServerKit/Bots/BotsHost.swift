import Foundation
import WovenLibrary
import WovenProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The bots on this server, one per server. Watches the setting `bots.home`:
///
/// - When it names this machine, prepares the container engine, writes
///   `D/bots-runtime/config.json`, starts the runtime and keeps it running
///   (restarting with backoff up to 30 s), and is the runtime's only client
///   over its Unix socket: requests pass through, pushes fan out to
///   subscribers, and the runtime's `host` requests are answered here.
/// - When it names another machine, follows that machine's server for its
///   status and forwards calls to it (an agent here calls through the Woven
///   MCP). Subscriptions are refused with `notOwner`: a UI connects to the
///   home machine's server directly.
/// - When it is unset, the bots are off.
///
/// A transfer (`BotsTransfer.swift`) holds the bots apart from the setting
/// while it runs: stopped on the old home, running on the target before the
/// switch.
actor BotsHost {
  typealias Events = AsyncThrowingStream<BotsEvent, any Error>

  /// How many events wait for a slow subscriber before it is ended.
  static let subscriberBuffer = 4096

  private enum Pending {
    case call(CheckedContinuation<JSONValue, any Error>)
    /// A `conversation.open` or `forum.open` for the subscriber `id`.
    case open(UUID, request: JSONValue, CheckedContinuation<JSONValue, any Error>)
    /// A close whose reply nobody waits for.
    case ignored
  }

  /// One conversation or Forum room open in the runtime, shared by every
  /// subscriber to it: the runtime keeps one subscription per conversation
  /// for its one client, under the latest open's id.
  private struct Opened {
    var subscribers: Set<UUID>
    var subscriptionID: String
    var close: [String: JSONValue]
  }

  /// Where a transfer holds the bots, apart from the setting.
  enum Hold: Equatable {
    /// The old home: the bots are stopped here while they move to `target`.
    case sending(target: String)
    /// The target: the bots run here before the switch.
    case receiving(source: String)
    /// The old home after the switch, until it has removed its copy.
    case moved(target: String)
  }

  let library: Library
  let peers: PeerSync
  private let interface: BotsHostInterface
  let tenure: BotsTenure
  let hosting: BotsHosting
  let engine: any BotsEngine
  let dataFolder: URL
  var thisMachine: String { library.machineID }

  /// Where the bots run, as this server acts on it: the setting, unless a transfer holds them.
  private(set) var home: String?
  /// The setting `bots.home`. A transfer sets it as soon as it writes it.
  var setting: String?
  var hold: Hold?
  private(set) var resources = BotsResources.defaults
  private(set) var status = BotsStatus(homeMachineID: nil, state: .off)
  private var watcher: Task<Void, Never>?
  private var supervisor: Task<Void, Never>?
  private var relay: Task<Void, Never>?
  private var capacity: BotsCapacity?
  /// The container engine was started here and not stopped since.
  var engineStarted = false
  // A transfer this server runs, sends or receives (`BotsTransfer.swift`).
  var outgoing: Task<Void, any Error>?
  /// When the old home last asked the target anything but to give back.
  var lastAsked = ContinuousClock.now
  var incoming: IncomingTransfer?
  var watchdog: Task<Void, Never>?
  /// The target giving a transfer back, or a restart ending one.
  var ending: Task<Void, Never>?
  var endings = 0

  // The connection to this machine's runtime.
  private var connection: (transport: any MessageTransport, generation: Int)?
  private var generation = 0
  private var nextID = 0
  private var pending: [String: Pending] = [:]
  private var restartRequested = false
  private var runningConfig: BotsRuntimeConfig?

  // Subscribers on this server.
  private var everyone: [UUID: Events.Continuation] = [:]
  private var waitingOpens: [UUID: Events.Continuation] = [:]
  private var openSubscribers: [UUID: (key: String, continuation: Events.Continuation)] = [:]
  private var opened: [String: Opened] = [:]

  init(library: Library, secrets: Secrets, peers: PeerSync, dataFolder: URL, hosting: BotsHosting = .standard) {
    self.library = library
    self.peers = peers
    self.tenure = BotsTenure(file: dataFolder.appendingPathComponent("bots-runtime/tenure"))
    self.interface = BotsHostInterface(library: library, secrets: secrets, tenure: tenure)
    self.hosting = hosting
    self.engine = hosting.engine(dataFolder)
    self.dataFolder = dataFolder
  }

  var runtimeFolder: URL { dataFolder.appendingPathComponent("bots-runtime", isDirectory: true) }
  var botsFolder: URL { dataFolder.appendingPathComponent("bots", isDirectory: true) }
  var configURL: URL { runtimeFolder.appendingPathComponent("config.json") }
  private var logURL: URL { runtimeFolder.appendingPathComponent("runtime.log") }

  /// The Woven MCP, offered to the bots when this machine is their home.
  func offerTools(_ tools: WovenTools) {
    interface.tools.attach(tools)
  }

  // MARK: Lifetime

  func start() {
    guard watcher == nil else { return }
    recoverTransfer()
    let changes = library.changes()
    watcher = Task { [weak self] in
      await self?.settingsChanged()
      for await _ in changes { await self?.settingsChanged() }
    }
  }

  func stop() async {
    watcher?.cancel()
    watcher = nil
    watchdog?.cancel()
    watchdog = nil
    home = nil
    await leaveHome()
    await releaseEngine()
    for continuation in everyone.values { continuation.finish() }
    everyone.removeAll()
  }

  private func settingsChanged() async {
    let stored = ((try? await library.setting(botsHomeSetting)) ?? nil)?.value
    let newSetting = stored?.string.flatMap { $0.isEmpty ? nil : $0 }
    let newResources = ((try? await library.setting(BotsResources.setting)) ?? nil)
      .flatMap { try? $0.value.decode(BotsResources.self) } ?? .defaults
    guard !Task.isCancelled else { return }
    setting = newSetting
    let moved = desiredHome != home
    if moved || newResources != resources {
      let changed = newResources != resources
      resources = newResources
      if moved { await reconcileHome() } else if changed, home == thisMachine { await resourcesChanged() }
    }
  }

  /// Where the bots should run now: the setting, unless a transfer holds them.
  private var desiredHome: String? {
    switch hold {
    case .receiving: thisMachine
    case .moved(let target): target
    case .sending, nil: setting
    }
  }

  /// Whether this machine's runtime should run: it is home and no transfer stopped it.
  private var runsHere: Bool {
    if case .sending = hold { return false }
    return desiredHome == thisMachine
  }

  /// Moves to the home the setting and any transfer name, starting or
  /// stopping this machine's runtime to match.
  func reconcileHome(keepEngine: Bool? = nil) async {
    let desired = desiredHome
    if desired == home, (home != thisMachine) || (runsHere == (supervisor != nil)) {
      if home == thisMachine, !runsHere, status.state != .transferring { setStatus(localStatus(.transferring)) }
      return
    }
    // The engine stays up while the bots stay here: a transfer still needs it.
    await leaveHome(keepEngine: keepEngine ?? (desired == thisMachine))
    home = desired
    enterHome()
  }

  private func enterHome() {
    guard let home else {
      setStatus(BotsStatus(homeMachineID: nil, state: .off))
      return
    }
    if home == thisMachine {
      guard runsHere else {
        setStatus(localStatus(.transferring, transfer: status.transfer))
        return
      }
      setStatus(localStatus(.starting))
      supervisor = Task { await self.supervise() }
    } else {
      setStatus(BotsStatus(homeMachineID: home, state: .unreachable))
      relay = Task { await self.follow(home) }
    }
  }

  /// Stops following another home, or this machine's runtime. The engine is
  /// stopped too unless `keepEngine`.
  func leaveHome(keepEngine: Bool = false) async {
    if let relay {
      relay.cancel()
      await relay.value
      self.relay = nil
    }
    if let supervisor {
      supervisor.cancel()
      await supervisor.value
      self.supervisor = nil
    }
    if !keepEngine { await releaseEngine() }
  }

  /// Starts the engine (or finds it running) and writes the runtime's config, for a transfer.
  func prepareEngine() async throws {
    let socket = try await engine.prepare(resources)
    engineStarted = true
    _ = try prepareConfig(engineSocket: socket)
  }

  func releaseEngine() async {
    guard engineStarted else { return }
    engineStarted = false
    await engine.stop()
  }

  /// New limits: the engine takes them now; a changed per-bot limit restarts the runtime.
  private func resourcesChanged() async {
    try? await engine.apply(resources)
    if let runningConfig, runningConfig.limits.botMemoryBytes != resources.perBotBytes, let connection {
      restartRequested = true
      connection.transport.close()
    }
  }

  // MARK: Supervision (this machine is home)

  private func supervise() async {
    var failures = 0
    while !Task.isCancelled {
      let began = ContinuousClock.now
      let message: String
      do {
        setStatus(localStatus(.starting))
        let engineSocket = try await engine.prepare(resources)
        engineStarted = true
        try Task.checkCancellation()
        let config = try prepareConfig(engineSocket: engineSocket)
        unlink(config.socket)
        let process = try hosting.launch(configURL, logURL)
        runningConfig = config
        message = await run(process, socket: config.socket)
      } catch is CancellationError {
        break
      } catch {
        message = ProtocolError(error).message
      }
      runningConfig = nil
      if Task.isCancelled { break }
      if restartRequested {
        restartRequested = false
        failures = 0
        continue
      }
      if ContinuousClock.now - began > .seconds(60) { failures = 0 }
      failures += 1
      setStatus(localStatus(.failed, message: message))
      try? await Task.sleep(for: .seconds(min(1 << min(failures - 1, 5), 30)))
    }
    runningConfig = nil
  }

  private func prepareConfig(engineSocket: String) throws -> BotsRuntimeConfig {
    let manager = FileManager.default
    try manager.createDirectory(at: runtimeFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeFolder.path)
    let bots = dataFolder.appendingPathComponent("bots", isDirectory: true)
    let pi = dataFolder.appendingPathComponent("pi-durable", isDirectory: true)
    try manager.createDirectory(at: bots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.createDirectory(at: pi, withIntermediateDirectories: true)
    let socketPath = try SocketFolder.path("runtime.sock", for: dataFolder)
    let config = BotsRuntimeConfig(
      dataDir: bots.path, socket: socketPath, engine: .init(socket: engineSocket, kind: engine.kind),
      image: .init(tag: "wovenmatter-bots"), limits: .init(botMemoryBytes: resources.perBotBytes),
      piDurable: .init(bundle: Resources.defaultAgent.path, directory: pi.path))
    try config.write(to: configURL)
    return config
  }

  /// Connects to a started runtime and serves it until it or the connection
  /// ends. Returns what to say about the end; the process is stopped by then.
  private func run(_ process: any BotsRuntimeProcess, socket: String) async -> String {
    let transport: (any MessageTransport)? = await withTaskGroup(of: (any MessageTransport)?.self) { group in
      group.addTask {
        await process.exited()
        return nil
      }
      group.addTask {
        // It listens once it has opened its database; that can take a while.
        for _ in 0..<1200 where !Task.isCancelled {
          if let transport = try? await connectWebSocket(.unix(path: socket)) { return transport }
          try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      for await late in group { late?.close() }
      return first
    }
    guard let transport else {
      await process.stop()
      return "The bots runtime did not start. Its log is \(logURL.path)."
    }
    generation += 1
    let current = generation
    connection = (transport, current)
    capacity = await engine.capacity()
    setStatus(localStatus(.ready))
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await process.exited() }
      group.addTask {
        do {
          for try await text in transport.incoming { await self.received(text, generation: current) }
        } catch {}
      }
      _ = await group.next()
      group.cancelAll()
    }
    transport.close()
    endConnection(current)
    await process.stop()
    return "The bots runtime stopped. Restarting…"
  }

  /// The connection ended: every waiting request fails and every opened
  /// conversation ends (subscribers open it again).
  private func endConnection(_ ended: Int) {
    guard connection?.generation == ended else { return }
    connection = nil
    let failed = pending
    pending.removeAll()
    for waiting in failed.values {
      switch waiting {
      case .call(let continuation), .open(_, _, let continuation):
        continuation.resume(throwing: ProtocolError(.failed, "The bots runtime stopped."))
      case .ignored: break
      }
    }
    let ending = Array(openSubscribers.values.map(\.continuation)) + Array(waitingOpens.values)
    openSubscribers.removeAll()
    waitingOpens.removeAll()
    opened.removeAll()
    for continuation in ending { continuation.finish() }
  }

  func localStatus(_ state: BotsState, message: String? = nil, transfer: BotsTransferProgress? = nil) -> BotsStatus {
    BotsStatus(homeMachineID: thisMachine, state: state, message: message, engine: engine.kind,
               capacity: state == .ready ? capacity : nil, transfer: transfer)
  }

  func setStatus(_ new: BotsStatus) {
    guard new != status else { return }
    status = new
    let event = BotsEvent.status(new)
    for continuation in everyone.values { deliver(event, to: continuation) }
    for subscriber in openSubscribers.values { deliver(event, to: subscriber.continuation) }
  }

  // MARK: The runtime's messages

  private func received(_ text: String, generation current: Int) {
    guard connection?.generation == current,
          let message = try? Wire.decoder.decode(JSONValue.self, from: Data(text.utf8)) else { return }
    switch message["type"]?.string {
    case "result", "error":
      guard let id = Self.idText(message["id"]), let waiting = pending.removeValue(forKey: id) else { return }
      let failure = message["type"]?.string == "error"
        ? ProtocolError(.failed, message["message"]?.string ?? "The bots runtime refused that.") : nil
      switch waiting {
      case .call(let continuation):
        if let failure { continuation.resume(throwing: failure) } else { continuation.resume(returning: message["data"] ?? .null) }
      case .open(let subscriber, let request, let continuation):
        if let failure {
          waitingOpens.removeValue(forKey: subscriber)
          continuation.resume(throwing: failure)
          return
        }
        let data = message["data"] ?? .null
        opened(subscriber, request: request, id: id, data: data)
        continuation.resume(returning: data)
      case .ignored:
        break
      }
    case "host":
      guard let id = message["id"], let method = message["method"]?.string, let transport = connection?.transport else { return }
      let params = message["params"] ?? .object([:])
      let interface = interface
      Task {
        let reply: JSONValue
        do {
          reply = .object(["type": .string("host.result"), "id": id, "data": try await interface.handle(method, params)])
        } catch {
          reply = .object(["type": .string("host.error"), "id": id, "message": .string(ProtocolError(error).message)])
        }
        if let text = try? String(decoding: Wire.encoder.encode(reply), as: UTF8.self) { try? transport.send(text) }
      }
    default:
      route(message)
    }
  }

  /// A push goes to those who opened its conversation or room; the rest to everyone.
  private func route(_ message: JSONValue) {
    let key: String? = switch message["type"]?.string {
    case "event": message["botId"]?.string.flatMap { bot in message["conversationId"]?.int.map { "c:\(bot):\($0)" } }
    case "forum.post": message["post"]?["roomId"]?.int.map { "f:\($0)" }
    case "forum.thinking": message["roomId"]?.int.map { "f:\($0)" }
    default: nil
    }
    let event = BotsEvent.message(message)
    guard let key else {
      for continuation in everyone.values { deliver(event, to: continuation) }
      return
    }
    for id in opened[key]?.subscribers ?? [] {
      if let subscriber = openSubscribers[id] { deliver(event, to: subscriber.continuation) }
    }
  }

  /// Hands an event over without waiting; a subscriber too far behind is ended.
  private func deliver(_ event: BotsEvent, to continuation: Events.Continuation) {
    if case .dropped = continuation.yield(event) { continuation.finish(throwing: SubscriberTooSlow()) }
  }

  /// An open's reply arrived: its subscriber now hears that conversation.
  private func opened(_ subscriber: UUID, request: JSONValue, id: String, data: JSONValue) {
    let key: String, close: [String: JSONValue]
    if request["type"]?.string == "forum.open" {
      guard let room = data["roomId"]?.int ?? request["roomId"]?.int else { return }
      key = "f:\(room)"
      close = ["type": .string("forum.close"), "roomId": .integer(Int64(room))]
    } else {
      guard let bot = data["botId"]?.string ?? request["botId"]?.string,
            let conversation = data["conversationId"]?.int else { return }
      key = "c:\(bot):\(conversation)"
      close = ["type": .string("conversation.close"), "botId": .string(bot), "conversationId": .integer(Int64(conversation))]
    }
    var entry = opened[key] ?? Opened(subscribers: [], subscriptionID: id, close: close)
    entry.subscriptionID = id
    if let continuation = waitingOpens.removeValue(forKey: subscriber) {
      entry.subscribers.insert(subscriber)
      openSubscribers[subscriber] = (key, continuation)
    }
    opened[key] = entry
    if entry.subscribers.isEmpty { closeInRuntime(key) }
  }

  private func closeInRuntime(_ key: String) {
    guard let entry = opened.removeValue(forKey: key) else { return }
    var close = entry.close
    close["subscriptionId"] = .string(entry.subscriptionID)
    _ = try? send(.object(close), .ignored)
  }

  /// A subscriber ended. The last to leave an opened conversation closes it.
  private func left(_ id: UUID) {
    everyone.removeValue(forKey: id)
    waitingOpens.removeValue(forKey: id)
    guard let subscriber = openSubscribers.removeValue(forKey: id) else { return }
    opened[subscriber.key]?.subscribers.remove(id)
    if opened[subscriber.key]?.subscribers.isEmpty == true { closeInRuntime(subscriber.key) }
  }

  /// Sends a request to the runtime under a fresh id, and returns that id.
  @discardableResult
  private func send(_ request: JSONValue, _ waiting: Pending) throws -> String {
    guard let connection else { throw ProtocolError(.failed, notReadyMessage) }
    guard case .object(var fields) = request, fields["type"]?.string != nil else {
      throw ProtocolError(.badRequest, "A bots request is a JSON object with a type.")
    }
    nextID += 1
    let id = "w\(nextID)"
    fields["id"] = .string(id)
    pending[id] = waiting
    do {
      try connection.transport.send(String(decoding: try Wire.encoder.encode(JSONValue.object(fields)), as: UTF8.self))
    } catch {
      pending[id] = nil
      throw ProtocolError(.failed, "The bots runtime stopped.")
    }
    return id
  }

  private var notReadyMessage: String {
    switch status.state {
    case .starting: "The bots are starting."
    case .transferring: "The bots are moving to another machine."
    case .failed: status.message ?? "The bots runtime is not running."
    default: "The bots runtime is not running."
    }
  }

  private static func idText(_ id: JSONValue?) -> String? {
    switch id {
    case .string(let text)?: text
    case .integer(let number)?: String(number)
    default: nil
    }
  }

  // MARK: Requests

  /// `BotsCall`: run here when this machine is home, else on the home machine's server.
  func call(_ request: JSONValue, caller: Caller) async throws -> JSONValue {
    guard let home else { throw ProtocolError(.failed, "No machine runs the bots.") }
    let type = request["type"]?.string
    if ["conversation.open", "conversation.close", "forum.open", "forum.close"].contains(type) {
      throw ProtocolError(.badRequest, "\(type ?? "") goes through SubscribeBots.")
    }
    if home == thisMachine {
      return try await withCheckedThrowingContinuation { continuation in
        do { try send(request, .call(continuation)) } catch { continuation.resume(throwing: error) }
      }
    }
    let client = try await homeClient(home, caller: caller)
    do {
      return try await client.call(BotsCall(request: request))
    } catch let error as ProtocolError {
      throw error
    } catch {
      throw await unreachable(home)
    }
  }

  /// `SubscribeBots`: the status and the messages for everyone, or with
  /// `open` that conversation or Forum room. Only the home machine's server
  /// answers: a UI connects to it directly, and no server relays its stream.
  func subscribe(open: JSONValue?, caller: Caller) async throws -> (BotsOpened, Events) {
    if let home, home != thisMachine {
      throw ProtocolError(.notOwner, "This machine does not run the bots.", machineID: home)
    }
    guard let open else {
      let (events, continuation) = makeStream()
      everyone[continuation.id] = continuation.continuation
      return (BotsOpened(status: status), events)
    }
    guard home != nil else { return (BotsOpened(status: status), Self.ended) }
    guard connection != nil, ["conversation.open", "forum.open"].contains(open["type"]?.string) else {
      if connection != nil { throw ProtocolError(.badRequest, "open is a conversation.open or forum.open request.") }
      return (BotsOpened(status: status), Self.ended)
    }
    let (events, continuation) = makeStream()
    waitingOpens[continuation.id] = continuation.continuation
    do {
      let snapshot = try await withCheckedThrowingContinuation { (reply: CheckedContinuation<JSONValue, any Error>) in
        do { try send(open, .open(continuation.id, request: open, reply)) } catch { reply.resume(throwing: error) }
      }
      return (BotsOpened(status: status, opened: snapshot), events)
    } catch {
      waitingOpens.removeValue(forKey: continuation.id)
      continuation.continuation.finish()
      throw error
    }
  }

  private static var ended: Events { Events { $0.finish() } }

  private func makeStream() -> (Events, (id: UUID, continuation: Events.Continuation)) {
    let id = UUID()
    let (events, continuation) = Events.makeStream(bufferingPolicy: .bufferingOldest(Self.subscriberBuffer))
    continuation.onTermination = { [weak self] _ in Task { await self?.left(id) } }
    return (events, (id, continuation))
  }

  // MARK: Another machine is home

  private func homeClient(_ home: String, caller: Caller) async throws -> Client {
    // A request another server sent here is never sent on again.
    guard caller.hello.role != .server else {
      throw ProtocolError(.notOwner, "This machine does not run the bots.", machineID: home)
    }
    guard let client = await peers.client(for: home) else { throw await unreachable(home) }
    return client
  }

  private func unreachable(_ home: String) async -> ProtocolError {
    let name = (try? await library.machine(home))?.name ?? home
    return ProtocolError(.ownerUnreachable, "\(name) runs the bots and is not reachable.", machineID: home)
  }

  /// Follows the home machine's server: its status, and its messages for
  /// everyone, for this server's subscribers. Reconnects while it is home.
  private func follow(_ home: String) async {
    while !Task.isCancelled {
      if let client = await peers.client(for: home),
         let subscription = try? await client.subscribe(SubscribeBots()) {
        setStatus(subscription.reply.status)
        do {
          for try await event in subscription.events {
            switch event {
            case .status(let status): setStatus(status)
            case .message: for continuation in everyone.values { deliver(event, to: continuation) }
            }
          }
        } catch {}
        if Task.isCancelled { try? await client.unsubscribe(subscription.id) }
      }
      guard !Task.isCancelled else { return }
      let name = (try? await library.machine(home))?.name ?? home
      setStatus(BotsStatus(homeMachineID: home, state: .unreachable, message: "\(name) is not reachable."))
      try? await Task.sleep(for: .seconds(1))
    }
  }
}

// MARK: Routes

func registerBots(_ router: inout Router, bots: BotsHost, library: Library, sessions: SessionManager) {
  router.on(BotsCall.self) { request, caller in
    try await bots.call(request.request, caller: caller)
  }
  router.subscription(SubscribeBots.self) { request, caller in
    try await bots.subscribe(open: request.open, caller: caller)
  }
  router.on(ListSavedBots.self) { _, _ in
    try await library.savedBots()
  }
  // A bot chat's title is the runtime's (the bot's name, a thread's title),
  // so renaming one goes to the runtime, and its next push brings the title
  // here. Other changes are the library's alone. Replaces the general handler.
  router.on(UpdateSession.self) { request, caller in
    if let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
       let chat = try await library.savedBots().chats.first(where: { $0.session.id == request.sessionID }) {
      let rename: JSONValue = switch chat.kind {
      case .main: .object(["type": .string("bots.rename"), "botId": .string(chat.botID ?? ""), "name": .string(title)])
      case .thread: .object(["type": .string("thread.setTitle"), "botId": .string(chat.botID ?? ""),
                             "conversationId": .integer(Int64(chat.conversationID)), "title": .string(title)])
      case .forumThread: .object(["type": .string("forum.thread.setTitle"), "roomId": .integer(Int64(chat.conversationID)),
                                  "title": .string(title)])
      case .forum: throw ProtocolError(.badRequest, "The Forum keeps its name.")
      }
      _ = try await bots.call(rename, caller: caller)
    }
    let isBotChat = try await library.session(request.sessionID)?.runtime == .bots
    let folder: String?? = request.removeFromFolder == true ? .some(nil) : request.folderID.map { .some($0) }
    return try await library.updateSession(request.sessionID, title: isBotChat ? nil : request.title, archived: request.archived,
                                           pinned: request.pinned, read: request.read, folderID: folder,
                                           tools: request.tools)
  }
  // A bot chat is deleted in the runtime first, so it is gone at the source
  // and the bots never save it again (on this home or the next). Replaces
  // the general handler.
  router.on(DeleteSession.self) { request, caller in
    if let chat = try await library.savedBots().chats.first(where: { $0.session.id == request.sessionID }) {
      let delete: JSONValue = switch chat.kind {
      case .thread: .object(["type": .string("thread.delete"), "botId": .string(chat.botID ?? ""),
                             "conversationId": .integer(Int64(chat.conversationID))])
      case .forumThread: .object(["type": .string("forum.thread.delete"), "roomId": .integer(Int64(chat.conversationID))])
      case .main: throw ProtocolError(.badRequest, "A bot's main chat goes with the bot.")
      case .forum: throw ProtocolError(.badRequest, "The Forum cannot be deleted.")
      }
      _ = try await bots.call(delete, caller: caller)
    } else {
      await sessions.close(request.sessionID)
    }
    try await library.deleteSession(request.sessionID)
    return Done()
  }
}

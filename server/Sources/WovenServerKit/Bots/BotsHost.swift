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
/// - When it names another machine, follows that machine's server for the
///   status and the messages for everyone, and forwards calls and opened
///   conversations to it.
/// - When it is unset, the bots are off.
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

  private let library: Library
  private let peers: PeerSync
  private let interface: BotsHostInterface
  private let hosting: BotsHosting
  private let engine: any BotsEngine
  private let dataFolder: URL
  private var thisMachine: String { library.machineID }

  private var home: String?
  private var resources = BotsResources.defaults
  private var status = BotsStatus(homeMachineID: nil, state: .off)
  private var watcher: Task<Void, Never>?
  private var supervisor: Task<Void, Never>?
  private var relay: Task<Void, Never>?
  private var capacity: BotsCapacity?

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
    self.interface = BotsHostInterface(library: library, secrets: secrets)
    self.hosting = hosting
    self.engine = hosting.engine(dataFolder)
    self.dataFolder = dataFolder
  }

  private var runtimeFolder: URL { dataFolder.appendingPathComponent("bots-runtime", isDirectory: true) }
  private var configURL: URL { runtimeFolder.appendingPathComponent("config.json") }
  private var logURL: URL { runtimeFolder.appendingPathComponent("runtime.log") }
  private var socketPath: String { runtimeFolder.appendingPathComponent("runtime.sock").path }

  /// The Woven MCP, offered to the bots when this machine is their home.
  func offerTools(_ tools: WovenTools) {
    interface.tools.attach(tools)
  }

  // MARK: Lifetime

  func start() {
    guard watcher == nil else { return }
    let changes = library.changes()
    watcher = Task { [weak self] in
      await self?.settingsChanged()
      for await _ in changes { await self?.settingsChanged() }
    }
  }

  func stop() async {
    watcher?.cancel()
    watcher = nil
    home = nil
    await leaveHome()
    for continuation in everyone.values { continuation.finish() }
    everyone.removeAll()
  }

  private func settingsChanged() async {
    let setting = ((try? await library.setting(botsHomeSetting)) ?? nil)?.value
    let newHome = setting?.string.flatMap { $0.isEmpty ? nil : $0 }
    let newResources = ((try? await library.setting(BotsResources.setting)) ?? nil)
      .flatMap { try? $0.value.decode(BotsResources.self) } ?? .defaults
    guard !Task.isCancelled else { return }
    if newHome != home {
      await leaveHome()
      home = newHome
      resources = newResources
      enterHome()
    } else if newResources != resources {
      resources = newResources
      if home == thisMachine { await resourcesChanged() }
    }
  }

  private func enterHome() {
    guard let home else {
      setStatus(BotsStatus(homeMachineID: nil, state: .off))
      return
    }
    if home == thisMachine {
      setStatus(localStatus(.starting))
      supervisor = Task { await self.supervise() }
    } else {
      setStatus(BotsStatus(homeMachineID: home, state: .unreachable))
      relay = Task { await self.follow(home) }
    }
  }

  private func leaveHome() async {
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
    await engine.stop()
  }

  private func prepareConfig(engineSocket: String) throws -> BotsRuntimeConfig {
    let manager = FileManager.default
    try manager.createDirectory(at: runtimeFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runtimeFolder.path)
    let bots = dataFolder.appendingPathComponent("bots", isDirectory: true)
    let pi = dataFolder.appendingPathComponent("pi-durable", isDirectory: true)
    try manager.createDirectory(at: bots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.createDirectory(at: pi, withIntermediateDirectories: true)
    // A Unix socket path has a short fixed limit (104 bytes on a Mac, 108 on Linux).
    guard socketPath.utf8.count < 104 else {
      throw RuntimeError.failed("The bots runtime's socket path is too long: \(socketPath)")
    }
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

  private func localStatus(_ state: BotsState, message: String? = nil) -> BotsStatus {
    BotsStatus(homeMachineID: thisMachine, state: state, message: message, engine: engine.kind,
               capacity: state == .ready ? capacity : nil)
  }

  private func setStatus(_ new: BotsStatus) {
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
  /// `open` that conversation or Forum room.
  func subscribe(open: JSONValue?, caller: Caller) async throws -> (BotsOpened, Events) {
    // Another server asks only the machine that is home; one that is not says so and ends.
    if let home, home != thisMachine, caller.hello.role == .server {
      return (BotsOpened(status: BotsStatus(homeMachineID: home, state: .unreachable,
                                            message: "This machine does not run the bots.")), Self.ended)
    }
    guard let open else {
      let (events, continuation) = makeStream()
      everyone[continuation.id] = continuation.continuation
      return (BotsOpened(status: status), events)
    }
    guard let home else { return (BotsOpened(status: status), Self.ended) }
    guard home == thisMachine else { return try await relayOpen(open, home: home, caller: caller) }
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

  /// An opened conversation on the home machine's server, relayed.
  private func relayOpen(_ open: JSONValue, home: String, caller: Caller) async throws -> (BotsOpened, Events) {
    guard let client = try? await homeClient(home, caller: caller) else {
      return (BotsOpened(status: status), Self.ended)
    }
    let subscription = try await client.subscribe(SubscribeBots(open: open))
    let (events, continuation) = Events.makeStream(bufferingPolicy: .bufferingOldest(Self.subscriberBuffer))
    let forward = Task {
      do {
        for try await event in subscription.events {
          if case .dropped = continuation.yield(event) {
            continuation.finish(throwing: SubscriberTooSlow())
            return
          }
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in
      forward.cancel()
      Task { try? await client.unsubscribe(subscription.id) }
    }
    return (subscription.reply, events)
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

func registerBots(_ router: inout Router, bots: BotsHost, library: Library) {
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
                                           pinned: request.pinned, read: request.read, folderID: folder)
  }
}

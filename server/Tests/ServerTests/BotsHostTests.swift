import Foundation
import Synchronization
import Testing
import WovenLibrary
import WovenProtocol
#if canImport(Glibc)
import Glibc
#endif
@testable import WovenServerKit

private let appVersion = "test"

/// A container engine that is always there.
private struct StandInEngine: BotsEngine {
  var kind: String { "linux-dockerd" }
  func prepare(_ resources: BotsResources) async throws -> String { "/tmp/no-docker.sock" }
  func apply(_ resources: BotsResources) async throws {}
  func capacity() async -> BotsCapacity? { nil }
  func stop() async {}
}

/// The bots runtime as the server sees it: a WebSocket server on the socket
/// its config names, answering requests, pushing messages and asking the
/// host interface, written in Swift so no Node runs.
private final class StandInBotsRuntime: Sendable {
  private struct State {
    var transport: (any MessageTransport)?
    var received: [JSONValue] = []
    var hostReplies: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    var listener: Listener?
    var launches = 0
  }

  private let state = Mutex(State())

  var hosting: BotsHosting { hosting(files: StandInFiles()) }

  func hosting(files: StandInFiles, committing: Gate? = nil) -> BotsHosting {
    BotsHosting(engine: { _, _ in StandInEngine() }, launch: { config, _ in try self.launch(config) }, files: files.files,
                committing: { await committing?.pass() })
  }

  var received: [JSONValue] { state.withLock { $0.received } }
  /// How many times the runtime was started.
  var launches: Int { state.withLock { $0.launches } }
  var connected: Bool { state.withLock { $0.transport != nil } }

  private func launch(_ config: URL) throws -> any BotsRuntimeProcess {
    state.withLock { $0.launches += 1 }
    let values = try Wire.decoder.decode(JSONValue.self, from: Data(contentsOf: config))
    let socket = values["socket"]?.string ?? ""
    let database = URL(fileURLWithPath: values["dataDir"]?.string ?? "").appendingPathComponent("bots.json")
    let process = StandInProcess()
    Task {
      guard let listener = try? await Listener.start(.unix(path: socket), accept: { transport, _ in
        await self.serve(transport, database: database)
      })
      else { return }
      state.withLock { $0.listener = listener }
      await process.exited()
      await listener.stop()
    }
    return process
  }

  /// Serves the server's connection. The stand-in's database, `bots.json`
  /// in its bots folder, is the host requests it makes once connected (its
  /// library copy).
  private func serve(_ transport: WebSocketTransport, database: URL) async {
    state.withLock { $0.transport = transport }
    if let data = try? Data(contentsOf: database), let pushes = try? Wire.decoder.decode([JSONValue].self, from: data) {
      Task { for push in pushes { _ = try? await host(push["method"]?.string ?? "", push["params"] ?? .null) } }
    }
    do {
      for try await text in transport.incoming {
        let message = try Wire.decoder.decode(JSONValue.self, from: Data(text.utf8))
        switch message["type"]?.string {
        case "host.result", "host.error":
          let id = message["id"]?.string ?? ""
          let waiter = state.withLock { $0.hostReplies.removeValue(forKey: id) }
          if message["type"]?.string == "host.result" {
            waiter?.resume(returning: message["data"] ?? .null)
          } else {
            waiter?.resume(throwing: RuntimeError.failed(message["message"]?.string ?? ""))
          }
        default:
          state.withLock { $0.received.append(message) }
          let data: JSONValue = switch message["type"]?.string {
          case "conversation.open":
            .object(["botId": message["botId"] ?? .null, "conversationId": .integer(1), "mainConversationId": .integer(1),
                     "entries": .array([]), "running": .bool(false), "subscriptionId": message["id"] ?? .null])
          case "conversation.close": .object(["closed": .bool(true)])
          default: .object(["asked": message])
          }
          push(.object(["type": .string("result"), "id": message["id"] ?? .null, "data": data]))
        }
      }
    } catch {}
  }

  func push(_ message: JSONValue) {
    let transport = state.withLock { $0.transport }
    try? transport?.send(String(decoding: try! Wire.encoder.encode(message), as: UTF8.self))
  }

  /// One request of the host interface, as the runtime makes it.
  func host(_ method: String, _ params: JSONValue) async throws -> JSONValue {
    let id = UUID().uuidString
    return try await withCheckedThrowingContinuation { continuation in
      state.withLock { $0.hostReplies[id] = continuation }
      push(.object(["type": .string("host"), "id": .string(id), "method": .string(method), "params": params]))
    }
  }
}

/// A point a transfer step stops at until the test lets it pass.
private final class Gate: Sendable {
  private let state = Mutex<(open: Bool, arrived: Bool, passing: [CheckedContinuation<Void, Never>],
                             watching: [CheckedContinuation<Void, Never>])>((false, false, [], []))

  /// Waits here until `open`.
  func pass() async {
    await withCheckedContinuation { continuation in
      let (open, watchers) = state.withLock { state in
        state.arrived = true
        defer { state.watching = [] }
        if !state.open { state.passing.append(continuation) }
        return (state.open, state.watching)
      }
      for watcher in watchers { watcher.resume() }
      if open { continuation.resume() }
    }
  }

  /// Returns once a step has reached the gate.
  func reached() async {
    await withCheckedContinuation { continuation in
      let arrived = state.withLock { state in
        if !state.arrived { state.watching.append(continuation) }
        return state.arrived
      }
      if arrived { continuation.resume() }
    }
  }

  func open() {
    let waiting = state.withLock { state in
      state.open = true
      defer { state.passing = [] }
      return state.passing
    }
    for continuation in waiting { continuation.resume() }
  }
}

/// A container engine's bot files, as a transfer writes them out and reads them in.
private final class StandInFiles: Sendable {
  let volumes = Mutex<[String: Data]>([:])
  let failImport: Bool
  /// Reading files in stops here.
  let importing: Gate?

  init(failImport: Bool = false, importing: Gate? = nil) {
    self.failImport = failImport
    self.importing = importing
  }

  var files: BotsFiles {
    BotsFiles { action, _, folder in
      switch action {
      case .export:
        try FileManager.default.createDirectory(at: folder!, withIntermediateDirectories: true)
        for (bot, data) in self.volumes.withLock({ $0 }) { try data.write(to: folder!.appendingPathComponent(bot + ".tar")) }
      case .import:
        await self.importing?.pass()
        if self.failImport { throw RuntimeError.failed("The engine refused the files.") }
        for name in try FileManager.default.contentsOfDirectory(atPath: folder!.path) where name.hasSuffix(".tar") {
          let data = try Data(contentsOf: folder!.appendingPathComponent(name))
          self.volumes.withLock { $0[String(name.dropLast(4))] = data }
        }
      case .remove:
        self.volumes.withLock { $0.removeAll() }
      }
    }
  }
}

private final class StandInProcess: BotsRuntimeProcess {
  private let done = Mutex<(stopped: Bool, waiters: [UUID: CheckedContinuation<Void, Never>])>((false, [:]))

  func exited() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Cancellation is read once, under the lock: read twice, a cancel in
        // between both stored the waiter and resumed it, so it was resumed twice.
        let ended = done.withLock { state in
          if state.stopped || Task.isCancelled { return true }
          state.waiters[id] = continuation
          return false
        }
        if ended { continuation.resume() }
      }
    } onCancel: {
      done.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
    }
  }

  func stop() async {
    let waiters = done.withLock { state in
      state.stopped = true
      defer { state.waiters.removeAll() }
      return state.waiters.values
    }
    for waiter in waiters { waiter.resume() }
  }
}

/// A server with a data folder of its own.
private struct TestServer {
  let server: WovenServer
  let folder: URL
  let socket: String

  static func start(name: String, runtime: StandInBotsRuntime, tailnet: StandInTailnet = StandInTailnet(),
                    listen: Bool = false, files: StandInFiles = StandInFiles(),
                    committing: Gate? = nil) async throws -> TestServer {
    // A test process can exit before `finishLater` removes its folder; with a
    // whole UUID a new server never opens a folder an earlier run left behind.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-bots-\(UUID().uuidString)", isDirectory: true)
    let socket = "/tmp/wvb-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: listen ? ("127.0.0.1", 0) : nil, appVersion: appVersion,
      machineName: name, tailnet: tailnet, runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    options.botsHosting = runtime.hosting(files: files, committing: committing)
    return TestServer(server: try await WovenServer.start(options), folder: folder, socket: socket)
  }

  func finish() async {
    await server.stop()
    try? FileManager.default.removeItem(at: folder)
  }

  /// `finish` for a `defer`: the sockets go now, the rest once the server stops.
  func finishLater() {
    try? FileManager.default.removeItem(at: SocketFolder.directory(for: folder))
    unlink(socket)
    Task { await finish() }
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: appVersion))
    return client
  }

  /// Makes this machine the bots' home and waits until its runtime is ready.
  func makeHome(_ client: Client, _ runtime: StandInBotsRuntime) async throws {
    _ = try await client.call(ChooseBotsHome(machineID: server.machineID))
    let subscription = try await client.subscribe(SubscribeBots())
    if subscription.reply.status.state != .ready {
      for try await event in subscription.events {
        if case .status(let status) = event, status.state == .ready { break }
      }
    }
    try await client.unsubscribe(subscription.id)
    while !runtime.connected { try await Task.sleep(for: .milliseconds(10)) }
  }
}

private func json(_ text: String) -> JSONValue {
  try! Wire.decoder.decode(JSONValue.self, from: Data(text.utf8))
}

@Test(.timeLimit(.minutes(1)))
func mirrorPushIsSavedOnceWithItsCheckpoint() async throws {
  let runtime = StandInBotsRuntime()
  let home = try await TestServer.start(name: "Studio", runtime: runtime)
  defer { home.finishLater() }
  let client = try await home.connect()
  try await home.makeHome(client, runtime)

  // A session's message, the model's thinking, and a call whose output is over the cap sessions keep.
  let long = String(repeating: "x", count: ToolOutput.limit + 10)
  let push = json("""
    {"bot": {"id": "b1", "name": "Ada", "kind": "bot", "manager": false, "orchestrator": false, "deleted": false,
             "createdAt": "2026-11-01T10:00:00.000Z"},
     "conversations": [{"conversationId": 1, "kind": "main", "createdAt": "2026-11-01T10:00:00.000Z"}],
     "items": [
       {"key": "3", "conversationId": 1, "createdAt": 1000, "kind": "user", "text": "Hello",
        "from": {"name": "Build", "sessionId": "s-1"}},
       {"key": "4", "conversationId": 1, "createdAt": 2000, "kind": "assistant", "text": "Hi",
        "usage": {"model": "p/m", "input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "cost": 0.01}},
       {"key": "4.1", "conversationId": 1, "createdAt": 2001, "kind": "thinking", "text": "Look first."},
       {"key": "4.2", "conversationId": 1, "createdAt": 2002, "kind": "tool",
        "tool": {"name": "bash", "input": "ls", "output": "\(long)", "failed": false}}],
     "upTo": 4}
    """)
  _ = try await runtime.host("mirror.bot", push)
  _ = try await runtime.host("mirror.bot", push)
  _ = try await runtime.host("mirror.forum", json("""
    {"rooms": [{"roomId": 1, "createdAt": "2026-11-01T10:00:00.000Z"}],
     "posts": [{"id": 7, "roomId": 1, "author": "bot", "botId": "b1", "name": "Ada", "text": "Morning", "createdAt": 3000}],
     "upTo": 7}
    """))

  let checkpoints = try await runtime.host("mirror.checkpoints", .object([:]))
  #expect(checkpoints == json(#"{"bots": {"b1": 4}, "forum": 7, "seats": {}}"#))

  let saved = try await client.call(ListSavedBots())
  #expect(saved.bots.map(\.name) == ["Ada"])
  let main = try #require(saved.chats.first { $0.kind == .main })
  #expect(main.session.id.hasPrefix("bot:\(home.server.machineID):") && main.session.id.hasSuffix(":b1:1"))
  #expect(main.session.title == "Ada")
  #expect(main.session.runtime == .bots)
  let items = try await client.call(SessionItems(sessionID: main.session.id))
  #expect(items.map(\.sequence) == [1, 2, 3, 4])
  #expect(items.map(\.content) == [
    .userMessage(text: "Hello"), .assistantMessage(text: "Hi"),
    .toolCall(ToolCall(name: "thinking", input: "", output: "Look first.", title: "Thinking", kind: .thinking)),
    .toolCall(ToolOutput.capped(ToolCall(name: "bash", input: "ls", output: long, kind: .execute))),
  ])
  #expect(items.first?.author == ItemAuthor(botID: nil, name: "Build", sessionID: "s-1"))
  guard case .toolCall(let call) = items.last?.content else { return }
  #expect(call.output?.contains("characters left out") == true)

  let forum = try #require(saved.chats.first { $0.kind == .forum })
  #expect(forum.session.title == "Forum")
  let posts = try await client.call(SessionItems(sessionID: forum.session.id))
  #expect(posts.map(\.author) == [ItemAuthor(botID: "b1", name: "Ada")])
}

@Test(.timeLimit(.minutes(1)))
func callsAndOpenedConversationsPassThroughToTheRuntime() async throws {
  let runtime = StandInBotsRuntime()
  let home = try await TestServer.start(name: "Studio", runtime: runtime)
  defer { home.finishLater() }
  let client = try await home.connect()
  try await home.makeHome(client, runtime)

  let reply = try await client.call(BotsCall(request: json(#"{"type": "bots.list"}"#)))
  #expect(reply["asked"]?["type"]?.string == "bots.list")

  let everyone = try await client.subscribe(SubscribeBots())
  let open = try await client.subscribe(SubscribeBots(open: json(#"{"type": "conversation.open", "botId": "b1"}"#)))
  #expect(open.reply.opened?["conversationId"]?.int == 1)
  let openID = try #require(runtime.received.last?["id"])

  runtime.push(json(#"{"type": "event", "botId": "b1", "conversationId": 2, "event": {"kind": "delta", "text": "no"}}"#))
  runtime.push(json(#"{"type": "event", "botId": "b1", "conversationId": 1, "event": {"kind": "delta", "text": "yes"}}"#))
  runtime.push(json(#"{"type": "bots.changed"}"#))
  for try await event in open.events {
    guard case .message(let message) = event else { continue }
    #expect(message["event"]?["text"]?.string == "yes")
    break
  }
  for try await event in everyone.events {
    guard case .message(let message) = event else { continue }
    #expect(message["type"]?.string == "bots.changed")
    break
  }

  try await client.unsubscribe(open.id)
  while runtime.received.last?["type"]?.string != "conversation.close" { try await Task.sleep(for: .milliseconds(10)) }
  let close = try #require(runtime.received.last)
  #expect(close["botId"]?.string == "b1")
  #expect(close["conversationId"]?.int == 1)
  #expect(close["subscriptionId"] == openID)
}

@Test(.timeLimit(.minutes(1)))
func anotherServerSendsUIsToTheHomeMachineAndForwardsCalls() async throws {
  let runtime = StandInBotsRuntime()
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let a = try await TestServer.start(name: "Studio", runtime: runtime, tailnet: tailnetA, listen: true)
  let b = try await TestServer.start(name: "Laptop", runtime: StandInBotsRuntime(), tailnet: tailnetB, listen: true)
  defer { a.finishLater(); b.finishLater() }
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()
  try await a.makeHome(try await a.connect(), runtime)

  // Once the setting reaches it, the other server streams nothing of the bots:
  // it names the home machine, whose server a UI connects to directly.
  let onB = try await b.connect()
  while true {
    do {
      let subscription = try await onB.subscribe(SubscribeBots())
      try await onB.unsubscribe(subscription.id)
      try await Task.sleep(for: .milliseconds(50))
    } catch let error as ProtocolError {
      #expect(error.code == .notOwner)
      #expect(error.machineID == a.server.machineID)
      break
    }
  }
  // A call (as an agent there makes through the Woven MCP) is still forwarded.
  let reply = try await onB.call(BotsCall(request: json(#"{"type": "bots.list"}"#)))
  #expect(reply["asked"]?["type"]?.string == "bots.list")
}

// MARK: Transfer

/// Two linked servers; the first is the bots' home, its stand-in runtime
/// holding one bot with a chat, a turn's usage, a Forum post, a visual reply
/// it published in the Forum (its HTML in the first server's content store),
/// a Forum turn's usage, and files.
private struct TransferSetup {
  static let visualReplyHTML = Data("<h1>Build times</h1>".utf8)
  let a: TestServer, b: TestServer
  let runtimeA: StandInBotsRuntime, runtimeB: StandInBotsRuntime
  let filesA: StandInFiles, filesB: StandInFiles
  let onA: Client, onB: Client

  static func start(failImport: Bool = false, importing: Gate? = nil, committing: Gate? = nil) async throws -> TransferSetup {
    let runtimeA = StandInBotsRuntime(), runtimeB = StandInBotsRuntime()
    let filesA = StandInFiles(), filesB = StandInFiles(failImport: failImport, importing: importing)
    let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
    let a = try await TestServer.start(name: "Studio", runtime: runtimeA, tailnet: tailnetA, listen: true, files: filesA)
    let b = try await TestServer.start(name: "Laptop", runtime: runtimeB, tailnet: tailnetB, listen: true, files: filesB,
                                       committing: committing)
    tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
    tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
    await a.server.discoverMachines()
    await b.server.discoverMachines()
    let bots = a.folder.appendingPathComponent("bots", isDirectory: true)
    try FileManager.default.createDirectory(at: bots, withIntermediateDirectories: true)
    let digest = try await a.server.library.storeContent(visualReplyHTML)
    try Data("""
      [{"method": "mirror.bot", "params": {
         "bot": {"id": "b1", "name": "Ada", "kind": "bot", "manager": false, "orchestrator": false, "deleted": false,
                 "createdAt": "2026-11-01T10:00:00.000Z"},
         "conversations": [{"conversationId": 1, "kind": "main", "createdAt": "2026-11-01T10:00:00.000Z"}],
         "items": [
           {"key": "3", "conversationId": 1, "createdAt": 1000, "kind": "user", "text": "Hello"},
           {"key": "4", "conversationId": 1, "createdAt": 2000, "kind": "assistant", "text": "Hi",
            "usage": {"model": "p/m", "input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "cost": 0.01}}],
         "upTo": 4}},
       {"method": "mirror.forum", "params": {
         "rooms": [{"roomId": 1, "createdAt": "2026-11-01T10:00:00.000Z"}],
         "posts": [{"id": 7, "roomId": 1, "author": "bot", "botId": "b1", "name": "Ada", "text": "Morning", "createdAt": 3000},
                   {"id": 8, "roomId": 1, "author": "bot", "botId": "b1", "name": "Ada", "text": "",
                    "visualReply": {"title": "Build times", "height": 320, "digest": "\(digest)", "size": 20}, "createdAt": 3100}],
         "seatItems": [{"botId": "b1", "name": "Ada", "item": {"key": "6", "conversationId": 1, "createdAt": 3050, "kind": "tool",
                        "tool": {"name": "bash", "input": "ls", "output": "a", "failed": false}}}],
         "seatUsage": [{"botId": "b1", "key": "6", "roomId": 1, "createdAt": 3050,
                        "usage": {"model": "p/m", "input": 7, "output": 2, "cacheRead": 0, "cacheWrite": 0, "cost": 0.01}}],
         "seats": {"b1": 6},
         "upTo": 8}}]
      """.utf8).write(to: bots.appendingPathComponent("bots.json"))
    try Data("{}".utf8).write(to: bots.appendingPathComponent("settings.json"))
    filesA.volumes.withLock { $0["b1"] = Data("Ada's files".utf8) }
    let onA = try await a.connect(), onB = try await b.connect()
    try await a.makeHome(onA, runtimeA)
    while try await onA.call(ListSavedBots()).chats.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
    // The other server knows the home and can reach it.
    while try await onB.call(ListSettings()).first(where: { $0.key == botsHomeSetting })?.value.string != a.server.machineID {
      try await Task.sleep(for: .milliseconds(20))
    }
    return TransferSetup(a: a, b: b, runtimeA: runtimeA, runtimeB: runtimeB, filesA: filesA, filesB: filesB, onA: onA, onB: onB)
  }

  func finishLater() {
    a.finishLater()
    b.finishLater()
  }
}

private func home(_ client: Client) async throws -> String? {
  try await client.call(ListSettings()).first { $0.key == botsHomeSetting }?.value.string
}

@Test(.timeLimit(.minutes(1)))
func transferMovesTheBotsAndSwitchesTheHomeWithNothingTwice() async throws {
  let setup = try await TransferSetup.start()
  defer { setup.finishLater() }
  let (a, b) = (setup.a, setup.b)
  // What the person set on a chat goes with it.
  let before = try #require(try await setup.onA.call(ListSavedBots()).chats.first { $0.kind == .main })
  _ = try await setup.onA.call(UpdateSession(sessionID: before.session.id, archived: true, folderID: "f1"))

  _ = try await setup.onA.call(TransferBots(targetMachineID: b.server.machineID))

  // The folder and the files moved, the home switched, and the old copy is gone.
  #expect(FileManager.default.contents(atPath: b.folder.appendingPathComponent("bots/bots.json").path) != nil)
  #expect(FileManager.default.contents(atPath: b.folder.appendingPathComponent("bots/settings.json").path) == Data("{}".utf8))
  #expect(setup.filesB.volumes.withLock { $0 } == ["b1": Data("Ada's files".utf8)])
  #expect(setup.filesA.volumes.withLock { $0.isEmpty })
  #expect(!FileManager.default.fileExists(atPath: a.folder.appendingPathComponent("bots").path))
  #expect(try await home(setup.onB) == b.server.machineID)
  #expect(setup.runtimeB.connected)

  // Once both libraries have synced, every chat and turn is there once, owned by the new home.
  for client in [setup.onA, setup.onB] {
    while true {
      let saved = try await client.call(ListSavedBots())
      if try await home(client) == b.server.machineID, saved.chats.count == 2,
         saved.chats.allSatisfy({ $0.session.machineID == b.server.machineID }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let main = try #require(try await client.call(ListSavedBots()).chats.first { $0.kind == .main })
    #expect(try await client.call(SessionItems(sessionID: main.session.id)).count == 2)
    #expect(main.session.archived && main.session.folderID == "f1")
  }
  for server in [a, b] {
    let usage = try await server.server.library.usage(from: .distantPast, to: .distantFuture, periodSeconds: 86400)
    #expect(usage.totals.requests == 2)
  }
  // The Forum's visual reply is one small item on both, and its HTML came to the new home.
  let digest = Library.digest(of: TransferSetup.visualReplyHTML)
  let expected: [ItemContent] = [.assistantMessage(text: "Morning"),
                                 .toolCall(ToolCall(name: "bash", input: "ls", output: "a", kind: .execute)),
                                 .visualReply(VisualReply(title: "Build times", height: 320, digest: digest, size: 20))]
  for client in [setup.onA, setup.onB] {
    let forum = try #require(try await client.call(ListSavedBots()).chats.first { $0.kind == .forum })
    var posts: [SessionItem] = []
    for _ in 0..<200 {
      posts = try await client.call(SessionItems(sessionID: forum.session.id))
      if posts.map(\.content) == expected { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(posts.map(\.content) == expected)
    #expect(posts.last?.author == ItemAuthor(botID: "b1", name: "Ada"))
  }
  for _ in 0..<200 {
    if try await b.server.library.hasContent(digest) { break }
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(try await b.server.library.content(digest)?.data == TransferSetup.visualReplyHTML)

  // And back: the first home saves them again under new sessions, though it deleted its old ones.
  _ = try await setup.onB.call(TransferBots(targetMachineID: a.server.machineID))
  #expect(setup.filesA.volumes.withLock { $0 } == ["b1": Data("Ada's files".utf8)])
  for client in [setup.onA, setup.onB] {
    while true {
      let saved = try await client.call(ListSavedBots())
      if try await home(client) == a.server.machineID, saved.chats.count == 2,
         saved.chats.allSatisfy({ $0.session.machineID == a.server.machineID }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let main = try #require(try await client.call(ListSavedBots()).chats.first { $0.kind == .main })
    #expect(try await client.call(SessionItems(sessionID: main.session.id)).count == 2)
  }
}

@Test(.timeLimit(.minutes(1)))
func aFailedTransferLeavesTheBotsRunningOnTheOldHome() async throws {
  let setup = try await TransferSetup.start(failImport: true)
  defer { setup.finishLater() }
  let (a, b) = (setup.a, setup.b)

  await #expect(throws: ProtocolError.self) {
    _ = try await setup.onA.call(TransferBots(targetMachineID: b.server.machineID))
  }
  let status = try await setup.onA.subscribe(SubscribeBots())
  if status.reply.status.state != .ready {
    for try await event in status.events {
      if case .status(let status) = event, status.state == .ready { break }
    }
  }
  #expect(try await home(setup.onA) == a.server.machineID)
  #expect(setup.filesA.volumes.withLock { $0 } == ["b1": Data("Ada's files".utf8)])
  #expect(FileManager.default.fileExists(atPath: a.folder.appendingPathComponent("bots/bots.json").path))
  // The target removed what it received.
  #expect(setup.filesB.volumes.withLock { $0.isEmpty })
  #expect(!FileManager.default.fileExists(atPath: b.folder.appendingPathComponent("bots").path))
  #expect(!FileManager.default.fileExists(atPath: b.folder.appendingPathComponent("bots-incoming").path))
}

/// Waits until the server's bots report `ready`.
private func ready(_ client: Client) async throws {
  let status = try await client.subscribe(SubscribeBots())
  if status.reply.status.state != .ready {
    for try await event in status.events {
      if case .status(let status) = event, status.state == .ready { break }
    }
  }
  try await client.unsubscribe(status.id)
}

@Test(.timeLimit(.minutes(1)))
func aTransferGivenBackDuringTheInstallNeverStartsTheBotsOnTheTarget() async throws {
  let importing = Gate()
  let setup = try await TransferSetup.start(importing: importing)
  defer { setup.finishLater() }
  let (a, b) = (setup.a, setup.b)

  let transfer = Task { try await setup.onA.call(TransferBots(targetMachineID: b.server.machineID)) }
  await importing.reached()
  let id = try #require(await b.server.bots.incoming?.id)
  // Given back while the files are being read in: it returns only once the
  // install has ended and everything it put in place is gone.
  let abort = Task { try await b.server.bots.abortReceived(id) }
  importing.open()
  try await abort.value
  #expect(setup.runtimeB.launches == 0)
  #expect(setup.filesB.volumes.withLock { $0.isEmpty })
  #expect(!FileManager.default.fileExists(atPath: b.folder.appendingPathComponent("bots").path))
  #expect(!FileManager.default.fileExists(atPath: b.folder.appendingPathComponent("bots-incoming").path))

  await #expect(throws: ProtocolError.self) { _ = try await transfer.value }
  try await ready(setup.onA)
  #expect(try await home(setup.onA) == a.server.machineID)
  #expect(setup.filesA.volumes.withLock { $0 } == ["b1": Data("Ada's files".utf8)])
  #expect(setup.runtimeB.launches == 0)
}

@Test(.timeLimit(.minutes(1)))
func onceTheTargetBeginsToCommitNothingGivesTheTransferBack() async throws {
  let committing = Gate()
  let setup = try await TransferSetup.start(committing: committing)
  defer { setup.finishLater() }
  let (a, b) = (setup.a, setup.b)

  let transfer = Task { try await setup.onA.call(TransferBots(targetMachineID: b.server.machineID)) }
  await committing.reached()
  let id = try #require(await b.server.bots.incoming?.id)
  await #expect(throws: ProtocolError.self) { try await b.server.bots.abortReceived(id) }
  committing.open()
  _ = try await transfer.value

  #expect(try await home(setup.onB) == b.server.machineID)
  #expect(setup.filesB.volumes.withLock { $0 } == ["b1": Data("Ada's files".utf8)])
  #expect(FileManager.default.fileExists(atPath: b.folder.appendingPathComponent("bots/bots.json").path))
  #expect(setup.runtimeB.connected)
  #expect(setup.filesA.volumes.withLock { $0.isEmpty })
  #expect(!FileManager.default.fileExists(atPath: a.folder.appendingPathComponent("bots").path))
}

@Test(.timeLimit(.minutes(1)))
func aSessionMessagesABotAsItself() async throws {
  let runtime = StandInBotsRuntime()
  let home = try await TestServer.start(name: "Studio", runtime: runtime)
  defer { home.finishLater() }
  let client = try await home.connect()
  try await home.makeHome(client, runtime)
  let session = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Build"))
  let tools = try #require(await home.server.bots.toolsForTests)

  // A session a bot sent off reports back: the bot's chat gets it as from that session.
  let result = await tools.call("message_bot", arguments: .object(["botID": .string("b1"), "text": .string("Done.")]),
                                caller: ToolCaller(machineID: home.server.machineID, sessionID: session.id))
  #expect(!result.isError)
  let sent = try #require(runtime.received.last { $0["type"]?.string == "message.send" })
  #expect(sent["text"]?.string == "Done.")
  #expect(sent["from"] == .object(["name": .string("Build"), "sessionId": .string(session.id)]))
  #expect(sent["context"]?.string?.contains(session.id) == true)
}

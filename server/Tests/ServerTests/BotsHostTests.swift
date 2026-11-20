import Foundation
import Synchronization
import Testing
import WovenLibrary
import WovenProtocol
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
  }

  private let state = Mutex(State())

  var hosting: BotsHosting {
    BotsHosting(engine: { _ in StandInEngine() }, launch: { config, _ in try self.launch(config) })
  }

  var received: [JSONValue] { state.withLock { $0.received } }
  var connected: Bool { state.withLock { $0.transport != nil } }

  private func launch(_ config: URL) throws -> any BotsRuntimeProcess {
    let socket = try Wire.decoder.decode(JSONValue.self, from: Data(contentsOf: config))["socket"]?.string ?? ""
    let process = StandInProcess()
    Task {
      guard let listener = try? await Listener.start(.unix(path: socket), accept: { transport, _ in await self.serve(transport) })
      else { return }
      state.withLock { $0.listener = listener }
      await process.exited()
      await listener.stop()
    }
    return process
  }

  private func serve(_ transport: WebSocketTransport) async {
    state.withLock { $0.transport = transport }
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

private final class StandInProcess: BotsRuntimeProcess {
  private let done = Mutex<(stopped: Bool, waiters: [UUID: CheckedContinuation<Void, Never>])>((false, [:]))

  func exited() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let stopped = done.withLock { state in
          if !state.stopped && !Task.isCancelled { state.waiters[id] = continuation }
          return state.stopped || Task.isCancelled
        }
        if stopped { continuation.resume() }
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

/// A server whose data folder is short enough for the runtime's socket path.
private struct TestServer {
  let server: WovenServer
  let folder: URL
  let socket: String

  static func start(name: String, runtime: StandInBotsRuntime, tailnet: StandInTailnet = StandInTailnet(),
                    listen: Bool = false) async throws -> TestServer {
    let folder = URL(fileURLWithPath: "/tmp/wvb-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let socket = folder.path + ".sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: listen ? ("127.0.0.1", 0) : nil, appVersion: appVersion,
      machineName: name, tailnet: tailnet, runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    options.botsHosting = runtime.hosting
    return TestServer(server: try await WovenServer.start(options), folder: folder, socket: socket)
  }

  func finish() async {
    await server.stop()
    try? FileManager.default.removeItem(at: folder)
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: appVersion))
    return client
  }

  /// Makes this machine the bots' home and waits until its runtime is ready.
  func makeHome(_ client: Client, _ runtime: StandInBotsRuntime) async throws {
    _ = try await client.call(SetSetting(key: botsHomeSetting, value: .string(server.machineID)))
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
  defer { Task { await home.finish() } }
  let client = try await home.connect()
  try await home.makeHome(client, runtime)

  let push = json("""
    {"bot": {"id": "b1", "name": "Ada", "kind": "bot", "manager": false, "orchestrator": false, "deleted": false,
             "createdAt": "2026-11-01T10:00:00.000Z"},
     "conversations": [{"conversationId": 1, "kind": "main", "createdAt": "2026-11-01T10:00:00.000Z"}],
     "items": [
       {"key": "3", "conversationId": 1, "createdAt": 1000, "kind": "user", "text": "Hello"},
       {"key": "4", "conversationId": 1, "createdAt": 2000, "kind": "assistant", "text": "Hi",
        "usage": {"model": "p/m", "input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "cost": 0.01}},
       {"key": "4.1", "conversationId": 1, "createdAt": 2001, "kind": "tool",
        "tool": {"name": "bash", "input": "ls", "output": "a", "failed": false}}],
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
  #expect(checkpoints == json(#"{"bots": {"b1": 4}, "forum": 7}"#))

  let saved = try await client.call(ListSavedBots())
  #expect(saved.bots.map(\.name) == ["Ada"])
  let main = try #require(saved.chats.first { $0.kind == .main })
  #expect(main.session.id == "bot:\(home.server.machineID):b1:1")
  #expect(main.session.title == "Ada")
  #expect(main.session.runtime == .bots)
  let items = try await client.call(SessionItems(sessionID: main.session.id))
  #expect(items.map(\.sequence) == [1, 2, 3])
  #expect(items.map(\.content) == [
    .userMessage(text: "Hello"), .assistantMessage(text: "Hi"),
    .toolCall(ToolCall(name: "bash", input: "ls", output: "a", kind: .execute)),
  ])

  let forum = try #require(saved.chats.first { $0.kind == .forum })
  #expect(forum.session.title == "Forum")
  let posts = try await client.call(SessionItems(sessionID: forum.session.id))
  #expect(posts.map(\.author) == [ItemAuthor(botID: "b1", name: "Ada")])
}

@Test(.timeLimit(.minutes(1)))
func callsAndOpenedConversationsPassThroughToTheRuntime() async throws {
  let runtime = StandInBotsRuntime()
  let home = try await TestServer.start(name: "Studio", runtime: runtime)
  defer { Task { await home.finish() } }
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
  defer { Task { await a.finish(); await b.finish() } }
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

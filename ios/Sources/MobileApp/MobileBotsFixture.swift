#if DEBUG
import Foundation
import Network
import WovenMatterShared

/// A scripted bots runtime on a loopback WebSocket, speaking Pi Bot protocol 1
/// like a Woven server's `/v1/bots/ws`: the UI fixture (`bots` scenarios) and the
/// app tests drive the real client, conversation controller and views against it.
/// Debug builds only.
final class ScriptedBotsRuntime: @unchecked Sendable {

  private let lock = NSLock()
  private var listener: NWListener?
  private var connections: [NWConnection] = []
  private var log: [String] = []
  private var nextEntry = 100
  private var nextThread = 20
  private var threads: [String: [[String: Any]]]
  private var entries: [Int: [[String: Any]]]
  /// Seconds between streamed words; tests make it zero.
  var wordDelay: Double = 0.06
  private(set) var port: UInt16 = 0

  static let mainConversation = 10
  nonisolated(unsafe) static let bots: [[String: Any]] = [
    ["id": "admin", "name": "Admin Bot", "createdAt": "2026-11-01T09:00:00Z", "kind": "admin", "manager": false, "orchestrator": false],
    ["id": "atlas", "name": "Atlas", "createdAt": "2026-11-02T09:00:00Z", "kind": "bot", "manager": false, "orchestrator": true, "profileName": "Claude Opus"],
    ["id": "research", "name": "Research", "createdAt": "2026-11-03T09:00:00Z", "kind": "bot", "manager": true, "orchestrator": false,
     "groupId": "work", "profileName": "GPT-6.1 Sol"],
    ["id": "scout", "name": "Scout", "createdAt": "2026-11-04T09:00:00Z", "kind": "bot", "manager": false, "managerId": "research",
     "orchestrator": false, "groupId": "work", "profileName": "Claude Sonnet"],
    ["id": "errands", "name": "Errands", "createdAt": "2026-11-05T09:00:00Z", "kind": "bot", "manager": false, "orchestrator": false],
  ]

  init() {
    threads = ["atlas": [["conversationId": 12, "parentConversationId": 10, "forkedAt": 3, "title": "Launch post sources",
                          "createdAt": "2026-11-16T18:00:00Z", "pinned": true]]]
    entries = [10: [
      ["id": 1, "conversationId": 10, "role": "user", "text": "What's on my plate for the launch this week?"],
      ["id": 2, "conversationId": 10, "role": "assistant", "text": "Three things are open:\n\n1. **Finish the TestFlight notes** for external testers.\n2. Review the privacy page update.\n3. Cut the desktop release once the PRs merge."],
      ["id": 3, "conversationId": 10, "role": "assistant", "text": "I also drafted an outline for the launch post. Want me to pull sources for it?"],
    ], 12: [
      ["id": 4, "conversationId": 12, "role": "user", "text": "Yes, pull three sources."],
      ["id": 5, "conversationId": 12, "role": "assistant", "text": "Here are three to start with. I'll keep adding as I find more."],
    ]]
  }

  /// Every request type the client sent, in order.
  var requests: [String] { lock.withLock { log } }

  func start() async throws -> UInt16 {
    let options = NWProtocolWebSocket.Options()
    options.autoReplyPing = true
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    let (stream, continuation) = AsyncStream.makeStream(of: UInt16.self)
    listener.stateUpdateHandler = { [weak listener] state in
      if case .ready = state, let port = listener?.port { continuation.yield(port.rawValue) }
      if case .failed = state { continuation.yield(0) }
    }
    listener.start(queue: .global())
    lock.withLock { self.listener = listener }
    port = await stream.first { _ in true } ?? 0
    return port
  }

  func stop() {
    lock.withLock {
      listener?.cancel(); listener = nil
      connections.forEach { $0.cancel() }; connections = []
    }
  }

  /// Drops every open socket, as when the machine goes away for a moment.
  func dropConnections() { lock.withLock { connections.forEach { $0.cancel() }; connections = [] } }

  private func accept(_ connection: NWConnection) {
    lock.withLock { connections.append(connection) }
    connection.start(queue: .global())
    write(connection, ["type": "hello", "version": "0.1.0", "protocol": 1, "installationId": "fixture", "environment": "mac-vm",
                       "capabilities": ["groups", "woven.mcp", "message.context"]])
    receive(connection)
  }

  private func receive(_ connection: NWConnection) {
    connection.receiveMessage { [weak self] data, _, _, error in
      guard let self, error == nil else { return }
      if let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(body, on: connection) }
      self.receive(connection)
    }
  }

  private func handle(_ body: [String: Any], on connection: NWConnection) {
    let id = body["id"] ?? NSNull(), type = body["type"] as? String ?? ""
    let botID = body["botId"] as? String ?? ""
    lock.withLock { log.append(type) }
    func reply(_ data: Any) { write(connection, ["type": "result", "id": id, "data": data]) }
    switch type {
    case "bots.list": reply(["bots": Self.bots])
    case "groups.list": reply(["groups": [["id": "work", "name": "Work", "position": 0]]])
    case "threads.list": reply(["threads": lock.withLock { threads[botID] ?? [] }])
    case "conversation.open":
      let conversation = body["conversationId"] as? Int ?? Self.mainConversation
      let shown = lock.withLock { () -> [[String: Any]] in
        // A thread inherits its parent's history up to the fork; the view filters it.
        let own = entries[conversation] ?? []
        guard conversation != Self.mainConversation else { return botID == "atlas" ? own : [] }
        return (entries[Self.mainConversation] ?? []).prefix(3) + own
      }
      var snapshot: [String: Any] = ["subscriptionId": conversation, "botId": botID, "conversationId": conversation,
                                     "mainConversationId": Self.mainConversation, "entries": shown, "running": false]
      if conversation != Self.mainConversation, let origin = lock.withLock({ entries[Self.mainConversation]?.first { $0["id"] as? Int == 3 } }) {
        snapshot["threadOrigin"] = origin
      }
      reply(snapshot)
    case "conversation.close", "thread.setPinned": reply([:])
    case "conversation.abort": reply([:])
    case "thread.fork":
      let thread: [String: Any] = lock.withLock {
        nextThread += 1
        let made: [String: Any] = ["conversationId": nextThread, "parentConversationId": Self.mainConversation,
                                   "forkedAt": body["entryId"] as? Int ?? 0, "createdAt": "2026-11-17T12:00:00Z"]
        threads[botID, default: []].append(made)
        return made
      }
      reply(["thread": thread])
      write(connection, ["type": "threads.changed", "botId": botID])
    case "message.send":
      reply([:])
      let conversation = body["conversationId"] as? Int ?? Self.mainConversation
      let text = body["text"] as? String ?? ""
      Task { await self.answer(text, botID: botID, conversation: conversation, on: connection) }
    default:
      write(connection, ["type": "error", "id": id, "message": "Unsupported request: \(type)"])
    }
  }

  /// Records the message, then streams a short reply word by word, as a runtime does.
  private func answer(_ text: String, botID: String, conversation: Int, on connection: NWConnection) async {
    func event(_ value: [String: Any]) {
      write(connection, ["type": "event", "botId": botID, "conversationId": conversation, "event": value])
    }
    let userEntry: [String: Any] = lock.withLock {
      nextEntry += 1
      let entry: [String: Any] = ["id": nextEntry, "conversationId": conversation, "role": "user", "text": text]
      entries[conversation, default: []].append(entry)
      return entry
    }
    event(["kind": "entry", "entry": userEntry])
    event(["kind": "run", "state": "start"])
    event(["kind": "assistant_start", "text": ""])
    let reply = "On it. I'll check the launch checklist and send you a summary in this conversation."
    for word in reply.split(separator: " ") {
      if wordDelay > 0 { try? await Task.sleep(for: .seconds(wordDelay)) }
      event(["kind": "delta", "text": String(word) + " "])
    }
    let assistant: [String: Any] = lock.withLock {
      nextEntry += 1
      let entry: [String: Any] = ["id": nextEntry, "conversationId": conversation, "role": "assistant", "text": reply]
      entries[conversation, default: []].append(entry)
      return entry
    }
    event(["kind": "entry", "entry": assistant])
    event(["kind": "run", "state": "end"])
  }

  private func write(_ connection: NWConnection, _ body: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    connection.send(content: data, contentContext: .init(identifier: "message", metadata: [metadata]), isComplete: true,
                    completion: .contentProcessed { _ in })
  }
}

extension MobileModel {
  /// `bots`: a paired phone whose bots run on "Studio" (the scripted runtime above).
  /// `bots-off`: no reachable computer runs bots.
  func seedBotsFixture(scenario: String) async {
    if scenario == "bots-off" {
      bots.apply(.off([.init(id: "studio", name: "Studio", detail: "Bots are off"),
                       .init(id: "workstation", name: "Workstation", detail: "Its Woven server doesn't run bots yet. Update it to use bots there.")]))
      return
    }
    let runtime = ScriptedBotsRuntime()
    guard let port = try? await runtime.start(), port > 0 else { return }
    Self.botsFixtureRuntime = runtime
    bots.apply(.ready(.init(deviceID: "fixture-studio", name: "Studio", kind: "mac",
                            socketURL: URL(string: "ws://127.0.0.1:\(port)/ws")!, audience: nil, bearer: "fixture")))
  }
  nonisolated(unsafe) static var botsFixtureRuntime: ScriptedBotsRuntime?
}
#endif

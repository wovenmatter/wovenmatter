import Foundation
import MobileInference
import Testing
import WovenProtocol
@testable import WovenDevice

// Quick Chat through the real in-app host and a UI client on its in-memory
// connection, with a scripted model in place of a provider, an in-memory
// store in place of the Keychain, and a stand-in model catalog.

let appVersion = "test"

/// One scripted model reply, emitted as pi-ai events.
final class Reply: @unchecked Sendable {
  private let emit: @Sendable (String) -> Void
  private var content: [[String: Any]] = []
  private var stop = "stop"

  init(emit: @escaping @Sendable (String) -> Void) {
    self.emit = emit
    send(["type": "start"])
  }

  private var message: [String: Any] {
    ["role": "assistant", "content": content, "api": "openai-responses", "provider": "openai", "model": "stand-in",
     "usage": ["input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 15,
               "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]],
     "stopReason": stop, "timestamp": Date().timeIntervalSince1970 * 1000]
  }

  private func send(_ event: [String: Any]) {
    let full = event.merging(event["type"] as? String == "done" ? ["message": message] : ["partial": message]) { $1 }
    emit(String(decoding: try! JSONSerialization.data(withJSONObject: full), as: UTF8.self))
  }

  func text(_ pieces: String...) {
    let index = content.count
    content.append(["type": "text", "text": ""])
    send(["type": "text_start", "contentIndex": index])
    for piece in pieces {
      content[index]["text"] = (content[index]["text"] as? String ?? "") + piece
      send(["type": "text_delta", "contentIndex": index, "delta": piece])
    }
    send(["type": "text_end", "contentIndex": index, "content": content[index]["text"] ?? ""])
  }

  func toolCall(id: String, name: String, arguments: [String: Any]) {
    let call: [String: Any] = ["type": "toolCall", "id": id, "name": name, "arguments": arguments]
    content.append(call)
    stop = "toolUse"
    send(["type": "toolcall_start", "contentIndex": content.count - 1])
    send(["type": "toolcall_end", "contentIndex": content.count - 1, "toolCall": call])
  }

  func done() { send(["type": "done", "reason": stop]) }
}

/// The stand-in model: each request gets the next scripted reply and is kept.
actor Model {
  typealias Step = @Sendable (Reply) async throws -> Void
  private var script: [Step] = []
  private(set) var requests: [String] = []

  func then(_ steps: Step...) { script += steps }

  func infer(_ request: String, emit: @escaping @Sendable (String) -> Void) async throws {
    requests.append(request)
    guard !script.isEmpty else { throw CancellationError() }
    let reply = Reply(emit: emit)
    try await script.removeFirst()(reply)
    reply.done()
  }
}

private actor Gate {
  private var open = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if open { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func release() {
    open = true
    for continuation in waiting { continuation.resume() }
    waiting.removeAll()
  }
}

/// The device's Keychain, in memory, signed in to OpenAI with a key.
actor Credentials: InferenceCredentialUpdating {
  nonisolated let credentialStoreID = "test"
  private var secrets = ["openai": "test-key"]
  func read(connectionID: String) -> String? { secrets[connectionID] }
  func save(_ secret: String, connectionID: String) { secrets[connectionID] = secret }
  func remove(connectionID: String) { secrets[connectionID] = nil }
  func compareAndSwap(connectionID: String, expected: String, replacement: String) -> Bool {
    guard secrets[connectionID] == expected else { return false }
    secrets[connectionID] = replacement
    return true
  }
}

/// OpenAI's model catalog: one stand-in model.
struct Catalog: CatalogHTTPTransport {
  func fetch(_ request: URLRequest) async throws -> CatalogHTTPResponse {
    let model: [String: Any] = ["id": "stand-in", "name": "Stand-in", "provider": "openai", "api": "openai-responses",
                                "baseUrl": "https://api.openai.com/v1", "contextWindow": 100_000, "maxTokens": 4096,
                                "input": ["text"], "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]]
    return CatalogHTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: [model]))
  }
}

/// Every event of one session subscription, as it comes.
actor Recorder {
  private(set) var events: [SessionEvent] = []
  private var task: Task<Void, Never>?

  func start(_ stream: AsyncThrowingStream<SessionEvent, any Error>) {
    task = Task { do { for try await event in stream { self.events.append(event) } } catch {} }
  }

  func until(_ condition: @Sendable ([SessionEvent]) -> Bool) async throws {
    for _ in 0..<800 {
      if condition(events) { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("Timed out; events so far: \(events)")
    throw CancellationError()
  }

  /// Waits for the turns sent so far to have ended.
  func idle(after turns: Int) async throws {
    try await until { events in events.filter { $0 == .runState(.idle) }.count >= turns }
  }

  var finished: [SessionItem] { events.compactMap { if case .itemFinished(let item) = $0 { item } else { nil } } }
  var text: String { events.map { if case .text(_, let delta) = $0 { delta } else { "" } }.joined() }
}

struct Device {
  let device: WovenDevice
  let ui: Client
  let folder: URL

  static func start(_ model: Model, folder: URL = FileManager.default.temporaryDirectory
                      .appendingPathComponent("woven-device-\(UUID().uuidString)"),
                    release: String = appVersion, dial: Machines.Dial? = nil) async throws -> Device {
    var options = WovenDevice.Options(dataFolder: folder, deviceName: "Phone", appVersion: release)
    options.dial = dial
    options.platform = .iPhone
    options.credentials = Credentials()
    options.catalogTransport = Catalog()
    options.inference = { _, request, emit in try await model.infer(request, emit: emit) }
    let device = try await WovenDevice.start(options)
    let ui = Client(transport: device.connect())
    _ = try await ui.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI", platform: .iPhone), appVersion: release))
    return Device(device: device, ui: ui, folder: folder)
  }

  func watch(_ sessionID: String) async throws -> Recorder {
    let recorder = Recorder()
    await recorder.start(try await ui.subscribe(SubscribeSession(sessionID: sessionID)).events)
    return recorder
  }
}

/// The tools a pi-ai request offers the model: the context's, with what its
/// system messages add and remove, as the request builder reads them.
private func tools(_ request: String) -> Set<String> {
  let object = try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
  let context = object?["context"] as? [String: Any] ?? [:]
  func names(_ value: Any?) -> [String] { (value as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
  var offered = Set(names(context["tools"]))
  for message in context["messages"] as? [[String: Any]] ?? [] where message["role"] as? String == "system" {
    offered.subtract(names(message["toolsRemoved"]))
    offered.formUnion(names(message["toolsAdded"]))
  }
  return offered
}

func content(_ items: [SessionItem]) -> [String] {
  items.map { item in
    switch item.content {
    case .userMessage(let text, _): "user: \(text)"
    case .assistantMessage(let text): "assistant: \(text)"
    case .toolCall(let call): "tool: \(call.name)\(call.failed ? " failed" : "")"
    case .notice(let notice): "notice: \(notice.text)"
    case .visualReply(let reply): "visual: \(reply.title)"
    }
  }
}

@Test(.timeLimit(.minutes(1)))
func aQuickChatTurnStreamsAndSavesEachItemOnceWithItsUsage() async throws {
  let model = Model()
  await model.then({ $0.text("Hel", "lo") })
  let phone = try await Device.start(model)
  defer { Task { await phone.device.stop(); try? FileManager.default.removeItem(at: phone.folder) } }

  let chat = try await phone.ui.call(CreateSession(runtime: .piDurable, title: "Quick Chat"))
  let configuration = try #require(try await phone.ui.call(GetRuntimeConfiguration(runtime: .piDurable)))
  #expect(configuration.model == "openai/stand-in" && configuration.permissionModes.map(\.id) == ["full"])
  let watching = try await phone.watch(chat.id)
  _ = try await phone.ui.call(SendTurn(sessionID: chat.id, text: "hello"))
  try await watching.idle(after: 1)

  #expect(await watching.text == "Hello")
  let saved = try await phone.ui.call(SessionItems(sessionID: chat.id))
  #expect(saved.map(\.id) == (await watching.finished).map(\.id))
  #expect(content(saved) == ["user: hello", "assistant: Hello"])
  let usage = try await phone.device.library.usage(from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600),
                                                   periodSeconds: 3600)
  #expect(usage.totals.input == 10 && usage.totals.output == 5)
}

@Test(.timeLimit(.minutes(1)))
func quickChatCallsWovenToolsAndTakesSteeringAndStop() async throws {
  let model = Model()
  let gate = Gate()
  await model.then(
    { $0.toolCall(id: "call-1", name: "create_artifact", arguments: ["kind": "note", "title": "Groceries", "text": "milk"]) },
    { $0.text("Saved.") },
    { reply in reply.text("Looking"); await gate.wait() },
    { $0.text("Cats too.") },
    { reply in reply.text("Partial"); try await Task.sleep(for: .seconds(600)) })
  let phone = try await Device.start(model)
  defer { Task { await phone.device.stop(); try? FileManager.default.removeItem(at: phone.folder) } }
  let chat = try await phone.ui.call(CreateSession(runtime: .piDurable, title: "Quick Chat"))
  let watching = try await phone.watch(chat.id)

  // A Woven tool runs through the core as this session.
  _ = try await phone.ui.call(SendTurn(sessionID: chat.id, text: "note milk"))
  try await watching.idle(after: 1)
  #expect(try await phone.ui.call(ListArtifacts()).map(\.title) == ["Groceries"])

  // A message sent while the turn runs steers it, and is saved where it came.
  _ = try await phone.ui.call(SendTurn(sessionID: chat.id, text: "tell me about dogs"))
  try await watching.until { events in events.contains { if case .text(_, "Looking") = $0 { true } else { false } } }
  _ = try await phone.ui.call(SendTurn(sessionID: chat.id, text: "also cats"))
  await gate.release()
  try await watching.idle(after: 2)

  // Tools turned off for the session are gone from the next turn.
  _ = try await phone.ui.call(UpdateSession(sessionID: chat.id, tools: [.history]))
  // Stop ends the turn with what was said so far, and no failure.
  _ = try await phone.ui.call(SendTurn(sessionID: chat.id, text: "write an essay"))
  try await watching.until { events in events.contains { if case .text(_, "Partial") = $0 { true } else { false } } }
  _ = try await phone.ui.call(InterruptTurn(sessionID: chat.id))
  try await watching.idle(after: 3)

  let saved = try await phone.ui.call(SessionItems(sessionID: chat.id))
  #expect(content(saved) == [
    "user: note milk", "tool: create_artifact", "assistant: Saved.",
    "user: tell me about dogs", "assistant: Looking", "user: also cats", "assistant: Cats too.",
    "user: write an essay", "assistant: Partial",
  ])
  let requests = await model.requests
  #expect(tools(requests[0]).contains("create_artifact") && !tools(requests[4]).contains("create_artifact"))
  #expect(tools(requests[4]).contains("web_search"))
  #expect(requests[4].contains("tell me about dogs"))
}

@Test(.timeLimit(.minutes(1)))
func aQuickChatContinuesAfterTheAppStartsAgain() async throws {
  let model = Model()
  await model.then({ $0.text("Noted.") }, { $0.text("It was 42.") })
  let first = try await Device.start(model)
  defer { try? FileManager.default.removeItem(at: first.folder) }
  let chat = try await first.ui.call(CreateSession(runtime: .piDurable, title: "Quick Chat"))
  let watching = try await first.watch(chat.id)
  _ = try await first.ui.call(SendTurn(sessionID: chat.id, text: "remember 42"))
  try await watching.idle(after: 1)
  await first.device.stop()

  let again = try await Device.start(model, folder: first.folder)
  defer { Task { await again.device.stop() } }
  #expect(try await again.ui.call(ListSessions()).map(\.id) == [chat.id])
  let resumed = try await again.watch(chat.id)
  _ = try await again.ui.call(SendTurn(sessionID: chat.id, text: "which number?"))
  try await resumed.idle(after: 1)
  #expect(content(try await again.ui.call(SessionItems(sessionID: chat.id)))
            == ["user: remember 42", "assistant: Noted.", "user: which number?", "assistant: It was 42."])
  let last = try #require(await model.requests.last)
  #expect(last.contains("remember 42") && last.contains("Noted."))
}

@Test(.timeLimit(.minutes(1)))
func aQuickChatStoppedMidTurnTakesTheNextMessageAsANewTurn() async throws {
  let model = Model()
  await model.then({ reply in reply.text("Partial"); try await Task.sleep(for: .seconds(600)) },
                   { $0.text("Answer to the new one.") })
  let first = try await Device.start(model)
  defer { try? FileManager.default.removeItem(at: first.folder) }
  let chat = try await first.ui.call(CreateSession(runtime: .piDurable, title: "Quick Chat"))
  let watching = try await first.watch(chat.id)
  _ = try await first.ui.call(SendTurn(sessionID: chat.id, text: "answer slowly"))
  try await watching.until { events in events.contains { if case .text(_, "Partial") = $0 { true } else { false } } }
  await first.device.stop()

  // The stopped turn stays stopped: the next message starts a turn, once.
  let again = try await Device.start(model, folder: first.folder)
  defer { Task { await again.device.stop() } }
  let resumed = try await again.watch(chat.id)
  _ = try await again.ui.call(SendTurn(sessionID: chat.id, text: "a new message"))
  try await resumed.idle(after: 1)
  #expect(content(try await again.ui.call(SessionItems(sessionID: chat.id))) == [
    "user: answer slowly", "assistant: Partial", "notice: The session was stopped while this reply was being written.",
    "user: a new message", "assistant: Answer to the new one.",
  ])
  #expect(await model.requests.count == 2)
}

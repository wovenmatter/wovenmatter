import XCTest
import MobileInference
@testable import PiDurableRuntime

private let model = """
{"id":"test-model","name":"Stand-in model","api":"openai-responses","provider":"stand-in","baseUrl":"https://invalid.test","reasoning":false,"input":["text"],"contextWindow":100000,"maxTokens":4096,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}
"""
private let saveNote = PiToolDefinition(name: "save_note", description: "Save a note on this device",
  parameters: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#)

private func json(_ value: Any) -> String {
  String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}

/// One scripted model reply, emitted as pi-ai events.
private final class Reply: @unchecked Sendable {
  private let emit: @Sendable (String) -> Void
  private var content: [[String: Any]] = []
  private var stop = "stop"
  var usage = ["input": 10, "output": 5, "cacheRead": 2, "cacheWrite": 0]

  init(emit: @escaping @Sendable (String) -> Void) {
    self.emit = emit
    send(["type": "start"])
  }

  private var message: [String: Any] {
    ["role": "assistant", "content": content, "api": "openai-responses", "provider": "stand-in", "model": "test-model",
     "usage": usage.merging(["totalTokens": usage.values.reduce(0, +)]) { $1 }
       .mapValues { $0 as Any }.merging(["cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]]) { $1 },
     "stopReason": stop, "timestamp": Date().timeIntervalSince1970 * 1000]
  }

  private func send(_ event: [String: Any]) {
    emit(json(event.merging(event["type"] as? String == "done" ? ["message": message] : ["partial": message]) { $1 }))
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

/// A stand-in model: each request gets the next scripted reply, and is kept for the test to read.
private actor StandIn {
  typealias Step = @Sendable (Reply) async throws -> Void
  private var script: [Step]
  private(set) var requests: [String] = []

  init(_ script: [Step]) { self.script = script }

  func infer(_ request: String, emit: @escaping @Sendable (String) -> Void) async throws {
    requests.append(request)
    guard !script.isEmpty else { throw PiDurableError.failed("The stand-in model has no more replies.") }
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

/// Every event a session emits, as it comes.
@MainActor
private final class Recorder {
  private(set) var events: [PiDurableEvent] = []

  init(_ session: PiDurableSession) {
    Task { for await event in session.events { self.events.append(event) } }
  }

  func until(_ condition: ([PiDurableEvent]) -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition(events) {
      guard ContinuousClock.now < deadline else { throw PiDurableError.failed("Timed out; events so far: \(events)") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func turnFinished() async throws { try await until { $0.contains(where: \.endsTurn) } }

  /// The events, with streamed text and thinking left out.
  var items: [PiDurableEvent] {
    events.filter { if case .text = $0 { false } else if case .thinking = $0 { false } else { true } }
  }

  var text: String { events.map { if case .text(let delta) = $0 { delta } else { "" } }.joined() }
}

private extension PiDurableEvent {
  var endsTurn: Bool { if case .turnFinished = self { true } else { false } }
}

@MainActor
final class PiDurableRuntimeTests: XCTestCase {
  private var folder: URL!

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("pi-durable-tests-" + UUID().uuidString)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: folder)
  }

  private func runtime(_ model: StandIn, tools: @escaping PiDurableRuntime.ToolExecutor = { _ in PiToolResult(output: "done") }) -> PiDurableRuntime {
    PiDurableRuntime(directory: folder, inference: { try await model.infer($0, emit: $1) }, tools: tools)
  }

  private func start(_ id: String = "conversation", resume: Bool = false, tools: [PiToolDefinition] = []) -> PiDurableStart {
    PiDurableStart(conversationID: id, resume: resume, modelJSON: model, instructions: "Work on this device.", tools: tools)
  }

  func testATurnStreamsTextAndEndsWithOneMessageAndItsUsage() async throws {
    let standIn = StandIn([{ $0.text("Hel", "lo") }])
    let session = try await runtime(standIn).open(start())
    let recorder = Recorder(session)
    try await session.send("hello")
    try await recorder.turnFinished()
    XCTAssertEqual(recorder.text, "Hello")
    XCTAssertEqual(recorder.items, [
      .userMessage(text: "hello"), .messageFinished(text: "Hello"),
      .turnFinished(failure: nil, usage: PiTokenUsage(model: "stand-in/test-model", input: 10, output: 5, cacheRead: 2, cacheWrite: 0)),
    ])
    await session.close()
  }

  func testAToolCallStartsAndFinishesInOrderAndTheModelSeesItsResult() async throws {
    let fixture = ResponsesFixture()
    let connection = InferenceConnection(id: "fixture-account", name: "Fixture", provider: "openai", modelID: "gpt-4.1")
    let service = MobileInferenceService(connection: connection, credentials: FixtureCredentials(), transport: fixture,
      model: InferenceModel(id: connection.modelID, name: "Fixture", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1"))
    let descriptor = try await service.model().descriptorJSON()
    let runtime = PiDurableRuntime(directory: folder, inference: { try await service.stream(requestJSON: $0, emit: $1) },
                                   tools: { request in PiToolResult(output: "Note saved: " + request.arguments) })
    let session = try await runtime.open(PiDurableStart(conversationID: "tools", resume: false, modelJSON: descriptor, tools: [saveNote]))
    let recorder = Recorder(session)
    try await session.send("save a note")
    try await recorder.turnFinished()

    guard case .toolStarted(let callID, "save_note", let input) = recorder.items[1],
          case .toolFinished(callID, "save_note", input, let output, false) = recorder.items[2] else {
      return XCTFail("Expected the tool call to start and finish: \(recorder.items)")
    }
    XCTAssertTrue(input.contains("saved through native inference"))
    XCTAssertEqual(output, #"Note saved: {"text":"saved through native inference"}"#)
    XCTAssertEqual(Array(recorder.items.dropFirst(3)), [.messageFinished(text: "Saved using native inference."),
                                                       .turnFinished(failure: nil, usage: recorder.usage)])
    let second = await fixture.bodies.last ?? ""
    XCTAssertTrue(second.contains("Note saved"), "The model did not get the tool's result")
    await session.close()
  }

  func testSteeringARunningTurnIsTakenInAndTheTurnEndsOnce() async throws {
    let gate = Gate()
    let standIn = StandIn([
      { reply in reply.text("Looking"); await gate.wait() },
      { $0.text("Cats too.") },
    ])
    let session = try await runtime(standIn).open(start())
    let recorder = Recorder(session)
    try await session.send("tell me about dogs")
    try await recorder.until { _ in recorder.text == "Looking" }
    let steered = try await session.steer("also cats")
    XCTAssertTrue(steered)
    await gate.release()
    try await recorder.turnFinished()

    let requests = await standIn.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[1].contains("also cats"))
    XCTAssertEqual(recorder.items.dropLast(), [
      .userMessage(text: "tell me about dogs"), .messageFinished(text: "Looking"),
      .userMessage(text: "also cats"), .messageFinished(text: "Cats too."),
    ])
    XCTAssertEqual(recorder.events.filter(\.endsTurn).count, 1)
    let late = try await session.steer("nothing is running")
    XCTAssertFalse(late)
    await session.close()
  }

  func testInterruptEndsTheTurnOnceWithWhatWasSaidSoFar() async throws {
    let standIn = StandIn([{ reply in reply.text("Partial"); try await Task.sleep(for: .seconds(600)) }])
    let session = try await runtime(standIn).open(start())
    let recorder = Recorder(session)
    try await session.send("write a long essay")
    try await recorder.until { _ in recorder.text == "Partial" }
    try await session.interrupt()
    try await recorder.turnFinished()
    try await Task.sleep(for: .milliseconds(200))

    XCTAssertEqual(recorder.items.count, 3)
    XCTAssertEqual(Array(recorder.items.prefix(2)), [.userMessage(text: "write a long essay"), .messageFinished(text: "Partial")])
    guard case .turnFinished(nil, _) = recorder.items[2] else { return XCTFail("The turn did not end cleanly: \(recorder.items)") }
    await session.close()
  }

  func testAQuestionWaitsForThePersonsAnswer() async throws {
    let standIn = StandIn([
      { $0.toolCall(id: "ask-1", name: "ask_user", arguments: ["question": "Which color?"]) },
      { $0.text("Blue it is.") },
    ])
    let session = try await runtime(standIn).open(start(tools: [.askUser]))
    let recorder = Recorder(session)
    try await session.send("pick a color with me")
    try await recorder.until { $0.contains(.prompt(id: "ask-1", question: "Which color?")) }
    try session.answer(promptID: "ask-1", text: "Blue")
    try await recorder.turnFinished()

    XCTAssertTrue(recorder.items.contains(.promptResolved(id: "ask-1")))
    XCTAssertTrue(recorder.items.contains(.toolFinished(callID: "ask-1", name: "ask_user", input: #"{"question":"Which color?"}"#,
                                                        output: "Blue", failed: false)))
    let requests = await standIn.requests
    XCTAssertTrue(requests.last?.contains("Blue") == true)
    await session.close()
  }

  func testReopeningAConversationContinuesIt() async throws {
    let standIn = StandIn([{ $0.text("Noted.") }, { $0.text("It was 42.") }])
    do {
      _ = try await runtime(standIn).open(start("later", resume: true))
      XCTFail("A conversation that was never started opened")
    } catch PiDurableError.conversationGone {}

    let first = try await runtime(standIn).open(start("later"))
    let recorder = Recorder(first)
    try await first.send("remember 42")
    try await recorder.turnFinished()
    await first.close()

    let second = try await runtime(standIn).open(start("later", resume: true))
    let again = Recorder(second)
    try await second.send("which number?")
    try await again.turnFinished()
    let requests = await standIn.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[1].contains("remember 42") && requests[1].contains("Noted."))
    XCTAssertEqual(again.items.first, .userMessage(text: "which number?"))
    await second.close()
  }

  func testATurnCutShortByClosingIsSettledWhenReopenedAndTheNextMessageStartsATurn() async throws {
    let standIn = StandIn([{ _ in try await Task.sleep(for: .seconds(600)) }, { $0.text("Here now.") }])
    let first = try await runtime(standIn).open(start("cut"))
    let recorder = Recorder(first)
    try await first.send("answer slowly")
    try await recorder.until { _ in !recorder.items.isEmpty }
    try await Task.sleep(for: .milliseconds(100))
    await first.close()
    try await recorder.turnFinished()
    XCTAssertEqual(recorder.items, [.userMessage(text: "answer slowly"),
                                    .turnFinished(failure: "The conversation was closed during the turn.", usage: nil)])

    // The host saved that turn as stopped, so it does not run again by itself.
    let second = try await runtime(standIn).open(start("cut", resume: true))
    let reopened = Recorder(second)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertEqual(reopened.items, [])
    try await second.send("and now?")
    try await reopened.turnFinished()
    XCTAssertEqual(Array(reopened.items.prefix(2)), [.userMessage(text: "and now?"), .messageFinished(text: "Here now.")])
    guard case .turnFinished(nil, _) = reopened.items.last else { return XCTFail("The new turn did not end: \(reopened.items)") }
    let requests = await standIn.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[1].contains("and now?"))
    await second.close()
  }
}

private extension Recorder {
  var usage: PiTokenUsage? {
    for case .turnFinished(_, let usage) in events { return usage }
    return nil
  }
}

private struct FixtureCredentials: InferenceCredentialReading {
  func read(connectionID: String) async throws -> String? { "fixture-secret" }
}

/// OpenAI Responses over a stand-in transport: a tool call, then an answer.
private actor ResponsesFixture: InferenceHTTPTransport {
  private(set) var bodies: [String] = []
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    bodies.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
    let output: [[String: Any]] = bodies.count == 1
      ? [["type": "function_call", "call_id": "call_1", "name": "save_note", "arguments": #"{"text":"saved through native inference"}"#]]
      : [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Saved using native inference."]]]]
    let completion = json(["type": "response.completed", "response": ["id": "response-\(bodies.count)", "status": "completed", "output": output,
                                                                      "usage": ["input_tokens": 10, "output_tokens": 8]]])
    return AsyncThrowingStream { stream in
      stream.yield(.response(200)); stream.yield(.line("data: " + completion)); stream.yield(.line("")); stream.finish()
    }
  }
}

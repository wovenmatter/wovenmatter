import XCTest
import CompanionInference
@testable import PiDurableRuntime

private func json(_ value: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
private func object(_ value: String) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
}
private let testModel = """
{"id":"test-model","name":"Controlled model","api":"openai-responses","provider":"controlled","baseUrl":"https://invalid.test","reasoning":false,"input":["text"],"contextWindow":100000,"maxTokens":4096,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}
"""
private let testTools = """
[{"name":"save_note","description":"Save a note on this device","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}}]
"""
private actor ControlledHost {
  var inferenceCalls = 0
  var toolCalls = 0
  var toolsSeen: [String] = []
  var requests: [String] = []
  enum Mode: Sendable { case normal, subagent, code }
  var mode: Mode = .normal
  func mode(_ value: Mode) { mode = value }
  var holdTool = false
  var toolStarted = false

  func inference(_ request: String, emit: @escaping @Sendable (String) -> Void) async throws {
    inferenceCalls += 1; requests.append(request)
    let payload = try object(request)
    let context = payload["context"] as? [String: Any]
    let messages = context?["messages"] as? [[String: Any]] ?? []
    let finishedTool = messages.contains { $0["role"] as? String == "toolResult" }
    let isChild = messages.contains { ($0["content"] as? String) == "delegated task" }
    let call: [String: Any]
    if mode == .subagent && !isChild {
      call = ["type":"toolCall","id":"call-child","name":"subagent","arguments":["task":"delegated task","name":"Researcher"]]
    } else if mode == .code {
      call = ["type":"toolCall","id":"call-code","name":"codemode","arguments":["code":"const result = await tools.save_note({text:'café 🟩'}); text(result); store('saved', true);"]]
    } else {
      call = ["type":"toolCall","id":"call-native-note","name":"save_note","arguments":["text":"café 🟩"]]
    }
    let content: [[String: Any]] = finishedTool
      ? [["type":"text","text":"Saved café 🟩 on this device."]] : [call]
    let message: [String: Any] = ["role":"assistant","content":content,"api":"openai-responses","provider":"controlled","model":"test-model",
      "usage":["input":10,"output":8,"cacheRead":0,"cacheWrite":0,"totalTokens":18,"cost":["input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0]],
      "stopReason":finishedTool ? "stop" : "toolUse","timestamp":Date().timeIntervalSince1970 * 1000]
    emit(try json(["type":"start","partial":message]))
    emit(try json(["type":"done","reason":finishedTool ? "stop" : "toolUse","message":message]))
  }
  func tool(_ request: String) async throws -> String {
    toolCalls += 1; toolStarted = true; toolsSeen.append(request)
    if holdTool { try await Task.sleep(for: .seconds(120)) }
    return try json(["content":[["type":"text","text":"Note saved: café 🟩"]]])
  }
  func hold() { holdTool = true }
  func counts() -> (Int,Int) { (inferenceCalls,toolCalls) }
}

private struct IntegrationCredentials: InferenceCredentialReading {
  func read(connectionID: String) async throws -> String? { "fixture-secret-kept-native" }
}
private actor ResponsesFixture: InferenceHTTPTransport {
  var requests: [URLRequest] = []
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    requests.append(request)
    let content: [[String:Any]] = requests.count == 1
      ? [["type":"function_call","call_id":"native_tool_1","name":"save_note","arguments":"{\"text\":\"saved through native inference\"}"]]
      : [["type":"message","role":"assistant","content":[["type":"output_text","text":"Saved using native inference."]]]]
    let completion = try json(["type":"response.completed","response":["id":"fixture-response-\(requests.count)","status":"completed","output":content,"usage":["input_tokens":10,"output_tokens":8]]])
    return AsyncThrowingStream { output in
      output.yield(.response(200)); output.yield(.line("data: " + completion)); output.yield(.line("")); output.finish()
    }
  }
}

@MainActor
final class PiDurableRuntimeTests: XCTestCase {
  private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pi-ios-tests-" + UUID().uuidString) }
  private func runtime(_ directory: URL, host: ControlledHost, events: @escaping PiDurableRuntime.Events = { _ in }) throws -> PiDurableRuntime {
    try PiDurableRuntime(storageDirectory: directory,
      configuration: .init(conversationID: "ios-conversation", modelJSON: testModel, toolsJSON: testTools, instructions: "Work on this device."),
      inference: { try await host.inference($0, emit: $1) }, tool: { try await host.tool($0) }, onEvents: events)
  }

  func testRealSDKRunsNativeToolAndReopensWithoutDuplicatingSubmission() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let host = ControlledHost()
    var events: [String] = []
    let first = try runtime(path, host: host) { events.append($0) }
    _ = try await first.open()
    let accepted = try object(await first.submit(text: "Save this note", requestID: "stable-request"))
    let id = try XCTUnwrap(accepted["id"] as? Int)
    let settled = try object(await first.wait(submissionID: id))
    XCTAssertEqual(settled["status"] as? String, "done")
    let snapshot = try await first.snapshot()
    XCTAssertTrue(snapshot.contains("Saved café 🟩 on this device."), snapshot)
    XCTAssertTrue(events.contains { $0.contains("tool_execution_start") })
    XCTAssertTrue(events.contains { $0.contains("message_end") })
    try await first.close()
    XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("main.jsonl").path))

    let second = try runtime(path, host: host)
    _ = try await second.open()
    let recoveredReceipt = try await second.submission(requestID: "stable-request")
    XCTAssertEqual(try object(XCTUnwrap(recoveredReceipt))["id"] as? Int, id)
    let missingReceipt = try await second.submission(requestID: "never-admitted")
    XCTAssertNil(missingReceipt)
    let history = try object(await second.history(limit: 2))
    XCTAssertEqual((history["items"] as? [Any])?.count, 2)
    let cursor = try json(XCTUnwrap(history["next"]))
    let older = try object(await second.history(cursorJSON: cursor, limit: 2))
    XCTAssertEqual((older["items"] as? [Any])?.count, 2)
    let duplicate = try object(await second.submit(text: "Save this note", requestID: "stable-request"))
    XCTAssertEqual(duplicate["id"] as? Int, id)
    XCTAssertEqual(duplicate["status"] as? String, "done")
    let restored = try await second.snapshot()
    XCTAssertTrue(restored.contains("café 🟩"))
    try await second.close()
    let counts = await host.counts()
    XCTAssertEqual(counts.0, 2, "One model turn requests a tool and one produces the final answer")
    XCTAssertEqual(counts.1, 1, snapshot)
    let toolsSeen = await host.toolsSeen
    XCTAssertEqual(try object(XCTUnwrap(toolsSeen.first))["toolCallID"] as? String, "call-native-note")
    let request = try object(await host.requests[0])
    let scope = try XCTUnwrap(request["scope"] as? [String:Any])
    XCTAssertTrue((scope["conversationID"] as? String)?.hasPrefix("ios-conversation:") == true)
    XCTAssertTrue((scope["requestID"] as? String)?.hasPrefix("ios-conversation:") == true)
  }

  func testSuspensionRecoversWithoutReplayingUnsafeTool() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let host = ControlledHost(); await host.hold()
    let first = try runtime(path, host: host)
    _ = try await first.open()
    let receipt = try object(await first.submit(text: "Save note", requestID: "interrupted"))
    let id = try XCTUnwrap(receipt["id"] as? Int)
    for _ in 0..<200 {
      if await host.toolStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let toolStarted = await host.toolStarted
    XCTAssertTrue(toolStarted)
    try await first.close()

    let second = try runtime(path, host: host)
    let restored = try await second.open()
    XCTAssertTrue(restored.contains("save_note"))
    let countsBeforeResume = await host.counts()
    XCTAssertEqual(countsBeforeResume.1, 1, "Opening a viewer must not execute pending tools")
    try await second.resume()
    let settled = try object(await second.wait(submissionID: id))
    XCTAssertEqual(settled["status"] as? String, "done")
    let snapshot = try await second.snapshot()
    XCTAssertTrue(snapshot.contains("interrupted"), snapshot)
    let counts = await host.counts()
    XCTAssertEqual(counts.1, 1, "Side effect with unknown completion must not run again")
    try await second.close()
  }

  func testExplicitStopIsPersistedAndDoesNotResume() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let host = ControlledHost(); await host.hold()
    let first = try runtime(path, host: host)
    _ = try await first.open()
    let receipt = try object(await first.submit(text: "Save note", requestID: "cancelled"))
    let id = try XCTUnwrap(receipt["id"] as? Int)
    for _ in 0..<200 {
      if await host.toolStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await first.abort()
    let stopped = try object(await first.wait(submissionID: id))
    XCTAssertEqual(stopped["status"] as? String, "unanswered")
    try await first.close()
    let count = await host.counts()
    let second = try runtime(path, host: host)
    _ = try await second.open()
    try await second.resume()
    let again = try object(await second.wait(submissionID: id))
    XCTAssertEqual(again["status"] as? String, "unanswered")
    XCTAssertEqual(again["reason"] as? String, stopped["reason"] as? String)
    let after = await host.counts()
    XCTAssertEqual(after.0,count.0); XCTAssertEqual(after.1,count.1)
    try await second.close()
  }

  func testSDKThroughNativeInferenceServiceAndNativeToolsWithoutNetwork() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let fixture = ResponsesFixture()
    let connection = InferenceConnection(id: "fixture-account", name: "Controlled inference", provider: "openai", route: .direct, modelID: "gpt-4.1")
    let service = CompanionInferenceService(connection: connection, credentials: IntegrationCredentials(), transport: fixture)
    let descriptor = try await service.model().descriptorJSON()
    let host = ControlledHost()
    let engine = try PiDurableRuntime(storageDirectory: path,
      configuration: .init(conversationID: "native-integration", modelJSON: descriptor, toolsJSON: testTools),
      inference: { request,emit in try await service.stream(requestJSON: request, emit: emit) },
      tool: { try await host.tool($0) })
    _ = try await engine.open()
    let receipt = try object(await engine.submit(text: "Save with native tools", requestID: "native-request"))
    let settled = try object(await engine.wait(submissionID: XCTUnwrap(receipt["id"] as? Int)))
    XCTAssertEqual(settled["status"] as? String, "done")
    let history = try await engine.history()
    XCTAssertTrue(history.contains("Saved using native inference."), history)
    XCTAssertFalse(history.contains("fixture-secret-kept-native"))
    let toolCount = await host.toolCalls
    XCTAssertEqual(toolCount, 1)
    let requests = await fixture.requests
    XCTAssertEqual(requests.count, 2)
    let second = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.httpBody)) as? [String:Any])
    let input = try XCTUnwrap(second["input"] as? [[String:Any]])
    XCTAssertTrue(input.contains { $0["type"] as? String == "function_call_output" })
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret-kept-native")
    try await engine.close()
    let files = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
    for file in files where file.pathExtension == "jsonl" {
      XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("fixture-secret-kept-native"))
    }
  }

  func testOwnedSubagentUsesSameModelAndIndependentProviderSession() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let host = ControlledHost(); await host.mode(.subagent)
    let engine = try runtime(path, host: host)
    _ = try await engine.open()
    let receipt = try object(await engine.submit(text: "Delegate the note", requestID: "parent-request"))
    let id = try XCTUnwrap(receipt["id"] as? Int)
    let settled = try object(await engine.wait(submissionID: id))
    XCTAssertEqual(settled["status"] as? String, "done")
    let conversations = try object(await engine.conversations())
    XCTAssertEqual((conversations["items"] as? [Any])?.count, 2)
    let counts = await host.counts()
    XCTAssertEqual(counts.0, 4); XCTAssertEqual(counts.1, 1)
    let requests = await host.requests
    let scopes = try requests.map { try object($0)["scope"] as? [String:Any] }
    XCTAssertEqual(Set(scopes.compactMap { $0?["conversationID"] as? String }).count, 2)
    XCTAssertTrue(try requests.allSatisfy { (try object($0)["model"] as? [String:Any])?["id"] as? String == "test-model" })
    try await engine.close()
  }

  func testCodeModeUsesDurableNestedToolAndStoresConversationValues() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let host = ControlledHost(); await host.mode(.code)
    let engine = try runtime(path, host: host)
    _ = try await engine.open()
    let receipt = try object(await engine.submit(text: "Use code to save note", requestID: "code-request"))
    let id = try XCTUnwrap(receipt["id"] as? Int)
    let settled = try object(await engine.wait(submissionID: id))
    XCTAssertEqual(settled["status"] as? String, "done")
    let history = try await engine.history()
    XCTAssertTrue(history.contains("woven.ios-codemode-store"), history)
    XCTAssertTrue(history.contains("wovenNestedCall"), history)
    let counts = await host.counts()
    XCTAssertEqual(counts.1, 1, history)
    let requests = await host.toolsSeen
    XCTAssertTrue(try object(XCTUnwrap(requests.first))["toolCallID"] as? String == "call-code/nested/1")
    try await engine.close()
  }

  func testCodeModeInterruptionDoesNotReplayNestedUnsafeEffect() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let host = ControlledHost(); await host.mode(.code); await host.hold()
    let first = try runtime(path, host: host)
    _ = try await first.open()
    let receipt = try object(await first.submit(text: "Code note", requestID: "interrupted-code"))
    let id = try XCTUnwrap(receipt["id"] as? Int)
    for _ in 0..<300 {
      if await host.toolStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let started = await host.toolStarted; XCTAssertTrue(started)
    try await first.close()
    let second = try runtime(path, host: host)
    _ = try await second.open(); try await second.resume()
    _ = try await second.wait(submissionID: id)
    let history = try await second.history()
    XCTAssertTrue(history.contains("interrupted"), history)
    let count = await host.toolCalls; XCTAssertEqual(count, 1)
    try await second.close()
  }

  func testStoppingParentCancelsOwnedSubagentTool() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let host = ControlledHost(); await host.mode(.subagent); await host.hold()
    let engine = try runtime(path, host: host)
    _ = try await engine.open()
    let receipt = try object(await engine.submit(text: "Delegate note", requestID: "stop-child"))
    let id = try XCTUnwrap(receipt["id"] as? Int)
    for _ in 0..<300 {
      if await host.toolStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let started = await host.toolStarted; XCTAssertTrue(started)
    try await engine.abort()
    let stopped = try object(await engine.wait(submissionID: id))
    XCTAssertEqual(stopped["status"] as? String, "unanswered")
    let count = await host.toolCalls; XCTAssertEqual(count, 1)
    try await engine.close()
  }

  func testCodeWorkerHasNoNetworkOrNativeHostAccessAndCanBeTerminated() async throws {
    let executor = PiCodeModeExecutor()
    let input = try json(["source":"let blocked = false; try { await fetch('https://example.invalid'); } catch { blocked = true; } text({blocked, window:typeof window, process:typeof process, host:typeof __wmNativeSync});", "tools":[], "state":[:]] as [String:Any])
    let output = try await executor.run(requestJSON: input) { _,_ in XCTFail("Unexpected tool"); return "{}" }
    XCTAssertTrue(output.contains("blocked")); XCTAssertTrue(output.contains("true")); XCTAssertTrue(output.contains("undefined"))
    let loop = PiCodeModeExecutor()
    let loopInput = try json(["source":"while (true) {}", "tools":[], "state":[:]] as [String:Any])
    do { _ = try await loop.run(requestJSON: loopInput, timeout: .milliseconds(300)) { _,_ in "{}" }; XCTFail("Unbounded code was not terminated") }
    catch { XCTAssertTrue(error.localizedDescription.contains("limit"), error.localizedDescription) }
  }

  func testSingleWriterAndTruncatedTailRecovery() async throws {
    let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
    let host = ControlledHost()
    let first = try runtime(path, host: host)
    _ = try await first.open()
    let competing = try runtime(path, host: host)
    do { _ = try await competing.open(); XCTFail("Two SDK writers opened one journal") }
    catch PiDurableRuntimeError.storageInUse { }
    try await first.close()
    let main = path.appendingPathComponent("main.jsonl")
    let before = try Data(contentsOf: main)
    var torn = before; torn.append(Data("{\"format\":1,\"type\":\"commit\"".utf8)); try torn.write(to: main)
    let recovered = try runtime(path, host: host)
    _ = try await recovered.open()
    let after = try Data(contentsOf: main)
    XCTAssertTrue(after.starts(with: before))
    XCTAssertEqual(after.last, 10, "SDK removes an incomplete uncommitted tail")
    try await recovered.close()
  }
}

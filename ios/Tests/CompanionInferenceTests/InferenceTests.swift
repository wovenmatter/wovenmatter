import XCTest
@testable import CompanionInference

private final class CapturedEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func append(_ value: String) { lock.withLock { values.append(value) } }
  var events: [InferenceObject] { lock.withLock { values.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? InferenceObject } } }
}
private struct TestCredentials: InferenceCredentialReading {
  func read(connectionID: String) async throws -> String? { "fixture-secret" }
}
private actor SelectedCredentials: InferenceCredentialReading {
  var requestedIDs = [String]()
  func read(connectionID: String) async throws -> String? {
    requestedIDs.append(connectionID)
    return connectionID == "selected-connection" ? "selected-secret" : "unrelated-secret"
  }
}
private actor FixtureTransport: InferenceHTTPTransport {
  let events: [InferenceHTTPEvent]
  var requests = [URLRequest]()
  init(_ events: [InferenceHTTPEvent]) { self.events = events }
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    requests.append(request)
    return AsyncThrowingStream { output in events.forEach { output.yield($0) }; output.finish() }
  }
}

@MainActor
final class InferenceTests: XCTestCase {
  let connection = InferenceConnection(id: "phone-key", name: "API", provider: "openai", route: .direct, modelID: "gpt-4")
  let model = InferenceModel(id: "gpt-4", name: "GPT", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1")
  func testThinkingChoicesAndRequestsFollowSelectedModelCapabilities() throws {
    var model = InferenceModel(id: "test", name: "Test", provider: "openai", api: "openai-responses", baseUrl: "https://api.openai.com/v1")
    XCTAssertEqual(model.supportedThinkingLevels, ["off"])
    XCTAssertEqual(model.middleThinkingLevel, "off")
    model.reasoning = true
    XCTAssertEqual(model.supportedThinkingLevels, ["off", "minimal", "low", "medium", "high"])
    XCTAssertEqual(model.middleThinkingLevel, "medium")
    // An omitted ordinary level is supported. Explicit null disables it;
    // extended levels must be explicitly enabled, matching the desktop Pi SDK.
    model.thinkingLevelMap = ["off": nil, "minimal": nil, "xhigh": "xhigh", "max": "ultra"]
    XCTAssertEqual(model.supportedThinkingLevels, ["low", "medium", "high", "xhigh", "max"])
    XCTAssertEqual(model.middleThinkingLevel, "high")
    model.thinkingLevelMap = ["minimal": nil, "xhigh": "xhigh", "max": nil]
    XCTAssertEqual(model.supportedThinkingLevels, ["off", "low", "medium", "high", "xhigh"])
    XCTAssertEqual(model.middleThinkingLevel, "high")
      model.thinkingLevelMap = ["minimal": nil, "max": "ultra"]
    let connection = InferenceConnection(name: "API", provider: model.provider, route: .direct, modelID: model.id)
    for (level, expected) in [("high", "high"), ("max", "ultra"), ("minimal", nil), ("off", nil)] {
      let request = try InferenceRequestBuilder(connection: connection, model: model).request(
        ["context": ["messages": [["role": "user", "content": "hello"]]], "options": ["reasoning": level]], secret: "fixture")
      let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? InferenceObject)
      XCTAssertEqual(inferenceObject(body["reasoning"])["effort"] as? String, expected)
    }
  }

  private func fixture(_ provider: String = "openai", api: String = "openai-responses", image: Bool = true) -> InferenceModel {
    var value = InferenceModel(id: "fixture-chat", name: "Fixture chat", provider: provider, api: api,
      baseUrl: InferenceModelPolicy.endpoints[provider]![api]!, input: image ? ["text", "image"] : ["text"])
    value.metadata["cost"] = .object(["input": .number(1), "output": .number(2), "cacheRead": .number(0), "cacheWrite": .number(0),
      "tiers": .array([.object(["inputTokensAbove": .number(100), "input": .number(2)])])])
    value.metadata["compat"] = .object(["supportsStrictMode": .bool(true)])
    return value
  }
  func testEndpointPolicyRejectsCredentialRedirectDestinations() throws {
    // Synthetic octets keep this fixture independent of any user network.
    func address(_ labels: [String]) -> String { labels.joined(separator: ".") }
    let tailnet = address(["100", "64", "2", "9"])
    for value in ["http://\(tailnet):8080", "https://work.example.ts.net", "http://[fd7a:115c:a1e0::1234]:8080/v1"] {
      XCTAssertNoThrow(try InferenceURLPolicy.tailnet(value))
    }
    let outside = address(["100", "128", "1", "1"])
    let spoofed = address(["100", "64", "0", "1", "evil", "com"])
    let mixed = address(["100", "64", "bad", "0", "1"])
    let invalid = address(["100", "64", "0", "999"])
    for value in ["https://evil.example", "https://foo.ts.net.evil.example", "http://\(outside)", "http://\(spoofed)", "http://\(mixed)", "http://\(invalid)", "https://u:p@host.ts.net", "https://host.ts.net?token=x"] {
      XCTAssertThrowsError(try InferenceURLPolicy.tailnet(value))
    }
  }
  func testTruncatedResponseCannotBecomeSuccessfulOrExposeCompletedTool() throws {
    let capture = CapturedEvents(), decoder = InferenceStreamDecoder(model: model, connectionID: connection.id, emit: capture.append)
    try decoder.consume("{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"call\",\"name\":\"write\"}}")
    try decoder.consume("{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\"}")
    XCTAssertThrowsError(try decoder.finish())
    XCTAssertFalse(capture.events.contains { ["toolcall_end", "done"].contains($0["type"] as? String ?? "") })
  }
  func testAnthropicStreamingPreservesThinkingSignatureAndToolArguments() throws {
    var anthropic = model; anthropic.provider = "anthropic"; anthropic.api = "anthropic-messages"
    let capture = CapturedEvents(), decoder = InferenceStreamDecoder(model: anthropic, connectionID: "key", emit: capture.append)
    for value: InferenceObject in [
      ["type": "message_start", "message": ["id": "m", "usage": ["input_tokens": 7]]],
      ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
      ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "plan"]],
      ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "opaque-signature"]],
      ["type": "content_block_stop", "index": 0],
      ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "t", "name": "read", "input": [:]]],
      ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"path\":\"a\"}"]],
      ["type": "content_block_stop", "index": 1],
      ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 9]],
      ["type": "message_stop"],
    ] { try decoder.consume(try inferenceJSONString(value)) }
    let result = inferenceObject(try XCTUnwrap(capture.events.last)["message"])
    XCTAssertEqual(inferenceObjects(result["content"]).first?["thinkingSignature"] as? String, "opaque-signature")
    XCTAssertEqual(result["stopReason"] as? String, "toolUse")
    XCTAssertEqual(inferenceObject(result["usage"])["totalTokens"] as? Int, 16)
  }
  func testChatCompletionsPreservesOpaqueReasoningAcrossToolExchange() throws {
    var chat = model; chat.api = "openai-completions"; chat.provider = "openrouter"; chat.baseUrl = "https://openrouter.ai/api/v1"
    let capture = CapturedEvents(), decoder = InferenceStreamDecoder(model: chat, connectionID: "route", emit: capture.append)
    try decoder.consume(try inferenceJSONString(["choices": [["delta": ["reasoning_details": [["type": "reasoning.encrypted", "data": "opaque", "id": "r"]], "tool_calls": [["index": 0, "id": "call", "function": ["name": "read", "arguments": "{}"]]]]]]]))
    try decoder.consume(try inferenceJSONString(["choices": [["delta": [:], "finish_reason": "tool_calls"]]])); try decoder.consume("[DONE]")
    let message = inferenceObject(try XCTUnwrap(capture.events.last)["message"])
    let connection = InferenceConnection(id: "route", name: "Router", provider: "openrouter", route: .direct, modelID: chat.id)
    let request = try InferenceRequestBuilder(connection: connection, model: chat).request(["context": ["messages": [message]]], secret: "fixture")
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? InferenceObject)
    XCTAssertEqual(inferenceObjects(inferenceObjects(body["messages"]).first?["reasoning_details"]).first?["data"] as? String, "opaque")
  }
  private let firstImage = "Zmlyc3QtaW1hZ2U="
  private let secondImage = "c2Vjb25kLWltYWdl"
  private func imageToolTranscript() -> [InferenceObject] {
    [
      ["role": "assistant", "content": [
        ["type": "toolCall", "id": "read-a|native-a", "name": "read_image", "arguments": ["path": "a.png"]],
        ["type": "toolCall", "id": "read-b|native-b", "name": "read_image", "arguments": ["path": "b.png"]]
      ]],
      ["role": "toolResult", "toolCallId": "read-a|native-a", "toolName": "read_image", "content": [
        ["type": "text", "text": "First image"], ["type": "image", "mimeType": "image/png", "data": firstImage]
      ]],
      ["role": "toolResult", "toolCallId": "read-b|native-b", "toolName": "read_image", "content": [
        ["type": "image", "mimeType": "image/jpeg", "data": secondImage]
      ]]
    ]
  }
  func testSelectedConnectionPreservesToolImagesAndRejectsForeignProvider() async throws {
    let model = fixture()
    let connection = InferenceConnection(id: "selected-connection", name: "Selected", provider: model.provider, accountID: "selected-account", route: .direct, modelID: model.id)
    let credentials = SelectedCredentials()
    let transport = FixtureTransport([.response(200), .line("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{}}}"), .line("")])
    let service = CompanionInferenceService(connection: connection, credentials: credentials, transport: transport, model: model)
    let input: InferenceObject = ["model": ["id": model.id, "provider": model.provider, "baseUrl": "https://unrelated.example/v1"],
      "accountID": "unrelated-account", "options": ["apiKey": "unrelated-secret"], "context": ["messages": imageToolTranscript()]]
    let capture = CapturedEvents()
    try await service.stream(requestJSON: inferenceJSONString(input), emit: capture.append)
    XCTAssertEqual(capture.events.last?["type"] as? String, "done")
    do {
      try await service.stream(requestJSON: inferenceJSONString(["model": ["id": model.id, "provider": "anthropic"]]), emit: capture.append)
      XCTFail("wrong provider accepted")
    } catch { XCTAssertEqual(error as? InferenceError, .modelUnavailable) }
    let requests = await transport.requests, requestedIDs = await credentials.requestedIDs
    XCTAssertEqual(requests.count, 1); XCTAssertEqual(requestedIDs, ["selected-connection"])
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.absoluteString, model.baseUrl + "/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer selected-secret")
    let bodyData = try XCTUnwrap(request.httpBody), body = inferenceObject(try JSONSerialization.jsonObject(with: bodyData))
    XCTAssertEqual(body["model"] as? String, model.id)
    XCTAssertFalse(String(decoding: bodyData, as: UTF8.self).contains("unrelated"))
    let outputs = inferenceObjects(body["input"]).filter { $0["type"] as? String == "function_call_output" }
    XCTAssertEqual(outputs.map { $0["call_id"] as? String }, ["read-a", "read-b"])
    let mixed = inferenceObjects(outputs[0]["output"]), imageOnly = inferenceObjects(outputs[1]["output"])
    XCTAssertEqual(mixed.map { $0["type"] as? String }, ["input_text", "input_image"])
    XCTAssertEqual(mixed[0]["text"] as? String, "First image")
    XCTAssertEqual(mixed[1]["image_url"] as? String, "data:image/png;base64,\(firstImage)")
    XCTAssertEqual(mixed[1]["detail"] as? String, "auto")
    XCTAssertEqual(imageOnly.count, 1)
    XCTAssertEqual(imageOnly[0]["image_url"] as? String, "data:image/jpeg;base64,\(secondImage)")
  }

  func testChatToolImageCompatibilitySeparatorPrecedesFollowingUserMessage() throws {
    var model = fixture("openrouter", api: "openai-completions")
    model.metadata["compat"] = .object(["requiresAssistantAfterToolResult": .bool(true), "requiresToolResultName": .bool(true)])
    let connection = InferenceConnection(name: "Selected", provider: model.provider, route: .direct, modelID: model.id)
    let transcript = imageToolTranscript() + [["role": "user", "content": "Compare these."]]
    let request = try InferenceRequestBuilder(connection: connection, model: model).request(["context": ["messages": transcript]], secret: "fixture")
    let body = inferenceObject(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))), messages = inferenceObjects(body["messages"])
    XCTAssertEqual(messages.map { $0["role"] as? String }, ["assistant", "tool", "tool", "assistant", "user", "user"])
    XCTAssertEqual(messages[1]["name"] as? String, "read_image")
    XCTAssertEqual(messages[2]["name"] as? String, "read_image")
    XCTAssertEqual(inferenceObjects(messages[4]["content"]).filter { $0["type"] as? String == "image_url" }.count, 2)
    XCTAssertEqual(inferenceObjects(messages[5]["content"]).first?["text"] as? String, "Compare these.")
  }
  func testUnsupportedOrMalformedToolImagesFailBeforeAnyProviderRequest() async throws {
    for (provider, api) in [("openai", "openai-responses"), ("openrouter", "openai-completions")] {
      for malformed in [false, true] {
        let model = fixture(provider, api: api, image: malformed)
        let connection = InferenceConnection(name: "Fixture", provider: provider, route: .direct, modelID: model.id)
        let transport = FixtureTransport([])
        let service = CompanionInferenceService(connection: connection, credentials: TestCredentials(), transport: transport, model: model)
        let input: InferenceObject = ["model": ["id": model.id, "provider": provider], "context": ["messages": [
          ["role": "toolResult", "toolCallId": "read-image", "content": [
            ["type": "text", "text": "Image follows"], ["type": "image", "mimeType": "image/png", "data": malformed ? "invalid-base64!" : firstImage]
          ]]
        ]]]
        do {
          try await service.stream(requestJSON: inferenceJSONString(input), emit: { _ in XCTFail("Rejected image produced a model event") })
          XCTFail("Unsupported or malformed tool image was accepted")
        } catch { XCTAssertEqual(error as? InferenceError, malformed ? .invalidConfiguration : .unsupportedImageInput) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty, "Invalid image input must not cause a partial request or provider fallback")
      }
    }
  }
  func testCustomTailscaleModelCannotOverrideDeclaredTextOnlyCapability() async throws {
    let connection = InferenceConnection(name: "Server", provider: "local-server-openai", route: .direct, baseURL: "https://models.example.ts.net", modelID: "fixture-model")
    let transport = FixtureTransport([]), service = CompanionInferenceService(connection: connection, credentials: TestCredentials(), transport: transport, model: model)
    let input: InferenceObject = ["model": ["id": connection.modelID, "provider": connection.provider, "input": ["text", "image"]], "context": ["messages": imageToolTranscript()]]
    do {
      try await service.stream(requestJSON: inferenceJSONString(input), emit: { _ in })
      XCTFail("Request metadata overrode native model capabilities")
    } catch { XCTAssertEqual(error as? InferenceError, .unsupportedImageInput) }
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testAdapterRequiresTerminalEventEvenWhenTransportEndsNormally() async throws {
    let connection = InferenceConnection(id: "adapter", name: "Host", provider: "openai-codex", accountID: "account-b", route: .adapter, baseURL: "https://host.example.ts.net", modelID: "m")
    let transport = FixtureTransport([.response(200), .line("{\"type\":\"start\",\"partial\":{\"content\":[]}}")])
    let service = CompanionInferenceService(connection: connection, credentials: TestCredentials(), transport: transport, model: model)
    let capture = CapturedEvents()
    do {
      try await service.stream(requestJSON: "{\"model\":{\"id\":\"m\",\"provider\":\"openai-codex\"},\"context\":{\"messages\":[]}}", emit: capture.append)
      XCTFail("A truncated host response became successful")
    } catch { XCTAssertEqual(error as? InferenceError, .interrupted) }
    XCTAssertFalse(capture.events.contains { $0["type"] as? String == "done" })
  }
  func testAdapterPreservesExactAccountScopeAndDoesNotForwardProviderKeys() async throws {
    let connection = InferenceConnection(id: "adapter", name: "Host", provider: "openai-codex", accountID: "account-b", route: .adapter, baseURL: "https://host.example.ts.net", modelID: "m", hostScope: .init(libraryID: "library", workspaceID: "workspace", deviceID: "phone", protocolVersion: 3))
    let transport = FixtureTransport([.response(200), .line("{\"type\":\"done\",\"reason\":\"stop\",\"message\":{\"content\":[]}}")])
    let service = CompanionInferenceService(connection: connection, credentials: TestCredentials(), transport: transport, model: model)
    try await service.stream(requestJSON: "{\"model\":{\"id\":\"m\",\"provider\":\"openai-codex\"},\"context\":{\"messages\":[]},\"scope\":{\"conversationID\":\"c\",\"requestID\":\"c:task\"}}", emit: { _ in })
    let requests = await transport.requests, request = try XCTUnwrap(requests.first)
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? InferenceObject)
    XCTAssertEqual(body["accountID"] as? String, "account-b")
    XCTAssertEqual(inferenceObject(body["scope"])["requestID"] as? String, "c:task")
    XCTAssertEqual(request.url?.path, "/v1/inference/stream")
    XCTAssertNil(body["apiKey"])
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Woven-Device"), "phone")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Woven-Library"), "library")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Woven-Protocol"), "3")
  }
}

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
  func testBundledCatalogIncludesAllExistingProvidersWithoutCredentials() throws {
    for provider in InferenceCatalog.providers where !provider.id.hasPrefix("local-server-") {
      let models = try InferenceCatalog.models(provider: provider.id)
      XCTAssertFalse(models.isEmpty, provider.id)
      XCTAssertTrue(models.allSatisfy { $0.provider == provider.id && $0.contextWindow > 0 })
    }
    let encoded = try JSONEncoder().encode(connection)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
  }
  func testAnthropicFamilyUsesVersionedMessagesAPIAndOpenCodeSessionHeader() throws {
    for provider in ["anthropic", "openrouter", "opencode-go"] {
      let model = try XCTUnwrap(InferenceCatalog.models(provider: provider).first { $0.api == "anthropic-messages" })
      let connection = InferenceConnection(name: provider, provider: provider, route: .direct, modelID: model.id)
      let request = try InferenceRequestBuilder(connection: connection, model: model).request(["context": ["messages": [["role": "user", "content": "hello"]]], "scope": ["conversationID": "session"]], secret: "fixture")
      XCTAssertEqual(request.url?.absoluteString, model.baseUrl + "/v1/messages")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      if provider == "opencode-go" { XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), "session") }
    }
  }
  func testSDKMetadataAndTieredCostsSurviveRoundTrip() throws {
    let model = try XCTUnwrap(InferenceCatalog.models(provider: "openai").first { $0.metadata["cost"]?.value is [String: Any] && inferenceObject($0.metadata["cost"]?.value)["tiers"] != nil })
    let descriptor = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(model.descriptorJSON().utf8)) as? InferenceObject)
    XCTAssertNotNil(inferenceObject(descriptor["cost"])["tiers"])
    XCTAssertEqual(inferenceObject(descriptor["compat"])["supportsStrictMode"] as? Bool, inferenceObject(model.metadata["compat"]?.value)["supportsStrictMode"] as? Bool)
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
  func testCustomServerDefaultsToResponsesVersionPathAndPreservesExplicitPrefix() throws {
    for (endpoint, path) in [("https://models.example.ts.net", "/v1/responses"), ("https://models.example.ts.net/custom/v1", "/custom/v1/responses")] {
      let connection = InferenceConnection(name: "Server", provider: "local-server-openai", route: .direct, baseURL: endpoint, modelID: "model")
      let model = InferenceModel(id: "model", name: "Model", provider: connection.provider, api: "openai-responses", baseUrl: endpoint)
      let request = try InferenceRequestBuilder(connection: connection, model: model).request(["context": ["messages": [["role": "user", "content": "hello"]]]], secret: "fixture")
      XCTAssertEqual(request.url?.path, path)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
    }
  }
  func testResponsesPreservesToolExchangeAndAppliesTranscriptToolChanges() throws {
    let transcript: [InferenceObject] = [
      ["role": "system", "content": "base", "toolsAdded": [["name": "old", "parameters": [:]]]],
      ["role": "system", "content": "extra", "toolsRemoved": [["name": "old"]], "toolsAdded": [["name": "read", "description": "Read", "parameters": ["type": "object"]]]],
      ["role": "user", "content": "read"],
      ["role": "assistant", "content": [["type": "toolCall", "id": "call_1|native", "name": "read", "arguments": ["path": "note.md"]]]],
      ["role": "toolResult", "toolCallId": "call_1|native", "content": [["type": "text", "text": "saved"]]],
    ]
    let request = try InferenceRequestBuilder(connection: connection, model: model).request(["context": ["messages": transcript]], secret: "fixture")
    let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? InferenceObject)
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
    XCTAssertEqual(body["instructions"] as? String, "base\n\nextra")
    XCTAssertEqual(inferenceObjects(body["tools"]).map { $0["name"] as? String }, ["read"])
    XCTAssertEqual(inferenceObjects(body["input"]).last?["call_id"] as? String, "call_1")
    XCTAssertEqual(body["store"] as? Bool, false)
  }
  func testResponsesEmitsCompleteToolCallAndUsageWithoutExecutingTool() throws {
    let capture = CapturedEvents(), decoder = InferenceStreamDecoder(model: model, connectionID: connection.id, emit: capture.append)
    try decoder.consume(try inferenceJSONString(["type": "response.output_item.added", "output_index": 0, "item": ["type": "function_call", "call_id": "call_1", "name": "write"]]))
    try decoder.consume(try inferenceJSONString(["type": "response.function_call_arguments.delta", "output_index": 0, "delta": "{\"path\":\"file\"}"]))
    try decoder.consume(try inferenceJSONString(["type": "response.completed", "response": ["status": "completed", "id": "response_1", "output": [["type": "function_call", "call_id": "call_1", "name": "write", "arguments": "{\"path\":\"file\"}"]], "usage": ["input_tokens": 12, "output_tokens": 4, "input_tokens_details": ["cached_tokens": 2]]]]))
    let result = inferenceObject(try XCTUnwrap(capture.events.last)["message"])
    XCTAssertEqual(result["stopReason"] as? String, "toolUse")
    XCTAssertEqual(inferenceObject(result["usage"])["input"] as? Int, 10)
    XCTAssertEqual(inferenceObject(result["usage"])["cacheRead"] as? Int, 2)
    XCTAssertEqual(inferenceObject(inferenceObjects(result["content"]).first?["arguments"])["path"] as? String, "file")
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
  func testServiceUsesSelectedConnectionAndRejectsProviderMismatchBeforeSending() async throws {
    let transport = FixtureTransport([.response(200), .line("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{}}}"), .line("")])
    let service = CompanionInferenceService(connection: connection, credentials: TestCredentials(), transport: transport)
    let capture = CapturedEvents()
    try await service.stream(requestJSON: "{\"model\":{\"id\":\"gpt-4\",\"provider\":\"openai\"},\"context\":{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}}", emit: capture.append)
    XCTAssertEqual(capture.events.last?["type"] as? String, "done")
    do { try await service.stream(requestJSON: "{\"model\":{\"id\":\"gpt-4\",\"provider\":\"anthropic\"}}", emit: capture.append); XCTFail("wrong provider accepted") }
    catch { XCTAssertEqual(error as? InferenceError, .modelUnavailable) }
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 1)
  }
  func testAdapterRequiresTerminalEventEvenWhenTransportEndsNormally() async throws {
    let connection = InferenceConnection(id: "adapter", name: "Host", provider: "openai-codex", accountID: "account-b", route: .adapter, baseURL: "https://host.example.ts.net", modelID: "m")
    let transport = FixtureTransport([.response(200), .line("{\"type\":\"start\",\"partial\":{\"content\":[]}}")])
    let service = CompanionInferenceService(connection: connection, credentials: TestCredentials(), transport: transport)
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
    let service = CompanionInferenceService(connection: connection, credentials: TestCredentials(), transport: transport)
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

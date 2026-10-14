import XCTest
import CryptoKit
@testable import CompanionInference

private func oauthResponse(_ status: Int, _ object: [String: Any]) throws -> InferenceOAuthHTTPResponse {
  .init(status: status, data: try JSONSerialization.data(withJSONObject: object))
}
private func oauthResponse(_ object: [String: Any]) throws -> InferenceOAuthHTTPResponse { try oauthResponse(200, object) }
private func fixtureJWT(account: String = "fixture-account", subject: String = "fixture-user") throws -> String {
  let data = try JSONSerialization.data(withJSONObject: ["sub": subject, "https://api.openai.com/auth": ["chatgpt_account_id": account]])
  return "fixture." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
}
private final class OAuthClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1000)
  private var intervals: [Double] = []
  func now() -> Date { lock.withLock { value } }
  func advance(_ seconds: Double) { lock.withLock { value += seconds } }
  func sleep(_ seconds: Double) { lock.withLock { intervals.append(seconds); value += seconds } }
  var sleeps: [Double] { lock.withLock { intervals } }
}
private actor OAuthFixture: InferenceOAuthHTTPTransport {
  var requests: [URLRequest] = []
  var responses: [InferenceOAuthHTTPResponse]
  let gated: Bool
  private var gate: CheckedContinuation<Void, Never>?
  init(_ responses: [InferenceOAuthHTTPResponse], gated: Bool = false) { self.responses = responses; self.gated = gated }
  func send(_ request: URLRequest) async throws -> InferenceOAuthHTTPResponse {
    requests.append(request)
    if gated { await withCheckedContinuation { gate = $0 } }
    guard !responses.isEmpty else { throw InferenceOAuthError.connectionFailed }
    return responses.removeFirst()
  }
  func release() { gate?.resume(); gate = nil }
  func waitUntilRequested() async throws {
    for _ in 0..<1000 {
      if !requests.isEmpty { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    throw InferenceOAuthError.connectionFailed
  }
}
private actor OAuthMemoryStore: InferenceCredentialUpdating {
  nonisolated let credentialStoreID = UUID().uuidString
  var values: [String: String]
  var replacements = 0
  var reads = 0
  init(_ values: [String: String] = [:]) { self.values = values }
  func read(connectionID: String) async throws -> String? { reads += 1; return values[connectionID] }
  func save(_ secret: String, connectionID: String) async throws { values[connectionID] = secret }
  func remove(connectionID: String) async throws { values.removeValue(forKey: connectionID) }
  func compareAndSwap(connectionID: String, expected: String, replacement: String) async throws -> Bool {
    guard values[connectionID] == expected else { return false }
    replacements += 1; values[connectionID] = replacement; return true
  }
}
private actor OAuthModelTransport: InferenceHTTPTransport {
  var requests: [URLRequest] = []
  let lines: [String]
  init(_ lines: [String]) { self.lines = lines }
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    requests.append(request)
    return AsyncThrowingStream { continuation in
      continuation.yield(.response(200))
      for line in lines { continuation.yield(.line("data: " + line)); continuation.yield(.line("")) }
      continuation.finish()
    }
  }
}
private final class OAuthEventCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func append(_ value: String) { lock.withLock { values.append(value) } }
  var events: [String] { lock.withLock { values } }
}
private actor OAuthCatalogFixture: CatalogHTTPTransport {
  var requests: [URLRequest] = []
  let data: Data
  init(_ model: InferenceModel) throws { data = try JSONEncoder().encode([model]) }
  func fetch(_ request: URLRequest) async throws -> CatalogHTTPResponse { requests.append(request); return .init(status: 200, data: data) }
}

@MainActor
final class InferenceOAuthTests: XCTestCase {
  private func session(_ transport: OAuthFixture, _ clock: OAuthClock) -> InferenceOAuthSession {
    .init(transport: transport, now: { clock.now() }, sleep: { clock.sleep($0) })
  }
  private func json(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
  }
  private func form(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map {
      let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      return (String(pair[0]).removingPercentEncoding!, String(pair[1]).removingPercentEncoding!)
    })
  }
  private func codeResponse(interval: Any = "2") throws -> InferenceOAuthHTTPResponse {
    try oauthResponse(["device_auth_id": "fixture-device-secret", "user_code": "TEST-CODE", "interval": interval])
  }
  private func grokCode(url: String = "https://accounts.x.ai/activate", lifetime: Int = 60) throws -> InferenceOAuthHTTPResponse {
    try oauthResponse(["device_code": "fixture-grok-device-secret", "user_code": "GROK-CODE", "interval": 2, "expires_in": lifetime, "verification_uri": url])
  }
  private func credential(_ provider: String = "openai-codex", expires: Double = 9_000_000) throws -> InferenceOAuthCredential {
    try .init(provider: provider, access: provider == "openai-codex" ? fixtureJWT() : "fixture-access", refresh: "fixture-refresh", expires: expires, accountID: "fixture-account", bindingID: "fixture-binding")
  }
  private func connection(_ provider: String = "openai-codex") -> InferenceConnection {
    .init(id: "fixture-key", name: "On this phone", provider: provider, accountID: "fixture-account", route: .direct, modelID: "fixture-model")
  }
  private func model(_ provider: String) -> InferenceModel {
    let api = provider == "openai-codex" ? "openai-codex-responses" : provider == "claude-subscription" ? "anthropic-messages" : "openai-responses"
    let base = provider == "openai-codex" ? "https://chatgpt.com/backend-api" : provider == "claude-subscription" ? "https://api.anthropic.com" : "https://api.x.ai/v1"
    return .init(id: "fixture-model", name: "Fixture", provider: provider, api: api, baseUrl: base)
  }
  private func expectError(_ expected: InferenceOAuthError, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? InferenceOAuthError, expected, file: file, line: line) }
  }

  func testOpenAIDeviceCodePendingSlowdownAndExactTokenExchange() async throws {
    let clock = OAuthClock(), token = try fixtureJWT()
    let transport = OAuthFixture([
      try codeResponse(), try oauthResponse(403, ["error": "provider_specific_pending"]),
      try oauthResponse(404, ["error": ["code": "still_pending"]]), try oauthResponse(400, ["error": "slow_down"]),
      try oauthResponse(["authorization_code": "fixture-code", "code_verifier": "fixture-verifier"]),
      try oauthResponse(["access_token": token, "refresh_token": "fixture-refresh", "expires_in": 3600])
    ])
    let auth = session(transport, clock), challenge = try await auth.start(provider: "openai-codex")
    XCTAssertEqual(challenge.kind, .deviceCode); XCTAssertEqual(challenge.userCode, "TEST-CODE")
    XCTAssertEqual(challenge.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
    XCTAssertFalse(String(describing: challenge).contains("fixture-device-secret"))
    let result = try await auth.poll()
    XCTAssertEqual(result.accountID, "fixture-account"); XCTAssertEqual(result.provider, "openai-codex")
    XCTAssertEqual(result.access, token); XCTAssertEqual(clock.sleeps, [2, 2, 7])
    XCTAssertEqual(result.expires, clock.now().timeIntervalSince1970 * 1000 + 3_540_000)
    XCTAssertFalse(String(describing: result).contains("fixture-refresh"))
    XCTAssertEqual(try result.serialized(), try result.serialized())
    XCTAssertEqual(try InferenceOAuthCredential.decode(result.serialized()), result)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 6)
    XCTAssertEqual(try json(requests[0])["client_id"] as? String, InferenceOAuthClient.openAIClient)
    XCTAssertEqual(try json(requests[1])["device_auth_id"] as? String, "fixture-device-secret")
    XCTAssertEqual(requests.last?.url?.absoluteString, "https://auth.openai.com/oauth/token")
    XCTAssertEqual(form(requests[5]), ["grant_type": "authorization_code", "client_id": InferenceOAuthClient.openAIClient, "code": "fixture-code", "code_verifier": "fixture-verifier", "redirect_uri": "https://auth.openai.com/deviceauth/callback"])
    await expectError(.sessionUnavailable) { _ = try await auth.poll() }
  }

  func testGrokPollingUsesProviderIntervalAndRejectsUntrustedVerificationURLs() async throws {
    let clock = OAuthClock(), transport = OAuthFixture([try grokCode(), try oauthResponse(400, ["error": "slow_down", "interval": 9]), try oauthResponse(["access_token": "fixture-grok-access", "refresh_token": "fixture-grok-refresh", "expires_in": 3600])])
    let auth = session(transport, clock), challenge = try await auth.start(provider: "xai")
    XCTAssertEqual(challenge.userCode, "GROK-CODE")
    let result = try await auth.poll(); XCTAssertEqual(clock.sleeps, [2, 9]); XCTAssertTrue(result.accountID.hasPrefix("xai-"))
    let requests = await transport.requests
    XCTAssertEqual(form(requests[0])["referrer"], "wovenmatter")
    XCTAssertEqual(form(requests[1])["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
    XCTAssertEqual(requests[1].url?.absoluteString, "https://auth.x.ai/oauth2/token")
    for url in ["https://x.ai.evil.invalid/activate", "http://x.ai/activate", "https://name:secret@x.ai/activate", "https://x.ai:444/activate"] {
      let invalid = session(OAuthFixture([try grokCode(url: url)]), clock)
      await expectError(.invalidResponse) { _ = try await invalid.start(provider: "xai") }
    }
  }

  func testDenialExpiryAndProviderErrorsStaySafe() async throws {
    let unavailable = session(OAuthFixture([try oauthResponse(404, [:])]), OAuthClock())
    await expectError(.deviceCodeUnavailable) { _ = try await unavailable.start(provider: "openai-codex") }
    let clock = OAuthClock(), deniedTransport = OAuthFixture([try codeResponse(), try oauthResponse(403, ["error": "access_denied", "description": "fixture-private-body"])]), denied = session(deniedTransport, clock)
    _ = try await denied.start(provider: "openai-codex")
    await expectError(.authorizationDenied) { _ = try await denied.poll() }
    XCTAssertFalse(InferenceOAuthError.authorizationDenied.localizedDescription.contains("fixture-private-body"))
    let expiredTransport = OAuthFixture([try grokCode(lifetime: 1)]), expired = session(expiredTransport, clock)
    _ = try await expired.start(provider: "xai")
    await expectError(.expired) { _ = try await expired.poll() }
    let requests = await expiredTransport.requests; XCTAssertEqual(requests.count, 1)
  }

  func testClaudePKCEStateExactCallbackAndSingleUse() async throws {
    for useURL in [false, true] {
      let clock = OAuthClock(), transport = OAuthFixture([try oauthResponse(["access_token": "fixture-claude-access", "refresh_token": "fixture-claude-refresh", "expires_in": 3600, "account": ["uuid": "fixture-claude-account"]])])
      let auth = session(transport, clock), challenge = try await auth.start(provider: "claude-subscription")
      XCTAssertEqual(challenge.kind, .authorizationCode); XCTAssertNil(challenge.userCode)
      let query = try XCTUnwrap(URLComponents(url: challenge.verificationURL, resolvingAgainstBaseURL: false)?.queryItems)
      let state = try XCTUnwrap(query.first { $0.name == "state" }?.value)
      let proof = try XCTUnwrap(query.first { $0.name == "code_challenge" }?.value)
      XCTAssertEqual(challenge.verificationURL.host, "claude.ai")
      XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
      let before = await transport.requests; XCTAssertTrue(before.isEmpty)
      let input = useURL ? "https://platform.claude.com/oauth/code/callback?code=fixture-code&state=\(state)" : "fixture-code#\(state)"
      let result = try await auth.complete(code: input)
      XCTAssertEqual(result.accountID, "fixture-claude-account"); XCTAssertEqual(result.provider, "claude-subscription")
      let requests = await transport.requests, request = try XCTUnwrap(requests.first), body = try json(request)
      XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
      XCTAssertEqual(body["redirect_uri"] as? String, InferenceOAuthClient.claudeCallback)
      XCTAssertEqual(body["state"] as? String, state); XCTAssertEqual(body["code"] as? String, "fixture-code")
      let verifier = try XCTUnwrap(body["code_verifier"] as? String)
      let hash = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
      XCTAssertEqual(hash, proof); XCTAssertNotEqual(verifier, state)
      await expectError(.sessionUnavailable) { _ = try await auth.complete(code: input) }
    }
  }

  func testClaudeRejectsStateCallbackAmbiguityExpiryAndCancellationBeforeExchange() async throws {
    let clock = OAuthClock(), transport = OAuthFixture([]), auth = session(transport, clock)
    for kind in ["bare", "state", "host", "duplicate", "fragment", "expired", "cancelled"] {
      let challenge = try await auth.start(provider: "claude-subscription")
      let state = try XCTUnwrap(URLComponents(url: challenge.verificationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
      var input = "fixture-code#\(state)", error = InferenceOAuthError.stateMismatch
      switch kind {
      case "bare": input = "fixture-code"
      case "state": input = "fixture-code#wrong-state"
      case "host": input = "https://foreign.invalid/oauth/code/callback?code=fixture&state=\(state)"
      case "duplicate": input = "https://platform.claude.com/oauth/code/callback?code=fixture&state=\(state)&state=\(state)"
      case "fragment": input = "https://platform.claude.com/oauth/code/callback?code=fixture&state=\(state)#fragment"
      case "expired": clock.advance(901); error = .expired
      default: await auth.cancel(); error = .sessionUnavailable
      }
      await expectError(error) { _ = try await auth.complete(code: input) }
    }
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
  }

  func testCancelledStartAndClaudeExchangeCannotReturnLateCredentials() async throws {
    let clock = OAuthClock(), transport = OAuthFixture([try codeResponse()], gated: true), auth = session(transport, clock)
    let start = Task { try await auth.start(provider: "openai-codex") }
    try await transport.waitUntilRequested(); await auth.cancel(); await transport.release()
    do { _ = try await start.value; XCTFail("Cancelled start completed") } catch { XCTAssertTrue(error is CancellationError) }
    await expectError(.sessionUnavailable) { _ = try await auth.poll() }
    let claudeTransport = OAuthFixture([try oauthResponse(["access_token": "fixture-access", "refresh_token": "fixture-refresh", "expires_in": 3600])], gated: true)
    let claude = session(claudeTransport, clock), challenge = try await claude.start(provider: "claude-subscription")
    let state = try XCTUnwrap(URLComponents(url: challenge.verificationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
    let exchange = Task { try await claude.complete(code: "fixture-code#\(state)") }
    try await claudeTransport.waitUntilRequested(); await claude.cancel(); await claudeTransport.release()
    do { _ = try await exchange.value; XCTFail("Cancelled exchange completed") } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testConcurrentRefreshIsSingleFlightAndCancellationDoesNotLoseRotatedToken() async throws {
    let old = try credential(expires: 999_000), raw = try old.serialized(), clock = OAuthClock()
    let store = OAuthMemoryStore(["fixture-key": raw]), transport = OAuthFixture([try oauthResponse(["access_token": fixtureJWT(), "refresh_token": "fixture-rotated-refresh", "expires_in": 3600])], gated: true)
    let resolver = InferenceOAuthCredentialResolver(transport: transport, now: { clock.now() }), connection = connection()
    let first = Task { try await resolver.resolve(connection: connection, credentials: store) }
    try await transport.waitUntilRequested()
    let other = Task { try await resolver.resolve(connection: connection, credentials: store) }
    first.cancel(); await transport.release()
    do { _ = try await first.value; XCTFail("Cancelled caller returned credential") } catch { XCTAssertTrue(error is CancellationError) }
    let refreshed = try await other.value
    XCTAssertEqual(refreshed.refresh, "fixture-rotated-refresh"); XCTAssertEqual(refreshed.bindingID, old.bindingID)
    XCTAssertEqual(refreshed.accountID, old.accountID)
    let requests = await transport.requests, replacements = await store.replacements, stored = try await store.read(connectionID: connection.id)
    XCTAssertEqual(requests.count, 1); XCTAssertEqual(replacements, 1); XCTAssertEqual(stored, try refreshed.serialized())
    XCTAssertEqual(form(requests[0])["refresh_token"], old.refresh)
    let again = try await resolver.resolve(connection: connection, credentials: store); XCTAssertEqual(again, refreshed)
  }

  func testRefreshCannotOverwriteReplacedOrRemovedCredential() async throws {
    for remove in [false, true] {
      let old = try credential(expires: 999_000), raw = try old.serialized(), clock = OAuthClock()
      let store = OAuthMemoryStore(["fixture-key": raw]), transport = OAuthFixture([try oauthResponse(["access_token": fixtureJWT(), "refresh_token": "fixture-rotated", "expires_in": 3600])], gated: true)
      let resolver = InferenceOAuthCredentialResolver(transport: transport, now: { clock.now() }), connection = connection()
      let task = Task { try await resolver.resolve(connection: connection, credentials: store) }
      try await transport.waitUntilRequested()
      if remove { try await store.remove(connectionID: connection.id) } else { try await store.save("new-explicit-connection", connectionID: connection.id) }
      await transport.release()
      await expectError(.credentialChanged) { _ = try await task.value }
      let stored = try await store.read(connectionID: connection.id), replacements = await store.replacements
      XCTAssertEqual(stored, remove ? nil : "new-explicit-connection"); XCTAssertEqual(replacements, 0)
    }
  }

  func testRefreshRejectsAccountChangeAndPreservesCredentialOnFailure() async throws {
    for response in [try oauthResponse(["access_token": fixtureJWT(account: "different-account"), "refresh_token": "fixture-rotated", "expires_in": 3600]), try oauthResponse(400, ["error": "invalid_grant", "detail": "fixture-sensitive-error"])] {
      let old = try credential(expires: 999_000), raw = try old.serialized(), clock = OAuthClock()
      let store = OAuthMemoryStore(["fixture-key": raw]), transport = OAuthFixture([response]), resolver = InferenceOAuthCredentialResolver(transport: transport, now: { clock.now() })
      await expectError(response.status == 200 ? .accountChanged : .signInRequired) { _ = try await resolver.resolve(connection: connection(), credentials: store) }
      let stored = try await store.read(connectionID: "fixture-key"); XCTAssertEqual(stored, raw)
    }
  }

  func testClaudeAndGrokRefreshPreserveUnrotatedRefreshAndAccountBinding() async throws {
    for provider in ["claude-subscription", "xai"] {
      let old = try credential(provider, expires: 999_000), clock = OAuthClock(), transport = OAuthFixture([try oauthResponse(["access_token": "fixture-updated-access", "expires_in": 3600])])
      let client = InferenceOAuthClient(transport: transport, now: { clock.now() }, sleep: { _ in })
      let new = try await client.refresh(old)
      XCTAssertEqual(new.refresh, old.refresh); XCTAssertEqual(new.accountID, old.accountID); XCTAssertEqual(new.bindingID, old.bindingID)
      let captured = await transport.requests
      let request = try XCTUnwrap(captured.first)
      let body = provider == "claude-subscription" ? try json(request) : form(request)
      XCTAssertEqual(body["refresh_token"] as? String, old.refresh)
      XCTAssertEqual(request.url?.absoluteString, provider == "claude-subscription" ? "https://platform.claude.com/v1/oauth/token" : "https://auth.x.ai/oauth2/token")
    }
  }

  func testDirectSubscriptionsUsePhoneCredentialsExactEndpointsAndTruthfulIdentity() async throws {
    for provider in ["openai-codex", "claude-subscription", "xai"] {
      let saved = try credential(provider), store = OAuthMemoryStore(["fixture-key": try saved.serialized()]), clock = OAuthClock()
      let auth = OAuthFixture([]), resolver = InferenceOAuthCredentialResolver(transport: auth, now: { clock.now() })
      let lines = provider == "claude-subscription" ? ["{\"type\":\"message_start\",\"message\":{\"id\":\"fixture\",\"usage\":{}}}", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}", "{\"type\":\"message_stop\"}"] : ["{\"type\":\"\(provider == "openai-codex" ? "response.done" : "response.completed")\",\"response\":{\"status\":\"completed\",\"output\":[],\"usage\":{}}}"]
      let modelTransport = OAuthModelTransport(lines), service = CompanionInferenceService(connection: connection(provider), credentials: store, transport: modelTransport, model: model(provider), oauthResolver: resolver), capture = OAuthEventCapture()
      let input: InferenceObject = ["model": ["id": "fixture-model", "provider": provider], "options": ["temperature": 0.5, "sessionId": "private-conversation-id"], "context": ["systemPrompt": "Woven Matter native agent", "tools": [["name": "read_image", "parameters": ["type": "object"]]], "messages": [["role": "user", "content": "hello"]]]]
      try await service.stream(requestJSON: inferenceJSONString(input), emit: capture.append)
      let requests = await modelTransport.requests, authRequests = await auth.requests
      XCTAssertEqual(requests.count, 1); XCTAssertTrue(authRequests.isEmpty)
      let request = try XCTUnwrap(requests.first), body = try json(request)
      XCTAssertEqual(request.url?.absoluteString, provider == "openai-codex" ? "https://chatgpt.com/backend-api/codex/responses" : provider == "claude-subscription" ? "https://api.anthropic.com/v1/messages" : "https://api.x.ai/v1/responses")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + saved.access)
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "WovenMatter/1 iOS")
      XCTAssertNil(request.value(forHTTPHeaderField: "x-app")); XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
      let text = String(decoding: request.httpBody!, as: UTF8.self)
      XCTAssertFalse(text.contains(saved.refresh)); XCTAssertFalse(text.contains(saved.access)); XCTAssertFalse(text.contains("Claude Code"))
      if provider == "openai-codex" {
        XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), saved.accountID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "wovenmatter")
        XCTAssertEqual(body["instructions"] as? String, "Woven Matter native agent")
        XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, true)
        XCTAssertNil(body["max_output_tokens"]); XCTAssertNil(body["temperature"])
        XCTAssertNotEqual(body["prompt_cache_key"] as? String, "private-conversation-id")
        XCTAssertTrue(inferenceObjects(body["tools"]).first?["strict"] is NSNull)
      } else if provider == "claude-subscription" {
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(body["system"] as? String, "Woven Matter native agent")
        XCTAssertEqual(inferenceObjects(body["tools"]).first?["name"] as? String, "read_image")
      }
      XCTAssertTrue(try XCTUnwrap(capture.events.last).contains("\"type\":\"done\""))
    }
  }

  func testWrongCredentialsAndForeignCatalogNeverReachAProvider() async throws {
    let clock = OAuthClock(), auth = OAuthFixture([]), resolver = InferenceOAuthCredentialResolver(transport: auth, now: { clock.now() })
    for raw in ["plain-api-key", try credential("xai").serialized(), try credential().serialized()] {
      let store = OAuthMemoryStore(["fixture-key": raw]), transport = OAuthModelTransport([])
      var connection = connection(); if raw == (try credential().serialized()) { connection.accountID = "another-account" }
      let service = CompanionInferenceService(connection: connection, credentials: store, transport: transport, model: model("openai-codex"), oauthResolver: resolver)
      do { try await service.stream(requestJSON: "{\"model\":{\"id\":\"fixture-model\",\"provider\":\"openai-codex\"},\"context\":{\"messages\":[]}}", emit: { _ in }); XCTFail("Wrong credential accepted") } catch {}
      let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }
    var foreign = model("openai-codex"); foreign.baseUrl = "https://foreign.invalid"
    let store = OAuthMemoryStore(), transport = OAuthModelTransport([]), service = CompanionInferenceService(connection: connection(), credentials: store, transport: transport, model: foreign, oauthResolver: resolver)
    do { try await service.stream(requestJSON: "{\"model\":{\"id\":\"fixture-model\",\"provider\":\"openai-codex\"}}", emit: { _ in }); XCTFail("Foreign endpoint accepted") } catch {}
    let reads = await store.reads, requests = await auth.requests; XCTAssertEqual(reads, 0); XCTAssertTrue(requests.isEmpty)
  }

  func testCodexReplayKeepsCommentaryFinalPhasesAndFencesOtherAccounts() throws {
    let selected = model("openai-codex"), route = connection(), capture = OAuthEventCapture()
    let decoder = InferenceStreamDecoder(model: selected, connectionID: route.id, emit: capture.append)
    let output: [InferenceObject] = [
      ["type": "message", "id": "msg_commentary", "phase": "commentary", "content": [["type": "output_text", "text": "Checking"], ["type": "output_text", "text": " the file"]]],
      ["type": "function_call", "call_id": "call_read", "name": "read", "arguments": "{}"],
      ["type": "message", "id": "msg_final", "phase": "final_answer", "content": [["type": "output_text", "text": "Done"]]]
    ]
    try decoder.consume(inferenceJSONString(["type": "response.done", "response": ["status": "completed", "output": output]]))
    let event = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(capture.events.last).utf8)) as? InferenceObject)
    let assistant = inferenceObject(event["message"])
    let request = try InferenceRequestBuilder(connection: route, model: selected).request(["context": ["messages": [assistant]]], secret: "fixture", accountID: route.accountID)
    let replay = inferenceObjects(try json(request)["input"])
    XCTAssertEqual(replay.count, 3)
    XCTAssertEqual(replay[0]["id"] as? String, "msg_commentary"); XCTAssertEqual(replay[0]["phase"] as? String, "commentary")
    XCTAssertEqual(inferenceObjects(replay[0]["content"]).count, 2)
    XCTAssertEqual(replay[1]["type"] as? String, "function_call")
    XCTAssertEqual(replay[2]["id"] as? String, "msg_final"); XCTAssertEqual(replay[2]["phase"] as? String, "final_answer")
    var other = route; other.id = "another-account-binding"
    let crossAccount = try InferenceRequestBuilder(connection: other, model: selected).request(["context": ["messages": [assistant]]], secret: "fixture-other", accountID: "other")
    let stripped = inferenceObjects(try json(crossAccount)["input"])
    XCTAssertTrue(stripped.allSatisfy { $0["phase"] == nil && $0["id"] == nil })
    let incomplete = OAuthEventCapture(), incompleteDecoder = InferenceStreamDecoder(model: selected, connectionID: route.id, emit: incomplete.append)
    try incompleteDecoder.consume(inferenceJSONString(["type": "response.done", "response": ["status": "incomplete", "output": []]]))
    let truncated = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(incomplete.events.last).utf8)) as? InferenceObject)
    XCTAssertEqual(inferenceObject(truncated["message"])["stopReason"] as? String, "length")
  }

  func testCatalogMapsDirectSubscriptionsAndOpenCodeZenWithoutLosingDescriptors() async throws {
    for provider in ["openai-codex", "claude-subscription", "xai", "opencode"] {
      var descriptor = provider == "opencode" ? InferenceModel(id: "fixture-model", name: "Fixture", provider: "opencode", api: "openai-completions", baseUrl: "https://opencode.ai/zen/v1") : model(provider)
      if provider == "claude-subscription" { descriptor.provider = "anthropic" }
      let transport = try OAuthCatalogFixture(descriptor), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let loader = ProviderModelCatalog(directory: directory, transport: transport), loaded = try await loader.load(provider: provider)
      XCTAssertEqual(loaded.first?.provider, provider); XCTAssertEqual(loaded.first?.id, descriptor.id)
      XCTAssertEqual(loaded.first?.baseUrl, descriptor.baseUrl)
      let captured = await transport.requests
      let request = try XCTUnwrap(captured.first)
      XCTAssertEqual(request.url?.path, "/api/models/providers/\(provider == "claude-subscription" ? "anthropic" : provider)")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      if provider == "opencode" {
        let connection = InferenceConnection(name: "Zen", provider: provider, route: .direct, modelID: descriptor.id)
        let request = try InferenceRequestBuilder(connection: connection, model: loaded[0]).request(["scope": ["conversationID": "fixture-session"], "context": ["messages": []]], secret: "fixture-zen-key")
        XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-session"), "fixture-session")
      } else {
        XCTAssertEqual(InferenceCatalog.providers.first { $0.id == provider }?.defaultRoute, .direct)
        XCTAssertEqual(InferenceCatalog.providers.first { $0.id == provider }?.supportsOAuth, true)
      }
    }
  }
}

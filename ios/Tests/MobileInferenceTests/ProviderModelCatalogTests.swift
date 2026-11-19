import XCTest
@testable import MobileInference

private actor CatalogFixture: CatalogHTTPTransport {
  var requests: [URLRequest] = []
  var responses: [CatalogHTTPResponse]
  init(_ responses: [CatalogHTTPResponse]) { self.responses = responses }
  func fetch(_ request: URLRequest) async throws -> CatalogHTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw InferenceError.connectionFailed }
    return responses.removeFirst()
  }
}
private final class CatalogClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1000)
  func now() -> Date { lock.withLock { value } }
  func advance() { lock.withLock { value += ProviderModelCatalog.refreshInterval } }
}
private actor WaitingCatalog: CatalogHTTPTransport {
  var started = false
  let body: Data
  init(_ body: Data) { self.body = body }
  func fetch(_ request: URLRequest) async throws -> CatalogHTTPResponse {
    started = true
    try await Task.sleep(for: .seconds(30))
    return .init(status: 200, data: body)
  }
}
private actor NoCredentials: InferenceCredentialReading {
  var reads = 0
  func read(connectionID: String) async throws -> String? { reads += 1; return "private-fixture-secret" }
}
private actor NoInference: InferenceHTTPTransport {
  var requests = 0
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    requests += 1; throw InferenceError.connectionFailed
  }
}

@MainActor
final class ProviderModelCatalogTests: XCTestCase {
  private func root() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-test-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func model(_ provider: String = "openai") -> InferenceModel {
    var value = InferenceModel(id: "fixture-chat", name: "Fixture chat", provider: provider, api: "openai-responses",
      baseUrl: provider == "openai" ? "https://api.openai.com/v1" : "https://api.x.ai/v1", reasoning: true, input: ["text", "image"], thinkingLevelMap: ["off": nil, "high": "high"])
    value.metadata["compat"] = .object(["supportsStrictMode": .bool(true)])
    value.metadata["inputLimits"] = .object(["maxRequestBytes": .number(1024)])
    value.metadata["cost"] = .object(["input": .number(1), "output": .number(2), "tiers": .array([.object(["inputTokensAbove": .number(100), "input": .number(2)])])])
    return value
  }
  private func data(_ models: [InferenceModel]) throws -> Data { try JSONEncoder().encode(models) }

  func testOpenCodeIsReadAtItsCurrentEndpointsAndEarlierOnesStayTrusted() throws {
    func entry(_ provider: String, _ id: String, _ api: String, _ baseUrl: String) -> InferenceModel {
      var value = model(provider)
      value.id = id; value.api = api; value.baseUrl = baseUrl
      return value
    }
    // The catalogs as Pi's service publishes them today, with an API the app has no endpoint for.
    let go = try InferenceModelPolicy.parse(try data([
      entry("opencode-go", "chat", "openai-completions", "https://opencode.ai/inference/go/openai/v1"),
      entry("opencode-go", "responses", "openai-responses", "https://opencode.ai/inference/go/openai/v1"),
      entry("opencode-go", "claude", "anthropic-messages", "https://opencode.ai/inference/go/anthropic"),
      entry("opencode-go", "gemini", "google-generative-ai", "https://opencode.ai/inference/go/google/v1beta"),
    ]), provider: "opencode-go")
    XCTAssertEqual(go.map(\.id), ["chat", "responses", "claude"])
    let zen = try InferenceModelPolicy.parse(try data([
      entry("opencode", "chat", "openai-completions", "https://opencode.ai/inference/openai/v1"),
      entry("opencode", "claude", "anthropic-messages", "https://opencode.ai/inference/anthropic"),
    ]), provider: "opencode")
    XCTAssertEqual(zen.map(\.id), ["chat", "claude"])
    // Conversations pinned before either move still open.
    for (provider, api, baseUrl) in [
      ("opencode-go", "openai-completions", "https://opencode.ai/inference/go/v1"), ("opencode-go", "anthropic-messages", "https://opencode.ai/inference/go"),
      ("opencode-go", "openai-responses", "https://opencode.ai/zen/go/v1"), ("opencode-go", "anthropic-messages", "https://opencode.ai/zen/go"),
      ("opencode", "openai-completions", "https://opencode.ai/zen/v1"), ("opencode", "anthropic-messages", "https://opencode.ai/zen"),
    ] {
      XCTAssertNoThrow(try InferenceModelPolicy.validate(entry(provider, "pinned", api, baseUrl), provider: provider), "\(provider) \(baseUrl)")
    }
    // One provider's address is not the other's, and one API's is not another's.
    for (provider, api, baseUrl) in [
      ("opencode", "openai-completions", "https://opencode.ai/inference/go/openai/v1"), ("opencode-go", "openai-completions", "https://opencode.ai/inference/openai/v1"),
      ("opencode-go", "anthropic-messages", "https://opencode.ai/inference/go/openai/v1"), ("opencode", "openai-completions", "https://opencode.ai/zen"),
    ] {
      XCTAssertThrowsError(try InferenceModelPolicy.validate(entry(provider, "wrong", api, baseUrl), provider: provider), "\(provider) \(baseUrl)")
    }
  }

  func testCatalogRecoversInitialFailuresRevalidatesAndPreservesSavedModelsDuringOutage() async throws {
    let directory = root(), clock = CatalogClock(), body = try data([model()])
    let transport = CatalogFixture([.init(status: 304), .init(status: 503), .init(status: 200, data: body, etag: "\"fixture\"", lastModified: "Thu, 01 Oct 2026 12:00:00 GMT"), .init(status: 304)])
    let cache = ProviderModelCatalog(directory: directory, transport: transport, now: { clock.now() })
    let empty = await cache.cached(provider: "openai")
    XCTAssertTrue(empty.isEmpty)
    do { _ = try await cache.load(provider: "openai"); XCTFail("Unbacked 304 accepted") } catch {}
    do { _ = try await cache.load(provider: "openai"); XCTFail("HTTP failure accepted") } catch {}
    let stillEmpty = await cache.cached(provider: "openai"); XCTAssertTrue(stillEmpty.isEmpty)
    let cold = try await cache.load(provider: "openai", force: true)
    XCTAssertEqual(cold.count, 1)
    let warm = try await cache.load(provider: "openai")
    XCTAssertEqual(cold, warm)
    let restarted = ProviderModelCatalog(directory: directory, transport: transport, now: { clock.now() })
    let restored = try await restarted.load(provider: "openai")
    XCTAssertEqual(restored, cold)
    let beforeStale = await transport.requests
    XCTAssertEqual(beforeStale.count, 3)
    clock.advance()
    let cached = await restarted.cached(provider: "openai")
    XCTAssertEqual(cached, cold)
    let revalidated = try await restarted.load(provider: "openai")
    XCTAssertEqual(revalidated, cold)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 4)
    XCTAssertEqual(requests[3].value(forHTTPHeaderField: "If-None-Match"), "\"fixture\"")
    XCTAssertEqual(requests[3].value(forHTTPHeaderField: "If-Modified-Since"), "Thu, 01 Oct 2026 12:00:00 GMT")
    for request in requests {
      XCTAssertEqual(request.url?.absoluteString, "https://pi.dev/api/models/providers/openai?types=chat&pi-version=\(ProviderModelCatalog.piVersion)")
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "pi/\(ProviderModelCatalog.piVersion)")
      XCTAssertNil(request.httpBody)
      let allowed = Set(["accept", "user-agent", "if-none-match", "if-modified-since"])
      XCTAssertTrue(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }).isSubset(of: allowed))
    }
    let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cold[0])) as? NSDictionary
    XCTAssertEqual(roundTrip, try JSONSerialization.jsonObject(with: JSONEncoder().encode(model())) as? NSDictionary)
      clock.advance()
    do { _ = try await restarted.load(provider: "openai"); XCTFail("Offline load succeeded") } catch {}
    let retained = await restarted.cached(provider: "openai")
    XCTAssertEqual(retained, cold)
    let saved = InferenceConnection(name: "Saved", provider: "openai", route: .direct, modelID: cold[0].id, selectedModel: cold[0])
    let persisted = try JSONDecoder().decode(InferenceConnection.self, from: JSONEncoder().encode(saved))
    let emptyCatalog = ProviderModelCatalog(directory: root(), transport: CatalogFixture([]))
    let service = MobileInferenceService(connection: persisted, catalogLoader: emptyCatalog)
    let resolved = try await service.model()
    XCTAssertEqual(resolved, cold[0])
    var changed = model(); changed.name = "Changed"
    let replacement = ProviderModelCatalog(directory: directory, transport: CatalogFixture([.init(status: 200, data: try data([changed]))]))
    _ = try await replacement.load(provider: "openai", force: true)
    let pinned = try await service.model()
    XCTAssertEqual(pinned, cold[0])
  }

}

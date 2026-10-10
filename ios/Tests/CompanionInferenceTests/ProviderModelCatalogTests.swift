import XCTest
@testable import CompanionInference

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

  func testColdWarmRestartStale304AndPublicRequestPrivacy() async throws {
    let directory = root(), clock = CatalogClock(), body = try data([model()])
    let transport = CatalogFixture([.init(status: 200, data: body, etag: "\"fixture\"", lastModified: "Thu, 01 Oct 2026 12:00:00 GMT"), .init(status: 304)])
    let cache = ProviderModelCatalog(directory: directory, transport: transport, now: { clock.now() })
    let empty = await cache.cached(provider: "openai")
    XCTAssertTrue(empty.isEmpty)
    let cold = try await cache.load(provider: "openai")
    let warm = try await cache.load(provider: "openai")
    XCTAssertEqual(cold, warm)
    let restarted = ProviderModelCatalog(directory: directory, transport: transport, now: { clock.now() })
    let restored = try await restarted.load(provider: "openai")
    XCTAssertEqual(restored, cold)
    let beforeStale = await transport.requests
    XCTAssertEqual(beforeStale.count, 1)
    clock.advance()
    let cached = await restarted.cached(provider: "openai")
    XCTAssertEqual(cached, cold)
    let revalidated = try await restarted.load(provider: "openai")
    XCTAssertEqual(revalidated, cold)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"fixture\"")
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Modified-Since"), "Thu, 01 Oct 2026 12:00:00 GMT")
    for request in requests {
      XCTAssertEqual(request.url?.absoluteString, "https://pi.dev/api/models/providers/openai?types=chat")
      XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "pi/1.1.0")
      XCTAssertNil(request.httpBody)
      let allowed = Set(["accept", "user-agent", "if-none-match", "if-modified-since"])
      XCTAssertTrue(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }).isSubset(of: allowed))
    }
    let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cold[0])) as? NSDictionary
    XCTAssertEqual(roundTrip, try JSONSerialization.jsonObject(with: JSONEncoder().encode(model())) as? NSDictionary)
  }
  func testOutagePreservesSavedDescriptorsAndDoesNotChangeTheirFreshness() async throws {
    let directory = root(), clock = CatalogClock()
    let transport = CatalogFixture([.init(status: 200, data: try data([model()]))])
    let cache = ProviderModelCatalog(directory: directory, transport: transport, now: { clock.now() })
    let initial = try await cache.load(provider: "openai")
    clock.advance()
    do { _ = try await cache.load(provider: "openai"); XCTFail("Offline load succeeded") } catch {}
    let retained = await cache.cached(provider: "openai")
    XCTAssertEqual(retained, initial)
    let saved = InferenceConnection(name: "Saved", provider: "openai", route: .direct, modelID: initial[0].id, selectedModel: initial[0])
    let persisted = try JSONDecoder().decode(InferenceConnection.self, from: JSONEncoder().encode(saved))
    let empty = ProviderModelCatalog(directory: root(), transport: CatalogFixture([]))
    let service = CompanionInferenceService(connection: persisted, catalogLoader: empty)
    let resolved = try await service.model()
    XCTAssertEqual(resolved, initial[0])
    var changed = model(); changed.name = "Changed"
    let replacement = ProviderModelCatalog(directory: directory, transport: CatalogFixture([.init(status: 200, data: try data([changed]))]))
    _ = try await replacement.load(provider: "openai", force: true)
    let pinned = try await service.model()
    XCTAssertEqual(pinned, initial[0])
  }
  func testFirstLoadFailureCanRetryAndUnbacked304Fails() async throws {
    let transport = CatalogFixture([.init(status: 503), .init(status: 200, data: try data([model()]))])
    let cache = ProviderModelCatalog(directory: root(), transport: transport)
    do { _ = try await cache.load(provider: "openai"); XCTFail("HTTP failure accepted") } catch {}
    let empty = await cache.cached(provider: "openai"); XCTAssertTrue(empty.isEmpty)
    let loaded = try await cache.load(provider: "openai", force: true); XCTAssertEqual(loaded.count, 1)
    let invalid = ProviderModelCatalog(directory: root(), transport: CatalogFixture([.init(status: 304)]))
    do { _ = try await invalid.load(provider: "openai"); XCTFail("Unbacked 304 accepted") } catch {}
  }
  func testTypeAPIFilteringAndXAIConnectionIdentity() throws {
    var image = model(); image.metadata["type"] = .string("image"); image.api = "image-generation"
    var classifier = model(); classifier.metadata["type"] = .string("classifier")
    var unsupported = model(); unsupported.api = "future-api"
    let models = try InferenceModelPolicy.parse(data([model(), image, classifier, unsupported]), provider: "openai")
    XCTAssertEqual(models.count, 1)
    let xai = try InferenceModelPolicy.parse(data([model("xai")]), provider: "xai-api")
    XCTAssertEqual(xai.first?.provider, "xai-api")
    XCTAssertEqual(xai.first?.api, "openai-responses")
  }
  func testRejectsForeignDestinationsAndMalformedMetadataBeforeReadingCredentials() async throws {
    for endpoint in ["https://foreign.invalid", "https://api.openai.com:8443/v1", "https://api.openai.com/v1/other", "https://u:p@api.openai.com/v1", "https://api.openai.com/v1?token=secret"] {
      var bad = model(); bad.baseUrl = endpoint
      XCTAssertThrowsError(try InferenceModelPolicy.parse(data([bad]), provider: "openai"))
      let credentials = NoCredentials(), inference = NoInference()
      let connection = InferenceConnection(name: "Saved", provider: "openai", route: .direct, modelID: bad.id, selectedModel: bad)
      let service = CompanionInferenceService(connection: connection, credentials: credentials, transport: inference)
      do { try await service.stream(requestJSON: "{\"model\":{\"id\":\"fixture-chat\",\"provider\":\"openai\"},\"context\":{\"messages\":[]}}", emit: { _ in }); XCTFail("Foreign endpoint accepted") } catch {}
      let reads = await credentials.reads, requests = await inference.requests
      XCTAssertEqual(reads, 0); XCTAssertEqual(requests, 0)
    }
    var invalid = model(); invalid.maxTokens = 0
    XCTAssertThrowsError(try InferenceModelPolicy.parse(data([invalid]), provider: "openai"))
    invalid = model(); invalid.metadata["cost"] = .object(["input": .number(-1)])
    XCTAssertThrowsError(try InferenceModelPolicy.parse(data([invalid]), provider: "openai"))
    invalid = model(); invalid.provider = "anthropic"
    XCTAssertThrowsError(try InferenceModelPolicy.parse(data([invalid]), provider: "openai"))
    invalid = model(); invalid.metadata["headers"] = .object(["Authorization": .string("secret")])
    XCTAssertThrowsError(try InferenceModelPolicy.parse(data([invalid]), provider: "openai"))
    XCTAssertThrowsError(try InferenceModelPolicy.parse(Data(repeating: 32, count: ProviderModelCatalog.byteLimit + 1), provider: "openai"))
    XCTAssertThrowsError(try InferenceModelPolicy.parse(data([model(), model()]), provider: "openai"))
  }
  func testCancellationAndProviderSwitchLeaveOnlyTheRequestedValidCache() async throws {
    let directory = root(), transport = WaitingCatalog(try data([model()]))
    let cache = ProviderModelCatalog(directory: directory, transport: transport)
    let task = Task { try await cache.load(provider: "openai") }
    while !(await transport.started) { await Task.yield() }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled request published") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error") }
    let other = ProviderModelCatalog(directory: directory, transport: CatalogFixture([.init(status: 200, data: try data([model("xai")]))]))
    let xai = try await other.load(provider: "xai-api")
    XCTAssertEqual(xai[0].provider, "xai-api")
    let cancelled = await other.cached(provider: "openai"); XCTAssertTrue(cancelled.isEmpty)
  }
}

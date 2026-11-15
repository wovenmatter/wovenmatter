import XCTest
@testable import MobileInference

private struct SearchCredentials: InferenceCredentialReading {
  var keys: [QuickChatSearchProvider: String]
  init(_ keys: [QuickChatSearchProvider: String]) { self.keys = keys }
  func read(connectionID: String) async throws -> String? {
    keys.first { $0.key.credentialID == connectionID }?.value
  }
}
private actor SearchTransport: InferenceHTTPTransport {
  var requests: [URLRequest] = []
  let status: Int
  let body: String
  init(status: Int = 200, body: String = "{\"results\":[]}") { self.status = status; self.body = body }
  func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<InferenceHTTPEvent, Error> {
    requests.append(request)
    return AsyncThrowingStream { stream in stream.yield(.response(status)); stream.yield(.line(body)); stream.finish() }
  }
}
private func body(_ request: URLRequest?) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: Any])
}

final class QuickChatWebSearchTests: XCTestCase {
  func testExaSearchUsesOnlyDeviceKeyAndFixedEndpointAndBoundsResults() async throws {
    let transport = SearchTransport(body: "{\"results\":[{\"title\":\"Source\",\"url\":\"https://example.org/source\",\"text\":\"Useful text\"},{\"url\":\"file:///private/file\"}]}")
    let output = try await QuickChatWebSearch(provider: .exa, credentials: SearchCredentials([.exa: "private-key"]), transport: transport).search("question")
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: [[String: String]]])
    XCTAssertEqual(parsed["results"]?.first?["url"], "https://example.org/source"); XCTAssertFalse(output.contains("file:")); XCTAssertFalse(output.contains("private-key"))
    let requests = await transport.requests
    XCTAssertEqual(requests.first?.url?.absoluteString, "https://api.exa.ai/search")
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-api-key"), "private-key")
    XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
  }

  func testBraveAndFirecrawlMatchTheDesktopRequestShapes() async throws {
    let brave = SearchTransport(body: "{\"grounding\":{\"generic\":[{\"title\":\"B\",\"url\":\"https://brave.example/a\",\"snippets\":[\"one\",\"two\"]}]}}")
    let braveOutput = try await QuickChatWebSearch(provider: .brave, credentials: SearchCredentials([.brave: "brave-key"]), transport: brave).search("news", limit: 3)
    let braveRequest = await brave.requests.first
    XCTAssertEqual(braveRequest?.url?.absoluteString, "https://api.search.brave.com/res/v1/llm/context")
    XCTAssertEqual(braveRequest?.value(forHTTPHeaderField: "X-Subscription-Token"), "brave-key")
    XCTAssertEqual(try body(braveRequest)["q"] as? String, "news"); XCTAssertEqual(try body(braveRequest)["count"] as? Int, 3)
    let braveRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(braveOutput.utf8)) as? [String: [[String: String]]])
    XCTAssertEqual(braveRows["results"]?.first?["text"], "one\n\ntwo")

    let firecrawl = SearchTransport(body: "{\"success\":true,\"data\":{\"web\":[{\"title\":\"F\",\"url\":\"https://fire.example/b\",\"markdown\":\"# Page\"}]}}")
    let fireOutput = try await QuickChatWebSearch(provider: .firecrawl, credentials: SearchCredentials([.firecrawl: "fire-key"]), transport: firecrawl).search("docs")
    let fireRequest = await firecrawl.requests.first
    XCTAssertEqual(fireRequest?.url?.absoluteString, "https://api.firecrawl.dev/v2/search")
    XCTAssertEqual(fireRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer fire-key")
    XCTAssertEqual(try body(fireRequest)["query"] as? String, "docs")
    XCTAssertTrue(fireOutput.contains("https://fire.example/b"))

    let scrape = SearchTransport(body: "{\"success\":true,\"data\":{\"markdown\":\"Body\",\"metadata\":{\"title\":\"T\"}}}")
    let page = try await QuickChatWebSearch(provider: .firecrawl, credentials: SearchCredentials([.firecrawl: "fire-key"]), transport: scrape).read("https://example.org/page")
    let scrapeRequest = await scrape.requests.first
    XCTAssertEqual(scrapeRequest?.url?.absoluteString, "https://api.firecrawl.dev/v2/scrape")
    XCTAssertEqual(try body(scrapeRequest)["url"] as? String, "https://example.org/page")
    XCTAssertTrue(page.contains("Body"))
  }

  func testConnectedProviderSelectionPrefersTheUsersChoiceAndRoutesReadsAwayFromBrave() async throws {
    let none = SearchCredentials([:])
    do { _ = try await QuickChatWebSearch.service(reading: false, credentials: none); XCTFail("No connection") }
    catch QuickChatSearchError.unconfigured {}
    let braveOnly = SearchCredentials([.brave: "b"])
    let search = try await QuickChatWebSearch.service(reading: false, credentials: braveOnly)
    XCTAssertEqual(search.provider, .brave)
    do { _ = try await QuickChatWebSearch.service(reading: true, credentials: braveOnly); XCTFail("Brave cannot read") }
    catch QuickChatSearchError.readUnavailable {}
    let all = SearchCredentials([.exa: "e", .brave: "b", .firecrawl: "f"])
    let defaultSearch = try await QuickChatWebSearch.service(reading: false, credentials: all)
    XCTAssertEqual(defaultSearch.provider, .exa)
    let preferredSearch = try await QuickChatWebSearch.service(reading: false, credentials: all, preferred: "brave")
    XCTAssertEqual(preferredSearch.provider, .brave)
    let preferredRead = try await QuickChatWebSearch.service(reading: true, credentials: all, preferred: "brave")
    XCTAssertEqual(preferredRead.provider, .exa, "Reads use the next connected provider that can read")
  }

  func testWebReadingDoesNotSendPrivateTailnetURLsOrCallPhoneServices() async throws {
    let transport = SearchTransport()
    let service = QuickChatWebSearch(provider: .exa, credentials: SearchCredentials([.exa: "private-key"]), transport: transport)
    for url in ["https://host.tail.ts.net/private", "https://127.0.0.1/private", "https://localhost/private", "file:///private/file"] {
      do { _ = try await service.read(url); XCTFail("Private address accepted") }
      catch QuickChatSearchError.invalidURL {}
    }
    let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    _ = try await service.read("https://example.org/page")
    let publicRequests = await transport.requests
    XCTAssertEqual(publicRequests.first?.url?.absoluteString, "https://api.exa.ai/contents")
  }

  func testMissingKeyAndProviderFailureStayExplicitWithoutLeakingBodies() async throws {
    let transport = SearchTransport(status: 401, body: "private-key in upstream error")
    do { _ = try await QuickChatWebSearch(provider: .exa, credentials: SearchCredentials([:]), transport: transport).search("question"); XCTFail() }
    catch QuickChatSearchError.unconfigured {}
    let before = await transport.requests.count; XCTAssertEqual(before, 0)
    do { _ = try await QuickChatWebSearch(provider: .exa, credentials: SearchCredentials([.exa: "private-key"]), transport: transport).search("question"); XCTFail() }
    catch { XCTAssertFalse(error.localizedDescription.contains("private-key")) }
  }
}

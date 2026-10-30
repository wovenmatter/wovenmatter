import XCTest
@testable import CompanionInference

private struct SearchCredentials: InferenceCredentialReading {
  var key: String?
  func read(connectionID: String) async throws -> String? { connectionID == QuickChatWebSearch.credentialID ? key : nil }
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
final class QuickChatWebSearchTests: XCTestCase {
  func testSearchUsesOnlyDeviceKeyAndFixedEndpointAndBoundsResults() async throws {
    let transport = SearchTransport(body: "{\"results\":[{\"title\":\"Source\",\"url\":\"https://example.org/source\",\"text\":\"Useful text\"},{\"url\":\"file:///private/file\"}]}")
    let output = try await QuickChatWebSearch(credentials: SearchCredentials(key: "private-key"), transport: transport).search("question")
    let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: [[String: String]]])
    XCTAssertEqual(parsed["results"]?.first?["url"], "https://example.org/source"); XCTAssertFalse(output.contains("file:")); XCTAssertFalse(output.contains("private-key"))
    let requests = await transport.requests
    XCTAssertEqual(requests.first?.url?.absoluteString, "https://api.exa.ai/search")
    XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-api-key"), "private-key")
    XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
  }
  func testWebReadingDoesNotSendPrivateTailnetURLsOrCallPhoneServices() async throws {
    let transport = SearchTransport()
    let service = QuickChatWebSearch(credentials: SearchCredentials(key: "private-key"), transport: transport)
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
    do { _ = try await QuickChatWebSearch(credentials: SearchCredentials(key: nil), transport: transport).search("question"); XCTFail() }
    catch QuickChatSearchError.unconfigured {}
    let before = await transport.requests.count; XCTAssertEqual(before, 0)
    do { _ = try await QuickChatWebSearch(credentials: SearchCredentials(key: "private-key"), transport: transport).search("question"); XCTFail() }
    catch { XCTAssertFalse(error.localizedDescription.contains("private-key")) }
  }
}

import Foundation
import Testing
@testable import WovenMatterClient

struct RemoteBrowserClientTests {
    @Test func browserReadsStayAuthenticatedAndOnTheWorkspaceOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42007")!, token: "fixture", session: session)
        #expect(try await client.browserTabs().tabs.first?.id == "tab")
        #expect(try await client.browserFrame(tabID: "tab").tabID == "tab")
        let old = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42008")!, token: "fixture", session: session)
        await #expect(throws: RemoteWorkspaceClientError.invalidResponse("Update this workspace container in Settings to view its browser.")) {
            try await old.browserTabs()
        }
    }
}

private final class BrowserFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        #expect(request.url?.host == "127.0.0.1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.timeoutInterval == 10)
        let old = request.url?.port == 42008
        let frame = request.url?.path == "/v1/browser/frame"
        #expect(request.httpMethod == (frame ? "POST" : "GET"))
        #expect(frame || request.url?.path == "/v1/browser/tabs")
        #expect(request.url?.query == nil)
        let body = old ? #"{"error":"not_found"}"# : frame
            ? #"{"tabID":"tab","imageBase64":"anBlZw=="}"#
            : #"{"running":true,"tabs":[{"id":"tab","title":"Test","url":"http://localhost:3000"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: old ? 404 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "no-store"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

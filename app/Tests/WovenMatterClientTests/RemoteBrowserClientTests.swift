import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import WovenMatterClient

struct RemoteBrowserClientTests {
    @Test func browserMCPBindsCallerAndOperationAndPreservesInlineImages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserMCPFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42007")!, token: "private-fixture", session: session)
        let caller = "11111111-1111-4111-8111-111111111111", operation = "22222222-2222-4222-8222-222222222222"
        let response = try await client.browserMCP(callerID: caller,
            input: .object(["action": .string("screenshot"), "tabId": .string("tab")]), requestID: operation)
        #expect(response.requestID == operation)
        #expect(response.result?.objectValue?["content"]?.arrayValue?.first?.objectValue?["type"] == .string("image"))
        #expect(try await client.browserMCP(callerID: caller, input: .object(["id": .string(operation)]),
            requestID: operation, cancelling: true).success)
    }
}

private final class BrowserMCPFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer private-fixture")
        #expect(request.url?.host == "127.0.0.1" && request.httpMethod == "POST")
        let cancelling = request.url?.path == "/v1/browser/mcp/cancel"
        #expect(cancelling || request.url?.path == "/v1/browser/mcp")
        #expect(request.timeoutInterval == (cancelling ? 10 : 30))
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
        }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(body?["callerID"] as? String == "11111111-1111-4111-8111-111111111111")
        #expect((body?["input"] as? [String: Any])?["requestID"] as? String == "22222222-2222-4222-8222-222222222222")
        #expect(!String(decoding: data, as: UTF8.self).contains("private-fixture"))
        let response = #"{"success":true,"requestID":"22222222-2222-4222-8222-222222222222","result":{"content":[{"type":"image","mimeType":"image/jpeg","data":"anBlZw=="}]}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

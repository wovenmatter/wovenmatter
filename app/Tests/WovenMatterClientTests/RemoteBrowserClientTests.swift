import Foundation
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
    @Test func browserReadsStayAuthenticatedAndOnTheWorkspaceOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42007")!, token: "fixture", session: session)
        #expect(try await client.browserTabs().tabs.first?.id == "tab")
        #expect(try await client.browserFrame(tabID: "tab").tabID == "tab")
        let old = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42008")!, token: "fixture", session: session)
        await #expect(throws: RemoteWorkspaceClientError.invalidResponse("Update this workspace service in Settings to view its browser.")) {
            try await old.browserTabs()
        }
    }

    @Test func browserProfileStaysBoundToAuthenticatedRequestsAndRejectsTraversal() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserProfileFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42007")!, token: "fixture", session: session)
        let tabs = try await client.browserTabs(profile: "work")
        #expect(tabs.profiles == ["default", "work"] && tabs.profile == "work")
        #expect(try await client.browserFrame(tabID: "tab", profile: "work").tabID == "tab")
        for profile in ["../private", "Work", "", String(repeating: "a", count: 33)] {
            await #expect(throws: RemoteWorkspaceClientError.invalidResponse("The browser profile identifier is invalid.")) {
                try await client.browserTabs(profile: profile)
            }
        }
    }

    @Test func fragmentedStreamKeepsOnlyTheLatestImageAndRejectsOversizedFrames() async throws {
        let pair = AsyncThrowingStream<RemoteBrowserFrame, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let decoder = RemoteBrowserStreamDecoder(pair.continuation)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://127.0.0.1:1")!)
        let first = Data(#"{"tabID":"tab","frameID":"one","imageBase64":"anBlZw==","imageID":"image"}"#.utf8)
        decoder.urlSession(session, dataTask: task, didReceive: first.prefix(17))
        decoder.urlSession(session, dataTask: task, didReceive: first.dropFirst(17) + Data([10]))
        decoder.urlSession(session, dataTask: task, didReceive: Data(#"{"tabID":"tab","frameID":"two","imageBase64":"","imageID":"image"}"#.utf8) + Data([10]))
        var iterator = pair.stream.makeAsyncIterator()
        let latest = try #require(try await iterator.next())
        #expect(latest.frameID == "two" && latest.imageBase64 == "anBlZw==")
        decoder.urlSession(session, dataTask: task, didReceive: Data(repeating: 65, count: 3 * 1024 * 1024 + 1))
        await #expect(throws: BackendRPCError.self) { try await iterator.next() }
    }

}

private final class BrowserProfileFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        #expect(request.url?.host == "127.0.0.1")
        #expect(request.url?.query == "profile=work")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let body = request.url?.path == "/v1/browser/frame"
            ? #"{"tabID":"tab","imageBase64":"anBlZw=="}"#
            : #"{"running":true,"tabs":[],"profiles":["default","work"],"profile":"work"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
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

import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RemoteTaskGatewayClientTests {


    @Test func gatewayStatusAndDisableUseAuthenticatedWorkspaceOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskGatewayFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42001")!, token: "fixture", session: session)
        #expect(try await client.taskGatewayStatus().enabled)
        #expect(try await client.setTaskGatewayEnabled(false).enabled == false)
        #expect(try await client.taskGatewayResults(after: "23").cursor == "23")
    }
}

private final class TaskGatewayFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        #expect(request.url?.host == "127.0.0.1")
        let response: String
        if request.url?.path == "/v1/task-gateway/results" {
            #expect(request.url?.query == "after=23")
            response = #"{"entries":[],"cursor":"23"}"#
        } else {
            #expect(request.url?.path == "/v1/task-gateway")
            response = "{\"enabled\":\(request.httpMethod == "PATCH" ? "false" : "true"),\"epoch\":\"fixture\",\"activeRuns\":0,\"scheduleCount\":0}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

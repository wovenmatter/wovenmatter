import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import WovenMatterClient

struct RemoteExecutionEnrollmentTests {
    /// A Linux host serves execution only; this Mac never asks it for inference.
    @Test func enrollmentAsksALinuxHostForExecutionOnly() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EnrollmentFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42008")!, token: "private-fixture", session: session)
        let id = { UUID().uuidString.lowercased() }
        _ = try? await client.provisionExecutionDevice(libraryID: id(), workspaceID: id(), ownerDeviceID: id(), deviceID: id(),
            name: "Studio Mac", workspaceName: "Workstation", endpoint: URL(string: "https://workstation.fixture.ts.net/wovenmatter-execution/w")!)
        #expect(EnrollmentFixtureProtocol.scopes == ["execution"])
    }
}

private final class EnrollmentFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [String]?
    static var scopes: [String]? { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
        }
        if request.url?.path == "/execution/devices" {
            let scopes = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["scopes"] as? [String]
            Self.lock.withLock { Self.captured = scopes }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":"fixture"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

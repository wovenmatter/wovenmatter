import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RemoteDatabaseClientTests {
    @Test func keepsDatabaseIDsInBodiesAndRequestsOnTheirWorkspaceOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteDatabaseFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let first = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42001")!, token: "one", session: session)
        let second = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42002")!, token: "two", session: session)
        #expect(try await first.databases().first?.name == "Sales #1")
        #expect(try await second.databases().isEmpty == true)
        #expect(try await first.createDatabase(name: "Sales #1", preference: .json).id == "Sales #1")
        #expect(try await first.setDatabasePreference(.sqlite, databaseID: "Sales #1").preference == .sqlite)
        let link = DatabaseArtifactLink(sourceID: "remote:configured-identity", databaseID: "Sales #1", relativePath: "nested/data.json")
        let data = try await first.databaseData(for: link)
        #expect(Data(base64Encoded: data.jsonBase64 ?? "") == Data("[1]".utf8))
        #expect(data.query == nil)
    }

    @Test func reportsOlderServiceAndOfflineErrorsWithoutEmptyCatalogSuccess() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteDatabaseFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let old = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42003")!, token: "old", session: session)
        await #expect(throws: RemoteWorkspaceClientError.invalidResponse("Update this workspace service in Settings to use remote databases.")) {
            try await old.databases()
        }
        let offline = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:42004")!, token: "offline", session: session)
        await #expect(throws: (any Error).self) { try await offline.databases() }
    }
}

private final class RemoteDatabaseFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let port = request.url!.port!
        if port == 42004 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(port == 42001 ? "one" : port == 42002 ? "two" : "old")")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        var row = #"{"id":"Sales #1","name":"Sales #1","preference":"json"}"#
        let response: String
        if port == 42003 { response = #"{"error":"not_found"}"# }
        else if request.httpMethod == "GET" {
            #expect(request.url?.path == "/v1/databases")
            response = port == 42001 ? "{\"databases\":[\(row)]}" : #"{"databases":[]}"#
        } else {
            #expect(payload?["databaseID"] as? String == "Sales #1")
            #expect(port == 42001)
            switch request.url?.path {
            case "/v1/databases":
                #expect(request.httpMethod == "POST")
                #expect(payload?["preference"] as? String == "json")
            case "/v1/databases/preference":
                #expect(request.httpMethod == "PATCH")
                #expect(payload?["preference"] as? String == "sqlite")
                row = row.replacingOccurrences(of: "json", with: "sqlite")
            case "/v1/databases/data":
                #expect(request.httpMethod == "POST")
                #expect(payload?["relativePath"] as? String == "nested/data.json")
                #expect(payload?["sourceID"] == nil)
                row = #"{"jsonBase64":"WzFd"}"#
            default: Issue.record("Unexpected database route")
            }
            response = row
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: port == 42003 ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

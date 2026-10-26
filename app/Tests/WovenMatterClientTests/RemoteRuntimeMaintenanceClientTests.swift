import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RemoteRuntimeMaintenanceClientTests {

    @Test func keepsRemoteRequestsOnTheirAuthenticatedWorkspaceOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteMaintenanceFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let first = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:41001")!, token: "workspace-one", session: session)
        let second = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:41002")!, token: "workspace-two", session: session)
        let initial = try await first.runtimeMaintenance()
        #expect(initial.count == 1)
        #expect(initial[0].enabled && initial[0].visible) // Legacy flags retired automatically.
        #expect(initial[0].components[0].installedVersion == "1.7.0")
        #expect(initial[0].components[1].installedVersion == "0.148.0")
        #expect(initial[0].failureCount == 2)
        #expect(initial[0].diagnosticPrompt == "Sanitized failure")
        _ = try await second.runtimeMaintenance(checkLatest: true)
        let selected = try await first.checkRuntimeUpdates(.codex)
        #expect(selected.id == .codex)
        #expect(selected.versionCheckAvailable == true)
        let operation = try await second.maintainRuntime(.codex, action: "update", sourceSHA256: "reviewed-digest", packageSpec: "fixture@1.2.3")
        #expect(operation.status == "running")
        let polled = try await second.operation(id: operation.id)
        #expect(polled.id == operation.id)
        let hermes = try await second.maintainRuntime(.hermes, action: "update", sourceSHA256: nil)
        #expect(hermes.harnessID == .hermes)
        let status = try await second.workspaceInstance(.opencode, action: "start")
        #expect(status.state == "running")
    }
}

private final class RemoteMaintenanceFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let first = request.url?.port == 41001
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer workspace-\(first ? "one" : "two")")
        let path = request.url!.path
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]

        var row = #"{"id":"codex","displayName":"Codex","enabled":false,"visible":false,"installed":true,"components":[{"id":"adapter","displayName":"codex-acp","path":"/home/woven/.local/bin/codex-acp","installedVersion":"1.7.0","latestVersion":"1.11.0","required":true,"installed":true},{"id":"engine","displayName":"Bundled Codex","path":null,"installedVersion":"0.148.0","latestVersion":null,"required":true,"installed":true}],"operation":null,"failureCount":2,"diagnosticPrompt":"Sanitized failure","notice":null,"updateAvailable":true,"versionCheckAvailable":true}"#
        if request.url?.port == 41003 { row = row.replacingOccurrences(of: "\"installed\":true", with: "\"installed\":false") }
        let value: String
        switch path {
        case "/v1/runtime-maintenance":
            #expect(first || request.url?.port == 41003)
            #expect(request.httpMethod == "GET")
            value = "{\"runtimes\":[\(row)]}"
        case "/v1/runtime-maintenance/check":
            #expect(!first)
            #expect(request.httpMethod == "POST")
            value = "{\"runtimes\":[\(row)]}"
        case "/v1/runtime-maintenance/codex/check":
            #expect(first)
            #expect(request.httpMethod == "POST")
            #expect(body.isEmpty)
            value = row
        case "/v1/runtime-maintenance/codex":
            #expect(request.url?.port != 41003, "Missing harnesses must never be activated")
            #expect(payload?["enabled"] as? Bool == true)
            #expect(payload?["visible"] as? Bool == true)
            #expect(request.httpMethod == "PATCH")
            value = row.replacingOccurrences(of: "\"enabled\":false", with: "\"enabled\":true")
                .replacingOccurrences(of: "\"visible\":false", with: "\"visible\":true")
        case "/v1/runtime-maintenance/codex/update":
            #expect(!first)
            #expect(payload?["confirmed"] as? Bool == true)
            #expect(payload?["sourceSHA256"] as? String == "reviewed-digest")
            #expect(payload?["packageSpec"] as? String == "fixture@1.2.3")
            #expect(request.httpMethod == "POST")
            value = #"{"id":"abcdef01-abcd-abcd-abcd-abcdef012345","harnessID":"codex","action":"update","status":"running","output":"","error":null,"startedAt":"2026-09-11T00:00:00Z","finishedAt":null}"#
        case "/v1/operations/abcdef01-abcd-abcd-abcd-abcdef012345":
            #expect(!first)
            #expect(request.httpMethod == "GET")
            value = #"{"id":"abcdef01-abcd-abcd-abcd-abcdef012345","harnessID":"codex","action":"update","status":"succeeded","output":"","error":null,"startedAt":"2026-09-11T00:00:00Z","finishedAt":null}"#
        case "/v1/runtime-maintenance/hermes/update":
            #expect(!first)
            #expect(request.httpMethod == "POST")
            #expect(payload?["confirmed"] as? Bool == true)
            #expect(payload?["sourceSHA256"] == nil)
            #expect(payload?["packageSpec"] == nil)
            value = #"{"id":"00000000-0000-0000-0000-000000000002","harnessID":"hermes","action":"update","status":"running","output":"","error":null,"startedAt":"2026-09-11T00:00:00Z","finishedAt":null}"#
        case "/v1/workspace-instances/opencode/start":
            #expect(!first)
            #expect(request.httpMethod == "POST")
            value = #"{"kind":"opencode","state":"running","pid":123,"version":"2.0.22","endpointPath":"/v1/workspace-instances/opencode/api","lastError":null}"#
        default:
            Issue.record("Unexpected remote route: \(path)")
            value = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(value.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

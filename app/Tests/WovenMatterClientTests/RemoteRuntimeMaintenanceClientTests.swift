import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RemoteRuntimeMaintenanceClientTests {
    @Test func bundledUpgradeArrowUsesOnlyCompatibleTarget() throws {
        func component(id: String = "bundled", installed: String = "0.153.4", target: String? = nil) throws -> RemoteRuntimeComponent {
            var object: [String: Any] = [
                "id": id, "displayName": "Component", "installedVersion": installed,
                "latestVersion": "0.154.0", "required": true, "installed": true,
            ]
            if let target { object["updateTargetVersion"] = target }
            return try JSONDecoder().decode(RemoteRuntimeComponent.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let current = try component(target: "0.153.4")
        #expect(current.latestVersion == "0.154.0") // Retained for diagnostics.
        #expect(current.availableUpdateVersion == nil)
        #expect(try component(installed: "0.153.1", target: "0.153.4").availableUpdateVersion == "0.153.4")
        #expect(try component().availableUpdateVersion == nil) // Unknown compatibility must not advertise latest.
        #expect(try component(id: "runtime").availableUpdateVersion == "0.154.0")
    }

    @Test func invalidatesSuspendedRequestsAfterCredentialOrDestinationChanges() {
        let configuration = RemoteWorkspaceConfiguration(name: "One", workspaceID: "one", hostName: "host-one")
        let credentialEpoch = UUID(), workspaceEpoch = UUID()
        let request = RemoteWorkspaceRequestIdentity(configuration: configuration,
                                                     credentialEpoch: credentialEpoch, workspaceEpoch: workspaceEpoch)
        func current(_ configuration: RemoteWorkspaceConfiguration?, enabled: Bool = true,
                     credential: UUID? = nil, workspace: UUID? = nil) -> Bool {
            request.isCurrent(configuration: configuration, credentialsEnabled: enabled,
                              credentialEpoch: credential ?? credentialEpoch, workspaceEpoch: workspace ?? workspaceEpoch)
        }
        #expect(current(configuration))
        #expect(!current(configuration, enabled: false))
        // Disable then re-enable cannot revive requests from the old credential epoch.
        #expect(!current(configuration, credential: UUID()))
        #expect(!current(nil))
        #expect(!current(configuration, workspace: UUID()))
        var moved = configuration
        moved.hostName = "host-two"
        #expect(!current(moved))
        moved = configuration
        moved.remotePort += 1
        #expect(!current(moved))
        // An unrelated metadata/network error does not itself change authorization.
        #expect(current(configuration))
    }

    @Test func currentNativeInstanceReplacesThePreLaunchHarnessSnapshot() {
        let stoppedSnapshot = RemoteHarnessStatus(
            id: .opencode, displayName: "OpenCode", transport: "opencode-v2", capabilities: [],
            state: "transport_unavailable", installationStatus: "installed", authenticationStatus: "unknown",
            transportStatus: "unavailable", transportError: "Start this workspace's server", setupMethods: [], detectedProviders: []
        )
        let running = RemoteWorkspaceInstanceStatus(kind: "opencode", state: "running", pid: 123,
                                                   version: "0.0.0-beta-19278", endpointPath: "/v1/workspace-instances/opencode/api", lastError: nil)
        let started = stoppedSnapshot.reconcilingOpenCode(instance: running, installed: true)
        #expect(started.state == "ready")
        #expect(started.transportStatus == "ready")
        #expect(started.transportError == nil)
        #expect(started.authenticationStatus == "unknown")
        let stopped = RemoteWorkspaceInstanceStatus(kind: "opencode", state: "stopped", pid: nil,
                                                   version: nil, endpointPath: running.endpointPath, lastError: nil)
        #expect(started.reconcilingOpenCode(instance: stopped, installed: true).state == "transport_unavailable")
        #expect(started.reconcilingOpenCode(instance: running, installed: false).state == "cli_missing")
        #expect(stoppedSnapshot.reconcilingOpenCode(instance: nil, installed: true) == stoppedSnapshot)
        let otherInstance = RemoteWorkspaceInstanceStatus(kind: "openclaw", state: "running", pid: 456,
                                                         version: nil, endpointPath: "/v1/openclaw/gateway/socket", lastError: nil)
        #expect(stoppedSnapshot.reconcilingOpenCode(instance: otherInstance, installed: true) == stoppedSnapshot)
        let acp = RemoteHarnessStatus(id: .codex, displayName: "Codex", transport: "acp", capabilities: [],
                                     state: "authentication_required", installationStatus: "installed", authenticationStatus: "required",
                                     transportStatus: "unknown", transportError: nil, setupMethods: [], detectedProviders: [])
        #expect(acp.reconcilingOpenCode(instance: running, installed: true) == acp)
    }

    @Test func keepsRemoteRequestsOnTheirAuthenticatedWorkspaceOrigin() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteMaintenanceFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let first = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:41001")!, token: "workspace-one", session: session)
        let second = RemoteWorkspaceServiceClient(baseURL: URL(string: "http://127.0.0.1:41002")!, token: "workspace-two", session: session)
        let initial = try await first.runtimeMaintenance()
        #expect(initial.count == 1)
        #expect(initial[0].components[0].installedVersion == "1.7.0")
        #expect(initial[0].components[1].installedVersion == "0.148.0")
        #expect(initial[0].failureCount == 2)
        #expect(initial[0].diagnosticPrompt == "Sanitized failure")
        _ = try await second.runtimeMaintenance(checkLatest: true)
        let selected = try await first.checkRuntimeUpdates(.codex)
        #expect(selected.id == .codex)
        #expect(selected.versionCheckAvailable == true)
        try await first.setRuntimePreferences(.codex, enabled: true, visible: false)
        let operation = try await second.maintainRuntime(.codex, action: "update", sourceSHA256: "reviewed-digest", packageSpec: "fixture@1.2.3")
        #expect(operation.status == "running")
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

        let row = #"{"id":"codex","displayName":"Codex","enabled":true,"visible":false,"installed":true,"components":[{"id":"adapter","displayName":"codex-acp","path":"/home/woven/.local/bin/codex-acp","installedVersion":"1.7.0","latestVersion":"1.11.0","required":true,"installed":true},{"id":"engine","displayName":"Bundled Codex","path":null,"installedVersion":"0.148.0","latestVersion":null,"required":true,"installed":true}],"operation":null,"failureCount":2,"diagnosticPrompt":"Sanitized failure","notice":null,"updateAvailable":true,"versionCheckAvailable":true}"#
        let value: String
        switch path {
        case "/v1/runtime-maintenance":
            #expect(first)
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
            #expect(first)
            #expect(payload?["enabled"] as? Bool == true)
            #expect(payload?["visible"] as? Bool == false)
            #expect(request.httpMethod == "PATCH")
            value = row
        case "/v1/runtime-maintenance/codex/update":
            #expect(!first)
            #expect(payload?["confirmed"] as? Bool == true)
            #expect(payload?["sourceSHA256"] as? String == "reviewed-digest")
            #expect(payload?["packageSpec"] as? String == "fixture@1.2.3")
            #expect(request.httpMethod == "POST")
            value = #"{"id":"00000000-0000-0000-0000-000000000001","harnessID":"codex","action":"update","status":"running","output":"","error":null,"startedAt":"2026-09-11T00:00:00Z","finishedAt":null}"#
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
            value = #"{"kind":"opencode","state":"running","pid":123,"version":"0.0.0-beta-19278","endpointPath":"/v1/workspace-instances/opencode/api","lastError":null}"#
        default:
            Issue.record("Unexpected remote route: \(path)")
            value = "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(value.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

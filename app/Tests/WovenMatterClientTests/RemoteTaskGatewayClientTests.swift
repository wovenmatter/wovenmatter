import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RemoteTaskGatewayClientTests {
    @Test func remoteBackgroundExecutionDefaultsOnAndPreservesOptOut() throws {
        let configuration = RemoteWorkspaceConfiguration(name: "Remote", workspaceID: "test", hostName: "host")
        #expect(configuration.backgroundExecutionEnabled)
        let encoder = JSONEncoder()
        var document = try #require(JSONSerialization.jsonObject(with: encoder.encode(configuration)) as? [String: Any])
        document.removeValue(forKey: "backgroundExecutionEnabled")
        let legacy = try JSONDecoder().decode(RemoteWorkspaceConfiguration.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(legacy.backgroundExecutionEnabled)
        var disabled = legacy
        disabled.backgroundExecutionEnabled = false
        #expect(try JSONDecoder().decode(RemoteWorkspaceConfiguration.self, from: encoder.encode(disabled)).backgroundExecutionEnabled == false)
    }

    @Test func durableLaunchUsesStableChannelAndOptOutKeepsDirectLaunch() throws {
        var configuration = RemoteWorkspaceConfiguration(name: "Remote", workspaceID: "test", hostName: "host")
        let channel = UUID().uuidString
        let launch = try RemoteHarnessLaunchResolver.resolve(configuration: configuration, runtimeKind: .codex,
            processWorkingDirectory: URL(fileURLWithPath: "/tmp"), durableChannelID: channel)
        #expect(launch.launch.arguments.last?.contains("/opt/wovenmatter/src/durable-acp-stdio.mjs") == true)
        #expect(launch.launch.arguments.last?.contains(channel) == true)
        configuration.backgroundExecutionEnabled = false
        let direct = try RemoteHarnessLaunchResolver.resolve(configuration: configuration, runtimeKind: .codex,
            processWorkingDirectory: URL(fileURLWithPath: "/tmp"), durableChannelID: channel)
        #expect(direct.launch.arguments.last?.contains("durable-acp") == false)
    }

    @Test func durablePiLaunchKeepsSessionArgumentsInsideSSHAndProbesDirect() throws {
        let configuration = RemoteWorkspaceConfiguration(name: "Remote", workspaceID: "test", hostName: "host")
        let channel = UUID().uuidString
        let launch = try RemoteHarnessLaunchResolver.resolve(configuration: configuration, runtimeKind: .pi,
            processWorkingDirectory: URL(fileURLWithPath: "/tmp"), durableChannelID: channel).launch
        #expect(launch.environment["WOVEN_DURABLE_REMOTE_ACP"] == "1")
        #expect(launch.arguments.last?.contains("durable-acp-stdio") == true)
        let resumed = PiRPCClient.sessionLaunchArguments(launch, sessionID: "native-session")
        #expect(resumed.count == launch.arguments.count)
        #expect(resumed.last?.hasSuffix("'--session' 'native-session'") == true)
        let probe = try RemoteHarnessLaunchResolver.resolve(configuration: configuration, runtimeKind: .pi,
            processWorkingDirectory: URL(fileURLWithPath: "/tmp")).launch
        #expect(probe.arguments.last?.contains("durable-acp-stdio") == false)
        #expect(probe.environment["WOVEN_DURABLE_REMOTE_ACP"] == nil)
    }

    @Test func durableGrokPermissionIsPassedToRelayAfterNodeExecutable() throws {
        let configuration = RemoteWorkspaceConfiguration(name: "Remote", workspaceID: "test", hostName: "host")
        let original = try RemoteHarnessLaunchResolver.resolve(configuration: configuration, runtimeKind: .grokBuild,
            processWorkingDirectory: URL(fileURLWithPath: "/tmp"), durableChannelID: UUID().uuidString).launch
        let launch = LocalACPRuntimeLaunchConfiguration(runtimeKind: .grokBuild,
            executableURL: original.executableURL, arguments: original.arguments,
            environment: original.environment, requestedPermission: "default", wrappedCommand: original.wrappedCommand)
        let prepared = try LocalACPSessionPermissions.prepareLaunch(launch)
        #expect(prepared.arguments.last?.contains("'node' '/opt/wovenmatter/src/durable-acp-stdio.mjs' '--permission-mode' 'default'") == true)
        #expect(prepared.explicitPermission == "default")
    }

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

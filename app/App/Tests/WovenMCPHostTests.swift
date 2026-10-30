import Foundation
import Network
import SQLite3
import Testing
import WorkspaceFixtures
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct WovenMCPHostTests {
    @Test func sessionOnlyHostRestartsImmediatelyAfterARealHTTPConnection() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let original = try await fixture.host.connection(sessionID: fixture.caller, captureID: "before-restart")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: #require(URL(string: original.endpointURL)))
        #expect((response as? HTTPURLResponse)?.statusCode == 401)
        fixture.host.stop()
        let restored = try WovenMCPHost(database: fixture.database) { _, _ in .init(success: true) }
        defer { restored.stop() }
        let renewed = try await restored.connection(sessionID: fixture.caller, captureID: "after-restart")
        #expect(renewed.bearerToken != original.bearerToken)
        #expect(renewed.captureID == "after-restart")
        let (_, restartedResponse) = try await session.data(from: #require(URL(string: renewed.endpointURL)))
        #expect((restartedResponse as? HTTPURLResponse)?.statusCode == 401)
    }

    @Test func occupiedSessionOnlyPortMovesWithoutSharingTheExistingListener() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let original = try await fixture.host.start()
        let restored = try WovenMCPHost(database: fixture.database) { _, _ in .init(success: true) }
        defer { restored.stop() }
        let replacement = try await restored.start()
        #expect(replacement != original)
        #expect(try await fixture.host.start() == original)
        // The new port is persisted for the next launch, with no external grants.
        let saved = try JSONDecoder().decode(GatewayJSONValue.self,
            from: Data(contentsOf: fixture.directory.appending(path: "mcp-access.json")))
        #expect(saved.objectValue?["port"]?.doubleValue == Double(try #require(URL(string: replacement)?.port)))
        #expect(saved.objectValue?["credentials"] == nil)
    }

    @Test(.enabled(if: mcpSDKFixtureAvailable(), "Run npm ci --prefix default-agent for the native HTTP MCP SDK fixture; --all installs this dependency."), .timeLimit(.minutes(1)), arguments: [false, true])
    func actualSDKInitializesDiscoversAndCallsTheNativeHTTPHost(outside: Bool) async throws {
        let serving = MCPServingFixture()
        let fixture = try await MCPHostFixture(exposure: serving.exposure())
        defer { fixture.remove() }
        let connection: WovenMCPConnection
        if outside {
            _ = try await fixture.host.access(.setEnabled(true))
            connection = .init(endpointURL: try #require(serving.child).target + "/mcp", bearerToken: "")
        } else { connection = try await fixture.host.connection(sessionID: fixture.caller, captureID: nil) }
        let script = mcpFixtureRepository().appending(path: "scripts/test-support/native-mcp-client.mjs")
        let result = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", script.path, connection.endpointURL] + (outside ? ["--outside"] : [])
            var environment = ProcessInfo.processInfo.environment
            environment["WOVEN_MCP_TEST_TOKEN"] = connection.bearerToken
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output; process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        #expect(result.0 == 0, "\(result.1)")
        let summary = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(result.1.utf8))
        #expect(summary.objectValue?["callerID"] == .string(outside ? WovenMCPCaller.outside : fixture.caller))
        #expect(summary.objectValue?["unauthorizedRejected"] == .bool(true))
        #expect(fixture.calls.callers == [outside ? WovenMCPCaller.outside : fixture.caller])
    }

    @Test func outsideAccessUsesGlobalToolsWithoutAChatOrCredential() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let request = try mcpHostRequest(token: nil, name: "woven_notes_list")
        #expect(await fixture.host.handle(request) == nil)
        #expect(await fixture.host.handle(request, allowOutside: true)?.status == 403)
        var settings = try await fixture.database.toolSettings()
        settings.externalMCP = .init(isEnabled: true, groups: [.notes, .sessions])
        try await fixture.database.saveToolSettings(settings)
        // Disabling every tool on the existing chat does not limit outside access.
        try await fixture.database.setSessionTools(.init(enabled: []), sessionID: fixture.caller)
        let response = try #require(await fixture.host.handle(request, allowOutside: true))
        let result = try JSONDecoder().decode(GatewayJSONValue.self, from: response.body)
        #expect(result.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        #expect(fixture.calls.callers == [WovenMCPCaller.outside])
        #expect(await fixture.host.handle(try mcpHostRequest(token: "old-revoked-token", name: "woven_notes_list"), allowOutside: true) == nil)
        settings.externalMCP?.groups.remove(.notes)
        try await fixture.database.saveToolSettings(settings)
        let disabled = try #require(await fixture.host.handle(request, allowOutside: true))
        #expect(try JSONDecoder().decode(GatewayJSONValue.self, from: disabled.body).objectValue?["error"] != nil)
        settings.externalMCP?.isEnabled = false
        try await fixture.database.saveToolSettings(settings)
        #expect(await fixture.host.handle(request, allowOutside: true)?.status == 403)
        #expect(fixture.calls.callers == [WovenMCPCaller.outside])
    }

    @Test func exposureTogglePublishesPrivateEndpointAndBlocksTheSameConnectionWhenDisabled() async throws {
        let serving = MCPServingFixture()
        let fixture = try await MCPHostFixture(exposure: serving.exposure())
        defer { fixture.remove() }
        let enabled = try await fixture.host.access(.setEnabled(true))
        #expect(enabled.exposureError == nil)
        #expect(enabled.endpointURL == "https://mcp.test.ts.net:8443/wovenmatter/mcp")
        let child = try #require(serving.child)
        let url = try #require(URL(string: child.target)).appending(path: "mcp")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try mcpHostRequest(token: nil, name: "woven_notes_list").body
        let (body, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(GatewayJSONValue.self, from: body).objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        let disabled = try await fixture.host.access(.setEnabled(false))
        #expect(!disabled.settings.isEnabled && !child.isRunning)
        let (_, blocked) = try await session.data(for: request)
        #expect((blocked as? HTTPURLResponse)?.statusCode == 401)
        // The independent master switch does not change native chat tools.
        #expect(try await fixture.database.sessionTools(fixture.caller).enabled.contains(.notes))
    }

    @Test func outsideDiscoveryAndTargetsFollowOnlyTheGlobalSelection() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        var settings = try await fixture.database.toolSettings()
        settings.externalMCP = .init(isEnabled: true, groups: [.timers])
        try await fixture.database.saveToolSettings(settings)
        let discovery = CompanionHTTPRequest(method: "POST", target: "/mcp", headers: [:],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        let response = try #require(await fixture.host.handle(discovery, allowOutside: true))
        let tools = try #require(JSONDecoder().decode(GatewayJSONValue.self, from: response.body).objectValue?["result"]?.objectValue?["tools"]?.arrayValue)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names.contains("woven_timers_list") && !names.contains("woven_notes_list"))
        let goal = try #require(tools.first { $0.objectValue?["name"] == .string("woven_goals_get") })
        #expect(goal.objectValue?["inputSchema"]?.objectValue?["required"]?.arrayValue?.contains(.string("sessionID")) == true)
        let targetless = try #require(await fixture.host.handle(mcpHostRequest(token: nil, name: "woven_goals_get"), allowOutside: true))
        #expect(try JSONDecoder().decode(GatewayJSONValue.self, from: targetless.body).objectValue?["error"] != nil)
        let targeted = try #require(await fixture.host.handle(mcpHostRequest(token: nil, name: "woven_goals_get", arguments: ["sessionID": .string(fixture.caller)]), allowOutside: true))
        #expect(try JSONDecoder().decode(GatewayJSONValue.self, from: targeted.body).objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        #expect(fixture.calls.callers == [WovenMCPCaller.outside])
        #expect(fixture.calls.requests.first?.targetSessionID == fixture.caller)
    }

    @Test func upgradePreservesLegacyMutationReceiptsAndNativePolicy() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let requestID = UUID().uuidString
        let note = try await fixture.database.createNote(folderID: nil, title: "Before upgrade", callerConversationID: fixture.caller, requestID: requestID)
        var connection: OpaquePointer?
        #expect(sqlite3_open(fixture.directory.appending(path: "workspace.sqlite").path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let sql = """
          CREATE TABLE workspace_tool_mutations_legacy(
            source_id TEXT NOT NULL REFERENCES dashboard_conversations(id), request_id TEXT NOT NULL,
            operation TEXT NOT NULL, input_digest TEXT NOT NULL, result_json TEXT NOT NULL,
            PRIMARY KEY(source_id,request_id));
          INSERT INTO workspace_tool_mutations_legacy SELECT * FROM workspace_tool_mutations;
          DROP TABLE workspace_tool_mutations;
          ALTER TABLE workspace_tool_mutations_legacy RENAME TO workspace_tool_mutations;
          """
        #expect(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
        let reopened = try await WorkspaceDatabase(url: fixture.directory.appending(path: "workspace.sqlite"))
        let replay = try await reopened.createNote(folderID: nil, title: "Before upgrade", callerConversationID: fixture.caller, requestID: requestID)
        #expect(replay == note)
        #expect(try await reopened.sessionTools(fixture.caller).enabled.contains(.notes))
        var settings = try await reopened.toolSettings()
        #expect(settings.externalMCP?.isEnabled != true)
        settings.externalMCP = .init(isEnabled: true, groups: [.notes])
        try await reopened.saveToolSettings(settings)
        let outside = try await reopened.createNote(folderID: nil, title: "After upgrade", callerConversationID: WovenMCPCaller.outside, requestID: UUID().uuidString)
        #expect(outside != note)
    }

    @Test func nativeCredentialsRetainConversationPolicyAndDoNotPersist() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let connection = try await fixture.host.connection(sessionID: fixture.caller, captureID: nil)
        _ = try await fixture.call(connection, name: "woven_notes_list")
        _ = try await fixture.database.setSessionToolEnabled(.notes, enabled: false, sessionID: fixture.caller)
        let denied = try await fixture.call(connection, name: "woven_notes_list")
        #expect(denied.objectValue?["error"] != nil)
        fixture.host.revokeSession(fixture.caller)
        #expect(try await fixture.host.handle(mcpHostRequest(token: connection.bearerToken, name: "woven_notes_list")) == nil)
        let saved = try String(contentsOf: fixture.directory.appending(path: "mcp-access.json"), encoding: .utf8)
        #expect(!saved.contains(connection.bearerToken))
    }

    @Test func outsidePrincipalCanMutateAndMessageWithoutCreatingAConversation() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        var settings = try await fixture.database.toolSettings()
        settings.externalMCP = .init(isEnabled: true)
        try await fixture.database.saveToolSettings(settings)
        let before = try await fixture.database.workspaceOverview().conversations.count
        let id = try await fixture.database.createNote(folderID: nil, title: "Outside note", callerConversationID: WovenMCPCaller.outside, requestID: UUID().uuidString)
        #expect(!id.isEmpty)
        let delivery = try await fixture.database.reserveToolDelivery(sourceID: WovenMCPCaller.outside, targetID: fixture.caller,
            text: "An outside instruction", requestID: UUID().uuidString)
        #expect(delivery.sourceTitle == "Outside agent")
        #expect(try await fixture.database.claimToolDelivery(id: delivery.id) != nil)
        #expect(try await fixture.database.workspaceOverview().conversations.count == before)
        let timer = WorkspaceSessionTimer(sessionID: fixture.caller, instruction: "Follow up", nextFireAt: Date().addingTimeInterval(60))
        _ = try await fixture.database.saveSessionTimer(timer, callerID: WovenMCPCaller.outside, requestID: UUID().uuidString)
        #expect(try await fixture.database.querySessionTimers(callerID: WovenMCPCaller.outside, sessionID: fixture.caller).objectValue?["rows"]?.arrayValue?.count == 1)
        let goal = try await fixture.database.mutateGoal(sessionID: fixture.caller,
            mutation: .set(objective: "Outside goal", tokenBudget: nil, turnBudget: nil),
            callerID: WovenMCPCaller.outside, requestID: UUID().uuidString)
        #expect(goal?.sessionID == fixture.caller)
        let assignment = try await fixture.database.requestCoordinationAccess(sourceID: WovenMCPCaller.outside,
            targetID: fixture.caller, purpose: "Monitor this work", requestID: UUID().uuidString)
        #expect(assignment.state == "accepted" && !assignment.notifications)
        #expect(try await fixture.database.sessionRelationship(fixture.caller).coordinatorID == WovenMCPCaller.outside)
        try await fixture.database.updateExternalMCP(enabled: false)
        #expect(try await fixture.database.sessionRelationship(fixture.caller).coordinatorID == nil)
    }

}

private func mcpFixtureRepository() -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    return root
}

private func mcpSDKFixtureAvailable() -> Bool {
    FileManager.default.fileExists(atPath: mcpFixtureRepository().appending(path:
        "default-agent/node_modules/@modelcontextprotocol/client/package.json").path)
}

@MainActor
private final class MCPHostCalls {
    var callers: [String] = []
    var requests: [WovenMatterToolRequest] = []
}

@MainActor
private struct MCPHostFixture {
    let directory: URL
    let database: WorkspaceDatabase
    let caller: String
    let otherCaller: String
    let host: WovenMCPHost
    let calls: MCPHostCalls

    init(exposure: CompanionTailscaleServe = CompanionTailscaleServe()) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "woven-mcp-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        caller = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "MCP caller", ownerDeviceID: UUID())
        otherCaller = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Other caller", ownerDeviceID: UUID())
        try await database.setSessionTools(.init(enabled: [.notes, .sessions, .browser]), sessionID: caller)
        let calls = MCPHostCalls()
        self.calls = calls
        host = try WovenMCPHost(database: database, exposure: exposure) { request, caller in
            calls.callers.append(caller); calls.requests.append(request)
            return .init(result: .object(["callerID": .string(caller)]), requestID: request.requestID)
        }
    }

    func call(_ connection: WovenMCPConnection, name: String, arguments: [String: GatewayJSONValue] = [:]) async throws -> GatewayJSONValue {
        let response = try #require(await host.handle(try mcpHostRequest(token: connection.bearerToken, name: name, arguments: arguments)))
        #expect(response.status == 200)
        return try JSONDecoder().decode(GatewayJSONValue.self, from: response.body)
    }

    func remove() {
        host.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func mcpHostRequest(token: String?, name: String, arguments: [String: GatewayJSONValue] = [:]) throws -> CompanionHTTPRequest {
    let message: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString),
        "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(arguments)])])
    return .init(method: "POST", target: "/mcp", headers: token.map { ["authorization": "Bearer " + $0] } ?? [:],
                 body: try JSONEncoder().encode(message))
}

@MainActor private final class MCPServingFixture {
    var child: MCPServingChild?
    func exposure() -> CompanionTailscaleServe {
        CompanionTailscaleServe(executable: URL(fileURLWithPath: "/fixture/tailscale"),
            probe: { [self] _, arguments in try await probe(arguments) },
            launch: { [self] _, arguments in
                let value = MCPServingChild(port: Int(arguments[1].dropFirst("--https=".count))!, target: arguments[3])
                child = value; return value
            })
    }
    func probe(_ arguments: [String]) throws -> Data {
        if arguments == ["status", "--json"] {
            return Data(#"{"BackendState":"Running","Self":{"DNSName":"mcp.test.ts.net."}}"#.utf8)
        }
        guard let child, child.isRunning else { return Data("{}".utf8) }
        return try JSONSerialization.data(withJSONObject: ["Foreground": ["fixture": [
            "TCP": [String(child.port): ["HTTPS": true]],
            "Web": ["mcp.test.ts.net:\(child.port)": ["Handlers": ["/wovenmatter": ["Proxy": child.target]]]]]]])
    }
}

@MainActor private final class MCPServingChild: CompanionServingProcess {
    let port: Int
    let target: String
    var isRunning = true
    init(port: Int, target: String) { self.port = port; self.target = target }
    func terminate() { isRunning = false }
}

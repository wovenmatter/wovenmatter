import Foundation
import SQLite3
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterLibraryStore
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
        let saved = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: fixture.directory.appending(path: "mcp-access.json")))
        #expect(saved.objectValue?["port"]?.doubleValue == Double(try #require(URL(string: replacement)?.port)))
        #expect(saved.objectValue?["credentials"] == nil)
    }

    @Test(.enabled(if: mcpSDKFixtureAvailable(), "Run npm ci --prefix default-agent for the native HTTP MCP SDK fixture; --all installs this dependency."), .timeLimit(.minutes(1)), arguments: [false, true])
    func actualSDKInitializesDiscoversAndCallsTheNativeHTTPHost(outside: Bool) async throws {
        let serving = FixtureTailscaleServe(dnsName: "mcp.test.ts.net")
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
        let summary = try JSONDecoder().decode(JSONValue.self, from: Data(result.1.utf8))
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
        let result = try JSONDecoder().decode(JSONValue.self, from: response.body)
        #expect(result.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        #expect(fixture.calls.callers == [WovenMCPCaller.outside])
        #expect(await fixture.host.handle(try mcpHostRequest(token: "old-revoked-token", name: "woven_notes_list"), allowOutside: true) == nil)
        settings.externalMCP?.groups.remove(.notes)
        try await fixture.database.saveToolSettings(settings)
        let disabled = try #require(await fixture.host.handle(request, allowOutside: true))
        #expect(try JSONDecoder().decode(JSONValue.self, from: disabled.body).objectValue?["error"] != nil)
        settings.externalMCP?.isEnabled = false
        try await fixture.database.saveToolSettings(settings)
        #expect(await fixture.host.handle(request, allowOutside: true)?.status == 403)
        #expect(fixture.calls.callers == [WovenMCPCaller.outside])
    }

    @Test func exposureTogglePublishesPrivateEndpointAndBlocksTheSameConnectionWhenDisabled() async throws {
        let serving = FixtureTailscaleServe(dnsName: "mcp.test.ts.net")
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
        #expect(try JSONDecoder().decode(JSONValue.self, from: body).objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        let disabled = try await fixture.host.access(.setEnabled(false))
        #expect(!disabled.settings.isEnabled && !child.isRunning)
        let (_, blocked) = try await session.data(for: request)
        #expect((blocked as? HTTPURLResponse)?.statusCode == 401)
        // The independent master switch does not change native chat tools.
        #expect(try await fixture.database.sessionTools(fixture.caller).enabled.contains(.notes))
    }

    @Test func restartingOutsideExposureRecoversWhenItsSavedPortIsOccupied() async throws {
        let serving = FixtureTailscaleServe(dnsName: "mcp.test.ts.net")
        let fixture = try await MCPHostFixture(exposure: serving.exposure())
        defer { fixture.remove() }
        let first = try await fixture.host.access(.setEnabled(true))
        #expect(URL(string: first.endpointURL)?.port == 8443)
        fixture.host.stop()
        // Device sharing or another Dev profile can claim the old port while
        // this instance is stopped. Preserve that route and publish a free one.
        serving.existingPorts = [8443]
        let restored = try WovenMCPHost(database: fixture.database, exposure: serving.exposure()) { _, _ in .init(success: true) }
        defer { restored.stop() }
        let restarted = try await restored.access(.status)
        #expect(restarted.exposureError == nil)
        #expect(URL(string: restarted.endpointURL)?.port == 10_000)
        #expect(serving.existingPorts == [8443])
        let saved = try JSONDecoder().decode(JSONValue.self,
            from: Data(contentsOf: fixture.directory.appending(path: "mcp-access.json")))
        #expect(saved.objectValue?["httpsPort"] == .number(10_000))
    }

    @Test func outsideDiscoveryAndTargetsFollowOnlyTheGlobalSelection() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        var settings = try await fixture.database.toolSettings()
        settings.externalMCP = .init(isEnabled: true, groups: [.timers])
        try await fixture.database.saveToolSettings(settings)
        let discovery = LibraryHTTPRequest(method: "POST", target: "/mcp", headers: [:],
            body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        let response = try #require(await fixture.host.handle(discovery, allowOutside: true))
        let tools = try #require(JSONDecoder().decode(JSONValue.self, from: response.body).objectValue?["result"]?.objectValue?["tools"]?.arrayValue)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names.contains("woven_timers_list") && !names.contains("woven_notes_list"))
        let goal = try #require(tools.first { $0.objectValue?["name"] == .string("woven_goals_get") })
        #expect(goal.objectValue?["inputSchema"]?.objectValue?["required"]?.arrayValue?.contains(.string("sessionID")) == true)
        let targetless = try #require(await fixture.host.handle(try mcpHostRequest(token: nil, name: "woven_goals_get"), allowOutside: true))
        #expect(try JSONDecoder().decode(JSONValue.self, from: targetless.body).objectValue?["error"] != nil)
        let targeted = try #require(await fixture.host.handle(try mcpHostRequest(token: nil, name: "woven_goals_get", arguments: ["sessionID": .string(fixture.caller)]), allowOutside: true))
        #expect(try JSONDecoder().decode(JSONValue.self, from: targeted.body).objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        #expect(fixture.calls.callers == [WovenMCPCaller.outside])
        #expect(fixture.calls.requests.first?.targetSessionID == fixture.caller)
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
        #expect(try await fixture.host.handle(try mcpHostRequest(token: connection.bearerToken, name: "woven_notes_list")) == nil)
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
        #expect(try await rows(fixture.database.querySessionTimers(callerID: WovenMCPCaller.outside, sessionID: fixture.caller)).count == 1)
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
    let persistence: PersistenceFixture
    var directory: URL { persistence.directory }
    let database: WorkspaceDatabase
    let caller: String
    let host: WovenMCPHost
    let calls: MCPHostCalls

    init(exposure: TailscaleServe = TailscaleServe()) async throws {
        persistence = try PersistenceFixture()
        database = try await persistence.openDatabase()
        caller = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "MCP caller", ownerDeviceID: UUID())
        try await database.setSessionTools(.init(enabled: [.notes, .sessions, .browser]), sessionID: caller)
        let calls = MCPHostCalls()
        self.calls = calls
        host = try WovenMCPHost(database: database, exposure: exposure) { request, caller in
            calls.callers.append(caller); calls.requests.append(request)
            return .init(result: .object(["callerID": .string(caller)]), requestID: request.requestID)
        }
    }

    func call(_ connection: WovenMCPConnection, name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let response = try #require(await host.handle(try mcpHostRequest(token: connection.bearerToken, name: name, arguments: arguments)))
        #expect(response.status == 200)
        return try JSONDecoder().decode(JSONValue.self, from: response.body)
    }

    func remove() {
        host.stop()
        persistence.remove()
    }
}

private func mcpHostRequest(token: String?, name: String, arguments: [String: JSONValue] = [:], headers: [String: String] = [:]) throws -> LibraryHTTPRequest {
    let message: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString),
        "method": .string("tools/call"), "params": .object(["name": .string(name), "arguments": .object(arguments)])])
    var headers = headers
    if let token { headers["authorization"] = "Bearer " + token }
    return .init(method: "POST", target: "/mcp", headers: headers,
                 body: try JSONEncoder().encode(message))
}


extension WovenMCPHostTests {
    nonisolated private static let machine = "8f1c0f5e-6a8a-4f0e-9a51-6b7d2c1e9f00"

    @Test func botIdentityAndOldSettingsDecodeWithoutAConversation() throws {
        let botID = UUID().uuidString
        let caller = WovenMCPCaller.bot(machineID: Self.machine.uppercased(), botID: botID)
        #expect(caller == "woven:bot:" + Self.machine + ":" + botID.lowercased())
        #expect(WovenMCPCaller.parseBot(caller)?.machineID == Self.machine)
        #expect(WovenMCPCaller.parseBot(caller)?.botID == botID.lowercased())
        #expect(WovenMCPCaller.isAppWide(caller) && WovenMCPCaller.isAppWide(WovenMCPCaller.outside))
        for forged in ["woven:bot:only-machine", "woven:bot::bot", "woven:bot:a b:c", "woven:bot:a:b:c", "woven:tailnet:x"] {
            #expect(!WovenMCPCaller.isAppWide(forged), "\(forged)")
        }
        var old = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkspaceToolSettings())) as? [String: Any])
        old.removeValue(forKey: "botMCP")
        let decoded = try JSONDecoder().decode(WorkspaceToolSettings.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.botMCP.isEnabled)
        #expect(!decoded.botMCP.groups.contains(.computer) && !decoded.botMCP.groups.contains(.executor))
    }

    @Test func eachBotHasItsOwnKeyThatNamesItAndPersistsOnlyAsADigest() async throws {
        let fixture = try await MCPHostFixture(); defer { fixture.remove() }
        let first = UUID().uuidString, second = UUID().uuidString
        let grant = try await fixture.host.issueBotKey(machineID: Self.machine, botID: first, botName: "Research Bot\n")
        let other = try await fixture.host.issueBotKey(machineID: Self.machine, botID: second, botName: "Other")
        #expect(URL(string: grant.endpointURL)?.host == "127.0.0.1")
        #expect(grant.bearerToken != other.bearerToken)
        let saved = try String(contentsOf: fixture.directory.appending(path: "mcp-access.json"), encoding: .utf8)
        #expect(!saved.contains(grant.bearerToken) && !saved.contains(other.bearerToken))
        // Headers never choose the identity: the key does.
        let forged = ["x-woven-bot-id": second, "x-woven-bot-name": "Impostor"]
        #expect(await fixture.host.handle(try mcpHostRequest(token: grant.bearerToken, name: "woven_notes_list", headers: forged))?.status == 200)
        let caller = WovenMCPCaller.bot(machineID: Self.machine, botID: first)
        #expect(fixture.calls.callers == [caller])
        let delivery = try await fixture.database.reserveToolDelivery(sourceID: caller, targetID: fixture.caller, text: "Hello", requestID: UUID().uuidString)
        #expect(delivery.sourceTitle == "Research Bot" && delivery.sourceHarness == "Research Bot")
        #expect(try await fixture.database.workspaceOverview().conversations.count == 1)
        // A new key replaces the old one.
        let rotated = try await fixture.host.issueBotKey(machineID: Self.machine, botID: first, botName: "Research Bot")
        #expect(await fixture.host.handle(try mcpHostRequest(token: grant.bearerToken, name: "woven_notes_list"), allowOutside: true) == nil)
        #expect(await fixture.host.handle(try mcpHostRequest(token: "wrong", name: "woven_notes_list"), allowOutside: true) == nil)
        #expect(await fixture.host.handle(try mcpHostRequest(token: rotated.bearerToken, name: "woven_notes_list"))?.status == 200)
        // Keys survive a restart of the server.
        fixture.host.stop()
        let reopened = try WovenMCPHost(database: fixture.database) { _, identity in .init(result: .string(identity)) }
        defer { reopened.stop() }
        #expect(await reopened.handle(try mcpHostRequest(token: rotated.bearerToken, name: "woven_notes_list"))?.status == 200)
        #expect(await reopened.handle(try mcpHostRequest(token: other.bearerToken, name: "woven_notes_list"))?.status == 200)
    }

    @Test func revokingOneBotLeavesTheOthersAndStaysRevokedUntilReinstated() async throws {
        let fixture = try await MCPHostFixture(); defer { fixture.remove() }
        let first = UUID().uuidString, second = UUID().uuidString
        let grant = try await fixture.host.issueBotKey(machineID: Self.machine, botID: first, botName: "First")
        let other = try await fixture.host.issueBotKey(machineID: Self.machine, botID: second, botName: "Second")
        let caller = WovenMCPCaller.bot(machineID: Self.machine, botID: first)
        fixture.host.revokeBotKey(callerID: caller, sticky: true)
        #expect(await fixture.host.handle(try mcpHostRequest(token: grant.bearerToken, name: "woven_notes_list")) == nil)
        #expect(await fixture.host.handle(try mcpHostRequest(token: other.bearerToken, name: "woven_notes_list"))?.status == 200)
        // The runtime cannot get around the user's revoke by asking again.
        await #expect(throws: WovenBotKeyError.self) {
            _ = try await fixture.host.issueBotKey(machineID: Self.machine, botID: first, botName: "First")
        }
        #expect(try await fixture.database.botCallers().first { $0.callerID == caller }?.revoked == true)
        await #expect(throws: (any Error).self) { try await fixture.database.requireTool(.notes, sessionID: caller) }
        try await fixture.host.reinstateBot(callerID: caller)
        let fresh = try await fixture.host.issueBotKey(machineID: Self.machine, botID: first, botName: "First")
        #expect(await fixture.host.handle(try mcpHostRequest(token: fresh.bearerToken, name: "woven_notes_list"))?.status == 200)
        // A bot its runtime deleted loses its key but is not marked revoked.
        fixture.host.revokeBotKey(callerID: WovenMCPCaller.bot(machineID: Self.machine, botID: second), sticky: false)
        #expect(await fixture.host.handle(try mcpHostRequest(token: other.bearerToken, name: "woven_notes_list")) == nil)
        _ = try await fixture.host.issueBotKey(machineID: Self.machine, botID: second, botName: "Second")
    }

    @Test func pauseAllStopsEveryBotOnTheMachineAndResumeKeepsTheirKeys() async throws {
        let fixture = try await MCPHostFixture(); defer { fixture.remove() }
        let grant = try await fixture.host.issueBotKey(machineID: Self.machine, botID: UUID().uuidString, botName: "One")
        let caller = WovenMCPCaller.bot(machineID: Self.machine, botID: "elsewhere")
        try await fixture.database.registerBotCaller(caller, displayName: "Coordinator")
        _ = try await fixture.database.requestCoordinationAccess(sourceID: caller, targetID: fixture.caller,
            purpose: "Coordinate", requestID: UUID().uuidString)
        try await fixture.host.setBotsPaused(machineID: Self.machine, paused: true)
        let paused = try #require(await fixture.host.handle(try mcpHostRequest(token: grant.bearerToken, name: "woven_notes_list")))
        #expect(try JSONDecoder().decode(JSONValue.self, from: paused.body).objectValue?["error"] != nil)
        #expect(try await fixture.database.sessionRelationship(fixture.caller).coordinatorID == nil)
        #expect(try await fixture.database.botCallers().allSatisfy(\.paused))
        #expect(try await fixture.database.isBotMachinePaused(Self.machine))
        // A bot created while paused still gets a key, which works on resume.
        let later = try await fixture.host.issueBotKey(machineID: Self.machine, botID: UUID().uuidString, botName: "Later")
        try await fixture.host.setBotsPaused(machineID: Self.machine, paused: false)
        #expect(await fixture.host.handle(try mcpHostRequest(token: grant.bearerToken, name: "woven_notes_list"))?.status == 200)
        #expect(await fixture.host.handle(try mcpHostRequest(token: later.bearerToken, name: "woven_notes_list"))?.status == 200)
    }

    @Test func botNamesAreBounded() async throws {
        let fixture = try await MCPHostFixture(); defer { fixture.remove() }
        let botID = UUID().uuidString
        let name = String(repeating: "A", count: 500) + "\n\u{0}\u{202E}"
        let grant = try await fixture.host.issueBotKey(machineID: Self.machine, botID: botID, botName: name)
        _ = await fixture.host.handle(try mcpHostRequest(token: grant.bearerToken, name: "woven_notes_list"))
        let caller = WovenMCPCaller.bot(machineID: Self.machine, botID: botID)
        let delivery = try await fixture.database.reserveToolDelivery(sourceID: caller, targetID: fixture.caller, text: "Attribution", requestID: UUID().uuidString)
        #expect(delivery.sourceTitle.count == 128 && !delivery.sourceTitle.contains("\n"))
        #expect(WovenMCPHost.botName("  ") == "Bot")
    }

    @Test(arguments: [false, true]) func botPolicyIsIndependentOfOutsideExposure(outside: Bool) async throws {
        let fixture = try await MCPHostFixture(); defer { fixture.remove() }
        let botID = UUID().uuidString
        let grant = try await fixture.host.issueBotKey(machineID: Self.machine, botID: botID, botName: "Bot")
        var settings = try await fixture.database.toolSettings()
        settings.externalMCP = .init(isEnabled: outside)
        try await fixture.database.saveToolSettings(settings)
        let request = try mcpHostRequest(token: grant.bearerToken, name: "woven_notes_list")
        #expect(await fixture.host.handle(request, allowOutside: outside)?.status == 200)
        settings.botMCP.groups.remove(.notes)
        try await fixture.database.saveToolSettings(settings)
        let disabledGroup = try #require(await fixture.host.handle(request, allowOutside: outside))
        #expect(try JSONDecoder().decode(JSONValue.self, from: disabledGroup.body).objectValue?["error"] != nil)
        settings.botMCP.isEnabled = false
        try await fixture.database.saveToolSettings(settings)
        let disabled = try #require(await fixture.host.handle(request, allowOutside: outside))
        #expect(try JSONDecoder().decode(JSONValue.self, from: disabled.body).objectValue?["error"] != nil)
        #expect(fixture.calls.callers.count == 1)
        _ = await fixture.host.handle(try mcpHostRequest(token: nil, name: "woven_notes_list"), allowOutside: outside)
        #expect(fixture.calls.callers.allSatisfy { WovenMCPCaller.parseBot($0) != nil } == !outside)
        #expect(fixture.calls.callers.last == (outside ? WovenMCPCaller.outside : WovenMCPCaller.bot(machineID: Self.machine, botID: botID)))
    }

    @Test func botToolsUseExplicitSessionTargets() async throws {
        let fixture = try await MCPHostFixture(); defer { fixture.remove() }
        let botID = UUID().uuidString
        _ = try await fixture.host.issueBotKey(machineID: Self.machine, botID: botID, botName: "Targeting bot")
        let caller = WovenMCPCaller.bot(machineID: Self.machine, botID: botID)
        let service = try await WorkspaceAgentToolsModel(database: fixture.database,
            sessionHandler: { _, _, _ in throw CancellationError() }, noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() }, usageHandler: { _ in throw CancellationError() }, onMutation: {})
        defer { service.stop() }
        let context = await service.handle(.init(arguments: ["context"]), callerID: caller)
        #expect(context.success && context.result == JSONValue.null)
        var goalRequest = WovenMatterToolRequest(arguments: ["goals", "get"])
        goalRequest.targetSessionID = fixture.caller
        let goal = await service.handle(goalRequest, callerID: caller)
        #expect(goal.success)
        let targetless = await service.handle(.init(arguments: ["goals", "get"]), callerID: caller)
        #expect(!targetless.success)
        let timer = WorkspaceSessionTimer(sessionID: fixture.caller, instruction: "Follow up", nextFireAt: Date().addingTimeInterval(60))
        _ = try await fixture.database.saveSessionTimer(timer, callerID: caller, requestID: UUID().uuidString)
        #expect(try await rows(fixture.database.querySessionTimers(callerID: caller, sessionID: fixture.caller)).count == 1)
        let run = try await fixture.database.beginLocalACPRun(conversationID: fixture.caller, input: .init(text: "Render"))
        let json = #"{"action":"render","html":"<p>From a bot</p>","title":"Bot page","height":160}"#
        var renderRequest = WovenMatterToolRequest(arguments: ["html", "call", "--json", json])
        renderRequest.targetSessionID = fixture.caller
        let render = await service.handle(renderRequest, callerID: caller)
        #expect(render.success, "\(render.error ?? "")")
        let history = try await fixture.database.conversationHistoryPage(id: fixture.caller, limit: 20, compactActivities: true)
        #expect(history.activities.contains { $0.runID == run.runID && $0.activity.htmlRender?.title == "Bot page" })
    }

    /// Relationships synchronize between machines and bot keys do not. A machine that does
    /// not host this bot must neither clear its coordination nor consume its events.
    @Test func aBotHostedByAnotherMachineKeepsItsCoordinationHere() async throws {
        let fixture = try await MCPHostFixture(); defer { fixture.remove() }
        let botID = UUID().uuidString
        _ = try await fixture.host.issueBotKey(machineID: Self.machine, botID: botID, botName: "Elsewhere")
        let caller = WovenMCPCaller.bot(machineID: Self.machine, botID: botID)
        _ = try await fixture.database.requestCoordinationAccess(sourceID: caller, targetID: fixture.caller,
            purpose: "Coordinate", requestID: UUID().uuidString)
        try await fixture.database.write { connection in
            try connection.toolsExecuteUnlocked("DELETE FROM workspace_mcp_bot_machines WHERE machine_id=?", [Self.machine])
        }
        #expect(try await fixture.database.collectCoordinationTurnNotifications().isEmpty)
        #expect(try await fixture.database.sessionRelationship(fixture.caller).coordinatorID == caller)
        #expect(try await fixture.database.recordCoordinationNeedsInput(sessionID: fixture.caller,
            requestID: "elsewhere-input", requiresUserApproval: true) == nil)
        #expect(try await fixture.database.sessionRelationship(fixture.caller).coordinatorID == caller)

        // A relationship that arrives through sync names a caller this machine never saw.
        let foreign = WovenMCPCaller.bot(machineID: UUID().uuidString, botID: UUID().uuidString)
        let violations = try await fixture.database.write { connection -> Int in
            try connection.toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=? WHERE session_id=?", [foreign, fixture.caller])
            return try connection.historyRowsUnlocked("PRAGMA foreign_key_check(workspace_session_relationships)", values: []).count
        }
        #expect(violations == 0)
        #expect(try await fixture.database.collectCoordinationTurnNotifications().isEmpty)
        #expect(try await fixture.database.sessionRelationship(fixture.caller).coordinatorID == foreign)
        try await fixture.database.write { connection in
            try connection.toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=? WHERE session_id=?", [caller, fixture.caller])
        }

        // A local revocation still retires it.
        _ = try await fixture.host.issueBotKey(machineID: Self.machine, botID: botID, botName: "Elsewhere")
        fixture.host.revokeBotKey(callerID: caller, sticky: true)
        try await fixture.host.reinstateBot(callerID: caller)
        #expect(try await fixture.database.collectCoordinationTurnNotifications().isEmpty)
        #expect(try await fixture.database.sessionRelationship(fixture.caller).coordinatorID == nil)
    }

    @Test func botNotificationsRetryWithoutReobservingOrDuplicatingAcceptedEvents() async throws {
        let fixture = try await MCPHostFixture(); defer { fixture.remove() }
        let botID = UUID().uuidString
        _ = try await fixture.host.issueBotKey(machineID: Self.machine, botID: botID, botName: "Coordinator")
        let caller = WovenMCPCaller.bot(machineID: Self.machine, botID: botID)
        let assignment = try await fixture.database.requestCoordinationAccess(sourceID: caller, targetID: fixture.caller,
            purpose: "Coordinate", requestID: UUID().uuidString)
        #expect(assignment.state == "accepted" && assignment.notifications)
        try await fixture.database.setCoordinationNotifications(sourceID: caller, targetID: fixture.caller, enabled: true)
        #expect(try await fixture.database.collectCoordinationTurnNotifications().isEmpty)
        let delivery = try #require(try await fixture.database.recordCoordinationNeedsInput(sessionID: fixture.caller,
            requestID: "fixture-input", requiresUserApproval: true))
        #expect(delivery.text.contains(fixture.caller) && delivery.text.contains("MCP caller") && delivery.text.contains("blocked"))
        #expect(try await fixture.database.recordCoordinationNeedsInput(sessionID: fixture.caller, requestID: "fixture-input", requiresUserApproval: true) == nil)
        await #expect(throws: (any Error).self) { _ = try await fixture.host.deliverBotNotification(delivery) }
        #expect(try await fixture.database.toolDelivery(id: delivery.id)?.status == "queued")
        try await fixture.database.write { try $0.toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET retry_after=0 WHERE id=?", [delivery.id]) }
        var attempts = 0
        var accepted = Set<String>()
        var machines = Set<String>()
        fixture.host.botNotificationSink = { event in
            attempts += 1
            accepted.insert(event.id)
            machines.insert(event.machineID + ":" + event.botID)
            if attempts == 1 { throw CancellationError() } // Lost acknowledgement after receiver acceptance.
        }
        await #expect(throws: CancellationError.self) { _ = try await fixture.host.deliverBotNotification(delivery) }
        try await fixture.database.write { try $0.toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET retry_after=0 WHERE id=?", [delivery.id]) }
        fixture.host.stop()
        let restored = try WovenMCPHost(database: fixture.database) { _, _ in .init(success: true) }
        restored.botNotificationSink = fixture.host.botNotificationSink
        defer { restored.stop() }
        #expect(try await restored.deliverBotNotification(delivery))
        #expect(try await restored.deliverBotNotification(delivery))
        #expect(attempts == 2 && accepted.count == 1)
        #expect(machines == [Self.machine + ":" + botID.lowercased()])
        #expect(try await fixture.database.toolDelivery(id: delivery.id)?.status == "accepted")
        let run = try await fixture.database.beginLocalACPRun(conversationID: fixture.caller, input: .init(text: "Fail in fixture"))
        try await fixture.database.completeLocalACPRun(runID: run.runID, error: "Fixture failure")
        let failures = try await fixture.database.collectCoordinationTurnNotifications()
        #expect(failures.count == 1 && failures.first?.text.contains("failed") == true)
        let creationID = UUID().uuidString.lowercased()
        _ = try await fixture.database.reserveToolSessionCreation(sourceID: caller, requestID: creationID,
            arguments: ["sessions", "create"], purpose: "Pending creation", managed: true)
        restored.revokeBotKey(callerID: caller, sticky: true)
        // Wait for the serialized revocation through the host API.
        _ = try? await restored.deliverBotNotification(delivery)
        #expect(try await fixture.database.sessionRelationship(fixture.caller).coordinatorID == nil)
        let creation = try await fixture.database.read { connection in
            try connection.historyRowsUnlocked("SELECT status FROM workspace_session_creations WHERE id=?", values: [creationID]).first
        }
        #expect(creation?.objectValue?["status"] == .string("failed"))
    }
}

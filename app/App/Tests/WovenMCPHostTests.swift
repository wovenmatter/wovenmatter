import Foundation
import Network
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
        #expect(saved.objectValue?["credentials"]?.arrayValue?.isEmpty == true)
    }

    @Test func occupiedPersistentEndpointFailsWithoutMovingOrReplacingCredentials() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let access = try await fixture.host.access(.create(label: "Stable external endpoint", sessionID: fixture.caller,
            groups: [.notes], readOnly: true))
        let connection = try #require(access.issuedConnection)
        let accessFile = fixture.directory.appending(path: "mcp-access.json")
        let original = try Data(contentsOf: accessFile)
        let restored = try WovenMCPHost(database: fixture.database) { _, _ in .init(success: true) }
        defer { restored.stop() }
        do {
            _ = try await restored.start()
            Issue.record("An occupied persistent MCP endpoint must remain exclusive")
        } catch {
            #expect((error as? NWError) == .posix(.EADDRINUSE))
        }
        #expect(try Data(contentsOf: accessFile) == original)
        #expect(try await fixture.host.start() == connection.endpointURL)
        let result = try await fixture.call(connection, name: "woven_notes_list")
        #expect(result.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
    }

    @Test func computerUseRequiresExplicitEnablementAndRevocableMcpAuthority() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let access = try await fixture.host.access(.create(label: "Computer acceptance", sessionID: fixture.caller,
            groups: [.computer], readOnly: false))
        let connection = try #require(access.issuedConnection)
        let disabled = try await fixture.call(connection, name: "woven_computer_use", arguments: ["action": .string("apps")])
        #expect(disabled.objectValue?["error"] != nil)
        #expect(fixture.calls.callers.isEmpty)
        _ = try await fixture.database.setSessionToolEnabled(.computer, enabled: true, sessionID: fixture.caller)
        let enabled = try await fixture.call(connection, name: "woven_computer_use", arguments: ["action": .string("snapshot"), "pid": .number(7), "windowID": .number(9)])
        #expect(enabled.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        #expect(fixture.calls.callers == [fixture.caller])
        _ = try await fixture.host.access(.revoke(try #require(access.clients.first?.id)))
        #expect(try await fixture.host.handle(mcpHostRequest(token: connection.bearerToken, name: "woven_computer_use")) == nil)
        #expect(fixture.calls.callers == [fixture.caller])
    }

    @Test(.enabled(if: mcpSDKFixtureAvailable(), "Run npm ci --prefix default-agent for the native HTTP MCP SDK fixture; --all installs this dependency."), .timeLimit(.minutes(1)))
    func actualSDKInitializesDiscoversAndCallsTheNativeHTTPHost() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let access = try await fixture.host.access(.create(label: "HTTP SDK fixture", sessionID: fixture.caller,
            groups: [.notes], readOnly: true))
        let connection = try #require(access.issuedConnection)
        let script = mcpFixtureRepository().appending(path: "scripts/test-support/native-mcp-client.mjs")
        let result = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", script.path, connection.endpointURL]
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
        #expect(summary.objectValue?["callerID"] == .string(fixture.caller))
        #expect(summary.objectValue?["unauthorizedRejected"] == .bool(true))
        #expect(fixture.calls.callers == [fixture.caller])
    }

    @Test func bearerScopeReadOnlyAndCurrentPolicyAreEnforcedBeforeDispatch() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let access = try await fixture.host.access(.create(label: "Outside reader", sessionID: fixture.caller,
            groups: [.notes, .browser], readOnly: true))
        let connection = try #require(access.issuedConnection)
        #expect(try await fixture.host.handle(mcpHostRequest(token: nil, name: "woven_notes_list")) == nil)
        #expect(try await fixture.host.handle(mcpHostRequest(token: connection.bearerToken + "invalid", name: "woven_notes_list")) == nil)

        let read = try await fixture.call(connection, name: "woven_notes_list")
        #expect(read.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["success"] == .bool(true))
        #expect(fixture.calls.callers == [fixture.caller])

        let create = try await fixture.call(connection, name: "woven_notes_create", arguments: ["title": .string("Forbidden")])
        let cancel = try await fixture.call(connection, name: "woven_browser_use_cancel", arguments: ["id": .string("all")])
        let outOfScope = try await fixture.call(connection, name: "woven_sessions_list")
        let forgedCaller = try await fixture.call(connection, name: "woven_notes_list", arguments: ["sessionID": .string(fixture.otherCaller)])
        for denied in [create, cancel, outOfScope, forgedCaller] { #expect(denied.objectValue?["error"] != nil) }
        #expect(fixture.calls.callers == [fixture.caller])

        _ = try await fixture.database.setSessionToolEnabled(.notes, enabled: false, sessionID: fixture.caller)
        let disabled = try await fixture.call(connection, name: "woven_notes_list")
        #expect(disabled.objectValue?["error"] != nil)
        #expect(fixture.calls.callers == [fixture.caller])
        let discovery = CompanionHTTPRequest(method: "POST", target: "/mcp",
            headers: ["authorization": "Bearer " + connection.bearerToken],
            body: Data(#"{"jsonrpc":"2.0","id":"discovery","method":"tools/list"}"#.utf8))
        let listed = try #require(await fixture.host.handle(discovery))
        let catalog = try JSONDecoder().decode(GatewayJSONValue.self, from: listed.body)
        let names = catalog.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? []
        #expect(names.contains("woven_notes_list"))
        #expect(!names.contains("woven_notes_create") && !names.contains("woven_sessions_list"))
        _ = try await fixture.database.setSessionToolEnabled(.notes, enabled: true, sessionID: fixture.caller)
        let enabledAgain = try await fixture.call(connection, name: "woven_notes_list")
        #expect(enabledAgain.objectValue?["result"]?.objectValue?["isError"] == .bool(false))
        #expect(fixture.calls.callers == [fixture.caller, fixture.caller])
    }

    @Test func externalCredentialsPersistAsHashesAndSessionCredentialsDoNotPersist() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let access = try await fixture.host.access(.create(label: "Persistent reader", sessionID: fixture.caller,
            groups: [.notes], readOnly: true))
        let external = try #require(access.issuedConnection)
        let session = try await fixture.host.connection(sessionID: fixture.caller, captureID: nil)
        let saved = try String(contentsOf: fixture.directory.appending(path: "mcp-access.json"), encoding: .utf8)
        #expect(!saved.contains(external.bearerToken) && !saved.contains(session.bearerToken))
        #expect(saved.contains("tokenHash") && saved.contains("Persistent reader"))

        // Recreate the registry from disk without starting a competing listener.
        let restored = try WovenMCPHost(database: fixture.database) { request, caller in
            .init(result: .object(["callerID": .string(caller)]), requestID: request.requestID)
        }
        defer { restored.stop() }
        let response = try #require(await restored.handle(try mcpHostRequest(token: external.bearerToken, name: "woven_notes_list")))
        #expect(response.status == 200)
        let result = try JSONDecoder().decode(GatewayJSONValue.self, from: response.body)
        #expect(result.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["success"] == .bool(true))
        #expect(try await restored.handle(mcpHostRequest(token: session.bearerToken, name: "woven_notes_list")) == nil)
        #expect(try await fixture.host.access(.status).issuedConnection == nil)
    }

    @Test func revocationImmediatelyRejectsTheCredentialAndRemovesItsPersistentGrant() async throws {
        let fixture = try await MCPHostFixture()
        defer { fixture.remove() }
        let access = try await fixture.host.access(.create(label: "Revocable reader", sessionID: fixture.caller,
            groups: [.notes], readOnly: true))
        let connection = try #require(access.issuedConnection)
        let id = try #require(access.clients.first?.id)
        _ = try await fixture.call(connection, name: "woven_notes_list")
        let revoked = try await fixture.host.access(.revoke(id))
        #expect(revoked.clients.isEmpty && revoked.issuedConnection == nil)
        #expect(try await fixture.host.handle(mcpHostRequest(token: connection.bearerToken, name: "woven_notes_list")) == nil)
        #expect(fixture.calls.callers == [fixture.caller])
        let saved = try String(contentsOf: fixture.directory.appending(path: "mcp-access.json"), encoding: .utf8)
        #expect(!saved.contains(id) && !saved.contains("Revocable reader"))
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
}

@MainActor
private struct MCPHostFixture {
    let directory: URL
    let database: WorkspaceDatabase
    let caller: String
    let otherCaller: String
    let host: WovenMCPHost
    let calls: MCPHostCalls

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "woven-mcp-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        caller = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "MCP caller", ownerDeviceID: UUID())
        otherCaller = try await database.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Other caller", ownerDeviceID: UUID())
        try await database.setSessionTools(.init(enabled: [.notes, .sessions, .browser]), sessionID: caller)
        let calls = MCPHostCalls()
        self.calls = calls
        host = try WovenMCPHost(database: database) { request, caller in
            calls.callers.append(caller)
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

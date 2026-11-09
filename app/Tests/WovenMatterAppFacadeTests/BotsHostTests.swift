import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor
private final class FakeEngine: BotEngineHost {
    var ensured: [BotResourceSettings] = []
    var applied: [BotResourceSettings] = []
    var forwards: [String] = []
    var stopped = 0
    let socket: String
    init(socket: String) { self.socket = socket }
    func ensureRunning(resources: BotResourceSettings) async throws -> BotEngineStatus {
        ensured.append(resources)
        return .init(state: .running, socketPath: socket)
    }
    func status() async -> BotEngineStatus { .init(state: stopped > 0 ? .stopped : .running, socketPath: socket) }
    func apply(resources: BotResourceSettings) async throws { applied.append(resources) }
    func diskUsedByBots() async -> Int64? { 2 * BotResourceSettings.gib }
    func forwardPort(botID: String, containerPort: Int) async throws -> UInt16 { forwards.append(botID + ":\(containerPort)"); return 1 }
    func removeForward(botID: String, containerPort: Int) async {}
    func stop() async { stopped += 1 }
}

@MainActor
private final class FakeChild: BotsRuntimeChild {
    var isRunning = true
    let processIdentifier: Int32 = 4242
    func terminate() { isRunning = false }
    func kill() { isRunning = false }
}

@MainActor
private final class HostFixture {
    let directory: URL
    let engine: FakeEngine
    var launches: [[String]] = []
    var issued: [(String, String, String)] = []
    var revoked: [(String, Bool)] = []
    var recorded: [(String, String, BotConversationReport)] = []
    let host: BotsHostController
    let supervisor: BotsRuntimeSupervisor

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "bots-host-\(UUID().uuidString)")
        let bundleRoot = directory.appending(path: "bundle")
        try FileManager.default.createDirectory(at: bundleRoot.appending(path: "src"), withIntermediateDirectories: true)
        try Data("export {}".utf8).write(to: bundleRoot.appending(path: "src/cli.ts"))
        try Data(#"{"name":"bots","version":"0.3.1"}"#.utf8).write(to: bundleRoot.appending(path: "package.json"))
        let bundle = BotsRuntimeBundle(node: URL(fileURLWithPath: "/usr/bin/true"), root: bundleRoot)
        engine = FakeEngine(socket: directory.appending(path: "docker.sock").path)
        let state = directory.appending(path: "Bots")
        var launches: [[String]] = []
        supervisor = BotsRuntimeSupervisor(directory: state, bundle: bundle, launch: { _, arguments, _, _, _ in
            launches.append(arguments)
            return FakeChild()
        }, probe: { _, _ in true })
        var issued: [(String, String, String)] = []
        var revoked: [(String, Bool)] = []
        var recorded: [(String, String, BotConversationReport)] = []
        let gib = BotResourceSettings.gib
        let dependencies = BotsHostDependencies(
            identity: { ("D3VICE-0001", "Fixture Mac") }, appVersion: "1.4.0",
            issueKey: { machine, bot, name in issued.append((machine, bot, name)); return .init(endpointURL: "http://127.0.0.1:1/mcp", bearerToken: "bot-key") },
            revokeKey: { caller, sticky in revoked.append((caller, sticky)) },
            reinstate: { _ in }, setPaused: { _, _ in }, callers: { [] }, botMCP: { nil },
            recordConversation: { machine, bot, report in recorded.append((machine, bot, report)); return report.entries.count },
            deleteConversations: { _, _ in },
            inferenceCredential: { provider in provider == "openai" ? .init(type: "api_key", key: "fixture-key") : nil },
            capacity: { _ in BotMachineCapacity(memoryBytes: 16 * gib, diskTotalBytes: 500 * gib, diskFreeBytes: 200 * gib) })
        host = BotsHostController(directory: state, engine: engine, bundle: bundle, dependencies: dependencies, supervisor: supervisor)
        // Closures above write through these boxes; mirror them after each step.
        self.launches = launches; self.issued = issued; self.revoked = revoked; self.recorded = recorded
        sync = { [unowned self] in self.launches = launches; self.issued = issued; self.revoked = revoked; self.recorded = recorded }
    }
    var sync: () -> Void = {}

    func config() throws -> [String: Any] {
        let data = try Data(contentsOf: supervisor.configURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(what)")
    throw CancellationError()
}

private func hostRequest(_ method: String, _ path: String, token: String?, body: [String: Any]? = nil) throws -> CompanionHTTPRequest {
    var headers = ["host": "127.0.0.1"]
    if let token { headers["authorization"] = "Bearer " + token }
    if body != nil { headers["content-type"] = "application/json" }
    return .init(method: method, target: path, headers: headers, body: try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data())
}

@MainActor @Suite(.serialized)
struct BotsHostTests {
    @Test func turningBotsOnStartsTheEngineThenTheRuntimeWithItsConfig() async throws {
        let fixture = try HostFixture(); defer { fixture.remove() }
        _ = try await fixture.host.perform(.setEnabled(true))
        try await waitFor("runtime") { fixture.supervisor.phase == .running }
        fixture.sync()
        #expect(fixture.engine.ensured == [.defaults])
        #expect(fixture.launches.first?.suffix(3) == ["serve", "--config", fixture.supervisor.configURL.path])
        let config = try fixture.config()
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.supervisor.configURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let listen = try #require(config["listen"] as? [String: Any])
        #expect(listen["host"] as? String == "127.0.0.1")
        #expect((config["engine"] as? [String: Any])?["socket"] as? String == fixture.engine.socket)
        #expect((config["engine"] as? [String: Any])?["kind"] as? String == "mac-vm")
        #expect((config["image"] as? [String: Any])?["tag"] as? String == "wovenmatter/bots:0.3.1")
        #expect((config["limits"] as? [String: Any])?["botMemoryBytes"] as? Int64 == 4 * BotResourceSettings.gib)
        #expect((config["machine"] as? [String: Any])?["deviceID"] as? String == "d3vice-0001")
        let hostURL = (config["host"] as? [String: Any])?["url"] as? String
        #expect(hostURL.flatMap { URL(string: $0) }?.host == "127.0.0.1")
        #expect(config["runtimeToken"] as? String != (config["host"] as? [String: Any])?["token"] as? String)

        let snapshot = await fixture.host.snapshot()
        let machine = try #require(snapshot.machines.first)
        #expect(machine.kind == .thisMac && machine.state == .ready && machine.id == "d3vice-0001")
        #expect(machine.socket?.url.absoluteString == "ws://127.0.0.1:\(listen["port"] as? Int ?? 0)/ws")
        #expect(machine.socket?.bearer == config["runtimeToken"] as? String)
        #expect(machine.versions.runtime == "0.3.1" && machine.capacity?.diskUsedByBotsBytes == 2 * BotResourceSettings.gib)

        _ = try await fixture.host.perform(.setEnabled(false))
        #expect(fixture.engine.stopped == 1 && fixture.supervisor.phase == .stopped)
        #expect(await fixture.host.snapshot().machines.first?.state == .off)
    }

    @Test func resourcesAreClampedAppliedToTheEngineAndPassedToTheRuntime() async throws {
        let fixture = try HostFixture(); defer { fixture.remove() }
        _ = try await fixture.host.perform(.setEnabled(true))
        try await waitFor("runtime") { fixture.supervisor.phase == .running }
        let gib = BotResourceSettings.gib
        _ = try await fixture.host.perform(.setResources(machineID: "D3VICE-0001", .init(poolBytes: 64 * gib, perBotBytes: nil, diskBytes: gib)))
        #expect(fixture.engine.applied == [.init(poolBytes: 16 * gib, perBotBytes: nil, diskBytes: 2 * gib)])
        let limits = try #require(try fixture.config()["limits"] as? [String: Any])
        #expect(limits.keys.contains("botMemoryBytes") && limits["botMemoryBytes"] is NSNull)
        // The choice outlives the server.
        let saved = try Data(contentsOf: fixture.directory.appending(path: "Bots/host.json"))
        #expect(try JSONDecoder().decode(BotsHostController.Persisted.self, from: saved).resources?.poolBytes == 16 * gib)
    }

    @Test func theHostAPIRequiresItsOwnBearerAndServesEachRoute() async throws {
        let fixture = try HostFixture(); defer { fixture.remove() }
        let api = fixture.host.makeHostAPI(machineID: "d3vice-0001")
        let token = fixture.host.persisted.hostToken
        #expect(await api.handle(try hostRequest("POST", "/v1/bots-host/mcp-keys", token: nil, body: ["botID": "b1"])).status == 401)
        #expect(await api.handle(try hostRequest("POST", "/v1/bots-host/mcp-keys", token: fixture.host.persisted.runtimeToken, body: ["botID": "b1"])).status == 401)
        let key = await api.handle(try hostRequest("POST", "/v1/bots-host/mcp-keys", token: token, body: ["botID": "b1", "botName": "Builder"]))
        #expect(key.status == 200)
        let keyBody = try #require(try JSONSerialization.jsonObject(with: key.body) as? [String: String])
        #expect(keyBody == ["endpoint": "http://127.0.0.1:1/mcp", "token": "bot-key"])
        #expect(await api.handle(try hostRequest("POST", "/v1/bots-host/mcp-keys", token: token, body: ["botID": "not valid"])).status == 400)
        #expect(await api.handle(try hostRequest("DELETE", "/v1/bots-host/mcp-keys/b1", token: token)).status == 200)
        let credential = await api.handle(try hostRequest("POST", "/v1/bots-host/inference-credentials", token: token, body: ["provider": "openai"]))
        #expect(credential.status == 200)
        #expect(String(decoding: credential.body, as: UTF8.self).contains("fixture-key"))
        #expect(await api.handle(try hostRequest("POST", "/v1/bots-host/inference-credentials", token: token, body: ["provider": "xai"])).status == 404)
        let entries = await api.handle(try hostRequest("POST", "/v1/bots-host/conversations/b1/entries", token: token, body: [
            "botName": "Builder", "conversationId": 7, "entries": [["id": 1, "role": "user", "text": "hi"], ["id": 2, "role": "assistant", "text": "hello"]],
        ]))
        #expect(entries.status == 200)
        #expect(await api.handle(try hostRequest("GET", "/v1/bots-host/previews", token: token)).status == 200)
        #expect(await api.handle(try hostRequest("GET", "/v1/bots-host/unknown", token: token)).status == 404)
        fixture.sync()
        #expect(fixture.issued.map(\.0) == ["d3vice-0001"] && fixture.issued.map(\.2) == ["Builder"])
        #expect(fixture.revoked.map(\.0) == ["woven:bot:d3vice-0001:b1"] && fixture.revoked.map(\.1) == [false])
        #expect(fixture.recorded.first?.2.entries.count == 2)
    }

    @Test func otherMembersReachTheRuntimeOnlyThroughItsOwnBearer() async throws {
        let fixture = try HostFixture(); defer { fixture.remove() }
        let upgrade = CompanionHTTPRequest(method: "GET", target: "/v1/bots/ws", headers: [
            "host": "mac.tail.ts.net", "upgrade": "websocket", "connection": "Upgrade",
            "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==", "sec-websocket-version": "13", "authorization": "Bearer member-grant",
        ])
        guard case .reject(let stopped) = fixture.host.remoteUpgrade(upgrade) else { Issue.record("tunnelled while off"); return }
        #expect(stopped.status == 503)
        _ = try await fixture.host.perform(.setEnabled(true))
        try await waitFor("runtime") { fixture.supervisor.phase == .running }
        guard case let .tunnel(port, head) = fixture.host.remoteUpgrade(upgrade) else { Issue.record("no tunnel"); return }
        let text = String(decoding: head, as: UTF8.self)
        #expect(Int(port) == fixture.host.persisted.runtimePort)
        #expect(text.hasPrefix("GET /ws HTTP/1.1\r\n"))
        #expect(text.contains("Authorization: Bearer " + fixture.host.persisted.runtimeToken))
        #expect(!text.contains("member-grant"))
        let status = await fixture.host.remoteRequest(try hostRequest("GET", "/v1/bots/status", token: "ignored"), path: "/v1/bots/status")
        let decoded = try JSONDecoder().decode(BotsRemoteStatus.self, from: status.body)
        #expect(decoded.machine.kind == "mac" && decoded.enabled && decoded.state == "ready")
    }

    @Test func theCompanionParserAcceptsAWebSocketUpgradeOnlyWhenAsked() throws {
        let raw = Data("GET /v1/bots/ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: k\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
        var plain = CompanionHTTPParser()
        #expect(throws: (any Error).self) { _ = try plain.append(raw) }
        var upgrading = CompanionHTTPParser(allowsUpgrade: true)
        #expect(try upgrading.append(raw)?.headers["upgrade"] == "websocket")
        var post = CompanionHTTPParser(allowsUpgrade: true)
        #expect(throws: (any Error).self) {
            _ = try post.append(Data("POST /v1/bots/ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nContent-Type: application/json\r\n\r\n".utf8))
        }
    }

    @Test func botConversationsAreLibraryRecordsThatSyncAndNeverDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bot-conversations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let report = BotConversationReport(botName: "Builder", conversationId: 5, mainConversationId: 5, title: "Main", entries: [
            .init(id: 1, role: "user", text: "hi"), .init(id: 2, role: "assistant", text: "hel"),
        ])
        #expect(try await database.recordBotConversation(machineID: "M1", botID: "B1", report) == 2)
        var finished = report; finished.entries = [.init(id: 2, role: "assistant", text: "hello")]
        #expect(try await database.recordBotConversation(machineID: "M1", botID: "B1", finished) == 0)
        let thread = BotConversationReport(botName: "Builder", conversationId: 9, mainConversationId: 5, title: "Side", entries: [
            .init(id: 3, role: "user", text: "thread"),
        ])
        #expect(try await database.recordBotConversation(machineID: "M1", botID: "B1", thread) == 1)
        let conversations = try await database.botConversations()
        #expect(conversations.map(\.conversationID) == [5, 9])
        #expect(conversations.first?.machineID == "m1" && conversations.first?.botName == "Builder")
        let entries = try await database.botConversationEntries(id: try #require(conversations.first?.id))
        #expect(entries.map(\.text) == ["hi", "hello"])
        // Regular chats never see bot conversations.
        #expect(try await database.workspaceOverview().conversations.isEmpty)
        #expect(PairedLibraryTables.names.contains("bot_conversations") && PairedLibraryTables.names.contains("bot_conversation_entries"))
        await #expect(throws: (any Error).self) {
            _ = try await database.recordBotConversation(machineID: "M1", botID: "B1", .init(botName: "x", conversationId: 1, entries: [.init(id: 1, role: "root", text: "x")]))
        }
        try await database.deleteBotConversations(machineID: "M1", botID: "B1")
        #expect(try await database.botConversations().isEmpty)
    }
}

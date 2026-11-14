import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

@MainActor
private final class FakeEngine: BotEngineHost {
    var ensured: [BotResourceSettings] = []
    var applied: [BotResourceSettings] = []
    var forwards: [String] = []
    var stopped = 0
    var updates = 0
    var updateError: String?
    var onStatusChange: (@MainActor (BotEngineStatus) -> Void)?
    let socket: String
    init(socket: String) { self.socket = socket }
    func update() async throws {
        updates += 1
        onStatusChange?(.init(state: .updating, socketPath: socket, message: "Updating the bots VM…"))
        if let updateError { throw BotsError.unavailable(updateError) }
    }
    func ensureRunning(resources: BotResourceSettings) async throws -> BotEngineStatus {
        ensured.append(resources)
        return .init(state: .running, socketPath: socket)
    }
    func status() async -> BotEngineStatus { .init(state: stopped > 0 ? .stopped : .running, socketPath: socket) }
    func apply(resources: BotResourceSettings) async throws { applied.append(resources) }
    func diskUsedByBots() async -> Int64? { 2 * BotResourceSettings.gib }
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
    var recorded: [(String, BotConversationMirror)] = []
    var deleted: [String] = []
    let host: BotsHostController
    let supervisor: BotsRuntimeSupervisor

    init(configure: (inout BotsHostDependencies) -> Void = { _ in }) throws {
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
        var recorded: [(String, BotConversationMirror)] = []
        var deleted: [String] = []
        let gib = BotResourceSettings.gib
        var dependencies = BotsHostDependencies(
            identity: { ("D3VICE-0001", "Fixture Mac") }, appVersion: "1.4.0",
            issueKey: { machine, bot, name in issued.append((machine, bot, name)); return .init(endpointURL: "http://127.0.0.1:1/mcp", bearerToken: "bot-key") },
            revokeKey: { caller, sticky in revoked.append((caller, sticky)) },
            reinstate: { _ in }, setPaused: { _, _ in }, callers: { [] }, botMCP: { nil },
            recordConversation: { machine, batch in recorded.append((machine, batch)) },
            deleteConversations: { _, bot in deleted.append(bot) },
            inferenceCredential: { provider in
                switch provider {
                case "openai": .init(credential: .apiKey("fixture-key"))
                case "web-search": .init(credential: .apiKey("search-key"), searchProvider: "brave")
                case "openai-codex": .init(credential: .oauth(access: "access", expires: 1_900_000_000_000, accountId: nil))
                default: .init()
                }
            },
            capacity: { _ in BotMachineCapacity(memoryBytes: 16 * gib, diskTotalBytes: 500 * gib, diskFreeBytes: 200 * gib) })
        configure(&dependencies)
        host = BotsHostController(directory: state, engine: engine, bundle: bundle, dependencies: dependencies, supervisor: supervisor)
        // Closures above write through these boxes; mirror them after each step.
        self.launches = launches; self.issued = issued; self.revoked = revoked; self.recorded = recorded
        sync = { [unowned self] in
            self.launches = launches; self.issued = issued; self.revoked = revoked; self.recorded = recorded; self.deleted = deleted
        }
    }
    var sync: () -> Void = {}

    func config() throws -> [String: Any] {
        let data = try Data(contentsOf: supervisor.configURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Holds a fake long command until the test lets it finish.
@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, any Error>?
    var waiting: Bool { continuation != nil }
    func wait() async throws { try await withCheckedThrowingContinuation { continuation = $0 } }
    func open(throwing error: (any Error)? = nil) {
        let pending = continuation; continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
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

private func hostRequest(_ method: String, _ path: String, token: String?, body: [String: Any]? = nil) throws -> LibraryHTTPRequest {
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
        #expect((config["image"] as? [String: Any])?["tag"] as? String == "wovenmatter-bots")
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

    @Test func botsMoveBetweenMachinesThroughOneCommand() async throws {
        var remote: [(String, Bool)] = []
        let fixture = try HostFixture { $0.setRemoteEnabled = { machine, enabled in remote.append((machine, enabled)) } }
        defer { fixture.remove() }
        // This Mac uses its own switch; any other machine goes over its signed route.
        _ = try await fixture.host.perform(.setMachineEnabled(machineID: "D3VICE-0001", true))
        try await waitFor("runtime") { fixture.supervisor.phase == .running }
        _ = try await fixture.host.perform(.setMachineEnabled(machineID: "linux-box", false))
        #expect(remote.map(\.0) == ["linux-box"] && remote.map(\.1) == [false])
        // Another member turns this Mac's bots off when they move elsewhere.
        let off = await fixture.host.remoteRequest(try hostRequest("POST", "/v1/bots/enabled", token: "ignored", body: ["enabled": false]),
                                                   path: "/v1/bots/enabled")
        #expect(off.status == 200)
        #expect(fixture.supervisor.phase == .stopped)
        #expect(await fixture.host.snapshot().machines.first?.state == .off)
    }

    @Test func aFailedMoveLeavesBotsOnTheMachineRunningThem() async throws {
        let bots = BotsModel()
        var result = BotsCommandResult()
        result.thisMachineID = "mac"
        result.machines = [BotMachine(id: "mac", name: "Mac", kind: .thisMac, state: .ready),
                           BotMachine(id: "box", name: "box", kind: .linux, state: .off)]
        var sent: [String] = []
        bots.perform = { command in
            if case let .setMachineEnabled(id, enabled) = command {
                sent.append("\(id):\(enabled)")
                if id == "box" { throw BotsError.unavailable("Install bots on this machine first.") }
            }
            return result
        }
        await bots.refresh()
        await bots.runBots(on: "box")
        #expect(sent == ["box:true"])
        #expect(bots.notice == "Install bots on this machine first.")
        // A move that works turns the target on, then the old machine off.
        sent = []
        bots.perform = { command in
            if case let .setMachineEnabled(id, enabled) = command { sent.append("\(id):\(enabled)") }
            return result
        }
        await bots.runBots(on: "box")
        #expect(sent == ["box:true", "mac:false"])
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
        func credential(_ provider: String) async throws -> [String: Any] {
            let reply = await api.handle(try hostRequest("POST", "/v1/bots-host/inference-credentials", token: token, body: ["provider": provider]))
            #expect(reply.status == 200)
            return try #require(try JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
        }
        #expect(try await credential("openai")["credential"] as? [String: String] == ["type": "api_key", "key": "fixture-key"])
        let search = try await credential("web-search")
        #expect(search["searchProvider"] as? String == "brave")
        let oauth = try #require(try await credential("openai-codex")["credential"] as? [String: Any])
        #expect(oauth["type"] as? String == "oauth" && oauth["refresh"] == nil && oauth["expires"] as? Double == 1_900_000_000_000)
        // Not connected is a reply, not an error.
        let missing = try await credential("xai")
        #expect(missing.keys.contains("credential") && missing["credential"] is NSNull)
        #expect(await api.handle(try hostRequest("POST", "/v1/bots-host/inference-credentials", token: token, body: ["provider": "unknown"])).status == 400)
        let batch: [String: Any] = [
            "bot": ["id": "b1", "name": "Builder"],
            "conversations": [["conversationId": 7, "kind": "main"]],
            "entries": [["id": 1, "conversationId": 7, "role": "user", "text": "hi", "createdAt": "2026-11-09T00:00:00Z"]],
        ]
        #expect(await api.handle(try hostRequest("POST", "/v1/bots-host/conversations/b1/entries", token: token, body: batch)).status == 200)
        #expect(await api.handle(try hostRequest("POST", "/v1/bots-host/conversations/other/entries", token: token, body: batch)).status == 400)
        #expect(await api.handle(try hostRequest("POST", "/v1/bots-host/previews", token: token, body: ["botID": "b1", "port": 80, "containerPort": 3000])).status == 400)
        #expect(await api.handle(try hostRequest("GET", "/v1/bots-host/unknown", token: token)).status == 404)
        fixture.sync()
        #expect(fixture.issued.map(\.0) == ["d3vice-0001"] && fixture.issued.map(\.2) == ["Builder"])
        #expect(fixture.revoked.map(\.0) == ["woven:bot:d3vice-0001:b1"] && fixture.revoked.map(\.1) == [false])
        #expect(fixture.deleted == ["b1"])
        #expect(fixture.recorded.first?.0 == "d3vice-0001" && fixture.recorded.first?.1.entries.count == 1)
    }

    @Test func otherMembersReachTheRuntimeOnlyThroughItsOwnBearer() async throws {
        let fixture = try HostFixture(); defer { fixture.remove() }
        let upgrade = LibraryHTTPRequest(method: "GET", target: "/v1/bots/ws", headers: [
            "host": "mac.tail.ts.net", "upgrade": "websocket", "connection": "Upgrade",
            "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==", "sec-websocket-version": "13", "authorization": "Bearer member-grant",
        ])
        guard case .reject(let stopped) = fixture.host.remoteUpgrade(upgrade) else { Issue.record("tunnelled while off"); return }
        #expect(stopped.status == 503)
        _ = try await fixture.host.perform(.setEnabled(true))
        try await waitFor("runtime") { fixture.supervisor.phase == .running }
        guard case let .tunnel(port, head, _) = fixture.host.remoteUpgrade(upgrade) else { Issue.record("no tunnel"); return }
        let text = String(decoding: head, as: UTF8.self)
        #expect(Int(port) == fixture.host.persisted.runtimePort)
        #expect(text.hasPrefix("GET /ws HTTP/1.1\r\n"))
        #expect(text.contains("Authorization: Bearer " + fixture.host.persisted.runtimeToken))
        #expect(!text.contains("member-grant"))
        let status = await fixture.host.remoteRequest(try hostRequest("GET", "/v1/bots/status", token: "ignored"), path: "/v1/bots/status")
        let decoded = try JSONDecoder().decode(BotsRemoteStatus.self, from: status.body)
        #expect(decoded.machine.kind == "mac" && decoded.enabled && decoded.state == "ready")
    }

    @Test func theEnginesProgressAndItsUpdateShowOnThisMac() async throws {
        let fixture = try HostFixture(); defer { fixture.remove() }
        _ = try await fixture.host.perform(.setEnabled(true))
        try await waitFor("runtime") { fixture.supervisor.phase == .running }
        // A note from a running engine reaches the machine row.
        fixture.engine.onStatusChange?(.init(state: .running, socketPath: fixture.engine.socket, message: "The new RAM pool applies later."))
        #expect(await fixture.host.snapshot().machines.first?.message == "The new RAM pool applies later.")

        _ = try await fixture.host.perform(.updateEngine(machineID: "D3VICE-0001"))
        try await waitFor("engine update") { fixture.host.engineUpdateTask == nil }
        #expect(fixture.engine.updates == 1)
        #expect(await fixture.host.snapshot().machines.first?.engineUpdateFailure == nil)

        fixture.engine.updateError = "The bots VM update failed and was rolled back: Docker did not start."
        let remote = await fixture.host.remoteRequest(try hostRequest("POST", "/v1/bots/engine/update", token: "ignored"), path: "/v1/bots/engine/update")
        #expect(remote.status == 200)
        try await waitFor("engine update") { fixture.host.engineUpdateTask == nil }
        let status = await fixture.host.remoteRequest(try hostRequest("GET", "/v1/bots/status", token: "ignored"), path: "/v1/bots/status")
        let decoded = try JSONDecoder().decode(BotsRemoteStatus.self, from: status.body)
        #expect(decoded.updating == false && decoded.engineUpdateFailure?.contains("rolled back") == true)

        _ = try await fixture.host.perform(.setEnabled(false))
        await #expect(throws: (any Error).self) { _ = try await fixture.host.perform(.updateEngine(machineID: "d3vice-0001")) }
    }

    /// Installing bots takes minutes, far longer than one window round trip: the command
    /// answers at once, and progress and the outcome reach the window in snapshots.
    @Test func installingBotsOnLinuxRunsAsAJobWhoseProgressAndFailureStayVisible() async throws {
        let gate = Gate()
        var reports: [@MainActor (String) -> Void] = []
        var discovered = [BotDiscoveredDevice(hostName: "box", displayName: "Box", dnsName: "box.example.ts.net", system: .linux, state: .installBots)]
        var changes = 0
        let fixture = try HostFixture { dependencies in
            dependencies.discover = { discovered }
            dependencies.installBots = { host, user, progress in
                #expect(host == "box" && user == "trey")
                reports.append(progress)
                progress("Installing agent dependencies…")
                try await gate.wait()
            }
        }
        defer { fixture.remove() }
        fixture.host.onChange = { changes += 1 }
        _ = try await fixture.host.perform(.discoverDevices)

        let started = try await fixture.host.perform(.installBots(hostName: "box", userName: "trey"))
        #expect(started.jobs.count == 1 && started.jobs.first?.running == true)
        try await waitFor("progress") { reports.count == 1 && gate.waiting }
        var snapshot = try await fixture.host.perform(.status)
        #expect(snapshot.devices?.first?.state == .installing("Installing agent dependencies…"))
        #expect(snapshot.jobs.first?.progress == "Installing agent dependencies…")
        #expect(changes >= 2, "every step refreshes the windows")
        await #expect(throws: (any Error).self) { _ = try await fixture.host.perform(.installBots(hostName: "box", userName: "trey")) }

        // A failure is kept with the device, and progress is cleared.
        gate.open(throwing: BotsError.unavailable("npm ci failed on box."))
        try await waitFor("failure") { fixture.host.jobTasks.isEmpty }
        snapshot = try await fixture.host.perform(.status)
        #expect(snapshot.devices?.first?.state == .failed("npm ci failed on box."))
        #expect(snapshot.jobs == [BotsJob(kind: .installBots, target: "box", running: false, progress: nil, error: "npm ci failed on box.")])

        // A retry that succeeds shows the device as discovery now finds it.
        discovered[0].state = .ready
        _ = try await fixture.host.perform(.installBots(hostName: "box", userName: "trey"))
        try await waitFor("retry") { reports.count == 2 && gate.waiting }
        gate.open()
        try await waitFor("success") { fixture.host.jobTasks.isEmpty }
        snapshot = try await fixture.host.perform(.status)
        #expect(snapshot.devices?.first?.state == .ready)
        #expect(snapshot.jobs.first?.running == false && snapshot.jobs.first?.error == nil)
        _ = try await fixture.host.perform(.discoverDevices)
        #expect(try await fixture.host.perform(.status).jobs.isEmpty, "a fresh look clears finished installs")
    }

    @Test func aLinuxHostUpdateRunsAsAJobUntilItFinishes() async throws {
        let gate = Gate()
        var updated: [String] = []
        let fixture = try HostFixture { dependencies in
            dependencies.updateLinuxHost = { machine, progress in
                updated.append(machine)
                progress("Uploading the host service…")
                try await gate.wait()
            }
        }
        defer { fixture.remove() }
        let started = try await fixture.host.perform(.updateLinuxHost(machineID: "LINUX-1"))
        #expect(started.jobs.first?.kind == .updateLinuxHost && started.jobs.first?.target == "linux-1" && started.jobs.first?.running == true)
        try await waitFor("update") { updated == ["LINUX-1"] && gate.waiting }
        #expect(try await fixture.host.perform(.status).jobs.first?.progress == "Uploading the host service…")
        gate.open(throwing: BotsError.unavailable("The host update failed and was rolled back."))
        try await waitFor("update end") { fixture.host.jobTasks.isEmpty }
        #expect(try await fixture.host.perform(.status).jobs.first?.error == "The host update failed and was rolled back.")
    }

    @Test func anotherMachinesHarnessesAreReadDirectlyAndUpdatedAsAJob() async throws {
        let gate = Gate()
        var updates: [(String, AgentRuntimeKind, String?, Bool)] = []
        let inventory = FleetMemberInventory(runtimes: [RemoteRuntimeMaintenance(
            id: .codex, displayName: "Codex", installed: true,
            components: [RemoteRuntimeComponent(id: "runtime", displayName: "codex-acp", path: nil, installedVersion: "1.0.0",
                                                latestVersion: "1.1.0", required: true, installed: true)],
            updateAvailable: true)])
        let fixture = try HostFixture { dependencies in
            dependencies.memberInventory = { machine, check in
                #expect(machine == "MAC-2" && check)
                return inventory
            }
            dependencies.memberInstallerPreview = { _, _ in nil }
            dependencies.updateMemberHarness = { machine, kind, sha, _, force, progress in
                updates.append((machine, kind, sha, force))
                progress("Updating Codex…")
                try await gate.wait()
            }
        }
        defer { fixture.remove() }
        // A read answers with the inventory alone, without a machine list to apply.
        let read = try await fixture.host.perform(.memberInventory(machineID: "MAC-2", checkLatest: true))
        #expect(read.memberInventory == inventory && read.machines.isEmpty)
        #expect(try await fixture.host.perform(.memberInstallerPreview(machineID: "MAC-2", kind: .codex)).installerPreview == nil)
        let started = try await fixture.host.perform(.updateMemberHarness(machineID: "MAC-2", kind: .codex, sourceSHA256: "abc",
                                                                         packageSpec: nil, force: true))
        #expect(started.jobs.first?.kind == .updateHarness && started.jobs.first?.target == "mac-2/codex")
        try await waitFor("harness update") { updates.count == 1 && gate.waiting }
        #expect(updates.first?.0 == "MAC-2" && updates.first?.2 == "abc" && updates.first?.3 == true)
        gate.open(throwing: FleetBusyError())
        try await waitFor("harness update end") { fixture.host.jobTasks.isEmpty }
        #expect(try await fixture.host.perform(.status).jobs.first?.error == FleetBusyError.message)
    }

    @Test func installJobsReplaceTheirDevicesStateAndAppearBeforeDiscoveryFindsThem() {
        let devices = [BotDiscoveredDevice(hostName: "Box", displayName: "Box", dnsName: nil, system: .linux, state: .installBots),
                       BotDiscoveredDevice(hostName: "mini", displayName: "Mini", dnsName: nil, system: .macOS, state: .installApp)]
        let jobs = [BotsJob(kind: .installBots, target: "box", running: true, progress: "Preparing box…"),
                    BotsJob(kind: .installBots, target: "other", running: false, error: "Bots require Linux."),
                    BotsJob(kind: .installBots, target: "mini", running: false),
                    BotsJob(kind: .updateLinuxHost, target: "box", running: true)]
        let shown = BotsHostController.devices(devices, showing: jobs)
        #expect(shown?.map(\.state) == [.installing("Preparing box…"), .installApp, .failed("Bots require Linux.")])
        #expect(shown?.last?.hostName == "other" && shown?.last?.system == .linux)
        #expect(BotsHostController.devices(nil, showing: []) == nil)
    }

    @Test func theLibraryParserAcceptsAWebSocketUpgradeOnlyWhenAsked() throws {
        let raw = Data("GET /v1/bots/ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: k\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
        var plain = LibraryHTTPParser()
        #expect(throws: (any Error).self) { _ = try plain.append(raw) }
        var upgrading = LibraryHTTPParser(allowsUpgrade: true)
        #expect(try upgrading.append(raw)?.headers["upgrade"] == "websocket")
        var post = LibraryHTTPParser(allowsUpgrade: true)
        #expect(throws: (any Error).self) {
            _ = try post.append(Data("POST /v1/bots/ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nContent-Type: application/json\r\n\r\n".utf8))
        }
    }

    @Test func botConversationsAreLibraryRecordsThatSyncAndNeverDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "bot-conversations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
        let stamp = "2026-11-09T00:00:00Z"
        let main = BotConversationMirror.Conversation(conversationId: 5, kind: "main", title: "Main")
        var batch = BotConversationMirror(bot: .init(id: "B1", name: "Builder"), conversations: [main], entries: [
            .init(id: 1, conversationId: 5, role: "user", text: "hi", createdAt: stamp),
            .init(id: 2, conversationId: 5, role: "assistant", text: "hel", createdAt: stamp),
        ])
        #expect(try await database.recordBotConversation(machineID: "M1", batch) == 2)
        batch.entries = [.init(id: 2, conversationId: 5, role: "assistant", text: "hello", stopped: true, createdAt: stamp)]
        #expect(try await database.recordBotConversation(machineID: "M1", batch) == 0)
        let thread = BotConversationMirror.Conversation(conversationId: 9, kind: "thread", parentConversationId: 5, forkedAt: 2, title: "Side", pinned: true)
        // A metadata-only batch: a new thread and a renamed main channel.
        var renamed = main; renamed.title = "Renamed"
        #expect(try await database.recordBotConversation(machineID: "M1", .init(bot: .init(id: "B1", name: "Builder"), conversations: [renamed, thread], entries: [])) == 0)
        let conversations = try await database.botConversations()
        #expect(conversations.map(\.conversationID) == [5, 9])
        #expect(conversations.first?.machineID == "m1" && conversations.first?.title == "Renamed")
        #expect(conversations.last?.kind == "thread" && conversations.last?.parentConversationID == 5 && conversations.last?.pinned == true)
        let entries = try await database.botConversationEntries(id: try #require(conversations.first?.id))
        #expect(entries.map(\.text) == ["hi", "hello"] && entries.last?.stopped == true)
        // Regular chats never see bot conversations.
        #expect(try await database.workspaceOverview().conversations.isEmpty)
        #expect(PairedLibraryTables.names.contains("bot_conversations") && PairedLibraryTables.names.contains("bot_conversation_entries"))
        await #expect(throws: (any Error).self) {
            _ = try await database.recordBotConversation(machineID: "M1", .init(bot: .init(id: "B1", name: "x"), conversations: [main],
                entries: [.init(id: 3, conversationId: 5, role: "system", text: "x", createdAt: stamp)]))
        }
        await #expect(throws: (any Error).self) {
            _ = try await database.recordBotConversation(machineID: "M1", .init(bot: .init(id: "B1", name: "x"), conversations: [main],
                entries: [.init(id: 3, conversationId: 77, role: "user", text: "x", createdAt: stamp)]))
        }
        try await database.deleteBotConversations(machineID: "M1", botID: "B1")
        #expect(try await database.botConversations().isEmpty)
    }
}

@MainActor
struct BundledComponentsTests {
    @Test func versionsReadAsPeopleSeeThem() {
        #expect(BundledComponents.debianVersion("5:29.9.3-1~ubuntu.26.04~resolute") == "29.9.3")
        #expect(BundledComponents.debianVersion("2.4.2-4~ubuntu.26.04~resolute") == "2.4.2")
        #expect(BundledComponents.trimmed("156.0.30.0") == "156.0.30")
        #expect(BundledComponents.trimmed("2.10.1") == "2.10.1")
        #expect(ExecutorVersions(installed: "2.3.0", latest: "2.4.1").updateAvailable)
        #expect(!ExecutorVersions(installed: "2.4.1", latest: "2.4.1").updateAvailable)
        #expect(!ExecutorVersions(installed: nil, latest: "2.4.1").updateAvailable)
    }

    @Test func imageToolsReadAsOneLine() {
        let image = PiBotImageStatus(tag: "wovenmatter-bots:abc", base: "ubuntu:26.04", node: "26.13.1", playwright: "1.65.1", staleBots: 2)
        #expect(image.tools == "Ubuntu 26.04 · Node 26.13.1 · Playwright 1.65.1 with Chromium")
        let decoded = try? JSONDecoder().decode(PiBotRuntimeStatus.self, from: Data(
            #"{"version":"0.1.0","environment":"mac-vm","bots":3,"image":{"tag":"t","node":"26.13.1","playwright":"1.65.1","staleBots":1}}"#.utf8))
        #expect(decoded?.image?.staleBots == 1 && decoded?.image?.base == nil)
        // A runtime from before image reporting still decodes.
        #expect((try? JSONDecoder().decode(PiBotRuntimeStatus.self, from: Data(#"{"version":"0.1.0"}"#.utf8)))?.image == nil)
    }
}

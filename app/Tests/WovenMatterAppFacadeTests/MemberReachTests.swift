import CompanionClient
import CryptoKit
import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

/// Everything reaches everything: a Mac reaches another Mac's workspace and
/// any Linux host with signed member requests, with nothing provisioned, and
/// manages a Linux host another Mac added. All traffic stays in process.
@MainActor @Suite(.serialized)
struct MemberReachTests {
    @Test func macCreatesASessionOnAnotherMacWithItsSignatureAlone() async throws {
        let macB = try await FacadeFixture(); defer { macB.remove() }
        let macA = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
        let bDevice = try await macB.database.companionLibraryIdentity().hostDeviceID
        let directory = MemberDirectory(database: macB.database, identity: MemberIdentity(deviceID: bDevice, kind: .mac, key: .init()), cacheLifetime: 0)
        try await directory.ensureSelf(name: "Mac B", endpoints: [])
        let descriptor = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: try await macB.database.companionLibraryIdentity().libraryID,
            ownerDeviceID: bDevice, kind: .mac, name: "Mac B", endpoint: URL(string: "https://mac-b.fixture.ts.net:8443/wovenmatter")!,
            capabilities: ["execution.v1", "history.central.v1"], executionDeviceID: bDevice)
        let commands = ReachMacCommands()
        let api = CompanionMacExecutionAPI(database: macB.database, commands: commands,
            authentication: try CompanionExecutionAuthentication(fileURL: macB.directory.appending(path: "execution-grants.json")),
            descriptor: descriptor, isActive: { true }, members: directory)
        let send = Self.route { request in await api.handle(request) }
        let transport = try SignedExecutionWorkspaceTransport(workspace: descriptor, signer: macA.signer, send: send)

        // Not a member yet: refused, with nothing issued.
        await #expect(throws: MobileConnectionError.self) { _ = try await transport.identity() }
        try await directory.add(deviceID: macA.deviceID, kind: .mac, name: "Mac A", publicKey: macA.publicKey, endpoints: [])
        #expect(try await transport.identity().id == descriptor.id)
        let providers = try await transport.providers()
        #expect(providers.map(\.id) == ["local:default_agent"])
        let id = UUID().uuidString.lowercased()
        let receipt = try await transport.command(.init(commandID: id, deviceID: macA.deviceID, kind: .createSession, conversationID: id,
            providerID: "local:default_agent", runtimeKind: "default_agent", libraryID: descriptor.libraryID, workspaceID: descriptor.id))
        #expect(receipt.status == .completed)
        #expect(commands.executed.map(\.kind) == [.createSession])
        #expect(commands.devices == [macA.deviceID])

        // A Linux member signs too: a Linux host starts sessions on this Mac with every other Mac offline.
        let linux = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
        try await directory.add(deviceID: linux.deviceID, kind: .linux, name: "Linux", publicKey: linux.publicKey, endpoints: [])
        let fromLinux = try SignedExecutionWorkspaceTransport(workspace: descriptor, signer: linux.signer, send: send)
        #expect(try await fromLinux.providers().count == 1)

        // A request addressed to another member (as one captured on its way to
        // Mac C would be) is refused here, although its nonce is new to Mac B.
        var elsewhere = descriptor; elsewhere.executionDeviceID = UUID().uuidString.lowercased()
        let misaddressed = try SignedExecutionWorkspaceTransport(workspace: elsewhere, signer: macA.signer, send: send)
        await #expect(throws: MobileConnectionError.self) { _ = try await misaddressed.providers() }
        // Without the destination's member device ID nothing is signed at all.
        var unknown = descriptor; unknown.executionDeviceID = nil
        #expect(throws: MemberRequestError.audienceUnknown) { _ = try SignedExecutionWorkspaceTransport(workspace: unknown, signer: macA.signer, send: send) }
    }

    @Test func agentToolsCreateSessionsOnLinuxHostsByIDAndRejectLocal() async throws {
        let macA = try await FacadeFixture(); defer { macA.remove() }
        let identity = try await macA.database.companionLibraryIdentity()
        let signer = MemberIdentity(deviceID: identity.hostDeviceID, kind: .mac, key: .init())
        let linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: identity.libraryID, members: [signer.deviceID: signer.publicKey])
        let workspace = try await macA.database.receiveSyncedWorkspace(linux.descriptor)
        macA.model.federatedExecutionClient = try CentralExecutionClient(database: macA.database,
            commandJournalURL: macA.directory.appending(path: "commands.json"),
            provision: { _ in throw CompanionAPIError(code: "unauthorized", message: "No grants in this test.") },
            loadCredential: { _ in nil }, saveCredential: { _ in },
            makeSignedTransport: { workspace in try SignedExecutionWorkspaceTransport(workspace: workspace, signer: signer.signer, send: linux.send) })

        #expect(try await macA.model.resolveAgentToolDestination(workspace.id, callerWorkspace: nil) == .member(workspace))
        do {
            _ = try await macA.model.resolveAgentToolDestination("local", callerWorkspace: nil)
            Issue.record("`local` must not be accepted as a destination.")
        } catch let error as WorkspaceToolError { #expect(error.localizedDescription.contains(workspace.id)) }

        let rows = try await macA.model.agentToolHarnessRows()
        #expect(rows.contains { $0.objectValue?["workspace"]?.stringValue == workspace.id && $0.objectValue?["harness"]?.stringValue == "codex" })
        #expect(!rows.contains { $0.objectValue?["workspace"]?.stringValue == "local" })

        let source = UUID().uuidString.lowercased(), request = UUID().uuidString.lowercased()
        let created = try await macA.model.createMemberToolSession(sourceID: source, requestID: request, workspace: workspace,
            runtime: .codex, title: "Build it", text: "Start here")
        #expect(created.success)
        #expect(created.result?.objectValue?["session"]?.objectValue?["workspace"]?.stringValue == workspace.id)
        #expect(linux.commands.map(\.kind) == [.createSession, .workspace, .send])
        #expect(linux.commands.last?.text == "Start here")
        #expect(linux.commands.allSatisfy { $0.deviceID == signer.deviceID })
        // A retry replays the destination's receipts instead of creating again.
        let replay = try await macA.model.createMemberToolSession(sourceID: source, requestID: request,
            workspace: workspace, runtime: .codex, title: "Build it", text: "Start here")
        #expect(replay.success)
        #expect(linux.commands.count == 3)
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await macA.model.createMemberToolSession(sourceID: source, requestID: UUID().uuidString.lowercased(),
                workspace: workspace, runtime: .claudeCode, title: "No", text: "Not ready")
        }
    }

    @Test func anotherMacManagesALinuxHostItDidNotAdd() async throws {
        let macB = try await FacadeFixture(); defer { macB.remove() }
        let identity = try await macB.database.companionLibraryIdentity()
        let host = CompanionHostController(model: macB.model, defaults: macB.defaults, supportDirectory: macB.directory, peerStorage: .memory())
        let signer = try await host.memberSigner()
        let macBKey = try await host.peerSync.members().identity.publicKey
        // Added on Mac A: its owner is another device, and Mac B has no SSH setup for it.
        let linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: UUID().uuidString.lowercased(), members: [signer.deviceID: macBKey])
        let workspace = try await macB.database.receiveSyncedWorkspace(linux.descriptor)
        host.remoteHostSend = linux.send
        macB.model.remoteWorkspaces.sharedHostAdministration = { _ in try await host.hostAdministration(for: workspace) }

        await macB.model.remoteWorkspaces.performSharedHost(workspace.id, .refresh)
        #expect(macB.model.remoteWorkspaces.sharedHosts[workspace.id]?.error == nil)
        #expect(macB.model.remoteWorkspaces.sharedHosts[workspace.id]?.serviceState == "running")
        await macB.model.remoteWorkspaces.performSharedHost(workspace.id, .logs)
        #expect(macB.model.remoteWorkspaces.sharedHosts[workspace.id]?.logs == "server started")
        await macB.model.remoteWorkspaces.performSharedHost(workspace.id, .restart)
        await macB.model.remoteWorkspaces.performSharedHost(workspace.id, .configureBots(poolBytes: 8 << 30, diskBytes: nil))
        #expect(linux.hostRequests == ["GET /v1/host/status", "GET /v1/host/logs?lines=500", "POST /v1/host/restart",
                                       "POST /v1/host/bots-configure", "GET /v1/host/status"])
        #expect(linux.botsBody == ["poolBytes": 8 << 30, "diskBytes": NSNull()] as NSDictionary)

        // Enrolling a phone asks the host itself, not the Mac that added it.
        let phone = UUID().uuidString.lowercased()
        let credential = try await host.provisionAtLinuxHost(workspace, deviceID: phone, name: "Phone")
        #expect(credential.deviceID == phone && credential.workspace.id == workspace.id)

        // A stranger's signature is refused.
        let stranger = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
        let refused = try RemoteHostAdministrationClient(endpoint: workspace.endpoint!, signer: stranger.signer,
                                                         audience: workspace.executionDeviceID!, send: linux.send)
        await #expect(throws: MemberSignedHTTPError.self) { _ = try await refused.status() }
    }

    /// A Linux host reaches a Mac's library-backed tools with its own member
    /// signature, only for the workspace it executes; no MCP grant exists.
    @Test func linuxMemberSignsWorkspaceMCPOnlyForItsOwnWorkspace() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let device = try await fixture.database.companionLibraryIdentity().hostDeviceID
        let mac = MemberDirectory(database: fixture.database, identity: MemberIdentity(deviceID: device, kind: .mac, key: .init()), cacheLifetime: 0)
        try await mac.ensureSelf(name: "Mac", endpoints: [])
        let linux = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
        let other = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
        for member in [linux, other] {
            try await mac.add(deviceID: member.deviceID, kind: .linux, name: "Linux", publicKey: member.publicKey, endpoints: [])
        }
        let workspace = try await fixture.database.receiveSyncedWorkspace(.init(id: UUID().uuidString.lowercased(), libraryID: UUID().uuidString.lowercased(),
            ownerDeviceID: UUID().uuidString.lowercased(), kind: .linux, name: "Linux L", executionDeviceID: linux.deviceID))
        let api = CompanionWorkspaceAPI(database: fixture.database,
            authentication: try CompanionAuthentication(fileURL: fixture.directory.appending(path: "mcp-devices.json")),
            commands: fixture.model.companionCommands, isActive: { true }, members: mac)
        let message = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        func call(_ signer: MemberIdentity) async throws -> (Int, String?) {
            var headers = try signer.signer.headers(method: "POST", target: "/wovenmatter/mcp/workspace", body: message, audience: device)
            headers["X-Woven-Protocol"] = String(CompanionProtocol.version)
            headers["X-Woven-Workspace-ID"] = workspace.id
            headers["X-Woven-Conversation-ID"] = UUID().uuidString.lowercased()
            headers["X-Woven-Enabled-Groups"] = "timers"
            let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
            let response = await api.handle(.init(method: "POST", target: "/wovenmatter/mcp/workspace", headers: lowered, body: message))
            return (response.status, (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["message"] as? String)
        }
        // The executing member is authenticated; its unknown conversation is then refused by ownership.
        let own = try await call(linux)
        #expect(own.1?.contains("execution workspace's conversations") == true, "\(own)")
        let wrong = try await call(other)
        #expect(wrong.1?.contains("does not execute") == true, "\(wrong)")
        let stranger = try await call(MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init()))
        #expect(stranger.0 == 401)
    }

    @Test func updateRequiredPeersRaiseTheUpdateEverythingNotice() {
        let status = LibrarySyncStatus(deviceID: "a", version: "1", schema: "2", peers: [
            .init(deviceID: "b", name: "Mini", kind: .mac, state: .updateRequired, version: "0.9"),
            .init(deviceID: "c", name: "Box", kind: .linux, state: .online)
        ], conflicts: 0, quarantined: 0)
        let notices = ApplicationModel.libraryUpdateNotices(status)
        #expect(notices.count == 1)
        #expect(BotVersionReport(thisMacVersion: "1", machines: [], syncErrors: notices).needsUpdate)
    }

    /// Carries a signed `URLRequest` to an in-process handler exactly as the
    /// server would receive it: path with query, lowercased header names.
    static func route(_ handle: @escaping @MainActor @Sendable (CompanionHTTPRequest) async -> CompanionHTTPResponse) -> MemberSignedHTTPClient.Send {
        { request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let target = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            let headers = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
            let response = await handle(.init(method: request.httpMethod ?? "GET", target: target, headers: headers, body: request.httpBody ?? Data()))
            return (response.body, HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }
}

@MainActor private final class ReachMacCommands: CompanionCommandServing {
    var executed: [CompanionCommand] = []
    var devices: [String] = []
    func providers() -> [CompanionProvider] { [.init(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)] }
    func pendingInteractions() async -> [CompanionPendingInteraction] { [] }
    func sessionCapabilities(conversationID: String) async throws -> CompanionProvider { providers()[0] }
    func transcript(conversationID: String, before: String?) async throws -> CompanionTranscript { .init(conversationID: conversationID) }
    func receipt(commandID: String, deviceID: String) async throws -> CompanionCommandReceipt? { nil }
    func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt {
        executed.append(command); devices.append(deviceID)
        return .init(commandID: command.commandID, deviceID: deviceID, status: .completed, conversationID: command.conversationID)
    }
}

/// A Linux host's Node server as a Mac sees it through Tailscale Serve: it
/// verifies every member signature over the path with its `/wovenmatter-execution/<id>`
/// prefix restored, then routes the stripped path.
private final class ReachLinuxHost: @unchecked Sendable {
    let prefix: String
    let descriptor: CompanionExecutionWorkspace
    private let verifier: MemberRequestVerifier
    private let lock = NSLock()
    private var _commands: [CompanionCommand] = [], _receipts: [String: CompanionCommandReceipt] = [:]
    private var _hostRequests: [String] = [], _botsBody: NSDictionary?
    var commands: [CompanionCommand] { lock.withLock { _commands } }
    var created: [CompanionCommand] { commands.filter { $0.kind == .createSession } }
    var hostRequests: [String] { lock.withLock { _hostRequests } }
    var botsBody: NSDictionary? { lock.withLock { _botsBody } }

    init(prefix: String, workspaceID: String, libraryID: String, members: [String: Data]) {
        self.prefix = prefix
        let host = UUID().uuidString.lowercased()
        descriptor = .init(id: workspaceID, libraryID: libraryID, ownerDeviceID: UUID().uuidString.lowercased(), kind: .linux, name: "Linux L",
            endpoint: URL(string: "https://linux-l.fixture.ts.net" + prefix)!, capabilities: ["execution", "historyReplay"],
            executionDeviceID: host)
        // Like the Node server, it accepts only requests addressed to its own member device ID.
        verifier = MemberRequestVerifier(audience: host, lookup: { id in members[id].map { MemberKey(deviceID: id, kind: .mac, name: "Member", publicKey: $0) } })
    }

    var send: MemberSignedHTTPClient.Send {
        { [self] request in
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let target = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            let headers = Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })
            let body = request.httpBody ?? Data()
            func reply(_ status: Int, _ value: Any) throws -> (Data, HTTPURLResponse) {
                (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { _ = try await verifier.verify(method: request.httpMethod ?? "GET", target: target, headers: headers, body: body, allowing: [.mac]) }
            catch { return try reply(401, ["error": "unauthorized"]) }
            guard target.hasPrefix(prefix + "/") else { return try reply(404, ["error": "not_found"]) }
            let path = String(target.dropFirst(prefix.count)), method = request.httpMethod ?? "GET"
            if path.hasPrefix("/v1/host/") { lock.withLock { _hostRequests.append(method + " " + path) } }
            switch (method, path.split(separator: "?").first.map(String.init) ?? path) {
            case ("GET", "/v1/execution"): return (try JSONEncoder().encode(descriptor), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", "/v1/execution/providers"):
                let providers = [CompanionProvider(id: "codex", runtimeKind: "codex", displayName: "Codex", routeName: "Linux L", available: true)]
                return (try JSONEncoder().encode(providers), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("POST", "/v1/execution/commands"):
                let command = try JSONDecoder().decode(CompanionCommand.self, from: body)
                let receipt = lock.withLock { () -> CompanionCommandReceipt in
                    if let saved = _receipts[command.commandID] { return saved }
                    _commands.append(command)
                    let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed,
                        conversationID: command.conversationID, libraryID: descriptor.libraryID, workspaceID: descriptor.id)
                    _receipts[command.commandID] = receipt
                    return receipt
                }
                return (try JSONEncoder().encode(receipt), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", let route) where route.hasPrefix("/v1/execution/commands/"):
                let id = String(route.dropFirst("/v1/execution/commands/".count))
                guard let saved = lock.withLock({ _receipts[id] }) else { return try reply(404, ["error": "not_found"]) }
                return (try JSONEncoder().encode(saved), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", "/v1/execution/interactions"): return try reply(200, [] as [Any])
            case ("GET", "/v1/execution/events"): return (try JSONEncoder().encode(CompanionJournalPage(libraryID: descriptor.libraryID, cursor: 0)), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", "/v1/host/status"): return try reply(200, ["state": "running", "roles": ["workspace": true]])
            case ("GET", "/v1/host/logs"): return try reply(200, ["logs": "server started"])
            case ("POST", "/v1/host/restart"): return try reply(202, ["restarting": true])
            case ("POST", "/v1/host/bots-configure"):
                lock.withLock { _botsBody = try? JSONSerialization.jsonObject(with: body) as? NSDictionary }
                return try reply(200, ["configured": true])
            case ("POST", "/v1/execution/devices"):
                struct Enrollment: Decodable { let deviceID: String }
                let enrollment = try JSONDecoder().decode(Enrollment.self, from: body)
                let credential = CompanionExecutionCredential(workspace: descriptor, deviceID: enrollment.deviceID, token: String(repeating: "t", count: 43))
                return (try JSONEncoder().encode(credential), HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!)
            default: return try reply(404, ["error": "not_found"])
            }
        }
    }
}

private extension WorkspaceDatabase {
    /// A registry row as peer sync delivers it from the Mac that added the host
    /// (another library, another owner), which local registration refuses.
    func receiveSyncedWorkspace(_ workspace: CompanionExecutionWorkspace) async throws -> CompanionExecutionWorkspace {
        var value = workspace; value.revision = 1
        let row = value
        try await write { db in
            let statement = try db.prepareUnlocked("INSERT INTO companion_execution_workspaces(id,owner_device_id,revision,deleted,payload) VALUES (?,?,?,0,?)")
            defer { sqlite3_finalize(statement) }
            try db.bind(row.id, at: 1, to: statement); try db.bind(row.ownerDeviceID, at: 2, to: statement)
            sqlite3_bind_int64(statement, 3, row.revision)
            try db.bind(JSONEncoder().encode(row), at: 4, to: statement); try db.stepDone(statement)
        }
        return value
    }
}

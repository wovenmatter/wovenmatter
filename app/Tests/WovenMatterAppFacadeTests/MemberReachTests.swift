import LibraryClient
import CryptoKit
import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore
@testable import WovenMatterAppFacade

/// Everything reaches everything: a Mac reaches another Mac's workspace and
/// any Linux host with signed member requests, with nothing provisioned, and
/// manages a Linux host another Mac added. All traffic stays in process.
@MainActor @Suite(.serialized)
struct MemberReachTests {
    @Test func macCreatesASessionOnAnotherMacWithItsSignatureAlone() async throws {
        let macB = try await FacadeFixture(); defer { macB.remove() }
        let macA = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
        let bDevice = try await macB.database.libraryIdentity().hostDeviceID
        let directory = MemberDirectory(database: macB.database, identity: MemberIdentity(deviceID: bDevice, kind: .mac, key: .init()), cacheLifetime: 0)
        try await directory.ensureSelf(name: "Mac B", endpoints: [])
        let descriptor = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: try await macB.database.libraryIdentity().libraryID,
            ownerDeviceID: bDevice, kind: .mac, name: "Mac B", endpoint: URL(string: "https://mac-b.fixture.ts.net:8443/wovenmatter")!,
            capabilities: ["execution.v1", "history.library.v1"], executionDeviceID: bDevice)
        let commands = ReachMacCommands()
        let api = MacExecutionAPI(database: macB.database, commands: commands, descriptor: descriptor, isActive: { true }, members: directory)
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
        let identity = try await macA.database.libraryIdentity()
        let signer = MemberIdentity(deviceID: identity.hostDeviceID, kind: .mac, key: .init())
        let linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: identity.libraryID, members: [signer.deviceID: signer.publicKey])
        let workspace = try await macA.database.receiveSyncedWorkspace(linux.descriptor)
        macA.model.federatedExecutionClient = try MemberExecutionClient(database: macA.database,
            commandJournalURL: macA.directory.appending(path: "commands.json"),
            makeSignedTransport: { workspace in try SignedExecutionWorkspaceTransport(workspace: workspace, signer: signer.signer, audience: linux.memberID, send: linux.send) })

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
        // The title names the session as it is created; the rename is for older destinations.
        #expect(linux.commands.first?.title == "Build it")
        #expect(linux.commands.dropFirst().allSatisfy { $0.title == nil })
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

    /// A Dev snapshot runs signed member sessions on the workspaces it knows
    /// live, and refuses only the owners it copied (`retainedHistory`): they are
    /// no agent destination, never signed for, and their chats read as saved history.
    @Test func aSnapshotReachesLiveMembersAndRefusesOnlyCopiedOwners() async throws {
        let macA = try await FacadeFixture(); defer { macA.remove() }
        macA.model.readsCopiedHistoryOnly = true
        let identity = try await macA.database.libraryIdentity()
        let signer = MemberIdentity(deviceID: identity.hostDeviceID, kind: .mac, key: .init())
        let linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: identity.libraryID, members: [signer.deviceID: signer.publicKey])
        let live = try await macA.database.receiveSyncedWorkspace(linux.descriptor)
        // As dev-build.py leaves a copied owner, here even with an address that answers.
        var row = linux.descriptor
        row.id = UUID().uuidString.lowercased(); row.ownerDeviceID = UUID().uuidString.lowercased()
        row.kind = .mac; row.name = "James's MacBook Air"; row.retainedHistory = true
        let copied = try await macA.database.receiveSyncedWorkspace(row)
        final class Signed { var ids: [String] = [] }; let signed = Signed()
        macA.model.federatedExecutionClient = try MemberExecutionClient(database: macA.database,
            commandJournalURL: macA.directory.appending(path: "commands.json"),
            makeSignedTransport: { workspace in
                signed.ids.append(workspace.id)
                return try SignedExecutionWorkspaceTransport(workspace: workspace, signer: signer.signer, audience: linux.memberID, send: linux.send)
            })

        let (_, others) = try await macA.model.agentToolWorkspaces()
        #expect(others.map(\.id) == [live.id])
        do {
            _ = try await macA.model.resolveAgentToolDestination(copied.id, callerWorkspace: nil)
            Issue.record("A copied owner must not be a destination.")
        } catch let error as WorkspaceToolError { #expect(error.localizedDescription.contains("copied history")) }
        let rows = try await macA.model.agentToolHarnessRows()
        #expect(!rows.contains { $0.objectValue?["workspace"]?.stringValue == copied.id })

        let created = try await macA.model.createMemberToolSession(sourceID: UUID().uuidString.lowercased(), requestID: UUID().uuidString.lowercased(),
            workspace: live, runtime: .codex, title: "Snapshot work", text: "Start here")
        #expect(created.success)
        #expect(linux.created.count == 1)

        let client = try macA.model.memberExecutionClient()
        await #expect(throws: LibraryAPIError.self) { _ = try await client.providers(workspace: copied) }
        #expect(!signed.ids.contains(copied.id))
        // A conversation with no live owner here is saved history, readable but not controllable.
        let history = try await macA.model.performFederatedExecution(.refresh(conversationID: UUID().uuidString.lowercased()))
        #expect(history.workspace.id == "snapshot-history" && !history.online)
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await macA.model.performFederatedExecution(.stop(conversationID: UUID().uuidString.lowercased(), runID: UUID().uuidString.lowercased()))
        }
    }

    /// An agent manages a session it created on a Linux host by ID alone, as on
    /// Linux: status (state, pending questions, recent transcript), send or steer,
    /// stop and respond are signed calls to that host, and retries replay.
    @Test func agentsManageTheSessionsTheyCreateOnAnotherWorkspace() async throws {
        let macA = try await FacadeFixture(); defer { macA.remove() }
        let identity = try await macA.database.libraryIdentity()
        let signer = MemberIdentity(deviceID: identity.hostDeviceID, kind: .mac, key: .init())
        let linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: identity.libraryID, members: [signer.deviceID: signer.publicKey])
        let workspace = try await macA.database.receiveSyncedWorkspace(linux.descriptor)
        macA.model.federatedExecutionClient = try MemberExecutionClient(database: macA.database,
            commandJournalURL: macA.directory.appending(path: "commands.json"),
            makeSignedTransport: { workspace in try SignedExecutionWorkspaceTransport(workspace: workspace, signer: signer.signer, audience: linux.memberID, send: linux.send) })
        let tools = try #require(macA.model.agentTools)
        let botID = UUID().uuidString.lowercased()
        _ = try await tools.issueBotKey(machineID: identity.hostDeviceID, botID: botID, botName: "Builder")
        let caller = WovenMCPCaller.bot(machineID: identity.hostDeviceID, botID: botID)
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> WovenMatterToolResponse {
            await tools.handle(try WovenMCPCatalog.request(name: name, arguments: .object(arguments)), callerID: caller)
        }

        let created = try await call("woven_sessions_create", ["title": .string("Build it"), "text": .string("Start here"),
            "purpose": .string("Fixture"), "harness": .string("codex"), "workspace": .string(workspace.id)])
        #expect(created.success, "\(created.error ?? "")")
        let id = try #require(created.result?.objectValue?["session"]?.objectValue?["id"]?.stringValue)
        #expect(try await macA.database.memberToolSession(id: id)?.workspaceID == workspace.id)

        // Status needs only the ID: state, the latest 20 messages (each clipped) and an older page.
        let status = try await call("woven_sessions_status", ["id": .string(id)])
        #expect(status.success, "\(status.error ?? "")")
        let session = status.result?.objectValue?["session"]?.objectValue
        #expect(session?["state"]?.stringValue == "idle" && session?["workspace"]?.stringValue == workspace.id && session?["workspaceKind"]?.stringValue == "linux")
        let page = try #require(status.result?.objectValue?["transcript"]?.objectValue)
        let messages = page["messages"]?.arrayValue ?? []
        #expect(messages.count == 20 && page["before"]?.stringValue == "cursor-1")
        #expect(messages.allSatisfy { ($0.objectValue?["content"]?.stringValue?.count ?? 0) <= 4_001 })
        let older = try await call("woven_sessions_status", ["id": .string(id), "before": .string("cursor-1")])
        #expect(older.result?.objectValue?["transcript"]?.objectValue?["messages"]?.arrayValue?.count == 1)

        // Running: a harness that cannot steer is refused; one that can is steered.
        linux.running = [id: "run-1"]
        let refused = try await call("woven_sessions_send", ["id": .string(id), "text": .string("More")])
        #expect(!refused.success && refused.error?.contains("mid-turn") == true)
        linux.canSteer = true
        let steered = try await call("woven_sessions_send", ["id": .string(id), "text": .string("More")])
        #expect(steered.success, "\(steered.error ?? "")")
        #expect(linux.commands.last?.kind == .steer && linux.commands.last?.runID == "run-1" && linux.commands.last?.text == "More")

        // A pending approval: status reports it; only an offered option is accepted.
        linux.pending = [.init(id: "approval-1", conversationID: id, runID: "run-1", kind: .approval, title: "Run tests?",
                               options: [.init(id: "allow", label: "Allow")])]
        let waiting = try await call("woven_sessions_status", ["id": .string(id)])
        #expect(waiting.result?.objectValue?["session"]?.objectValue?["state"]?.stringValue == "needsInput")
        #expect(waiting.result?.objectValue?["pending"]?.arrayValue?.first?.objectValue?["id"]?.stringValue == "approval-1")
        let wrong = try await call("woven_sessions_respond", ["id": .string(id), "interaction": .string("approval-1"), "optionID": .string("nope")])
        #expect(!wrong.success)
        let answered = try await call("woven_sessions_respond", ["id": .string(id), "interaction": .string("approval-1"), "optionID": .string("allow")])
        #expect(answered.success, "\(answered.error ?? "")")
        #expect(linux.commands.last?.kind == .respond && linux.commands.last?.interactionID == "approval-1" && linux.commands.last?.response?.optionID == "allow")

        // Stop, then the identical retry replays the receipt.
        let stopRequest = UUID().uuidString.lowercased()
        let stopped = try await call("woven_sessions_stop", ["id": .string(id), "requestID": .string(stopRequest)])
        #expect(stopped.success && stopped.result?.objectValue?["stopped"] == .bool(true), "\(stopped.error ?? "")")
        #expect(linux.commands.last?.kind == .stop && linux.commands.last?.runID == "run-1")
        let count = linux.commands.count
        _ = try await call("woven_sessions_stop", ["id": .string(id), "requestID": .string(stopRequest)])
        #expect(linux.commands.count == count)

        // The workspace's list, and a bot's own list without a workspace.
        let listed = try await call("woven_sessions_list", ["workspace": .string(workspace.id)])
        #expect(listed.result?.objectValue?["rows"]?.arrayValue?.map { $0.objectValue?["id"]?.stringValue } == [id])
        let mine = try await call("woven_sessions_list", [:])
        #expect(mine.result?.objectValue?["rows"]?.arrayValue?.first?.objectValue?["state"]?.stringValue == "running")
        #expect(linux.commands.allSatisfy { $0.deviceID == signer.deviceID })

        // A session on this Mac that the bot neither created nor coordinates cannot be stopped by it.
        let local = try #require(await macA.model.createLocalACPSession(runtimeKind: .codex))
        let foreign = try await call("woven_sessions_stop", ["id": .string(local)])
        #expect(!foreign.success && foreign.error?.contains("created or coordinate") == true)
    }

    /// The sidebar lists another Mac's agents, including those for a Linux host that Mac
    /// added. Starting a chat with one goes straight to that host, signed by this Mac.
    @Test func aChatWithAnAgentAnotherMacAddedStartsOnItsHostSigned() async throws {
        let macB = try await FacadeFixture(); defer { macB.remove() }
        let identity = try await macB.database.libraryIdentity()
        let signer = MemberIdentity(deviceID: identity.hostDeviceID, kind: .mac, key: .init())
        let linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: identity.libraryID, members: [signer.deviceID: signer.publicKey])
        let workspace = try await macB.database.receiveSyncedWorkspace(linux.descriptor)
        macB.model.federatedExecutionClient = try MemberExecutionClient(database: macB.database,
            commandJournalURL: macB.directory.appending(path: "commands.json"),
            makeSignedTransport: { workspace in try SignedExecutionWorkspaceTransport(workspace: workspace, signer: signer.signer, audience: linux.memberID, send: linux.send) })
        // Mac A's agent for the host, as peer sync delivers it.
        let macA = UUID()
        let agentID = try await macB.database.ensureRemoteHarnessAgent(runtimeKind: .codex, remoteWorkspaceID: try #require(UUID(uuidString: workspace.id)),
                                                                       remoteWorkspaceName: "Linux L", ownerDeviceID: macA)
        try await macB.database.write { db in
            try db.toolsExecuteUnlocked("INSERT OR REPLACE INTO paired_agent_owners VALUES(?,?)", [agentID.uuidString.lowercased(), macA.uuidString.lowercased()])
        }
        #expect(try await macB.database.pairedAgentWorkspaces()[agentID]?.id == workspace.id)
        let conversation = UUID()
        #expect(try await macB.model.createPairedMacSession(agentID: agentID, conversationID: conversation, folderID: nil) == conversation.uuidString.lowercased())
        #expect(linux.created.map(\.conversationID) == [conversation.uuidString.lowercased()])
        #expect(linux.created.first?.deviceID == signer.deviceID && linux.created.first?.runtimeKind == "codex")
    }

    @Test func anotherMacManagesALinuxHostItDidNotAdd() async throws {
        let macB = try await FacadeFixture(); defer { macB.remove() }
        let identity = try await macB.database.libraryIdentity()
        let host = LibraryHostController(model: macB.model, defaults: macB.defaults, supportDirectory: macB.directory, peerStorage: .memory())
        let signer = try await host.memberSigner()
        let macBKey = try await host.peerSync.members().identity.publicKey
        // Added on Mac A: its owner is another device, and Mac B has no SSH setup for it.
        let linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: UUID().uuidString.lowercased(), members: [signer.deviceID: macBKey])
        let workspace = try await macB.database.receiveSyncedWorkspace(linux.descriptor)
        try await linux.join(host.peerSync.members())
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

        // "Update everything" updates it with the signed route: upload, then poll until it reports success.
        macB.model.remoteWorkspaces.sharedHostBundle = { (Data("host bundle".utf8), String(repeating: "f", count: 64)) }
        try await macB.model.remoteWorkspaces.runSharedHost(workspace.id, .update, pollInterval: .milliseconds(10), updateTimeout: .seconds(5))
        #expect(linux.hostRequests.suffix(3) == ["POST /v1/host/update?fingerprint=" + String(repeating: "f", count: 64), "GET /v1/host/update", "GET /v1/host/status"])
        #expect(linux.uploaded == Data("host bundle".utf8))
        #expect(macB.model.remoteWorkspaces.sharedHosts[workspace.id]?.error == nil)

        // A stranger's signature is refused.
        let stranger = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
        let refused = try RemoteHostAdministrationClient(endpoint: workspace.endpoint!, signer: stranger.signer,
                                                         audience: linux.memberID, send: linux.send)
        await #expect(throws: MemberSignedHTTPError.self) { _ = try await refused.status() }
    }

    /// A Linux host reaches a Mac's library-backed tools with its own member
    /// signature, only for the workspace it executes; no MCP grant exists.
    @Test func linuxMemberSignsWorkspaceMCPOnlyForItsOwnWorkspace() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let device = try await fixture.database.libraryIdentity().hostDeviceID
        let mac = MemberDirectory(database: fixture.database, identity: MemberIdentity(deviceID: device, kind: .mac, key: .init()), cacheLifetime: 0)
        try await mac.ensureSelf(name: "Mac", endpoints: [])
        let linux = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
        let other = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
        for member in [linux, other] {
            try await mac.add(deviceID: member.deviceID, kind: .linux, name: "Linux", publicKey: member.publicKey, endpoints: [])
        }
        let workspace = try await fixture.database.receiveSyncedWorkspace(.init(id: UUID().uuidString.lowercased(), libraryID: UUID().uuidString.lowercased(),
            ownerDeviceID: UUID().uuidString.lowercased(), kind: .linux, name: "Linux L", executionDeviceID: linux.deviceID))
        let api = DeviceAPI(database: fixture.database,
            authentication: try DeviceAuthentication(fileURL: fixture.directory.appending(path: "mcp-devices.json")),
            commands: fixture.model.libraryCommands, isActive: { true }, members: mac)
        let message = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        func call(_ signer: MemberIdentity, conversation: String = UUID().uuidString.lowercased(), workspace named: String? = nil) async throws -> (Int, String?) {
            var headers = try signer.signer.headers(method: "POST", target: "/wovenmatter/mcp/workspace", body: message, audience: device)
            headers["X-Woven-Protocol"] = String(LibraryProtocol.version)
            headers["X-Woven-Workspace-ID"] = named ?? workspace.id
            headers["X-Woven-Conversation-ID"] = conversation
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

        // This Mac did not add the host (the workspace's owner is another Mac). Once the
        // session's row arrives by peer sync, as the Linux library publishes it, the
        // host's own conversation is served here like on any other Mac.
        let session = UUID().uuidString.lowercased()
        let row = LibraryConversation(id: session, title: "Linux session", providerID: "local:codex", routeID: "local:codex",
                                        runtimeKind: "codex", libraryID: workspace.libraryID, workspaceID: workspace.id)
        try await fixture.database.write { db in
            try db.toolsExecuteUnlocked("INSERT INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,?)",
                                        [session, workspace.id, String(decoding: try JSONEncoder().encode(row), as: UTF8.self)])
        }
        let served = try await call(linux, conversation: session)
        #expect(served.0 == 200, "\(served)")
        #expect(try await call(other, conversation: session).1?.contains("does not execute") == true)

        // A real host's registry row names its Node server's own execution device ID; the
        // member that serves that endpoint's host (from the synced member list) is accepted.
        let hostM = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
        try await mac.add(deviceID: hostM.deviceID, kind: .linux, name: "Linux M", publicKey: hostM.publicKey,
                          endpoints: [URL(string: "https://linux-m.fixture.ts.net:8443/wovenmatter/")!])
        let m = try await fixture.database.receiveSyncedWorkspace(.init(id: UUID().uuidString.lowercased(), libraryID: UUID().uuidString.lowercased(),
            ownerDeviceID: UUID().uuidString.lowercased(), kind: .linux, name: "Linux M",
            endpoint: URL(string: "https://linux-m.fixture.ts.net/wovenmatter-execution/m"), executionDeviceID: UUID().uuidString.lowercased()))
        let mSession = UUID().uuidString.lowercased()
        let mRow = LibraryConversation(id: mSession, title: "M session", providerID: "local:codex", routeID: "local:codex",
                                         runtimeKind: "codex", libraryID: m.libraryID, workspaceID: m.id)
        try await fixture.database.write { db in
            try db.toolsExecuteUnlocked("INSERT INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,?)",
                                        [mSession, m.id, String(decoding: try JSONEncoder().encode(mRow), as: UTF8.self)])
        }
        #expect(await mac.audience(for: m) == hostM.deviceID)
        let fromM = try await call(hostM, conversation: mSession, workspace: m.id)
        #expect(fromM.0 == 200, "\(fromM)")
        #expect(try await call(linux, conversation: mSession, workspace: m.id).1?.contains("does not execute") == true)
        // Two members claiming that host: nobody is trusted to serve it.
        try await mac.add(deviceID: other.deviceID, kind: .linux, name: "Linux", publicKey: other.publicKey,
                          endpoints: [URL(string: "https://linux-m.fixture.ts.net/wovenmatter/")!])
        #expect(await mac.audience(for: m) == nil)
        #expect(try await call(hostM, conversation: mSession, workspace: m.id).1?.contains("does not execute") == true)
    }

    /// Bots on a Linux host another Mac added: this Mac lists it from the registry, reads its
    /// status with a signed request, signs its socket upgrade for it, and updates it signed.
    @Test func botsOnAHostAnotherMacAddedAreReachedSigned() async throws {
        let macB = try await FacadeFixture(); defer { macB.remove() }
        let host = LibraryHostController(model: macB.model, defaults: macB.defaults, supportDirectory: macB.directory, peerStorage: .memory())
        macB.model.libraryHost = host
        let signer = try await host.memberSigner()
        let macBKey = try await host.peerSync.members().identity.publicKey
        let linux = ReachLinuxHost(prefix: "/wovenmatter-execution/linux-l", workspaceID: UUID().uuidString.lowercased(),
                                   libraryID: UUID().uuidString.lowercased(), members: [signer.deviceID: macBKey])
        let workspace = try await macB.database.receiveSyncedWorkspace(linux.descriptor)
        try await linux.join(host.peerSync.members())
        host.remoteHostSend = linux.send
        // The host's member ID, not the execution device ID its Node server names.
        let machineID = linux.memberID
        #expect(workspace.executionDeviceID != machineID)

        #expect(await macB.model.memberBotWorkspaces().map(\.id) == [workspace.id])
        let client = try await macB.model.botsClient(for: workspace)
        let status: BotsRemoteStatus = try await client.request("v1/bots/status")
        #expect(status.machine.deviceID == machineID && client.audience == machineID)
        #expect(linux.hostRequests.isEmpty && linux.botsRequests == ["GET /v1/bots/status"])

        // A host whose library schema differs from this Mac's cannot sync: it needs Update everything.
        linux.librarySchema = "another-schema"
        let stale = await macB.model.remoteBotMachines(thisMacVersion: nil, directory: BotsRemoteDirectory())
        #expect(stale.first { $0.id == machineID }?.state == .needsUpdate)
        #expect(stale.first { $0.id == machineID }?.message?.contains("library format") == true)
        linux.librarySchema = try await macB.database.pairedLibrarySchema()
        let current = await macB.model.remoteBotMachines(thisMacVersion: nil, directory: BotsRemoteDirectory())
        #expect(current.first { $0.id == machineID }?.message?.contains("library format") != true)

        // The socket upgrade is signed for that machine only, and only for a member's bots socket.
        let socket = try #require(workspace.endpoint).appending(path: "v1/bots/ws")
        var wss = try #require(URLComponents(url: socket, resolvingAgainstBaseURL: false)); wss.scheme = "wss"
        let headers = try await macB.model.signMemberSocket(url: try #require(wss.url), audience: machineID)
        #expect(headers[MemberRequestSignature.audienceHeader] == machineID && headers["Authorization"] == nil)
        #expect(try await linux.verifies(method: "GET", target: "/wovenmatter-execution/linux-l/v1/bots/ws", headers: headers))
        await #expect(throws: BotsError.self) { _ = try await macB.model.signMemberSocket(url: try #require(wss.url), audience: UUID().uuidString.lowercased()) }
        await #expect(throws: BotsError.self) {
            _ = try await macB.model.signMemberSocket(url: URL(string: "wss://linux-l.fixture.ts.net/wovenmatter-execution/linux-l/v1/host/update")!, audience: machineID)
        }

        // The live stream upgrade is signed too, with its protocol query, and only that query.
        let stream = try StreamEndpoint.url(for: try #require(workspace.endpoint))
        let streamHeaders = try await macB.model.signMemberSocket(url: stream, audience: machineID)
        #expect(try await linux.verifies(method: "GET", target: "/wovenmatter-execution/linux-l/v1/stream?protocol=1", headers: streamHeaders))
        #expect(streamHeaders[MemberRequestSignature.nonceHeader] != headers[MemberRequestSignature.nonceHeader])
        var otherQuery = try #require(URLComponents(url: stream, resolvingAgainstBaseURL: false)); otherQuery.query = "protocol=2"
        await #expect(throws: BotsError.self) { _ = try await macB.model.signMemberSocket(url: try #require(otherQuery.url), audience: machineID) }
        var plain = otherQuery; plain.scheme = "ws"; plain.query = "protocol=1"
        await #expect(throws: BotsError.self) { _ = try await macB.model.signMemberSocket(url: try #require(plain.url), audience: machineID) }
        await #expect(throws: BotsError.self) { _ = try await macB.model.signMemberSocket(url: stream, audience: UUID().uuidString.lowercased()) }
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
    static func route(_ handle: @escaping @MainActor @Sendable (LibraryHTTPRequest) async -> LibraryHTTPResponse) -> MemberSignedHTTPClient.Send {
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

@MainActor private final class ReachMacCommands: DeviceCommandServing {
    var executed: [LibraryCommand] = []
    var devices: [String] = []
    func providers() -> [HarnessCapabilities] { [.init(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Pi Durable", available: true)] }
    func pendingInteractions() async -> [PendingInteraction] { [] }
    func sessionCapabilities(conversationID: String) async throws -> HarnessCapabilities { providers()[0] }
    func transcript(conversationID: String, before: String?) async throws -> LibraryTranscript { .init(conversationID: conversationID) }
    func receipt(commandID: String, deviceID: String) async throws -> LibraryCommandReceipt? { nil }
    func execute(_ command: LibraryCommand, deviceID: String) async throws -> LibraryCommandReceipt {
        executed.append(command); devices.append(deviceID)
        return .init(commandID: command.commandID, deviceID: deviceID, status: .completed, conversationID: command.conversationID)
    }
}

/// A Linux host's Node server as a Mac sees it through Tailscale Serve: it
/// verifies every member signature over the path with its `/wovenmatter-execution/<id>`
/// prefix restored, then routes the stripped path.
final class ReachLinuxHost: @unchecked Sendable {
    let prefix: String
    let descriptor: ExecutionWorkspace
    private let verifier: MemberRequestVerifier
    private let lock = NSLock()
    private var _commands: [LibraryCommand] = [], _receipts: [String: LibraryCommandReceipt] = [:]
    private var _hostRequests: [String] = [], _botsBody: NSDictionary?, _botsRequests: [String] = [], _uploaded: Data?
    var commands: [LibraryCommand] { lock.withLock { _commands } }
    var created: [LibraryCommand] { commands.filter { $0.kind == .createSession } }
    var hostRequests: [String] { lock.withLock { _hostRequests } }
    var botsBody: NSDictionary? { lock.withLock { _botsBody } }
    var botsRequests: [String] { lock.withLock { _botsRequests } }
    var uploaded: Data? { lock.withLock { _uploaded } }
    // Live session state the host reports: running runs by session, pending
    // questions, whether its harness steers, and the library schema it reports.
    private var _running: [String: String] = [:], _pending: [PendingInteraction] = [], _canSteer = false, _librarySchema: String?
    var running: [String: String] { get { lock.withLock { _running } } set { lock.withLock { _running = newValue } } }
    var pending: [PendingInteraction] { get { lock.withLock { _pending } } set { lock.withLock { _pending = newValue } } }
    var canSteer: Bool { get { lock.withLock { _canSteer } } set { lock.withLock { _canSteer = newValue } } }
    var librarySchema: String? { get { lock.withLock { _librarySchema } } set { lock.withLock { _librarySchema = newValue } } }
    /// Whether a signed upgrade would be accepted here, as the server's socket handler checks it.
    func verifies(method: String, target: String, headers: [String: String]) async throws -> Bool {
        let lowered = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        return (try? await verifier.verify(method: method, target: target, headers: lowered, body: Data(), allowing: [.mac])) != nil
    }

    init(prefix: String, workspaceID: String, libraryID: String, members: [String: Data]) {
        self.prefix = prefix
        let host = UUID().uuidString.lowercased()
        memberID = host
        // As in an older host's record, the Node server's execution device ID is its own, not the
        // member ID, so these tests also cover the audience fallback kept for such records.
        descriptor = .init(id: workspaceID, libraryID: libraryID, ownerDeviceID: UUID().uuidString.lowercased(), kind: .linux, name: "Linux L",
            endpoint: URL(string: "https://linux-l.fixture.ts.net" + prefix)!, capabilities: ["execution", "historyReplay"],
            executionDeviceID: UUID().uuidString.lowercased())
        // Like the Node server, it accepts only requests addressed to its own member device ID.
        verifier = MemberRequestVerifier(audience: host, lookup: { id in members[id].map { MemberKey(deviceID: id, kind: .mac, name: "Member", publicKey: $0) } })
    }

    /// The host's member ID, as the library host's identity names it.
    let memberID: String
    /// The host's member entry as a Mac's library receives it by sync.
    func join(_ directory: MemberDirectory) async throws {
        try await directory.ensureSelf(name: "Mac", endpoints: [])
        try await directory.add(deviceID: memberID, kind: .linux, name: "Linux L", publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                                endpoints: [URL(string: "https://linux-l.fixture.ts.net/wovenmatter/")!])
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
            if path.hasPrefix("/v1/bots/") { lock.withLock { _botsRequests.append(method + " " + path) } }
            switch (method, path.split(separator: "?").first.map(String.init) ?? path) {
            case ("GET", "/v1/execution"): return (try JSONEncoder().encode(descriptor), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", "/v1/execution/providers"):
                let providers = [HarnessCapabilities(id: "codex", runtimeKind: "codex", displayName: "Codex", routeName: "Linux L", available: true)]
                return (try JSONEncoder().encode(providers), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("POST", "/v1/execution/commands"):
                let command = try JSONDecoder().decode(LibraryCommand.self, from: body)
                let receipt = lock.withLock { () -> LibraryCommandReceipt in
                    if let saved = _receipts[command.commandID] { return saved }
                    _commands.append(command)
                    let receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID, status: .completed,
                        conversationID: command.conversationID, libraryID: descriptor.libraryID, workspaceID: descriptor.id)
                    _receipts[command.commandID] = receipt
                    return receipt
                }
                return (try JSONEncoder().encode(receipt), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", let route) where route.hasPrefix("/v1/execution/commands/"):
                let id = String(route.dropFirst("/v1/execution/commands/".count))
                guard let saved = lock.withLock({ _receipts[id] }) else { return try reply(404, ["error": "not_found"]) }
                return (try JSONEncoder().encode(saved), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", "/v1/execution/interactions"):
                return (try JSONEncoder().encode(pending), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", "/v1/execution/conversations"):
                let running = running
                let sessions = created.compactMap(\.conversationID).map { id in
                    LibraryConversation(id: id, title: "Build it", providerID: "codex", runtimeKind: "codex", activeRunID: running[id],
                                          preview: "Working", updatedAt: "2026-11-09T12:00:00Z", libraryID: descriptor.libraryID, workspaceID: descriptor.id)
                }
                return (try JSONEncoder().encode(sessions), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", let route) where route.hasPrefix("/v1/execution/conversations/") && route.hasSuffix("/transcript"):
                let id = String(route.dropFirst("/v1/execution/conversations/".count).dropLast("/transcript".count))
                let paged = target.contains("before=")
                let messages = (paged ? ["Earlier"] : (0..<25).map { "Message \($0)" }).enumerated().map { index, text in
                    LibraryMessage(id: "\(id)-\(paged ? "old" : "new")-\(index)", conversationID: id, role: "assistant",
                                     content: index == 0 && !paged ? String(repeating: "x", count: 5000) : text, createdAt: "2026-11-09T12:00:00Z")
                }
                return (try JSONEncoder().encode(LibraryTranscript(conversationID: id, messages: messages, olderCursor: paged ? nil : "cursor-1")),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", let route) where route.hasPrefix("/v1/execution/conversations/") && route.hasSuffix("/capabilities"):
                let provider = HarnessCapabilities(id: "codex", runtimeKind: "codex", displayName: "Codex", available: true, canSteer: canSteer)
                return (try JSONEncoder().encode(provider), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", "/v1/execution/events"): return (try JSONEncoder().encode(ExecutionJournalPage(libraryID: descriptor.libraryID, cursor: 0)), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("GET", "/v1/host/status"): return try reply(200, ["state": "running", "roles": ["workspace": true]])
            case ("GET", "/v1/host/logs"): return try reply(200, ["logs": "server started"])
            case ("POST", "/v1/host/restart"): return try reply(202, ["restarting": true])
            case ("POST", "/v1/host/update"):
                lock.withLock { _uploaded = body }
                return try reply(202, ["state": "running"])
            case ("GET", "/v1/host/update"): return try reply(200, ["state": "succeeded", "result": ["state": "running"]])
            case ("GET", "/v1/bots/status"):
                let status = BotsRemoteStatus(machine: .init(deviceID: memberID, name: "Linux L", kind: "linux"),
                                              enabled: true, state: "ready", versions: .init(runtime: "0.1.0", protocol: 1, librarySchema: librarySchema))
                return (try JSONEncoder().encode(status), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case ("POST", "/v1/host/bots-configure"):
                lock.withLock { _botsBody = try? JSONSerialization.jsonObject(with: body) as? NSDictionary }
                return try reply(200, ["configured": true])
            case ("POST", "/v1/execution/devices"):
                struct Enrollment: Decodable { let deviceID: String }
                let enrollment = try JSONDecoder().decode(Enrollment.self, from: body)
                let credential = ExecutionCredential(workspace: descriptor, deviceID: enrollment.deviceID, token: String(repeating: "t", count: 43))
                return (try JSONEncoder().encode(credential), HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!)
            default: return try reply(404, ["error": "not_found"])
            }
        }
    }
}

extension WorkspaceDatabase {
    /// A registry row as peer sync delivers it from the Mac that added the host
    /// (another library, another owner), which local registration refuses.
    func receiveSyncedWorkspace(_ workspace: ExecutionWorkspace) async throws -> ExecutionWorkspace {
        var value = workspace; value.revision = 1
        let row = value
        try await write { db in
            let statement = try db.prepareUnlocked("INSERT INTO execution_workspaces(id,owner_device_id,revision,deleted,payload) VALUES (?,?,?,0,?)")
            defer { sqlite3_finalize(statement) }
            try db.bind(row.id, at: 1, to: statement); try db.bind(row.ownerDeviceID, at: 2, to: statement)
            sqlite3_bind_int64(statement, 3, row.revision)
            try db.bindJSON(row, at: 4, to: statement); try db.stepDone(statement)
        }
        return value
    }
}

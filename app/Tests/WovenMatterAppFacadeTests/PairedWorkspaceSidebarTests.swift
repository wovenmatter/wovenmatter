import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterShared
import WovenMatterCore
@testable import WovenMatterAppFacade

/// Every Mac lists paired iPhones and iPads from the synced registry, with their
/// Quick Chat history read-only and the folders bound to them.
@MainActor @Suite(.serialized)
struct PairedWorkspaceSidebarTests {
    @Test func syncedPhoneQuickChatsAppearUnderTheirWorkspaceAsReadOnlyHistory() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let identity = try await fixture.database.libraryIdentity()
        let phone = try await fixture.database.registerExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: fixture.device,
            kind: .ios, name: "Trey's iPhone", executionDeviceID: fixture.device)), deviceID: fixture.device)
        let chat = UUID().uuidString.lowercased()
        _ = try await fixture.database.ingestExecutionJournal(.init(libraryID: identity.libraryID, entries: [
            .init(workspaceID: phone.id, originSequence: 1, conversationID: chat, kind: .conversation,
                  conversation: .init(id: chat, title: "Tea timer", runtimeKind: "piDurable"))
        ]), deviceID: fixture.device)
        await fixture.model.refreshWorkspace()

        // The phone is listed even though it has no endpoint (offline phones stay visible).
        let listed = PairedWorkspaceSidebarModel.workspaces(fixture.model.executionWorkspaceRegistry)
        #expect(listed.map(\.id) == [phone.id])
        #expect(listed.first?.endpoint == nil)
        let conversations = fixture.model.workspaceOverview?.conversations ?? []
        let history = PairedWorkspaceSidebarModel.history(
            for: phone, conversations: conversations, owners: fixture.model.federatedExecutionOwners)
        #expect(history.map(\.id) == [chat])
        #expect(history.first?.title == "Tea timer")
        #expect(PairedWorkspaceSidebarModel.isPhoneHistory(
            owner: fixture.model.federatedExecutionOwners[chat], registry: fixture.model.executionWorkspaceRegistry))
        let local = conversations.first { fixture.model.federatedExecutionOwners[$0.id] == nil }
        #expect(PairedWorkspaceSidebarModel.isPhoneHistory(
            owner: local.flatMap { fixture.model.federatedExecutionOwners[$0.id] },
            registry: fixture.model.executionWorkspaceRegistry) == false)
    }

    /// New Chat offers every other Mac's and Linux workspace's agents from the
    /// synced registry, once per workspace and harness, never an iPhone's, and
    /// not those this Mac already offers through a Linux host it manages.
    @Test func newChatListsEveryOtherMacAndLinuxWorkspaceButNeverThePhone() throws {
        func agent(_ runtime: AgentRuntimeKind) -> WorkspaceAgent {
            .init(codename: runtime.rawValue, displayName: runtime.displayName, iconKey: "bot",
                  executionLocation: .remote, runtimeKind: runtime)
        }
        let mac = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .mac, name: "Studio")
        let linux = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .linux, name: "Workstation")
        let managed = RemoteWorkspaceConfiguration(name: "Managed", workspaceID: "managed", hostName: "managed.invalid", kind: .host,
                                                   dataRoot: "/data", workspaceRoot: "/workspace")
        let managedLinux = ExecutionWorkspace(id: managed.id.uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .linux, name: "Managed")
        let phone = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "phone", kind: .ios, name: "iPhone")
        let macCodex = agent(.codex), linuxCodex = agent(.codex), linuxAgain = agent(.codex), linuxClaude = agent(.claudeCode)
        let managedCodex = agent(.codex), phoneAgent = agent(.defaultAgent), local = agent(.codex)
        let peers = [macCodex.id: mac, linuxCodex.id: linux, linuxAgain.id: linux, linuxClaude.id: linux, managedCodex.id: managedLinux, phoneAgent.id: phone]
        let harness = try JSONDecoder().decode(RemoteHarnessStatus.self, from: Data("""
            {"id":"codex","displayName":"Codex","transport":"acp","capabilities":[],"state":"ready","authenticationStatus":"ready","setupMethods":[],"detectedProviders":[]}
            """.utf8))
        let agents = [linuxClaude, linuxCodex, linuxAgain, phoneAgent, managedCodex, macCodex, local]
        let targets = NewChatPeerTarget.resolve(agents: agents, peerWorkspaces: peers,
            configured: [.init(configuration: managed, harness: harness)], folderOwnerID: nil)
        #expect(targets.map(\.workspace.name) == ["Studio", "Workstation", "Workstation"])
        #expect(targets.map(\.runtimeKind) == [.codex, .claudeCode, .codex])
        #expect(targets.map(\.agentID) == [macCodex.id, linuxClaude.id, linuxCodex.id])
        // A folder bound to one workspace offers only that workspace's agents.
        let scoped = NewChatPeerTarget.resolve(agents: agents, peerWorkspaces: peers, configured: [], folderOwnerID: "device:" + mac.id)
        #expect(scoped.map(\.agentID) == [macCodex.id])
    }

    @Test func onlyLivePhonesAreListedOnceAndFoldersMatchTheirDeviceBinding() throws {
        let phone = UUID().uuidString.lowercased(), mac = UUID().uuidString.lowercased()
        let registry: [ExecutionWorkspace] = [
            .init(id: mac, libraryID: "library", ownerDeviceID: mac, kind: .mac, name: "Other Mac"),
            .init(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: mac, kind: .linux, name: "Workstation"),
            .init(id: phone, libraryID: "library", ownerDeviceID: phone, kind: .ios, name: "iPhone"),
            .init(id: "device:" + phone, libraryID: "library", ownerDeviceID: phone, kind: .ios, name: "Legacy alias"),
            .init(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "gone", kind: .ios, name: "Removed iPad", deleted: true),
            .init(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "ipad", kind: .ios, name: "iPad")
        ]
        let listed = PairedWorkspaceSidebarModel.workspaces(registry)
        #expect(listed.map(\.name) == ["iPad", "iPhone"])

        let folders = try JSONDecoder().decode([WorkspaceFolderRecord].self, from: Data("""
            [{"id":"phone-folder","name":"Phone ideas","position":0,"is_pinned":0,"execution_workspace_id":"device:\(phone.uppercased())"},
             {"id":"mac-folder","name":"Mac projects","position":1,"is_pinned":0,"execution_workspace_id":"device:\(mac)"},
             {"id":"loose","name":"Unbound","position":2,"is_pinned":0}]
            """.utf8))
        let phoneWorkspace = try #require(listed.first { $0.id == phone })
        #expect(PairedWorkspaceSidebarModel.folders(for: phoneWorkspace, in: folders).map(\.id) == ["phone-folder"])

        let conversations = try JSONDecoder().decode([WorkspaceConversationRecord].self, from: Data("""
            [{"id":"older","title":"Older","unread":0,"is_pinned":0,"is_archived":0,"last_message_at":"2026-11-01T00:00:00Z"},
             {"id":"newer","title":"Newer","unread":0,"is_pinned":0,"is_archived":0,"last_message_at":"2026-11-08T00:00:00Z"},
             {"id":"archived","title":"Archived","unread":0,"is_pinned":0,"is_archived":1},
             {"id":"mac-chat","title":"Mac chat","unread":0,"is_pinned":0,"is_archived":0}]
            """.utf8))
        let owners = ["older": phone, "newer": "device:" + phone, "archived": phone, "mac-chat": mac]
        #expect(PairedWorkspaceSidebarModel.history(for: phoneWorkspace, conversations: conversations, owners: owners)
            .map(\.id) == ["newer", "older"])
        #expect(PairedWorkspaceSidebarModel.isPhoneHistory(owner: mac, registry: registry) == false)
        #expect(PairedWorkspaceSidebarModel.isPhoneHistory(owner: "device:" + phone, registry: registry))
    }

    /// Agents are listed by their owner records: this Mac's as stored;
    /// another member's under its workspace by the plain harness name; a local
    /// agent of unknown owner nowhere; this Mac's Linux agents unchanged.
    @Test func agentsAreListedWhereTheirOwnerRecordsPlaceThem() {
        func agent(_ runtime: AgentRuntimeKind, _ location: AgentExecutionLocation, name: String? = nil, on device: UUID? = nil) -> WorkspaceAgent {
            .init(codename: runtime.rawValue, displayName: name ?? runtime.displayName, iconKey: "bot", executionLocation: location,
                  runtimeKind: runtime, runtimeDeviceID: device)
        }
        let studio = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .mac, name: "Studio")
        let workstation = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .linux, name: "Workstation")
        let mine = agent(.codex, .local), theirs = agent(.codex, .local), unknown = agent(.claudeCode, .local)
        let ownLinux = agent(.codex, .remote, name: "Codex · Fixture remote", on: UUID())
        let theirLinux = agent(.claudeCode, .remote, name: "Claude Code · Workstation", on: UUID(uuidString: workstation.id))
        let listed = ApplicationModel.presentedAgents([mine, theirs, unknown, ownLinux, theirLinux], own: [mine.id, ownLinux.id],
                                                      peerWorkspaces: [theirs.id: studio, theirLinux.id: workstation])
        #expect(listed.filter { $0.executionLocation == .local } == [mine])
        let remote = listed.filter { $0.executionLocation == .remote }
        #expect(remote.map(\.id) == [theirs.id, ownLinux.id, theirLinux.id])
        #expect(remote.map(\.displayName) == ["Codex", "Codex · Fixture remote", AgentRuntimeKind.claudeCode.displayName])
        #expect(remote.map(\.runtimeDeviceID) == [UUID(uuidString: studio.id), ownLinux.runtimeDeviceID, UUID(uuidString: workstation.id)])
        // Before any owner record or registry row: nothing of another Mac's is local.
        #expect(ApplicationModel.presentedAgents([theirs, unknown], own: [], peerWorkspaces: [:]).isEmpty)
    }

    /// One rule titles another machine's workspace everywhere: the name
    /// someone chose; else a Mac's tailnet machine name; else the name its
    /// owner registered, which is all a Linux host has.
    @Test func aWorkspaceIsTitledByItsChosenNameThenItsTailnetNameThenItsRegisteredName() async throws {
        let endpoint = URL(string: "https://jamess-mac-mini.tail1234.ts.net:8443/wovenmatter")!
        let mac = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .mac,
                                     name: "James’s Mac mini", endpoint: endpoint)
        var offline = mac; offline.endpoint = nil
        let linux = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .linux,
                                       name: "workstation-home-1", endpoint: URL(string: "https://other-label.tail1234.ts.net/wovenmatter-execution/x")!)
        #expect(ApplicationModel.workspaceDisplayName(mac, overrides: [:]) == "jamess-mac-mini")
        #expect(ApplicationModel.workspaceDisplayName(offline, overrides: [:]) == "James’s Mac mini")
        #expect(ApplicationModel.workspaceDisplayName(linux, overrides: [:]) == "workstation-home-1")
        let chosen = [mac.id: "Studio", linux.id: "Build box"]
        #expect(ApplicationModel.workspaceDisplayName(mac, overrides: chosen) == "Studio")
        #expect(ApplicationModel.workspaceDisplayName(offline, overrides: chosen) == "Studio")
        #expect(ApplicationModel.workspaceDisplayName(linux, overrides: chosen) == "Build box")
    }

    /// The Mac that owns a workspace publishes its chosen name as the
    /// registry name, for its own row and each Linux host it set up, returns
    /// to the default when the name is cleared, and writes nothing while the
    /// name stays the same. A window sends a rename to its background server.
    @Test func theOwnerPublishesChosenNamesInItsRegistryRowsAndReturnsToTheDefaults() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let host = fixture.model.libraryHost
        try await host.refreshExecutionRegistry()
        let identity = try await fixture.database.libraryIdentity(), linuxID = fixture.remote.id.uuidString.lowercased()
        func rows() async throws -> (mac: ExecutionWorkspace, linux: ExecutionWorkspace) {
            let all = try await fixture.database.libraryExecutionWorkspaces()
            return (try #require(all.first { $0.kind == .mac && $0.ownerDeviceID == identity.hostDeviceID }), try #require(all.first { $0.id == linuxID }))
        }
        let original = try await rows()
        #expect(original.mac.name == DevelopmentLaunch.deviceName() && original.linux.name == fixture.remote.name)
        #expect(fixture.model.workspaceDisplayName(fixture.remote) == fixture.remote.name)

        // As the background server runs a window's rename.
        let service = BackendApplicationService(model: fixture.model)
        _ = try await service.executeWorkspaceMutation(.renameWorkspace(registryID: original.mac.id, name: "Studio"))
        #expect(await fixture.model.renameWorkspace(registryID: linuxID.uppercased(), name: "Build box"))
        #expect(fixture.model.workspaceNameOverrides == [original.mac.id: "Studio", linuxID: "Build box"])
        #expect(fixture.model.workspaceDisplayName(fixture.remote) == "Build box")
        try await host.refreshExecutionRegistry()
        let named = try await rows()
        #expect(named.mac.name == "Studio" && named.linux.name == "Build box")
        #expect(named.mac.revision == original.mac.revision + 1 && named.linux.revision == original.linux.revision + 1)
        #expect(fixture.model.workspaceDisplayName(named.linux) == "Build box")

        let head = try await fixture.database.peerSyncHead()
        for _ in 0..<3 { try await host.refreshExecutionRegistry() }
        let unchanged = try await rows()
        #expect(unchanged.mac == named.mac && unchanged.linux == named.linux)
        #expect(try await fixture.database.peerSyncHead() == head)

        #expect(await fixture.model.renameWorkspace(registryID: original.mac.id, name: "  "))
        #expect(await fixture.model.renameWorkspace(registryID: linuxID, name: nil))
        try await host.refreshExecutionRegistry()
        let cleared = try await rows()
        #expect(cleared.mac.name == DevelopmentLaunch.deviceName() && cleared.linux.name == fixture.remote.name)
        #expect(cleared.mac.revision == named.mac.revision + 1 && cleared.linux.revision == named.linux.revision + 1)
        #expect(fixture.model.workspaceNameOverrides.isEmpty)
        await #expect(throws: (any Error).self) { try await service.executeWorkspaceMutation(.renameWorkspace(registryID: "local", name: "Studio")) }
    }
}

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
        _ = try await fixture.database.ingestLibraryJournal(.init(libraryID: identity.libraryID, entries: [
            .init(workspaceID: phone.id, originSequence: 1, conversationID: chat, kind: .conversation,
                  conversation: .init(id: chat, title: "Tea timer", runtimeKind: "piDurable"))
        ]), deviceID: fixture.device)
        await fixture.model.refreshWorkspace()

        // The phone is listed even though it has no endpoint (offline phones stay visible).
        let listed = DashboardPairedWorkspaceSidebarModel.workspaces(fixture.model.executionWorkspaceRegistry)
        #expect(listed.map(\.id) == [phone.id])
        #expect(listed.first?.endpoint == nil)
        let conversations = fixture.model.workspaceOverview?.conversations ?? []
        let history = DashboardPairedWorkspaceSidebarModel.history(
            for: phone, conversations: conversations, owners: fixture.model.federatedExecutionOwners)
        #expect(history.map(\.id) == [chat])
        #expect(history.first?.title == "Tea timer")
        #expect(DashboardPairedWorkspaceSidebarModel.isPhoneHistory(
            owner: fixture.model.federatedExecutionOwners[chat], registry: fixture.model.executionWorkspaceRegistry))
        let local = conversations.first { fixture.model.federatedExecutionOwners[$0.id] == nil }
        #expect(DashboardPairedWorkspaceSidebarModel.isPhoneHistory(
            owner: local.flatMap { fixture.model.federatedExecutionOwners[$0.id] },
            registry: fixture.model.executionWorkspaceRegistry) == false)
    }

    /// New Chat offers every other Mac's and Linux workspace's agents from the
    /// synced registry, once per workspace and harness, never an iPhone's, and
    /// not those this Mac already offers through a Linux host it manages.
    @Test func newChatListsEveryOtherMacAndLinuxWorkspaceButNeverThePhone() throws {
        func agent(_ runtime: AgentRuntimeKind) -> WorkspaceAgent {
            .init(userID: "user", codename: runtime.rawValue, displayName: runtime.displayName, iconKey: "bot",
                  executionLocation: .remote, governingPlane: .remoteWorkspace, runtimeKind: runtime)
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
        let targets = DashboardNewChatPeerTarget.resolve(agents: agents, peerWorkspaces: peers,
            configured: [.init(configuration: managed, harness: harness)], folderOwnerID: nil)
        #expect(targets.map(\.workspace.name) == ["Studio", "Workstation", "Workstation"])
        #expect(targets.map(\.runtimeKind) == [.codex, .claudeCode, .codex])
        #expect(targets.map(\.agentID) == [macCodex.id, linuxClaude.id, linuxCodex.id])
        // A folder bound to one workspace offers only that workspace's agents.
        let scoped = DashboardNewChatPeerTarget.resolve(agents: agents, peerWorkspaces: peers, configured: [], folderOwnerID: "device:" + mac.id)
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
        let listed = DashboardPairedWorkspaceSidebarModel.workspaces(registry)
        #expect(listed.map(\.name) == ["iPad", "iPhone"])

        let folders = try JSONDecoder().decode([WorkspaceFolderRecord].self, from: Data("""
            [{"id":"phone-folder","name":"Phone ideas","position":0,"is_pinned":0,"execution_workspace_id":"device:\(phone.uppercased())"},
             {"id":"mac-folder","name":"Mac projects","position":1,"is_pinned":0,"execution_workspace_id":"device:\(mac)"},
             {"id":"loose","name":"Unbound","position":2,"is_pinned":0}]
            """.utf8))
        let phoneWorkspace = try #require(listed.first { $0.id == phone })
        #expect(DashboardPairedWorkspaceSidebarModel.folders(for: phoneWorkspace, in: folders).map(\.id) == ["phone-folder"])

        let conversations = try JSONDecoder().decode([WorkspaceConversationRecord].self, from: Data("""
            [{"id":"older","title":"Older","unread":0,"is_pinned":0,"is_archived":0,"last_message_at":"2026-11-01T00:00:00Z"},
             {"id":"newer","title":"Newer","unread":0,"is_pinned":0,"is_archived":0,"last_message_at":"2026-11-08T00:00:00Z"},
             {"id":"archived","title":"Archived","unread":0,"is_pinned":0,"is_archived":1},
             {"id":"mac-chat","title":"Mac chat","unread":0,"is_pinned":0,"is_archived":0}]
            """.utf8))
        let owners = ["older": phone, "newer": "device:" + phone, "archived": phone, "mac-chat": mac]
        #expect(DashboardPairedWorkspaceSidebarModel.history(for: phoneWorkspace, conversations: conversations, owners: owners)
            .map(\.id) == ["newer", "older"])
        #expect(DashboardPairedWorkspaceSidebarModel.isPhoneHistory(owner: mac, registry: registry) == false)
        #expect(DashboardPairedWorkspaceSidebarModel.isPhoneHistory(owner: "device:" + phone, registry: registry))
    }
}

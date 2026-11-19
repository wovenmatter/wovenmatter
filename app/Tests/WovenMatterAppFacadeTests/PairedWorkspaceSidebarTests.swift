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
        // A Mac's registry ID is random; its folders name its device ID instead.
        let macFolderOwner = "device:" + UUID().uuidString.lowercased()
        let mac = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .mac, name: "Studio",
                                     folderOwnerID: macFolderOwner)
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
        // A folder bound to one workspace offers only that workspace's agents:
        // a Mac's through the registry row that names the folder's owner, a
        // Linux host's by its own ID.
        let registry = [mac, linux, managedLinux, phone]
        let scoped = NewChatPeerTarget.resolve(agents: agents, peerWorkspaces: peers, configured: [], folderOwnerID: macFolderOwner, registry: registry)
        #expect(scoped.map(\.agentID) == [macCodex.id])
        let onLinux = NewChatPeerTarget.resolve(agents: agents, peerWorkspaces: peers, configured: [],
                                                folderOwnerID: "remote:" + linux.id.uppercased(), registry: registry)
        #expect(onLinux.map(\.agentID) == [linuxClaude.id, linuxCodex.id])
        // The registry ID is not the folder owner, so it matches nothing.
        #expect(NewChatPeerTarget.resolve(agents: agents, peerWorkspaces: peers, configured: [],
                                          folderOwnerID: "device:" + UUID().uuidString.lowercased(), registry: registry).isEmpty)
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
        // A Dev instance shares its Mac's machine name, so it says which it is;
        // stopped, it has no address and keeps the name it registered.
        var dev = mac; dev.id = UUID().uuidString.lowercased(); dev.developmentInstance = "pairing"; dev.name = "James’s Mac mini (Dev) · pairing"
        #expect(ApplicationModel.workspaceDisplayName(dev, overrides: [:]) == "jamess-mac-mini (Dev) · pairing")
        #expect(ApplicationModel.workspaceDisplayName(dev, overrides: [dev.id: "Sandbox"]) == "Sandbox")
        dev.endpoint = nil
        #expect(ApplicationModel.workspaceDisplayName(dev, overrides: [:]) == "James’s Mac mini (Dev) · pairing")
    }

    // MARK: Remote workspaces: one list of every other machine

    private func remoteAgent(_ runtime: AgentRuntimeKind, on workspace: String, name: String? = nil) -> WorkspaceAgent {
        .init(codename: "remote-\(workspace.prefix(8))-\(runtime.rawValue)", displayName: name ?? runtime.displayName, iconKey: "bot",
              executionLocation: .remote, runtimeKind: runtime, runtimeDeviceID: UUID(uuidString: workspace))
    }

    private func readyTarget(_ runtime: AgentRuntimeKind, on configuration: RemoteWorkspaceConfiguration) throws -> RemoteHarnessChatTarget {
        .init(configuration: configuration, harness: try JSONDecoder().decode(RemoteHarnessStatus.self, from: Data("""
            {"id":"\(runtime.rawValue)","displayName":"\(runtime.displayName)","transport":"acp","capabilities":[],"state":"ready","authenticationStatus":"ready","setupMethods":[],"detectedProviders":[]}
            """.utf8)))
    }

    private func folders(_ owners: [(id: String, owner: String?)]) throws -> [WorkspaceFolderRecord] {
        let rows = owners.enumerated().map { index, folder in
            "{\"id\":\"\(folder.id)\",\"name\":\"\(folder.id)\",\"position\":\(index),\"is_pinned\":0"
                + (folder.owner.map { ",\"execution_workspace_id\":\"\($0)\"" } ?? "") + "}"
        }
        return try JSONDecoder().decode([WorkspaceFolderRecord].self, from: Data("[\(rows.joined(separator: ","))]".utf8))
    }

    /// Two paired Macs and the Linux hosts they set up, as this Mac's library
    /// holds them. A Mac has three IDs: its registry ID (random), its library
    /// host ID (`ownerDeviceID`) and its device ID (`folderOwnerID`).
    private struct Fleet {
        let hostID = "host-this-mac", folderOwner = "device:" + UUID().uuidString.lowercased()
        let otherFolderOwner = "device:" + UUID().uuidString.lowercased()
        let own: ExecutionWorkspace, other: ExecutionWorkspace
        /// A Linux host this Mac set up, and one the other Mac set up.
        let configured: RemoteWorkspaceConfiguration, configuredRow: ExecutionWorkspace, shared: ExecutionWorkspace
        let phone: ExecutionWorkspace
        var registry: [ExecutionWorkspace] { [own, other, configuredRow, shared, phone] }

        init() {
            func id() -> String { UUID().uuidString.lowercased() }
            own = .init(id: id(), libraryID: "library", ownerDeviceID: hostID, kind: .mac, name: "This Mac",
                        endpoint: URL(string: "https://this-mac.tail1234.ts.net:8443/wovenmatter"), folderOwnerID: folderOwner)
            other = .init(id: id(), libraryID: "library", ownerDeviceID: "host-other-mac", kind: .mac, name: "James’s Mac mini",
                          endpoint: URL(string: "https://jamess-mac-mini.tail1234.ts.net:8443/wovenmatter"), folderOwnerID: otherFolderOwner)
            configured = .init(name: "workstation", workspaceID: "workstation", hostName: "workstation.tail1234.ts.net", kind: .host,
                               dataRoot: "/data", workspaceRoot: "/workspace")
            configuredRow = .init(id: configured.id.uuidString.lowercased(), libraryID: "library", ownerDeviceID: hostID, kind: .linux, name: "workstation")
            shared = .init(id: id(), libraryID: "library", ownerDeviceID: "host-other-mac", kind: .linux, name: "build-box")
            phone = .init(id: id(), libraryID: "library", ownerDeviceID: "phone", kind: .ios, name: "iPhone")
        }

        func links(registry: [ExecutionWorkspace]? = nil, targets: [RemoteHarnessChatTarget] = [], names: [String: String] = [:],
                   hostID: String?? = .none, folderOwner: String?? = .none) -> [RemoteWorkspaceSidebarLink] {
            RemoteWorkspaceSidebarModel.links(configurations: [configured], readyTargets: targets, registry: registry ?? self.registry,
                nameOverrides: names, localHostDeviceID: hostID ?? self.hostID, localFolderOwnerID: folderOwner ?? self.folderOwner)
        }
    }

    /// Remote workspaces are every other machine, Mac or Linux, in one list by
    /// name: listed while offline, never this Mac, never a retained snapshot
    /// owner or a stopped Dev connection, and a Linux host once whether this
    /// Mac set it up, another did, or both know it.
    @Test func remoteWorkspacesAreOneListOfEveryOtherMacAndLinuxHost() throws {
        let fleet = Fleet()
        let links = fleet.links()
        #expect(links.map(\.title) == ["build-box", "jamess-mac-mini", "workstation"])
        #expect(links.map(\.id) == [fleet.shared.id, fleet.other.id, fleet.configuredRow.id])
        #expect(links.map(\.kind) == [.linux, .mac, .linux])
        #expect(links.map(\.folderOwnerID) == ["remote:" + fleet.shared.id, fleet.otherFolderOwner, "remote:" + fleet.configuredRow.id])
        // Only a host set up here has a configuration; it is one link with its registry row.
        #expect(links.map { $0.configuration?.id } == [nil, nil, fleet.configured.id])
        #expect(links.map { $0.workspace?.id } == [fleet.shared.id, fleet.other.id, fleet.configuredRow.id])
        #expect(links.allSatisfy { !$0.hasChosenName })
        // The header counts every workspace: remote ones, iPhones and iPads, and this Mac.
        #expect(links.count + PairedWorkspaceSidebarModel.workspaces(fleet.registry).count + 1 == 5)

        // This Mac is named by its library host ID or by its folder owner; either is enough.
        #expect(fleet.links(hostID: .some(nil)).map(\.id) == links.map(\.id))
        #expect(fleet.links(folderOwner: .some(nil)).map(\.id) == links.map(\.id))
        // Until it knows either, it lists no Mac rather than itself; Linux hosts need neither.
        #expect(fleet.links(hostID: .some(nil), folderOwner: .some(nil)).map(\.id) == [fleet.shared.id, fleet.configuredRow.id])

        // Offline, the other Mac stays, under the name it registered.
        var offline = fleet.other; offline.endpoint = nil
        var retained = fleet.other; retained.id = UUID().uuidString.lowercased(); retained.retainedHistory = true
        var stoppedDev = fleet.other; stoppedDev.id = UUID().uuidString.lowercased(); stoppedDev.developmentInstance = "pairing"; stoppedDev.endpoint = nil
        var runningDev = fleet.other; runningDev.id = UUID().uuidString.lowercased(); runningDev.developmentInstance = "pairing"
        var removed = fleet.shared; removed.id = UUID().uuidString.lowercased(); removed.deleted = true
        let changed = fleet.links(registry: [fleet.own, offline, retained, stoppedDev, runningDev, removed, fleet.shared, fleet.phone])
        #expect(changed.map(\.title) == ["build-box", "James’s Mac mini", "jamess-mac-mini (Dev) · pairing", "workstation"])
        #expect(changed.map(\.id) == [fleet.shared.id, fleet.other.id, runningDev.id, fleet.configuredRow.id])
        // A host set up here is listed before it has registered.
        #expect(changed.last?.workspace == nil && changed.last?.configuration == fleet.configured)

        // A chosen name titles any of them, sorts it, and can be removed again.
        let named = fleet.links(names: [fleet.other.id: "Studio", fleet.configuredRow.id: "Alpha", fleet.shared.id: "Zeta"])
        #expect(named.map(\.title) == ["Alpha", "Studio", "Zeta"])
        #expect(named.allSatisfy { $0.hasChosenName })
        #expect(named.map(\.id) == [fleet.configuredRow.id, fleet.other.id, fleet.shared.id])
        // Disclosure, pin and order keys are per workspace, and a Linux host keeps the key it had.
        #expect(AgentDisclosureKey.workspace(named[0].id) == "workspace:" + fleet.configured.id.uuidString.lowercased())
        #expect(AgentDisclosureKey.workspace(fleet.other.id.uppercased()) == "workspace:" + fleet.other.id)
    }

    /// A remote workspace lists the agents that run on it, one per harness.
    /// When this Mac and another Mac each hold an agent for the same Linux
    /// host and harness, this Mac's is shown, also when this Mac only has the
    /// harness ready and has not saved its agent yet.
    @Test func aRemoteWorkspaceListsItsAgentsOncePerHarnessPreferringThisMacs() throws {
        let fleet = Fleet()
        let macCodex = remoteAgent(.codex, on: fleet.other.id), macClaude = remoteAgent(.claudeCode, on: fleet.other.id)
        let ownCodex = remoteAgent(.codex, on: fleet.configuredRow.id, name: "Codex · workstation")
        let theirCodex = remoteAgent(.codex, on: fleet.configuredRow.id), theirClaude = remoteAgent(.claudeCode, on: fleet.configuredRow.id)
        let theirPi = remoteAgent(.defaultAgent, on: fleet.configuredRow.id)
        let sharedCodex = remoteAgent(.codex, on: fleet.shared.id), sharedAgain = remoteAgent(.codex, on: fleet.shared.id)
        let local = WorkspaceAgent(codename: "codex", displayName: "Codex", iconKey: "bot", executionLocation: .local, runtimeKind: .codex)
        let all = [local, sharedAgain, theirPi, theirClaude, theirCodex, ownCodex, macClaude, macCodex, sharedCodex]
        let peers = Set([macCodex, macClaude, theirCodex, theirClaude, theirPi, sharedCodex, sharedAgain].map(\.id))
        let links = fleet.links(targets: [try readyTarget(.defaultAgent, on: fleet.configured)])
        func listed(_ id: String) throws -> [UUID] {
            RemoteWorkspaceSidebarModel.agents(all, in: try #require(links.first { $0.id == id }), peerAgentIDs: peers).map(\.id)
        }
        #expect(Set(try listed(fleet.other.id)) == [macCodex.id, macClaude.id])
        // This Mac's Codex and its ready Pi Durable stand for those harnesses; Claude Code is only the other Mac's.
        #expect(Set(try listed(fleet.configuredRow.id)) == [ownCodex.id, theirClaude.id])
        // Two other members' agents for one harness are one row, the same one every time.
        #expect(try listed(fleet.shared.id) == Array([sharedCodex, sharedAgain].map(\.id).sorted { $0.uuidString < $1.uuidString }.prefix(1)))
    }

    /// Folders are listed under the workspace that owns them. Another Mac's
    /// folders name its device ID, not its registry ID, and are its folders,
    /// not an "Unavailable workspace".
    @Test func foldersAreListedUnderTheirOwningWorkspaceIncludingAnotherMacs() throws {
        let fleet = Fleet()
        let gone = "remote:" + UUID().uuidString.lowercased()
        let all = try folders([
            ("mine", fleet.folderOwner), ("theirs", fleet.otherFolderOwner), ("theirs-upper", fleet.otherFolderOwner.uppercased().replacingOccurrences(of: "DEVICE:", with: "device:")),
            ("configured", "remote:" + fleet.configuredRow.id), ("shared", "remote:" + fleet.shared.id),
            ("phone", "device:" + fleet.phone.id), ("gone", gone), ("loose", nil)
        ])
        let links = fleet.links()
        func listed(_ id: String) throws -> [String] {
            RemoteWorkspaceSidebarModel.folders(all, in: try #require(links.first { $0.id == id }), registry: fleet.registry).map(\.id)
        }
        #expect(try listed(fleet.other.id) == ["theirs", "theirs-upper"])
        #expect(try listed(fleet.configuredRow.id) == ["configured"])
        #expect(try listed(fleet.shared.id) == ["shared"])
        let paired = PairedWorkspaceSidebarModel.workspaces(fleet.registry)
        #expect(RemoteWorkspaceSidebarModel.unavailableFolderOwnerIDs(folders: all, links: links, paired: paired,
            localFolderOwnerID: fleet.folderOwner, registry: fleet.registry) == [gone])
        // A host set up here owns its folders before it has registered.
        let unregistered = fleet.registry.filter { $0.id != fleet.configuredRow.id }
        let early = fleet.links(registry: unregistered)
        #expect(RemoteWorkspaceSidebarModel.folders(all, in: try #require(early.first { $0.configuration != nil }), registry: unregistered).map(\.id) == ["configured"])
        // A Mac that is no longer listed leaves its folders unavailable rather than under another workspace.
        var retained = fleet.other; retained.retainedHistory = true
        let without = [fleet.own, retained, fleet.configuredRow, fleet.shared, fleet.phone]
        #expect(RemoteWorkspaceSidebarModel.unavailableFolderOwnerIDs(folders: all, links: fleet.links(registry: without), paired: paired,
            localFolderOwnerID: fleet.folderOwner, registry: without).contains(fleet.otherFolderOwner))
        // A Mac's Dev instance registers beside it under the same device ID.
        // Stopped, it is not listed, and the folders stay with the Mac that is,
        // whichever row the registry holds first.
        var stoppedDev = fleet.other; stoppedDev.id = UUID().uuidString.lowercased(); stoppedDev.developmentInstance = "pairing"; stoppedDev.endpoint = nil
        for withDev in [[stoppedDev] + fleet.registry, fleet.registry + [stoppedDev]] {
            let link = try #require(fleet.links(registry: withDev).first { $0.id == fleet.other.id })
            #expect(RemoteWorkspaceSidebarModel.folders(all, in: link, registry: withDev).map(\.id) == ["theirs", "theirs-upper"])
            #expect(RemoteWorkspaceSidebarModel.unavailableFolderOwnerIDs(folders: all, links: fleet.links(registry: withDev), paired: paired,
                localFolderOwnerID: fleet.folderOwner, registry: withDev) == [gone])
        }
    }

    /// "+" beside an agent starts a chat anywhere with no folder selected, and
    /// with one selected only on the workspace that owns the folder.
    @Test func anAgentStartsAChatInASelectedFolderOnlyOnTheFoldersWorkspace() throws {
        let fleet = Fleet()
        let all = try folders([("mine", fleet.folderOwner), ("theirs", fleet.otherFolderOwner),
                               ("configured", "remote:" + fleet.configuredRow.id), ("loose", nil)])
        func can(_ workspace: String?, _ folder: String?) -> Bool {
            RemoteWorkspaceSidebarModel.canCreateChat(onWorkspace: workspace, selectedFolderID: folder, folders: all,
                localFolderOwnerID: fleet.folderOwner, registry: fleet.registry)
        }
        for workspace in [nil, fleet.other.id, fleet.configuredRow.id, fleet.shared.id] { #expect(can(workspace, nil)) }
        #expect(can(nil, "mine") && !can(fleet.other.id, "mine") && !can(fleet.configuredRow.id, "mine"))
        // The other Mac's folder allows its agents, through its registry row, and nobody else's.
        #expect(can(fleet.other.id, "theirs") && !can(nil, "theirs") && !can(fleet.shared.id, "theirs"))
        #expect(can(fleet.configuredRow.id, "configured") && !can(fleet.shared.id, "configured") && !can(nil, "configured"))
        // A folder with no owner, or one that is gone, starts nothing.
        #expect(!can(nil, "loose") && !can(fleet.other.id, "loose") && !can(nil, "missing"))
    }

    /// New Chat groups remote agents under their workspace's name in the
    /// sidebar's order, and a folder leaves only the workspace that owns it.
    @Test func newChatGroupsRemoteAgentsUnderTheirWorkspaceAndAFolderScopesThem() throws {
        let fleet = Fleet()
        let macCodex = remoteAgent(.codex, on: fleet.other.id), macClaude = remoteAgent(.claudeCode, on: fleet.other.id)
        let ownCodex = remoteAgent(.codex, on: fleet.configuredRow.id, name: "Codex · workstation")
        let theirCodex = remoteAgent(.codex, on: fleet.configuredRow.id), theirClaude = remoteAgent(.claudeCode, on: fleet.configuredRow.id)
        let sharedCodex = remoteAgent(.codex, on: fleet.shared.id)
        let agents = [ownCodex, theirClaude, theirCodex, sharedCodex, macCodex, macClaude]
        let peers = [macCodex.id: fleet.other, macClaude.id: fleet.other, theirCodex.id: fleet.configuredRow, theirClaude.id: fleet.configuredRow,
                     sharedCodex.id: fleet.shared]
        let links = fleet.links(targets: [try readyTarget(.codex, on: fleet.configured)], names: [fleet.other.id: "Studio"])
        func groups(_ folderOwner: String?) -> [NewChatWorkspaceGroup] {
            NewChatWorkspaceGroup.resolve(links: links, agents: agents, peerWorkspaces: peers, folderOwnerID: folderOwner, registry: fleet.registry)
        }
        let everything = groups(nil)
        #expect(everything.map(\.title) == ["build-box", "Studio", "workstation"])
        #expect(everything.map(\.kind) == [.linux, .mac, .linux])
        #expect(everything.map { $0.peers.map(\.agentID) } == [[sharedCodex.id], [macCodex.id, macClaude.id], [theirClaude.id]])
        // This Mac's ready Codex on its own host is offered once, as this Mac's.
        #expect(everything.map { $0.targets.map(\.harness.id) } == [[], [], [.codex]])
        // A folder on the other Mac: only that Mac, found through its folder owner.
        #expect(groups(fleet.otherFolderOwner).map(\.id) == [fleet.other.id])
        #expect(groups("remote:" + fleet.configuredRow.id).map(\.id) == [fleet.configuredRow.id])
        // This Mac's own folder offers no remote agent, and a workspace with none is not a group.
        #expect(groups(fleet.folderOwner).isEmpty)
        #expect(NewChatWorkspaceGroup.resolve(links: links, agents: [], peerWorkspaces: [:], folderOwnerID: nil, registry: fleet.registry)
            .map(\.id) == [fleet.configuredRow.id])
    }

    /// Several machines list the same harness, so a chat's row says which
    /// workspace runs it, by the name the sidebar shows, and finds its agent
    /// by ID: paired Macs' agents share a codename.
    @Test func aChatRowNamesTheRemoteWorkspaceThatRunsIt() throws {
        let fleet = Fleet()
        let local = WorkspaceAgent(codename: "codex", displayName: "Codex", iconKey: "bot", executionLocation: .local, runtimeKind: .codex)
        let theirs = WorkspaceAgent(codename: "codex", displayName: "Codex", iconKey: "bot", executionLocation: .remote, runtimeKind: .codex,
                                    runtimeDeviceID: UUID(uuidString: fleet.other.id))
        let conversations = try JSONDecoder().decode([WorkspaceConversationRecord].self, from: Data("""
            [{"id":"here","agent_id":"\(local.id.uuidString.lowercased())","agent_codename":"codex","title":"Here","unread":0,"is_pinned":0,"is_archived":0},
             {"id":"there","agent_id":"\(theirs.id.uuidString.lowercased())","agent_codename":"codex","title":"There","unread":0,"is_pinned":0,"is_archived":0}]
            """.utf8))
        let titles = Dictionary(uniqueKeysWithValues: fleet.links(names: [fleet.other.id: "Studio"]).map { ($0.id, $0.title) })
        let content = RightRailContent(conversations: conversations, notes: [], agents: [local, theirs], workspaceTitles: titles, query: "", readFilter: nil)
        let rows = Dictionary(uniqueKeysWithValues: content.recentChats.map { ($0.id, $0.meta) })
        #expect(rows["here"]?.agentLabel == "Codex" && rows["here"]?.locationLabel == "Local workspace")
        #expect(rows["there"]?.agentLabel == "Codex · Studio" && rows["there"]?.locationLabel == "Studio")
        // Without a listed workspace the row keeps the agent's own name.
        let unlisted = ConversationListMeta.resolve(conversation: conversations[1], agent: theirs, foldersByID: [:])
        #expect(unlisted.agentLabel == "Codex" && unlisted.locationLabel == "Remote workspace")
    }

    /// A new Linux workspace left unnamed is named after its machine on the tailnet.
    @Test func aNewLinuxWorkspaceLeftUnnamedTakesItsTailnetMachineName() {
        #expect(RemoteWorkspacesModel.workspaceName(entered: "  ", hostName: " workstation-home-1.tail1234.ts.net ") == "workstation-home-1")
        #expect(RemoteWorkspacesModel.workspaceName(entered: "", hostName: "workstation") == "workstation")
        #expect(RemoteWorkspacesModel.workspaceName(entered: " Build box ", hostName: "workstation.tail1234.ts.net") == "Build box")
        // A Tailscale IP names no machine, and no host names nothing: a name must be entered.
        // (Joined here because the public-tree scan refuses a literal address.)
        #expect(RemoteWorkspacesModel.workspaceName(entered: "", hostName: ["100", "64", "0", "7"].joined(separator: ".")) == "")
        #expect(RemoteWorkspacesModel.workspaceName(entered: "", hostName: "fd7a:115c:a1e0::1") == "")
        #expect(RemoteWorkspacesModel.workspaceName(entered: "", hostName: "") == "")
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

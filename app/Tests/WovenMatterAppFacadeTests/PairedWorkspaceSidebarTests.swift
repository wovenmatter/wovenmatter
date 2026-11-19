import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterShared
import WovenMatterCore
@testable import WovenMatterLibraryStore
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
    /// a harness this Mac has ready on a Linux host it manages as its own.
    @Test func newChatListsEveryOtherMacAndLinuxWorkspaceButNeverThePhone() throws {
        func agent(_ runtime: AgentRuntimeKind, on workspace: String) -> WorkspaceAgent {
            .init(codename: runtime.rawValue, displayName: runtime.displayName, iconKey: "bot",
                  executionLocation: .remote, runtimeKind: runtime, runtimeDeviceID: UUID(uuidString: workspace))
        }
        // A Mac's registry ID is random; its folders name its device ID instead.
        let macFolderOwner = "device:" + UUID().uuidString.lowercased()
        let mac = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .mac, name: "Studio",
                                     folderOwnerID: macFolderOwner)
        let linux = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .linux, name: "Workstation")
        let managed = RemoteWorkspaceConfiguration(name: "Managed", workspaceID: "managed", hostName: "managed.invalid",
                                                   dataRoot: "/data", workspaceRoot: "/workspace")
        let managedLinux = ExecutionWorkspace(id: managed.id.uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-a", kind: .linux, name: "Managed")
        let phone = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "phone", kind: .ios, name: "iPhone")
        let macCodex = agent(.codex, on: mac.id), linuxCodex = agent(.codex, on: linux.id), linuxAgain = agent(.codex, on: linux.id)
        let linuxClaude = agent(.claudeCode, on: linux.id), managedCodex = agent(.codex, on: managedLinux.id), phoneAgent = agent(.defaultAgent, on: phone.id)
        let agents = [linuxClaude, linuxCodex, linuxAgain, phoneAgent, managedCodex, macCodex]
        let registry = [mac, linux, managedLinux, phone]
        func groups(_ folderOwner: String?, targets: [RemoteHarnessChatTarget] = []) -> [NewChatWorkspaceGroup] {
            NewChatWorkspaceGroup.resolve(listing: RemoteWorkspaceSidebarModel.listing(
                configurations: [managed], readyTargets: targets, registry: registry, activeDeviceIDs: [], nameOverrides: [:],
                localHostDeviceID: "mac-a", localFolderOwnerID: nil, agents: agents, peerAgentIDs: Set(agents.map(\.id)), folders: []),
                folderOwnerID: folderOwner)
        }
        let ready = try readyTarget(.codex, on: managed)
        let offered = groups(nil, targets: [ready])
        #expect(offered.map(\.title) == ["Managed", "Studio", "Workstation"])
        // The managed host's Codex is this Mac's ready harness, not the other Mac's agent for it.
        #expect(offered.map { $0.targets.map(\.harness.id) } == [[.codex], [], []])
        let lowest = [linuxCodex, linuxAgain].map(\.id).min { $0.uuidString < $1.uuidString }
        #expect(offered.map { $0.peers.map(\.agentID) } == [[], [macCodex.id], [lowest, linuxClaude.id].compactMap { $0 }])
        #expect(offered[2].peers.map(\.runtimeKind) == [.codex, .claudeCode])
        // A folder bound to one workspace offers only that workspace's agents:
        // a Mac's through the registry row that names the folder's owner, a
        // Linux host's by its own ID.
        #expect(groups(macFolderOwner).flatMap(\.peers).map(\.agentID) == [macCodex.id])
        #expect(groups("remote:" + linux.id.uppercased()).map(\.id) == [linux.id])
        // The registry ID is not the folder owner, so it matches nothing.
        #expect(groups("device:" + UUID().uuidString.lowercased()).isEmpty)
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
    /// someone chose; else a Mac's tailnet machine name, from its registry
    /// row's address or else from the route this library keeps for it; else
    /// the name its owner registered, which is all a Linux host has.
    @Test func aWorkspaceIsTitledByItsChosenNameThenItsTailnetNameThenItsRegisteredName() async throws {
        let endpoint = URL(string: "https://jamess-mac-mini.tail1234.ts.net:8443/wovenmatter")!
        let mac = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .mac,
                                     name: "James’s Mac mini", endpoint: endpoint)
        var offline = mac; offline.endpoint = nil
        let linux = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: "library", ownerDeviceID: "mac-b", kind: .linux,
                                       name: "workstation-home-1", endpoint: URL(string: "https://other-label.tail1234.ts.net/wovenmatter-execution/x")!)
        #expect(ApplicationModel.workspaceDisplayName(mac, overrides: [:]) == "jamess-mac-mini")
        #expect(ApplicationModel.workspaceDisplayName(linux, overrides: [:]) == "workstation-home-1")
        // A row with no address (Tailscale was unavailable on that Mac) is
        // still its machine: the route kept for its library host names it.
        // The computer name is only for a Mac with neither.
        let routes = ["mac-b": endpoint, "mac-c": URL(string: "https://studio.tail1234.ts.net:8443/wovenmatter")!]
        #expect(ApplicationModel.workspaceDisplayName(offline, overrides: [:], macAddresses: routes) == "jamess-mac-mini")
        #expect(ApplicationModel.workspaceDisplayName(offline, overrides: [:], macAddresses: ["mac-c": routes["mac-c"]!]) == "James’s Mac mini")
        #expect(ApplicationModel.workspaceDisplayName(offline, overrides: [:]) == "James’s Mac mini")
        // The row's own address wins over a route, and a route never titles a Linux host.
        #expect(ApplicationModel.workspaceDisplayName(mac, overrides: [:], macAddresses: ["mac-b": routes["mac-c"]!]) == "jamess-mac-mini")
        #expect(ApplicationModel.workspaceDisplayName(linux, overrides: [:], macAddresses: routes) == "workstation-home-1")
        let chosen = [mac.id: "Studio", linux.id: "Build box"]
        #expect(ApplicationModel.workspaceDisplayName(mac, overrides: chosen) == "Studio")
        #expect(ApplicationModel.workspaceDisplayName(offline, overrides: chosen, macAddresses: routes) == "Studio")
        #expect(ApplicationModel.workspaceDisplayName(linux, overrides: chosen) == "Build box")
        // A Dev instance shares its Mac's machine name, so it says which it is.
        var dev = mac; dev.id = UUID().uuidString.lowercased(); dev.developmentInstance = "pairing"; dev.name = "James’s Mac mini (Dev) · pairing"
        #expect(ApplicationModel.workspaceDisplayName(dev, overrides: [:]) == "jamess-mac-mini (Dev) · pairing")
        #expect(ApplicationModel.workspaceDisplayName(dev, overrides: [dev.id: "Sandbox"]) == "Sandbox")
        // Stopped, a live Dev instance shares its Mac's host ID and so its
        // route, and keeps the suffix; a Dev snapshot has a host ID of its own
        // and takes only its own route, never its Mac's production one.
        dev.endpoint = nil
        #expect(ApplicationModel.workspaceDisplayName(dev, overrides: [:], macAddresses: routes) == "jamess-mac-mini (Dev) · pairing")
        var snapshot = dev; snapshot.ownerDeviceID = "snapshot-host"
        #expect(ApplicationModel.workspaceDisplayName(snapshot, overrides: [:], macAddresses: routes) == "James’s Mac mini (Dev) · pairing")
        #expect(ApplicationModel.workspaceDisplayName(snapshot, overrides: [:], macAddresses: ["snapshot-host": endpoint]) == "jamess-mac-mini (Dev) · pairing")
        #expect(ApplicationModel.workspaceDisplayName(dev, overrides: [:]) == "James’s Mac mini (Dev) · pairing")

        // A Linux host keeps the name typed at its setup. One stored under
        // its own host name (a bots-only host is) shows its machine name, on
        // the Mac that set it up and, by its registered name, on the others.
        func host(_ name: String, _ hostName: String) -> RemoteWorkspaceConfiguration {
            .init(name: name, workspaceID: "bots", hostName: hostName, dataRoot: "/data", workspaceRoot: "/workspace")
        }
        let botsOnly = host("build-box.tail1234.ts.net", "build-box.tail1234.ts.net"), typed = host("Build box", "build-box.tail1234.ts.net")
        let byAddress = host(["100", "64", "0", "7"].joined(separator: "."), ["100", "64", "0", "7"].joined(separator: "."))
        #expect(ApplicationModel.workspaceDisplayName(botsOnly, overrides: [:]) == "build-box")
        #expect(ApplicationModel.workspaceDisplayName(typed, overrides: [:]) == "Build box")
        #expect(ApplicationModel.workspaceDisplayName(byAddress, overrides: [:]) == byAddress.name)
        #expect(ApplicationModel.workspaceDisplayName(botsOnly, overrides: [botsOnly.id.uuidString.lowercased(): "Bots"]) == "Bots")
        var registered = linux; registered.name = "build-box.tail1234.ts.net"
        #expect(ApplicationModel.workspaceDisplayName(registered, overrides: [:]) == "build-box")
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
            configured = .init(name: "workstation", workspaceID: "workstation", hostName: "workstation.tail1234.ts.net",
                               dataRoot: "/data", workspaceRoot: "/workspace")
            configuredRow = .init(id: configured.id.uuidString.lowercased(), libraryID: "library", ownerDeviceID: hostID, kind: .linux, name: "workstation")
            shared = .init(id: id(), libraryID: "library", ownerDeviceID: "host-other-mac", kind: .linux, name: "build-box")
            phone = .init(id: id(), libraryID: "library", ownerDeviceID: "phone", kind: .ios, name: "iPhone")
        }

        func links(registry: [ExecutionWorkspace]? = nil, targets: [RemoteHarnessChatTarget] = [], names: [String: String] = [:],
                   routes: [String: URL] = [:], configurations: [RemoteWorkspaceConfiguration]? = nil,
                   hostID: String?? = .none, folderOwner: String?? = .none) -> [RemoteWorkspaceSidebarLink] {
            RemoteWorkspaceSidebarModel.links(configurations: configurations ?? [configured], readyTargets: targets, registry: registry ?? self.registry,
                nameOverrides: names, macAddresses: routes, localHostDeviceID: hostID ?? self.hostID, localFolderOwnerID: folderOwner ?? self.folderOwner)
        }

        /// What the window builds once for a render and hands to the sidebar and New Chat.
        func listing(registry: [ExecutionWorkspace]? = nil, active: Set<String> = [], targets: [RemoteHarnessChatTarget] = [],
                     names: [String: String] = [:], agents: [WorkspaceAgent] = [], peers: Set<UUID> = [],
                     folders: [WorkspaceFolderRecord] = []) -> RemoteWorkspaceListing {
            RemoteWorkspaceSidebarModel.listing(configurations: [configured], readyTargets: targets, registry: registry ?? self.registry,
                activeDeviceIDs: active, nameOverrides: names, localHostDeviceID: hostID, localFolderOwnerID: folderOwner,
                agents: agents, peerAgentIDs: peers, folders: folders)
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

        // This Mac is named by its library host ID; that alone lists everything else.
        #expect(fleet.links(folderOwner: .some(nil)).map(\.id) == links.map(\.id))
        // With only its folder owner known, a Mac is listed when its own folder
        // owner says it is another; a Linux host set up elsewhere waits for the
        // host ID, since a host this Mac removed looks the same until then.
        #expect(fleet.links(hostID: .some(nil)).map(\.id) == [fleet.other.id, fleet.configuredRow.id])
        var unnamedOwner = fleet.other; unnamedOwner.folderOwnerID = nil
        #expect(fleet.links(registry: [fleet.own, unnamedOwner, fleet.configuredRow], hostID: .some(nil)).map(\.id) == [fleet.configuredRow.id])
        // Before its own row names a folder owner, this Mac is still never listed: by host ID, or not at all.
        var ownEarly = fleet.own; ownEarly.folderOwnerID = nil
        #expect(fleet.links(registry: [ownEarly, fleet.other], hostID: .some(nil)).map(\.id) == [fleet.other.id, fleet.configuredRow.id])
        #expect(fleet.links(registry: [ownEarly, fleet.other]).map(\.id) == [fleet.other.id, fleet.configuredRow.id])
        // Until it knows either, it lists only the hosts it set up itself.
        #expect(fleet.links(hostID: .some(nil), folderOwner: .some(nil)).map(\.id) == [fleet.configuredRow.id])

        // Offline, the other Mac stays, under the name it registered when
        // this library keeps no route for it.
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
        // With the route every paired Mac has, going offline changes neither its title nor the order.
        let routes = ["host-other-mac": try #require(fleet.other.endpoint)]
        let online = fleet.links(routes: routes), away = fleet.links(registry: [fleet.own, offline, fleet.configuredRow, fleet.shared, fleet.phone], routes: routes)
        #expect(away.map(\.title) == ["build-box", "jamess-mac-mini", "workstation"])
        #expect(away.map(\.title) == online.map(\.title) && away.map(\.id) == online.map(\.id))

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
    /// host and harness, this Mac's stands for it while this Mac has the
    /// harness ready there (also before its agent is saved); otherwise the
    /// other member's does, and this Mac's own only when it is the only one.
    @Test func aRemoteWorkspaceListsItsAgentsOncePerHarnessPreferringThisMacs() throws {
        let fleet = Fleet()
        let macCodex = remoteAgent(.codex, on: fleet.other.id), macClaude = remoteAgent(.claudeCode, on: fleet.other.id)
        let ownCodex = remoteAgent(.codex, on: fleet.configuredRow.id, name: "Codex · workstation")
        let theirCodex = remoteAgent(.codex, on: fleet.configuredRow.id), theirClaude = remoteAgent(.claudeCode, on: fleet.configuredRow.id)
        let theirPi = remoteAgent(.defaultAgent, on: fleet.configuredRow.id)
        let ownGrok = remoteAgent(.grokBuild, on: fleet.configuredRow.id, name: "Grok Build · workstation")
        let sharedCodex = remoteAgent(.codex, on: fleet.shared.id), sharedAgain = remoteAgent(.codex, on: fleet.shared.id)
        let local = WorkspaceAgent(codename: "codex", displayName: "Codex", iconKey: "bot", executionLocation: .local, runtimeKind: .codex)
        let all = [local, sharedAgain, theirPi, theirClaude, theirCodex, ownCodex, ownGrok, macClaude, macCodex, sharedCodex]
        let peers = Set([macCodex, macClaude, theirCodex, theirClaude, theirPi, sharedCodex, sharedAgain].map(\.id))
        func choices(_ id: String, ready: [AgentRuntimeKind]) throws -> [RemoteWorkspaceAgentChoice] {
            let links = fleet.links(targets: try ready.map { try readyTarget($0, on: fleet.configured) })
            return RemoteWorkspaceSidebarModel.choices(all, in: try #require(links.first { $0.id == id }), peerAgentIDs: peers)
        }
        func choice(_ kind: AgentRuntimeKind, ready: [AgentRuntimeKind]) throws -> RemoteWorkspaceAgentChoice {
            try #require(try choices(fleet.configuredRow.id, ready: ready).first { $0.runtimeKind == kind })
        }
        // Another Mac's agents are its own: no harness of a Mac is this Mac's to start.
        #expect(Set(try choices(fleet.other.id, ready: []).compactMap { $0.agent?.id }) == [macCodex.id, macClaude.id])
        #expect(try choices(fleet.other.id, ready: []).allSatisfy { $0.isPeer && $0.target == nil })

        // Own and ready: this Mac's Codex, started as this Mac's, standing for the other Mac's too.
        let ready = try choice(.codex, ready: [.codex])
        #expect(ready.agent?.id == ownCodex.id && ready.target?.harness.id == .codex && !ready.isPeer)
        #expect(ready.agentIDs == [ownCodex.id, theirCodex.id])
        // Own but not ready here, and another member holds one: theirs, so the
        // row is one a chat can be started from, and New Chat offers the same agent.
        let notReady = try choice(.codex, ready: [])
        #expect(notReady.agent?.id == theirCodex.id && notReady.isPeer && notReady.target == nil)
        #expect(notReady.agentIDs == [ownCodex.id, theirCodex.id])
        // Peer only: Claude Code is the other Mac's, whatever is ready here.
        for readiness in [[AgentRuntimeKind](), [.codex]] {
            let peerOnly = try choice(.claudeCode, ready: readiness)
            #expect(peerOnly.agent?.id == theirClaude.id && peerOnly.isPeer && peerOnly.agentIDs == [theirClaude.id])
        }
        // Own only and not ready: still listed, and its "+" says to connect the workspace.
        let alone = try choice(.grokBuild, ready: [])
        #expect(alone.agent?.id == ownGrok.id && !alone.isPeer && alone.target == nil)
        // Ready here before this Mac saved its agent: its own to start, with no saved agent yet.
        let pending = try choice(.defaultAgent, ready: [.defaultAgent])
        #expect(pending.agent == nil && pending.target?.harness.id == .defaultAgent && !pending.isPeer && pending.agentIDs == [theirPi.id])
        // The rows are the choices that have a saved agent, one per harness.
        let links = fleet.links(targets: [try readyTarget(.defaultAgent, on: fleet.configured)])
        let rows = RemoteWorkspaceSidebarModel.choices(all, in: try #require(links.first { $0.id == fleet.configuredRow.id }), peerAgentIDs: peers).compactMap(\.agent)
        #expect(Set(rows.map(\.id)) == [theirCodex.id, theirClaude.id, ownGrok.id])
        #expect(Set(rows.map(\.runtimeKind)).count == rows.count)

        // Duplicates: two members' agents for one harness are one row, the
        // lowest ID every time, whatever order the agents arrive in.
        let lowest = try #require([sharedCodex, sharedAgain].map(\.id).min { $0.uuidString < $1.uuidString })
        for order in [all, Array(all.reversed())] {
            let link = try #require(fleet.links().first { $0.id == fleet.shared.id })
            let duplicate = RemoteWorkspaceSidebarModel.choices(order, in: link, peerAgentIDs: peers)
            #expect(duplicate.map { $0.agent?.id } == [lowest] && duplicate.first?.agentIDs == [sharedCodex.id, sharedAgain.id])
        }
        // This Mac's own duplicates too.
        let ownAgain = remoteAgent(.codex, on: fleet.configuredRow.id, name: "Codex · workstation")
        let ownLowest = try #require([ownCodex, ownAgain].map(\.id).min { $0.uuidString < $1.uuidString })
        let configuredLink = try #require(fleet.links(targets: [try readyTarget(.codex, on: fleet.configured)]).first { $0.id == fleet.configuredRow.id })
        for order in [[ownCodex, ownAgain, theirCodex], [theirCodex, ownAgain, ownCodex]] {
            #expect(RemoteWorkspaceSidebarModel.choices(order, in: configuredLink, peerAgentIDs: peers).first?.agent?.id == ownLowest)
        }
    }

    /// The sidebar's rows, New Chat, the "+" paths and the row a chat
    /// highlights all read one listing, so they name the same agent for a
    /// workspace and harness: started from New Chat, a chat selects a row the
    /// sidebar shows, and a chat held by a hidden duplicate highlights the
    /// agent listed in its place.
    @Test func theSidebarNewChatAndSelectionAgreeOnTheAgentForAWorkspaceAndHarness() throws {
        let fleet = Fleet()
        let ownCodex = remoteAgent(.codex, on: fleet.configuredRow.id, name: "Codex · workstation")
        let theirCodex = remoteAgent(.codex, on: fleet.configuredRow.id), theirClaude = remoteAgent(.claudeCode, on: fleet.configuredRow.id)
        let macCodex = remoteAgent(.codex, on: fleet.other.id)
        let local = WorkspaceAgent(codename: "codex", displayName: "Codex", iconKey: "bot", executionLocation: .local, runtimeKind: .codex)
        let agents = [theirClaude, theirCodex, ownCodex, macCodex], peers = Set([theirCodex, theirClaude, macCodex].map(\.id))
        let target = try readyTarget(.codex, on: fleet.configured)
        func rows(_ listing: RemoteWorkspaceListing) -> Set<UUID> { Set((listing.choices[fleet.configuredRow.id] ?? []).compactMap { $0.agent?.id }) }
        func offered(_ listing: RemoteWorkspaceListing) throws -> NewChatWorkspaceGroup {
            try #require(NewChatWorkspaceGroup.resolve(listing: listing, folderOwnerID: nil).first { $0.id == fleet.configuredRow.id })
        }

        // Codex not ready from this Mac: the other Mac's Codex is the row, New
        // Chat offers that same agent, and no row is this Mac's unusable one.
        let away = fleet.listing(agents: agents, peers: peers)
        #expect(rows(away) == [theirCodex.id, theirClaude.id])
        let offeredAway = try offered(away)
        #expect(Set(offeredAway.peers.map(\.agentID)) == rows(away) && offeredAway.targets.isEmpty)
        // A chat this Mac's own agent holds highlights the listed row, and that row lists both agents' chats.
        #expect(away.listedAgentID(for: ownCodex) == theirCodex.id && away.listedAgentID(for: theirCodex) == theirCodex.id)
        #expect(away.representedAgentIDs(by: theirCodex) == [ownCodex.id, theirCodex.id])
        #expect(away.representedAgentIDs(by: ownCodex) == [ownCodex.id])
        #expect(away.choice(for: target)?.agent?.id == theirCodex.id)

        // Codex ready here: this Mac's Codex is the row, New Chat starts it as
        // this Mac's target, and the chat it starts selects that row.
        let here = fleet.listing(targets: [target], agents: agents, peers: peers)
        #expect(rows(here) == [ownCodex.id, theirClaude.id])
        let offeredHere = try offered(here)
        #expect(offeredHere.targets.map(\.harness.id) == [.codex] && offeredHere.peers.map(\.agentID) == [theirClaude.id])
        #expect(here.choice(for: target)?.agent?.id == ownCodex.id)
        #expect(here.listedAgentID(for: theirCodex) == ownCodex.id && here.representedAgentIDs(by: ownCodex) == [ownCodex.id, theirCodex.id])

        // Another Mac's agent and a local one are their own rows.
        #expect(here.listedAgentID(for: macCodex) == macCodex.id && here.listedAgentID(for: local) == local.id)
        #expect(here.representedAgentIDs(by: local) == [local.id])
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
        // The listing a render builds once: each workspace's folders, by link.
        func listed(_ registry: [ExecutionWorkspace]? = nil) -> (folders: [String: [String]], unavailable: [String]) {
            let listing = fleet.listing(registry: registry, folders: all)
            return (listing.folders.mapValues { $0.map(\.id) }, listing.unavailableFolderOwnerIDs)
        }
        let everything = [fleet.other.id: ["theirs", "theirs-upper"], fleet.configuredRow.id: ["configured"], fleet.shared.id: ["shared"]]
        #expect(listed().folders == everything)
        // This Mac's, the phone's and an unbound folder are none of them; only the owner with no workspace is unavailable.
        #expect(listed().unavailable == [gone])
        // A host set up here owns its folders before it has registered.
        #expect(listed(fleet.registry.filter { $0.id != fleet.configuredRow.id }).folders == everything)
        // A Mac that is no longer listed leaves its folders unavailable rather than under another workspace.
        var retained = fleet.other; retained.retainedHistory = true
        let without = listed([fleet.own, retained, fleet.configuredRow, fleet.shared, fleet.phone])
        #expect(without.unavailable == [fleet.otherFolderOwner, fleet.otherFolderOwner.uppercased().replacingOccurrences(of: "DEVICE:", with: "device:"), gone].sorted())
        #expect(without.folders == [fleet.configuredRow.id: ["configured"], fleet.shared.id: ["shared"]])
        // A Mac's Dev instance registers beside it under the same device ID.
        // Stopped, it is not listed, and the folders stay with the Mac that is,
        // whichever row the registry holds first.
        var stoppedDev = fleet.other; stoppedDev.id = UUID().uuidString.lowercased(); stoppedDev.developmentInstance = "pairing"; stoppedDev.endpoint = nil
        for withDev in [[stoppedDev] + fleet.registry, fleet.registry + [stoppedDev]] {
            #expect(RemoteWorkspaceSidebarModel.workspaceID(ofFolderOwner: fleet.otherFolderOwner, in: withDev) == fleet.other.id)
            #expect(listed(withDev).folders == everything && listed(withDev).unavailable == [gone])
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
        let peers = Set([macCodex, macClaude, theirCodex, theirClaude, sharedCodex].map(\.id))
        let targets = [try readyTarget(.codex, on: fleet.configured)]
        func groups(_ folderOwner: String?, saved: [WorkspaceAgent]? = nil) -> [NewChatWorkspaceGroup] {
            NewChatWorkspaceGroup.resolve(listing: fleet.listing(targets: targets, names: [fleet.other.id: "Studio"], agents: saved ?? agents, peers: peers),
                                          folderOwnerID: folderOwner)
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
        #expect(groups(nil, saved: []).map(\.id) == [fleet.configuredRow.id])
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

    // MARK: Review fixes: removed hosts, presence, identity, placement

    /// A Linux registry row this Mac owns belongs to a host it set up. One it
    /// holds no configuration for was removed here: it is not a remote
    /// workspace on this Mac (also for a user with no paired Mac), is not
    /// offered in Settings as another device's, and once its row is marked
    /// deleted no Mac lists it, places agents on it or offers it.
    @Test func aLinuxHostThisMacRemovedIsNotListedHereOrOfferedAsAnotherDevices() throws {
        let fleet = Fleet()
        var removedHere = fleet.configuredRow; removedHere.id = UUID().uuidString.lowercased(); removedHere.name = "old-box"
        let registry = fleet.registry + [removedHere]
        #expect(fleet.links(registry: registry).map(\.id) == fleet.links().map(\.id))
        #expect(fleet.links(registry: [fleet.own, removedHere], configurations: []).isEmpty)
        // Not for a moment at launch either, before this Mac knows which rows are its own.
        #expect(fleet.links(registry: [fleet.own, removedHere], configurations: [], hostID: .some(nil)).isEmpty)
        #expect(fleet.links(registry: [fleet.own, removedHere], configurations: [], hostID: .some(nil), folderOwner: .some(nil)).isEmpty)
        // Settings → Workspaces, "From other devices": other devices' rows only.
        let configured: Set = [fleet.configuredRow.id]
        #expect(RemoteWorkspaceSidebarModel.sharedWorkspaces(registry, configured: configured, localHostDeviceID: fleet.hostID).map(\.id)
            == [fleet.other.id, fleet.shared.id, fleet.phone.id])
        // Until this Mac's host ID is known, only what is certainly another device's.
        #expect(RemoteWorkspaceSidebarModel.sharedWorkspaces(registry, configured: configured, localHostDeviceID: nil).map(\.id) == [fleet.phone.id])
        // Its agents and folders have no section; the folders are an unavailable workspace's.
        let orphan = remoteAgent(.codex, on: removedHere.id), kept = remoteAgent(.codex, on: fleet.shared.id)
        let bound = try folders([("old", "remote:" + removedHere.id), ("shared", "remote:" + fleet.shared.id)])
        let here = fleet.listing(registry: registry, agents: [orphan, kept], peers: [kept.id], folders: bound)
        #expect(here.choices[removedHere.id] == nil && here.folders[removedHere.id] == nil)
        #expect(here.unavailableFolderOwnerIDs == ["remote:" + removedHere.id])
        #expect(NewChatWorkspaceGroup.resolve(listing: here, folderOwnerID: nil).map(\.id) == [fleet.shared.id])
        #expect(NewChatWorkspaceGroup.resolve(listing: here, folderOwnerID: "remote:" + removedHere.id).isEmpty)

        // On the other Macs, once its owner has marked the row deleted.
        var deleted = fleet.shared; deleted.deleted = true
        let without = [fleet.own, fleet.other, fleet.configuredRow, deleted, fleet.phone]
        let after = fleet.listing(registry: without, agents: [kept], peers: [kept.id], folders: bound)
        #expect(after.links.map(\.id) == [fleet.other.id, fleet.configuredRow.id])
        #expect(after.choices[fleet.shared.id] == nil && NewChatWorkspaceGroup.resolve(listing: after, folderOwnerID: nil).isEmpty)
        #expect(after.unavailableFolderOwnerIDs == ["remote:" + removedHere.id, "remote:" + fleet.shared.id].sorted())
        #expect(RemoteWorkspaceSidebarModel.sharedWorkspaces(without, configured: configured, localHostDeviceID: fleet.hostID).map(\.id)
            == [fleet.other.id, fleet.phone.id])
    }

    /// Uninstalling a Linux workspace on the Mac that set it up marks its
    /// registry row deleted, as its owner and against the row's revision, and
    /// only that: a row this Mac merely holds no configuration for is left
    /// alone. The removal is kept until the row is marked. A deleted identity
    /// never returns; the same machine added again is a new row.
    @Test func uninstallingALinuxWorkspaceMarksItsRegistryRowDeletedOnce() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let host = fixture.model.libraryHost, database = fixture.database, remote = fixture.model.remoteWorkspaces
        try await host.refreshExecutionRegistry()
        let identity = try await database.libraryIdentity(), linuxID = fixture.remote.id.uuidString.lowercased()
        func row(_ id: String) async throws -> ExecutionWorkspace? { try await database.libraryExecutionWorkspaces().first { $0.id == id } }
        let registered = try #require(try await row(linuxID))
        #expect(!registered.deleted && registered.ownerDeviceID == identity.hostDeviceID && registered.kind == .linux)

        // This Mac's own Linux row with no configuration and no removal on
        // record (a live Dev build keeps other configurations; a restored
        // library arrives without them): never marked.
        let unconfigured = try await database.registerExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID, kind: .linux, name: "Kept")),
            deviceID: identity.hostDeviceID)
        // Another Mac's Linux row is never this Mac's to mark, removal on record or not.
        let otherMac = UUID().uuidString.lowercased()
        let theirs = try await database.registerExecutionWorkspace(.init(workspace: .init(
            id: UUID().uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: otherMac, kind: .linux, name: "Theirs")),
            deviceID: identity.hostDeviceID)
        try await host.refreshExecutionRegistry()
        #expect(try await row(unconfigured.id)?.deleted == false && remote.removedWorkspaceIDs.isEmpty)

        // The host uninstalled the workspace: the removal is on record, also across a relaunch.
        await remote.removeFacadeFixtureWorkspace(fixture.remote.id)
        #expect(remote.workspaces.isEmpty && remote.removedWorkspaceIDs == [fixture.remote.id])
        #expect(RemoteWorkspacesModel(defaults: fixture.defaults, backendProjection: false).removedWorkspaceIDs == [fixture.remote.id])
        #expect(try await row(linuxID)?.deleted == false)

        try await host.refreshExecutionRegistry()
        let gone = try #require(try await row(linuxID))
        #expect(gone.deleted && gone.revision == registered.revision + 1 && gone.ownerDeviceID == identity.hostDeviceID)
        #expect(gone.name == registered.name && gone.kind == .linux)
        #expect(remote.removedWorkspaceIDs.isEmpty)
        #expect(RemoteWorkspacesModel(defaults: fixture.defaults, backendProjection: false).removedWorkspaceIDs.isEmpty)
        #expect(try await row(unconfigured.id)?.deleted == false)
        #expect(try await row(theirs.id)?.deleted == false)
        // The library host's list, which Settings reads, drops it too.
        #expect(host.executionWorkspaces.first { $0.id == linuxID }?.isVisibleInConnections == false)

        // Nothing more is written, and the identity does not come back: not by
        // a refresh, and not for a configuration under the old ID.
        let head = try await database.peerSyncHead()
        for _ in 0..<3 { try await host.refreshExecutionRegistry() }
        #expect(try await database.peerSyncHead() == head)
        #expect(try await row(linuxID) == gone)
        let status = try JSONDecoder().decode(RemoteWorkspaceStatus.self, from: Data(#"{"id":"fixture","name":"Fixture","state":"running","running":true,"startedAt":"","hostPort":7337,"hostStorageLow":false}"#.utf8))
        remote.configureFacadeFixture(fixture.remote, status: status, harnesses: [], maintenance: [])
        try await host.refreshExecutionRegistry()
        #expect(try await row(linuxID) == gone)
        // The same machine set up again is a new configuration, so a new row beside the deleted one.
        let again = RemoteWorkspaceConfiguration(name: fixture.remote.name, workspaceID: "fixture", hostName: fixture.remote.hostName,
            dataRoot: "/home/.local/share/wovenmatter", workspaceRoot: "/home/.woven-matter")
        #expect(again.id != fixture.remote.id)
        remote.configureFacadeFixture(again, status: status, harnesses: [], maintenance: [])
        try await host.refreshExecutionRegistry()
        let fresh = try #require(try await row(again.id.uuidString.lowercased()))
        #expect(!fresh.deleted && fresh.revision == 1 && fresh.name == fixture.remote.name)
        #expect(try await row(linuxID) == gone)

        // What this Mac then lists: the host as set up again and the other
        // Mac's, never the deleted row or the one it holds no configuration for.
        await fixture.model.refreshWorkspace()
        let listed = RemoteWorkspaceSidebarModel.listing(configurations: remote.workspaces, readyTargets: [],
            registry: fixture.model.executionWorkspaceRegistry, activeDeviceIDs: [], nameOverrides: [:],
            localHostDeviceID: identity.hostDeviceID, localFolderOwnerID: nil, agents: [], peerAgentIDs: [], folders: [])
        #expect(Set(listed.links.map(\.id)) == [again.id.uuidString.lowercased(), theirs.id])
    }

    /// Another device's Dev instance is listed only while that device is
    /// active, as Settings lists connections: one that quit without
    /// withdrawing its row drops out of the sidebar and New Chat too.
    /// Production Macs are listed whether or not they are online, also while
    /// this Mac shares nothing and so sees no device as active. This Mac's
    /// own live Dev row has this Mac's host ID under another registry ID and
    /// is never a remote workspace.
    @Test func anotherDevicesDevInstanceIsListedOnlyWhileThatDeviceIsActive() throws {
        let fleet = Fleet()
        let devHost = "dev-snapshot-host"
        var dev = fleet.other; dev.id = UUID().uuidString.lowercased(); dev.ownerDeviceID = devHost; dev.developmentInstance = "pairing"
        dev.name = "James’s Mac mini (Dev) · pairing"; dev.folderOwnerID = "device:" + UUID().uuidString.lowercased()
        var ownLiveDev = fleet.own; ownLiveDev.id = UUID().uuidString.lowercased(); ownLiveDev.developmentInstance = "live"
        var ownLiveDevUnnamed = ownLiveDev; ownLiveDevUnnamed.id = UUID().uuidString.lowercased(); ownLiveDevUnnamed.folderOwnerID = nil
        let registry = fleet.registry + [dev, ownLiveDev, ownLiveDevUnnamed]
        let devAgent = remoteAgent(.codex, on: dev.id), bound = try folders([("dev-folder", dev.folderOwnerID)])
        func listing(_ active: Set<String>) -> RemoteWorkspaceListing {
            fleet.listing(registry: registry, active: active, agents: [devAgent], peers: [devAgent.id], folders: bound)
        }
        let production = fleet.links().map(\.id)

        let running = listing([devHost])
        #expect(running.links.map(\.title) == ["build-box", "jamess-mac-mini", "jamess-mac-mini (Dev) · pairing", "workstation"])
        #expect(running.folders[dev.id]?.map(\.id) == ["dev-folder"] && running.unavailableFolderOwnerIDs.isEmpty)
        #expect(NewChatWorkspaceGroup.resolve(listing: running, folderOwnerID: nil).map(\.id) == [dev.id])

        // It quit without withdrawing: its row still has its address, and it is not listed.
        for active in [Set<String>(), ["someone-else"]] {
            let quit = listing(active)
            #expect(quit.links.map(\.id) == production)
            #expect(quit.choices[dev.id] == nil && NewChatWorkspaceGroup.resolve(listing: quit, folderOwnerID: nil).isEmpty)
            #expect(quit.unavailableFolderOwnerIDs == [try #require(dev.folderOwnerID)])
            // Settings lists the same rows: the two agree on everything this Mac did not set up.
            let shared = RemoteWorkspaceSidebarModel.sharedWorkspaces(quit.registry, configured: [fleet.configuredRow.id], localHostDeviceID: fleet.hostID)
            #expect(Set(shared.filter { $0.kind != .ios }.map(\.id)) == Set(quit.links.filter { $0.configuration == nil }.map(\.id)))
        }
        // The store's projection, which the library host hands Settings, is this same rule.
        #expect(ExecutionWorkspace.connections(registry, hostDeviceID: fleet.hostID, activeDeviceIDs: []).first { $0.id == dev.id }?.endpoint == nil)
        #expect(ExecutionWorkspace.connections(registry, hostDeviceID: fleet.hostID, activeDeviceIDs: [devHost]) == registry)
        // This Mac's own Dev rows keep their address and are still never listed,
        // by host ID, and before it is known because nothing says they are another Mac's.
        #expect(ExecutionWorkspace.connections(registry, hostDeviceID: fleet.hostID, activeDeviceIDs: []).first { $0.id == ownLiveDev.id }?.endpoint != nil)
        for hostID in [String?.some(fleet.hostID), nil] {
            let links = fleet.links(registry: ExecutionWorkspace.connections(registry, hostDeviceID: hostID, activeDeviceIDs: [devHost, fleet.hostID]),
                                    hostID: .some(hostID))
            #expect(!links.contains { [fleet.own.id, ownLiveDev.id, ownLiveDevUnnamed.id].contains($0.id) })
            #expect(links.contains { $0.id == fleet.other.id })
        }
    }

    /// Real placement beside the list: a Mac with a production row that has
    /// no address and a withdrawn Dev row, in either registry order, has its
    /// agents (`agentPlacements`), its folders and its one listed section all
    /// on the production row, titled by its tailnet machine name through the
    /// route this library keeps. Its agents leave with a deleted Linux row.
    @Test(arguments: [true, false])
    func aMacsAgentsAndFoldersLandInItsOneListedSection(devRowFirst: Bool) async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let database = fixture.database, identity = try await database.libraryIdentity()
        try await fixture.model.libraryHost.refreshExecutionRegistry()
        let otherHost = UUID().uuidString.lowercased(), otherFolderOwner = "device:" + UUID().uuidString.lowercased()
        // The registry is read in ID order, so the IDs decide which row comes first.
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()].sorted()
        let devID = devRowFirst ? ids[0] : ids[1], productionID = devRowFirst ? ids[1] : ids[0]
        func register(_ workspace: ExecutionWorkspace) async throws {
            _ = try await database.registerExecutionWorkspace(.init(workspace: workspace), deviceID: identity.hostDeviceID)
        }
        try await register(.init(id: productionID, libraryID: identity.libraryID, ownerDeviceID: otherHost, kind: .mac, name: "James’s Mac mini",
            capabilities: [], executionDeviceID: otherHost, folderOwnerID: otherFolderOwner))
        try await register(.init(id: devID, libraryID: identity.libraryID, ownerDeviceID: otherHost, kind: .mac, name: "James’s Mac mini (Dev) · pairing",
            capabilities: [], executionDeviceID: otherHost, developmentInstance: "pairing", folderOwnerID: otherFolderOwner))
        try await database.saveMacRoute(.init(deviceID: otherHost, libraryID: UUID().uuidString.lowercased(),
            endpoint: try #require(URL(string: "https://jamess-mac-mini.tail1234.ts.net:8443/wovenmatter")), name: "James’s Mac mini"))

        // The other Mac's own agent, and its agent for a Linux host it set up, as synchronization delivers them.
        _ = try #require(await fixture.model.createLocalACPSession(runtimeKind: .codex))
        let macAgent = try #require(try await database.workspaceAgents().first { $0.executionLocation == .local && $0.runtimeKind == .codex })
        let linuxID = UUID()
        try await register(.init(id: linuxID.uuidString.lowercased(), libraryID: identity.libraryID, ownerDeviceID: otherHost, kind: .linux, name: "build-box",
            executionDeviceID: UUID().uuidString.lowercased()))
        let linuxAgent = try await database.ensureRemoteHarnessAgent(runtimeKind: .codex, remoteWorkspaceID: linuxID,
            remoteWorkspaceName: "build-box", ownerDeviceID: UUID())
        try await database.write { connection in
            try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=1")
            for id in [macAgent.id, linuxAgent] {
                try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO agent_owners VALUES(?,?)", [id.uuidString.lowercased(), otherHost])
            }
            try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=0")
        }
        let folder = try await database.createFolder(name: "Theirs", location: .init(workspaceID: otherFolderOwner, rootPath: "/Volumes/Other/.woven-matter/Theirs", managed: false))
        await fixture.model.refreshWorkspace()

        let registry = try await database.libraryExecutionWorkspaces()
        #expect(registry.filter { $0.ownerDeviceID == otherHost && $0.kind == .mac }.map(\.id) == ids)
        let placements = try await database.agentPlacements()
        #expect(placements.workspaces[macAgent.id]?.id == productionID && placements.workspaces[linuxAgent]?.id == linuxID.uuidString.lowercased())
        #expect(ExecutionWorkspace.macWorkspace(ownedBy: otherHost, in: registry)?.id == productionID)
        #expect(RemoteWorkspaceSidebarModel.workspaceID(ofFolderOwner: otherFolderOwner, in: registry) == productionID)

        // What the window lists from the model, exactly as it builds it.
        let model = fixture.model
        #expect(model.pairedMacAddresses[otherHost]?.host == "jamess-mac-mini.tail1234.ts.net")
        func listing() -> RemoteWorkspaceListing {
            RemoteWorkspaceSidebarModel.listing(configurations: model.remoteWorkspaces.workspaces, readyTargets: [],
                registry: model.executionWorkspaceRegistry, activeDeviceIDs: [], nameOverrides: model.workspaceNameOverrides,
                macAddresses: model.pairedMacAddresses, localHostDeviceID: identity.hostDeviceID, localFolderOwnerID: nil,
                agents: model.remoteWorkspaceAgents, peerAgentIDs: Set(model.peerAgentWorkspaces.keys), folders: model.workspaceOverview?.folders ?? [])
        }
        let listed = listing()
        let section = try #require(listed.links.first { $0.id == productionID })
        #expect(listed.links.filter { $0.kind == .mac }.map(\.id) == [productionID], "one section for the Mac, never its Dev row or this Mac")
        let sectionRow = try #require(section.workspace)
        #expect(section.title == "jamess-mac-mini" && model.workspaceDisplayName(sectionRow) == "jamess-mac-mini")
        #expect(listed.choices[productionID]?.compactMap { $0.agent?.id } == [macAgent.id])
        #expect(listed.folders[productionID]?.map(\.id) == [folder] && listed.unavailableFolderOwnerIDs.isEmpty)
        #expect(listed.choices[devID] == nil && listed.folders[devID] == nil)
        #expect(listed.choices[linuxID.uuidString.lowercased()]?.compactMap { $0.agent?.id } == [linuxAgent])
        // The Mac cannot be asked for a folder: its row lists no folder capability.
        #expect(RemoteFolderCreation.problem(for: section) == "Update Woven Matter on jamess-mac-mini to create folders there.")

        // Its Linux host is uninstalled: the deleted row places no agent and lists no section.
        var linuxRow = try #require(registry.first { $0.id == linuxID.uuidString.lowercased() })
        let revision = linuxRow.revision
        linuxRow.deleted = true
        _ = try await database.registerExecutionWorkspace(.init(workspace: linuxRow, expectedRevision: revision), deviceID: identity.hostDeviceID)
        await model.refreshWorkspace()
        #expect(try await database.agentPlacements().workspaces[linuxAgent] == nil)
        #expect(!model.remoteWorkspaceAgents.contains { $0.id == linuxAgent })
        #expect(listing().links.filter { $0.configuration == nil }.map(\.id) == [productionID])
    }

    /// The form's New folder for a workspace whose owner creates it says why
    /// it cannot be asked, before Create, in the title the sidebar shows.
    @Test func newFolderSaysWhyAnotherMachineCannotTakeOne() throws {
        let fleet = Fleet()
        func problem(_ row: ExecutionWorkspace, names: [String: String] = [:]) throws -> String? {
            let registry = fleet.registry.filter { $0.id != row.id } + [row]
            return RemoteFolderCreation.problem(for: try #require(fleet.links(registry: registry, names: names).first { $0.id == row.id }))
        }
        // A Mac that has not updated lists no folder capability.
        #expect(try problem(fleet.other) == "Update Woven Matter on jamess-mac-mini to create folders there.")
        #expect(try problem(fleet.other, names: [fleet.other.id: "Studio"]) == "Update Woven Matter on Studio to create folders there.")
        var current = fleet.other; current.capabilities = [LibraryWorkspaceAction.createFolderCapability]
        #expect(try problem(current) == nil)
        current.endpoint = nil
        #expect(try problem(current) == "Connect this workspace before creating a folder.")
        // A Linux host another Mac set up needs only an address: any member administers it.
        #expect(try problem(fleet.shared) == "Connect this workspace before creating a folder.")
        var reachable = fleet.shared; reachable.endpoint = URL(string: "https://build-box.tail1234.ts.net/wovenmatter-execution/build")
        #expect(try problem(reachable) == nil)
        // A host set up here reports its own status; nothing is said for it here.
        #expect(try problem(fleet.configuredRow) == nil)
    }

    /// A production Mac's registry row keeps its last address when a refresh
    /// runs while Tailscale is unavailable (a rename made then), so the other
    /// devices keep its machine name; nothing is rewritten for it.
    @Test func aRefreshWithoutAnAddressKeepsTheLastOneAMacPublished() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let host = fixture.model.libraryHost, database = fixture.database
        try await host.refreshExecutionRegistry()
        let identity = try await database.libraryIdentity()
        func own() async throws -> ExecutionWorkspace {
            try #require(try await database.libraryExecutionWorkspaces().first { $0.kind == .mac && $0.ownerDeviceID == identity.hostDeviceID })
        }
        var published = try await own()
        #expect(published.endpoint == nil && host.endpoint == nil)
        // As this Mac published it while it was sharing.
        let revision = published.revision
        published.endpoint = URL(string: "https://this-mac.tail1234.ts.net:8443/wovenmatter")
        let sharing = try await database.registerExecutionWorkspace(.init(workspace: published, expectedRevision: revision), deviceID: identity.hostDeviceID)
        let head = try await database.peerSyncHead()
        for _ in 0..<2 { try await host.refreshExecutionRegistry() }
        #expect(try await own() == sharing)
        #expect(try await database.peerSyncHead() == head)
        #expect(await fixture.model.renameWorkspace(registryID: sharing.id, name: "Studio"))
        try await host.refreshExecutionRegistry()
        let renamed = try await own()
        #expect(renamed.name == "Studio" && renamed.endpoint == sharing.endpoint && renamed.revision == sharing.revision + 1)
    }

    /// A live Dev build shares its Mac's library host and keeps its address
    /// when it quits without withdrawing. That row must not take the Mac's
    /// agents or folders from its production row, whichever the registry
    /// reads first.
    @Test(arguments: [true, false])
    func aMacsProductionRowComesBeforeADevRowThatKeptItsAddress(devRowFirst: Bool) throws {
        let host = UUID().uuidString.lowercased(), folderOwner = "device:" + UUID().uuidString.lowercased()
        let ids = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()].sorted()
        let devID = devRowFirst ? ids[0] : ids[1], productionID = devRowFirst ? ids[1] : ids[0]
        func row(_ id: String, endpoint: String?, instance: String?) throws -> ExecutionWorkspace {
            .init(id: id, libraryID: "library", ownerDeviceID: host, kind: .mac, name: "James’s Mac mini",
                  endpoint: try endpoint.map { try #require(URL(string: $0)) }, capabilities: [], executionDeviceID: host,
                  developmentInstance: instance, folderOwnerID: folderOwner)
        }
        func ordered(_ rows: [ExecutionWorkspace]) -> [ExecutionWorkspace] { rows.sorted { $0.id < $1.id } }
        let production = try row(productionID, endpoint: "https://jamess-mac-mini.tail1234.ts.net:8443/wovenmatter", instance: nil)
        let dev = try row(devID, endpoint: "https://jamess-mac-mini.tail1234.ts.net:10000/wovenmatter", instance: "live")
        let both = ordered([production, dev])
        #expect(ExecutionWorkspace.macWorkspace(ownedBy: host, in: both)?.id == productionID)
        #expect(RemoteWorkspaceSidebarModel.workspaceID(ofFolderOwner: folderOwner, in: both) == productionID)

        // Without an address the production row still stands for the Mac, before a Dev row that has one or not.
        let quiet = try row(productionID, endpoint: nil, instance: nil)
        #expect(ExecutionWorkspace.macWorkspace(ownedBy: host, in: ordered([quiet, try row(devID, endpoint: nil, instance: "live")]))?.id == productionID)
        // A Dev instance that is running is the only row with an address: it is where that Mac answers now.
        #expect(ExecutionWorkspace.macWorkspace(ownedBy: host, in: ordered([quiet, dev]))?.id == devID)
        #expect(ExecutionWorkspace.preferred(among: []) == nil)
    }

    /// Paired Macs' agents share a codename. A chat that names an agent this
    /// Mac does not list (the other Mac's, before its owner record arrives or
    /// while that Mac has not updated) is not given this Mac's agent of that
    /// codename; only a chat that names no agent is found by codename.
    @Test func aChatThatNamesAnUnlistedAgentIsNotGivenThisMacsAgentOfThatCodename() throws {
        let mine = WorkspaceAgent(codename: "codex", displayName: "Codex", iconKey: "codex", executionLocation: .local, runtimeKind: .codex)
        let byID = [mine.id.uuidString.lowercased(): mine], byCodename = [mine.codename: mine]
        func chat(agentID: String?) throws -> WorkspaceConversationRecord {
            var fields: [String: Any] = ["id": UUID().uuidString.lowercased(), "agent_codename": "codex", "title": "Chat",
                                         "unread": 0, "is_pinned": 0, "is_archived": 0]
            if let agentID { fields["agent_id"] = agentID }
            return try JSONDecoder().decode(WorkspaceConversationRecord.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        #expect(ConversationListMeta.agent(for: try chat(agentID: mine.id.uuidString.lowercased()), byID: byID, byCodename: byCodename)?.id == mine.id)
        let theirs = try chat(agentID: UUID().uuidString.lowercased())
        #expect(ConversationListMeta.agent(for: theirs, byID: byID, byCodename: byCodename) == nil)
        #expect(ConversationListMeta.agent(for: try chat(agentID: nil), byID: byID, byCodename: byCodename)?.id == mine.id)
    }
}

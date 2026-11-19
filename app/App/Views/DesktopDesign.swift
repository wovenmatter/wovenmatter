import SwiftUI
import WovenMatterClient
import WovenMatterCore
import WovenMatterLibraryStore

/// Settings saved under an earlier name move to their current one, once, at
/// launch. Through v0.4.2 the window, sidebar and theme settings were saved
/// under "wovenmatter.dashboard." keys; through v0.4.6 the Linux hosts, Mac
/// access, session choices, built-in agent settings, local model servers and
/// the pending update receipt were saved under names ending in a number. The
/// left side names stored data and appears nowhere else.
///
/// The window and the background server share one defaults domain and both
/// run this before reading anything. Each move writes the value that is
/// already stored, so two processes moving at once store the same thing.
enum WindowPreferenceUpgrade {
    static let renamedKeys: [String: String] = [
        "wovenmatter.remote-workspaces.v1": RemoteWorkspacesModel.storageKey,
        "wovenmatter.remote-workspaces.removed.v1": RemoteWorkspacesModel.removedKey,
        "wovenmatter.mac-access.v1": MacAccessSetupModel.storageKey,
        "wovenmatter.session-selections.v1": SessionSelectionPreferences.storageKey,
        "wovenmatter.analytics.pending-update.v1": ProductAnalyticsModel.updateReceiptKey,
        "wovenmatter.default-agent.settings.v1": DefaultAgentSupport.settingsKey,
        "wovenmatter.connections.local-servers.v1": LocalModelServerStore.storageKey,
        "wovenmatter.dashboard.theme": WovenTheme.storageKey,
        "wovenmatter.dashboard.sidebar-style": SidebarStyle.storageKey,
        "wovenmatter.dashboard.single-sidebar-side": SidebarSide.storageKey,
        "wovenmatter.dashboard.left-rail": "wovenmatter.layout.left-rail",
        "wovenmatter.dashboard.right-rail": "wovenmatter.layout.right-rail",
        "wovenmatter.dashboard.single-rail": "wovenmatter.layout.single-rail",
        "wovenmatter.dashboard.chat-width-percent": "wovenmatter.layout.chat-width-percent",
        "wovenmatter.dashboard.note-on-left": "wovenmatter.layout.note-on-left",
        "wovenmatter.dashboard.workspace-mode": "wovenmatter.layout.workspace-mode",
        "wovenmatter.dashboard.show-localWorkspace": WorkspaceSidebarVisibility.localWorkspace.storageKey,
        "wovenmatter.dashboard.show-remoteWorkspaces": WorkspaceSidebarVisibility.remoteWorkspaces.storageKey,
        "wovenmatter.dashboard.collapsed-agent-sections": AgentDisclosureStore.storageKey,
        "wovenmatter.dashboard.agent-order-by-group": AgentOrderStore.storageKey,
        "wovenmatter.dashboard.pinned-agent-ids": PinnedAgentsStore.storageKey,
        "wovenmatter.dashboard.bots.expanded-threads": BotThreadDisclosure.storageKey,
    ]

    static func moveRenamedKeys(in defaults: UserDefaults) {
        for (legacy, current) in renamedKeys {
            guard let value = defaults.object(forKey: legacy) else { continue }
            if defaults.object(forKey: current) == nil { defaults.set(value, forKey: current) }
            defaults.removeObject(forKey: legacy)
        }
        // A cache is read again, not moved.
        for key in defaults.dictionaryRepresentation().keys where removedCachePrefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Cached display data saved under an earlier name.
    static let removedCachePrefixes = ["wovenmatter.built-in.enabled-metadata.v2."]
}

enum NewChatSource: String, CaseIterable, Identifiable {
    case acpDirect
    case remoteWorkspace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .acpDirect: "Local workspace agents"
        case .remoteWorkspace: "Remote workspace agents"
        }
    }
}

/// Left-rail agent groupings for Woven Matter's product terminology.
/// Each agent's `AgentBucket` follows its execution location.
enum AgentSidebarGroup: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pinned
    case localWorkspace
    case remoteWorkspaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pinned: "Pinned"
        case .localWorkspace: "Local workspace"
        case .remoteWorkspaces: "Remote workspaces"
        }
    }

    var orderKey: String { rawValue }

    static func contains(
        _ agent: WorkspaceAgent,
        in group: AgentSidebarGroup,
        pinnedIDs: Set<UUID>
    ) -> Bool {
        switch group {
        case .pinned:
            return pinnedIDs.contains(agent.id)
        case .localWorkspace:
            return agent.bucket == .localCLIAgents
                && !pinnedIDs.contains(agent.id)
        case .remoteWorkspaces:
            return agent.bucket == .remoteWorkspaceAgents
                && !pinnedIDs.contains(agent.id)
        }
    }

    static func agents(
        from agents: [WorkspaceAgent],
        in group: AgentSidebarGroup,
        pinnedIDs: Set<UUID>,
        customOrder: [UUID] = []
    ) -> [WorkspaceAgent] {
        switch group {
        case .pinned:
            return applyOrder(
                agents.filter { contains($0, in: .pinned, pinnedIDs: pinnedIDs) },
                preferred: customOrder
            )
        case .localWorkspace:
            let defaultOrder = agents
                .filter { contains($0, in: group, pinnedIDs: pinnedIDs) }
                .sorted { lhs, rhs in
                    if lhs.runtimeKind != rhs.runtimeKind {
                        return lhs.runtimeKind.presentationRank
                            < rhs.runtimeKind.presentationRank
                    }
                    let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
                        rhs.displayName
                    )
                    if comparison != .orderedSame { return comparison == .orderedAscending }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            return applyPreferredOrder(defaultOrder, preferred: customOrder)
        case .remoteWorkspaces:
            let defaultOrder = agents
                .filter { contains($0, in: group, pinnedIDs: pinnedIDs) }
                .sorted { lhs, rhs in
                    if lhs.runtimeKind != rhs.runtimeKind {
                        return lhs.runtimeKind.presentationRank
                            < rhs.runtimeKind.presentationRank
                    }
                    if lhs.displayName != rhs.displayName {
                        return lhs.displayName.localizedCaseInsensitiveCompare(
                            rhs.displayName
                        ) == .orderedAscending
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            return applyPreferredOrder(defaultOrder, preferred: customOrder)
        }
    }

    /// Stable display order: preferred IDs first (when present), then name-sorted remainder.
    static func applyOrder(
        _ agents: [WorkspaceAgent],
        preferred: [UUID]
    ) -> [WorkspaceAgent] {
        guard !agents.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var ordered: [WorkspaceAgent] = []
        for id in preferred {
            guard let agent = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(agent)
        }
        let remaining = agents
            .filter { seen.insert($0.id).inserted }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        return ordered + remaining
    }

    /// Applies preferred IDs while retaining the caller's fallback ordering.
    static func applyPreferredOrder(
        _ agents: [WorkspaceAgent],
        preferred: [UUID]
    ) -> [WorkspaceAgent] {
        guard !agents.isEmpty, !preferred.isEmpty else { return agents }
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        var seen = Set<UUID>()
        let preferredAgents = preferred.compactMap { id -> WorkspaceAgent? in
            guard let agent = byID[id], seen.insert(id).inserted else { return nil }
            return agent
        }
        return preferredAgents + agents.filter { seen.insert($0.id).inserted }
    }
}

/// Another machine's workspace: a paired Mac, or a Linux host, whichever Mac
/// set it up. Listed whether or not it is online.
struct RemoteWorkspaceSidebarLink: Equatable, Identifiable {
    /// The registry ID (`ExecutionWorkspace.id`), a lowercased UUID. A Linux
    /// host this Mac set up has its configuration's ID.
    let id: String
    let kind: ExecutionWorkspace.Kind
    let title: String
    /// True when someone chose the title; false when it is the default name.
    let hasChosenName: Bool
    /// The synced registry row. Nil for a host set up here that has not registered yet.
    let workspace: ExecutionWorkspace?
    /// Set for a Linux host this Mac set up: it has status, SSH and a browser here.
    let configuration: RemoteWorkspaceConfiguration?
    let readyTargets: [RemoteHarnessChatTarget]
    /// What this workspace's folders name as their owner: `remote:<id>` for a
    /// Linux host, the registry row's `folderOwnerID` for a Mac.
    let folderOwnerID: String?
}

/// The agent that stands for one harness on a remote workspace, wherever the
/// workspace's agents are shown or started: the sidebar's rows and their "+",
/// New Chat, and the row a chat highlights. Decided in one place
/// (`RemoteWorkspaceSidebarModel.choices`).
struct RemoteWorkspaceAgentChoice: Equatable, Identifiable {
    let runtimeKind: AgentRuntimeKind
    /// The saved agent listed for the harness. Nil only while this Mac has
    /// the harness ready on a host it set up and has not saved its agent yet.
    let agent: WorkspaceAgent?
    /// This Mac's ready harness on a Linux host it set up. Set exactly when
    /// the harness is this Mac's own to start (`createRemoteACPSession`).
    let target: RemoteHarnessChatTarget?
    /// The listed agent is another member's (`createPairedMacSession`).
    let isPeer: Bool
    /// Every saved agent for this workspace and harness: the listed one and
    /// the ones it stands for. Their chats are all this row's chats.
    let agentIDs: Set<UUID>
    var id: String { runtimeKind.rawValue }
}

/// Why another machine cannot be asked for a new folder now. The messages
/// name the workspace by its title, as the sidebar does.
enum RemoteFolderCreation {
    /// Nil when the workspace can be asked. Only for a workspace whose owner
    /// creates the folder: another Mac, or a Linux host this Mac did not set
    /// up. A Mac takes a folder request only when its registry row lists the
    /// capability (`LibraryWorkspaceAction.createFolderCapability`); the
    /// client refuses the same way if asked anyway
    /// (`MemberExecutionClient.createFolder`). A Linux host needs only
    /// an address: any member administers it by signed request.
    static func problem(for link: RemoteWorkspaceSidebarLink) -> String? {
        guard link.configuration == nil else { return nil }
        if link.kind == .mac, link.workspace?.capabilities.contains(LibraryWorkspaceAction.createFolderCapability) != true {
            return "Update Woven Matter on \(link.title) to create folders there."
        }
        return link.workspace?.endpoint == nil ? "Connect this workspace before creating a folder." : nil
    }
}

/// Everything listed under Remote workspaces, built once for a render and
/// shared by the sidebar and New Chat so they cannot disagree: the links, the
/// registry they were built from, and each link's agents and folders.
struct RemoteWorkspaceListing {
    var links: [RemoteWorkspaceSidebarLink] = []
    /// The registry as connections are listed (`ExecutionWorkspace.connections`).
    var registry: [ExecutionWorkspace] = []
    /// By link ID.
    var choices: [String: [RemoteWorkspaceAgentChoice]] = [:]
    var folders: [String: [WorkspaceFolderRecord]] = [:]
    /// Folder owners with no listed workspace: not this Mac, not a remote
    /// workspace, and not a paired iPhone or iPad.
    var unavailableFolderOwnerIDs: [String] = []

    /// The choice that stands for a saved remote agent: the one of its
    /// workspace and harness. Nil for an agent on no listed workspace.
    func choice(for agent: WorkspaceAgent) -> RemoteWorkspaceAgentChoice? {
        guard agent.executionLocation == .remote, let id = agent.runtimeDeviceID?.uuidString.lowercased() else { return nil }
        return choices[id]?.first { $0.runtimeKind == agent.runtimeKind && $0.agentIDs.contains(agent.id) }
    }

    func choice(for target: RemoteHarnessChatTarget) -> RemoteWorkspaceAgentChoice? {
        choices[target.configuration.id.uuidString.lowercased()]?.first { $0.runtimeKind == target.harness.id }
    }

    /// The row a chat of `agent` highlights: the agent listed for its
    /// workspace and harness, which is not always the one that holds the chat
    /// (two Macs can each keep an agent for one Linux host and harness). An
    /// agent outside the remote list, a local one for instance, is its own.
    func listedAgentID(for agent: WorkspaceAgent) -> UUID? {
        guard agent.executionLocation == .remote else { return agent.id }
        guard let choice = choice(for: agent) else { return agent.id }
        return choice.agent?.id
    }

    /// The agents whose chats a listed agent's row holds: its own and those
    /// of the agents it stands for.
    func representedAgentIDs(by agent: WorkspaceAgent) -> Set<UUID> {
        guard let choice = choice(for: agent), choice.agent?.id == agent.id else { return [agent.id] }
        return choice.agentIDs
    }
}

enum RemoteWorkspaceSidebarModel {
    /// Every other machine's workspace as one list: the Linux hosts this Mac
    /// set up, merged with the registry's Macs and Linux hosts. A registry row
    /// is listed while it is visible in connections, so an offline Mac stays
    /// and a retained snapshot owner or a stopped Dev connection does not.
    /// Pass the registry as connections list it (`ExecutionWorkspace.connections`),
    /// so a Dev instance that quit without withdrawing is hidden here as in
    /// Settings.
    ///
    /// This Mac's own row is the Local workspace. A Mac row is listed only
    /// when it is known not to be this Mac's: its owner is not this library's
    /// host, and its folder owner is not this Mac's. With the host ID unknown
    /// a row that names no folder owner cannot be told from this Mac's, so it
    /// is not listed, and with neither known no Mac is.
    ///
    /// A Linux row this Mac owns belongs to a host it set up. One it holds no
    /// configuration for was removed here, so it is not listed: its row is
    /// marked deleted for everyone once the removal is published
    /// (`LibraryHostController.withdrawRemovedLinuxWorkspaces`), and a row
    /// removed before that existed stays in the registry. So a Linux row
    /// without a configuration here is listed only once its owner is known
    /// to be another Mac, which takes this library's host ID.
    static func links(
        configurations: [RemoteWorkspaceConfiguration],
        readyTargets: [RemoteHarnessChatTarget],
        registry: [ExecutionWorkspace],
        nameOverrides: [String: String],
        macAddresses: [String: URL] = [:],
        localHostDeviceID: String?,
        localFolderOwnerID: String?
    ) -> [RemoteWorkspaceSidebarLink] {
        let targetsByWorkspaceID = Dictionary(grouping: readyTargets, by: { $0.configuration.id })
        var rows: [String: ExecutionWorkspace] = [:]
        for row in registry where row.isVisibleInConnections && row.kind != .ios {
            let id = ExecutionWorkspace.displayID(row.id)
            if rows[id] == nil { rows[id] = row }
        }
        var links = configurations.map { configuration -> RemoteWorkspaceSidebarLink in
            let id = configuration.id.uuidString.lowercased()
            return RemoteWorkspaceSidebarLink(
                id: id, kind: .linux, title: ApplicationModel.workspaceDisplayName(configuration, overrides: nameOverrides),
                hasChosenName: nameOverrides[id] != nil,
                workspace: rows[id].flatMap { $0.kind == .linux ? $0 : nil }, configuration: configuration,
                readyTargets: (targetsByWorkspaceID[configuration.id] ?? [])
                    .sorted { $0.harness.id.presentationRank < $1.harness.id.presentationRank },
                folderOwnerID: "remote:" + id)
        }
        let configured = Set(links.map(\.id))
        let localOwner = localFolderOwnerID.map(ExecutionWorkspace.displayID)
        for (id, row) in rows where !configured.contains(id) {
            switch row.kind {
            case .mac:
                let owner = row.folderOwnerID.map(ExecutionWorkspace.displayID)
                if let localHostDeviceID {
                    guard row.ownerDeviceID != localHostDeviceID, localOwner == nil || owner != localOwner else { continue }
                } else {
                    guard let localOwner, let owner, owner != localOwner else { continue }
                }
            case .linux:
                guard let localHostDeviceID, row.ownerDeviceID != localHostDeviceID else { continue }
            case .ios: continue
            }
            links.append(RemoteWorkspaceSidebarLink(
                id: id, kind: row.kind, title: ApplicationModel.workspaceDisplayName(row, overrides: nameOverrides, macAddresses: macAddresses),
                hasChosenName: nameOverrides[id] != nil, workspace: row, configuration: nil, readyTargets: [],
                folderOwnerID: row.kind == .mac ? row.folderOwnerID : "remote:" + id))
        }
        return links.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// Settings → Workspaces, "From other devices": the listed registry rows
    /// this Mac did not add, by the rule `links` uses. An iPhone or iPad is
    /// always another device. A Mac or Linux row is one only once its owner
    /// is known to be another Mac, so neither this Mac's own row nor a Linux
    /// host it removed is offered as someone else's. `registry` is the
    /// library host's, which already lists connections.
    static func sharedWorkspaces(_ registry: [ExecutionWorkspace], configured: Set<String>,
                                 localHostDeviceID: String?) -> [ExecutionWorkspace] {
        registry.filter { row in
            guard row.isVisibleInConnections, !configured.contains(row.id) else { return false }
            if row.kind == .ios { return true }
            guard let localHostDeviceID else { return false }
            return row.ownerDeviceID != localHostDeviceID
        }
    }

    /// The links with everything listed under them. `registry` is the stored
    /// registry; the listing keeps the projection every part of it uses.
    /// Each folder owner is mapped to its workspace once, however many
    /// folders name it.
    static func listing(
        configurations: [RemoteWorkspaceConfiguration], readyTargets: [RemoteHarnessChatTarget],
        registry: [ExecutionWorkspace], activeDeviceIDs: Set<String>,
        nameOverrides: [String: String], macAddresses: [String: URL] = [:],
        localHostDeviceID: String?, localFolderOwnerID: String?,
        agents: [WorkspaceAgent], peerAgentIDs: Set<UUID>, folders: [WorkspaceFolderRecord]
    ) -> RemoteWorkspaceListing {
        let registry = ExecutionWorkspace.connections(registry, hostDeviceID: localHostDeviceID, activeDeviceIDs: activeDeviceIDs)
        let links = links(configurations: configurations, readyTargets: readyTargets, registry: registry, nameOverrides: nameOverrides,
                          macAddresses: macAddresses, localHostDeviceID: localHostDeviceID, localFolderOwnerID: localFolderOwnerID)
        let listed = Set(links.map(\.id) + PairedWorkspaceSidebarModel.workspaces(registry).map { ExecutionWorkspace.displayID($0.id) })
        var workspaceIDs: [String: String] = [:], byLink: [String: [WorkspaceFolderRecord]] = [:], unavailable = Set<String>()
        for folder in folders {
            guard let owner = folder.executionWorkspaceID, !owner.isEmpty else { continue }
            let workspace = workspaceIDs[owner] ?? workspaceID(ofFolderOwner: owner, in: registry)
            workspaceIDs[owner] = workspace
            byLink[workspace, default: []].append(folder)
            if owner != localFolderOwnerID, !listed.contains(workspace) { unavailable.insert(owner) }
        }
        let linkIDs = Set(links.map(\.id))
        return RemoteWorkspaceListing(
            links: links, registry: registry,
            choices: Dictionary(links.map { ($0.id, choices(agents, in: $0, peerAgentIDs: peerAgentIDs)) }, uniquingKeysWith: { first, _ in first }),
            folders: byLink.filter { linkIDs.contains($0.key) }, unavailableFolderOwnerIDs: unavailable.sorted())
    }

    /// The registry ID of the workspace a folder's owner (`device:<id>` or
    /// `remote:<id>`) belongs to. A Mac's registry ID is not its folder owner,
    /// so this goes through the row that names the owner as its `folderOwnerID`
    /// (`ExecutionWorkspace.displayOwner`). A Mac can register more than one
    /// such row (a Dev instance beside it): the listed one holds the folders,
    /// the one devices connect to first, as its agents are placed
    /// (`ExecutionWorkspace.macWorkspace(ownedBy:in:)`).
    static func workspaceID(ofFolderOwner owner: String, in registry: [ExecutionWorkspace]) -> String {
        let id = ExecutionWorkspace.displayID(owner)
        guard !registry.contains(where: { ExecutionWorkspace.displayID($0.id) == id }) else { return id }
        let listed = registry.filter { $0.isVisibleInConnections && $0.folderOwnerID.map(ExecutionWorkspace.displayID) == id }
        if let row = ExecutionWorkspace.preferred(among: listed) { return ExecutionWorkspace.displayID(row.id) }
        return ExecutionWorkspace.displayOwner(of: owner, in: registry) ?? id
    }

    /// The agent that stands for each harness on a remote workspace, one per
    /// harness, in presentation order. Membership is persisted separately
    /// from transient connection and readiness checks. Two Macs can each
    /// hold an agent for the same Linux host and harness, so one is chosen:
    ///
    /// 1. this Mac's own, when this Mac has the harness ready there
    ///    (`link.readyTargets`), also before its agent is saved;
    /// 2. else another member's agent for that workspace and harness;
    /// 3. else this Mac's own, whose "+" then says to connect the workspace.
    ///
    /// Rule 2 is not a detour through the other Mac. A chat started from
    /// another member's agent for a Linux host is created on the host itself
    /// by a request this Mac signs with its own member key
    /// (`createPairedMacSession` sends `createSession` to the workspace the
    /// agent is placed on); the other Mac is not asked and need not be
    /// running. The chat is filed under that member's agent record, so it is
    /// this harness's row that lists and highlights it. Another Mac's own
    /// agents are always its own (no ready target exists for a Mac).
    ///
    /// Among several agents of one kind (duplicates), the lowest ID is the
    /// one, every time, and the choice says which others it stands for.
    static func choices(_ saved: [WorkspaceAgent], in link: RemoteWorkspaceSidebarLink,
                        peerAgentIDs: Set<UUID>) -> [RemoteWorkspaceAgentChoice] {
        let here = Dictionary(grouping: saved.filter { $0.executionLocation == .remote && $0.runtimeDeviceID?.uuidString.lowercased() == link.id },
                              by: \.runtimeKind)
        let targets = Dictionary(link.readyTargets.map { ($0.harness.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(here.keys).union(targets.keys)
            .sorted { ($0.presentationRank, $0.rawValue) < ($1.presentationRank, $1.rawValue) }
            .map { kind in
                let agents = (here[kind] ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
                let own = agents.first { !peerAgentIDs.contains($0.id) }, peer = agents.first { peerAgentIDs.contains($0.id) }
                let ids = Set(agents.map(\.id))
                if let target = targets[kind] {
                    return RemoteWorkspaceAgentChoice(runtimeKind: kind, agent: own, target: target, isPeer: false, agentIDs: ids)
                }
                if let peer { return RemoteWorkspaceAgentChoice(runtimeKind: kind, agent: peer, target: nil, isPeer: true, agentIDs: ids) }
                return RemoteWorkspaceAgentChoice(runtimeKind: kind, agent: own, target: nil, isPeer: false, agentIDs: ids)
            }
    }

    /// Whether "+" beside an agent may start a chat: always with no folder
    /// selected, else only when the selected folder is on the agent's
    /// workspace. `workspaceID` is a remote workspace's registry ID (a remote
    /// agent's `runtimeDeviceID`); nil is this Mac.
    static func canCreateChat(onWorkspace workspaceID: String?, selectedFolderID: String?, folders: [WorkspaceFolderRecord],
                              localFolderOwnerID: String?, registry: [ExecutionWorkspace]) -> Bool {
        guard let selectedFolderID else { return true }
        guard let owner = folders.first(where: { $0.id == selectedFolderID })?.executionWorkspaceID else { return false }
        guard let workspaceID else { return owner == localFolderOwnerID }
        return self.workspaceID(ofFolderOwner: owner, in: registry) == workspaceID
    }
}

/// Paired iPhone and iPad workspaces, derived from the synced execution workspace
/// registry so every Mac lists them, online or not. Quick Chats belong to the
/// workspace that runs them; folders to the workspace they are bound to. Unfiled
/// notes have no owner and stay in All Workspaces, as on the iPhone.
enum PairedWorkspaceSidebarModel {
    /// Folder bindings say `device:<id>` where registry rows say `<id>`; this is
    /// display grouping only and never decides execution ownership.
    static func canonicalID(_ value: String) -> String {
        for prefix in ["device:", "remote:"] where value.hasPrefix(prefix) {
            if let id = UUID(uuidString: String(value.dropFirst(prefix.count))) { return id.uuidString.lowercased() }
        }
        return UUID(uuidString: value)?.uuidString.lowercased() ?? value
    }

    static func workspaces(_ registry: [ExecutionWorkspace]) -> [ExecutionWorkspace] {
        var seen = Set<String>()
        return registry
            .filter { $0.kind == .ios && !$0.deleted && seen.insert(canonicalID($0.id)).inserted }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    /// Quick Chat history this workspace ran, newest first.
    static func history(
        for workspace: ExecutionWorkspace,
        conversations: [WorkspaceConversationRecord],
        owners: [String: String]
    ) -> [WorkspaceConversationRecord] {
        let owner = canonicalID(workspace.id)
        return conversations
            .filter { !$0.isArchived && owners[$0.id].map(canonicalID) == owner }
            .sorted { ($0.lastMessageAt ?? "") > ($1.lastMessageAt ?? "") }
    }

    static func folders(for workspace: ExecutionWorkspace, in folders: [WorkspaceFolderRecord]) -> [WorkspaceFolderRecord] {
        let owner = canonicalID(workspace.id)
        return folders.filter { $0.executionWorkspaceID.map(canonicalID) == owner }
    }

    /// True when the conversation's execution owner is an iPhone or iPad.
    static func isPhoneHistory(owner: String?, registry: [ExecutionWorkspace]) -> Bool {
        guard let owner else { return false }
        let id = canonicalID(owner)
        return registry.contains { $0.kind == .ios && canonicalID($0.id) == id }
    }
}

/// Presentation-only preferences, independent of runtime visibility and section expansion.
enum WorkspaceSidebarVisibility: String {
    case localWorkspace
    case remoteWorkspaces

    var storageKey: String {
        "wovenmatter.sidebar.show-\(rawValue)"
    }

    var title: String {
        switch self {
        case .localWorkspace: AgentSidebarGroup.localWorkspace.title
        case .remoteWorkspaces: AgentSidebarGroup.remoteWorkspaces.title
        }
    }
}

enum AgentDisclosureKey {
    static let localWorkspace = "section:local-workspace"
    static let remoteWorkspaces = "section:remote-workspaces"

    /// One scheme for every remote workspace, keyed by registry ID: a Linux
    /// host's is its configuration ID, so its saved state carries over.
    static func workspace(_ id: String) -> String {
        "workspace:\(id.lowercased())"
    }
}

enum AgentDisclosureStore {
    static let storageKey = "wovenmatter.sidebar.collapsed-agent-sections"

    static func decode(_ raw: String) -> Set<String> {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    static func encode(_ collapsed: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(collapsed.sorted()),
              let raw = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return raw
    }

    static func isExpanded(_ key: String, in raw: String) -> Bool {
        !decode(raw).contains(key)
    }

    static func toggle(_ key: String, in raw: inout String) {
        var collapsed = decode(raw)
        if !collapsed.insert(key).inserted {
            collapsed.remove(key)
        }
        raw = encode(collapsed)
    }
}

enum AgentListMoveDirection: Sendable {
    case up
    case down
}

/// Device-local order of agents within each sidebar group (`AppStorage` JSON map).
enum AgentOrderStore {
    static let storageKey = "wovenmatter.sidebar.agent-order-by-group"

    static func decode(_ raw: String) -> [String: [UUID]] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        var result: [String: [UUID]] = [:]
        for (key, ids) in values {
            var seen = Set<UUID>()
            result[key] = ids.compactMap { UUID(uuidString: $0) }.filter { seen.insert($0).inserted }
        }
        return result
    }

    static func encode(_ map: [String: [UUID]]) -> String {
        let values = map.mapValues { $0.map { $0.uuidString.lowercased() } }
        guard let data = try? JSONEncoder().encode(values),
              let raw = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return raw
    }

    static func order(forKey key: String, in raw: String) -> [UUID] {
        decode(raw)[key] ?? []
    }

    /// Preferred IDs first when present, then remaining present IDs in their given order.
    static func mergePreferred(_ preferred: [UUID], present: [UUID]) -> [UUID] {
        let presentSet = Set(present)
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in preferred where presentSet.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        for id in present where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    static func move(
        id: UUID,
        direction: AgentListMoveDirection,
        inKey key: String,
        presentIDs: [UUID],
        raw: inout String
    ) {
        var map = decode(raw)
        var ids = presentIDs
        guard let index = ids.firstIndex(of: id) else { return }
        let target: Int
        switch direction {
        case .up:
            guard index > 0 else { return }
            target = index - 1
        case .down:
            guard index < ids.count - 1 else { return }
            target = index + 1
        }
        ids.swapAt(index, target)
        map[key] = ids
        raw = encode(map)
    }

    static func canMove(
        id: UUID,
        direction: AgentListMoveDirection,
        presentIDs: [UUID]
    ) -> Bool {
        guard let index = presentIDs.firstIndex(of: id) else { return false }
        switch direction {
        case .up: return index > 0
        case .down: return index < presentIDs.count - 1
        }
    }
}

struct AgentPresentation: Equatable {
    let displayName: String
    let iconKey: String
}

extension HarnessLogo {
    init(runtimeKind: AgentRuntimeKind) {
        switch runtimeKind {
        case .codex: self = .codex
        case .claudeCode: self = .claude
        case .grokBuild: self = .grok
        case .defaultAgent: self = .defaultAgent
        case .opencode: self = .openCode
        }
    }
}

enum SidebarStyle: String, CaseIterable, Identifiable {
    case adaptive
    case single
    case split

    static let storageKey = "wovenmatter.layout.sidebar-style"
    static let defaultStyle = SidebarStyle.split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adaptive: "Adaptive Sidebar"
        case .single: "Single Sidebar"
        case .split: "Split Sidebar"
        }
    }

    var detail: String {
        switch self {
        case .adaptive: "Keep navigation visible and open folder contents beside it."
        case .single: "Open folder contents in place of the movable navigation sidebar."
        case .split: "Keep navigation and workspace sidebars visible on opposite sides."
        }
    }
}

enum SidebarSide: String, CaseIterable, Identifiable {
    case left
    case right

    static let storageKey = "wovenmatter.layout.single-sidebar-side"
    static let defaultSide = SidebarSide.left

    var id: String { rawValue }

    var opposite: SidebarSide {
        switch self {
        case .left: .right
        case .right: .left
        }
    }
}

enum SidebarPage: Hashable, Sendable {
    case navigation
    case workspace
}

struct SidebarNavigationState: Equatable, Sendable {
    private(set) var singlePage = SidebarPage.navigation
    private(set) var adaptiveWorkspaceVisible = false

    mutating func selectFolder() {
        singlePage = .workspace
        adaptiveWorkspaceVisible = true
    }

    mutating func showNavigation() {
        singlePage = .navigation
        adaptiveWorkspaceVisible = false
    }

    /// A compact window has room for one rail page, so Adaptive then shows the
    /// folder's contents alone, with a back button, as Single does.
    func pages(
        for side: SidebarSide,
        style: SidebarStyle,
        collapsesAdaptivePages: Bool = false
    ) -> [SidebarPage] {
        switch style {
        case .adaptive:
            guard adaptiveWorkspaceVisible else { return [.navigation] }
            if collapsesAdaptivePages { return [.workspace] }
            return side == .left
                ? [.navigation, .workspace]
                : [.workspace, .navigation]
        case .single:
            return [singlePage]
        case .split:
            return [side == .left ? .navigation : .workspace]
        }
    }
}

enum DesktopShapes {
    /// Keeps full-height inset surfaces optically aligned with the macOS window.
    /// The system supplies the window's container shape; the fixed value is only
    /// a minimum for corners that are too far from a window edge to resolve.
    static var windowAlignedSurface: ConcentricRectangle {
        ConcentricRectangle(
            corners: .concentric(
                minimum: .fixed(WovenMetrics.windowAlignedSurfaceMinimumRadius)
            ),
            isUniform: true
        )
    }

    static var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: WovenMetrics.cardRadius, style: .continuous)
    }
}

struct WorkspaceLayoutState: Equatable {
    let compact: Bool
    let showsLeftRail: Bool
    let showsRightRail: Bool

    static func resolve(
        width: CGFloat,
        leftRailRequested: Bool,
        rightRailRequested: Bool,
        sidebarStyle: SidebarStyle = .defaultStyle,
        singleSidebarSide: SidebarSide = .defaultSide,
        singleRailRequested: Bool = true,
        compactRail: SidebarSide? = nil
    ) -> WorkspaceLayoutState {
        // Below the breakpoint the rails hide on their own. Revealing one docks
        // it beside the conversation exactly as at full width; the minimum
        // window always leaves one rail and the minimum workspace room.
        let compact = width < WovenMetrics.desktopBreakpoint
        let showsLeftRail: Bool
        let showsRightRail: Bool
        switch sidebarStyle {
        case .adaptive, .single:
            showsLeftRail = compact
                ? compactRail == .left && singleSidebarSide == .left
                : singleRailRequested && singleSidebarSide == .left
            showsRightRail = compact
                ? compactRail == .right && singleSidebarSide == .right
                : singleRailRequested && singleSidebarSide == .right
        case .split:
            showsLeftRail = compact ? compactRail == .left : leftRailRequested
            showsRightRail = compact ? compactRail == .right : rightRailRequested
        }
        return WorkspaceLayoutState(
            compact: compact,
            showsLeftRail: showsLeftRail,
            showsRightRail: showsRightRail
        )
    }
}

struct RailBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wovenTheme) private var theme
    @State private var hovered = false

    var body: some View {
        let palette = theme.palette
        DesktopShapes.windowAlignedSurface
            .fill(reduceTransparency ? palette.railReducedFill : palette.workspace)
            .overlay {
                if !reduceTransparency {
                    DesktopShapes.windowAlignedSurface
                        .fill(palette.railFill)
                }
            }
            .overlay {
                DesktopShapes.windowAlignedSurface
                    .stroke(hovered ? palette.railHoverRim : palette.railRim, lineWidth: 1)
            }
            .overlay {
                DesktopShapes.windowAlignedSurface
                    .stroke(hovered ? palette.railHoverInner : palette.railInnerLight, lineWidth: 1)
                    .padding(1)
            }
            .overlay {
                DesktopShapes.windowAlignedSurface
                    .stroke(palette.railEdge, lineWidth: 0.5)
            }
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: hovered)
    }
}

struct ActiveConversationRowBackground: View {
    @Environment(\.wovenTheme) private var theme
    let presentation: ConversationActivityPresentation
    let selected: Bool
    let hovered: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(presentation.isActive ? theme.palette.themeWhisper : .clear)
            if presentation.allowsMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    // Animate drawing, rather than a child's frame and offset.
                    // Active rows appear in both rails; relaying their sweep
                    // through layout repeatedly invalidates the whole window.
                    Canvas(rendersAsynchronously: true) { canvas, size in
                        let progress = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 4.2) / 4.2
                        let start = size.width * (-1.7 + 2.7 * progress)
                        canvas.fill(
                            Path(CGRect(x: start, y: 0, width: size.width * 1.7, height: size.height)),
                            with: .linearGradient(
                                Gradient(colors: [.clear, WovenPalette.primary.opacity(0.055), .clear]),
                                startPoint: CGPoint(x: start, y: 0),
                                endPoint: CGPoint(x: start + size.width * 1.7, y: 0)
                            )
                        )
                    }
                    .clipShape(shape)
                }
            }
            shape.fill(
                selected
                    ? theme.palette.themeStrong
                    : hovered ? theme.palette.themeSoft : .clear
            )
        }
    }
}

struct RoundedCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .clipShape(RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
    }
}

/// Compact native switches share the app's forest-green action color.
/// Keeping the native control preserves keyboard and accessibility behavior.
struct CompactSwitchToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: WovenPalette.primary))
                .controlSize(.mini)
                .fixedSize()
                .scaleEffect(0.8)
                .frame(width: 28, height: 16)
            configuration.label
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

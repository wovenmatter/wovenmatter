import Foundation

/// Wire shapes from Pi Bot's WebSocket protocol. Pi Bot owns them; decode what the
/// native client shows and tolerate fields added upstream.
public struct PiBotSummary: Codable, Equatable, Identifiable, Sendable {
    public struct ModelStatus: Codable, Equatable, Sendable {
        /// A provider limit the server observed. Only what the provider said.
        public struct Limit: Codable, Equatable, Sendable {
            public let model: String
            public let account: String
            public let kind: String
            public let resetsAt: Double?
            public let retryAt: Double
            public init(model: String, account: String, kind: String, resetsAt: Double? = nil, retryAt: Double = 0) {
                self.model = model; self.account = account; self.kind = kind; self.resetsAt = resetsAt; self.retryAt = retryAt
            }
        }
        public let kind: String
        public let at: Double?
        public let primary: String?
        public let active: String?
        public let limits: [Limit]?
        public init(kind: String, at: Double? = nil, primary: String? = nil, active: String? = nil, limits: [Limit]? = nil) {
            self.kind = kind; self.at = at; self.primary = primary; self.active = active; self.limits = limits
        }
    }

    public let id: String
    public let name: String
    public let createdAt: String
    public let kind: String
    public let manager: Bool
    public let managerId: String?
    public let orchestrator: Bool
    public let groupId: String?
    public let profileId: String?
    public let profileName: String?
    public let defaultProfile: Bool?
    public let modelStatus: ModelStatus?

    public init(id: String, name: String, createdAt: String = "", kind: String = "bot", manager: Bool = false,
                managerId: String? = nil, orchestrator: Bool = false, groupId: String? = nil, profileId: String? = nil,
                profileName: String? = nil, defaultProfile: Bool? = nil, modelStatus: ModelStatus? = nil) {
        self.profileId = profileId; self.profileName = profileName; self.defaultProfile = defaultProfile
        self.id = id; self.name = name; self.createdAt = createdAt; self.kind = kind; self.manager = manager
        self.managerId = managerId; self.orchestrator = orchestrator; self.groupId = groupId; self.modelStatus = modelStatus
    }

    public var isAdmin: Bool { kind == "admin" }
}

public struct PiBotThread: Codable, Equatable, Identifiable, Sendable {
    public let conversationId: Int
    public let parentConversationId: Int?
    public let forkedAt: Int?
    public let title: String?
    public let createdAt: String
    public let pinned: Bool?

    public init(conversationId: Int, parentConversationId: Int? = nil, forkedAt: Int? = nil, title: String?,
                createdAt: String, pinned: Bool? = nil) {
        self.conversationId = conversationId; self.parentConversationId = parentConversationId; self.forkedAt = forkedAt
        self.title = title; self.createdAt = createdAt; self.pinned = pinned
    }

    public var id: Int { conversationId }
    public var isPinned: Bool { pinned == true }
    public var label: String {
        guard let title, !title.isEmpty else { return "Untitled thread" }
        return title
    }

    /// Pi Bot's `sortThreads`: pins first, then newest created. Replies never reorder.
    public static func sorted(_ threads: [PiBotThread]) -> [PiBotThread] {
        threads.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.conversationId > rhs.conversationId
        }
    }
}

public struct PiBotGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let position: Int

    public init(id: String, name: String, position: Int) {
        self.id = id; self.name = name; self.position = position
    }
}

public struct PiBotHealth: Codable, Equatable, Sendable {
    public let ok: Bool
    public let version: String
    public let `protocol`: Int?
    public let installationId: String?
    public let capabilities: [String]?
    /// Where this server runs bots' tools: `container`, `docker`, or `none`.
    public let environment: String?

    public init(ok: Bool, version: String, protocol: Int? = nil, installationId: String? = nil, capabilities: [String]? = nil, environment: String? = nil) {
        self.ok = ok; self.version = version; self.protocol = `protocol`
        self.installationId = installationId; self.capabilities = capabilities; self.environment = environment
    }

    public func supports(_ capability: String) -> Bool { capabilities?.contains(capability) == true }
}

public struct PiBotWovenStatus: Codable, Equatable, Sendable {
    public let state: String
    public let endpointURL: String?
    public let toolCount: Int?
    public let error: String?

    public init(state: String, endpointURL: String? = nil, toolCount: Int? = nil, error: String? = nil) {
        self.state = state; self.endpointURL = endpointURL; self.toolCount = toolCount; self.error = error
    }
}

/// Sidebar placement, without any network or view dependency: Admin Bot, then the
/// orchestrator, then groups in their stored order, then everyone else. Team
/// members nest under their manager when both are in the same list.
public struct PiBotSidebarLayout: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let bot: PiBotSummary
        public let isTeamMember: Bool
        public var id: String { bot.id }
    }

    public struct Group: Equatable, Identifiable, Sendable {
        public let group: PiBotGroup
        public let rows: [Row]
        public var id: String { group.id }
    }

    public let pinned: [Row]
    public let groups: [Group]
    public let ungrouped: [Row]

    public init(bots: [PiBotSummary], groups: [PiBotGroup]) {
        let known = Set(groups.map(\.id))
        let admin = bots.filter(\.isAdmin)
        let orchestrator = bots.filter { !$0.isAdmin && $0.orchestrator && ($0.groupId.map(known.contains) != true) }
        let top = Set((admin + orchestrator).map(\.id))
        let orchestratorIDs = Set(orchestrator.map(\.id))
        let remaining = bots.filter { !top.contains($0.id) }
        func isInGroup(_ bot: PiBotSummary) -> Bool { bot.groupId.map(known.contains) == true }
        // A member of the orchestrator's own team stays with it unless grouped elsewhere.
        let orchestratorMembers = remaining.filter {
            !isInGroup($0) && $0.managerId.map(orchestratorIDs.contains) == true && !$0.manager
        }
        let memberIDs = Set(orchestratorMembers.map(\.id))
        pinned = admin.map { Row(bot: $0, isTeamMember: false) }
            + orchestrator.map { Row(bot: $0, isTeamMember: false) }
            + orchestratorMembers.map { Row(bot: $0, isTeamMember: true) }
        self.groups = groups.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map { group in
            Group(group: group, rows: Self.rows(remaining.filter { $0.groupId == group.id }))
        }
        ungrouped = Self.rows(remaining.filter { !isInGroup($0) && !memberIDs.contains($0.id) })
    }

    private static func rows(_ bots: [PiBotSummary]) -> [Row] {
        var result: [Row] = []
        var placed = Set<String>()
        for manager in bots where manager.manager {
            result.append(Row(bot: manager, isTeamMember: false))
            placed.insert(manager.id)
            for member in bots where member.managerId == manager.id && !member.manager {
                result.append(Row(bot: member, isTeamMember: true))
                placed.insert(member.id)
            }
        }
        for bot in bots where !placed.contains(bot.id) { result.append(Row(bot: bot, isTeamMember: false)) }
        return result
    }

    public var allRows: [Row] { pinned + groups.flatMap(\.rows) + ungrouped }
}

/// `pi-bot/selection.json`: the exact Pi Bot revision and runtime this app delivers.
public struct PiBotSelection: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public let version: String
        public let sha256: [String: String]
        public init(version: String, sha256: [String: String]) { self.version = version; self.sha256 = sha256 }
    }
    public let schema: Int
    public let repository: String
    public let commit: String
    public let `protocol`: Int
    public let pnpm: String
    public let node: Node
    /// Apple's signed `container` package, for Macs that don't have it installed.
    public let container: Container?

    public struct Container: Codable, Equatable, Sendable {
        public let version: String
        public let sha256: String
        public init(version: String, sha256: String) { self.version = version; self.sha256 = sha256 }
    }

    public init(schema: Int = 1, repository: String, commit: String, protocol: Int, pnpm: String, node: Node, container: Container? = nil) {
        self.schema = schema; self.repository = repository; self.commit = commit
        self.protocol = `protocol`; self.pnpm = pnpm; self.node = node; self.container = container
    }
}

/// `pi-bot-host.sh inspect`.
public struct PiBotHostInspection: Codable, Equatable, Sendable {
    public struct Managed: Codable, Equatable, Sendable {
        public let installed: Bool
        public let commit: String?
        public let running: Bool
        public let port: Int?
        public let root: String?
    }
    public struct Existing: Codable, Equatable, Identifiable, Sendable {
        public let port: Int
        public let version: String?
        public let `protocol`: Int?
        public let installationId: String?
        public let service: String?
        public var id: Int { port }
    }
    public let schema: Int
    public let os: String
    public let arch: String
    public let libc: String?
    public let serviceManager: String
    /// Where bots' tools would run after an install here: `container`, `docker`, or `none`.
    public let environment: String?
    public let docker: Bool
    public let lingering: Bool?
    public let managed: Managed
    public let existing: [Existing]

    public var nodePlatform: String { os + "-" + arch }
}

/// `pi-bot-host.sh install`.
public struct PiBotInstallResult: Codable, Equatable, Sendable {
    public let schema: Int
    public let commit: String
    public let port: Int
    public let root: String
    public let node: String?
    public let entry: String?
    public let config: String?
    public let lingering: Bool?
}

/// A device on the tailnet that can host Pi Bot. Addresses always come from tailscaled.
public struct PiBotTailnetPeer: Codable, Equatable, Identifiable, Sendable {
    public enum System: String, Codable, Sendable { case macOS, linux }
    public let id: String
    public let name: String
    public let dnsName: String
    public let address: String
    public let system: System
    public let online: Bool

    public init(id: String, name: String, dnsName: String, address: String, system: System, online: Bool) {
        self.id = id; self.name = name; self.dnsName = dnsName; self.address = address
        self.system = system; self.online = online
    }

    public var sshName: String { dnsName.split(separator: ".").first.map(String.init) ?? address }
}

/// Where the one Pi Bot server for this Woven Matter instance runs.
public struct PiBotDeploymentTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case thisMac, tailnet }
    /// `managed` means Woven Matter installed it. `attached` means it already existed:
    /// its config, credentials, data, service and updates remain its own.
    public enum Ownership: String, Codable, Sendable { case managed, attached }

    public var kind: Kind
    public var ownership: Ownership
    public var peer: PiBotTailnetPeer?
    public var sshUser: String
    public var remotePort: Int?

    public init(kind: Kind, ownership: Ownership = .managed, peer: PiBotTailnetPeer? = nil, sshUser: String = "", remotePort: Int? = nil) {
        self.kind = kind; self.ownership = ownership; self.peer = peer; self.sshUser = sshUser; self.remotePort = remotePort
    }

    public static let thisMac = PiBotDeploymentTarget(kind: .thisMac)
    public var displayName: String { kind == .thisMac ? "This Mac" : peer?.name ?? "Unknown device" }
    public func isSameDevice(as other: PiBotDeploymentTarget) -> Bool {
        kind == other.kind && peer?.id == other.peer?.id
    }
}

public struct PiBotRuntimeSnapshot: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case notConfigured, installing, starting, ready, stopped, reconnecting, failed }

    public var phase: Phase
    public var message: String?
    public var error: String?
    public var target: PiBotDeploymentTarget?
    /// Loopback only: this Mac's server, or the local end of the SSH forward.
    public var baseURL: URL?
    public var health: PiBotHealth?
    public var installedCommit: String?
    public var bundledCommit: String?
    public var bundleAvailable: Bool
    public var woven: PiBotWovenStatus?
    public var lingeringDisabled: Bool
    /// A device command is still running; its outcome arrives in a later snapshot.
    public var busy: Bool

    public init(phase: Phase = .notConfigured, message: String? = nil, error: String? = nil, target: PiBotDeploymentTarget? = nil,
                baseURL: URL? = nil, health: PiBotHealth? = nil, installedCommit: String? = nil, bundledCommit: String? = nil,
                bundleAvailable: Bool = false, woven: PiBotWovenStatus? = nil, lingeringDisabled: Bool = false, busy: Bool = false) {
        self.phase = phase; self.message = message; self.error = error; self.target = target; self.baseURL = baseURL
        self.health = health; self.installedCommit = installedCommit; self.bundledCommit = bundledCommit
        self.bundleAvailable = bundleAvailable; self.woven = woven; self.lingeringDisabled = lingeringDisabled; self.busy = busy
    }

    /// Pi Bot's client can run inside this app only from this capability on.
    /// Old enough servers lack the protocol Woven's bot UI runs on.
    public var isCompatible: Bool { health?.supports("groups") == true && health?.supports("message.context") == true }

    public var updateAvailable: Bool {
        guard target?.ownership == .managed, let installedCommit, let bundledCommit else { return false }
        return installedCommit != bundledCommit
    }
}

public enum PiBotHostError: LocalizedError, Sendable, Equatable {
    case bundleMissing
    case tailscaleUnavailable
    case peerOffline(String)
    case invalidConnection
    case command(String)
    case response(String)

    public var errorDescription: String? {
        switch self {
        case .bundleMissing: "This build does not include Pi Bot. Rebuild Woven Matter with its Pi Bot resources."
        case .tailscaleUnavailable: "Install and connect Tailscale to use your other devices."
        case .peerOffline(let name): "\(name) is offline. Connect it to Tailscale and try again."
        case .invalidConnection: "Enter a valid SSH user name."
        case .command(let detail): detail
        case .response(let detail): detail
        }
    }
}

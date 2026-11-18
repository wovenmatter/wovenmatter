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

/// The runtime's `hello` (and `GET /health`).
public struct PiBotHealth: Codable, Equatable, Sendable {
    public let ok: Bool
    public let version: String
    public let `protocol`: Int?
    public let installationId: String?
    public let capabilities: [String]?
    /// Where bots' tools run: `none`, `linux-dockerd` or `mac-vm`.
    public let environment: String?

    public init(ok: Bool, version: String, protocol: Int? = nil, installationId: String? = nil, capabilities: [String]? = nil,
                environment: String? = nil) {
        self.ok = ok; self.version = version; self.protocol = `protocol`
        self.installationId = installationId; self.capabilities = capabilities; self.environment = environment
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

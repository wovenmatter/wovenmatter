import Foundation
import UniformTypeIdentifiers

// What the bots views show, as the bots' host's server reports it.

/// Where the bots are: the state of the bots runtime on their host.
enum BotsState: Equatable, Sendable {
    /// No host is chosen, or bots are turned off there.
    case off
    case starting
    case ready
    /// The host is offline, or its server does not answer.
    case unreachable
    case failed
    /// They are moving to another machine.
    case transferring
}

/// What the user can do about a failed reply.
enum BotReplyIssue: Equatable, Sendable {
    /// The model's provider isn't signed in, or its key was refused.
    case signIn
    /// The model hit a usage limit or ran out of credits.
    case limit
}

struct PiBotSummary: Equatable, Identifiable, Sendable {
    struct ModelStatus: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Out of usage, with no fallback left.
            case paused
            /// On a fallback until the main model's limit resets.
            case fallback
            /// Back on the main model.
            case returned
        }

        /// A provider limit the server observed. Only what the provider said.
        struct Limit: Equatable, Sendable {
            enum Kind: Equatable, Sendable { case fiveHour, weekly, credits, other }
            let model: String
            let account: String
            let kind: Kind
            /// Epoch milliseconds.
            let resetsAt: Double?
            let retryAt: Double
        }

        let kind: Kind
        /// Epoch milliseconds of the change.
        let at: Double?
        let primary: String?
        let active: String?
        let limits: [Limit]
    }

    let id: String
    let name: String
    let isAdmin: Bool
    let manager: Bool
    let managerId: String?
    let orchestrator: Bool
    let groupId: String?
    let profileId: String?
    let profileName: String?
    let defaultProfile: Bool
    let modelStatus: ModelStatus?

    /// What a bot does, separate from its name.
    var role: String {
        if isAdmin { return "Admin" }
        if orchestrator { return "Orchestrator" }
        return manager ? "Manager" : "Bot"
    }

    /// "none" for no team, "manager" when it leads one, or its manager's id.
    var placement: String { manager ? "manager" : (managerId ?? "none") }
}

struct PiBotThread: Equatable, Identifiable, Sendable {
    let conversationId: Int
    let parentConversationId: Int?
    let forkedAt: Int?
    let title: String?
    let createdAt: Date
    let isPinned: Bool

    var id: Int { conversationId }
    var label: String {
        guard let title, !title.isEmpty else { return "Untitled thread" }
        return title
    }

    /// Pins first, then newest created. Replies never reorder.
    static func sorted(_ threads: [PiBotThread]) -> [PiBotThread] {
        threads.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.conversationId > rhs.conversationId
        }
    }
}

struct PiBotGroup: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let position: Int
}

/// Sidebar placement: Admin Bot, then the orchestrator, then groups in their stored order,
/// then everyone else. Team members nest under their manager when both are in the same list.
struct PiBotSidebarLayout: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        let bot: PiBotSummary
        let isTeamMember: Bool
        var id: String { bot.id }
    }

    struct Group: Equatable, Identifiable, Sendable {
        let group: PiBotGroup
        let rows: [Row]
        var id: String { group.id }
    }

    let pinned: [Row]
    let groups: [Group]
    let ungrouped: [Row]

    init(bots: [PiBotSummary], groups: [PiBotGroup]) {
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
}

/// Settings order for bots: the orchestrator, each team, then bots on no team; Admin Bot apart.
struct PiBotTeamLayout: Equatable, Sendable {
    struct Row: Equatable, Identifiable, Sendable {
        let bot: PiBotSummary
        let isMember: Bool
        var id: String { bot.id }
    }
    let rows: [Row]
    let admin: PiBotSummary?

    init(_ bots: [PiBotSummary]) {
        admin = bots.first(where: \.isAdmin)
        let orchestrator = bots.first { !$0.isAdmin && $0.orchestrator }
        let managers = bots.filter { !$0.isAdmin && $0.manager }
        let managerIDs = Set(managers.map(\.id))
        func members(of manager: PiBotSummary) -> [PiBotSummary] {
            bots.filter { $0.managerId == manager.id && !$0.manager && $0.id != orchestrator?.id }
        }
        var rows: [Row] = []
        if let orchestrator {
            rows.append(Row(bot: orchestrator, isMember: false))
            if orchestrator.manager { rows += members(of: orchestrator).map { Row(bot: $0, isMember: true) } }
        }
        for manager in managers where manager.id != orchestrator?.id {
            rows.append(Row(bot: manager, isMember: false))
            rows += members(of: manager).map { Row(bot: $0, isMember: true) }
        }
        rows += bots.filter { bot in
            !bot.isAdmin && bot.id != orchestrator?.id && !bot.manager
                && !(bot.managerId.map(managerIDs.contains) ?? false)
        }.map { Row(bot: $0, isMember: false) }
        self.rows = rows
    }
}

// MARK: - Conversations

struct PiBotDisplayEntry: Equatable, Identifiable, Sendable {
    let id: Int
    /// The conversation that owns the entry; differs from the viewed one for inherited entries.
    let conversationId: Int
    let isUser: Bool
    let text: String
    let error: String?
    let issue: BotReplyIssue?
    let isStopped: Bool
    /// Visual replies the bot published with `render_html`, shown after the text.
    var visualReplies: [ConversationHTMLRenderReference] = []

    var needsSignIn: Bool { issue == .signIn }
    var hitLimit: Bool { issue == .limit }
}

/// What one open bot conversation shows.
struct PiBotConversationState: Equatable, Sendable {
    struct Pending: Equatable, Identifiable, Sendable {
        let id: Int
        let text: String
    }

    var entries: [PiBotDisplayEntry] = []
    /// Text of the reply being generated; the final entry replaces it.
    var streaming: String?
    var running = false
    /// Sent messages not yet recorded as entries, queued behind a running reply.
    var pending: [Pending] = []
}

/// A text file on its way into a message. Bots take attachments as message text.
struct PiBotAttachmentDraft: Equatable, Identifiable, Sendable {
    static let maxFileBytes = 80_000
    static let maxMessageCharacters = 100_000
    static let textExtensions: Set<String> = [
        "txt", "md", "csv", "json", "log", "xml", "yaml", "yml", "ts", "tsx", "js", "jsx", "py", "html", "css", "sh",
    ]

    enum Problem: LocalizedError, Equatable {
        case tooLarge, notText, binary
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Attach text files smaller than 80 KB."
            case .notText: "Attachments currently support text, code, and CSV files. Images and binary documents are not supported yet."
            case .binary: "This file contains binary data. Choose a text file."
            }
        }
    }

    let id: String
    let name: String
    let text: String
    let url: URL

    init(id: String = UUID().uuidString, name: String, text: String, url: URL) {
        self.id = id; self.name = name; self.text = text; self.url = url
    }

    static func read(_ url: URL) throws -> PiBotAttachmentDraft {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        if size > maxFileBytes { throw Problem.tooLarge }
        let fileExtension = url.pathExtension.lowercased()
        let isText = textExtensions.contains(fileExtension) || UTType(filenameExtension: fileExtension)?.conforms(to: .text) == true
        guard isText else { throw Problem.notText }
        let data = try Data(contentsOf: url)
        if data.contains(0) { throw Problem.binary }
        guard let text = String(data: data, encoding: .utf8) else { throw Problem.binary }
        return PiBotAttachmentDraft(name: url.lastPathComponent, text: text, url: url)
    }

    /// The message text for a draft and its attachments.
    static func message(draft: String, attachments: [PiBotAttachmentDraft]) -> String {
        ([draft.trimmingCharacters(in: .whitespacesAndNewlines)] + attachments.map { "Attached text file: \($0.name)\n\n\($0.text)" })
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

// MARK: - Models and profiles

struct PiBotPriceRates: Equatable, Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double
}

struct PiBotModelPricing: Equatable, Sendable {
    enum Status: Equatable, Sendable { case listed, zero, unknown }
    struct Tier: Equatable, Sendable {
        let rates: PiBotPriceRates
        let inputTokensAbove: Double
    }
    let status: Status
    let rates: PiBotPriceRates?
    let tiers: [Tier]
}

struct PiBotModelOption: Equatable, Identifiable, Sendable {
    struct Limit: Equatable, Sendable {
        let label: String
        /// Epoch milliseconds.
        let resetsAt: Double?
    }
    let id: String
    let name: String
    let reasoning: Bool
    let contextWindow: Double
    let maxTokens: Double?
    let input: [String]
    let pricing: PiBotModelPricing?
    let limit: Limit?
}

struct PiBotProviderModels: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// How the provider is reached ("Subscription", "API key"), when known.
    let accessLabel: String?
    let models: [PiBotModelOption]
}

struct PiBotRoles: Equatable, Sendable {
    var titles: String
    var titlesReasoning: String
}

struct PiBotModelCatalog: Equatable, Sendable {
    var providers: [PiBotProviderModels]
    var roles: PiBotRoles
    var reasoningLevels: [String]

    func isKnown(_ ref: String) -> Bool { Self.find(providers, ref) != nil }

    static func find(_ providers: [PiBotProviderModels], _ ref: String) -> (provider: PiBotProviderModels, model: PiBotModelOption)? {
        for provider in providers {
            if let model = provider.models.first(where: { "\(provider.id)/\($0.id)" == ref }) { return (provider, model) }
        }
        return nil
    }
}

/// A model's catalog facts. Prices are API list prices, never billing.
enum PiBotModelFacts {
    /// Catalog values as given, never rounded to $0. Only float noise past 10 digits goes.
    static func usd(_ value: Double) -> String {
        guard value != 0 else { return "$0" }
        let plain = Decimal(string: String(format: "%.9e", value)).map { "\($0)" } ?? "\(value)"
        return "$\(plain)"
    }

    static func tokens(_ value: Double) -> String {
        if value >= 1_000_000, value.truncatingRemainder(dividingBy: 1_000_000) == 0 { return "\(Int(value / 1_000_000))M" }
        if value >= 1000 { return "\(Int((value / 1000).rounded()))k" }
        return "\(Int(value))"
    }

    private static func rates(_ rates: PiBotPriceRates) -> String {
        "\(usd(rates.input)) in · \(usd(rates.output)) out · \(usd(rates.cacheRead)) cache read · \(usd(rates.cacheWrite)) cache write"
    }

    static func priceText(_ pricing: PiBotModelPricing?) -> String {
        guard let pricing else { return "API price unknown" }
        switch pricing.status {
        case .unknown: return "API price unknown"
        case .zero: return "API price listed as $0 (free or unpriced)"
        case .listed:
            guard let listed = pricing.rates else { return "API price unknown" }
            let tiered = pricing.tiers.isEmpty ? "" : " (other rates above set input sizes)"
            return "\(rates(listed)) per 1M tokens\(tiered)"
        }
    }

    static func tierTexts(_ pricing: PiBotModelPricing?) -> [String] {
        guard let pricing, pricing.status == .listed else { return [] }
        return pricing.tiers.map { "Above \(tokens($0.inputTokensAbove)) input tokens: \(rates($0.rates)) per 1M tokens" }
    }

    /// Price, capabilities, access and limit state of one model.
    static func text(_ providers: [PiBotProviderModels], _ ref: String) -> String {
        guard let (provider, model) = PiBotModelCatalog.find(providers, ref) else { return "Not signed in: no catalog details" }
        var parts = [priceText(model.pricing)]
        if model.contextWindow > 0 { parts.append("\(tokens(model.contextWindow)) context") }
        if let max = model.maxTokens, max > 0 { parts.append("\(tokens(max)) max output") }
        if !model.input.isEmpty { parts.append(model.input.joined(separator: ", ")) }
        if model.reasoning { parts.append("reasoning") }
        if let access = provider.accessLabel { parts.append(access) }
        if let limit = model.limit {
            let reset = limit.resetsAt.map { ms -> String in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyy-MM-dd HH:mm"
                return "resets \(formatter.string(from: Date(timeIntervalSince1970: ms / 1000))) UTC"
            } ?? "reset unknown"
            parts.append("\(limit.label), \(reset)")
        }
        return parts.joined(separator: " · ")
    }
}

struct PiBotProfile: Equatable, Identifiable, Sendable {
    struct PoolModel: Equatable, Sendable {
        let model: String
        let useFor: String
    }
    let id: String
    let name: String
    let main: String
    let fallbacks: [String]
    let memoryModel: String?
    let guidance: String?
    let pool: [PoolModel]
    let isDefault: Bool
}

/// The profile editor's working copy.
struct PiBotProfileDraft: Equatable, Sendable {
    struct Fallback: Equatable, Identifiable, Sendable {
        let id: UUID
        var model: String
        init(id: UUID = UUID(), model: String = "") { self.id = id; self.model = model }
    }
    struct PoolEntry: Equatable, Identifiable, Sendable {
        let id: UUID
        var model: String
        var useFor: String
        init(id: UUID = UUID(), model: String = "", useFor: String = "") { self.id = id; self.model = model; self.useFor = useFor }
    }

    static let maxFallbacks = 5
    static let activeMainModel = "Use active main model"

    var id = ""
    var name = ""
    var main = ""
    var fallbacks: [Fallback] = []
    var memoryModel = ""
    var guidance = ""
    var pool: [PoolEntry] = []

    init(profile: PiBotProfile? = nil) {
        guard let profile else { return }
        id = profile.id; name = profile.name; main = profile.main
        fallbacks = profile.fallbacks.map { Fallback(model: $0) }
        memoryModel = profile.memoryModel ?? ""
        guidance = profile.guidance ?? ""
        pool = profile.pool.map { PoolEntry(model: $0.model, useFor: $0.useFor) }
    }

    var fallbackModels: [String] { fallbacks.map(\.model).filter { !$0.isEmpty } }
    var poolModels: [String] { pool.map(\.model).filter { !$0.isEmpty } }
    var fallbackProblem: String? {
        if fallbackModels.contains(main) { return "A fallback can't be the main model." }
        if Set(fallbackModels).count < fallbackModels.count { return "Each fallback can appear only once." }
        return nil
    }
    func canSave(isNew: Bool) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !main.isEmpty
            && (!isNew || !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && fallbackProblem == nil
    }
}

/// The banner's words for a bot's model status.
struct PiBotModelStatusText: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case warning, error, success }
    let tone: Tone
    let title: String
    let lines: [String]

    static func localTime(_ ms: Double, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, h:mm a zzz"
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// What was hit, in the provider's own terms. Never names a window or reset it didn't report.
    static func limit(_ limit: PiBotSummary.ModelStatus.Limit) -> String {
        switch limit.kind {
        case .fiveHour: "Your \(limit.account) hit its 5-hour usage limit"
        case .weekly: "Your \(limit.account) hit its weekly usage limit"
        case .credits: "Your \(limit.account) ran out of credits"
        case .other: "This \(limit.account) ran out of usage"
        }
    }

    static func reset(_ limit: PiBotSummary.ModelStatus.Limit, timeZone: TimeZone) -> String {
        if let resets = limit.resetsAt { return "Resets \(localTime(resets, timeZone: timeZone))." }
        return "Reset time not reported; Woven Matter tries again around \(localTime(limit.retryAt, timeZone: timeZone))."
    }

    init(status: PiBotSummary.ModelStatus, botName: String, timeZone: TimeZone = .current) {
        let primaryModel = status.primary ?? ""
        if status.kind == .returned {
            tone = .success
            title = "\(botName) is back on \(primaryModel)."
            lines = ["Its usage limit reset, so it switched back from the fallback."]
            return
        }
        let limits = status.limits
        let primary = limits.first { $0.model == primaryModel } ?? limits.first
        let others = limits.filter { $0 != primary }
        var lines: [String] = []
        if let primary { lines.append(Self.reset(primary, timeZone: timeZone)) }
        for limit in others {
            let described = Self.limit(limit)
            lines.append("Fallback \(limit.model): \(described.prefix(1).lowercased())\(described.dropFirst()). \(Self.reset(limit, timeZone: timeZone))")
        }
        if status.kind == .paused {
            lines.append(others.isEmpty
                ? "\(botName) is out of usage: this profile has no fallback. Add one under Settings → Bots → Profiles."
                : "\(botName) is out of usage: every fallback is out too.")
        } else {
            lines.append("\(botName) is now using \(status.active ?? primaryModel) until then.")
        }
        tone = status.kind == .paused ? .error : .warning
        title = primary.map { "\(Self.limit($0)) (\($0.model))." } ?? "\(primaryModel) is unavailable."
        self.lines = lines
    }
}

// MARK: - Bots, containers, setup

struct PiBotDeletedBot: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let deletedAt: Date
}

struct PiBotPurgeResult: Equatable, Sendable {
    /// Why the bot's files and container were not removed, when they were not.
    let environmentError: String?
}

struct PiBotOnboardingStatus: Equatable, Sendable {
    let mainModel: String
    let mainModelAvailable: Bool
    let signedIn: Bool
    let needed: Bool
}

/// A bot's container.
struct PiBotEnvironment: Equatable, Sendable {
    enum State: Equatable, Sendable { case missing, running, stopped, unavailable }
    let state: State
    /// Why a running bot is not idle now.
    let busy: String?

    var stateText: String {
        switch state {
        case .running: busy.map { "Running · \($0)" } ?? "Running"
        case .stopped: "Stopped · starts on its next tool call"
        case .missing: "Not created yet"
        case .unavailable: "Unavailable"
        }
    }
}

/// A bots update running on the host: which bot it is on, and how far.
struct BotsUpdateProgress: Equatable, Sendable {
    let botID: String?
    let text: String
}

// MARK: - Resources

/// Byte counts for the bots' host. nil means no cap.
struct BotResourceSettings: Equatable, Sendable {
    static let gib: Int64 = 1 << 30
    static let defaults = BotResourceSettings(poolBytes: 8 * gib, perBotBytes: 4 * gib, diskBytes: 50 * gib)

    /// The memory every bot shares: the VM on a Mac, the engine's slice on Linux.
    var poolBytes: Int64?
    /// Each bot's container memory limit.
    var perBotBytes: Int64?
    /// One total cap on bot storage.
    var diskBytes: Int64?
}

struct BotMachineCapacity: Equatable, Sendable {
    var memoryBytes: Int64
    var diskTotalBytes: Int64
    var diskFreeBytes: Int64
    /// What bots already store; lowering the disk cap stops here.
    var diskUsedByBotsBytes: Int64?
}

/// The rules in Settings → Bots → Resources, without any view.
enum BotResourcePolicy {
    static let gib = BotResourceSettings.gib
    /// Below this much memory left over, the machine itself suffers.
    static let machineReserveBytes: Int64 = 4 * gib

    enum Warning: Equatable, Sendable {
        case poolLeavesLittleMemory(leftBytes: Int64)
        case diskCapExceedsFree(freeBytes: Int64)
    }

    /// Whole gigabytes from 1 GB to the machine's memory.
    static func poolChoices(_ capacity: BotMachineCapacity) -> [Int64] {
        stride(from: gib, through: max(gib, capacity.memoryBytes / gib * gib), by: Int(gib)).map { $0 }
    }

    /// Whole gigabytes up to the pool, or up to the machine's memory with no pool cap.
    static func perBotChoices(pool: Int64?, _ capacity: BotMachineCapacity) -> [Int64] {
        let ceiling = pool ?? max(gib, capacity.memoryBytes / gib * gib)
        return stride(from: gib, through: max(gib, ceiling), by: Int(gib)).map { $0 }
    }

    static func diskChoices(_ capacity: BotMachineCapacity) -> [Int64] {
        let total = max(gib, capacity.diskTotalBytes / gib * gib)
        var values: [Int64] = [5, 10, 20, 50, 100, 200, 500, 1_000, 2_000, 4_000].map { $0 * gib }.filter { $0 <= total }
        if values.last != total { values.append(total) }
        return values
    }

    /// The defaults, fitted to a machine smaller than they assume.
    static func defaults(for capacity: BotMachineCapacity) -> BotResourceSettings {
        validated(.defaults, capacity)
    }

    /// Brings every value inside its range: the pool within 1 GB…machine memory, per-bot within
    /// the pool, and disk within the disk's size and at least what bots already use.
    static func validated(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) -> BotResourceSettings {
        var result = settings
        let memory = max(gib, capacity.memoryBytes)
        if let pool = result.poolBytes { result.poolBytes = min(max(gib, pool), memory) }
        if let perBot = result.perBotBytes { result.perBotBytes = min(max(gib, perBot), result.poolBytes ?? memory) }
        if let disk = result.diskBytes {
            let floor = max(gib, capacity.diskUsedByBotsBytes ?? 0)
            result.diskBytes = min(max(floor, disk), max(floor, capacity.diskTotalBytes))
        }
        return result
    }

    static func warnings(_ settings: BotResourceSettings, _ capacity: BotMachineCapacity) -> [Warning] {
        var result: [Warning] = []
        // No cap can take everything, so it leaves the machine nothing it can count on.
        let left = capacity.memoryBytes - (settings.poolBytes ?? capacity.memoryBytes)
        if left < machineReserveBytes { result.append(.poolLeavesLittleMemory(leftBytes: max(0, left))) }
        if (settings.diskBytes ?? Int64.max) > capacity.diskFreeBytes + (capacity.diskUsedByBotsBytes ?? 0) {
            result.append(.diskCapExceedsFree(freeBytes: capacity.diskFreeBytes))
        }
        return result
    }

    static func text(_ warning: Warning) -> String {
        switch warning {
        case .poolLeavesLittleMemory(let left):
            "This leaves \(format(left)) for everything else on this machine. Keep at least 4 GB free."
        case .diskCapExceedsFree(let free):
            "This is more than the \(format(free)) free on this disk. Bots stop saving files when the disk fills."
        }
    }

    static func format(_ bytes: Int64?) -> String {
        guard let bytes else { return "No cap" }
        let gigabytes = Double(bytes) / Double(gib)
        if gigabytes >= 1_000 { return String(format: gigabytes.truncatingRemainder(dividingBy: 1_000) == 0 ? "%.0f TB" : "%.1f TB", gigabytes / 1_000) }
        if gigabytes >= 10 || gigabytes.rounded() == gigabytes { return String(format: "%.0f GB", gigabytes.rounded()) }
        return String(format: "%.1f GB", gigabytes)
    }
}

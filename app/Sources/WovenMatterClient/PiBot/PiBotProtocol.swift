import Foundation
import UniformTypeIdentifiers

// Pi Bot's WebSocket protocol beyond the sidebar, as `apps/web/src/protocol.ts` defines it.
// Pi Bot owns these shapes. Decode what the native client shows and tolerate additions.

public struct PiBotDisplayEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    /// The conversation that owns the entry; differs from the viewed one for inherited entries.
    public let conversationId: Int
    public let role: String
    public let text: String
    public let error: String?
    public let stopped: Bool?

    public init(id: Int, conversationId: Int, role: String, text: String, error: String? = nil, stopped: Bool? = nil) {
        self.id = id; self.conversationId = conversationId; self.role = role; self.text = text
        self.error = error; self.stopped = stopped
    }

    public var isUser: Bool { role == "user" }
    public var isStopped: Bool { stopped == true }
}

public struct PiBotConversationSnapshot: Decodable, Sendable {
    public let subscriptionId: GatewayJSONValue?
    public let botId: String
    public let conversationId: Int
    public let mainConversationId: Int
    public let threadOrigin: PiBotDisplayEntry?
    public let entries: [PiBotDisplayEntry]
    public let running: Bool
    public let streaming: String?

    public init(subscriptionId: GatewayJSONValue? = nil, botId: String, conversationId: Int, mainConversationId: Int,
                threadOrigin: PiBotDisplayEntry? = nil, entries: [PiBotDisplayEntry] = [], running: Bool = false,
                streaming: String? = nil) {
        self.subscriptionId = subscriptionId; self.botId = botId; self.conversationId = conversationId
        self.mainConversationId = mainConversationId; self.threadOrigin = threadOrigin; self.entries = entries
        self.running = running; self.streaming = streaming
    }
}

public enum PiBotStreamEvent: Equatable, Sendable {
    case run(started: Bool)
    case assistantStart(String)
    case delta(String)
    case entry(PiBotDisplayEntry)
    case error(String)

    private struct Wire: Decodable {
        let kind: String
        let state: String?
        let text: String?
        let entry: PiBotDisplayEntry?
        let message: String?
    }

    public init?(json: GatewayJSONValue) {
        guard let data = try? JSONEncoder().encode(json), let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.kind {
        case "run": self = .run(started: wire.state == "start")
        case "assistant_start": self = .assistantStart(wire.text ?? "")
        case "delta": self = .delta(wire.text ?? "")
        case "entry":
            guard let entry = wire.entry else { return nil }
            self = .entry(entry)
        case "error": self = .error(wire.message ?? "Pi Bot returned an error.")
        default: return nil
        }
    }
}

/// What one open conversation shows. Mirrors Pi Bot's `conversation-state.ts`.
public struct PiBotConversationState: Equatable, Sendable {
    public struct Pending: Equatable, Identifiable, Sendable {
        public let id: Int
        public let text: String
        public init(id: Int, text: String) { self.id = id; self.text = text }
    }

    public var entries: [PiBotDisplayEntry] = []
    /// Text of the reply being generated; the final entry replaces it.
    public var streaming: String?
    public var running = false
    /// Sent messages not yet recorded as entries, queued behind a running reply.
    public var pending: [Pending] = []

    public init() {}

    /// Adds or replaces entries by id, keeping first-seen order.
    public static func merge(_ current: [PiBotDisplayEntry], _ incoming: [PiBotDisplayEntry]) -> [PiBotDisplayEntry] {
        var next = current
        var positions = Dictionary(next.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
        for entry in incoming {
            if let index = positions[entry.id] {
                next[index] = entry
            } else {
                positions[entry.id] = next.count
                next.append(entry)
            }
        }
        return next
    }

    public mutating func apply(_ event: PiBotStreamEvent) {
        switch event {
        case .run(let started):
            running = started
            if !started { streaming = nil }
        case .assistantStart(let text):
            streaming = text
        case .delta(let text):
            streaming = (streaming ?? "") + text
        case .entry(let entry):
            if entry.isUser, let index = pending.firstIndex(where: { $0.text == entry.text }) {
                pending.remove(at: index)
            }
            entries = Self.merge(entries, [entry])
            if !entry.isUser { streaming = nil }
        case .error:
            break
        }
    }

    /// History that arrives after streaming began does not undo what the stream already showed.
    public mutating func apply(snapshot: PiBotConversationSnapshot) {
        entries = Self.merge(snapshot.entries, entries)
        running = snapshot.running || running
        streaming = streaming ?? snapshot.streaming
    }
}

// MARK: - Accounts and sign-in

public struct PiBotAccount: Codable, Equatable, Identifiable, Sendable {
    public struct LoginMethod: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }

    public let id: String
    public let provider: String
    public let group: String
    public let label: String
    /// "oauth", "api_key" or "token".
    public let method: String
    public let help: String
    public let link: String?
    public let loginMethods: [LoginMethod]?
    public let signInLabel: String?
    public let alternateTo: String?
    public let configured: Bool
    public let unreadable: Bool?
    public let detail: String?
    public let ambient: Bool?

    public init(id: String, provider: String = "", group: String = "", label: String, method: String = "api_key",
                help: String = "", link: String? = nil, loginMethods: [LoginMethod]? = nil, signInLabel: String? = nil,
                alternateTo: String? = nil, configured: Bool = false, unreadable: Bool? = nil, detail: String? = nil,
                ambient: Bool? = nil) {
        self.id = id; self.provider = provider; self.group = group; self.label = label; self.method = method
        self.help = help; self.link = link; self.loginMethods = loginMethods; self.signInLabel = signInLabel
        self.alternateTo = alternateTo; self.configured = configured; self.unreadable = unreadable
        self.detail = detail; self.ambient = ambient
    }

    public var isKeyed: Bool { method != "oauth" }
    public var statusText: String {
        if let detail, !detail.isEmpty { return detail }
        if configured { return "Configured" }
        return method == "oauth" ? "Not signed in" : "Not set"
    }
    /// Can be signed out or removed. An ambient credential comes from the device, not Pi Bot.
    public var isRemovable: Bool { (configured || unreadable == true) && ambient != true }
    public var keyLabel: String {
        if label.hasSuffix("API key") || label.hasSuffix("token") { return label }
        return "\(label) \(method == "token" ? "token" : "API key")"
    }
    public var keyPlaceholder: String {
        if configured { return "Paste a new value to replace it" }
        return method == "token" ? "Paste token" : "Paste API key"
    }
    /// The heading over an API key offered instead of this sign-in.
    public var alternateKeyTitle: String {
        switch id {
        case "claude-oauth": "Use a Claude API key"
        case "openai-codex": "Use an OpenAI API key"
        case "xai-oauth": "Use an xAi API key"
        default: "Use an API key"
        }
    }
}

public struct PiBotAccountGroups: Equatable, Sendable {
    public struct Group: Equatable, Identifiable, Sendable {
        public let name: String
        public let accounts: [PiBotAccount]
        public var id: String { name }
    }

    public let groups: [Group]
    private let alternates: [String: [PiBotAccount]]

    /// An API key that is the alternative to a sign-in folds under that sign-in's row.
    public init(_ accounts: [PiBotAccount]) {
        let ids = Set(accounts.map(\.id))
        var order: [String] = []
        var members: [String: [PiBotAccount]] = [:]
        var folded: [String: [PiBotAccount]] = [:]
        for account in accounts {
            if let parent = account.alternateTo, ids.contains(parent) {
                folded[parent, default: []].append(account)
                continue
            }
            if members[account.group] == nil { order.append(account.group) }
            members[account.group, default: []].append(account)
        }
        groups = order.map { Group(name: $0, accounts: members[$0] ?? []) }
        alternates = folded
    }

    public func apiKeys(for account: PiBotAccount) -> [PiBotAccount] { alternates[account.id] ?? [] }
}

public struct PiBotSearchSettings: Codable, Equatable, Sendable {
    public let provider: String
    public let providers: [PiBotAccount]
    public init(provider: String, providers: [PiBotAccount]) { self.provider = provider; self.providers = providers }
    /// The saved key in use: the chosen provider, or else the first one saved.
    public var selected: PiBotAccount? {
        let configured = providers.filter(\.configured)
        return configured.first { $0.id == provider } ?? configured.first
    }
}

public struct PiBotAccountsResult: Codable, Equatable, Sendable {
    public let accounts: [PiBotAccount]
    public let search: PiBotSearchSettings
    public init(accounts: [PiBotAccount], search: PiBotSearchSettings) { self.accounts = accounts; self.search = search }
}

public enum PiBotLoginPrompt: Equatable, Sendable {
    public struct Option: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let description: String?
    }
    case input(kind: String, message: String, placeholder: String?)
    case select(message: String, options: [Option])

    public var isSecret: Bool { if case .input("secret", _, _) = self { true } else { false } }
    public var placeholder: String? {
        guard case .input(let kind, _, let placeholder) = self else { return nil }
        return placeholder ?? (kind == "manual_code" ? "Paste the redirect URL or code" : nil)
    }
}

public enum PiBotLoginEvent: Equatable, Sendable {
    case authURL(url: String, instructions: String?)
    case deviceCode(userCode: String, verificationUri: String)
    case prompt(id: String, PiBotLoginPrompt)
    case promptClosed(id: String)
    case info(String)
    case done
    case error(String)

    private struct Wire: Decodable {
        struct Prompt: Decodable {
            let type: String
            let message: String
            let placeholder: String?
            let options: [PiBotLoginPrompt.Option]?
        }
        let kind: String
        let url: String?
        let instructions: String?
        let userCode: String?
        let verificationUri: String?
        let promptId: String?
        let prompt: Prompt?
        let message: String?
    }

    public init?(json: GatewayJSONValue) {
        guard let data = try? JSONEncoder().encode(json), let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.kind {
        case "auth_url":
            guard let url = wire.url else { return nil }
            self = .authURL(url: url, instructions: wire.instructions)
        case "device_code":
            guard let code = wire.userCode, let uri = wire.verificationUri else { return nil }
            self = .deviceCode(userCode: code, verificationUri: uri)
        case "prompt":
            guard let id = wire.promptId, let prompt = wire.prompt else { return nil }
            if prompt.type == "select" {
                self = .prompt(id: id, .select(message: prompt.message, options: prompt.options ?? []))
            } else {
                self = .prompt(id: id, .input(kind: prompt.type, message: prompt.message, placeholder: prompt.placeholder))
            }
        case "prompt_closed":
            guard let id = wire.promptId else { return nil }
            self = .promptClosed(id: id)
        case "info", "progress": self = .info(wire.message ?? "")
        case "done": self = .done
        case "error": self = .error(wire.message ?? "Sign-in failed.")
        default: return nil
        }
    }
}

/// A sign-in in progress, folded from its event log. Mirrors Pi Bot's `loginView`.
public struct PiBotLoginProgress: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case running, done, failed(String) }

    public private(set) var authURL: String?
    public private(set) var authInstructions: String?
    public private(set) var deviceCode: (userCode: String, verificationUri: String)?
    public private(set) var status = Status.running
    public private(set) var message: String?
    private var prompts: [(id: String, prompt: PiBotLoginPrompt)] = []

    public init(events: [PiBotLoginEvent] = []) { events.forEach { apply($0) } }

    public var openPrompt: (id: String, prompt: PiBotLoginPrompt)? { status == .running ? prompts.last : nil }
    /// A localhost redirect is the one case where the reader has to copy from the address bar.
    public var needsRedirectPaste: Bool {
        guard case .input(_, _, let placeholder)? = openPrompt?.prompt, let placeholder else { return false }
        return placeholder.contains("//localhost") || placeholder.contains("//127.0.0.1")
    }

    public mutating func apply(_ event: PiBotLoginEvent) {
        switch event {
        case .authURL(let url, let instructions): authURL = url; authInstructions = instructions
        case .deviceCode(let code, let uri): deviceCode = (code, uri)
        case .prompt(let id, let prompt):
            prompts.removeAll { $0.id == id }
            prompts.append((id, prompt))
        case .promptClosed(let id): prompts.removeAll { $0.id == id }
        case .info(let text): message = text
        case .done: status = .done
        case .error(let text): status = .failed(text)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.authURL == rhs.authURL && lhs.authInstructions == rhs.authInstructions
            && lhs.deviceCode?.userCode == rhs.deviceCode?.userCode && lhs.status == rhs.status
            && lhs.message == rhs.message && lhs.openPrompt?.id == rhs.openPrompt?.id
    }
}

// MARK: - Models and profiles

public struct PiBotPriceRates: Codable, Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

public struct PiBotModelPricing: Codable, Equatable, Sendable {
    public struct Tier: Codable, Equatable, Sendable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheWrite: Double
        public let inputTokensAbove: Double
        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, inputTokensAbove: Double) {
            self.input = input; self.output = output; self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite; self.inputTokensAbove = inputTokensAbove
        }
        var rates: PiBotPriceRates { PiBotPriceRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite) }
    }
    public let status: String
    public let rates: PiBotPriceRates?
    public let tiers: [Tier]?
    public init(status: String, rates: PiBotPriceRates? = nil, tiers: [Tier]? = nil) {
        self.status = status; self.rates = rates; self.tiers = tiers
    }
}

public struct PiBotModelOption: Codable, Equatable, Identifiable, Sendable {
    public struct Limit: Codable, Equatable, Sendable {
        public let kind: String
        public let label: String
        public let account: String
        public let resetsAt: Double?
    }
    public let id: String
    public let name: String
    public let reasoning: Bool
    public let contextWindow: Double
    public let maxTokens: Double?
    public let input: [String]?
    public let pricing: PiBotModelPricing?
    public let limit: Limit?

    public init(id: String, name: String, reasoning: Bool = false, contextWindow: Double = 0, maxTokens: Double? = nil,
                input: [String]? = nil, pricing: PiBotModelPricing? = nil, limit: Limit? = nil) {
        self.id = id; self.name = name; self.reasoning = reasoning; self.contextWindow = contextWindow
        self.maxTokens = maxTokens; self.input = input; self.pricing = pricing; self.limit = limit
    }
}

public struct PiBotProviderModels: Codable, Equatable, Identifiable, Sendable {
    public struct Access: Codable, Equatable, Sendable {
        public let kind: String
        public let label: String
        public init(kind: String, label: String) { self.kind = kind; self.label = label }
    }
    public let id: String
    public let name: String
    public let access: Access?
    public let models: [PiBotModelOption]
    public init(id: String, name: String, access: Access? = nil, models: [PiBotModelOption]) {
        self.id = id; self.name = name; self.access = access; self.models = models
    }
}

public struct PiBotRoles: Codable, Equatable, Sendable {
    public var titles: String
    public var titlesReasoning: String
    public init(titles: String, titlesReasoning: String) { self.titles = titles; self.titlesReasoning = titlesReasoning }
}

public struct PiBotModelCatalog: Codable, Equatable, Sendable {
    public var providers: [PiBotProviderModels]
    public var roles: PiBotRoles
    public var reasoningLevels: [String]
    public init(providers: [PiBotProviderModels], roles: PiBotRoles, reasoningLevels: [String]) {
        self.providers = providers; self.roles = roles; self.reasoningLevels = reasoningLevels
    }

    public func isKnown(_ ref: String) -> Bool { Self.find(providers, ref) != nil }

    static func find(_ providers: [PiBotProviderModels], _ ref: String) -> (provider: PiBotProviderModels, model: PiBotModelOption)? {
        for provider in providers {
            if let model = provider.models.first(where: { "\(provider.id)/\($0.id)" == ref }) { return (provider, model) }
        }
        return nil
    }
}

/// A model's catalog facts, in Pi Bot's words. Prices are API list prices, never billing.
public enum PiBotModelFacts {
    /// Catalog values as given, never rounded to $0. Only float noise past 10 digits goes.
    public static func usd(_ value: Double) -> String {
        guard value != 0 else { return "$0" }
        let plain = Decimal(string: String(format: "%.9e", value)).map { "\($0)" } ?? "\(value)"
        return "$\(plain)"
    }

    public static func tokens(_ value: Double) -> String {
        if value >= 1_000_000, value.truncatingRemainder(dividingBy: 1_000_000) == 0 { return "\(Int(value / 1_000_000))M" }
        if value >= 1000 { return "\(Int((value / 1000).rounded()))k" }
        return "\(Int(value))"
    }

    private static func rates(_ rates: PiBotPriceRates) -> String {
        "\(usd(rates.input)) in · \(usd(rates.output)) out · \(usd(rates.cacheRead)) cache read · \(usd(rates.cacheWrite)) cache write"
    }

    public static func priceText(_ pricing: PiBotModelPricing?) -> String {
        guard let pricing, pricing.status != "unknown" else { return "API price unknown" }
        if pricing.status == "zero" { return "API price listed as $0 (free or unpriced)" }
        guard let listed = pricing.rates else { return "API price unknown" }
        let tiered = pricing.tiers?.isEmpty == false ? " (other rates above set input sizes)" : ""
        return "\(rates(listed)) per 1M tokens\(tiered)"
    }

    public static func tierTexts(_ pricing: PiBotModelPricing?) -> [String] {
        guard pricing?.status == "listed" else { return [] }
        return (pricing?.tiers ?? []).map { "Above \(tokens($0.inputTokensAbove)) input tokens: \(rates($0.rates)) per 1M tokens" }
    }

    /// Price, capabilities, access and limit state of one model.
    public static func text(_ providers: [PiBotProviderModels], _ ref: String) -> String {
        guard let (provider, model) = PiBotModelCatalog.find(providers, ref) else { return "Not signed in: no catalog details" }
        var parts = [priceText(model.pricing)]
        if model.contextWindow > 0 { parts.append("\(tokens(model.contextWindow)) context") }
        if let max = model.maxTokens, max > 0 { parts.append("\(tokens(max)) max output") }
        if let input = model.input, !input.isEmpty { parts.append(input.joined(separator: ", ")) }
        if model.reasoning { parts.append("reasoning") }
        if let access = provider.access, access.kind != "unknown" { parts.append(access.label) }
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

public struct PiBotProfile: Codable, Equatable, Identifiable, Sendable {
    public struct PoolModel: Codable, Equatable, Sendable {
        public let model: String
        public let useFor: String
        public init(model: String, useFor: String) { self.model = model; self.useFor = useFor }
    }
    public let id: String
    public let name: String
    public let main: String
    public let fallbacks: [String]?
    public let memoryModel: String?
    public let guidance: String?
    public let pool: [PoolModel]
    public let `default`: Bool?

    public init(id: String, name: String, main: String, fallbacks: [String]? = nil, memoryModel: String? = nil,
                guidance: String? = nil, pool: [PoolModel] = [], default isDefault: Bool? = nil) {
        self.id = id; self.name = name; self.main = main; self.fallbacks = fallbacks; self.memoryModel = memoryModel
        self.guidance = guidance; self.pool = pool; self.default = isDefault
    }

    public var isDefault: Bool { `default` == true }
}

public struct PiBotProfilesList: Codable, Equatable, Sendable {
    public let defaultId: String
    public let profiles: [PiBotProfile]
    public init(defaultId: String, profiles: [PiBotProfile]) { self.defaultId = defaultId; self.profiles = profiles }
}

/// The profile editor's working copy. Mirrors `toDraft` and `toInput` in Pi Bot's client.
public struct PiBotProfileDraft: Equatable, Sendable {
    public struct Fallback: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var model: String
        public init(id: UUID = UUID(), model: String = "") { self.id = id; self.model = model }
    }
    public struct PoolEntry: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var model: String
        public var useFor: String
        public init(id: UUID = UUID(), model: String = "", useFor: String = "") { self.id = id; self.model = model; self.useFor = useFor }
    }

    /// Mirrors the server's limit.
    public static let maxFallbacks = 5
    public static let activeMainModel = "Use active main model"

    public var id = ""
    public var name = ""
    public var main = ""
    public var fallbacks: [Fallback] = []
    public var memoryModel = ""
    public var guidance = ""
    public var pool: [PoolEntry] = []

    public init(profile: PiBotProfile? = nil) {
        guard let profile else { return }
        id = profile.id; name = profile.name; main = profile.main
        fallbacks = (profile.fallbacks ?? []).map { Fallback(model: $0) }
        memoryModel = profile.memoryModel ?? ""
        guidance = profile.guidance ?? ""
        pool = profile.pool.map { PoolEntry(model: $0.model, useFor: $0.useFor) }
    }

    public var fallbackModels: [String] { fallbacks.map(\.model).filter { !$0.isEmpty } }
    public var poolModels: [String] { pool.map(\.model).filter { !$0.isEmpty } }
    public var fallbackProblem: String? {
        if fallbackModels.contains(main) { return "A fallback can't be the main model." }
        if Set(fallbackModels).count < fallbackModels.count { return "Each fallback can appear only once." }
        return nil
    }
    public func canSave(isNew: Bool) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !main.isEmpty
            && (!isNew || !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && fallbackProblem == nil
    }

    public var wire: GatewayJSONValue {
        var fields: [String: GatewayJSONValue] = [
            "id": .string(id.trimmingCharacters(in: .whitespacesAndNewlines)),
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "main": .string(main),
            "fallbacks": .array(fallbackModels.map(GatewayJSONValue.string)),
            "pool": .array(pool.filter { !$0.model.isEmpty }.map {
                .object(["model": .string($0.model), "useFor": .string($0.useFor.trimmingCharacters(in: .whitespacesAndNewlines))])
            }),
        ]
        if !memoryModel.isEmpty { fields["memoryModel"] = .string(memoryModel) }
        let preferences = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferences.isEmpty { fields["guidance"] = .string(preferences) }
        return .object(fields)
    }
}

// MARK: - Bots, teams, memory

public struct PiBotDeletedBot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let deletedAt: String
    public init(id: String, name: String, deletedAt: String) { self.id = id; self.name = name; self.deletedAt = deletedAt }
}

public struct PiBotPurgeResult: Codable, Equatable, Sendable {
    public struct Environment: Codable, Equatable, Sendable {
        public let removed: Bool
        public let error: String?
    }
    public let purged: Bool
    public let environment: Environment?
}

public struct PiBotOnboardingStatus: Codable, Equatable, Sendable {
    public let adminId: String
    public let profileId: String
    public let mainModel: String
    public let mainModelAvailable: Bool
    public let signedIn: Bool
    public let needed: Bool
    public init(adminId: String = "", profileId: String = "", mainModel: String = "", mainModelAvailable: Bool = false,
                signedIn: Bool = false, needed: Bool = false) {
        self.adminId = adminId; self.profileId = profileId; self.mainModel = mainModel
        self.mainModelAvailable = mainModelAvailable; self.signedIn = signedIn; self.needed = needed
    }
}

/// Settings order for bots: the orchestrator, each team, then bots on no team; Admin Bot apart.
/// Mirrors Pi Bot's `groupBots`.
public struct PiBotTeamLayout: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let bot: PiBotSummary
        public let isMember: Bool
        public var id: String { bot.id }
    }
    public let rows: [Row]
    public let admin: PiBotSummary?

    public init(_ bots: [PiBotSummary]) {
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

extension PiBotSummary {
    /// What a bot does, separate from its name.
    public var role: String {
        if isAdmin { return "Admin" }
        if orchestrator { return "Orchestrator" }
        return manager ? "Manager" : "Bot"
    }
    /// "none" for no team, "manager" when it leads one, or its manager's id.
    public var placement: String { manager ? "manager" : (managerId ?? "none") }
}

// MARK: - Config and GitHub

public struct PiBotEffectiveConfig: Codable, Equatable, Sendable {
    public struct BotToBot: Codable, Equatable, Sendable {
        public let max_rounds_per_request: Int
        public let max_messages_per_hour_per_pair: Int
    }
    public struct Extraction: Codable, Equatable, Sendable {
        public let schedule: String
        public let timezone: String
    }
    public let bot_to_bot: BotToBot
    public let extraction: Extraction
}

public struct PiBotConfigDocument: Codable, Equatable, Sendable {
    public let path: String?
    public let text: String
    public let exists: Bool
    public let revision: String
    public let restartRequired: Bool
    public let effective: PiBotEffectiveConfig?
    public init(path: String? = nil, text: String = "", exists: Bool = false, revision: String = "",
                restartRequired: Bool = false, effective: PiBotEffectiveConfig? = nil) {
        self.path = path; self.text = text; self.exists = exists; self.revision = revision
        self.restartRequired = restartRequired; self.effective = effective
    }
}

public struct PiBotConfigValidation: Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String?
    public init(ok: Bool, error: String? = nil) { self.ok = ok; self.error = error }
}

public struct PiBotConfigEdit: Equatable, Sendable {
    public let path: [String]
    public let value: GatewayJSONValue
    public init(path: [String], value: GatewayJSONValue) { self.path = path; self.value = value }
    var wire: GatewayJSONValue { .object(["path": .array(path.map(GatewayJSONValue.string)), "value": value]) }
}

/// Bot-to-bot limits and the extraction schedule, as the Limits form edits them.
public struct PiBotLimits: Equatable, Sendable {
    public var maxRounds: String
    public var maxMessages: String
    public var schedule: String
    public var timezone: String

    public init(maxRounds: String = "", maxMessages: String = "", schedule: String = "", timezone: String = "") {
        self.maxRounds = maxRounds; self.maxMessages = maxMessages; self.schedule = schedule; self.timezone = timezone
    }
    public init(_ config: PiBotEffectiveConfig) {
        self.init(maxRounds: String(config.bot_to_bot.max_rounds_per_request),
                  maxMessages: String(config.bot_to_bot.max_messages_per_hour_per_pair),
                  schedule: config.extraction.schedule, timezone: config.extraction.timezone)
    }

    /// Numbers that don't parse are sent as text, so the server is what rejects them.
    public func edits(from before: PiBotLimits) -> [PiBotConfigEdit] {
        func number(_ text: String) -> GatewayJSONValue {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber), let value = Double(trimmed) { return .number(value) }
            return .string(text)
        }
        func text(_ value: String) -> GatewayJSONValue { .string(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var edits: [PiBotConfigEdit] = []
        if maxRounds != before.maxRounds { edits.append(.init(path: ["bot_to_bot", "max_rounds_per_request"], value: number(maxRounds))) }
        if maxMessages != before.maxMessages { edits.append(.init(path: ["bot_to_bot", "max_messages_per_hour_per_pair"], value: number(maxMessages))) }
        if schedule != before.schedule { edits.append(.init(path: ["extraction", "schedule"], value: text(schedule))) }
        if timezone != before.timezone { edits.append(.init(path: ["extraction", "timezone"], value: text(timezone))) }
        return edits
    }
}

public struct PiBotRestart: Codable, Equatable, Sendable {
    public let restarting: Bool
    public let activeWork: Int
    /// "reload" or "exit".
    public let mode: String
    public init(restarting: Bool = true, activeWork: Int = 0, mode: String = "reload") {
        self.restarting = restarting; self.activeWork = activeWork; self.mode = mode
    }
}

public struct PiBotSshKey: Codable, Equatable, Sendable {
    public let type: String
    public let publicKey: String
    public let fingerprint: String
    public let comment: String?
    public init(type: String, publicKey: String, fingerprint: String, comment: String? = nil) {
        self.type = type; self.publicKey = publicKey; self.fingerprint = fingerprint; self.comment = comment
    }
}

public struct PiBotGitHubStatus: Codable, Equatable, Sendable {
    public struct Identity: Codable, Equatable, Sendable {
        public let name: String?
        public let email: String?
        public init(name: String? = nil, email: String? = nil) { self.name = name; self.email = email }
    }
    public let automaticEmail: String?
    public let sshKey: PiBotSshKey?
    public let identity: Identity
    public init(automaticEmail: String? = nil, sshKey: PiBotSshKey? = nil, identity: Identity = Identity()) {
        self.automaticEmail = automaticEmail; self.sshKey = sshKey; self.identity = identity
    }
}

// MARK: - Model status

/// The banner's words for a bot's model status. Mirrors `describeModelStatus`.
public struct PiBotModelStatusText: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case warning, error, success }
    public let tone: Tone
    public let title: String
    public let lines: [String]

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
        case "five_hour": "Your \(limit.account) hit its 5-hour usage limit"
        case "weekly": "Your \(limit.account) hit its weekly usage limit"
        case "credits": "Your \(limit.account) ran out of credits"
        default: "This \(limit.account) ran out of usage"
        }
    }

    static func reset(_ limit: PiBotSummary.ModelStatus.Limit, timeZone: TimeZone) -> String {
        if let resets = limit.resetsAt { return "Resets \(localTime(resets, timeZone: timeZone))." }
        return "Reset time not reported; Pi Bot tries again around \(localTime(limit.retryAt, timeZone: timeZone))."
    }

    public init(status: PiBotSummary.ModelStatus, botName: String, timeZone: TimeZone = .current) {
        let primaryModel = status.primary ?? ""
        if status.kind == "returned" {
            tone = .success
            title = "\(botName) is back on \(primaryModel)."
            lines = ["Its usage limit reset, so Pi Bot switched back from the fallback."]
            return
        }
        let limits = status.limits ?? []
        let primary = limits.first { $0.model == primaryModel } ?? limits.first
        let others = limits.filter { $0 != primary }
        var lines: [String] = []
        if let primary { lines.append(Self.reset(primary, timeZone: timeZone)) }
        for limit in others {
            let described = Self.limit(limit)
            lines.append("Fallback \(limit.model): \(described.prefix(1).lowercased())\(described.dropFirst()). \(Self.reset(limit, timeZone: timeZone))")
        }
        if status.kind == "paused" {
            lines.append(others.isEmpty
                ? "\(botName) is paused: this profile has no fallback. Add one under Settings → Bots → Profiles."
                : "\(botName) is paused: every fallback is out too.")
        } else {
            lines.append("\(botName) is now using \(status.active ?? primaryModel) until then.")
        }
        tone = status.kind == "paused" ? .error : .warning
        title = primary.map { "\(Self.limit($0)) (\($0.model))." } ?? "\(primaryModel) is unavailable."
        self.lines = lines
    }
}

// MARK: - Composer attachments

/// A text file on its way into a message. Pi Bot takes attachments as message text for now.
public struct PiBotAttachmentDraft: Equatable, Identifiable, Sendable {
    public static let maxFileBytes = 80_000
    public static let maxMessageCharacters = 100_000
    static let textExtensions: Set<String> = [
        "txt", "md", "csv", "json", "log", "xml", "yaml", "yml", "ts", "tsx", "js", "jsx", "py", "html", "css", "sh",
    ]

    public enum Problem: LocalizedError, Equatable {
        case tooLarge, notText, binary
        public var errorDescription: String? {
            switch self {
            case .tooLarge: "Attach text files smaller than 80 KB."
            case .notText: "Attachments currently support text, code, and CSV files. Images and binary documents are not supported yet."
            case .binary: "This file contains binary data. Choose a text file."
            }
        }
    }

    public let id: String
    public let name: String
    public let text: String
    public let url: URL

    public init(id: String = UUID().uuidString, name: String, text: String, url: URL) {
        self.id = id; self.name = name; self.text = text; self.url = url
    }

    public static func read(_ url: URL) throws -> PiBotAttachmentDraft {
        let name = url.lastPathComponent
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        if size > maxFileBytes { throw Problem.tooLarge }
        let fileExtension = url.pathExtension.lowercased()
        guard textExtensions.contains(fileExtension) || UTType(filenameExtension: fileExtension)?.conforms(to: .text) == true else {
            throw Problem.notText
        }
        let data = try Data(contentsOf: url)
        if data.contains(0) { throw Problem.binary }
        guard let text = String(data: data, encoding: .utf8) else { throw Problem.binary }
        return PiBotAttachmentDraft(name: name, text: text, url: url)
    }

    /// The wire text for a draft and its attachments.
    public static func message(draft: String, attachments: [PiBotAttachmentDraft]) -> String {
        ([draft.trimmingCharacters(in: .whitespacesAndNewlines)] + attachments.map { "Attached text file: \($0.name)\n\n\($0.text)" })
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

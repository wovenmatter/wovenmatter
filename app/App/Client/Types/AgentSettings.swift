import Foundation

/// A provider Pi Durable and bots can use: a subscription, an API key or a web
/// search key. Sign-ins and keys are per machine.
enum ProviderConnectionID: String, CaseIterable, Identifiable, Hashable, Sendable {
    case chatGPT = "openai-codex"
    case openAI = "openai"
    case grok = "xai"
    case xaiAPI = "xai-api"
    case claudeSubscription = "claude-subscription"
    case claudeAPI = "anthropic"
    case openRouter = "openrouter"
    case openCodeGo = "opencode-go"
    case exa
    case brave
    case firecrawl

    static let searchProviders: [Self] = [.exa, .brave, .firecrawl]
    var isSearchProvider: Bool { Self.searchProviders.contains(self) }
    var isSubscription: Bool { self == .chatGPT || self == .grok || self == .claudeSubscription }
    var id: String { rawValue }

    var name: String {
        switch self {
        case .chatGPT: "ChatGPT subscription"
        case .openAI: "OpenAI API key"
        case .grok: "Grok subscription"
        case .xaiAPI: "xAI API key"
        case .claudeSubscription: "Claude subscription"
        case .claudeAPI: "Claude API key"
        case .openRouter: "OpenRouter"
        case .openCodeGo: "OpenCode Go"
        case .exa: "Exa search"
        case .brave: "Brave Search"
        case .firecrawl: "Firecrawl"
        }
    }
}

/// One saved account or key for a provider on one machine. The first selected
/// one is used; the others are backups in order.
struct ProviderAccount: Identifiable, Hashable, Sendable {
    /// At most this many accounts per provider and machine.
    static let limit = 4

    let id: String
    var label: String
    var createdAt: Date?
    var isSelected: Bool
}

/// Whether a provider's credentials on a machine work.
struct ProviderStatus: Identifiable, Hashable, Sendable {
    let id: String
    var connected: Bool
}

/// What the last sign-in for a provider ended with.
struct ProviderSignInOutcome: Hashable, Sendable {
    let provider: String
    let notice: String?
    let error: String?
}

/// An OpenAI Responses-compatible model server on a machine or the tailnet.
struct LocalModelServer: Identifiable, Hashable, Sendable {
    let id: String
    var url: String
    var models: [String]
    var verifiedAt: Date

    var name: String { URL(string: url)?.host ?? "Local Model Server" }
}

/// Everything Subscriptions & API Keys shows for one machine.
struct MachineProviderConnections: Hashable, Sendable {
    var accounts: [String: [ProviderAccount]] = [:]
    var providers: [ProviderStatus] = []
    var localServers: [LocalModelServer] = []

    /// Providers with usable credentials, search providers excluded.
    var availableModelProviderIDs: Set<String> {
        var result = Set(accounts.filter { !$0.value.isEmpty }.map(\.key))
        for provider in providers {
            if provider.connected { result.insert(provider.id) } else { result.remove(provider.id) }
        }
        return result.subtracting(ProviderConnectionID.searchProviders.map(\.rawValue))
    }

    func connectionLabel(_ id: String) -> String {
        if let provider = providers.first(where: { $0.id == id }) {
            return provider.connected ? "Credentials present" : "Connect account"
        }
        guard let saved = accounts[id] else { return "Status unchecked" }
        return saved.isEmpty ? "Connect account" : "Credential saved · status unchecked"
    }
}

enum BuiltInCodeMode: String, CaseIterable, Hashable, Sendable {
    case on, only, off
    var title: String { switch self { case .on: "On"; case .only: "Only"; case .off: "Off" } }
}

/// Pi Durable's chat settings for all machines or one machine.
struct DefaultAgentSettings: Hashable, Sendable {
    static let providerIDs = ["openai-codex", "openai", "openrouter", "opencode-go", "xai", "xai-api", "claude-subscription", "anthropic"]
    static let subagentConcurrencyRange = 2...24

    var providers: [String] = Self.providerIDs
    /// Models offered in the composer, in order. The default is always offered.
    var models: [String] = []
    var defaultModel: String?
    var fallbackModels: [String] = []
    var searchProvider = "exa"
    var codeMode: BuiltInCodeMode = .on
    /// Active subagents per new conversation, the parent excluded.
    var subagentConcurrency = 8

    var resolvedCodeMode: BuiltInCodeMode { codeMode }
    var resolvedSubagentConcurrency: Int {
        min(Self.subagentConcurrencyRange.upperBound, max(Self.subagentConcurrencyRange.lowerBound, subagentConcurrency))
    }
}

/// Pi Durable's settings: one set for every machine, and the machines that keep their own.
struct PiDurableSettings: Hashable, Sendable {
    var global = DefaultAgentSettings()
    /// Machine ID → its own settings. A machine not listed follows `global`.
    var machines: [String: DefaultAgentSettings] = [:]

    func resolved(_ scope: String) -> DefaultAgentSettings {
        scope == "global" ? global : machines[scope] ?? global
    }
}

/// A model in Pi Durable's catalog.
struct PiDurableModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String
    let providerName: String
}

/// Router prefixes name the connection; the lab is read from the model itself.
enum DefaultAgentModelCatalog {
    static func lab(id: String, name: String) -> String {
        let text = (id + " " + name).lowercased()
        if text.contains("claude") || text.contains("anthropic/") { return "Anthropic" }
        if text.contains("gpt") || text.contains("openai/") || text.range(of: #"(?:^|[/ ])o[134](?:[-/ ]|$)"#, options: .regularExpression) != nil { return "OpenAI" }
        if text.contains("gemini") || text.contains("gemma") || text.contains("google/") { return "Google" }
        if text.contains("grok") || text.contains("x-ai/") { return "xAI" }
        if text.contains("deepseek") { return "DeepSeek" }
        if text.contains("qwen") || text.contains("alibaba/") { return "Alibaba" }
        if text.contains("llama") || text.contains("meta-llama/") { return "Meta" }
        if text.contains("mistral") || text.contains("codestral") || text.contains("devstral") { return "Mistral" }
        if text.contains("kimi") || text.contains("moonshot") { return "Moonshot" }
        if text.contains("glm") || text.contains("z-ai/") { return "Z.ai" }
        if text.contains("minimax") { return "MiniMax" }
        return "Other"
    }
}

/// The Pi Durable SDK installed on one machine.
struct PiDurableSDKStatus: Hashable, Sendable {
    struct SDK: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let installedVersion: String?
        let latestVersion: String?
        let updateAvailable: Bool
        let notice: String?
        let consistent: Bool?
        var displayName: String { id == "pi" ? "Pi Durable SDK" : name }
    }

    let sdks: [SDK]
    let notice: String?
}

enum PiDurableSDKAction: Hashable, Sendable { case status, check, update }

/// SDK state for one machine, as Settings → Pi Durable → Software shows it.
struct PiDurableSDKState: Hashable, Sendable {
    var status: PiDurableSDKStatus?
    var operation: PiDurableSDKAction?
    var error: String?
    var busy: Bool { operation != nil }
}

// MARK: - Defaults for new chats

enum SessionSelectionField: String, CaseIterable, Hashable, Sendable {
    case model, thinking, permission, tools
}

/// A saved choice of model, thinking level, permission mode and Woven tools.
/// A nil field follows the shared or the agent's own default.
struct SessionSelections: Hashable, Sendable {
    var model: String?
    var thinking: String?
    var permission: String?
    var tools: [String]?

    init(model: String? = nil, thinking: String? = nil, permission: String? = nil, tools: [String]? = nil) {
        self.model = model
        self.thinking = thinking
        self.permission = permission
        self.tools = tools
    }

    var isEmpty: Bool { model == nil && thinking == nil && permission == nil && tools == nil }
}

/// The defaults for new chats with one runtime, for all machines or one machine.
struct AgentSelectionDefaults: Hashable, Sendable {
    /// What is saved for this scope.
    var stored: SessionSelections
    /// What a new chat would get.
    var resolved: SessionSelections
    /// The machine follows the defaults for all machines.
    var usesShared: Bool
}

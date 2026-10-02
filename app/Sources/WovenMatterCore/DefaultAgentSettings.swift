import Foundation

public enum BuiltInCodeMode: String, CaseIterable, Codable, Sendable {
    case on, only, off
    public var title: String { switch self { case .on: "On"; case .only: "Only"; case .off: "Off" } }
}

public struct DefaultAgentSettings: Codable, Equatable, Sendable {
    public static let providerIDs = ["openai-codex", "openai", "openrouter", "opencode-go", "xai", "xai-api", "claude-subscription", "anthropic"]
    public var providers: [String] = Self.providerIDs
    /// Explicitly enabled composer models in selector order. The default is always included.
    public var models: [String] = []
    public var defaultModel: String?
    public var fallbackModels: [String] = []
    public var searchProvider = "exa"
    public var customServers: [LocalModelServer]?
    // Optional storage preserves decoding of settings saved before code mode.
    public var codeMode: BuiltInCodeMode? = .on
    public var resolvedCodeMode: BuiltInCodeMode { codeMode ?? .on }
    public init() {}

    /// Apply a UI edit to the latest saved value without undoing a connection
    /// added or removed while the edit was in flight to the background service.
    public func applyingChanges(from base: Self, to edited: Self) -> Self {
        var result = self
        func merge(_ current: [String], _ original: [String], _ requested: [String]) -> [String] {
            guard original != requested else { return current }
            let oldIDs = Set(original), currentIDs = Set(current), requestedIDs = Set(requested)
            var seen = Set<String>()
            return (requested.filter { currentIDs.contains($0) || !oldIDs.contains($0) }
                + current.filter { !oldIDs.contains($0) && !requestedIDs.contains($0) })
                .filter { seen.insert($0).inserted }
        }
        result.providers = merge(providers, base.providers, edited.providers)
        result.models = merge(models, base.models, edited.models)
        result.fallbackModels = merge(fallbackModels, base.fallbackModels, edited.fallbackModels)
        if base.defaultModel != edited.defaultModel { result.defaultModel = edited.defaultModel }
        if base.searchProvider != edited.searchProvider { result.searchProvider = edited.searchProvider }
        if base.customServers != edited.customServers { result.customServers = edited.customServers }
        if base.codeMode != edited.codeMode { result.codeMode = edited.codeMode }
        return result
    }
}

public struct DefaultAgentSettingsScope: Codable, Equatable, Sendable {
    public var global = DefaultAgentSettings()
    /// "local" or the remote workspace UUID. Absence inherits global settings.
    public var workspaces: [String: DefaultAgentSettings] = [:]
    public init() {}
    public func resolved(_ workspace: String) -> DefaultAgentSettings { workspaces[workspace] ?? global }
}

public struct DefaultAgentRunSnapshot: Codable, Equatable, Sendable {
    public let runID: String
    public let content: String
    public let error: String?
    public let model: String?
    public init(runID: String, content: String, error: String? = nil, model: String? = nil) {
        self.runID = runID; self.content = content; self.error = error; self.model = model
    }
}

/// Shared model-catalog classification; router prefixes identify the lab, not the connection.
public enum DefaultAgentModelCatalog {
    public static func lab(id: String, name: String) -> String {
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
    public static func visibleIDs(explicit: [String], defaultModel: String?, catalog: [String]) -> [String] {
        let effectiveDefault = defaultModel.flatMap { catalog.contains($0) ? $0 : nil } ?? catalog.first
        var ids = explicit.filter { catalog.contains($0) }
        if let effectiveDefault, catalog.contains(effectiveDefault), !ids.contains(effectiveDefault) { ids.insert(effectiveDefault, at: 0) }
        return ids
    }
}

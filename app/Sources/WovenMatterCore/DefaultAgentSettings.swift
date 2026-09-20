import Foundation

public struct DefaultAgentSettings: Codable, Equatable, Sendable {
    public static let providerIDs = ["openai-codex", "openai", "openrouter", "opencode-go", "xai"]
    public var providers: [String] = Self.providerIDs
    /// Empty means the full supported catalog, otherwise this is also selector order.
    public var models: [String] = []
    public var defaultModel: String?
    public var fallbackModels: [String] = []
    public var searchProvider = "exa"
    public init() {}
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

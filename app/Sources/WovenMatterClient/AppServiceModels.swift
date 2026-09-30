import Foundation
import WovenMatterCore

/// Provider-supplied presentation kept separate from the exact selection ID.
public struct SessionOptionMetadata: Codable, Equatable, Sendable {
    public let name: String?
    public let description: String?
    public let modelGroup: String?
    public let modelName: String?

    public init(name: String? = nil, description: String? = nil, modelGroup: String? = nil, modelName: String? = nil) {
        self.name = Self.nonempty(name)
        self.description = Self.nonempty(description)
        self.modelGroup = modelGroup
        self.modelName = Self.nonempty(modelName)
    }

    public static func modelLabel(id: String, metadata: Self?) -> String {
        guard let name = metadata?.name else { return id }
        // Some ACP catalogs omit the family from otherwise useful GPT names.
        // Restore only the family proven by the exact ID; keep versions intact.
        if id.hasPrefix("gpt-"), name.range(of: "GPT", options: .caseInsensitive) == nil {
            return "GPT " + name
        }
        return name
    }

    /// The compact composer uses the model alone; the menu keeps its full label.
    public static func modelButtonLabel(id: String, metadata: Self?) -> String {
        if let name = metadata?.modelName {
            return modelLabel(id: id, metadata: Self(name: name))
        }
        // Old Built-in sessions predate modelName. Recognize only their exact
        // provider-qualified IDs and corresponding emitted suffix, never split
        // arbitrary provider-supplied names on a separator.
        if let separator = id.firstIndex(of: "/"), let name = metadata?.name {
            let provider = String(id[..<separator])
            if let attribution = legacyBuiltInAttributions[provider] {
                let suffix = " · " + attribution
                if name.hasSuffix(suffix), name.count > suffix.count {
                    return String(name.dropLast(suffix.count))
                }
            }
        }
        return modelLabel(id: id, metadata: metadata)
    }

    private static let legacyBuiltInAttributions = [
        "openai-codex": "OpenAI · ChatGPT subscription",
        "openai": "OpenAI · API key",
        "openrouter": "OpenRouter",
        "opencode-go": "OpenCode Go",
        "xai": "Grok subscription",
        "xai-api": "xAI · API key",
        "claude-subscription": "Claude · Subscription",
        "anthropic": "Claude · API key",
    ]

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public struct LocalACPSessionMetadata: Codable, Equatable, Sendable {
    public let workingDirectory: String?
    public let sessionKey: String
    public let model: String?
    public let thinking: String?
    public let permission: String?
    public let permissionOptions: [String]?
    public let permissionOptionMetadata: [String: SessionOptionMetadata]?
    public let modelOptions: [String]?
    public let excludedModels: [String]?
    public let allowedModels: [String]?
    public let thinkingLevels: [String]?
    public let modelOptionMetadata: [String: SessionOptionMetadata]?
    public let thinkingOptionMetadata: [String: SessionOptionMetadata]?
    public let slashCommands: [LocalACPSlashCommand]

    public init(
        sessionKey: String,
        model: String?,
        thinking: String?,
        modelOptions: [String]? = nil,
        allowedModels: [String]? = nil,
        excludedModels: [String]? = nil,
        thinkingLevels: [String]? = nil,
        slashCommands: [LocalACPSlashCommand] = [],
        modelOptionMetadata: [String: SessionOptionMetadata]? = nil,
        thinkingOptionMetadata: [String: SessionOptionMetadata]? = nil,
        permission: String? = nil,
        permissionOptions: [String]? = nil,
        permissionOptionMetadata: [String: SessionOptionMetadata]? = nil,
        workingDirectory: String? = nil
    ) {
        self.sessionKey = sessionKey
        self.model = model
        self.thinking = thinking
        self.permission = permission
        self.permissionOptions = permissionOptions
        self.permissionOptionMetadata = permissionOptionMetadata
        self.modelOptions = modelOptions
        self.allowedModels = allowedModels
        self.excludedModels = excludedModels
        self.thinkingLevels = thinkingLevels
        self.slashCommands = slashCommands
        self.modelOptionMetadata = modelOptionMetadata
        self.thinkingOptionMetadata = thinkingOptionMetadata
        self.workingDirectory = workingDirectory
    }

    public var selectableModels: [String] {
        let options = Self.unique((modelOptions ?? allowedModels ?? []) + [model].compactMap { $0 })
            .filter { !(excludedModels ?? []).contains($0) }
        var result: [String] = []
        var groupIndices: [String: Int] = [:]
        for id in options {
            guard let group = modelOptionMetadata?[id]?.modelGroup else {
                result.append(id)
                continue
            }
            if let index = groupIndices[group] {
                let existing = result[index]
                // Keep the exact selected context variant. Otherwise prefer
                // a native plain option without changing the group's order.
                if id == model || (existing != model && existing.hasSuffix("[1m]") && !id.hasSuffix("[1m]")) {
                    result[index] = id
                }
            } else {
                groupIndices[group] = result.count
                result.append(id)
            }
        }
        return result
    }

    public var selectableThinkingLevels: [String] {
        Self.unique(thinkingLevels ?? [])
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
}

/// Restored native chats may appear before their local or remote launch context.
/// Include readiness in the SwiftUI task key so discovery completion retries a
/// skipped refresh, without polling or restarting on unchanged runtime snapshots.
public struct LocalACPSessionMetadataTaskIdentity: Hashable, Sendable {
    private let conversationID: String
    private let runtimeKind: AgentRuntimeKind
    private let launchAvailable: Bool?

    public init?(conversationID: String, runtimeKind: AgentRuntimeKind?,
                 usesOpenClawGateway: Bool, launchAvailable: @autoclosure () -> Bool) {
        guard let runtimeKind else { return nil }
        self.conversationID = conversationID
        self.runtimeKind = runtimeKind
        // These paths watch an existing native session or gateway connection.
        // Do not observe unrelated CLI launch state for either one.
        self.launchAvailable = runtimeKind == .opencode || usesOpenClawGateway
            ? nil : launchAvailable()
    }
}

public struct LocalACPSessionRefreshRequest: Equatable, Hashable, Sendable {
    public let conversationID: String
    fileprivate let generation: UInt64
}

/// Prevents an older SwiftUI refresh task from publishing after its replacement.
public struct LocalACPSessionRefreshLifecycle: Sendable {
    private var activeRefreshes: [String: LocalACPSessionRefreshRequest] = [:]
    private var nextGeneration: UInt64 = 0

    public init() {}

    public var loadingConversationIDs: Set<String> {
        Set(activeRefreshes.keys)
    }

    public mutating func beginRefresh(
        for conversationID: String
    ) -> LocalACPSessionRefreshRequest {
        nextGeneration &+= 1
        let request = LocalACPSessionRefreshRequest(
            conversationID: conversationID,
            generation: nextGeneration
        )
        activeRefreshes[conversationID] = request
        return request
    }

    public func isCurrent(_ request: LocalACPSessionRefreshRequest) -> Bool {
        activeRefreshes[request.conversationID] == request
    }

    public mutating func finish(_ request: LocalACPSessionRefreshRequest) {
        guard isCurrent(request) else { return }
        activeRefreshes.removeValue(forKey: request.conversationID)
    }
}

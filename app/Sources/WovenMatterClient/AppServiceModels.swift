import Foundation

/// Provider-supplied presentation kept separate from the exact selection ID.
public struct SessionOptionMetadata: Codable, Equatable, Sendable {
    public let name: String?
    public let description: String?
    public let modelGroup: String?

    public init(name: String? = nil, description: String? = nil, modelGroup: String? = nil) {
        self.name = Self.nonempty(name)
        self.description = Self.nonempty(description)
        self.modelGroup = modelGroup
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

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

public struct LocalACPSessionMetadata: Codable, Equatable, Sendable {
    public let sessionKey: String
    public let model: String?
    public let thinking: String?
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
        thinkingOptionMetadata: [String: SessionOptionMetadata]? = nil
    ) {
        self.sessionKey = sessionKey
        self.model = model
        self.thinking = thinking
        self.modelOptions = modelOptions
        self.allowedModels = allowedModels
        self.excludedModels = excludedModels
        self.thinkingLevels = thinkingLevels
        self.slashCommands = slashCommands
        self.modelOptionMetadata = modelOptionMetadata
        self.thinkingOptionMetadata = thinkingOptionMetadata
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

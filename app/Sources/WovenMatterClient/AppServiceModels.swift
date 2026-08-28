import Foundation

public struct LocalACPSessionMetadata: Codable, Equatable, Sendable {
    public let sessionKey: String
    public let model: String?
    public let thinking: String?
    public let modelOptions: [String]?
    public let allowedModels: [String]?
    public let thinkingLevels: [String]?
    public let slashCommands: [LocalACPSlashCommand]

    public init(
        sessionKey: String,
        model: String?,
        thinking: String?,
        modelOptions: [String]? = nil,
        allowedModels: [String]? = nil,
        thinkingLevels: [String]? = nil,
        slashCommands: [LocalACPSlashCommand] = []
    ) {
        self.sessionKey = sessionKey
        self.model = model
        self.thinking = thinking
        self.modelOptions = modelOptions
        self.allowedModels = allowedModels
        self.thinkingLevels = thinkingLevels
        self.slashCommands = slashCommands
    }

    public var selectableModels: [String] {
        Self.unique((modelOptions ?? allowedModels ?? []) + [model].compactMap { $0 })
    }

    public var selectableThinkingLevels: [String] {
        Self.unique((thinkingLevels ?? []) + [thinking].compactMap { $0 })
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

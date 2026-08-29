import Foundation
import WovenMatterCore

private actor CodexTitleResponseAccumulator {
    private var value = ""

    func append(_ fragment: String) {
        value.append(fragment)
    }

    func result() -> String { value }
}

public struct CodexTitleGenerationCapabilities: Equatable, Sendable {
    public let currentModel: String?
    public let currentThinking: String?
    public let models: [String]
    public let thinkingLevels: [String]

    public init(configuration: LocalACPSessionConfiguration) {
        currentModel = configuration.model
        currentThinking = configuration.thinking
        models = configuration.modelOptions
        thinkingLevels = configuration.thinkingOptions
    }
}

public enum CodexConversationTitleGeneratorError: LocalizedError {
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "Codex did not return a conversation title."
        }
    }
}

public actor CodexConversationTitleGenerator {
    public init() {}

    public func discover(
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration
    ) async throws -> CodexTitleGenerationCapabilities {
        let client = try LocalACPClient.start(
            launch: launch,
            workingDirectory: workspace.rootURL
        )
        defer { Task { await client.shutdown() } }
        let initialized = try await client.initializeSession(
            workingDirectory: workspace.rootURL,
            existingSessionID: nil,
            title: "Woven Matter title settings",
            systemPrompt: Self.systemPrompt
        )
        return CodexTitleGenerationCapabilities(
            configuration: initialized.configuration
        )
    }

    public func generate(
        firstPrompt: String,
        model: String?,
        thinking: String?,
        launch: LocalACPRuntimeLaunchConfiguration,
        workspace: LocalACPWorkspaceLaunchConfiguration
    ) async throws -> String {
        let client = try LocalACPClient.start(
            launch: launch,
            workingDirectory: workspace.rootURL
        )
        defer { Task { await client.shutdown() } }
        let initialized = try await client.initializeSession(
            workingDirectory: workspace.rootURL,
            existingSessionID: nil,
            title: "Generate Woven Matter conversation title",
            systemPrompt: Self.systemPrompt
        )
        let configuration = initialized.configuration
        let selectedModel = model.flatMap {
            configuration.modelOptions.contains($0) ? $0 : nil
        }
        let selectedThinking = thinking.flatMap {
            configuration.thinkingOptions.contains($0) ? $0 : nil
        }
        if selectedModel != nil || selectedThinking != nil {
            _ = try await client.setSessionConfiguration(
                model: selectedModel,
                thinking: selectedThinking
            )
        }

        let response = CodexTitleResponseAccumulator()
        _ = try await client.prompt(
            "User's first prompt:\n\(firstPrompt)",
            onEvent: { event in
                if case .assistantChunk(let fragment) = event {
                    await response.append(fragment)
                }
            },
            onPermission: { _ in nil }
        )
        let title = Self.sanitize(await response.result())
        guard !title.isEmpty else {
            throw CodexConversationTitleGeneratorError.emptyTitle
        }
        return title
    }

    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = object["title"] as? String {
            candidate = title
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"), start <= end,
                  let data = String(trimmed[start...end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["title"] as? String {
            candidate = title
        } else {
            candidate = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
        let normalized = candidate
            .trimmingCharacters(in: CharacterSet(charactersIn: " `\"'\n\r\t"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalized.count > 50 else { return normalized }
        return String(normalized.prefix(47)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let systemPrompt = """
    Generate a short title that helps the user recognize this conversation later.
    Return JSON with exactly one key: title.
    Use 3 to 8 words and fewer than 40 characters.
    Name the durable subject and desired outcome, not the workflow, tools, model, or agent.
    Do not claim completion. Do not use quotes or trailing punctuation.
    Do not call tools or modify files.
    """
}

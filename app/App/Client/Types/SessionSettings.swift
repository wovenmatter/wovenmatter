import Foundation

/// Label and description for one value a session option can take.
struct SessionOptionMetadata: Hashable, Sendable {
    let name: String?
    let description: String?
    let modelGroup: String?
    let modelName: String?

    init(name: String? = nil, description: String? = nil, modelGroup: String? = nil, modelName: String? = nil) {
        self.name = Self.nonempty(name)
        self.description = Self.nonempty(description)
        self.modelGroup = modelGroup
        self.modelName = Self.nonempty(modelName)
    }

    static func modelLabel(id: String, metadata: Self?) -> String {
        guard let name = metadata?.name else { return id }
        // Some catalogs omit the family from otherwise useful GPT names.
        if id.hasPrefix("gpt-"), name.range(of: "GPT", options: .caseInsensitive) == nil {
            return "GPT " + name
        }
        return name
    }

    /// The compact composer uses the model alone; the menu keeps its full label.
    static func modelButtonLabel(id: String, metadata: Self?) -> String {
        if let name = metadata?.modelName {
            return modelLabel(id: id, metadata: Self(name: name))
        }
        return modelLabel(id: id, metadata: metadata)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct SessionSlashCommand: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let detail: String?
    let argumentHint: String?

    init(name: String, detail: String? = nil, argumentHint: String? = nil) {
        self.name = name
        self.detail = detail
        self.argumentHint = argumentHint
    }
}

/// One shape for a session's settings on every runtime: the chosen model,
/// thinking level and permission mode, what each can be, and the slash
/// commands the runtime offers.
struct SessionSettings: Hashable, Sendable {
    var model: String?
    var thinking: String?
    var permission: String?
    var modelOptions: [String] = []
    var thinkingLevels: [String] = []
    var permissionOptions: [String] = []
    var modelOptionMetadata: [String: SessionOptionMetadata] = [:]
    var thinkingOptionMetadata: [String: SessionOptionMetadata] = [:]
    var permissionOptionMetadata: [String: SessionOptionMetadata] = [:]
    var slashCommands: [SessionSlashCommand] = []
    var workingDirectory: String?

    /// Models to offer, with context variants of one model group folded together.
    var selectableModels: [String] {
        let options = Self.unique(modelOptions + [model].compactMap { $0 })
        var result: [String] = []
        var groupIndices: [String: Int] = [:]
        for id in options {
            guard let group = modelOptionMetadata[id]?.modelGroup else {
                result.append(id)
                continue
            }
            if let index = groupIndices[group] {
                let existing = result[index]
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

    var selectableThinkingLevels: [String] { Self.unique(thinkingLevels) }

    static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
}

/// A change to a session's settings the person asked for.
struct SessionSettingsChange: Hashable, Sendable {
    var model: String?
    var thinking: String?
    var permission: String?
}

// MARK: - Questions, approvals and forms

struct SessionChoice: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let detail: String?
    /// For an approval, the option that allows this one request only.
    let allowsOnce: Bool

    init(id: String, label: String, detail: String? = nil, allowsOnce: Bool = false) {
        self.id = id
        self.label = label
        self.detail = detail
        self.allowsOnce = allowsOnce
    }
}

struct SessionQuestion: Identifiable, Hashable, Sendable {
    let id: String
    let prompt: String
    let options: [SessionChoice]
    let allowsMultiple: Bool
    /// Whether the person may answer in their own words instead.
    let acceptsOwnAnswer: Bool
}

enum SessionFormValue: Hashable, Sendable {
    case string(String), strings([String]), number(Double), boolean(Bool)
}

struct SessionFormField: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case text, singleChoice, multipleChoice, number, integer, boolean }
    let id: String
    let title: String
    let detail: String?
    let kind: Kind
    let required: Bool
    let options: [SessionChoice]
    /// For a choice, whether the person may answer in their own words too.
    let acceptsOwnAnswer: Bool
    let initialValue: SessionFormValue?
    let placeholder: String?
    let multiline: Bool
    let minimum: Double?
    let maximum: Double?
    let minimumLength: Int?
    let maximumLength: Int?

    func accepts(_ value: SessionFormValue) -> Bool {
        switch (kind, value) {
        case (.text, .string(let value)):
            return (minimumLength.map { value.unicodeScalars.count >= $0 } ?? true)
                && (maximumLength.map { value.unicodeScalars.count <= $0 } ?? true)
        case (.singleChoice, .string(let value)): return offers(value)
        case (.multipleChoice, .strings(let values)):
            return Set(values).count == values.count && values.allSatisfy(offers)
                && (minimumLength.map { values.count >= $0 } ?? true) && (maximumLength.map { values.count <= $0 } ?? true)
        case (.number, .number(let value)), (.integer, .number(let value)):
            return value.isFinite && (kind != .integer || value.rounded() == value)
                && (minimum.map { value >= $0 } ?? true) && (maximum.map { value <= $0 } ?? true)
        case (.boolean, .boolean): return true
        default: return false
        }
    }

    /// An option's id, or the person's own words where the field takes them.
    private func offers(_ value: String) -> Bool {
        options.contains { $0.id == value } || (acceptsOwnAnswer && nonemptyString(value) != nil)
    }
}

/// One shape for everything a running turn asks the person, on every runtime.
struct SessionInteraction: Identifiable, Hashable, Sendable {
    enum Request: Hashable, Sendable {
        /// Permission to run a tool; the options are the runtime's own.
        case approval(title: String, options: [SessionChoice])
        case questions(title: String?, questions: [SessionQuestion])
        case form(message: String, fields: [SessionFormField])
    }

    let id: String
    let sessionID: String
    let request: Request
}

/// The answer to one question: the options picked, by id, or the person's
/// own words.
enum SessionQuestionAnswer: Hashable, Sendable {
    case options([String])
    case text(String)
}

enum SessionInteractionResponse: Hashable, Sendable {
    case option(String)
    case answers([String: SessionQuestionAnswer])
    case formValues([String: SessionFormValue])
    case cancelled
}

import Foundation

public enum LocalACPFormValue: Codable, Equatable, Sendable {
    case string(String), strings([String]), number(Double), boolean(Bool)

    var json: ACPJSONValue {
        switch self {
        case .string(let value): .string(value)
        case .strings(let values): .array(values.map(ACPJSONValue.string))
        case .number(let value): .number(value)
        case .boolean(let value): .bool(value)
        }
    }
}

public struct LocalACPFormField: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, singleChoice, multipleChoice, number, integer, boolean }
    public let id: String
    public let title: String
    public let detail: String?
    public let kind: Kind
    public let required: Bool
    public let options: [LocalACPQuestionOption]
    public let initialValue: LocalACPFormValue?
    public let placeholder: String?
    public let multiline: Bool
    public let minimum: Double?
    public let maximum: Double?
    public let minimumLength: Int?
    public let maximumLength: Int?

    public init(id: String, title: String, detail: String? = nil, kind: Kind = .text,
                required: Bool = true, options: [LocalACPQuestionOption] = [], initialValue: LocalACPFormValue? = nil,
                placeholder: String? = nil, multiline: Bool = false, minimum: Double? = nil, maximum: Double? = nil,
                minimumLength: Int? = nil, maximumLength: Int? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.kind = kind; self.required = required
        self.options = options; self.initialValue = initialValue; self.placeholder = placeholder; self.multiline = multiline
        self.minimum = minimum; self.maximum = maximum; self.minimumLength = minimumLength; self.maximumLength = maximumLength
    }

    public func accepts(_ value: LocalACPFormValue) -> Bool {
        switch (kind, value) {
        case (.text, .string(let value)):
            return (minimumLength.map { value.unicodeScalars.count >= $0 } ?? true)
                && (maximumLength.map { value.unicodeScalars.count <= $0 } ?? true)
        case (.singleChoice, .string(let value)): return options.contains { $0.id == value }
        case (.multipleChoice, .strings(let values)):
            return Set(values).count == values.count && values.allSatisfy { value in options.contains { $0.id == value } }
                && (minimumLength.map { values.count >= $0 } ?? true) && (maximumLength.map { values.count <= $0 } ?? true)
        case (.number, .number(let value)), (.integer, .number(let value)):
            return value.isFinite && (kind != .integer || value.rounded() == value)
                && (minimum.map { value >= $0 } ?? true) && (maximum.map { value <= $0 } ?? true)
        case (.boolean, .boolean): return true
        default: return false
        }
    }
}

public struct LocalACPFormRequest: Codable, Equatable, Sendable {
    public let message: String
    public let fields: [LocalACPFormField]
    public init(message: String, fields: [LocalACPFormField]) { self.message = message; self.fields = fields }

    public func accepts(_ values: [String: LocalACPFormValue]) -> Bool {
        Set(values.keys).isSubset(of: Set(fields.map(\.id))) && fields.allSatisfy { field in
            if let value = values[field.id] { return field.accepts(value) }
            return !field.required
        }
    }

    // A bounded flat form subset. Unsupported constraints are declined rather
    // than silently discarded (including unbounded agent-provided regexes).
    static func parse(message: String, schema: ACPJSONValue) throws -> Self {
        func invalid() -> LocalACPClientError { .invalidResponse("Unsupported elicitation form schema") }
        guard case .object(let root) = schema, root["type"]?.stringValue == "object",
              case .object(let properties) = root["properties"], properties.count <= 64,
              Set(root.keys).isSubset(of: ["type", "title", "description", "properties", "required", "additionalProperties", "$schema", "_meta"]),
              root["additionalProperties"] == nil || root["additionalProperties"] == .bool(false) else { throw invalid() }
        let required: [String]
        if let raw = root["required"] {
            guard let array = raw.arrayValue else { throw invalid() }
            required = array.compactMap(\.stringValue)
            guard required.count == array.count, Set(required).count == required.count,
                  Set(required).isSubset(of: Set(properties.keys)) else { throw invalid() }
        } else { required = [] }
        func number(_ value: ACPJSONValue?) throws -> Double? {
            guard let value else { return nil }
            let result: Double
            switch value { case .integer(let v): result = Double(v); case .number(let v): result = v; default: throw invalid() }
            guard result.isFinite else { throw invalid() }; return result
        }
        func count(_ value: ACPJSONValue?) throws -> Int? {
            guard let value else { return nil }
            guard let n = value.integerValue, n >= 0, n <= Int64(Int.max) else { throw invalid() }; return Int(n)
        }
        func choices(_ object: [String: ACPJSONValue], multiple: Bool = false) throws -> [LocalACPQuestionOption] {
            let options: [LocalACPQuestionOption]
            if object["enum"] != nil && object[multiple ? "anyOf" : "oneOf"] != nil { throw invalid() }
            if let raw = object["enum"]?.arrayValue {
                guard raw.count <= 256, raw.allSatisfy({ $0.stringValue != nil }) else { throw invalid() }
                let names = object["enumNames"]?.arrayValue
                if let names, names.count != raw.count || names.contains(where: { $0.stringValue == nil }) { throw invalid() }
                options = raw.enumerated().map { index, value in
                    LocalACPQuestionOption(id: value.stringValue!, label: names?[index].stringValue ?? value.stringValue!)
                }
            } else if let raw = object[multiple ? "anyOf" : "oneOf"]?.arrayValue {
                guard raw.count <= 256 else { throw invalid() }
                options = try raw.map { item in
                    guard case .object(let item) = item, Set(item.keys).isSubset(of: ["const", "title", "description", "_meta"]),
                          let value = item["const"]?.stringValue else { throw invalid() }
                    return LocalACPQuestionOption(id: value, label: item["title"]?.stringValue ?? value,
                                                  detail: item["description"]?.stringValue)
                }
            } else { throw invalid() }
            guard !options.isEmpty, Set(options.map(\.id)).count == options.count else { throw invalid() }
            return options
        }
        let fields = try properties.keys.sorted().map { id -> LocalACPFormField in
            guard case .object(let field) = properties[id],
                  let type = field["type"]?.stringValue else { throw invalid() }
            let annotation: Set<String> = ["type", "title", "description", "default", "_meta"]
            var allowed = annotation
            let kind: LocalACPFormField.Kind
            var options: [LocalACPQuestionOption] = []
            var minLength: Int?, maxLength: Int?, min: Double?, max: Double?
            switch type {
            case "string":
                allowed.formUnion(["minLength", "maxLength", "format", "enum", "enumNames", "oneOf"])
                if field["enum"] != nil || field["oneOf"] != nil { kind = .singleChoice; options = try choices(field) }
                else { kind = .text }
                minLength = try count(field["minLength"]); maxLength = try count(field["maxLength"])
                if kind == .singleChoice, minLength != nil || maxLength != nil { throw invalid() }
            case "array":
                allowed.formUnion(["items", "minItems", "maxItems"]); kind = .multipleChoice
                guard case .object(let items) = field["items"], items["type"] == nil || items["type"] == .string("string"),
                      Set(items.keys).isSubset(of: ["type", "enum", "enumNames", "anyOf", "_meta"]) else { throw invalid() }
                options = try choices(items, multiple: true)
                minLength = try count(field["minItems"]); maxLength = try count(field["maxItems"])
            case "number", "integer":
                allowed.formUnion(["minimum", "maximum"]); kind = type == "number" ? .number : .integer
                min = try number(field["minimum"]); max = try number(field["maximum"])
            case "boolean": kind = .boolean
            default: throw invalid()
            }
            guard Set(field.keys).isSubset(of: allowed), !(min != nil && max != nil && min! > max!),
                  !(minLength != nil && maxLength != nil && minLength! > maxLength!) else { throw invalid() }
            let initial: LocalACPFormValue?
            if let value = field["default"] {
                switch value {
                case .string(let v): initial = .string(v)
                case .bool(let v): initial = .boolean(v)
                case .integer(let v): initial = .number(Double(v))
                case .number(let v): initial = .number(v)
                case .array(let v) where v.allSatisfy({ $0.stringValue != nil }): initial = .strings(v.compactMap(\.stringValue))
                default: throw invalid()
                }
            } else { initial = nil }
            let result = LocalACPFormField(id: id, title: field["title"]?.stringValue ?? id,
                detail: field["description"]?.stringValue, kind: kind, required: required.contains(id), options: options,
                initialValue: initial, minimum: min, maximum: max, minimumLength: minLength, maximumLength: maxLength)
            if let initial, !result.accepts(initial) { throw invalid() }
            return result
        }
        return Self(message: message, fields: fields)
    }
}

// Cancelling a native request must release its wire barrier even if a client UI
// callback is slow to observe cancellation. A late answer cannot win this gate.
final class LocalACPInteractionDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var result: LocalACPInteractionResponse?
    private var continuation: CheckedContinuation<LocalACPInteractionResponse, Never>?
    private var task: Task<Void, Never>?

    func start(_ operation: @escaping @Sendable () async -> LocalACPInteractionResponse) {
        let task = Task { self.resolve(await operation()) }
        let cancelled = lock.withLock { self.task = task; return result == .cancelled }
        if cancelled { task.cancel() }
    }
    func value() async -> LocalACPInteractionResponse {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> LocalACPInteractionResponse? in
                if let result { return result }
                self.continuation = continuation; return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
    func cancel() {
        resolve(.cancelled)
        lock.withLock { task }?.cancel()
    }
    private func resolve(_ value: LocalACPInteractionResponse) {
        let continuation = lock.withLock { () -> CheckedContinuation<LocalACPInteractionResponse, Never>? in
            guard result == nil else { return nil }
            result = value; defer { self.continuation = nil }; return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

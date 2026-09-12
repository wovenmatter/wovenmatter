import Foundation

/// JSON at the beta protocol boundary. Unknown fields remain available for
/// inspection and round trips; routing and mutation inputs are explicitly typed.
public enum OpenCodeValue: Codable, Equatable, Hashable, Sendable {
    case object([String: OpenCodeValue]), array([OpenCodeValue]), string(String)
    case number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([OpenCodeValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: OpenCodeValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> OpenCodeValue {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v = object; v[key] = newValue; self = .object(v) }
    }
    public var object: [String: OpenCodeValue] { if case .object(let v) = self { v } else { [:] } }
    public var array: [OpenCodeValue] { if case .array(let v) = self { v } else { [] } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var text: String { string ?? "" }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var bool: Bool { if case .bool(let v) = self { v } else { false } }
    public var isNull: Bool { self == .null }
    public var json: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
    public static func decode(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

extension OpenCodeValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension OpenCodeValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, OpenCodeValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}

public enum OpenCodeError: LocalizedError, Equatable, Sendable {
    case message(String), http(Int), incompatible(String), malformedStream, uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .http(401): "OpenCode rejected the credentials. Reconnect with the service's current credentials."
        case .http(404): "This OpenCode resource no longer exists on the connected service."
        case .http(let code): "OpenCode returned HTTP \(code)."
        case .incompatible(let version): "OpenCode \(version) is unsupported. This build supports \(OpenCodeConnection.supportedVersion)."
        case .malformedStream: "OpenCode sent an invalid or oversized event. Reconnecting and reconciling session state."
        case .uncertain(let id): "OpenCode may have accepted input \(id). Woven Matter will reconcile it without resending."
        }
    }
}

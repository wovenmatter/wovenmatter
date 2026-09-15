import Foundation

/// JSON at the native Hermes protocol boundary. Unknown fields remain available for
/// inspection and round trips; routing and mutation inputs are explicitly typed.
public enum HermesValue: Codable, Equatable, Hashable, Sendable {
    case object([String: HermesValue]), array([HermesValue]), string(String)
    case number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([HermesValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: HermesValue].self)) }
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
    public subscript(_ key: String) -> HermesValue {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v = object; v[key] = newValue; self = .object(v) }
    }
    public var object: [String: HermesValue] { if case .object(let v) = self { v } else { [:] } }
    public var array: [HermesValue] { if case .array(let v) = self { v } else { [] } }
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

extension HermesValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension HermesValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, HermesValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}

public enum HermesGatewayError: LocalizedError, Sendable {
    case message(String)
    case rpc(code: Int, message: String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .rpc(_, let message): return "Hermes: " + message
        }
    }
}

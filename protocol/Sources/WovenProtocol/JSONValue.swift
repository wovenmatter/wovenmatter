import Foundation

/// Any JSON value. Request parameters, replies and events travel as this
/// inside the envelope and are decoded into their typed form by whoever knows
/// the method.
public enum JSONValue: Codable, Sendable, Hashable {
  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Int64.self) { self = .integer(value) }
    else if let value = try? container.decode(Double.self) { self = .double(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
    else { self = .object(try container.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// The JSON form of any encodable value.
  public init(encoding value: some Encodable) throws {
    self = try Wire.decoder.decode(JSONValue.self, from: Wire.encoder.encode(value))
  }

  /// This value decoded as `type`.
  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try Wire.decoder.decode(type, from: Wire.encoder.encode(self))
  }
}

/// The one JSON configuration used on the wire.
public enum Wire {
  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

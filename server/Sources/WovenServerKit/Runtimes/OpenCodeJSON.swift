import Foundation

/// JSON as OpenCode's HTTP API sends it, read by key without a type per message.
enum OpenCodeJSON: Codable, Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByArrayLiteral, ExpressibleByBooleanLiteral {
  case object([String: OpenCodeJSON])
  case array([OpenCodeJSON])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(stringLiteral value: String) { self = .string(value) }
  init(dictionaryLiteral elements: (String, OpenCodeJSON)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
  init(arrayLiteral elements: OpenCodeJSON...) { self = .array(elements) }
  init(booleanLiteral value: Bool) { self = .bool(value) }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([OpenCodeJSON].self) { self = .array(value) }
    else { self = .object(try container.decode([String: OpenCodeJSON].self)) }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  static func decode(_ data: Data) throws -> OpenCodeJSON { try JSONDecoder().decode(OpenCodeJSON.self, from: data) }

  subscript(_ key: String) -> OpenCodeJSON {
    if case .object(let value) = self { return value[key] ?? .null }
    return .null
  }

  var array: [OpenCodeJSON] { if case .array(let value) = self { value } else { [] } }
  var string: String? { if case .string(let value) = self { value } else { nil } }
  var text: String { string ?? "" }
  var number: Double? { if case .number(let value) = self { value } else { nil } }
  var int: Int64 { number.map { Int64($0) } ?? 0 }
  var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
  var isNull: Bool { self == .null }

  /// Compact JSON text with sorted keys, for tool input.
  var jsonText: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
  }
}

/// Server-sent events, byte by byte. OpenCode sends each event as one
/// `data:` line of JSON followed by a blank line.
struct OpenCodeSSEParser: Sendable {
  private var line = Data()
  private var data = Data()
  private var afterCarriageReturn = false

  /// Takes more bytes and returns the events they complete. A frame that is
  /// not JSON is skipped.
  mutating func append(_ bytes: Data) -> [OpenCodeJSON] {
    var events: [OpenCodeJSON] = []
    for byte in bytes {
      if afterCarriageReturn && byte == 10 {
        afterCarriageReturn = false
        continue
      }
      afterCarriageReturn = byte == 13
      guard byte == 10 || byte == 13 else {
        line.append(byte)
        continue
      }
      if line.isEmpty {
        if !data.isEmpty, let event = try? OpenCodeJSON.decode(data) { events.append(event) }
        data.removeAll(keepingCapacity: true)
      } else if line.starts(with: Data("data:".utf8)) {
        let payload = line.dropFirst(5)
        if !data.isEmpty { data.append(10) }
        data.append(payload.first == 32 ? payload.dropFirst() : payload)
      }
      line.removeAll(keepingCapacity: true)
    }
    return events
  }
}

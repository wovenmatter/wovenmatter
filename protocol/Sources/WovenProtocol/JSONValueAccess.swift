import Foundation

extension JSONValue {
  /// A member of an object, or nil.
  public subscript(_ key: String) -> JSONValue? {
    if case .object(let object) = self { object[key] } else { nil }
  }

  public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
  public var string: String? { if case .string(let value) = self { value } else { nil } }
  public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
  public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }

  /// A whole number, or nil.
  public var int: Int? {
    switch self {
    case .integer(let value): Int(exactly: value)
    case .double(let value): Int(exactly: value)
    default: nil
    }
  }

  public var double: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .double(let value): value
    default: nil
    }
  }
}

extension JSONValue {
  /// A JSON number: an integer when it is a whole number that fits one.
  public static func number(_ value: Double) -> JSONValue {
    if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return .integer(Int64(value)) }
    return .double(value)
  }
}

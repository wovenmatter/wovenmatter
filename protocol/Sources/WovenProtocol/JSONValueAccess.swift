import Foundation

extension JSONValue {
  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    switch self {
    case .integer(let value): Int(exactly: value)
    case .double(let value): Int(exactly: value)
    default: nil
    }
  }

  public var doubleValue: Double? {
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

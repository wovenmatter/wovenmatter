import Foundation

// Devices of one user run different versions for days, so a value another
// device wrote may hold something this build does not know. These wrappers are
// for READ paths only: a list keeps the elements this build can read, and an
// optional detail reads as absent, instead of the whole page failing. Requests
// a device must not lose (journal ingest, registrations, mutations, commands)
// stay strict, so their sender keeps the data and retries after an update.
// Both wrappers encode exactly as the plain array or optional they wrap.

/// An array decoded element by element. An element this build cannot read is
/// dropped and kept as raw JSON in `unreadable`; the others decode normally.
@propertyWrapper
public struct LossyArray<Element> {
  public var wrappedValue: [Element]
  /// The elements the decode dropped, in order. Never encoded or compared.
  public private(set) var unreadable: [JSONValue] = []
  public init(wrappedValue: [Element]) { self.wrappedValue = wrappedValue }
  /// `$name.unreadable` tells a consumer that the list is not the whole list.
  public var projectedValue: LossyArray<Element> { self }
}

extension LossyArray: Sendable where Element: Sendable {}
extension LossyArray: Equatable where Element: Equatable {
  public static func == (left: Self, right: Self) -> Bool { left.wrappedValue == right.wrappedValue }
}

extension LossyArray: Decodable where Element: Decodable {
  public init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var elements: [Element] = [], dropped: [JSONValue] = []
    while !container.isAtEnd {
      // A failed decode leaves the container on the same element; reading it
      // as raw JSON moves past it.
      do { elements.append(try container.decode(Element.self)) }
      catch { dropped.append(try container.decode(JSONValue.self)) }
    }
    wrappedValue = elements; unreadable = dropped
    if !dropped.isEmpty {
      NSLog("Ignoring %ld unreadable %@ value(s) another device sent", dropped.count, String(describing: Element.self))
    }
  }
}

extension LossyArray: Encodable where Element: Encodable {
  public func encode(to encoder: any Encoder) throws { try wrappedValue.encode(to: encoder) }
}

/// An optional detail that reads as nil when this build cannot decode it, so
/// the value that carries it still decodes.
@propertyWrapper
public struct LossyOptional<Value> {
  public var wrappedValue: Value?
  public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
}

extension LossyOptional: Sendable where Value: Sendable {}
extension LossyOptional: Equatable where Value: Equatable {}

extension LossyOptional: Decodable where Value: Decodable {
  public init(from decoder: any Decoder) throws {
    do { wrappedValue = try Value(from: decoder) }
    catch {
      wrappedValue = nil
      NSLog("Ignoring an unreadable %@ value another device sent", String(describing: Value.self))
    }
  }
}

extension LossyOptional: Encodable where Value: Encodable {
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
  }
}

// Synthesized `Codable` calls these for a wrapped property, so a missing or
// null key still reads as nil and a nil value still leaves its key out.
extension KeyedDecodingContainer {
  public func decode<Value: Decodable>(_ type: LossyOptional<Value>.Type, forKey key: Key) throws -> LossyOptional<Value> {
    try decodeIfPresent(type, forKey: key) ?? LossyOptional(wrappedValue: nil)
  }
}
extension KeyedEncodingContainer {
  public mutating func encode<Value: Encodable>(_ value: LossyOptional<Value>, forKey key: Key) throws {
    try encodeIfPresent(value.wrappedValue, forKey: key)
  }
}

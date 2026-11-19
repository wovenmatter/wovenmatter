import Foundation

/// One SQLite value. Text is a JSON string, an integer a JSON number, null is
/// null; reals and blobs are tagged so they keep their type.
public enum SQLValue: Codable, Sendable, Hashable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)

  private enum Tag: String, CodingKey { case real, blob }

  public init(from decoder: any Decoder) throws {
    if let keyed = try? decoder.container(keyedBy: Tag.self) {
      if let value = try keyed.decodeIfPresent(Double.self, forKey: .real) { self = .real(value); return }
      if let value = try keyed.decodeIfPresent(Data.self, forKey: .blob) { self = .blob(value); return }
    }
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Int64.self) { self = .integer(value) }
    else { self = .text(try container.decode(String.self)) }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .real(let value):
      var keyed = encoder.container(keyedBy: Tag.self)
      try keyed.encode(value, forKey: .real)
    case .blob(let value):
      var keyed = encoder.container(keyedBy: Tag.self)
      try keyed.encode(value, forKey: .blob)
    case .null:
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    case .integer(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .text(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    }
  }
}

/// One synced row exactly as its library holds it, minus the local `changed`
/// counter. A machine passes rows on unchanged, so any machine can relay
/// another machine's writes.
public struct SyncRow: Codable, Sendable, Hashable {
  public var table: String
  public var id: String
  /// Hybrid logical clock value of the last write.
  public var stamp: String
  public var deleted: Bool
  /// Every other column, by name.
  public var values: [String: SQLValue]

  public init(table: String, id: String, stamp: String, deleted: Bool, values: [String: SQLValue]) {
    self.table = table
    self.id = id
    self.stamp = stamp
    self.deleted = deleted
    self.values = values
  }
}

/// Rows whose `changed` is above the cursor the puller sent, in `changed` order.
public struct SyncPage: Codable, Sendable, Hashable {
  public var rows: [SyncRow]
  /// The cursor to send next time: the `changed` of the last row here.
  public var next: Int64
  /// More rows wait beyond this page.
  public var more: Bool

  public init(rows: [SyncRow], next: Int64, more: Bool) {
    self.rows = rows
    self.next = next
    self.more = more
  }
}

/// Part of a file from the content store.
public struct ContentChunk: Codable, Sendable, Hashable {
  public var data: Data
  /// The whole file's size in bytes.
  public var size: Int64

  public init(data: Data, size: Int64) {
    self.data = data
    self.size = size
  }
}

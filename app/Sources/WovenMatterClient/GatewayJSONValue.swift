import Foundation
import WovenMatterCore

public enum GatewayJSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: GatewayJSONValue])
  case array([GatewayJSONValue])
  case null

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([String: GatewayJSONValue].self) { self = .object(value) }
    else { self = .array(try container.decode([GatewayJSONValue].self)) }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var objectValue: [String: GatewayJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [GatewayJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    guard case .number(let value) = self else { return nil }
    return Int(exactly: value)
  }

  public var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }
}

public struct OpenClawGatewayEvent: Equatable, Sendable {
  public let name: String
  public let payload: GatewayJSONValue?
  public let sequence: Int?

  public init(name: String, payload: GatewayJSONValue?, sequence: Int?) {
    self.name = name
    self.payload = payload
    self.sequence = sequence
  }
}

public enum OpenClawGatewayClientError: LocalizedError, Equatable, Sendable {
  case invalidEndpoint
  case connectionClosed
  case malformedFrame
  case challengeMissing
  case authenticationMissing
  case unavailable(String, retryAfterMilliseconds: Int?)
  case rejected(String)
  case unsupportedCapability(String)
  case requestTimedOut(String)

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint: "The OpenClaw Gateway endpoint is invalid."
    case .connectionClosed: "The OpenClaw Gateway connection is unavailable."
    case .malformedFrame: "OpenClaw Gateway returned an invalid protocol frame."
    case .challengeMissing: "OpenClaw Gateway did not provide a connection challenge."
    case .authenticationMissing: "OpenClaw Gateway authentication is missing."
    case .unavailable(let message, _): "OpenClaw Gateway is starting: \(message)"
    case .rejected(let message): "OpenClaw Gateway rejected the request: \(message)"
    case .unsupportedCapability(let method): "This OpenClaw Gateway does not support \(method)."
    case .requestTimedOut(let method): "OpenClaw Gateway timed out while running \(method)."
    }
  }
}

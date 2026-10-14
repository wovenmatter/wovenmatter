@_exported import WovenMatterCompanion
import Foundation

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

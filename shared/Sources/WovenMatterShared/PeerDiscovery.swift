import Foundation

public enum DeviceKind: String, Codable, Sendable { case mac, iPhone, iPad, unknown }
public struct DeviceMetadata: Codable, Equatable, Sendable {
  public let kind: DeviceKind
  public let osVersion: String?
  public let appVersion: String?
  public let developmentInstance: String?
  public init(kind: DeviceKind = .unknown, osVersion: String? = nil, appVersion: String? = nil, developmentInstance: String? = nil) {
    self.kind = kind; self.osVersion = osVersion; self.appVersion = appVersion; self.developmentInstance = developmentInstance
  }
}
public struct PairingDeviceIdentity: Codable, Equatable, Sendable {
  public let deviceID: String
  public let deviceName: String
  public let metadata: DeviceMetadata
  public init(deviceID: String, deviceName: String, metadata: DeviceMetadata) {
    self.deviceID = deviceID; self.deviceName = deviceName; self.metadata = metadata
  }
}
/// A library member Mac's advertisement. Public to this tailnet; deliberately
/// contains no workspace contents or secrets.
public struct DiscoveryAdvertisement: Codable, Equatable, Sendable {
  public let identity: PairingDeviceIdentity
  public let protocolVersion: Int
  public let capabilities: [String]?
  public init(identity: PairingDeviceIdentity, protocolVersion: Int = LibraryProtocol.version, capabilities: [String]? = nil) {
    self.capabilities = capabilities
    self.identity = identity; self.protocolVersion = protocolVersion
  }
}
public struct DiscoveredPeer: Codable, Equatable, Sendable, Identifiable {
  public var id: String { endpoint.absoluteString }
  public let endpoint: URL
  public let advertisement: DiscoveryAdvertisement
  public init(endpoint: URL, advertisement: DiscoveryAdvertisement) {
    self.endpoint = endpoint; self.advertisement = advertisement
  }
}
/// The client retains a random request secret. Neither the public queue nor a
/// guessed request ID can redeem an approved device credential.
public struct PairingApprovalRequest: Codable, Equatable, Sendable {
  public let requestID: String
  public let requestSecret: String
  public let invitationToken: String?
  public let identity: PairingDeviceIdentity
  public let protocolVersion: Int
  public let purpose: String?
  public init(requestID: String, requestSecret: String, identity: PairingDeviceIdentity, protocolVersion: Int = LibraryProtocol.version, invitationToken: String? = nil, purpose: String? = nil) {
    self.requestID = requestID; self.requestSecret = requestSecret; self.identity = identity; self.protocolVersion = protocolVersion; self.invitationToken = invitationToken
    self.purpose = purpose
  }
}
public struct PairingPoll: Codable, Sendable {
  public let requestID: String
  public let requestSecret: String
  public init(requestID: String, requestSecret: String) { self.requestID = requestID; self.requestSecret = requestSecret }
}
public enum PairingApprovalState: String, Codable, Sendable { case pending, approved, denied }
public struct PendingPairingRequest: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let identity: PairingDeviceIdentity
  public let expiresAt: Date
  public init(id: String, identity: PairingDeviceIdentity, expiresAt: Date) {
    self.id = id; self.identity = identity; self.expiresAt = expiresAt
  }
}
public struct PairingApprovalResult: Codable, Equatable, Sendable {
  public let state: PairingApprovalState
  public let expiresAt: Date
  public let pairing: PairResponse?
  public init(state: PairingApprovalState, expiresAt: Date, pairing: PairResponse? = nil) {
    self.state = state; self.expiresAt = expiresAt; self.pairing = pairing
  }
}
/// Read-only roster projection; credential digests and pending claim material
/// are never serialized onto the pairing network.
public struct DeviceConnection: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let metadata: DeviceMetadata
  public let pairedAt: Date
  public let lastSeenAt: Date?
  public init(id: String, name: String, metadata: DeviceMetadata, pairedAt: Date, lastSeenAt: Date?) {
    self.id = id; self.name = name; self.metadata = metadata; self.pairedAt = pairedAt; self.lastSeenAt = lastSeenAt
  }
}

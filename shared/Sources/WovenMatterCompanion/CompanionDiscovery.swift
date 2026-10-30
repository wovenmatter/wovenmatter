import Foundation

public enum CompanionDeviceKind: String, Codable, Sendable { case mac, iPhone, iPad, unknown }
public struct CompanionDeviceMetadata: Codable, Equatable, Sendable {
  public let kind: CompanionDeviceKind
  public let osVersion: String?
  public let appVersion: String?
  public let developmentInstance: String?
  public init(kind: CompanionDeviceKind = .unknown, osVersion: String? = nil, appVersion: String? = nil, developmentInstance: String? = nil) {
    self.kind = kind; self.osVersion = osVersion; self.appVersion = appVersion; self.developmentInstance = developmentInstance
  }
}
public struct CompanionPairingDeviceIdentity: Codable, Equatable, Sendable {
  public let deviceID: String
  public let deviceName: String
  public let metadata: CompanionDeviceMetadata
  public init(deviceID: String, deviceName: String, metadata: CompanionDeviceMetadata) {
    self.deviceID = deviceID; self.deviceName = deviceName; self.metadata = metadata
  }
}
public enum CompanionDiscoveryRole: String, Codable, Sendable { case central, client }
/// Public to this tailnet; deliberately contains no workspace contents or secrets.
public struct CompanionDiscoveryAdvertisement: Codable, Equatable, Sendable {
  public let role: CompanionDiscoveryRole
  public let identity: CompanionPairingDeviceIdentity
  public let protocolVersion: Int
  public let capabilities: [String]?
  public init(role: CompanionDiscoveryRole, identity: CompanionPairingDeviceIdentity, protocolVersion: Int = CompanionProtocol.version, capabilities: [String]? = nil) {
    self.capabilities = capabilities
    self.role = role; self.identity = identity; self.protocolVersion = protocolVersion
  }
}
public struct CompanionDiscoveredPeer: Codable, Equatable, Sendable, Identifiable {
  public var id: String { endpoint.absoluteString }
  public let endpoint: URL
  public let advertisement: CompanionDiscoveryAdvertisement
  public init(endpoint: URL, advertisement: CompanionDiscoveryAdvertisement) {
    self.endpoint = endpoint; self.advertisement = advertisement
  }
}
/// The client retains a random request secret. Neither the public queue nor a
/// guessed request ID can redeem an approved device credential.
public struct CompanionPairingApprovalRequest: Codable, Equatable, Sendable {
  public let requestID: String
  public let requestSecret: String
  public let invitationToken: String?
  public let identity: CompanionPairingDeviceIdentity
  public let protocolVersion: Int
  public let purpose: String?
  public init(requestID: String, requestSecret: String, identity: CompanionPairingDeviceIdentity, protocolVersion: Int = CompanionProtocol.version, invitationToken: String? = nil, purpose: String? = nil) {
    self.requestID = requestID; self.requestSecret = requestSecret; self.identity = identity; self.protocolVersion = protocolVersion; self.invitationToken = invitationToken
    self.purpose = purpose
  }
}
public struct CompanionPairingPoll: Codable, Sendable {
  public let requestID: String
  public let requestSecret: String
  public init(requestID: String, requestSecret: String) { self.requestID = requestID; self.requestSecret = requestSecret }
}
public enum CompanionPairingApprovalState: String, Codable, Sendable { case pending, approved, denied }
public struct CompanionPendingPairingRequest: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let identity: CompanionPairingDeviceIdentity
  public let expiresAt: Date
  public init(id: String, identity: CompanionPairingDeviceIdentity, expiresAt: Date) {
    self.id = id; self.identity = identity; self.expiresAt = expiresAt
  }
}
public struct CompanionPairingApprovalResult: Codable, Equatable, Sendable {
  public let state: CompanionPairingApprovalState
  public let expiresAt: Date
  public let pairing: CompanionPairResponse?
  public init(state: CompanionPairingApprovalState, expiresAt: Date, pairing: CompanionPairResponse? = nil) {
    self.state = state; self.expiresAt = expiresAt; self.pairing = pairing
  }
}
/// A central Mac creates this only after the user chooses Invite. Receiving it
/// does not pair the client: the receiving Mac must explicitly accept locally.
public struct CompanionPairingInvitation: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let central: CompanionPairingDeviceIdentity
  public let payload: CompanionPairingPayload
  public let expiresAt: Date
  public init(id: String, central: CompanionPairingDeviceIdentity, payload: CompanionPairingPayload, expiresAt: Date) {
    self.id = id; self.central = central; self.payload = payload; self.expiresAt = expiresAt
  }
}

/// Read-only roster projection; credential digests and pending claim material
/// are never serialized onto the companion network.
public struct CompanionDeviceConnection: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let metadata: CompanionDeviceMetadata
  public let pairedAt: Date
  public let lastSeenAt: Date?
  public init(id: String, name: String, metadata: CompanionDeviceMetadata, pairedAt: Date, lastSeenAt: Date?) {
    self.id = id; self.name = name; self.metadata = metadata; self.pairedAt = pairedAt; self.lastSeenAt = lastSeenAt
  }
}

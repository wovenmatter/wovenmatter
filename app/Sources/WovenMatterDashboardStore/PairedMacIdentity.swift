import CryptoKit
import Foundation
import WovenMatterCore

/// Paired-Mac identity is separate from authentication. Signed membership pins
/// keys and records introductions and revocations; it never carries a bearer.
/// Each Mac authenticates only grants it issued itself (target-local grants).
public enum PeerIdentifier {
  /// The lowercase canonical UUID text, or nil. Non-canonical envelopes are
  /// rejected rather than normalized so signed and compared values agree.
  public static func canonical(_ value: String) -> String? {
    guard value.utf8.count == 36, let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else { return nil }
    return value
  }
  /// Local identities from older stores are normalized once on this Mac.
  public static func normalized(_ value: String) -> String? { UUID(uuidString: value)?.uuidString.lowercased() }
  static let maximumRevocationsPerDevice = 64
}

/// Immutable device-UUID pin for a paired Mac's signing key. Local only.
public struct PeerPin: Codable, Equatable, Sendable {
  public let libraryID: String
  public let publicKey: Data
  public init(libraryID: String, publicKey: Data) { self.libraryID = libraryID; self.publicKey = publicKey }
}

/// This Mac's signing identity, loaded from device-only storage.
public struct PeerSelf: Sendable {
  public let deviceID: String
  public let libraryID: String
  public let key: Curve25519.Signing.PrivateKey
  public init(deviceID: String, libraryID: String, key: Curve25519.Signing.PrivateKey) {
    self.deviceID = deviceID.lowercased(); self.libraryID = libraryID.lowercased(); self.key = key
  }
  public var publicKey: Data { key.publicKey.rawRepresentation }
  public var pin: PeerPin { .init(libraryID: libraryID, publicKey: publicKey) }
}

/// One unpair action. Distinct concurrent unpairs are distinct events; a grant
/// or admission stays valid only while it acknowledges every known event for
/// its device, so revocations merge as a set rather than a clock or counter.
public struct PeerRevocation: Codable, Equatable, Hashable, Sendable {
  public let eventID: String
  public let deviceID: String
  public let revokerDeviceID: String
  public let signature: Data
  static func statement(eventID: String, deviceID: String, revokerDeviceID: String) -> Data {
    canonical([("event", eventID), ("device", deviceID), ("revoker", revokerDeviceID)], domain: "woven.peer.revocation.v2")
  }
  static func signed(deviceID: String, by own: PeerSelf) throws -> Self {
    let eventID = UUID().uuidString.lowercased()
    return .init(eventID: eventID, deviceID: deviceID, revokerDeviceID: own.deviceID,
      signature: try own.key.signature(for: statement(eventID: eventID, deviceID: deviceID, revokerDeviceID: own.deviceID)))
  }
  var isWellFormed: Bool {
    PeerIdentifier.canonical(eventID) != nil && PeerIdentifier.canonical(deviceID) != nil && PeerIdentifier.canonical(revokerDeviceID) != nil
      && signature.count == 64
  }
  func verifies(_ key: Data) -> Bool {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { return false }
    return key.isValidSignature(signature, for: Self.statement(eventID: eventID, deviceID: deviceID, revokerDeviceID: revokerDeviceID))
  }
}

/// A signed introduction of a subject Mac's key by an issuer Mac. The subject
/// signs exactly this statement, including the complete set of revocation
/// events for it that the issuer knew, so no issuer can relabel an old proof
/// into a newer revocation context. The issuer countersigns the subject proof.
public struct PeerAdmission: Codable, Equatable, Sendable {
  public static let protocolName = "woven.peer.admission.v2"
  public static let role = "mac"
  public let issuerDeviceID: String
  public let issuerLibraryID: String
  public let subjectDeviceID: String
  public let subjectLibraryID: String
  public let subjectPublicKey: Data
  public let acknowledgedRevocations: [String]
  public let subjectSignature: Data
  public let issuerSignature: Data

  public static func subjectStatement(issuerDeviceID: String, issuerLibraryID: String, subjectDeviceID: String,
                                      subjectLibraryID: String, subjectPublicKey: Data, acknowledgedRevocations: [String]) -> Data {
    canonical([("protocol", protocolName), ("role", role), ("issuer", issuerDeviceID), ("issuer_library", issuerLibraryID),
               ("subject", subjectDeviceID), ("subject_library", subjectLibraryID),
               ("subject_key", subjectPublicKey.base64EncodedString()),
               ("revocations", acknowledgedRevocations.sorted().joined(separator: ","))])
  }
  var subjectStatement: Data {
    Self.subjectStatement(issuerDeviceID: issuerDeviceID, issuerLibraryID: issuerLibraryID, subjectDeviceID: subjectDeviceID,
      subjectLibraryID: subjectLibraryID, subjectPublicKey: subjectPublicKey, acknowledgedRevocations: acknowledgedRevocations)
  }
  var issuerStatement: Data {
    canonical([("statement", subjectStatement.base64EncodedString()), ("subject_signature", subjectSignature.base64EncodedString())],
              domain: Self.protocolName + ".issuer")
  }
  static func issue(issuer: PeerSelf, subjectDeviceID: String, subjectLibraryID: String, subjectPublicKey: Data,
                    acknowledgedRevocations: [String], subjectSignature: Data) throws -> Self {
    let draft = PeerAdmission(issuerDeviceID: issuer.deviceID, issuerLibraryID: issuer.libraryID, subjectDeviceID: subjectDeviceID,
      subjectLibraryID: subjectLibraryID, subjectPublicKey: subjectPublicKey, acknowledgedRevocations: acknowledgedRevocations.sorted(),
      subjectSignature: subjectSignature, issuerSignature: Data())
    return .init(issuerDeviceID: draft.issuerDeviceID, issuerLibraryID: draft.issuerLibraryID, subjectDeviceID: draft.subjectDeviceID,
      subjectLibraryID: draft.subjectLibraryID, subjectPublicKey: draft.subjectPublicKey, acknowledgedRevocations: draft.acknowledgedRevocations,
      subjectSignature: draft.subjectSignature, issuerSignature: try issuer.key.signature(for: draft.issuerStatement))
  }
  /// Canonical identifiers, a sorted, unique, bounded revocation context and a
  /// well-formed key. Values are never normalized after signing.
  var isWellFormed: Bool {
    [issuerDeviceID, issuerLibraryID, subjectDeviceID, subjectLibraryID].allSatisfy { PeerIdentifier.canonical($0) != nil }
      && issuerDeviceID != subjectDeviceID && subjectPublicKey.count == 32
      && acknowledgedRevocations.count <= PeerIdentifier.maximumRevocationsPerDevice
      && acknowledgedRevocations.allSatisfy { PeerIdentifier.canonical($0) != nil }
      && acknowledgedRevocations == Array(Set(acknowledgedRevocations)).sorted()
  }
  func verifies(issuerKey: Data) -> Bool {
    guard isWellFormed, let subject = try? Curve25519.Signing.PublicKey(rawRepresentation: subjectPublicKey),
          let issuer = try? Curve25519.Signing.PublicKey(rawRepresentation: issuerKey) else { return false }
    return subject.isValidSignature(subjectSignature, for: subjectStatement)
      && issuer.isValidSignature(issuerSignature, for: issuerStatement)
  }
}

/// Shared membership: Mac introductions, mobile device names for display and
/// delegation attestation, and signed revocations. It authenticates nothing.
public struct PeerRosterEntry: Codable, Equatable, Sendable {
  public let deviceID: String
  public let name: String
  public let kind: CompanionDeviceKind
  public let introducedBy: String
  public let admission: PeerAdmission?
  public init(deviceID: String, name: String, kind: CompanionDeviceKind, introducedBy: String, admission: PeerAdmission?) {
    self.deviceID = deviceID; self.name = name; self.kind = kind; self.introducedBy = introducedBy; self.admission = admission
  }
}
public struct PeerMembership: Codable, Equatable, Sendable {
  public let entries: [PeerRosterEntry]
  public let revocations: [PeerRevocation]
  public init(entries: [PeerRosterEntry], revocations: [PeerRevocation]) { self.entries = entries; self.revocations = revocations }
}

extension PairedMacProof {
  /// Signed by the target Mac. Binds a fresh requester nonce, the requester and
  /// its target-local credential identity, and the exact returned route.
  public static func statement(_ challenge: PairedMacProofChallenge, route: PairedMacRoute) -> Data {
    canonical([("requester", challenge.deviceID.lowercased()), ("credential", challenge.credentialID),
               ("nonce", challenge.nonce.base64EncodedString()), ("target", challenge.targetDeviceID.lowercased()),
               ("target_library", challenge.targetLibraryID.lowercased()), ("route_device", route.deviceID.lowercased()),
               ("route_library", route.libraryID.lowercased()), ("route_endpoint", route.endpoint.absoluteString),
               ("route_name", route.name)], domain: "woven.peer.proof.v2")
  }
}

/// A one-use server challenge for the learned-peer handshake. The target signs
/// it so the requester knows it reached the pinned Mac before signing anything.
public struct PairedMacChallengeRequest: Codable, Equatable, Sendable {
  public let requesterDeviceID: String
  public let requesterLibraryID: String
  public let targetDeviceID: String
  public let targetLibraryID: String
  public init(requesterDeviceID: String, requesterLibraryID: String, targetDeviceID: String, targetLibraryID: String) {
    self.requesterDeviceID = requesterDeviceID; self.requesterLibraryID = requesterLibraryID
    self.targetDeviceID = targetDeviceID; self.targetLibraryID = targetLibraryID
  }
}
public struct PairedMacChallenge: Codable, Sendable {
  public let challengeID: String
  public let nonce: Data
  public let serviceID: String
  public let route: PairedMacRoute
  public let signature: Data
  static func statement(challengeID: String, nonce: Data, serviceID: String, request: PairedMacChallengeRequest, route: PairedMacRoute) -> Data {
    canonical([("challenge", challengeID), ("nonce", nonce.base64EncodedString()), ("service", serviceID),
               ("requester", request.requesterDeviceID), ("requester_library", request.requesterLibraryID),
               ("target", request.targetDeviceID), ("target_library", request.targetLibraryID),
               ("route_device", route.deviceID), ("route_library", route.libraryID),
               ("route_endpoint", route.endpoint.absoluteString), ("route_name", route.name)], domain: "woven.peer.challenge.v2")
  }
}
/// The requester's signature over the consumed challenge. The target issues a
/// fresh grant that authenticates only at the target itself.
public struct PairedMacHandshake: Codable, Sendable {
  public let challengeID: String
  public let request: PairedMacChallengeRequest
  public let operationID: String
  public let signature: Data
  public init(challengeID: String, request: PairedMacChallengeRequest, operationID: String, signature: Data) {
    self.challengeID = challengeID; self.request = request; self.operationID = operationID; self.signature = signature
  }
  public static func statement(challenge: PairedMacChallenge, request: PairedMacChallengeRequest, operationID: String) -> Data {
    canonical([("purpose", "peer.grant"), ("role", PeerAdmission.role), ("protocol", PeerAdmission.protocolName),
               ("challenge", challenge.challengeID), ("nonce", challenge.nonce.base64EncodedString()), ("service", challenge.serviceID),
               ("requester", request.requesterDeviceID), ("requester_library", request.requesterLibraryID),
               ("target", request.targetDeviceID), ("target_library", request.targetLibraryID),
               ("endpoint", challenge.route.endpoint.absoluteString), ("operation", operationID)], domain: "woven.peer.handshake.v2")
  }
}
public struct PairedMacGrant: Codable, Sendable {
  public let token: String
  public init(token: String) { self.token = token }
}

/// Length-prefixed, domain-separated encoding: unambiguous for any field value.
func canonical(_ fields: [(String, String)], domain: String = PeerAdmission.protocolName) -> Data {
  var data = Data()
  for part in [domain] + fields.flatMap({ [$0.0, $0.1] }) {
    let bytes = Data(part.utf8)
    withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
    data.append(bytes)
  }
  return data
}

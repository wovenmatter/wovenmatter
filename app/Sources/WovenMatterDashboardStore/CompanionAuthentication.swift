import CryptoKit
import Darwin
import Foundation
import Security
import WovenMatterCore

public struct CompanionPairedDevice: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let pairedAt: Date
  public var revokedAt: Date?
  public var metadata: CompanionDeviceMetadata?
  public var lastSeenAt: Date?
  public var kind: CompanionDeviceKind { metadata?.kind ?? .unknown }
  public var isDevelopment: Bool { localDevelopment == true || metadata?.developmentInstance != nil }
  public var displayName: String {
    if localDevelopment == true { return String(name.dropFirst("Dev · ".count)) + " (Dev)" }
    return isDevelopment && !name.contains("(Dev)") ? name + " (Dev)" : name
  }
  fileprivate let credentialHash: Data
  fileprivate var localDevelopment: Bool? = nil
  /// Fixed at issuance from the explicit pairing purpose, never from metadata.
  fileprivate var role: CompanionGrantRole? = nil
  /// Revocation events for this device known when this grant was issued. Any
  /// later event for the device revokes the grant; a fresh grant acknowledges it.
  fileprivate var acknowledged: [String]? = nil
  /// The immutable explicit-join transcript a peer grant was admitted with.
  fileprivate var transcript: Data? = nil
  fileprivate var origin: String? = nil
  public var isPeerGrant: Bool { role == .peer }
}

/// A grant's role is fixed when this Mac issues it.
public enum CompanionGrantRole: String, Codable, Sendable {
  /// A phone, tablet or other library client of this Mac only.
  case client
  /// An explicitly approved Mac pairing that has not completed its signed join.
  case peerCandidate
  /// A paired Mac admitted through a signed join or pinned handshake.
  case peer
}

/// App-owned credentials. Only random-token digests are written to disk; pairing
/// secrets are memory-only. A save must reach stable storage before acknowledgement.
public actor CompanionAuthentication {
  private struct Approval: Codable {
    var request: CompanionPendingPairingRequest
    var proof: Data
    var invitationProof: Data?
    var state: CompanionPairingApprovalState
    var encryptedCredential: Data?
    var workspaceID: String?
    var purpose: String?
  }
  private struct PendingQRPairing: Codable {
    var device: CompanionPairedDevice
    var workspaceID: String
    var expiresAt: Date
    var offerProof: Data
    var encryptedCredential: Data
    var purpose: String?
  }
  private struct State: Codable {
    var version = 1
    var devices: [CompanionPairedDevice] = []
    var approvals: [Approval]?
    var pendingQRPairings: [PendingQRPairing]?
    var revokedDevelopmentIDs: Set<String>?
    /// Immutable device-UUID pins for paired Macs' signing keys. Local only.
    var pins: [String: PeerPin]?
    var admissionVersion: Int?
    /// Replicated identity: Mac admissions and mobile names. Authenticates nothing.
    var roster: [String: RosterRecord]?
    /// Every known unpair event, signed by the Mac that made it.
    var revocations: [PeerRevocation]?
    /// Execution access this Mac issued for a device on another Mac's behalf.
    var delegations: [Delegation]?
  }
  struct RosterRecord: Codable, Equatable {
    var name: String
    var kind: CompanionDeviceKind
    var introducedBy: String
    var admissions: [PeerAdmission]
  }
  /// One delegated grant's provenance. A staged record exists only while its
  /// issuance is in flight; an issued record lasts until that grant is
  /// replaced by a successful issuance or revoked with its provisioning Mac.
  public struct Delegation: Codable, Equatable, Sendable {
    public let deviceID: String
    public let workspaceID: String
    public let provisionedBy: String
    public let acknowledged: [String]
    public var issued: Bool?
  }
  private struct Offer { let digest: Data; let expiresAt: Date; let deviceID: String? }
  private let fileURL: URL
  private var state: State
  private var offer: Offer?
  private var attempts: [Date] = []
  private var approvalKeys: [String: SymmetricKey] = [:]
  private var lastSeenSaved: [String: Date] = [:]
  private let now: @Sendable () -> Date

  public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) throws {
    self.fileURL = fileURL
    self.now = now
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let size = (try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
      guard size <= 16_777_216 else { throw Self.error("credential_store", "The paired-device store exceeds its safety limit.") }
      state = try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
      guard state.version == 1 else { throw Self.error("credential_store", "This paired-device store requires a newer Woven Matter.") }
    } else { state = State() }
    // Before paired-Mac identity existed every grant here was issued locally
    // through explicit approval; such Mac grants may complete one signed join.
    // An unreleased v2 store mixed replicated bearers into this ledger, so its
    // grants are revoked and those devices pair again.
    if state.admissionVersion != 3 {
      var upgraded = state
      let previous = upgraded.admissionVersion
      for index in upgraded.devices.indices {
        let device = upgraded.devices[index]
        if previous == 2, !device.isDevelopment, device.revokedAt == nil { upgraded.devices[index].revokedAt = now() }
        upgraded.devices[index].role = device.kind == .mac && !device.isDevelopment && previous == nil ? .peerCandidate : .client
      }
      if previous == 2 { upgraded.pins = nil }
      upgraded.admissionVersion = 3
      state = upgraded
    }
    lastSeenSaved = state.devices.reduce(into: [:]) { $0[$1.id] = $1.lastSeenAt }
  }

  /// Grants this Mac issued and still honors. Replicated membership is never here.
  public func devices() -> [CompanionPairedDevice] {
    var seen = Set<String>()
    return state.devices.filter { Self.isActive($0, in: state) && (!$0.isDevelopment || now().timeIntervalSince($0.lastSeenAt ?? .distantPast) < 45) && seen.insert($0.id).inserted }
  }

  /// Normal Dev quit withdraws presence without making the identity permanently
  /// revoked. Explicit Unpair continues to block automatic reenrollment.
  public func suspendLocalDevelopment(deviceID: String, credential: String) throws {
    guard let index = state.devices.firstIndex(where: { $0.id == deviceID && $0.isDevelopment && $0.revokedAt == nil && Self.constantTimeEqual($0.credentialHash, Self.digest(credential)) }) else { throw Self.unauthorized }
    var next = state; next.devices[index].lastSeenAt = nil
    try persist(next); state = next; lastSeenSaved.removeValue(forKey: deviceID)
  }

  // MARK: Paired-Mac identity, membership and target-local peer grants

  /// This Mac's signing identity, set before peer use. Local unpairs are
  /// signed with it so other Macs can verify them.
  private var identity: PeerSelf?
  public func useIdentity(_ own: PeerSelf) { identity = own }
  public func pin(for deviceID: String) -> PeerPin? { state.pins?[deviceID] }

  private static func events(_ id: String, in state: State) -> Set<String> {
    Set((state.revocations ?? []).filter { $0.deviceID == id }.map(\.eventID))
  }
  /// The unpair events this Mac knows for a device, as a sorted context.
  public func revocationContext(for deviceID: String) -> [String] { Self.events(deviceID, in: state).sorted() }
  private static func isActive(_ grant: CompanionPairedDevice, in state: State) -> Bool {
    grant.revokedAt == nil && events(grant.id, in: state).isSubset(of: Set(grant.acknowledged ?? []))
  }
  /// A Mac identity is active while one of its accepted admissions matches its
  /// pin and acknowledges every unpair event known for it. An admission stays
  /// accepted when its introducer is later offline or unpaired.
  private static func isActiveMac(_ id: String, in state: State, own: String?) -> Bool {
    if id == own { return true }
    guard let pin = state.pins?[id], let record = state.roster?[id] else { return false }
    let known = events(id, in: state)
    return record.admissions.contains {
      $0.subjectPublicKey == pin.publicKey && $0.subjectLibraryID == pin.libraryID && known.isSubset(of: Set($0.acknowledgedRevocations))
    }
  }
  public func isActiveMac(_ id: String) -> Bool { Self.isActiveMac(id, in: state, own: identity?.deviceID) }

  /// A paired-Mac endpoint accepts only a peer grant this Mac issued, for an
  /// identity it still admits. Device metadata and roster entries never count.
  public func isAuthorizedPeer(_ principal: CompanionPairedDevice) -> Bool {
    guard let grant = state.devices.first(where: { $0.id == principal.id && Self.constantTimeEqual($0.credentialHash, principal.credentialHash) }),
          Self.isActive(grant, in: state), grant.role == .peer, !grant.isDevelopment, grant.id != identity?.deviceID else { return false }
    return Self.isActiveMac(grant.id, in: state, own: nil)
  }

  /// Shared membership: accepted Mac admissions with their original signatures,
  /// names of mobile devices for display and delegation, and signed unpairs.
  public func peerMembership() -> PeerMembership {
    var entries: [PeerRosterEntry] = []
    for (id, record) in (state.roster ?? [:]).sorted(by: { $0.key < $1.key }) {
      if record.admissions.isEmpty {
        entries.append(.init(deviceID: id, name: record.name, kind: record.kind, introducedBy: record.introducedBy, admission: nil))
      } else {
        for admission in record.admissions {
          entries.append(.init(deviceID: id, name: record.name, kind: .mac, introducedBy: admission.issuerDeviceID, admission: admission))
        }
      }
    }
    if let own = identity?.deviceID {
      for grant in devices() where grant.role == .client && !grant.isDevelopment && state.roster?[grant.id] == nil
        && PeerIdentifier.canonical(grant.id) != nil {
        entries.append(.init(deviceID: grant.id, name: grant.name, kind: grant.kind, introducedBy: own, admission: nil))
      }
    }
    return .init(entries: entries, revocations: (state.revocations ?? []).filter(\.isWellFormed))
  }

  private enum AdmissionCheck { case valid(PeerPin), waiting, invalid }
  private static func validate(_ admission: PeerAdmission, in state: State, own: PeerSelf) -> AdmissionCheck {
    guard admission.isWellFormed else { return .invalid }
    let subject = admission.subjectDeviceID, issuer = admission.issuerDeviceID
    let pin = PeerPin(libraryID: admission.subjectLibraryID, publicKey: admission.subjectPublicKey)
    if subject == own.deviceID {
      guard pin == own.pin else { return .invalid }
    } else if let pinned = state.pins?[subject], pinned != pin { return .invalid }
    // An introduction that does not acknowledge a known unpair is stale forever.
    guard events(subject, in: state).isSubset(of: Set(admission.acknowledgedRevocations)) else { return .invalid }
    if state.roster?[subject]?.admissions.contains(admission) == true { return .invalid }
    let issuerKey: Data
    if issuer == own.deviceID {
      guard admission.issuerLibraryID == own.libraryID else { return .invalid }
      issuerKey = own.publicKey
    } else {
      guard let pinned = state.pins?[issuer], pinned.libraryID == admission.issuerLibraryID,
            isActiveMac(issuer, in: state, own: own.deviceID) else { return .waiting }
      issuerKey = pinned.publicKey
    }
    return admission.verifies(issuerKey: issuerKey) ? .valid(pin) : .invalid
  }

  /// Merges another Mac's membership. Every verifiable unpair applies before
  /// any new introduction is judged, and again after each newly pinned Mac, so
  /// an introduction from a Mac unpaired in the same exchange is rejected in
  /// every order. Pins are never replaced and no bearer is ever learned here.
  public func mergeMembership(_ membership: PeerMembership, own: PeerSelf) throws {
    identity = own
    guard membership.entries.count <= 4096, membership.revocations.count <= 4096 else { throw Self.unauthorized }
    var next = state
    var revocations = next.revocations ?? []
    var known = Set(revocations.map(\.eventID))
    // One trust hop per exchange. The Macs this Mac admits at entry are the only
    // signers it trusts in this exchange. Every new unpair they signed is
    // accepted together, as concurrent events, before any introduction is
    // judged; unpairs accepted earlier always remain. An unpair signed by a Mac
    // already unpaired at entry is rejected: its random event ID cannot prove it
    // was made before that Mac's removal. A Mac pinned in this exchange can
    // neither unpair nor introduce until the next exchange, when repeated full
    // membership carries its events and introductions again.
    let trusted = { (id: String) in Self.isActiveMac(id, in: self.state, own: own.deviceID) }
    let fresh = membership.revocations.filter { $0.isWellFormed && !known.contains($0.eventID) }
    for event in fresh.sorted(by: { $0.eventID < $1.eventID }) where !known.contains(event.eventID) {
      let revoker = event.revokerDeviceID
      guard trusted(revoker), let key = revoker == own.deviceID ? own.publicKey : state.pins?[revoker]?.publicKey,
            event.verifies(key), revocations.filter({ $0.deviceID == event.deviceID }).count < PeerIdentifier.maximumRevocationsPerDevice else { continue }
      revocations.append(event); known.insert(event.eventID)
    }
    next.revocations = revocations
    // Introductions only from a Mac trusted at entry and still admitted once
    // every unpair above has applied.
    for entry in membership.entries {
      guard let admission = entry.admission, entry.deviceID == admission.subjectDeviceID,
            admission.issuerDeviceID == own.deviceID || trusted(admission.issuerDeviceID),
            case .valid(let pin) = Self.validate(admission, in: next, own: own) else { continue }
      var roster = next.roster ?? [:]
      let name = String(entry.name.prefix(120))
      var record = roster[admission.subjectDeviceID] ?? .init(name: name.isEmpty ? "Mac" : name, kind: .mac, introducedBy: admission.issuerDeviceID, admissions: [])
      record.kind = .mac; record.admissions.append(admission)
      roster[admission.subjectDeviceID] = record; next.roster = roster
      if admission.subjectDeviceID != own.deviceID { next.pins = (next.pins ?? [:]).merging([admission.subjectDeviceID: pin]) { current, _ in current } }
    }
    // Mobile names are display and delegation attestation only; they can
    // never describe a pinned Mac, this Mac, or a non-canonical identity.
    for entry in membership.entries where entry.admission == nil && entry.kind != .mac {
      guard let id = PeerIdentifier.canonical(entry.deviceID), id != own.deviceID, next.pins?[id] == nil,
            let introducer = PeerIdentifier.canonical(entry.introducedBy), !entry.name.isEmpty else { continue }
      var roster = next.roster ?? [:]
      if roster[id] == nil { roster[id] = .init(name: String(entry.name.prefix(120)), kind: entry.kind, introducedBy: introducer, admissions: []) }
      next.roster = roster
    }
    Self.sweepRevokedGrants(&next, at: now())
    guard next.devices.count <= 4096, (next.roster ?? [:]).count <= 4096 else { throw Self.unauthorized }
    guard next.devices != state.devices || next.pins != state.pins || next.roster != state.roster || next.revocations != state.revocations else { return }
    try persist(next); state = next
  }

  /// Records an unpair event's effect on this Mac's own grants durably.
  private static func sweepRevokedGrants(_ next: inout State, at instant: Date) {
    for index in next.devices.indices where next.devices[index].revokedAt == nil && !isActive(next.devices[index], in: next) {
      next.devices[index].revokedAt = instant
    }
  }

  /// The revocation context the explicitly approved requester must sign.
  public func joinContext(for principal: CompanionPairedDevice) throws -> [String] {
    guard let grant = activeGrant(principal), grant.role == .peerCandidate || (grant.role == .peer && grant.transcript != nil) else { throw Self.unauthorized }
    return Self.events(grant.id, in: state).sorted()
  }
  private func activeGrant(_ principal: CompanionPairedDevice) -> CompanionPairedDevice? {
    state.devices.first { $0.id == principal.id && Self.constantTimeEqual($0.credentialHash, principal.credentialHash) && Self.isActive($0, in: state) && !$0.isDevelopment }
  }

  /// Completes an explicitly approved Mac pairing this Mac issued. The full
  /// transcript is bound to the grant: an exact retry is accepted, anything
  /// else is rejected. An active admission learned elsewhere is not a join.
  public func admitJoin(_ principal: CompanionPairedDevice, join: PairedMacJoin, own: PeerSelf) throws {
    identity = own
    guard let grant = activeGrant(principal), let index = state.devices.firstIndex(where: { $0.id == grant.id && $0.credentialHash == grant.credentialHash }),
          PeerIdentifier.canonical(join.route.deviceID) == grant.id, let library = PeerIdentifier.canonical(join.route.libraryID),
          join.publicKey.count == 32, (32...256).contains(join.returnCredential.utf8.count),
          Self.wellFormedContext(join.acknowledgedRevocations), Self.wellFormedContext(join.reciprocalRevocations),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: join.publicKey) else { throw Self.unauthorized }
    let transcript = Data(SHA256.hash(data: canonical([
      ("issuer", own.deviceID), ("issuer_library", own.libraryID), ("subject", grant.id), ("subject_library", library),
      ("subject_key", join.publicKey.base64EncodedString()), ("revocations", join.acknowledgedRevocations.joined(separator: ",")),
      ("grant", grant.credentialHash.base64EncodedString()), ("reciprocal", Self.digest(join.returnCredential).base64EncodedString()),
      ("reciprocal_revocations", join.reciprocalRevocations.joined(separator: ",")), ("route", join.route.endpoint.absoluteString)
    ], domain: "woven.peer.join.v2")))
    if let existing = grant.transcript {
      guard Self.constantTimeEqual(existing, transcript) else { throw Self.error("join_conflict", "This pairing already completed with different details. Pair again.") }
      return
    }
    guard grant.role == .peerCandidate else { throw Self.unauthorized }
    guard Set(join.acknowledgedRevocations) == Self.events(grant.id, in: state) else {
      throw Self.error("revocation_context", "Pairing details changed. Retry pairing.")
    }
    let statement = PeerAdmission.subjectStatement(issuerDeviceID: own.deviceID, issuerLibraryID: own.libraryID, subjectDeviceID: grant.id,
      subjectLibraryID: library, subjectPublicKey: join.publicKey, acknowledgedRevocations: join.acknowledgedRevocations)
    guard key.isValidSignature(join.subjectSignature, for: statement) else { throw Self.unauthorized }
    var next = state
    try Self.pinExplicitly(grant.id, .init(libraryID: library, publicKey: join.publicKey), in: &next, own: own.deviceID)
    let admission = try PeerAdmission.issue(issuer: own, subjectDeviceID: grant.id, subjectLibraryID: library, subjectPublicKey: join.publicKey,
      acknowledgedRevocations: join.acknowledgedRevocations, subjectSignature: join.subjectSignature)
    Self.record(admission, name: join.route.name, in: &next)
    next.devices[index].role = .peer; next.devices[index].transcript = transcript; next.devices[index].origin = "join"
    try persist(next); state = next
  }

  /// The requester's side of an explicit pairing: verifies the responder's key
  /// proof for the reciprocal grant this Mac issued, pins it, and records that
  /// grant locally. The bearer authenticates only at this Mac.
  public func enrollPeer(route: PairedMacRoute, token: String, publicKey: Data, subjectSignature: Data,
                         acknowledgedRevocations: [String], own: PeerSelf) throws {
    identity = own
    guard let id = PeerIdentifier.canonical(route.deviceID), let library = PeerIdentifier.canonical(route.libraryID), id != own.deviceID,
          !route.name.isEmpty, route.name.utf8.count <= 256, (32...256).contains(token.utf8.count),
          Self.wellFormedContext(acknowledgedRevocations), Set(acknowledgedRevocations) == Self.events(id, in: state),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { throw Self.unauthorized }
    let hash = Self.digest(token)
    if let existing = state.devices.first(where: { $0.id == id && $0.credentialHash == hash }) {
      guard Self.isActive(existing, in: state), existing.role == .peer, state.pins?[id]?.publicKey == publicKey else { throw Self.unauthorized }
      return
    }
    let statement = PeerAdmission.subjectStatement(issuerDeviceID: own.deviceID, issuerLibraryID: own.libraryID, subjectDeviceID: id,
      subjectLibraryID: library, subjectPublicKey: publicKey, acknowledgedRevocations: acknowledgedRevocations)
    guard key.isValidSignature(subjectSignature, for: statement) else { throw Self.unauthorized }
    var next = state
    try Self.pinExplicitly(id, .init(libraryID: library, publicKey: publicKey), in: &next, own: own.deviceID)
    Self.record(try PeerAdmission.issue(issuer: own, subjectDeviceID: id, subjectLibraryID: library, subjectPublicKey: publicKey,
      acknowledgedRevocations: acknowledgedRevocations, subjectSignature: subjectSignature), name: route.name, in: &next)
    var device = CompanionPairedDevice(id: id, name: route.name, pairedAt: now(), metadata: .init(kind: .mac), credentialHash: hash)
    device.role = .peer; device.acknowledged = acknowledgedRevocations; device.origin = "join"
    next.devices.append(device)
    try persist(next); state = next
  }

  private static func wellFormedContext(_ context: [String]) -> Bool {
    context.count <= PeerIdentifier.maximumRevocationsPerDevice && context.allSatisfy { PeerIdentifier.canonical($0) != nil }
      && context == Array(Set(context)).sorted()
  }
  private static func record(_ admission: PeerAdmission, name: String, in next: inout State) {
    var roster = next.roster ?? [:]
    var record = roster[admission.subjectDeviceID] ?? .init(name: String(name.prefix(120)), kind: .mac, introducedBy: admission.issuerDeviceID, admissions: [])
    record.kind = .mac
    if !record.admissions.contains(admission) { record.admissions.append(admission) }
    roster[admission.subjectDeviceID] = record; next.roster = roster
  }

  /// Pins are immutable. Only an explicit fresh pairing, after the device is
  /// no longer an active Mac identity here, may bind a different key or library.
  private static func pinExplicitly(_ deviceID: String, _ pin: PeerPin, in next: inout State, own: String) throws {
    if let existing = next.pins?[deviceID], existing != pin, isActiveMac(deviceID, in: next, own: own) {
      throw error("identity_conflict", "This Mac presented a different identity key. Unpair it everywhere, then pair it again.")
    }
    next.pins = (next.pins ?? [:]).merging([deviceID: pin]) { _, new in new }
  }

  /// A new local grant has a fixed role and acknowledges every unpair this Mac
  /// knows for the device, so only a pairing made after them stays valid.
  private static func issued(_ device: CompanionPairedDevice, in state: State, purpose: String?) -> CompanionPairedDevice {
    var device = device
    device.role = purpose == CompanionPairingPurpose.peerMac && !device.isDevelopment ? .peerCandidate : .client
    device.acknowledged = events(device.id, in: state).sorted()
    device.origin = "pairing"
    return device
  }

  // MARK: Learned-peer handshake

  private struct IssuedChallenge { let request: PairedMacChallengeRequest; let challenge: PairedMacChallenge; let expires: Date }
  /// Issued challenges live only in this process: a restart invalidates them.
  private var challenges: [String: IssuedChallenge] = [:]
  private let serviceID = UUID().uuidString.lowercased()

  /// A Mac this Mac already admits (for example one introduced while another
  /// Mac is offline) asks for its own grant here. This Mac signs a one-use
  /// challenge with its key; nothing is issued until the requester signs it.
  public func issueChallenge(_ request: PairedMacChallengeRequest, route: PairedMacRoute, own: PeerSelf) throws -> PairedMacChallenge {
    identity = own
    guard let requester = PeerIdentifier.canonical(request.requesterDeviceID), PeerIdentifier.canonical(request.requesterLibraryID) != nil,
          request.targetDeviceID == own.deviceID, request.targetLibraryID == own.libraryID, requester != own.deviceID,
          route.deviceID == own.deviceID, state.pins?[requester]?.libraryID == request.requesterLibraryID,
          Self.isActiveMac(requester, in: state, own: own.deviceID) else { throw Self.unauthorized }
    let instant = now()
    challenges = challenges.filter { $0.value.expires > instant }
    guard challenges.count < 128 else { throw Self.error("rate_limited", "Too many paired Mac handshakes. Try again shortly.") }
    let id = UUID().uuidString.lowercased(), nonce = PairedMacNetwork.nonce()
    let signature = try own.key.signature(for: PairedMacChallenge.statement(challengeID: id, nonce: nonce, serviceID: serviceID, request: request, route: route))
    let challenge = PairedMacChallenge(challengeID: id, nonce: nonce, serviceID: serviceID, route: route, signature: signature)
    challenges[id] = .init(request: request, challenge: challenge, expires: instant.addingTimeInterval(60))
    return challenge
  }

  /// Consumes the challenge before any check or side effect, verifies the
  /// requester's pinned key, and issues a grant valid only at this Mac. A
  /// retry after a lost reply needs a new challenge and supersedes the grant.
  public func completeHandshake(_ handshake: PairedMacHandshake, own: PeerSelf) throws -> PairedMacGrant {
    guard let issued = challenges.removeValue(forKey: handshake.challengeID) else { throw Self.unauthorized }
    let requester = handshake.request.requesterDeviceID
    guard issued.expires > now(), issued.request == handshake.request, PeerIdentifier.canonical(handshake.operationID) != nil,
          Self.isActiveMac(requester, in: state, own: own.deviceID), let pin = state.pins?[requester],
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pin.publicKey),
          key.isValidSignature(handshake.signature, for: PairedMacHandshake.statement(challenge: issued.challenge, request: handshake.request,
            operationID: handshake.operationID)) else { throw Self.unauthorized }
    let token = try Self.randomToken()
    var next = state
    next.devices.removeAll { $0.id == requester && $0.origin == "handshake" }
    var device = CompanionPairedDevice(id: requester, name: state.roster?[requester]?.name ?? "Mac", pairedAt: now(), metadata: .init(kind: .mac),
      credentialHash: Self.digest(token))
    device.role = .peer; device.acknowledged = Self.events(requester, in: state).sorted(); device.origin = "handshake"
    next.devices.append(device)
    try persist(next); state = next
    return .init(token: token)
  }

  /// Signs a fresh challenge for a requester holding a peer grant this Mac
  /// issued, binding the expected target identity and route.
  public func peerProof(_ challenge: PairedMacProofChallenge, route: PairedMacRoute, own: PeerSelf) throws -> PairedMacProof {
    guard challenge.nonce.count == 32, challenge.targetDeviceID == own.deviceID, challenge.targetLibraryID == own.libraryID,
          route.deviceID == own.deviceID,
          let grant = state.devices.first(where: {
            $0.id == challenge.deviceID && $0.role == .peer && Self.isActive($0, in: state)
              && SHA256.hash(data: $0.credentialHash).map { String(format: "%02x", $0) }.joined() == challenge.credentialID
          }), isAuthorizedPeer(grant) else { throw Self.unauthorized }
    return .init(route: route, signature: try own.key.signature(for: PairedMacProof.statement(challenge, route: route)))
  }

  // MARK: Delegated execution provenance

  /// Stages a paired Mac's request for this Mac's execution access for one of
  /// its mobile devices. Earlier provenance for that device and workspace is
  /// kept until the new grant is actually issued.
  public func stageDelegation(deviceID: String, workspaceID: String, provisionedBy: String) throws {
    guard PeerIdentifier.canonical(deviceID) != nil, state.pins?[deviceID] == nil, deviceID != identity?.deviceID else { throw Self.unauthorized }
    var next = state
    var delegations = (next.delegations ?? []).filter { !($0.deviceID == deviceID && $0.workspaceID == workspaceID && $0.provisionedBy == provisionedBy && $0.issued != true) }
    delegations.append(.init(deviceID: deviceID, workspaceID: workspaceID, provisionedBy: provisionedBy,
      acknowledged: Self.events(deviceID, in: state).sorted(), issued: false))
    next.delegations = delegations
    try persist(next); state = next
  }
  /// The staged grant was issued, which replaced the device's earlier grant for
  /// this workspace: only now is earlier provenance retired.
  public func confirmDelegation(deviceID: String, workspaceID: String, provisionedBy: String) throws {
    var next = state
    var delegations = (next.delegations ?? []).filter { !($0.deviceID == deviceID && $0.workspaceID == workspaceID && $0.issued == true) }
    for index in delegations.indices where delegations[index].deviceID == deviceID && delegations[index].workspaceID == workspaceID
      && delegations[index].provisionedBy == provisionedBy { delegations[index].issued = true }
    next.delegations = delegations
    try persist(next); state = next
  }
  /// This Mac issued the device its own grant for the workspace, which replaced
  /// any delegated one: that delegated provenance is retired so a later unpair
  /// of its provisioning Mac never queues cleanup against the new grant.
  public func retireDelegations(deviceID: String, workspaceID: String) throws {
    var next = state
    next.delegations = (next.delegations ?? []).filter { !($0.deviceID == deviceID && $0.workspaceID == workspaceID) }
    guard next.delegations != state.delegations else { return }
    try persist(next); state = next
  }
  /// A failed issuance leaves every earlier grant and its provenance in place.
  public func cancelStagedDelegation(deviceID: String, workspaceID: String, provisionedBy: String) throws {
    var next = state
    next.delegations = (next.delegations ?? []).filter { !($0.deviceID == deviceID && $0.workspaceID == workspaceID && $0.provisionedBy == provisionedBy && $0.issued != true) }
    guard next.delegations != state.delegations else { return }
    try persist(next); state = next
  }
  /// Live authorization for one delegated grant: its provisioning Mac is still
  /// admitted and holds a peer grant here, and the device has no unpair the
  /// delegation did not acknowledge.
  public func delegationActive(deviceID: String, provisionedBy: String) -> Bool {
    (state.delegations ?? []).contains { delegation in
      delegation.deviceID == deviceID && delegation.provisionedBy == provisionedBy
        && Self.events(deviceID, in: state).isSubset(of: Set(delegation.acknowledged))
        && Self.isActiveMac(provisionedBy, in: state, own: nil)
        && state.devices.contains { $0.id == provisionedBy && $0.role == .peer && Self.isActive($0, in: state) }
    }
  }
  /// Live authorization for an execution or inference grant. A grant this Mac
  /// issued directly needs the device's own active grant here; a delegated grant
  /// needs its own provisioning Mac, regardless of other grants for the device.
  public func authorizesExecution(deviceID: String, provisionedBy: String?) -> Bool {
    if let provisionedBy { return delegationActive(deviceID: deviceID, provisionedBy: provisionedBy) }
    return devices().contains { $0.id == deviceID }
  }
  public func delegations(provisionedBy deviceID: String) -> [Delegation] { (state.delegations ?? []).filter { $0.provisionedBy == deviceID } }
  public func removeDelegations(provisionedBy deviceID: String) throws {
    var next = state
    next.delegations = (next.delegations ?? []).filter { $0.provisionedBy != deviceID }
    guard next.delegations != state.delegations else { return }
    try persist(next); state = next
  }
  /// Whether this Mac's execution or inference may serve a device: a grant it
  /// issued, or a live delegation from a Mac that still holds a peer grant here.
  public func mayExecute(deviceID: String) -> Bool {
    if devices().contains(where: { $0.id == deviceID }) { return true }
    return (state.delegations ?? []).contains { delegationActive(deviceID: deviceID, provisionedBy: $0.provisionedBy) && $0.deviceID == deviceID }
  }
  /// A mobile device another Mac may delegate for: never a pinned Mac or this Mac.
  public func rosterName(for deviceID: String) -> String? { state.roster?[deviceID]?.name }
  public func mayDelegate(for deviceID: String) -> Bool {
    PeerIdentifier.canonical(deviceID) != nil && state.pins?[deviceID] == nil && deviceID != identity?.deviceID
  }
  /// Unpaired devices whose effects this Mac must still apply locally.
  public func revokedDeviceContexts() -> [String: [String]] {
    Dictionary(grouping: (state.revocations ?? []), by: \.deviceID).mapValues { $0.map(\.eventID).sorted() }
      .filter { id, _ in !Self.isActiveMac(id, in: state, own: identity?.deviceID) && !devices().contains { $0.id == id } }
  }

  /// Called only by the same-user Unix socket, never by an HTTP route. A local
  /// development instance receives its own revocable identity, not the host's.
  public func enrollLocalDevelopment(deviceID: String, name: String, workspaceID: String) throws -> CompanionPairResponse {
    guard UUID(uuidString: deviceID) != nil, name.hasPrefix("Dev · "), name.utf8.count <= 120,
          !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
      throw Self.error("invalid_device", "Invalid development instance identity.")
    }
    guard !(state.revokedDevelopmentIDs ?? []).contains(deviceID.lowercased()) else {
      throw Self.error("revoked_device", "This development identity was revoked. Use a new development instance.")
    }
    if let existing = state.devices.first(where: { $0.id.lowercased() == deviceID.lowercased() }) {
      guard existing.id == deviceID, existing.name == name, existing.localDevelopment == true,
            existing.revokedAt == nil else {
        throw Self.error("invalid_device", "This device identity is already in use or was revoked.")
      }
    }
    let token = try Self.randomToken()
    var next = state
    next.devices.removeAll { $0.id == deviceID }
    next.devices.append(.init(id: deviceID, name: name, pairedAt: now(), revokedAt: nil,
      metadata: .init(kind: .mac), lastSeenAt: now(), credentialHash: Self.digest(token), localDevelopment: true))
    try persist(next); state = next
    return .init(workspaceID: workspaceID, deviceID: deviceID, credential: token)
  }
  public func deviceConnections() -> [CompanionDeviceConnection] {
    devices().map { .init(id: $0.id, name: $0.displayName, metadata: $0.metadata ?? .init(), pairedAt: $0.pairedAt, lastSeenAt: $0.lastSeenAt) }
  }
  public func isCurrent(_ device: CompanionPairedDevice) -> Bool {
    state.devices.contains { $0.id == device.id && Self.isActive($0, in: state) && Self.constantTimeEqual($0.credentialHash, device.credentialHash) }
  }
  /// Close pending approval atomically, or return the exact approved principal
  /// whose direct-workspace grants the host must durably revoke before closing.
  public func preparePairingCancellation(_ request: CompanionPairingPoll) throws -> CompanionPairedDevice? {
    guard (32...256).contains(request.requestSecret.utf8.count),
          let entry = (state.approvals ?? []).first(where: { $0.request.id == request.requestID }),
          entry.request.expiresAt > now(), Self.constantTimeEqual(entry.proof, Self.proof(request.requestSecret)) else {
      throw Self.error("invalid_pairing", "The pairing request is invalid or expired.")
    }
    if entry.state == .approved, let encrypted = entry.encryptedCredential,
       let credential = String(data: try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: Self.key(request.requestSecret)), encoding: .utf8),
       let device = state.devices.first(where: {
         $0.id == entry.request.identity.deviceID && $0.revokedAt == nil && Self.constantTimeEqual($0.credentialHash, Self.digest(credential))
       }) { return device }
    try cancelPairing(request, revokeApproved: false)
    return nil
  }

  public func cancelPairing(_ request: CompanionPairingPoll, revokeApproved: Bool = true) throws {
    guard (32...256).contains(request.requestSecret.utf8.count),
          let entry = (state.approvals ?? []).first(where: { $0.request.id == request.requestID }),
          entry.request.expiresAt > now(), Self.constantTimeEqual(entry.proof, Self.proof(request.requestSecret)) else {
      throw Self.error("invalid_pairing", "The pairing request is invalid or expired.")
    }
    var next = state
    if revokeApproved, entry.state == .approved, let encrypted = entry.encryptedCredential,
       let credential = String(data: try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: Self.key(request.requestSecret)), encoding: .utf8),
       let index = next.devices.firstIndex(where: {
         $0.id == entry.request.identity.deviceID && Self.constantTimeEqual($0.credentialHash, Self.digest(credential))
       }) { next.devices[index].revokedAt = now() }
    if !revokeApproved, entry.state == .approved, let encrypted = entry.encryptedCredential,
       let credential = String(data: try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: Self.key(request.requestSecret)), encoding: .utf8),
       state.devices.contains(where: { $0.revokedAt == nil && $0.id == entry.request.identity.deviceID && Self.constantTimeEqual($0.credentialHash, Self.digest(credential)) }) {
      throw Self.error("revocation_pending", "Finish revoking this device's workspace access before cancelling pairing.")
    }
    if let index = next.approvals?.firstIndex(where: { $0.request.id == request.requestID }) {
      next.approvals?[index].state = .denied; next.approvals?[index].encryptedCredential = nil
    }
    try persist(next); state = next; approvalKeys.removeValue(forKey: request.requestID)
  }

  public func createOffer(endpoint: URL, deviceID: String? = nil) throws -> (payload: CompanionPairingPayload, expiresAt: Date) {
    let secret = try Self.randomToken()
    let expiresAt = now().addingTimeInterval(300)
    offer = Offer(digest: Self.digest(secret), expiresAt: expiresAt, deviceID: deviceID)
    return (try CompanionPairingPayload(endpoint: endpoint, token: secret), expiresAt)
  }

  public func cancelOffer() { offer = nil }

  /// Verify the code and target without enrolling a device or consuming the code.
  public func previewPairing(_ request: CompanionPairRequest, workspaceID: String) throws -> CompanionPairingPreview {
    guard request.protocolVersion == CompanionProtocol.version else { throw Self.error("version_mismatch", "Update Woven Matter on both devices before pairing.") }
    guard request.expectedWorkspaceID == nil || request.expectedWorkspaceID == workspaceID else {
      throw Self.error("workspace_mismatch", "The paired library changed. Generate a new pairing code.")
    }
    let proof = Self.digest(request.token)
    let available = offer.map { $0.expiresAt > now() && Self.constantTimeEqual($0.digest, proof) && ($0.deviceID == nil || $0.deviceID == request.deviceID) } == true
    let retry = request.requiresConfirmation == true && (state.pendingQRPairings ?? []).contains {
      $0.expiresAt > now() && $0.workspaceID == workspaceID && $0.device.id == request.deviceID &&
        $0.device.name == request.deviceName && $0.device.metadata == request.metadata && Self.constantTimeEqual($0.offerProof, proof)
    }
    guard available || retry else { throw Self.error("invalid_pairing", "The pairing code is invalid or expired. Generate another code on the Mac.") }
    return .init(workspaceID: workspaceID)
  }

  /// Pending credentials cannot read data or appear in the paired-device list.
  /// Confirmation is idempotent when its response is lost after the commit.
  public func confirmPairing(bearer: String, workspaceID: String) throws {
    let hash = Self.digest(bearer)
    if state.devices.contains(where: { $0.revokedAt == nil && Self.constantTimeEqual($0.credentialHash, hash) }) { return }
    guard let entry = state.pendingQRPairings?.first(where: { $0.expiresAt > now() && $0.workspaceID == workspaceID && Self.constantTimeEqual($0.device.credentialHash, hash) }),
      !state.devices.contains(where: { $0.revokedAt == nil && $0.id.lowercased() == entry.device.id.lowercased() }) else { throw Self.unauthorized }
    var next = state
    next.devices.append(Self.issued(entry.device, in: next, purpose: entry.purpose))
    next.pendingQRPairings?.removeAll { $0.device.id == entry.device.id || $0.expiresAt <= now() }
    try persist(next); state = next
  }

  public func pair(_ request: CompanionPairRequest, workspaceID: String) throws -> CompanionPairResponse {
    guard request.protocolVersion == CompanionPairingPayload.currentProtocolVersion else {
      throw Self.error("version_mismatch", "Update Woven Matter on both devices before pairing.")
    }
    _ = try previewPairing(request, workspaceID: workspaceID)
    let instant = now()
    attempts.removeAll { instant.timeIntervalSince($0) >= 60 }
    guard attempts.count < 10 else { throw Self.error("rate_limited", "Too many pairing attempts. Wait a minute and try again.") }
    attempts.append(instant)
    if request.requiresConfirmation == true, let pending = state.pendingQRPairings?.first(where: {
      $0.expiresAt > instant && $0.workspaceID == workspaceID && $0.device.id == request.deviceID &&
        $0.device.name == request.deviceName && $0.device.metadata == request.metadata && Self.constantTimeEqual($0.offerProof, Self.digest(request.token))
    }) {
      let data = try AES.GCM.open(AES.GCM.SealedBox(combined: pending.encryptedCredential), using: Self.key(request.token))
      guard let credential = String(data: data, encoding: .utf8) else { throw Self.unauthorized }
      return .init(workspaceID: workspaceID, deviceID: request.deviceID, credential: credential, confirmationRequired: true)
    }
    guard UUID(uuidString: request.deviceID) != nil,
          !request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          request.deviceName.utf8.count <= 120,
          !request.deviceName.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }),
          !state.devices.contains(where: { $0.revokedAt == nil && $0.id.lowercased() == request.deviceID.lowercased() }) else {
      throw Self.error("invalid_device", "This device cannot be paired. Check the Mac's paired-device settings.")
    }
    try Self.validateMetadata(request.metadata)
    let credential = try Self.randomToken()
    let device = CompanionPairedDevice(id: request.deviceID,
      name: request.deviceName, pairedAt: instant, revokedAt: nil,
      metadata: request.metadata, lastSeenAt: instant, credentialHash: Self.digest(credential))
    var next = state
    if request.requiresConfirmation == true {
      let encrypted = try AES.GCM.seal(Data(credential.utf8), using: Self.key(request.token)).combined!
      next.pendingQRPairings = (next.pendingQRPairings ?? []).filter { $0.expiresAt > instant && $0.device.id != request.deviceID }
      next.pendingQRPairings?.append(.init(device: device, workspaceID: workspaceID,
        expiresAt: instant.addingTimeInterval(300), offerProof: Self.digest(request.token), encryptedCredential: encrypted, purpose: request.purpose))
    } else {
      // Legacy clients retain their v3 pairing contract.
      next.devices.append(Self.issued(device, in: next, purpose: request.purpose))
    }
    try persist(next)
    state = next
    self.offer = nil
    return CompanionPairResponse(workspaceID: workspaceID, deviceID: request.deviceID, credential: credential, confirmationRequired: request.requiresConfirmation == true ? true : nil)
  }

  public func authenticate(bearer: String, metadata: CompanionDeviceMetadata? = nil) throws -> CompanionPairedDevice {
    guard (32...256).contains(bearer.utf8.count) else { throw Self.unauthorized }
    let digest = Self.digest(bearer)
    // Only a grant this Mac issued, still acknowledging every unpair event
    // known for its device, authenticates. Replicated membership never does.
    guard let index = state.devices.firstIndex(where: {
      Self.isActive($0, in: state) && Self.constantTimeEqual($0.credentialHash, digest)
    }) else { throw Self.unauthorized }
    try Self.validateMetadata(metadata)
    var next = state
    let instant = now()
    let changedMetadata = metadata != nil && next.devices[index].metadata != metadata
    if let metadata { next.devices[index].metadata = metadata }
    next.devices[index].lastSeenAt = instant
    let id = next.devices[index].id
    if changedMetadata || instant.timeIntervalSince(lastSeenSaved[id] ?? .distantPast) >= (next.devices[index].isDevelopment ? 10 : 60) {
      try persist(next); lastSeenSaved[id] = instant
    }
    state = next
    return next.devices[index]
  }

  /// Applies an unpair this Mac learned to its own grants, without a new event.
  public func revokeLocally(deviceID: String) throws {
    var next = state
    for index in next.devices.indices where next.devices[index].id == deviceID && next.devices[index].revokedAt == nil {
      next.devices[index].revokedAt = now()
    }
    guard next.devices != state.devices else { return }
    try persist(next); state = next
  }

  public func revoke(deviceID: String, expected: CompanionPairedDevice? = nil) throws {
    if let expected, !isCurrent(expected) { throw Self.unauthorized }
    var next = state
    // An unpair is a distinct event. Every grant for this device that does
    // not acknowledge it is revoked here and, once synchronized, on every Mac;
    // only a pairing issued afterwards acknowledges it. Without a signing
    // identity the event stays local.
    let instant = now()
    let event = try identity.map { try PeerRevocation.signed(deviceID: deviceID, by: $0) }
      ?? PeerRevocation(eventID: UUID().uuidString.lowercased(), deviceID: deviceID, revokerDeviceID: deviceID, signature: Data())
    next.revocations = (next.revocations ?? []) + [event]
    for index in next.devices.indices where next.devices[index].id == deviceID {
      if next.devices[index].revokedAt == nil { next.devices[index].revokedAt = instant }
      if next.devices[index].localDevelopment == true {
        next.revokedDevelopmentIDs = (next.revokedDevelopmentIDs ?? []).union([deviceID.lowercased()])
      }
    }
    next.pendingQRPairings?.removeAll { $0.device.id == deviceID }
    try persist(next); state = next
    offer = nil
  }

  public func pendingPairingRequests() -> [CompanionPendingPairingRequest] {
    (state.approvals ?? []).filter { $0.state == .pending && $0.request.expiresAt > now() }.map(\.request)
  }

  public func requestPairing(_ request: CompanionPairingApprovalRequest, workspaceID: String? = nil) throws -> CompanionPairingApprovalResult {
    guard request.protocolVersion == CompanionProtocol.version else {
      throw Self.error("version_mismatch", "Update Woven Matter on both devices before pairing.")
    }
    try Self.validateIdentity(request.identity)
    guard UUID(uuidString: request.requestID) != nil, (32...256).contains(request.requestSecret.utf8.count) else {
      throw Self.error("invalid_pairing", "The pairing request is invalid.")
    }
    let proof = Self.proof(request.requestSecret)
    if let existing = (state.approvals ?? []).first(where: { $0.request.id == request.requestID && $0.request.expiresAt > now() }) {
      guard Self.constantTimeEqual(existing.proof, proof), existing.request.identity == request.identity,
            existing.invitationProof == request.invitationToken.map(Self.digest) else {
        throw Self.error("pairing_conflict", "This pairing request has changed. Start a new request.")
      }
      return try pairingResult(.init(requestID: request.requestID, requestSecret: request.requestSecret))
    }
    try checkPairingRate()
    guard !state.devices.contains(where: { $0.revokedAt == nil && $0.id.lowercased() == request.identity.deviceID.lowercased() }) else {
      throw Self.error("invalid_device", "This device is already paired. Revoke its old pairing before pairing it again.")
    }
    var next = state
    var entries = (next.approvals ?? []).filter { $0.request.expiresAt > now() }
    guard entries.count < 64 else { throw Self.error("rate_limited", "Too many pending pairing requests. Try again later.") }
    let pending = CompanionPendingPairingRequest(id: request.requestID, identity: request.identity, expiresAt: now().addingTimeInterval(600))
    entries.append(.init(request: pending, proof: proof, invitationProof: request.invitationToken.map(Self.digest), state: .pending, purpose: request.purpose))
    if let token = request.invitationToken {
      guard let offer, offer.expiresAt > now(), let workspaceID,
            offer.deviceID == request.identity.deviceID,
            Self.constantTimeEqual(offer.digest, Self.digest(token)) else {
        throw Self.error("invalid_pairing", "This invitation is invalid or expired.")
      }
      let credential = try Self.randomToken()
      let encrypted = try AES.GCM.seal(Data(credential.utf8), using: Self.key(request.requestSecret)).combined!
      entries[entries.count - 1].state = .approved
      entries[entries.count - 1].workspaceID = workspaceID
      entries[entries.count - 1].encryptedCredential = encrypted
        next.devices.append(Self.issued(.init(id: request.identity.deviceID, name: request.identity.deviceName, pairedAt: now(), revokedAt: nil,
        metadata: request.identity.metadata, lastSeenAt: nil, credentialHash: Self.digest(credential)), in: next, purpose: request.purpose))
    }
    next.approvals = entries
    try persist(next); state = next
    if request.invitationToken != nil { self.offer = nil }
    approvalKeys[request.requestID] = Self.key(request.requestSecret)
    return try pairingResult(.init(requestID: request.requestID, requestSecret: request.requestSecret))
  }

  public func pairingResult(_ request: CompanionPairingPoll) throws -> CompanionPairingApprovalResult {
    guard (32...256).contains(request.requestSecret.utf8.count),
          let entry = (state.approvals ?? []).first(where: { $0.request.id == request.requestID }),
          entry.request.expiresAt > now(), Self.constantTimeEqual(entry.proof, Self.proof(request.requestSecret)) else {
      throw Self.error("invalid_pairing", "The pairing request is invalid or expired.")
    }
    let key = Self.key(request.requestSecret)
    approvalKeys[request.requestID] = key
    guard entry.state == .approved else { return .init(state: entry.state, expiresAt: entry.request.expiresAt) }
    guard let encrypted = entry.encryptedCredential, let workspaceID = entry.workspaceID,
          let credential = String(data: try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key), encoding: .utf8),
          state.devices.contains(where: { $0.id == entry.request.identity.deviceID && $0.revokedAt == nil && Self.constantTimeEqual($0.credentialHash, Self.digest(credential)) }) else {
      throw Self.unauthorized
    }
    return .init(state: .approved, expiresAt: entry.request.expiresAt,
      pairing: .init(workspaceID: workspaceID, deviceID: entry.request.identity.deviceID, credential: credential))
  }

  /// Only the local settings/backend owner invokes this method. There is no HTTP
  /// endpoint that approves requests or expands a pending request's authority.
  public func approvePairing(id: String, workspaceID: String) throws {
    var next = state
    guard let index = next.approvals?.firstIndex(where: { $0.request.id == id && $0.request.expiresAt > now() }),
          let entry = next.approvals?[index], entry.state == .pending else {
      throw Self.error("invalid_pairing", "This pairing request is no longer pending.")
    }
    guard let key = approvalKeys[id] else { throw Self.error("pairing_pending", "Wait for this Mac to reconnect, then approve its request.") }
    let identity = entry.request.identity
    guard !next.devices.contains(where: { $0.revokedAt == nil && $0.id.lowercased() == identity.deviceID.lowercased() }) else {
      throw Self.error("invalid_device", "This device is already paired.")
    }
    let credential = try Self.randomToken()
    let encrypted = try AES.GCM.seal(Data(credential.utf8), using: key).combined!
    next.devices.append(Self.issued(.init(id: identity.deviceID, name: identity.deviceName, pairedAt: now(), revokedAt: nil,
      metadata: identity.metadata, lastSeenAt: nil, credentialHash: Self.digest(credential)), in: next, purpose: entry.purpose))
    next.approvals?[index].state = .approved
    next.approvals?[index].workspaceID = workspaceID
    next.approvals?[index].encryptedCredential = encrypted
    try persist(next); state = next
  }

  public func denyPairing(id: String) throws {
    var next = state
    guard let index = next.approvals?.firstIndex(where: { $0.request.id == id }), next.approvals?[index].state == .pending else { return }
    next.approvals?[index].state = .denied
    try persist(next); state = next; approvalKeys.removeValue(forKey: id)
  }

  private func checkPairingRate() throws {
    let instant = now()
    attempts.removeAll { instant.timeIntervalSince($0) >= 60 }
    guard attempts.count < 10 else { throw Self.error("rate_limited", "Too many pairing attempts. Wait a minute and try again.") }
    attempts.append(instant)
  }
  private static func validateIdentity(_ identity: CompanionPairingDeviceIdentity) throws {
    guard UUID(uuidString: identity.deviceID) != nil, !identity.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          identity.deviceName.utf8.count <= 120, !identity.deviceName.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
      throw error("invalid_device", "The device information is invalid.")
    }
    try validateMetadata(identity.metadata)
  }
  private static func validateMetadata(_ metadata: CompanionDeviceMetadata?) throws {
    for value in [metadata?.osVersion, metadata?.appVersion, metadata?.developmentInstance].compactMap({ $0 }) {
      guard value.utf8.count <= 120, !value.unicodeScalars.contains(where: { $0.value < 32 || (127...159).contains($0.value) }) else {
        throw error("invalid_device", "The device version information is invalid.")
      }
    }
  }
  private static func proof(_ secret: String) -> Data { digest("woven-pairing-proof\0" + secret) }
  private static func key(_ secret: String) -> SymmetricKey { SymmetricKey(data: digest("woven-pairing-key\0" + secret)) }

  private func persist(_ next: State) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".companion-credentials-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let bytes = try JSONEncoder().encode(next)
    guard bytes.count <= 16_777_216 else { throw Self.error("credential_store", "The paired-device store exceeds its safety limit.") }
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else {
      throw Self.error("credential_store", "Could not save paired-device credentials.")
    }
    let handle = try FileHandle(forWritingTo: temporary)
    do { try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close() }
    catch { try? handle.close(); throw error }
    guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw POSIXError(.EIO) }
    let descriptor = Darwin.open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
  }

  private static func randomToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw error("random_failed", "Could not securely create a pairing code.")
    }
    return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  private static func digest(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
  private static let unauthorized = error("unauthorized", "This device is not paired or its access was revoked.")
  private static func error(_ code: String, _ message: String) -> CompanionAPIError {
    CompanionAPIError(code: code, message: message)
  }
}

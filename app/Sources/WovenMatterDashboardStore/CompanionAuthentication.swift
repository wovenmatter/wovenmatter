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
  }
  private struct PendingQRPairing: Codable {
    var device: CompanionPairedDevice
    var workspaceID: String
    var expiresAt: Date
    var offerProof: Data
    var encryptedCredential: Data
  }
  private struct State: Codable {
    var version = 1
    var devices: [CompanionPairedDevice] = []
    var approvals: [Approval]?
    var pendingQRPairings: [PendingQRPairing]?
    var revokedDevelopmentIDs: Set<String>?
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
    lastSeenSaved = state.devices.reduce(into: [:]) { $0[$1.id] = $1.lastSeenAt }
  }

  public func devices() -> [CompanionPairedDevice] {
    var seen = Set<String>()
    return state.devices.filter { $0.revokedAt == nil && (!$0.isDevelopment || now().timeIntervalSince($0.lastSeenAt ?? .distantPast) < 45) && seen.insert($0.id).inserted }
  }

  /// Normal Dev quit withdraws presence without making the identity permanently
  /// revoked. Explicit Unpair continues to block automatic reenrollment.
  public func suspendLocalDevelopment(deviceID: String, credential: String) throws {
    guard let index = state.devices.firstIndex(where: { $0.id == deviceID && $0.isDevelopment && $0.revokedAt == nil && Self.constantTimeEqual($0.credentialHash, Self.digest(credential)) }) else { throw Self.unauthorized }
    var next = state; next.devices[index].lastSeenAt = nil
    try persist(next); state = next; lastSeenSaved.removeValue(forKey: deviceID)
  }

  /// Only authenticated paired Macs receive verifiers. Bearers and pending
  /// pairing secrets stay on their originating device. Revocation is monotonic.
  public func peerDevices() -> [CompanionPairedDevice] { state.devices.filter { !$0.isDevelopment } }
  public func mergePeerDevices(_ devices: [CompanionPairedDevice]) throws {
    guard devices.count <= 4096, devices.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.credentialHash.count == 32 && !$0.isDevelopment }) else { throw Self.unauthorized }
    var next = state
    for incoming in devices {
      if let index = next.devices.firstIndex(where: { $0.id == incoming.id && $0.credentialHash == incoming.credentialHash }) {
        if let revoked = incoming.revokedAt { next.devices[index].revokedAt = next.devices[index].revokedAt.map { min($0, revoked) } ?? revoked }
      } else { next.devices.append(incoming) }
    }
    guard next.devices.count <= 4096 else { throw Self.unauthorized }
    try persist(next); state = next
  }
  /// Reciprocal enrollment is allowed only after local approval of the first
  /// direction. Retrying the same grant cannot revive a revoked credential.
  public func enrollPeer(deviceID: String, name: String, token: String) throws {
    guard UUID(uuidString: deviceID) != nil, !name.isEmpty, name.utf8.count <= 256,
          (32...256).contains(token.utf8.count) else { throw Self.unauthorized }
    let hash = Self.digest(token)
    if let existing = state.devices.first(where: { $0.id == deviceID && $0.credentialHash == hash }) {
      guard existing.revokedAt == nil else { throw Self.unauthorized }; return
    }
    var next = state
    next.devices.append(.init(id: deviceID, name: name, pairedAt: now(), metadata: .init(kind: .mac), credentialHash: hash))
    try persist(next); state = next
  }
  public func peerProof(_ challenge: PairedMacProofChallenge, route: PairedMacRoute) throws -> PairedMacProof {
    guard challenge.nonce.count == 32, let device = state.devices.first(where: {
      $0.id == challenge.deviceID && $0.revokedAt == nil && $0.kind == .mac && !$0.isDevelopment
        && SHA256.hash(data: $0.credentialHash).map { String(format: "%02x", $0) }.joined() == challenge.credentialID
    }) else { throw Self.unauthorized }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return .init(route: route, signature: Data(HMAC<SHA256>.authenticationCode(for: challenge.nonce + (try encoder.encode(route)), using: SymmetricKey(data: device.credentialHash))))
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
    state.devices.contains { $0.id == device.id && $0.revokedAt == nil && Self.constantTimeEqual($0.credentialHash, device.credentialHash) }
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
      throw Self.error("workspace_mismatch", "The central database changed. Generate a new pairing code.")
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
    next.devices.append(entry.device)
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
        expiresAt: instant.addingTimeInterval(300), offerProof: Self.digest(request.token), encryptedCredential: encrypted))
    } else {
      // Legacy clients retain their v3 pairing contract.
      next.devices.append(device)
    }
    try persist(next)
    state = next
    self.offer = nil
    return CompanionPairResponse(workspaceID: workspaceID, deviceID: request.deviceID, credential: credential, confirmationRequired: request.requiresConfirmation == true ? true : nil)
  }

  public func authenticate(bearer: String, metadata: CompanionDeviceMetadata? = nil) throws -> CompanionPairedDevice {
    guard (32...256).contains(bearer.utf8.count) else { throw Self.unauthorized }
    let digest = Self.digest(bearer)
    guard let index = state.devices.firstIndex(where: {
      $0.revokedAt == nil && Self.constantTimeEqual($0.credentialHash, digest)
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

  public func revoke(deviceID: String, expected: CompanionPairedDevice? = nil) throws {
    if let expected, !isCurrent(expected) { throw Self.unauthorized }
    var next = state
    if let index = next.devices.firstIndex(where: { $0.id == deviceID }) {
      if next.devices[index].revokedAt == nil { next.devices[index].revokedAt = now() }
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
    entries.append(.init(request: pending, proof: proof, invitationProof: request.invitationToken.map(Self.digest), state: .pending))
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
        next.devices.append(.init(id: request.identity.deviceID, name: request.identity.deviceName, pairedAt: now(), revokedAt: nil,
        metadata: request.identity.metadata, lastSeenAt: nil, credentialHash: Self.digest(credential)))
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
    next.devices.append(.init(id: identity.deviceID, name: identity.deviceName, pairedAt: now(), revokedAt: nil,
      metadata: identity.metadata, lastSeenAt: nil, credentialHash: Self.digest(credential)))
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

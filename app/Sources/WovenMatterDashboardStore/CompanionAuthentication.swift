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
  fileprivate let credentialHash: Data
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
  private struct State: Codable {
    var version = 1
    var devices: [CompanionPairedDevice] = []
    var approvals: [Approval]?
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

  public func devices() -> [CompanionPairedDevice] { state.devices.filter { $0.revokedAt == nil } }
  public func deviceConnections() -> [CompanionDeviceConnection] {
    devices().map { .init(id: $0.id, name: $0.name, metadata: $0.metadata ?? .init(), pairedAt: $0.pairedAt, lastSeenAt: $0.lastSeenAt) }
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

  public func pair(_ request: CompanionPairRequest, workspaceID: String) throws -> CompanionPairResponse {
    guard request.protocolVersion == CompanionPairingPayload.currentProtocolVersion else {
      throw Self.error("version_mismatch", "Update Woven Matter on both devices before pairing.")
    }
    let instant = now()
    attempts.removeAll { instant.timeIntervalSince($0) >= 60 }
    guard attempts.count < 10 else { throw Self.error("rate_limited", "Too many pairing attempts. Wait a minute and try again.") }
    attempts.append(instant)
    guard let offer, offer.expiresAt > instant,
          Self.constantTimeEqual(offer.digest, Self.digest(request.token)),
          offer.deviceID == nil || offer.deviceID == request.deviceID else {
      throw Self.error("invalid_pairing", "The pairing code is invalid or expired. Generate another code on the Mac.")
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
    // Revoked secrets cannot authorize requests and need no unbounded retention.
    next.devices = state.devices.filter { $0.revokedAt == nil } + [device]
    try persist(next)
    state = next
    self.offer = nil
    return CompanionPairResponse(workspaceID: workspaceID, deviceID: request.deviceID, credential: credential)
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
    if changedMetadata || instant.timeIntervalSince(lastSeenSaved[id] ?? .distantPast) >= 60 {
      try persist(next); lastSeenSaved[id] = instant
    }
    state = next
    return next.devices[index]
  }

  public func revoke(deviceID: String, expected: CompanionPairedDevice? = nil) throws {
    if let expected, !isCurrent(expected) { throw Self.unauthorized }
    var next = state
    if let index = next.devices.firstIndex(where: { $0.id == deviceID }) {
      next.devices[index].revokedAt = now()
      try persist(next)
      state = next
    }
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
      next.devices = next.devices.filter { $0.revokedAt == nil }
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
    next.devices = next.devices.filter { $0.revokedAt == nil }
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
    for value in [metadata?.osVersion, metadata?.appVersion].compactMap({ $0 }) {
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

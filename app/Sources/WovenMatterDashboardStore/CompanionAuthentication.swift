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
  fileprivate let credentialHash: Data
}

/// App-owned credentials. Only random-token digests are written to disk; pairing
/// secrets are memory-only. A save must reach stable storage before acknowledgement.
public actor CompanionAuthentication {
  private struct State: Codable { var version = 1; var devices: [CompanionPairedDevice] = [] }
  private struct Offer { let digest: Data; let expiresAt: Date }
  private let fileURL: URL
  private var state: State
  private var offer: Offer?
  private var attempts: [Date] = []
  private let now: @Sendable () -> Date

  public init(fileURL: URL, now: @escaping @Sendable () -> Date = Date.init) throws {
    self.fileURL = fileURL
    self.now = now
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let size = (try fileURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
      guard size <= 1_048_576 else { throw Self.error("credential_store", "The paired-device store exceeds its safety limit.") }
      state = try JSONDecoder().decode(State.self, from: Data(contentsOf: fileURL))
      guard state.version == 1 else { throw Self.error("credential_store", "This paired-device store requires a newer Woven Matter.") }
    } else { state = State() }
  }

  public func devices() -> [CompanionPairedDevice] { state.devices.filter { $0.revokedAt == nil } }

  public func createOffer(endpoint: URL) throws -> (payload: CompanionPairingPayload, expiresAt: Date) {
    guard !state.devices.contains(where: { $0.revokedAt == nil }) else {
      throw Self.error("already_paired", "Revoke the paired iPhone before pairing another device.")
    }
    let secret = try Self.randomToken()
    let expiresAt = now().addingTimeInterval(300)
    offer = Offer(digest: Self.digest(secret), expiresAt: expiresAt)
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
          Self.constantTimeEqual(offer.digest, Self.digest(request.token)) else {
      throw Self.error("invalid_pairing", "The pairing code is invalid or expired. Generate another code on the Mac.")
    }
    guard UUID(uuidString: request.deviceID) != nil,
          !request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          request.deviceName.utf8.count <= 120,
          !state.devices.contains(where: { $0.revokedAt == nil }) else {
      throw Self.error("invalid_device", "This iPhone cannot be paired. Check the Mac's paired-device settings.")
    }
    let credential = try Self.randomToken()
    let device = CompanionPairedDevice(id: request.deviceID,
      name: request.deviceName, pairedAt: instant, revokedAt: nil,
      credentialHash: Self.digest(credential))
    var next = state
    // Revoked secrets cannot authorize requests and need no unbounded retention.
    next.devices = [device]
    try persist(next)
    state = next
    self.offer = nil
    return CompanionPairResponse(workspaceID: workspaceID, deviceID: request.deviceID, credential: credential)
  }

  public func authenticate(bearer: String) throws -> CompanionPairedDevice {
    guard (32...256).contains(bearer.utf8.count) else { throw Self.unauthorized }
    let digest = Self.digest(bearer)
    guard let device = state.devices.first(where: {
      $0.revokedAt == nil && Self.constantTimeEqual($0.credentialHash, digest)
    }) else { throw Self.unauthorized }
    return device
  }

  public func revoke(deviceID: String) throws {
    var next = state
    if let index = next.devices.firstIndex(where: { $0.id == deviceID }) {
      next.devices[index].revokedAt = now()
      try persist(next)
      state = next
    }
    offer = nil
  }

  private func persist(_ next: State) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".companion-credentials-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let bytes = try JSONEncoder().encode(next)
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

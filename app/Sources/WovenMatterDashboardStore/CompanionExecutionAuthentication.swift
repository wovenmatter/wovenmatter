import CryptoKit
import Darwin
import Foundation
import Security
import WovenMatterCore

/// Separate device-scoped secrets for execution. Central-library credentials do
/// not authorize this endpoint, and the store never persists a raw bearer.
public actor CompanionExecutionAuthentication {
  public struct Scope: Codable, Equatable, Sendable {
    public let deviceID: String
    public let libraryID: String
    public let workspaceID: String
  }
  /// `provisionedBy` names the paired Mac that obtained a grant for one of its
  /// own mobile devices; nil means this Mac issued it for a device it paired.
  /// `known` is true for every grant issued with recorded provenance; a grant
  /// from an earlier version cannot prove who received its token.
  private struct Grant: Codable { var scope: Scope; var digest: Data; var provisionedBy: String?; var known: Bool? }
  private struct State: Codable { var version = 1; var grants: [Grant] = [] }
  private let fileURL: URL
  private var state: State
  public init(fileURL: URL) throws {
    self.fileURL = fileURL
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let bytes = try Data(contentsOf: fileURL)
      guard bytes.count <= 1_024 * 1_024 else { throw CompanionAPIError(code: "credential_store", message: "Execution credentials exceed their safety limit.") }
      state = try JSONDecoder().decode(State.self, from: bytes)
      guard state.version == 1 else { throw CompanionAPIError(code: "credential_store", message: "Execution credentials require a newer app.") }
    } else { state = State() }
  }
  public func provision(deviceID: String, libraryID: String, workspaceID: String, provisionedBy: String? = nil) throws -> String {
    guard [deviceID, libraryID, workspaceID].allSatisfy({ UUID(uuidString: $0) != nil }) else { throw unauthorized }
    let scope = Scope(deviceID: deviceID, libraryID: libraryID, workspaceID: workspaceID)
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CompanionAPIError(code: "random_failed", message: "Could not securely provision execution access.")
    }
    let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    var next = state; next.grants.removeAll { $0.scope == scope }
    guard next.grants.count < 128 else { throw CompanionAPIError(code: "device_limit", message: "Revoke unused execution device access before provisioning more.") }
    next.grants.append(Grant(scope: scope, digest: Data(SHA256.hash(data: Data(token.utf8))), provisionedBy: provisionedBy, known: true))
    try persist(next); state = next
    return token
  }
  /// The grant's scope and provenance, for live per-grant authorization.
  public struct AuthenticatedGrant: Sendable { public let scope: Scope; public let provisionedBy: String? }
  public func authenticateGrant(bearer: String) throws -> AuthenticatedGrant {
    guard (32...256).contains(bearer.utf8.count) else { throw unauthorized }
    let hash = Data(SHA256.hash(data: Data(bearer.utf8)))
    guard let grant = state.grants.first(where: { constantTimeEqual($0.digest, hash) }) else { throw unauthorized }
    return .init(scope: grant.scope, provisionedBy: grant.provisionedBy)
  }
  public func authenticate(bearer: String) throws -> Scope {
    guard (32...256).contains(bearer.utf8.count) else { throw unauthorized }
    let hash = Data(SHA256.hash(data: Data(bearer.utf8)))
    guard let grant = state.grants.first(where: { constantTimeEqual($0.digest, hash) }) else { throw unauthorized }
    return grant.scope
  }
  public func revoke(deviceID: String) throws {
    var next = state; next.grants.removeAll { $0.scope.deviceID == deviceID }
    try persist(next); state = next
  }
  /// Revokes every execution and inference grant derived through one paired
  /// Mac, leaving grants this Mac issued for the same devices.
  @discardableResult
  public func revoke(provisionedBy deviceID: String) throws -> [Scope] {
    let removed = state.grants.filter { $0.provisionedBy == deviceID }.map(\.scope)
    guard !removed.isEmpty else { return [] }
    var next = state; next.grants.removeAll { $0.provisionedBy == deviceID }
    try persist(next); state = next
    return removed
  }
  /// A grant issued before provenance was recorded cannot prove who received
  /// its token: a device paired here today may have been enrolled through
  /// another Mac before. Every such grant except this Mac's own is retired;
  /// the device enrolls again through an active Mac. Each grant is judged by
  /// itself, so new grants never exempt older ones.
  public func retireUnknownProvenance(keeping ownDeviceID: String) throws {
    var next = state
    next.grants.removeAll { $0.known != true && $0.scope.deviceID != ownDeviceID }
    guard next.grants.count != state.grants.count else { return }
    try persist(next); state = next
  }
  private var unauthorized: CompanionAPIError { .init(code: "unauthorized", message: "This execution credential is missing, revoked, or belongs to a different workspace.") }
  private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
    return difference == 0
  }
  private func persist(_ next: State) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = directory.appendingPathComponent(".execution-credentials-\(UUID())")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
    let handle = try FileHandle(forWritingTo: temporary)
    do { try handle.write(contentsOf: JSONEncoder().encode(next)); try handle.synchronize(); try handle.close() }
    catch { try? handle.close(); throw error }
    guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw POSIXError(.EIO) }
    let fd = Darwin.open(directory.path, O_RDONLY); guard fd >= 0 else { throw POSIXError(.EIO) }
    defer { Darwin.close(fd) }; guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
  }
}

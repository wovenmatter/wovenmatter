import Foundation
import WovenMatterCore

/// This device's view of the member list: its own identity, the signed
/// records in its library and the verifier every member route uses.
public actor MemberDirectory {
  public nonisolated let identity: MemberIdentity
  public nonisolated let database: WorkspaceDatabase
  private var cached: (list: LibraryMemberList, at: Date)?
  private var observer: UUID?
  private let cacheLifetime: TimeInterval
  public nonisolated let verifier: MemberRequestVerifier

  public init(database: WorkspaceDatabase, identity: MemberIdentity, cacheLifetime: TimeInterval = 1) {
    self.database = database; self.identity = identity; self.cacheLifetime = cacheLifetime
    let box = WeakDirectory()
    verifier = MemberRequestVerifier(lookup: { await box.directory?.activeKey($0) },
      verify: { MemberIdentity.verify(publicKey: $0, signature: $1, message: $2) })
    box.directory = self
  }
  private final class WeakDirectory: @unchecked Sendable { weak var directory: MemberDirectory? }

  /// Anchors this device and keeps its own self-signed entry current. A
  /// member's own entry may change only its name and endpoints.
  public func ensureSelf(name: String, endpoints: [URL]) async throws {
    try await database.saveLibraryMemberAnchor(identity.anchor)
    let records = try await database.libraryMemberRecords()
    let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
    if let current = records.entries.first(where: { $0.deviceID == identity.deviceID && $0.addedBy == identity.deviceID }),
       current.publicKey == identity.publicKey, current.name == (clean.isEmpty ? "Device" : clean), current.endpoints == endpoints, current.kind == identity.kind {
      return
    }
    try await database.saveLibraryMemberEntries([try .signed(deviceID: identity.deviceID, kind: identity.kind, name: name,
      publicKey: identity.publicKey, endpoints: endpoints, by: identity)])
    invalidate()
  }

  public func list() async throws -> LibraryMemberList {
    if let cached, Date().timeIntervalSince(cached.at) < cacheLifetime { return cached.list }
    let list = try await database.libraryMembers()
    cached = (list, Date())
    return list
  }
  public func invalidate() { cached = nil }

  /// The key a request may be verified with: a current, unremoved member
  /// other than this device.
  public func activeKey(_ deviceID: String) async -> MemberKey? {
    guard deviceID != identity.deviceID, let member = try? await list().active(deviceID) else { return nil }
    return member.key
  }
  public func member(_ deviceID: String) async -> LibraryMember? { try? await list().active(deviceID) }

  /// Authenticates one signed request (any route: execution, mobile, bots
  /// WebSocket upgrade) and returns the current member that signed it.
  public func authenticate(_ request: CompanionHTTPRequest, allowing kinds: Set<MemberKind> = Set(MemberKind.allCases)) async throws -> LibraryMember {
    let key = try await verifier.verify(method: request.method, target: request.target, headers: request.headers, body: request.body, allowing: kinds)
    guard let member = await member(key.deviceID) else { throw MemberRequestError.unknown }
    return member
  }

  /// Adds (or re-adds) a device. Only a Mac member signs entries, because
  /// adding needs the pairing UI.
  @discardableResult
  public func add(deviceID: String, kind: MemberKind, name: String, publicKey: Data, endpoints: [URL]) async throws -> LibraryMemberEntry {
    guard identity.kind == .mac else {
      throw CompanionAPIError(code: "wrong_device", message: "Only a Mac adds devices.")
    }
    guard deviceID.lowercased() != identity.deviceID, publicKey.count == 32 else {
      throw CompanionAPIError(code: "invalid_member", message: "This device cannot be added with that identity.")
    }
    if let current = try await list().members.first(where: { $0.deviceID == deviceID.lowercased() }), current.publicKey != publicKey {
      throw CompanionAPIError(code: "member_key_changed", message: "This device presented a different key from the one already added. Remove it first, then add it again.")
    }
    let entry = try LibraryMemberEntry.signed(deviceID: deviceID, kind: kind, name: name, publicKey: publicKey, endpoints: endpoints, by: identity)
    try await database.saveLibraryMemberEntries([entry])
    invalidate()
    return entry
  }

  /// A signed removal, applied by every device as soon as it synchronizes.
  @discardableResult
  public func remove(_ deviceID: String) async throws -> LibraryMemberRevocation {
    guard identity.kind == .mac || deviceID.lowercased() == identity.deviceID else {
      throw CompanionAPIError(code: "wrong_device", message: "Only a Mac removes other devices.")
    }
    let revocation = try LibraryMemberRevocation.signed(deviceID: deviceID, by: identity)
    try await database.saveLibraryMemberRevocations([revocation])
    invalidate()
    return revocation
  }

  /// The complete signed record set with this device as the new member's
  /// anchor, for a device that cannot pair through the UI (a Linux host).
  public func adoption() async throws -> LibraryMemberAdoption {
    let records = try await database.libraryMemberRecords()
    return .init(anchor: identity.anchor, entries: records.entries, revocations: records.revocations)
  }

  /// Accepts an adoption delivered over a trusted local channel. Its anchor
  /// becomes a trust root; the entries still need their signatures.
  public func adopt(_ adoption: LibraryMemberAdoption) async throws -> LibraryMemberList {
    guard adoption.anchor.kind == .mac, adoption.anchor.deviceID != identity.deviceID, adoption.anchor.publicKey.count == 32 else {
      throw CompanionAPIError(code: "invalid_member", message: "Only a Mac can add this machine.")
    }
    guard adoption.entries.contains(where: { entry in
      entry.deviceID == identity.deviceID && entry.addedBy == adoption.anchor.deviceID && entry.publicKey == identity.publicKey
        && entry.kind == identity.kind && entry.isWellFormed && entry.verifies(with: adoption.anchor.publicKey)
    }) else {
      throw CompanionAPIError(code: "invalid_member", message: "The adding Mac did not sign this machine's current key.")
    }
    try await database.saveLibraryMemberEntries(adoption.entries)
    try await database.saveLibraryMemberRevocations(adoption.revocations)
    try await database.saveLibraryMemberAnchor(adoption.anchor)
    invalidate()
    return try await list()
  }
}

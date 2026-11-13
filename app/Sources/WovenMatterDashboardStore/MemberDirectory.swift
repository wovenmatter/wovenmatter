import Foundation
import WovenMatterCore

/// This device's view of the member list: its own identity, the signed
/// records in its library and the verifier every member route uses.
public actor MemberDirectory {
  public nonisolated let identity: MemberIdentity
  public nonisolated let database: WorkspaceDatabase
  private var cached: (list: LibraryMemberList, at: Date)?
  private let cacheLifetime: TimeInterval
  private let pinAfter: TimeInterval
  public nonisolated let verifier: MemberRequestVerifier

  /// `pinAfter`: how long a Mac must stay trusted before it becomes an anchor.
  public init(database: WorkspaceDatabase, identity: MemberIdentity, cacheLifetime: TimeInterval = 1, pinAfter: TimeInterval = 24 * 60 * 60) {
    self.database = database; self.identity = identity; self.cacheLifetime = cacheLifetime; self.pinAfter = pinAfter
    let box = WeakDirectory()
    verifier = MemberRequestVerifier(audience: identity.deviceID, lookup: { await box.directory?.activeKey($0) },
      verify: { MemberIdentity.verify(publicKey: $0, signature: $1, message: $2) })
    box.directory = self
  }
  private final class WeakDirectory: @unchecked Sendable { weak var directory: MemberDirectory? }

  /// Anchors this device and keeps its own self-signed entry current. A
  /// member's own entry may change only its name and endpoints.
  public func ensureSelf(name: String, endpoints: [URL]) async throws {
    try await database.saveLibraryMemberAnchor(identity.anchor, replacing: true)
    let records = try await database.libraryMemberRecords()
    let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
    if let current = records.entries.first(where: { $0.deviceID == identity.deviceID && $0.addedBy == identity.deviceID }),
       current.publicKey == identity.publicKey, current.name == (clean.isEmpty ? "Device" : clean), current.endpoints == endpoints, current.kind == identity.kind {
      return
    }
    try await database.saveLibraryMemberEntries([try .signed(deviceID: identity.deviceID, kind: identity.kind, name: name,
      publicKey: identity.publicKey, endpoints: endpoints, by: identity, at: Self.after(records, identity.deviceID))])
    invalidate()
  }

  public func list() async throws -> LibraryMemberList {
    if let cached, Date().timeIntervalSince(cached.at) < cacheLifetime { return cached.list }
    let started = changes
    let list = try await database.libraryMembers(own: identity.deviceID)
    try await pin(list)
    // A change while this read was under way may not be in it: such a list is
    // neither cached nor returned (a sweep acting on it would close a member's
    // socket that was just added, or keep one that was just removed).
    guard started == changes else { return try await self.list() }
    cached = (list, Date())
    return list
  }
  /// Counts invalidations, so a read knows whether one happened meanwhile.
  private var changes = 0
  /// Every change to the member list (a sync that received records, or a
  /// local add or removal) invalidates the cache, and observers hear of it.
  public func invalidate() {
    changes += 1
    cached = nil
    for observer in observers.values { observer() }
  }
  private var observers: [UUID: @Sendable () -> Void] = [:]
  /// `handler` runs (on this actor; keep it short) whenever the member list may have changed.
  @discardableResult
  public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> UUID {
    let id = UUID(); observers[id] = handler; return id
  }
  public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

  /// A Mac this device has trusted continuously for `pinAfter` becomes one
  /// of its anchors, so its trust no longer depends on the Mac that
  /// introduced it. The wait means a Mac vouched for by a key that is being
  /// removed (a race the removal wins within minutes) is never pinned. An
  /// anchor's key is never replaced and it can still be revoked.
  private func pin(_ list: LibraryMemberList) async throws {
    let now = MemberRequestSignature.now()
    let trusted = Dictionary(list.members.filter { $0.kind == .mac && !$0.revoked && $0.deviceID != identity.deviceID }.map { ($0.deviceID, $0) },
                             uniquingKeysWith: { first, _ in first })
    let anchored = Set(try await database.libraryMemberRecords().anchors.map(\.deviceID))
    let candidates = try await database.libraryMemberPinCandidates()
    var saving: [(anchor: LibraryMemberAnchor, firstSeen: Int64)] = [], removing: [String] = []
    for (id, member) in trusted where !anchored.contains(id) {
      let anchor = LibraryMemberAnchor(deviceID: id, kind: .mac, publicKey: member.publicKey)
      guard let candidate = candidates[id], candidate.anchor.publicKey == member.publicKey else { saving.append((anchor, now)); continue }
      if Double(now - candidate.firstSeen) >= pinAfter * 1_000 {
        try await database.saveLibraryMemberAnchor(anchor)
        removing.append(id)
      }
    }
    removing += candidates.keys.filter { trusted[$0] == nil || anchored.contains($0) }
    if !saving.isEmpty || !removing.isEmpty { try await database.updateLibraryMemberPinCandidates(saving: saving, removing: removing) }
  }

  /// The key a request may be verified with: a current, unremoved member
  /// other than this device.
  public func activeKey(_ deviceID: String) async -> MemberKey? {
    guard deviceID != identity.deviceID, let member = try? await list().active(deviceID) else { return nil }
    return member.key
  }
  public func member(_ deviceID: String) async -> LibraryMember? { try? await list().active(deviceID) }

  /// The member that serves `workspace`'s endpoint, the audience of signed
  /// requests to it (`MemberAudience.serving`); nil when it is not known yet.
  public func audience(for workspace: ExecutionWorkspace) async -> String? {
    guard let list = try? await list() else { return nil }
    return MemberAudience.serving(workspace, members: list.members.map {
      .init(deviceID: $0.deviceID, kind: $0.kind, endpoints: $0.endpoints, revoked: $0.revoked)
    })
  }

  /// Authenticates one signed request (any route: execution, mobile, bots
  /// WebSocket upgrade) and returns the current member that signed it.
  public func authenticate(_ request: LibraryHTTPRequest, allowing kinds: Set<MemberKind> = Set(MemberKind.allCases)) async throws -> LibraryMember {
    let key = try await verifier.verify(method: request.method, target: request.target, headers: request.headers, body: request.body, allowing: kinds)
    guard let member = await member(key.deviceID) else { throw MemberRequestError.unknown }
    return member
  }

  /// A time after every record about `device`: a new signature always
  /// supersedes what this device holds, whatever the clocks of its signers.
  static func after(_ records: (entries: [LibraryMemberEntry], revocations: [LibraryMemberRevocation], anchors: [LibraryMemberAnchor]),
                    _ device: String, now: Int64 = MemberRequestSignature.now()) -> Int64 {
    let device = device.lowercased()
    let latest = max(records.entries.filter { $0.deviceID == device && $0.addedAt <= now + LibraryMemberResolver.futureSkew }.map(\.addedAt).max() ?? 0,
                     records.revocations.filter { $0.deviceID == device && $0.revokedAt <= now + LibraryMemberResolver.futureSkew }.map(\.revokedAt).max() ?? 0)
    return max(now, latest + 1)
  }

  /// Whether `add` would accept this device and key, without signing.
  /// `replacingKey`: the user paired this phone again on this Mac, so a new
  /// key replaces the one already listed (a phone restored from a backup).
  public func checkAdd(deviceID: String, kind: MemberKind, publicKey: Data, replacingKey: Bool = false) async throws {
    _ = try await plan(deviceID: deviceID, kind: kind, publicKey: publicKey, replacingKey: replacingKey)
  }

  private func plan(deviceID: String, kind: MemberKind, publicKey: Data, replacingKey: Bool) async throws -> (current: LibraryMember?, endsOldKey: Bool) {
    guard identity.kind == .mac else {
      throw LibraryAPIError(code: "wrong_device", message: "Only a Mac adds devices.")
    }
    guard deviceID.lowercased() != identity.deviceID, publicKey.count == 32 else {
      throw LibraryAPIError(code: "invalid_member", message: "This device cannot be added with that identity.")
    }
    let current = try await list().members.first(where: { $0.deviceID == deviceID.lowercased() })
    guard let current, current.publicKey != publicKey else { return (current, false) }
    // A removed device comes back with whatever key it presents now. A
    // phone's key changes only when the user pairs it again on a Mac. A Mac
    // is pinned by key on every device, so its key never changes.
    guard kind != .mac, current.kind != .mac, current.revoked || (replacingKey && current.kind == kind) else {
      throw LibraryAPIError(code: "member_key_changed", message: "This device presented a different key from the one already added. Remove it first, then add it again.")
    }
    return (current, !current.revoked)
  }

  /// Adds (or re-adds) a device. Only a Mac member signs entries, because
  /// adding needs the pairing UI. A new key first ends the old one with a
  /// removal, so every entry for the old key stops counting.
  @discardableResult
  public func add(deviceID: String, kind: MemberKind, name: String, publicKey: Data, endpoints: [URL],
                  replacingKey: Bool = false) async throws -> LibraryMemberEntry {
    let plan = try await plan(deviceID: deviceID, kind: kind, publicKey: publicKey, replacingKey: replacingKey)
    let records = try await database.libraryMemberRecords()
    var time = Self.after(records, deviceID)
    if plan.endsOldKey {
      try await database.saveLibraryMemberRevocations([try .signed(deviceID: deviceID, by: identity, at: time)])
      time += 1
    }
    let entry = try LibraryMemberEntry.signed(deviceID: deviceID, kind: kind, name: name, publicKey: publicKey, endpoints: endpoints,
                                              by: identity, at: time)
    try await database.saveLibraryMemberEntries([entry])
    invalidate()
    return entry
  }

  /// A signed removal, applied by every device as soon as it synchronizes.
  /// Everything the removed device signed stops counting, so a Mac removing
  /// another Mac first re-signs what this Mac still holds from it: entries for
  /// the devices it added and removals it made. Those are written first and
  /// therefore reach every peer before the removal itself.
  @discardableResult
  public func remove(_ deviceID: String) async throws -> LibraryMemberRevocation {
    let device = deviceID.lowercased()
    guard identity.kind == .mac || device == identity.deviceID else {
      throw LibraryAPIError(code: "wrong_device", message: "Only a Mac removes other devices.")
    }
    let records = try await database.libraryMemberRecords()
    let revocation = try LibraryMemberRevocation.signed(deviceID: device, by: identity, at: Self.after(records, device))
    if identity.kind == .mac, device != identity.deviceID {
      let kept = try keeping(after: revocation, records: records)
      try await database.saveLibraryMemberEntries(kept.entries)
      try await database.saveLibraryMemberRevocations(kept.revocations)
    }
    try await database.saveLibraryMemberRevocations([revocation])
    invalidate()
    return revocation
  }

  /// The re-signatures that leave every other device as it is now once
  /// `revocation` voids its target's signatures.
  private func keeping(after revocation: LibraryMemberRevocation,
                       records: (entries: [LibraryMemberEntry], revocations: [LibraryMemberRevocation], anchors: [LibraryMemberAnchor]))
    throws -> (entries: [LibraryMemberEntry], revocations: [LibraryMemberRevocation]) {
    let own = identity.deviceID, now = MemberRequestSignature.now()
    let before = LibraryMemberResolver.resolve(entries: records.entries, revocations: records.revocations, anchors: records.anchors, own: own, now: now)
    var all = (entries: records.entries, revocations: records.revocations + [revocation], anchors: records.anchors)
    var signed: (entries: [LibraryMemberEntry], revocations: [LibraryMemberRevocation]) = ([], [])
    for _ in 0..<4 {
      let after = LibraryMemberResolver.resolve(entries: all.entries, revocations: all.revocations, anchors: all.anchors, own: own, now: now)
      var changed = false
      for member in before where member.deviceID != revocation.deviceID && member.deviceID != own {
        let next = after.first { $0.deviceID == member.deviceID }
        if !member.revoked, next == nil || next?.revoked == true || next?.publicKey != member.publicKey {
          let entry = try LibraryMemberEntry.signed(deviceID: member.deviceID, kind: member.kind, name: member.name, publicKey: member.publicKey,
                                                    endpoints: member.endpoints, by: identity, at: Self.after(all, member.deviceID, now: now))
          all.entries.append(entry); signed.entries.append(entry); changed = true
        } else if member.revoked, next?.revoked == false {
          let removal = try LibraryMemberRevocation.signed(deviceID: member.deviceID, by: identity, at: Self.after(all, member.deviceID, now: now))
          all.revocations.append(removal); signed.revocations.append(removal); changed = true
        }
      }
      if !changed { break }
    }
    return signed
  }

  /// The complete signed record set with this device as the new member's
  /// anchor, for a device that cannot pair through the UI (a Linux host).
  public func adoption() async throws -> LibraryMemberAdoption {
    let records = try await database.libraryMemberRecords()
    return .init(anchor: identity.anchor, entries: records.entries, revocations: records.revocations)
  }

  /// Accepts an adoption delivered over a trusted local channel. The first
  /// one anchors its Mac, which must have signed this machine's current key.
  /// After that this machine belongs to a library: an adoption only carries
  /// records (which also arrive by sync), from a Mac it already trusts with
  /// the key it trusts, and never adds or replaces an anchor.
  public func adopt(_ adoption: LibraryMemberAdoption) async throws -> LibraryMemberList {
    guard adoption.anchor.kind == .mac, adoption.anchor.deviceID != identity.deviceID, adoption.anchor.publicKey.count == 32 else {
      throw LibraryAPIError(code: "invalid_member", message: "Only a Mac can add this machine.")
    }
    let records = try await database.libraryMemberRecords()
    let adopted = records.anchors.contains { $0.kind == .mac && $0.deviceID != identity.deviceID }
    if adopted {
      guard let member = try await list().active(adoption.anchor.deviceID), member.kind == .mac,
            member.publicKey == adoption.anchor.publicKey else {
        throw LibraryAPIError(code: "already_adopted", message: "This machine already belongs to a library. Only one of its Macs can update it.")
      }
    } else {
      guard adoption.entries.contains(where: { entry in
        entry.deviceID == identity.deviceID && entry.addedBy == adoption.anchor.deviceID && entry.publicKey == identity.publicKey
          && entry.kind == identity.kind && entry.isWellFormed && entry.verifies(with: adoption.anchor.publicKey)
      }) else {
        throw LibraryAPIError(code: "invalid_member", message: "The adding Mac did not sign this machine's current key.")
      }
    }
    try await database.saveLibraryMemberEntries(adoption.entries)
    try await database.saveLibraryMemberRevocations(adoption.revocations)
    if !adopted { try await database.saveLibraryMemberAnchor(adoption.anchor) }
    invalidate()
    return try await list()
  }
}

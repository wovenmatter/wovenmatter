#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import WovenMatterCore

/// One signed member entry: an adding Mac vouches for a device's key, kind
/// and endpoints. Entries are library rows and synchronize like any content;
/// trust comes only from their signatures, resolved against local anchors.
/// See docs/architecture/WOVEN_EVERYWHERE.md, "Membership and device keys".
public struct LibraryMemberEntry: Codable, Equatable, Sendable {
  public let deviceID: String
  public let kind: MemberKind
  public let name: String
  public let publicKey: Data
  /// Base URLs where the member serves `v1/...` routes, for example
  /// `https://studio.tailnet.ts.net/wovenmatter/`. Empty for a phone.
  public let endpoints: [URL]
  public let addedBy: String
  /// Unix time in milliseconds, asserted by the signer.
  public let addedAt: Int64
  public let signature: Data

  public static let domain = "woven.member.entry.v1"
  static func statement(deviceID: String, kind: MemberKind, name: String, publicKey: Data, endpoints: [URL],
                        addedBy: String, addedAt: Int64) -> Data {
    canonical([("device", deviceID), ("kind", kind.rawValue), ("name", name), ("key", publicKey.base64EncodedString()),
               ("endpoints", endpoints.map(\.absoluteString).joined(separator: "\n")), ("added_by", addedBy),
               ("added_at", String(addedAt))], domain: domain)
  }
  var statement: Data {
    Self.statement(deviceID: deviceID, kind: kind, name: name, publicKey: publicKey, endpoints: endpoints, addedBy: addedBy, addedAt: addedAt)
  }
  public static func signed(deviceID: String, kind: MemberKind, name: String, publicKey: Data, endpoints: [URL],
                            by signer: MemberIdentity, at time: Int64 = MemberRequestSignature.now()) throws -> Self {
    let device = deviceID.lowercased()
    let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
    let entry = Self(deviceID: device, kind: kind, name: clean.isEmpty ? "Device" : clean, publicKey: publicKey,
                     endpoints: endpoints, addedBy: signer.deviceID, addedAt: time, signature: Data())
    return .init(deviceID: entry.deviceID, kind: kind, name: entry.name, publicKey: publicKey, endpoints: endpoints,
                 addedBy: signer.deviceID, addedAt: time, signature: try signer.sign(entry.statement))
  }
  var isWellFormed: Bool {
    PeerIdentifier.canonical(deviceID) != nil && PeerIdentifier.canonical(addedBy) != nil && publicKey.count == 32
      && signature.count == 64 && !name.isEmpty && name.utf8.count <= 512 && endpoints.count <= 8 && addedAt > 0
      && endpoints.allSatisfy { ["https", "http"].contains($0.scheme) && $0.absoluteString.utf8.count <= 512 }
  }
  func verifies(with key: Data) -> Bool { MemberIdentity.verify(publicKey: key, signature: signature, message: statement) }
}

/// A signed removal. Applied everywhere as soon as it synchronizes, as long
/// as its signer stands. Re-adding the device later takes a newer entry from
/// a standing Mac, which may carry a new key.
public struct LibraryMemberRevocation: Codable, Equatable, Sendable {
  public let eventID: String
  public let deviceID: String
  public let revokedBy: String
  public let revokedAt: Int64
  public let signature: Data

  public static let domain = "woven.member.revocation.v1"
  static func statement(eventID: String, deviceID: String, revokedBy: String, revokedAt: Int64) -> Data {
    canonical([("event", eventID), ("device", deviceID), ("revoked_by", revokedBy), ("revoked_at", String(revokedAt))], domain: domain)
  }
  var statement: Data { Self.statement(eventID: eventID, deviceID: deviceID, revokedBy: revokedBy, revokedAt: revokedAt) }
  public static func signed(deviceID: String, by signer: MemberIdentity, at time: Int64 = MemberRequestSignature.now()) throws -> Self {
    let event = UUID().uuidString.lowercased(), device = deviceID.lowercased()
    return .init(eventID: event, deviceID: device, revokedBy: signer.deviceID, revokedAt: time,
                 signature: try signer.sign(statement(eventID: event, deviceID: device, revokedBy: signer.deviceID, revokedAt: time)))
  }
  var isWellFormed: Bool {
    PeerIdentifier.canonical(eventID) != nil && PeerIdentifier.canonical(deviceID) != nil
      && PeerIdentifier.canonical(revokedBy) != nil && signature.count == 64 && revokedAt > 0
  }
}

/// A local trust root: this device itself, the Mac that adopted a Linux
/// host, and every Mac this device has trusted (pinned on first sight, so
/// removing the Mac that introduced it never cuts this device off from the
/// others). Anchors are local, never synchronize, are never removed and
/// never change key; any but this device's own can still be revoked.
public struct LibraryMemberAnchor: Codable, Equatable, Sendable {
  public let deviceID: String
  public let kind: MemberKind
  public let publicKey: Data
  public init(deviceID: String, kind: MemberKind, publicKey: Data) {
    self.deviceID = deviceID.lowercased(); self.kind = kind; self.publicKey = publicKey
  }
}

/// The resolved member list (`GET /v1/members` on the library socket).
public struct LibraryMember: Codable, Equatable, Sendable, Identifiable {
  public var id: String { deviceID }
  public let deviceID: String
  public let kind: MemberKind
  public let name: String
  public let publicKey: Data
  public let endpoints: [URL]
  public let addedBy: String
  public let revoked: Bool
  public var key: MemberKey { .init(deviceID: deviceID, kind: kind, name: name, publicKey: publicKey) }
}

public struct LibraryMemberList: Codable, Equatable, Sendable {
  public let members: [LibraryMember]
  /// Opaque; changes whenever any resolved field changes.
  public let revision: String
  /// This device has anchored a Mac (a Linux host's first adoption, or any
  /// Mac it has trusted). Anchors are never removed, so a Linux host that
  /// was adopted once never takes the installer's bearer for adoption again.
  public var adopted: Bool?
  public init(members: [LibraryMember], revision: String, adopted: Bool? = nil) {
    self.members = members; self.revision = revision; self.adopted = adopted
  }
  public func active(_ deviceID: String) -> LibraryMember? {
    members.first { $0.deviceID == deviceID.lowercased() && !$0.revoked }
  }
}

/// The full signed record set, as one device hands it to another it adds
/// over a trusted local channel (a Linux host's library socket).
public struct LibraryMemberAdoption: Codable, Sendable {
  public let anchor: LibraryMemberAnchor
  public let entries: [LibraryMemberEntry]
  public let revocations: [LibraryMemberRevocation]
  public init(anchor: LibraryMemberAnchor, entries: [LibraryMemberEntry], revocations: [LibraryMemberRevocation]) {
    self.anchor = anchor; self.entries = entries; self.revocations = revocations
  }
}

public enum LibraryMemberResolver {
  /// A record dated further ahead than this is ignored until then, so no
  /// signer can date one to outlast every later record.
  public static let futureSkew: Int64 = 10 * 60 * 1_000

  struct Trust: Equatable { var key: Data; var kind: MemberKind; var anchor: Bool }
  struct Reach { var trusted: [String: Trust]; var vouched: [String: [Int]] }

  /// Trust flows from this device's local anchors (itself, and every Mac it
  /// has trusted, pinned on first sight) through entries signed by Macs that
  /// still stand. Signer times only order records among standing Macs; they
  /// never decide which side of a dispute wins. See
  /// docs/architecture/WOVEN_EVERYWHERE.md, "Trust model".
  /// - Kind comes from a Mac's entry (or an anchor); a device's own entry
  ///   changes only its name and endpoints. A pinned anchor's key never changes.
  /// - An entry counts only while its signer stands and it is newer than every
  ///   effective revocation of its device, so everything a removed Mac signed
  ///   is void, whatever its date, and a revocation older than a standing
  ///   entry does nothing. Two live keys for one device: not trusted.
  /// - A revocation is effective when a standing Mac (or the device itself)
  ///   signed it. This device is removed here only by itself, and a Mac that
  ///   removed this device without a later re-add removes nobody here.
  /// - Removals that depend on each other are settled from the anchors
  ///   outward (the well-founded evaluation): a Mac stands only if no Mac that
  ///   might stand removed it, so two Macs that removed each other both lose
  ///   here and neither wins.
  public static func resolve(entries rawEntries: [LibraryMemberEntry], revocations rawRevocations: [LibraryMemberRevocation],
                             anchors rawAnchors: [LibraryMemberAnchor], own rawOwn: String? = nil,
                             now: Int64 = MemberRequestSignature.now()) -> [LibraryMember] {
    let limit = now + futureSkew
    let entries = rawEntries.filter { $0.isWellFormed && $0.addedAt <= limit }
    let revocations = rawRevocations.filter { $0.isWellFormed && $0.revokedAt <= limit }
    var anchors: [String: LibraryMemberAnchor] = [:]
    for anchor in rawAnchors where anchor.publicKey.count == 32 && anchors[anchor.deviceID] == nil { anchors[anchor.deviceID] = anchor }
    let own = rawOwn?.lowercased()
    var checked: [String: Bool] = [:]
    func entryVerifies(_ index: Int, _ key: Data) -> Bool {
      let memo = "e\(index):" + key.base64EncodedString()
      if let known = checked[memo] { return known }
      let result = entries[index].verifies(with: key); checked[memo] = result; return result
    }
    func revocationVerifies(_ index: Int, _ key: Data) -> Bool {
      let memo = "r\(index):" + key.base64EncodedString()
      if let known = checked[memo] { return known }
      let revocation = revocations[index]
      let result = MemberIdentity.verify(publicKey: key, signature: revocation.signature, message: revocation.statement)
      checked[memo] = result; return result
    }
    func earliest(_ list: [Int]) -> Int? { list.min { (entries[$0].addedAt, entries[$0].addedBy) < (entries[$1].addedAt, entries[$1].addedBy) } }

    // Who is trusted when `cut` holds each device's latest effective removal.
    func reach(cut: [String: Int64]) -> Reach {
      var trusted: [String: Trust] = [:], conflicted = Set<String>(), vouched: [String: [Int]] = [:]
      for (id, anchor) in anchors where id == own || cut[id] == nil {
        trusted[id] = .init(key: anchor.publicKey, kind: anchor.kind, anchor: true)
      }
      var changed = true
      while changed {
        changed = false
        // Entries for this device only add vouchers (its name and endpoints): its anchor fixes its key.
        for (index, entry) in entries.enumerated() where entry.addedBy != entry.deviceID
          && !conflicted.contains(entry.deviceID) && entry.addedAt > (cut[entry.deviceID] ?? 0) {
          guard let adder = trusted[entry.addedBy], adder.kind == .mac, !conflicted.contains(entry.addedBy),
                anchors[entry.deviceID].map({ $0.publicKey == entry.publicKey }) ?? true,
                entryVerifies(index, adder.key) else { continue }
          if !(vouched[entry.deviceID]?.contains(index) ?? false) { vouched[entry.deviceID, default: []].append(index) }
          if let current = trusted[entry.deviceID] {
            if current.key != entry.publicKey && !current.anchor { conflicted.insert(entry.deviceID); trusted.removeValue(forKey: entry.deviceID); changed = true }
            continue
          }
          trusted[entry.deviceID] = .init(key: entry.publicKey, kind: anchors[entry.deviceID]?.kind ?? entry.kind, anchor: false); changed = true
        }
      }
      // The earliest live Mac-signed entry fixes the kind; a phone cannot promote itself.
      for (device, list) in vouched where trusted[device]?.anchor == false && anchors[device] == nil {
        if let first = earliest(list.filter { entries[$0].publicKey == trusted[device]?.key }) { trusted[device]?.kind = entries[first].kind }
      }
      return .init(trusted: trusted, vouched: vouched)
    }

    // Latest effective removal per device when the members of `standing` may revoke.
    func effectiveCut(_ standing: [String: Trust]) -> [String: Int64] {
      var hostile = Set<String>()
      if let own {
        for (index, revocation) in revocations.enumerated() where revocation.deviceID == own && revocation.revokedBy != own {
          guard let revoker = standing[revocation.revokedBy], revoker.kind == .mac, revocationVerifies(index, revoker.key) else { continue }
          let readded = entries.indices.contains { other in
            let entry = entries[other]
            return entry.deviceID == own && entry.addedBy != own && entry.addedBy != revocation.revokedBy && entry.addedAt > revocation.revokedAt
              && standing[entry.addedBy].map { $0.kind == .mac && entryVerifies(other, $0.key) } == true
          }
          if !readded { hostile.insert(revocation.revokedBy) }
        }
      }
      var cut: [String: Int64] = [:]
      for (index, revocation) in revocations.enumerated() {
        guard let revoker = standing[revocation.revokedBy], revoker.kind == .mac || revocation.revokedBy == revocation.deviceID,
              !hostile.contains(revocation.revokedBy), revocation.deviceID != own || revocation.revokedBy == own,
              revocationVerifies(index, revoker.key) else { continue }
        cut[revocation.deviceID] = max(cut[revocation.deviceID] ?? 0, revocation.revokedAt)
      }
      return cut
    }

    // Alternating fixpoint: `upper` is everyone who might stand, `lower`
    // everyone who stands whatever the undecided Macs do.
    let ownOnly = own.flatMap { id in anchors[id].map { [id: Trust(key: $0.publicKey, kind: $0.kind, anchor: true)] } } ?? [:]
    let known = reach(cut: [:])
    var upper = reach(cut: effectiveCut(ownOnly)).trusted
    var lower = Reach(trusted: [:], vouched: [:])
    for _ in 0..<16 {
      let nextLower = reach(cut: effectiveCut(upper))
      let nextUpper = reach(cut: effectiveCut(nextLower.trusted)).trusted
      let settled = nextLower.trusted == lower.trusted && nextUpper == upper
      lower = nextLower; upper = nextUpper
      if settled { break }
    }
    let disputed = effectiveCut(upper)
    return Set(known.trusted.keys).union(lower.trusted.keys).sorted().compactMap { device in
      let standing = lower.trusted[device]
      // Unreachable and never removed: every Mac that vouched for it is gone.
      guard let trust = standing ?? (disputed[device] != nil ? known.trusted[device] : nil) else { return nil }
      let vouchers = ((standing != nil ? lower : known).vouched[device] ?? []).filter { entries[$0].publicKey == trust.key }
      // Name and endpoints: the newest entry with the trusted key, from a
      // voucher or the device itself.
      let candidates = vouchers + entries.indices.filter { index in
        entries[index].deviceID == device && entries[index].addedBy == device && entries[index].publicKey == trust.key
          && entryVerifies(index, trust.key)
      }
      let newest = candidates.max { (entries[$0].addedAt, entries[$0].addedBy) < (entries[$1].addedAt, entries[$1].addedBy) }.map { entries[$0] }
      let adder = earliest(vouchers).map { entries[$0].addedBy }
      return LibraryMember(deviceID: device, kind: trust.kind, name: newest?.name ?? "Device", publicKey: trust.key,
        endpoints: newest?.endpoints ?? [], addedBy: adder ?? device,
        revoked: standing == nil || (device == own && disputed[device] != nil))
    }
  }
}

/// This device's long-lived signing identity. On a Mac and an iPhone the key
/// lives in the Keychain; on Linux in a 0600 file under the data root.
public struct MemberIdentity: Sendable {
  public let deviceID: String
  public let kind: MemberKind
  private let key: Curve25519.Signing.PrivateKey
  public init(deviceID: String, kind: MemberKind, key: Curve25519.Signing.PrivateKey) {
    self.deviceID = deviceID.lowercased(); self.kind = kind; self.key = key
  }
  public init(_ peer: PeerSelf, kind: MemberKind = .mac) { self.init(deviceID: peer.deviceID, kind: kind, key: peer.key) }
  public var publicKey: Data { key.publicKey.rawRepresentation }
  public var anchor: LibraryMemberAnchor { .init(deviceID: deviceID, kind: kind, publicKey: publicKey) }
  public func sign(_ message: Data) throws -> Data { try key.signature(for: message) }
  public var signer: MemberRequestSigner {
    let key = key
    return MemberRequestSigner(deviceID: deviceID) { try key.signature(for: $0) }
  }
  public static func verify(publicKey: Data, signature: Data, message: Data) -> Bool {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
    return key.isValidSignature(signature, for: message)
  }

  /// The Linux identity file: 0600, the raw 32-byte private key in base64,
  /// created once. `deviceID` is the library's replica identity.
  public static func loadOrCreate(file: URL, deviceID: String, kind: MemberKind) throws -> MemberIdentity {
    let manager = FileManager.default
    if !manager.fileExists(atPath: file.path) {
      try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let staging = file.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).key")
      let raw = Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString()
      guard manager.createFile(atPath: staging.path, contents: Data((raw + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
        throw CompanionAPIError(code: "identity_unavailable", message: "This machine's member key could not be written.")
      }
      // Never replace an existing key: another process may have created it.
      if (try? manager.linkItem(at: staging, to: file)) == nil, !manager.fileExists(atPath: file.path) {
        try? manager.removeItem(at: staging)
        throw CompanionAPIError(code: "identity_unavailable", message: "This machine's member key could not be written.")
      }
      try? manager.removeItem(at: staging)
    }
    let attributes = try manager.attributesOfItem(atPath: file.path)
    guard (attributes[.type] as? FileAttributeType) == .typeRegular,
          ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
      throw CompanionAPIError(code: "identity_unavailable", message: "\(file.path) must be a regular file private to this user.")
    }
    let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), raw.count == 32 else {
      throw CompanionAPIError(code: "identity_unavailable", message: "This machine's member key is unreadable.")
    }
    return .init(deviceID: deviceID, kind: kind, key: try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
  }
}

extension WorkspaceDatabaseConnection {
  /// Member tables. Entries and revocations are shared rows (see
  /// `PairedLibraryTables`); anchors stay on this device.
  func migrateLibraryMembers() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS library_members(device_id TEXT NOT NULL, added_by TEXT NOT NULL, added_at INTEGER NOT NULL,
        payload TEXT NOT NULL, PRIMARY KEY(device_id, added_by));
      CREATE TABLE IF NOT EXISTS library_member_revocations(event_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS library_member_anchors(device_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS library_member_pin_candidates(device_id TEXT PRIMARY KEY, payload TEXT NOT NULL, first_seen INTEGER NOT NULL);
      """)
  }

  fileprivate static func memberJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  fileprivate func memberPayloads<T: Decodable>(_ sql: String, as type: T.Type) throws -> [T] {
    try historyRowsUnlocked(sql, values: []).compactMap { row in
      row.objectValue?["payload"]?.stringValue.flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
  }
  func memberRecordsUnlocked() throws -> (entries: [LibraryMemberEntry], revocations: [LibraryMemberRevocation], anchors: [LibraryMemberAnchor]) {
    (try memberPayloads("SELECT payload FROM library_members ORDER BY device_id,added_by", as: LibraryMemberEntry.self),
     try memberPayloads("SELECT payload FROM library_member_revocations ORDER BY event_id", as: LibraryMemberRevocation.self),
     try memberPayloads("SELECT payload FROM library_member_anchors ORDER BY device_id", as: LibraryMemberAnchor.self))
  }
}

extension WorkspaceDatabase {
  public func libraryMemberRecords() async throws -> (entries: [LibraryMemberEntry], revocations: [LibraryMemberRevocation], anchors: [LibraryMemberAnchor]) {
    try await read { try $0.memberRecordsUnlocked() }
  }
  /// `own` is this device's member ID: its anchor is removed only by itself.
  public func libraryMembers(own: String? = nil, now: Int64 = MemberRequestSignature.now()) async throws -> LibraryMemberList {
    let records = try await libraryMemberRecords()
    let members = LibraryMemberResolver.resolve(entries: records.entries, revocations: records.revocations, anchors: records.anchors,
                                                own: own, now: now)
    let revision = SHA256.hash(data: Data(try WorkspaceDatabaseConnection.memberJSON(members).utf8)).hexString
    let adopted = records.anchors.contains { $0.kind == .mac && $0.deviceID != own?.lowercased() }
    return .init(members: members, revision: String(revision.prefix(32)), adopted: adopted)
  }
  /// Keeps the newest entry per (device, adder). An older copy never replaces
  /// a newer one, so retries and relays are harmless.
  public func saveLibraryMemberEntries(_ entries: [LibraryMemberEntry]) async throws {
    let rows = try entries.filter(\.isWellFormed).map { ($0, try WorkspaceDatabaseConnection.memberJSON($0)) }
    try await write { connection in
      try connection.transaction {
        for (entry, payload) in rows {
          try connection.toolsExecuteUnlocked("""
            INSERT INTO library_members VALUES(?,?,?,?) ON CONFLICT(device_id,added_by) DO UPDATE SET
              added_at=excluded.added_at,payload=excluded.payload WHERE excluded.added_at>library_members.added_at
            """, [entry.deviceID, entry.addedBy, String(entry.addedAt), payload])
        }
      }
    }
  }
  public func saveLibraryMemberRevocations(_ revocations: [LibraryMemberRevocation]) async throws {
    let rows = try revocations.filter(\.isWellFormed).map { ($0, try WorkspaceDatabaseConnection.memberJSON($0)) }
    try await write { connection in
      try connection.transaction {
        for (revocation, payload) in rows {
          try connection.toolsExecuteUnlocked("INSERT OR IGNORE INTO library_member_revocations VALUES(?,?,?)",
                                              [revocation.eventID, revocation.deviceID, payload])
        }
      }
    }
  }
  /// Macs trusted but not yet pinned, with the time each was first trusted
  /// with its current key (local, unsynced).
  public func libraryMemberPinCandidates() async throws -> [String: (anchor: LibraryMemberAnchor, firstSeen: Int64)] {
    try await read { connection in
      var result: [String: (anchor: LibraryMemberAnchor, firstSeen: Int64)] = [:]
      for row in try connection.historyRowsUnlocked("SELECT payload,first_seen FROM library_member_pin_candidates", values: []) {
        guard let fields = row.objectValue, let payload = fields["payload"]?.stringValue,
              let anchor = try? JSONDecoder().decode(LibraryMemberAnchor.self, from: Data(payload.utf8)) else { continue }
        result[anchor.deviceID] = (anchor, Int64(fields["first_seen"]?.intValue ?? 0))
      }
      return result
    }
  }
  public func updateLibraryMemberPinCandidates(saving: [(anchor: LibraryMemberAnchor, firstSeen: Int64)], removing: [String]) async throws {
    let rows = try saving.map { ($0.anchor.deviceID, try WorkspaceDatabaseConnection.memberJSON($0.anchor), String($0.firstSeen)) }
    try await write { connection in
      try connection.transaction {
        for id in removing { try connection.toolsExecuteUnlocked("DELETE FROM library_member_pin_candidates WHERE device_id=?", [id]) }
        for (id, payload, time) in rows {
          try connection.toolsExecuteUnlocked("INSERT INTO library_member_pin_candidates VALUES(?,?,?) ON CONFLICT(device_id) DO UPDATE SET payload=excluded.payload,first_seen=excluded.first_seen", [id, payload, time])
        }
      }
    }
  }
  /// Pins an anchor. An existing anchor's key is never replaced, except this
  /// device's own (`replacing`), whose key is its identity.
  public func saveLibraryMemberAnchor(_ anchor: LibraryMemberAnchor, replacing: Bool = false) async throws {
    let payload = try WorkspaceDatabaseConnection.memberJSON(anchor)
    try await write { try $0.toolsExecuteUnlocked(replacing
      ? "INSERT INTO library_member_anchors VALUES(?,?) ON CONFLICT(device_id) DO UPDATE SET payload=excluded.payload"
      : "INSERT OR IGNORE INTO library_member_anchors VALUES(?,?)", [anchor.deviceID, payload]) }
  }
}

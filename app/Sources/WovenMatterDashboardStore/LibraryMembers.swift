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

/// A signed removal. Applied everywhere as soon as it synchronizes. Re-adding
/// the device later takes a newer entry from a member Mac.
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

/// A local trust root: this device itself, and on a Linux host the Mac that
/// added it. Anchors are local state and never synchronize.
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
  /// Trust flows only from anchors through entries signed by trusted Macs.
  /// - A device's kind comes from an anchor or a Mac-signed entry; its own
  ///   later entry may change only its name and endpoints.
  /// - A device that two trusted entries give different keys is not trusted.
  /// - Removing a Mac does not remove the devices it added before removal.
  ///   Entries it signed at or after its own removal time are ignored.
  /// - A revocation counts when a trusted, unremoved Mac (or the device
  ///   itself) signed it. A later entry from an unremoved Mac re-adds.
  public static func resolve(entries rawEntries: [LibraryMemberEntry], revocations rawRevocations: [LibraryMemberRevocation],
                             anchors: [LibraryMemberAnchor]) -> [LibraryMember] {
    let entries = rawEntries.filter(\.isWellFormed)
    let revocations = rawRevocations.filter(\.isWellFormed)
    struct Trust { var key: Data; var kind: MemberKind; var anchor: Bool }
    var trusted: [String: Trust] = [:], conflicted = Set<String>()
    for anchor in anchors where anchor.publicKey.count == 32 { trusted[anchor.deviceID] = .init(key: anchor.publicKey, kind: anchor.kind, anchor: true) }
    var vouched: [String: [LibraryMemberEntry]] = [:]
    var changed = true
    while changed {
      changed = false
      for entry in entries where entry.addedBy != entry.deviceID && !conflicted.contains(entry.deviceID) {
        guard let adder = trusted[entry.addedBy], adder.kind == .mac, !conflicted.contains(entry.addedBy),
              entry.verifies(with: adder.key) else { continue }
        if !(vouched[entry.deviceID]?.contains(entry) ?? false) { vouched[entry.deviceID, default: []].append(entry) }
        if let current = trusted[entry.deviceID] {
          if current.key != entry.publicKey && !current.anchor { conflicted.insert(entry.deviceID); trusted.removeValue(forKey: entry.deviceID); changed = true }
          continue
        }
        trusted[entry.deviceID] = .init(key: entry.publicKey, kind: entry.kind, anchor: false); changed = true
      }
    }
    // Earliest Mac-signed entry fixes the kind; a phone cannot promote itself.
    for (device, list) in vouched where trusted[device]?.anchor == false {
      if let first = list.filter({ $0.publicKey == trusted[device]?.key }).min(by: { ($0.addedAt, $0.addedBy) < ($1.addedAt, $1.addedBy) }) {
        trusted[device]?.kind = first.kind
      }
    }
    // Removal times, settled to a fixpoint because an unremoved re-adder and a
    // removed revoker each depend on removals.
    func validRevocations(removedAt: [String: Int64]) -> [String: Int64] {
      var latest: [String: Int64] = [:]
      for revocation in revocations {
        guard let revoker = trusted[revocation.revokedBy], revoker.kind == .mac || revocation.revokedBy == revocation.deviceID,
              MemberIdentity.verify(publicKey: revoker.key, signature: revocation.signature, message: revocation.statement) else { continue }
        if let revokerRemoved = removedAt[revocation.revokedBy], revocation.revokedBy != revocation.deviceID,
           revocation.revokedAt >= revokerRemoved { continue }
        latest[revocation.deviceID] = max(latest[revocation.deviceID] ?? 0, revocation.revokedAt)
      }
      return latest
    }
    var removedAt: [String: Int64] = [:]
    for _ in 0..<8 {
      var next: [String: Int64] = [:]
      for (device, time) in validRevocations(removedAt: removedAt) {
        let readded = (vouched[device] ?? []).contains { entry in
          entry.addedAt > time && entry.publicKey == trusted[device]?.key
            && (removedAt[entry.addedBy].map { entry.addedAt < $0 } ?? true)
        }
        if !readded { next[device] = time }
      }
      if next == removedAt { break }
      removedAt = next
    }
    return trusted.keys.sorted().compactMap { device in
      guard let trust = trusted[device] else { return nil }
      // A removed Mac's entries from its removal on are void.
      if !trust.anchor, !(vouched[device] ?? []).contains(where: { entry in
        entry.publicKey == trust.key && (removedAt[entry.addedBy].map { entry.addedAt < $0 } ?? true)
      }) { return nil }
      // Name and endpoints: the newest entry with the trusted key, from a
      // trusted Mac or the device itself.
      let candidates = entries.filter { entry in
        entry.deviceID == device && entry.publicKey == trust.key
          && (entry.addedBy == device ? entry.verifies(with: trust.key)
              : (vouched[device]?.contains(entry) ?? false))
      }
      let newest = candidates.max { ($0.addedAt, $0.addedBy) < ($1.addedAt, $1.addedBy) }
      let adder = vouched[device]?.filter { $0.publicKey == trust.key }.min { ($0.addedAt, $0.addedBy) < ($1.addedAt, $1.addedBy) }?.addedBy
      return LibraryMember(deviceID: device, kind: trust.kind, name: newest?.name ?? "Device", publicKey: trust.key,
        endpoints: newest?.endpoints ?? [], addedBy: adder ?? device, revoked: removedAt[device] != nil)
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
  public func libraryMembers() async throws -> LibraryMemberList {
    let records = try await libraryMemberRecords()
    let members = LibraryMemberResolver.resolve(entries: records.entries, revocations: records.revocations, anchors: records.anchors)
    let revision = SHA256.hash(data: Data(try WorkspaceDatabaseConnection.memberJSON(members).utf8)).hexString
    return .init(members: members, revision: String(revision.prefix(32)))
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
  public func saveLibraryMemberAnchor(_ anchor: LibraryMemberAnchor) async throws {
    let payload = try WorkspaceDatabaseConnection.memberJSON(anchor)
    try await write { try $0.toolsExecuteUnlocked("INSERT INTO library_member_anchors VALUES(?,?) ON CONFLICT(device_id) DO UPDATE SET payload=excluded.payload", [anchor.deviceID, payload]) }
  }
  /// Pairing state may be reset on upgrade; membership is never reset here.
  public func removeLibraryMemberAnchor(_ deviceID: String) async throws {
    try await write { try $0.toolsExecuteUnlocked("DELETE FROM library_member_anchors WHERE device_id=?", [deviceID.lowercased()]) }
  }
}

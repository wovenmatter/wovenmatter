#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import WovenMatterClient
import WovenMatterCore

/// Settings → GitHub on every Mac (docs/architecture/GITHUB_IDENTITY.md). Two
/// paired-library tables carry it:
///
/// - `github_identity_recipients`: each Mac's and Linux host's X25519 sealing
///   key, signed with its member key. The private half stays on that machine
///   (Keychain on a Mac, the library host's secret store on Linux).
/// - `github_identity`: one row with the identity, the public key, the access
///   list, and the private key sealed to each recipient, signed by the Mac that
///   wrote it.
///
/// Every Mac and Linux host stores the key; phones relay only ciphertext. The
/// access list decides only where agents may use it, through that machine's
/// signing agent. A Mac opens its own sealed copy, keeps it in Keychain and
/// seals copies for machines that join later; a Linux host opens its copy for
/// its Woven server (`hostCopy`). Records are trusted only when a current Mac
/// member signed them.
public struct GitHubSharedIdentity: Codable, Equatable, Sendable {
  public struct Sealed: Codable, Equatable, Sendable {
    public var device: String
    /// Base64: the recipient's sealing key this copy was made for.
    public var recipient: String
    /// Base64: the sender's one-time X25519 public key.
    public var ephemeral: String
    /// Base64: ChaChaPoly combined box of the `GitHubSSHKey` JSON.
    public var box: String
  }
  /// A key earlier records carry inside their signature (`"version"`).
  /// Nothing reads it and no record signed now has it; it is kept only so a
  /// stored record re-encodes to the bytes that were signed.
  var earlierSignedKey: Int?
  public var revision: Int64
  public var author: String
  public var identity: GitHubGitIdentity
  public var key: GitHubPublicKey?
  /// Which places get the key (absent: everywhere).
  public var access: GitHubAccess?
  public var sealed: [Sealed]
  public var signature: String?

  enum CodingKeys: String, CodingKey {
    case earlierSignedKey = "version"
    case revision, author, identity, key, access, sealed, signature
  }

  static let domain = "woven.github.identity.v1"

  var statement: Data {
    var unsigned = self
    unsigned.signature = nil
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return Data(Self.domain.utf8) + Data([0]) + ((try? encoder.encode(unsigned)) ?? Data())
  }

  func verifies(publicKey: Data) -> Bool {
    guard let signature, let bytes = Data(base64Encoded: signature) else { return false }
    return MemberIdentity.verify(publicKey: publicKey, signature: bytes, message: statement)
  }
}

public struct GitHubIdentityRecipient: Codable, Equatable, Sendable {
  public var device: String
  /// Base64 X25519 public key.
  public var key: String
  public var signature: String

  static func statement(device: String, key: String) -> Data {
    canonical([("device", device), ("key", key)], domain: "woven.github.recipient.v1")
  }
  func verifies(publicKey: Data) -> Bool {
    guard let bytes = Data(base64Encoded: signature) else { return false }
    return MemberIdentity.verify(publicKey: publicKey, signature: bytes, message: Self.statement(device: device, key: key))
  }
}

extension WorkspaceDatabaseConnection {
  /// Declared for every library, new or existing: an existing one gains the
  /// tables at its next open (`migrateGitHubIdentity`).
  static let gitHubIdentityTablesSQL = """
    CREATE TABLE IF NOT EXISTS github_identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1), payload TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS github_identity_recipients(device_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
    """

  func migrateGitHubIdentity() throws {
    try withLock { try executeUnlocked(Self.gitHubIdentityTablesSQL) }
  }
}

extension WorkspaceDatabase {
  public func gitHubSharedIdentity() async throws -> GitHubSharedIdentity? {
    try await read { connection in
      try connection.withLock {
        try connection.historyRowsUnlocked("SELECT payload FROM github_identity WHERE singleton=1", values: [])
          .first?.objectValue?["payload"]?.stringValue
      }
    }.flatMap { try? JSONDecoder().decode(GitHubSharedIdentity.self, from: Data($0.utf8)) }
  }

  public func setGitHubSharedIdentity(_ value: GitHubSharedIdentity) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = String(decoding: try encoder.encode(value), as: UTF8.self)
    try await write { connection in
      try connection.withLock {
        try connection.toolsExecuteUnlocked("""
          INSERT INTO github_identity(singleton,payload) VALUES(1,?)
          ON CONFLICT(singleton) DO UPDATE SET payload=excluded.payload WHERE payload IS NOT excluded.payload
          """, [payload])
      }
    }
  }

  public func gitHubIdentityRecipients() async throws -> [GitHubIdentityRecipient] {
    try await read { connection in
      try connection.withLock {
        try connection.historyRowsUnlocked("SELECT device_id,payload FROM github_identity_recipients ORDER BY device_id", values: [])
          .compactMap { row -> (String, String)? in
            guard let device = row.objectValue?["device_id"]?.stringValue, let payload = row.objectValue?["payload"]?.stringValue else { return nil }
            return (device, payload)
          }
      }
    }.compactMap { device, payload in
      // A row counts only under the device its signed payload names.
      (try? JSONDecoder().decode(GitHubIdentityRecipient.self, from: Data(payload.utf8))).flatMap { $0.device == device ? $0 : nil }
    }
  }

  public func setGitHubIdentityRecipient(_ value: GitHubIdentityRecipient) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = String(decoding: try encoder.encode(value), as: UTF8.self)
    try await write { connection in
      try connection.withLock {
        try connection.toolsExecuteUnlocked("""
          INSERT INTO github_identity_recipients(device_id,payload) VALUES(?,?)
          ON CONFLICT(device_id) DO UPDATE SET payload=excluded.payload WHERE payload IS NOT excluded.payload
          """, [value.device, payload])
      }
    }
  }
}

/// Keeps this Mac's Keychain copy and the shared record in step.
public actor GitHubIdentitySync {
  /// This Mac's own storage; tests substitute memory.
  public struct Storage: Sendable {
    public var load: @Sendable () throws -> GitHubConfiguration?
    public var save: @Sendable (GitHubConfiguration) throws -> Void
    /// This Mac's X25519 sealing key, created once.
    public var sealingKey: @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey
    public init(load: @escaping @Sendable () throws -> GitHubConfiguration?,
                save: @escaping @Sendable (GitHubConfiguration) throws -> Void,
                sealingKey: @escaping @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey) {
      self.load = load; self.save = save; self.sealingKey = sealingKey
    }

    public static let keychain = Storage(
      load: { try GitHubConfigurationStore.load() },
      save: { try GitHubConfigurationStore.save($0) },
      sealingKey: {
        if let text = try DefaultAgentSupport.key("github-sealing"), let raw = Data(base64Encoded: text),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) { return key }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try DefaultAgentSupport.saveKey(key.rawRepresentation.base64EncodedString(), provider: "github-sealing", notify: false)
        return key
      })
  }

  let database: WorkspaceDatabase
  let directory: MemberDirectory
  let storage: Storage
  let clock: @Sendable () -> Int64

  public init(database: WorkspaceDatabase, directory: MemberDirectory, storage: Storage = .keychain,
              clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
    self.database = database; self.directory = directory; self.storage = storage; self.clock = clock
  }

  private var own: String { directory.identity.deviceID }

  /// One change or reconcile at a time: each reads Keychain, then writes it after awaiting.
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private func acquire() async {
    if locked { await withCheckedContinuation { waiters.append($0) } } else { locked = true }
  }
  private func release() {
    if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
  }

  /// This Mac's copy; one Keychain cannot decode (corrupt, or from a newer build) counts as
  /// none, so Settings can replace it. Keychain errors still throw.
  private func loadLocal() throws -> GitHubConfiguration? {
    do { return try storage.load() } catch is GitHubIdentityError { return nil }
  }

  /// The user changed the setting on this Mac: save it, then share it. `replacesKey` is a new
  /// key or a removal: the user's choice, which goes ahead whatever this Mac holds.
  @discardableResult
  public func change(replacesKey: Bool = false, _ update: (inout GitHubConfiguration) throws -> Void) async throws -> GitHubConfiguration {
    await acquire()
    defer { release() }
    try await publishSealingKey()
    var before = try loadLocal() ?? .init()
    let shared = try await verifiedShared()
    // Catch up first: a change on top of an older copy would put back what another Mac changed
    // since (a removed key, a place turned off).
    let behind = shared.map { $0.revision > before.revision } ?? false
    if let shared, behind { before = try caughtUp(before, shared).value }
    var value = before
    try update(&value)
    // Only a Mac that was behind and still has no copy of the record's key takes this path; a
    // Mac whose own key is newer (not shared yet) shares it below.
    if !replacesKey, behind, let shared, let current = shared.key, before.key?.fingerprint != current.fingerprint {
      // This Mac doesn't hold the current key yet (no copy sealed to it): change the list or the
      // identity in the record, keeping every sealed copy. Its own copy keeps its older revision,
      // so the key is adopted once a copy reaches it.
      var record = shared
      record.identity = value.identity
      record.access = value.access
      record.revision = max(clock(), shared.revision + 1)
      record.author = own
      try await write(record)
      try storage.save(value)
      lastSeen = nil
      return value
    }
    value.revision = max(clock(), max(value.revision, shared?.revision ?? 0) + 1)
    try storage.save(value)
    try await share(value)
    lastSeen = nil
    return value
  }

  /// This Mac's copy brought up to a newer record. Without a copy sealed to this Mac it still
  /// takes the record's identity and list; it keeps its key when the record has the same one
  /// (complete: only this Mac's copy is missing), and otherwise drops it and keeps its older
  /// revision, so the newer key is adopted once a copy arrives.
  private func caughtUp(_ local: GitHubConfiguration?, _ shared: GitHubSharedIdentity) throws -> (value: GitHubConfiguration, complete: Bool) {
    if let opened = try open(shared) { return (opened, true) }
    var value = local ?? .init()
    value.identity = (try? shared.identity.validated()) ?? .init()
    value.access = shared.access ?? .init()
    if let key = value.key, key.fingerprint == shared.key?.fingerprint {
      value.revision = shared.revision
      return (value, true)
    }
    value.key = nil
    return (value, false)
  }

  /// After sync or at launch. Returns true when this Mac's copy changed.
  @discardableResult
  public func reconcile() async throws -> Bool {
    await acquire()
    defer { release() }
    // Peer sync calls this after every batch it applies; skip when neither record moved.
    if try await observed() == lastSeen { return false }
    let changed = try await reconcileNow()
    lastSeen = try await observed()
    return changed
  }
  private var lastSeen: [String]?

  /// What reconciling depends on: both records and which Macs and Linux hosts are current members.
  private func observed() async throws -> [String] {
    var values = [try await database.gitHubSharedIdentity()?.signature ?? ""]
    values += try await database.gitHubIdentityRecipients().map(\.signature)
    values += ((try? await directory.list())?.members ?? []).filter { ($0.kind == .mac || $0.kind == .linux) && !$0.revoked }.map(\.deviceID).sorted()
    return values
  }

  private func reconcileNow() async throws -> Bool {
    try await publishSealingKey()
    let local = try loadLocal()
    let shared = try await verifiedShared()
    if let shared, shared.revision > (local?.revision ?? 0) {
      let (adopted, complete) = try caughtUp(local, shared)
      if complete, adopted.key != nil { try await addMissingCopies(adopted, shared: shared) }
      guard adopted != local else { return false }
      try storage.save(adopted)
      return true
    }
    guard let local else { return false }
    if local.revision > (shared?.revision ?? 0) {
      try await share(local)
    } else if let shared, shared.revision == local.revision, local.key != nil {
      try await addMissingCopies(local, shared: shared)
    }
    return false
  }

  /// Another Mac changed the key and no copy is sealed to this Mac yet.
  public func waitingForCopy() async -> Bool {
    guard let shared = try? await verifiedShared(), shared.key != nil else { return false }
    return shared.revision > ((try? loadLocal())?.revision ?? 0)
  }

  /// A Linux host's copy for its Woven server: it publishes its sealing key, then opens the
  /// current record. Nil until a Mac has written one; without a key while no copy is sealed to
  /// this host yet (the next Mac online seals one).
  public func hostCopy() async throws -> GitHubConfiguration? {
    await acquire()
    defer { release() }
    try await publishSealingKey()
    guard let shared = try await verifiedShared() else { return nil }
    if let opened = try open(shared) { return opened }
    return GitHubConfiguration(identity: (try? shared.identity.validated()) ?? .init(), revision: shared.revision, access: shared.access ?? .init())
  }

  /// This Mac's device ID, the place Settings → GitHub lists as This Mac.
  public var deviceID: String { own }

  // MARK: Records

  private func publishSealingKey() async throws {
    let key = try storage.sealingKey().publicKey.rawRepresentation.base64EncodedString()
    let current = try await database.gitHubIdentityRecipients().first { $0.device == own }
    if current?.key == key, current?.verifies(publicKey: directory.identity.publicKey) == true { return }
    let signature = try directory.identity.sign(GitHubIdentityRecipient.statement(device: own, key: key))
    try await database.setGitHubIdentityRecipient(.init(device: own, key: key, signature: signature.base64EncodedString()))
  }

  /// A machine that stores the key: a current Mac or Linux member (never a phone).
  private func recipientKey(_ device: String) async -> Data? {
    if device == own { return directory.identity.publicKey }
    guard let member = await directory.member(device), member.kind == .mac || member.kind == .linux, !member.revoked else { return nil }
    return member.publicKey
  }

  /// A record counts only when a current Mac member signed it.
  private func signerKey(_ device: String) async -> Data? {
    if device == own { return directory.identity.publicKey }
    guard let member = await directory.member(device), member.kind == .mac, !member.revoked else { return nil }
    return member.publicKey
  }

  private func verifiedShared() async throws -> GitHubSharedIdentity? {
    guard let shared = try await database.gitHubSharedIdentity(), let key = await signerKey(shared.author),
          shared.verifies(publicKey: key) else { return nil }
    return shared
  }

  /// Every Mac and Linux host whose sealing key that current member signed, this Mac included.
  private func recipients() async throws -> [(device: String, key: Curve25519.KeyAgreement.PublicKey)] {
    var result: [(String, Curve25519.KeyAgreement.PublicKey)] = []
    for recipient in try await database.gitHubIdentityRecipients() {
      guard let signer = await recipientKey(recipient.device), recipient.verifies(publicKey: signer),
            let raw = Data(base64Encoded: recipient.key),
            let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { continue }
      result.append((recipient.device, key))
    }
    return result
  }

  private func share(_ value: GitHubConfiguration) async throws {
    var record = GitHubSharedIdentity(revision: value.revision, author: own, identity: value.identity,
                                      key: value.key?.summary, access: value.access, sealed: [], signature: nil)
    if let key = value.key {
      for recipient in try await recipients() {
        record.sealed.append(try Self.seal(key, for: recipient.device, to: recipient.key))
      }
    }
    try await write(record)
  }

  private func addMissingCopies(_ value: GitHubConfiguration, shared: GitHubSharedIdentity) async throws {
    guard let key = value.key, shared.key?.fingerprint == key.fingerprint else { return }
    // A Mac whose sealing key changed (a new Keychain) needs a new copy too.
    let present = Set(shared.sealed.map { $0.device + " " + $0.recipient })
    let missing = try await recipients().filter { !present.contains($0.device + " " + $0.key.rawRepresentation.base64EncodedString()) }
    guard !missing.isEmpty else { return }
    var record = shared
    record.author = own
    record.sealed.removeAll { sealed in missing.contains { $0.device == sealed.device } }
    for recipient in missing {
      record.sealed.append(try Self.seal(key, for: recipient.device, to: recipient.key))
    }
    try await write(record)
  }

  private func write(_ record: GitHubSharedIdentity) async throws {
    var record = record
    record.sealed.sort { $0.device < $1.device }
    record.earlierSignedKey = nil
    record.signature = nil
    record.signature = try directory.identity.sign(record.statement).base64EncodedString()
    try await database.setGitHubSharedIdentity(record)
  }

  /// This Mac's copy of `shared`, or nil while no copy is sealed to it yet.
  private func open(_ shared: GitHubSharedIdentity) throws -> GitHubConfiguration? {
    // Checked again here: a record is signed by a Mac, not proof its fields are well formed.
    let identity = (try? shared.identity.validated()) ?? .init()
    let access = shared.access ?? .init()
    guard let summary = shared.key else { return .init(key: nil, identity: identity, revision: shared.revision, access: access) }
    let sealingKey = try storage.sealingKey()
    let mine = sealingKey.publicKey.rawRepresentation.base64EncodedString()
    guard let sealed = shared.sealed.first(where: { $0.device == own && $0.recipient == mine }) else { return nil }
    let key = try Self.open(sealed, with: sealingKey, fingerprint: summary.fingerprint)
    guard key.fingerprint == summary.fingerprint, key.authorizedKey == summary.publicKey else {
      throw GitHubIdentityError.message("The GitHub key shared by another Mac does not match its description.")
    }
    return .init(key: key, identity: identity, revision: shared.revision, access: access)
  }

  // MARK: Sealing

  /// Bound to the machine and the key's fingerprint, not the revision: a Mac without the key can
  /// still change the list or the identity and carry every sealed copy into the new record.
  static func info(device: String, fingerprint: String) -> Data {
    Data("woven.github.identity.v1|\(device)|\(fingerprint)".utf8)
  }

  static func seal(_ key: GitHubSSHKey, for device: String, to recipient: Curve25519.KeyAgreement.PublicKey) throws -> GitHubSharedIdentity.Sealed {
    let info = info(device: device, fingerprint: key.fingerprint)
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
    let salt = ephemeral.publicKey.rawRepresentation + recipient.rawRepresentation
    let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                    sharedInfo: info, outputByteCount: 32)
    let box = try ChaChaPoly.seal(JSONEncoder().encode(key), using: symmetric, authenticating: info)
    return .init(device: device, recipient: recipient.rawRepresentation.base64EncodedString(),
                 ephemeral: ephemeral.publicKey.rawRepresentation.base64EncodedString(), box: box.combined.base64EncodedString())
  }

  static func open(_ sealed: GitHubSharedIdentity.Sealed, with key: Curve25519.KeyAgreement.PrivateKey,
                   fingerprint: String) throws -> GitHubSSHKey {
    let info = info(device: sealed.device, fingerprint: fingerprint)
    guard let raw = Data(base64Encoded: sealed.ephemeral), let combined = Data(base64Encoded: sealed.box),
          let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
      throw GitHubIdentityError.message("The GitHub key shared by another Mac could not be read.")
    }
    let secret = try key.sharedSecretFromKeyAgreement(with: ephemeral)
    let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: raw + key.publicKey.rawRepresentation,
                                                    sharedInfo: info, outputByteCount: 32)
    do {
      let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: symmetric,
                                      authenticating: info)
      return try JSONDecoder().decode(GitHubSSHKey.self, from: plain)
    } catch {
      throw GitHubIdentityError.message("The GitHub key shared by another Mac could not be opened on this Mac.")
    }
  }
}

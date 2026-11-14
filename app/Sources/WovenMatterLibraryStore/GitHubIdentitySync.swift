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
/// - `github_identity_recipients`: each Mac's X25519 sealing key, signed with
///   its member key. The private half stays in that Mac's Keychain.
/// - `github_identity`: one row with the identity, the public key, and the
///   private key sealed to each recipient Mac, signed by the Mac that wrote it.
///
/// Library copies on Linux hosts and phones hold only ciphertext. A Mac opens
/// its own sealed copy, keeps it in Keychain and seals copies for Macs that
/// join later. Records are trusted only when a current Mac member signed them.
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
  /// Record format; a Mac leaves records from a newer format alone. Absent means 1.
  public var version: Int?
  public var revision: Int64
  public var author: String
  public var identity: GitHubGitIdentity
  public var key: GitHubPublicKey?
  public var sealed: [Sealed]
  public var signature: String?

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
  /// A new library's declaration; schema step 2 makes the same change to a v0.4.3 library.
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

  static let format = 1

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

  /// The user changed the setting on this Mac: save it, then share it.
  @discardableResult
  public func change(_ update: (inout GitHubConfiguration) throws -> Void) async throws -> GitHubConfiguration {
    await acquire()
    defer { release() }
    if let raw = try await database.gitHubSharedIdentity(), (raw.version ?? 1) > Self.format {
      throw GitHubIdentityError.message("Another Mac uses a newer Woven Matter. Update this Mac to change GitHub settings.")
    }
    try await publishSealingKey()
    let before = try loadLocal() ?? .init()
    var value = before
    try update(&value)
    let shared = try await verifiedShared()
    // Keeping this Mac's older key while another Mac's newer one is on its way would replace it
    // everywhere. A new key or a removal is the user's choice and goes ahead.
    if let shared, shared.key != nil, shared.revision > before.revision, value.key == before.key {
      throw GitHubIdentityError.message("Another Mac changed the GitHub key. Wait until it reaches this Mac (when that Mac is online), then try again.")
    }
    value.revision = max(clock(), max(value.revision, shared?.revision ?? 0) + 1)
    try storage.save(value)
    try await share(value)
    lastSeen = nil
    return value
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

  /// What reconciling depends on: both records and which Macs are current members.
  private func observed() async throws -> [String] {
    var values = [try await database.gitHubSharedIdentity()?.signature ?? ""]
    values += try await database.gitHubIdentityRecipients().map(\.signature)
    values += ((try? await directory.list())?.members ?? []).filter { $0.kind == .mac && !$0.revoked }.map(\.deviceID).sorted()
    return values
  }

  private func reconcileNow() async throws -> Bool {
    try await publishSealingKey()
    // A record in a newer format is left alone until this Mac is updated.
    if let raw = try await database.gitHubSharedIdentity(), (raw.version ?? 1) > Self.format { return false }
    let local = try loadLocal()
    let shared = try await verifiedShared()
    if let shared, shared.revision > (local?.revision ?? 0) {
      guard let adopted = try open(shared) else { return false }
      try storage.save(adopted)
      if adopted.key != nil { try await addMissingCopies(adopted, shared: shared) }
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

  // MARK: Records

  private func publishSealingKey() async throws {
    let key = try storage.sealingKey().publicKey.rawRepresentation.base64EncodedString()
    let current = try await database.gitHubIdentityRecipients().first { $0.device == own }
    if current?.key == key, current?.verifies(publicKey: directory.identity.publicKey) == true { return }
    let signature = try directory.identity.sign(GitHubIdentityRecipient.statement(device: own, key: key))
    try await database.setGitHubIdentityRecipient(.init(device: own, key: key, signature: signature.base64EncodedString()))
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

  /// Macs whose sealing key a current Mac member signed, this Mac included.
  private func recipients() async throws -> [(device: String, key: Curve25519.KeyAgreement.PublicKey)] {
    var result: [(String, Curve25519.KeyAgreement.PublicKey)] = []
    for recipient in try await database.gitHubIdentityRecipients() {
      guard let signer = await signerKey(recipient.device), recipient.verifies(publicKey: signer),
            let raw = Data(base64Encoded: recipient.key),
            let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { continue }
      result.append((recipient.device, key))
    }
    return result
  }

  private func share(_ value: GitHubConfiguration) async throws {
    var record = GitHubSharedIdentity(version: Self.format, revision: value.revision, author: own, identity: value.identity,
                                      key: value.key?.summary, sealed: [], signature: nil)
    if let key = value.key {
      for recipient in try await recipients() {
        record.sealed.append(try Self.seal(key, for: recipient.device, to: recipient.key, revision: value.revision))
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
      record.sealed.append(try Self.seal(key, for: recipient.device, to: recipient.key, revision: value.revision))
    }
    try await write(record)
  }

  private func write(_ record: GitHubSharedIdentity) async throws {
    var record = record
    record.sealed.sort { $0.device < $1.device }
    record.signature = nil
    record.signature = try directory.identity.sign(record.statement).base64EncodedString()
    try await database.setGitHubSharedIdentity(record)
  }

  /// This Mac's copy of `shared`, or nil while no copy is sealed to it yet.
  private func open(_ shared: GitHubSharedIdentity) throws -> GitHubConfiguration? {
    // Checked again here: a record is signed by a Mac, not proof its fields are well formed.
    let identity = (try? shared.identity.validated()) ?? .init()
    guard let summary = shared.key else { return .init(key: nil, identity: identity, revision: shared.revision) }
    let sealingKey = try storage.sealingKey()
    let mine = sealingKey.publicKey.rawRepresentation.base64EncodedString()
    guard let sealed = shared.sealed.first(where: { $0.device == own && $0.recipient == mine }) else { return nil }
    let key = try Self.open(sealed, with: sealingKey, revision: shared.revision)
    guard key.fingerprint == summary.fingerprint, key.authorizedKey == summary.publicKey else {
      throw GitHubIdentityError.message("The GitHub key shared by another Mac does not match its description.")
    }
    return .init(key: key, identity: identity, revision: shared.revision)
  }

  // MARK: Sealing

  static func info(device: String, revision: Int64) -> Data {
    Data("woven.github.identity.v1|\(device)|\(revision)".utf8)
  }

  static func seal(_ key: GitHubSSHKey, for device: String, to recipient: Curve25519.KeyAgreement.PublicKey,
                   revision: Int64) throws -> GitHubSharedIdentity.Sealed {
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
    let salt = ephemeral.publicKey.rawRepresentation + recipient.rawRepresentation
    let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                    sharedInfo: info(device: device, revision: revision), outputByteCount: 32)
    let box = try ChaChaPoly.seal(JSONEncoder().encode(key), using: symmetric, authenticating: info(device: device, revision: revision))
    return .init(device: device, recipient: recipient.rawRepresentation.base64EncodedString(),
                 ephemeral: ephemeral.publicKey.rawRepresentation.base64EncodedString(), box: box.combined.base64EncodedString())
  }

  static func open(_ sealed: GitHubSharedIdentity.Sealed, with key: Curve25519.KeyAgreement.PrivateKey,
                   revision: Int64) throws -> GitHubSSHKey {
    guard let raw = Data(base64Encoded: sealed.ephemeral), let combined = Data(base64Encoded: sealed.box),
          let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
      throw GitHubIdentityError.message("The GitHub key shared by another Mac could not be read.")
    }
    let secret = try key.sharedSecretFromKeyAgreement(with: ephemeral)
    let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: raw + key.publicKey.rawRepresentation,
                                                    sharedInfo: info(device: sealed.device, revision: revision), outputByteCount: 32)
    do {
      let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: symmetric,
                                      authenticating: info(device: sealed.device, revision: revision))
      return try JSONDecoder().decode(GitHubSSHKey.self, from: plain)
    } catch {
      throw GitHubIdentityError.message("The GitHub key shared by another Mac could not be opened on this Mac.")
    }
  }
}

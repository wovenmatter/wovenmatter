import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Testing
import WorkspaceFixtures
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore

/// One Mac's Keychain, in memory.
final class MemoryGitHubStore: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: GitHubConfiguration?
  private var sealing = Curve25519.KeyAgreement.PrivateKey()
  /// Keychain holds an item this build cannot decode.
  var unreadable = false
  var value: GitHubConfiguration? { lock.withLock { stored } }
  /// A reinstalled Mac: an empty Keychain, so a new sealing key.
  func wipe() { lock.withLock { stored = nil; sealing = .init() } }
  var storage: GitHubIdentitySync.Storage {
    .init(load: { [self] in
            try lock.withLock {
              if unreadable { throw GitHubIdentityError.message("The saved GitHub settings could not be read.") }
              return stored
            }
          },
          save: { [self] value in lock.withLock { stored = value; unreadable = false } },
          sealingKey: { [self] in lock.withLock { sealing } })
  }
}

private struct Device {
  let persistence: PersistenceFixture
  let database: WorkspaceDatabase
  let identity: MemberIdentity
  let directory: MemberDirectory
  let store = MemoryGitHubStore()
  var id: String { identity.deviceID }
  var sync: GitHubIdentitySync { .init(database: database, directory: directory, storage: store.storage) }

  init(_ kind: MemberKind) async throws {
    persistence = try PersistenceFixture()
    database = try await persistence.openDatabase()
    identity = MemberIdentity(deviceID: try await database.libraryIdentity().hostDeviceID, kind: kind, key: Curve25519.Signing.PrivateKey())
    directory = MemberDirectory(database: database, identity: identity, cacheLifetime: 0)
    try await directory.ensureSelf(name: kind.rawValue, endpoints: [URL(string: "https://\(UUID().uuidString.lowercased()).ts.net/wovenmatter")!])
  }

  func add(_ other: Device) async throws {
    try await directory.add(deviceID: other.id, kind: other.identity.kind, name: other.identity.kind.rawValue,
                            publicKey: other.identity.publicKey, endpoints: [URL(string: "https://\(other.id).ts.net/wovenmatter")!])
  }
}

/// Copies the two GitHub rows from one library to another, as peer sync would.
private func copyRecords(from source: Device, to destination: Device) async throws {
  for recipient in try await source.database.gitHubIdentityRecipients() { try await destination.database.setGitHubIdentityRecipient(recipient) }
  if let shared = try await source.database.gitHubSharedIdentity() { try await destination.database.setGitHubSharedIdentity(shared) }
}

let gitHubFixtureKey = GitHubSSHKey(
  privateKey: GitHubSSHKeys.openSSHHeader + "\nfixture-private-material\n" + GitHubSSHKeys.openSSHFooter + "\n",
  publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFix",
  fingerprint: "SHA256:fixture", comment: "woven-matter")

@Suite("Settings → GitHub across Macs")
struct GitHubIdentitySyncTests {
  @Test func everyMacReceivesItsOwnSealedCopyAndOtherDevicesOnlyCiphertext() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac), linux = try await Device(.linux)
    defer { for device in [mac1, mac2, linux] { device.persistence.remove() } }
    try await mac1.add(mac2); try await mac2.add(mac1); try await mac1.add(linux)
    _ = try await linux.directory.adopt(try await mac1.directory.adoption())

    // Each Mac publishes its sealing key; the libraries exchange rows.
    try await mac2.sync.reconcile()
    try await copyRecords(from: mac2, to: mac1)
    let saved = try await mac1.sync.change { $0.key = gitHubFixtureKey; $0.identity = .init(name: "Ada", email: "ada@example.com") }
    #expect(mac1.store.value == saved && saved.revision > 0)

    try await copyRecords(from: mac1, to: mac2)
    #expect(try await mac2.sync.reconcile())
    #expect(mac2.store.value == saved)

    // A library copy on a Linux host holds no private key text.
    try await copyRecords(from: mac1, to: linux)
    let shared = try #require(try await linux.database.gitHubSharedIdentity())
    let encoded = String(decoding: try JSONEncoder().encode(shared), as: UTF8.self)
    #expect(!encoded.contains("fixture-private-material"))
    #expect(Set(shared.sealed.map(\.device)) == [mac1.id, mac2.id])
  }

  @Test func aMacThatJoinsLaterGetsACopyFromAMacThatHasIt() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac)
    defer { for device in [mac1, mac2] { device.persistence.remove() } }
    try await mac1.add(mac2); try await mac2.add(mac1)
    let saved = try await mac1.sync.change { $0.key = gitHubFixtureKey }

    // Mac 2 learns the record before any copy was sealed to it: it waits.
    try await copyRecords(from: mac1, to: mac2)
    #expect(try await !mac2.sync.reconcile())
    #expect(await mac2.sync.waitingForCopy())
    #expect(mac2.store.value == nil)
    // Its sealing key reaches Mac 1, which seals a copy.
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await !mac1.sync.reconcile())
    try await copyRecords(from: mac1, to: mac2)
    #expect(try await mac2.sync.reconcile())
    #expect(mac2.store.value == saved)

    // A reinstalled Mac (new Keychain, new sealing key) is sealed a new copy.
    mac2.store.wipe()
    #expect(try await !mac2.sync.reconcile())
    #expect(mac2.store.value == nil)
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await !mac1.sync.reconcile())
    try await copyRecords(from: mac1, to: mac2)
    #expect(try await mac2.sync.reconcile())
    #expect(mac2.store.value == saved)
    #expect(try await mac2.database.gitHubSharedIdentity()?.sealed.count == 2)
  }

  /// A Mac still waiting for another Mac's new key cannot put its older key (or none) back
  /// everywhere by saving only its identity; a new key of its own is the user's choice.
  @Test func aMacWaitingForANewerKeyCannotReplaceItWithItsOwn() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac)
    defer { for device in [mac1, mac2] { device.persistence.remove() } }
    try await mac1.add(mac2); try await mac2.add(mac1)
    try await mac1.sync.change { $0.key = gitHubFixtureKey }
    try await copyRecords(from: mac1, to: mac2)
    #expect(await mac2.sync.waitingForCopy())
    await #expect(throws: GitHubIdentityError.self) { try await mac2.sync.change { $0.identity = .init(name: "Grace") } }
    #expect(try await mac2.database.gitHubSharedIdentity()?.key?.fingerprint == gitHubFixtureKey.fingerprint)
    var other = gitHubFixtureKey
    other.fingerprint = "SHA256:other"
    try await mac2.sync.change { $0.key = other }
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await mac1.sync.reconcile())
    #expect(mac1.store.value?.key?.fingerprint == "SHA256:other")
  }

  /// An item this build cannot read neither blocks sync nor Settings: it can be replaced.
  @Test func anUnreadableCopyCanBeReplaced() async throws {
    let mac = try await Device(.mac)
    defer { mac.persistence.remove() }
    mac.store.unreadable = true
    #expect(try await !mac.sync.reconcile())
    let saved = try await mac.sync.change { $0.key = gitHubFixtureKey }
    #expect(mac.store.value == saved)
  }

  /// Records from a newer format are left for the Macs that understand them.
  @Test func recordsFromANewerFormatAreLeftAlone() async throws {
    let mac = try await Device(.mac)
    defer { mac.persistence.remove() }
    let saved = try await mac.sync.change { $0.identity = .init(name: "Ada") }
    var newer = try #require(try await mac.database.gitHubSharedIdentity())
    newer.version = 2
    newer.revision = saved.revision - 10
    try await mac.database.setGitHubSharedIdentity(newer)
    #expect(try await !mac.sync.reconcile())
    #expect(try await mac.database.gitHubSharedIdentity()?.version == 2)
    await #expect(throws: GitHubIdentityError.self) { try await mac.sync.change { $0.identity = .init(name: "Grace") } }
  }

  @Test func removalReachesEveryMac() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac)
    defer { for device in [mac1, mac2] { device.persistence.remove() } }
    try await mac1.add(mac2); try await mac2.add(mac1)
    try await mac2.sync.reconcile()
    try await copyRecords(from: mac2, to: mac1)
    try await mac1.sync.change { $0.key = gitHubFixtureKey }
    try await copyRecords(from: mac1, to: mac2)
    try await mac2.sync.reconcile()
    #expect(mac2.store.value?.key == gitHubFixtureKey)
    try await mac2.sync.change { $0.key = nil }
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await mac1.sync.reconcile())
    #expect(mac1.store.value?.key == nil)
  }

  /// A record only counts when a current Mac member signed it: a Linux host (or anything
  /// relaying through one) cannot hand Macs a key of its own, and Macs put theirs back.
  @Test func recordsNotSignedByAMacAreIgnored() async throws {
    let mac = try await Device(.mac), linux = try await Device(.linux)
    defer { for device in [mac, linux] { device.persistence.remove() } }
    try await mac.add(linux)
    _ = try await linux.directory.adopt(try await mac.directory.adoption())
    let saved = try await mac.sync.change { $0.key = gitHubFixtureKey }
    try await copyRecords(from: mac, to: linux)

    var forged = try #require(try await linux.database.gitHubSharedIdentity())
    forged.revision += 1_000
    forged.author = linux.id
    forged.key = .init(publicKey: "ssh-ed25519 AAAAforged", fingerprint: "SHA256:forged", type: "ssh-ed25519", comment: nil)
    forged.signature = nil
    forged.signature = try linux.identity.sign(forged.statement).base64EncodedString()
    try await linux.database.setGitHubSharedIdentity(forged)
    var recipient = try #require(try await linux.database.gitHubIdentityRecipients().first)
    recipient.device = linux.id
    try await linux.database.setGitHubIdentityRecipient(.init(device: linux.id, key: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
      signature: try linux.identity.sign(GitHubIdentityRecipient.statement(device: linux.id, key: recipient.key)).base64EncodedString()))
    try await copyRecords(from: linux, to: mac)

    #expect(try await !mac.sync.reconcile())
    #expect(mac.store.value == saved)
    // The Mac wrote its own record back, sealed to Macs only.
    let restored = try #require(try await mac.database.gitHubSharedIdentity())
    #expect(restored.author == mac.id && restored.key?.fingerprint == gitHubFixtureKey.fingerprint)
    #expect(restored.sealed.map(\.device) == [mac.id])
  }

  @Test func sealedCopiesOpenOnlyForTheirMacAndRevision() throws {
    let recipient = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try GitHubIdentitySync.seal(gitHubFixtureKey, for: "mac-1", to: recipient.publicKey, revision: 7)
    #expect(try GitHubIdentitySync.open(sealed, with: recipient, revision: 7) == gitHubFixtureKey)
    #expect(throws: GitHubIdentityError.self) { try GitHubIdentitySync.open(sealed, with: recipient, revision: 8) }
    #expect(throws: GitHubIdentityError.self) { try GitHubIdentitySync.open(sealed, with: .init(), revision: 7) }
    var moved = sealed
    moved.device = "mac-2"
    #expect(throws: GitHubIdentityError.self) { try GitHubIdentitySync.open(moved, with: recipient, revision: 7) }
  }
}

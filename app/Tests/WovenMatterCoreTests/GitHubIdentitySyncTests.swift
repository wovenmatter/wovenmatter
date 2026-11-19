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

    // Mac 2 learns the record before any copy was sealed to it: it takes the list and identity
    // and waits for the key.
    try await copyRecords(from: mac1, to: mac2)
    #expect(try await mac2.sync.reconcile())
    #expect(await mac2.sync.waitingForCopy())
    #expect(mac2.store.value?.key == nil && mac2.store.value?.revision == 0)
    // Its sealing key reaches Mac 1, which seals a copy.
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await !mac1.sync.reconcile())
    try await copyRecords(from: mac1, to: mac2)
    #expect(try await mac2.sync.reconcile())
    #expect(mac2.store.value == saved)

    // A reinstalled Mac (new Keychain, new sealing key) is sealed a new copy.
    mac2.store.wipe()
    #expect(try await mac2.sync.reconcile())
    #expect(mac2.store.value?.key == nil)
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await !mac1.sync.reconcile())
    try await copyRecords(from: mac1, to: mac2)
    #expect(try await mac2.sync.reconcile())
    #expect(mac2.store.value == saved)
    #expect(try await mac2.database.gitHubSharedIdentity()?.sealed.count == 2)
  }

  /// A Mac still waiting for another Mac's new key can change the list and identity (every
  /// sealed copy is carried over) but never puts its older key back; a new key of its own is
  /// the user's choice.
  @Test func aMacWithoutTheCurrentKeyStillChangesTheListAndNeverItsOlderKey() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac)
    defer { for device in [mac1, mac2] { device.persistence.remove() } }
    try await mac1.add(mac2); try await mac2.add(mac1)
    try await mac2.sync.reconcile()
    try await copyRecords(from: mac2, to: mac1)
    try await mac1.sync.change { $0.key = gitHubFixtureKey }
    // Mac 2 learns the record while its own copy is missing (a new Keychain).
    mac2.store.wipe()
    try await copyRecords(from: mac1, to: mac2)
    try await mac2.sync.change { $0.identity = .init(name: "Grace"); $0.access.set(mac1.id, false) }
    #expect(mac2.store.value?.key == nil)
    let record = try #require(try await mac2.database.gitHubSharedIdentity())
    #expect(record.key?.fingerprint == gitHubFixtureKey.fingerprint && record.author == mac2.id)
    #expect(record.sealed.map(\.device).contains(mac1.id))
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await mac1.sync.reconcile())
    #expect(mac1.store.value?.key == gitHubFixtureKey)
    #expect(mac1.store.value?.identity.name == "Grace" && mac1.store.value?.access.allows(mac1.id) == false)
    // Mac 1 seals a copy for Mac 2's new sealing key, and Mac 2 gets the key and the list.
    try await copyRecords(from: mac1, to: mac2)
    try await mac2.sync.reconcile()
    try await copyRecords(from: mac2, to: mac1)
    try await mac1.sync.reconcile()
    try await copyRecords(from: mac1, to: mac2)
    try await mac2.sync.reconcile()
    #expect(mac2.store.value?.key == gitHubFixtureKey && mac2.store.value?.identity.name == "Grace")

    var other = gitHubFixtureKey
    other.fingerprint = "SHA256:other"
    try await mac2.sync.change(replacesKey: true) { $0.key = other }
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await mac1.sync.reconcile())
    #expect(mac1.store.value?.key?.fingerprint == "SHA256:other")
  }

  /// A Mac that has not caught up yet never brings back a key another Mac removed.
  @Test func aStaleMacNeverBringsBackARemovedKey() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac)
    defer { for device in [mac1, mac2] { device.persistence.remove() } }
    try await mac1.add(mac2); try await mac2.add(mac1)
    try await mac2.sync.reconcile()
    try await copyRecords(from: mac2, to: mac1)
    try await mac1.sync.change { $0.key = gitHubFixtureKey }
    try await copyRecords(from: mac1, to: mac2)
    try await mac2.sync.reconcile()
    try await mac1.sync.change(replacesKey: true) { $0.key = nil }
    // Mac 2 changes a place before its next reconcile.
    try await copyRecords(from: mac1, to: mac2)
    try await mac2.sync.change { $0.access.set("bot-1", false) }
    #expect(mac2.store.value?.key == nil)
    #expect(try await mac2.database.gitHubSharedIdentity()?.key == nil)
  }

  /// A Mac whose own newer key was never shared (sharing failed) shares it with its next change,
  /// instead of losing it to the older record.
  @Test func aMacsUnsharedNewerKeyIsSharedNotLost() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac)
    defer { for device in [mac1, mac2] { device.persistence.remove() } }
    try await mac1.add(mac2); try await mac2.add(mac1)
    try await mac2.sync.reconcile()
    try await copyRecords(from: mac2, to: mac1)
    try await mac1.sync.change { $0.key = gitHubFixtureKey }
    try await copyRecords(from: mac1, to: mac2)
    try await mac2.sync.reconcile()
    // Mac 2 saved a newer key of its own that never reached the record.
    var newer = gitHubFixtureKey
    newer.fingerprint = "SHA256:newer"
    var local = try #require(mac2.store.value)
    local.key = newer
    local.revision += 1_000
    try mac2.store.storage.save(local)
    try await mac2.sync.change { $0.access.set("bot-1", false) }
    #expect(mac2.store.value?.key == newer)
    #expect(try await mac2.database.gitHubSharedIdentity()?.key?.fingerprint == "SHA256:newer")
  }

  /// A reinstalled Mac whose copy is missing still follows list changes, keeping the same key.
  @Test func aMacMissingItsCopyStillFollowsTheList() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac)
    defer { for device in [mac1, mac2] { device.persistence.remove() } }
    try await mac1.add(mac2); try await mac2.add(mac1)
    try await mac2.sync.reconcile()
    try await copyRecords(from: mac2, to: mac1)
    try await mac1.sync.change { $0.key = gitHubFixtureKey }
    try await copyRecords(from: mac1, to: mac2)
    try await mac2.sync.reconcile()
    // A sealing key Mac 1 has not seen: the next record has no copy for it.
    var stale = try #require(try await mac2.database.gitHubIdentityRecipients().first { $0.device == mac2.id })
    stale.key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    stale.signature = try mac2.identity.sign(GitHubIdentityRecipient.statement(device: mac2.id, key: stale.key)).base64EncodedString()
    try await mac1.database.setGitHubIdentityRecipient(stale)
    try await mac1.sync.change { $0.access.set(mac2.id, false) }
    try await copyRecords(from: mac1, to: mac2)
    #expect(try await mac2.sync.reconcile())
    #expect(mac2.store.value?.key == gitHubFixtureKey && mac2.store.value?.access.allows(mac2.id) == false)
  }

  /// Every Mac and Linux host stores the key, whether its agents may use it or not; phones
  /// never get a copy. Turning a place off changes only the list every machine reads.
  @Test func everyMacAndLinuxHostStoresTheKeyAndPhonesNever() async throws {
    let mac1 = try await Device(.mac), mac2 = try await Device(.mac), linux = try await Device(.linux), phone = try await Device(.ios)
    defer { for device in [mac1, mac2, linux, phone] { device.persistence.remove() } }
    for other in [mac2, linux, phone] { try await mac1.add(other) }
    // Member lists sync too; here each Mac is told directly.
    try await mac2.add(mac1); try await mac2.add(linux)
    for device in [linux, phone] { _ = try await device.directory.adopt(try await mac1.directory.adoption()) }

    // Each machine publishes its sealing key; a phone's (if it ever wrote one) is ignored.
    try await mac2.sync.reconcile()
    #expect(try await linux.sync.hostCopy() == nil)
    _ = try await phone.sync.hostCopy()
    for device in [mac2, linux, phone] { try await copyRecords(from: device, to: mac1) }

    // Mac 2 is off from the start: it still gets its own copy.
    try await mac1.sync.change { $0.key = gitHubFixtureKey; $0.identity = .init(name: "Ada"); $0.access.set(mac2.id, false) }
    let record = try #require(try await mac1.database.gitHubSharedIdentity())
    #expect(Set(record.sealed.map(\.device)) == [mac1.id, mac2.id, linux.id])
    try await copyRecords(from: mac1, to: mac2)
    #expect(try await mac2.sync.reconcile())
    #expect(mac2.store.value?.key == gitHubFixtureKey)
    #expect(mac2.store.value?.access.allows(mac2.id) == false)

    // The Linux host opens its own copy for its Woven server, list included.
    try await copyRecords(from: mac1, to: linux)
    let copy = try #require(try await linux.sync.hostCopy())
    #expect(copy.key == gitHubFixtureKey && copy.identity.name == "Ada" && copy.access.allows(linux.id))
    // A phone can relay the record but opens nothing.
    try await copyRecords(from: mac1, to: phone)
    #expect(try await phone.sync.hostCopy()?.key == nil)

    // Any Mac can change the list, including a Mac that is off, and every machine sees it.
    try await mac2.sync.change { $0.access.set(linux.id, false); $0.access.set(mac2.id, true) }
    try await copyRecords(from: mac2, to: linux)
    let changed = try #require(try await linux.sync.hostCopy())
    #expect(changed.key == gitHubFixtureKey && !changed.access.allows(linux.id))
    try await copyRecords(from: mac2, to: mac1)
    #expect(try await mac1.sync.reconcile())
    #expect(mac1.store.value?.access.allows(mac2.id) == true)
  }

  /// A Linux host that joins after the key was saved is sealed a copy by the next Mac online.
  @Test func aLinuxHostThatJoinsLaterGetsACopy() async throws {
    let mac = try await Device(.mac), linux = try await Device(.linux)
    defer { for device in [mac, linux] { device.persistence.remove() } }
    try await mac.sync.change { $0.key = gitHubFixtureKey; $0.access.newPlaces = false }
    try await mac.add(linux)
    _ = try await linux.directory.adopt(try await mac.directory.adoption())
    try await copyRecords(from: mac, to: linux)
    // It learns the record before any copy was sealed to it: the list and identity, no key yet.
    let waiting = try #require(try await linux.sync.hostCopy())
    #expect(waiting.key == nil && waiting.access.newPlaces == false)
    try await copyRecords(from: linux, to: mac)
    #expect(try await !mac.sync.reconcile())
    try await copyRecords(from: mac, to: linux)
    #expect(try await linux.sync.hostCopy()?.key == gitHubFixtureKey)
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

  @Test func sealedCopiesOpenOnlyForTheirMachineAndKey() throws {
    let recipient = Curve25519.KeyAgreement.PrivateKey()
    let sealed = try GitHubIdentitySync.seal(gitHubFixtureKey, for: "mac-1", to: recipient.publicKey)
    let fingerprint = gitHubFixtureKey.fingerprint
    #expect(try GitHubIdentitySync.open(sealed, with: recipient, fingerprint: fingerprint) == gitHubFixtureKey)
    #expect(throws: GitHubIdentityError.self) { try GitHubIdentitySync.open(sealed, with: recipient, fingerprint: "SHA256:other") }
    #expect(throws: GitHubIdentityError.self) { try GitHubIdentitySync.open(sealed, with: .init(), fingerprint: fingerprint) }
    var moved = sealed
    moved.device = "mac-2"
    #expect(throws: GitHubIdentityError.self) { try GitHubIdentitySync.open(moved, with: recipient, fingerprint: fingerprint) }
  }
}

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterDashboardStore

/// The trust model (docs/architecture/WOVEN_EVERYWHERE.md, "Trust model"):
/// signer times never decide which side of a dispute wins.
@Suite("Member trust", .serialized)
struct MemberTrustTests {
  private static func identity(_ kind: MemberKind) -> MemberIdentity {
    MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: kind, key: .init())
  }
  private static func entry(_ device: MemberIdentity, by signer: MemberIdentity, at time: Int64, kind: MemberKind? = nil) throws -> LibraryMemberEntry {
    try .signed(deviceID: device.deviceID, kind: kind ?? device.kind, name: String(device.deviceID.prefix(4)), publicKey: device.publicKey,
                endpoints: [], by: signer, at: time)
  }
  /// Every Mac signs entries for every other (Mac pairing records both sides).
  private static func meshed(_ macs: [MemberIdentity], at time: Int64) throws -> [LibraryMemberEntry] {
    try macs.flatMap { signer in try macs.filter { $0.deviceID != signer.deviceID }.map { try entry($0, by: signer, at: time) } }
  }
  private static func view(_ own: MemberIdentity, _ entries: [LibraryMemberEntry], _ revocations: [LibraryMemberRevocation],
                           pinned: [MemberIdentity] = [], now: Int64 = 1_000_000) -> [String: LibraryMember] {
    let members = LibraryMemberResolver.resolve(entries: entries, revocations: revocations, anchors: [own.anchor] + pinned.map(\.anchor),
                                                own: own.deviceID, now: now)
    return Dictionary(uniqueKeysWithValues: members.map { ($0.deviceID, $0) })
  }
  private static func active(_ view: [String: LibraryMember], _ device: MemberIdentity) -> Bool { view[device.deviceID]?.revoked == false }

  @Test func aRemovedMacsBackdatedEntriesNeverCount() throws {
    let a = Self.identity(.mac), x = Self.identity(.mac), sockpuppet = Self.identity(.mac), phone = Self.identity(.ios)
    var entries = try Self.meshed([a, x], at: 10)
    entries.append(try Self.entry(phone, by: x, at: 20))
    let removal = try LibraryMemberRevocation.signed(deviceID: x.deviceID, by: a, at: 100)
    // After its removal X signs entries dated before it: a sockpuppet Mac,
    // and an entry re-adding X from that sockpuppet.
    let backdated = [try Self.entry(sockpuppet, by: x, at: 50), try Self.entry(x, by: sockpuppet, at: 60)]
    for own in [a] {
      let members = Self.view(own, entries + backdated, [removal])
      #expect(members[x.deviceID]?.revoked == true)
      #expect(members[sockpuppet.deviceID] == nil, "a removed Mac's signatures are void whatever their date")
      #expect(members[phone.deviceID] == nil, "devices only it vouched for drop out until re-signed")
    }
    // A Mac that joins later, added by A, sees the same.
    let newcomer = Self.identity(.mac)
    let joined = entries + backdated + [try Self.entry(newcomer, by: a, at: 200), try Self.entry(a, by: newcomer, at: 200)]
    let fresh = Self.view(newcomer, joined, [removal])
    #expect(fresh[x.deviceID]?.revoked == true && fresh[sockpuppet.deviceID] == nil && Self.active(fresh, a))
    // An entry dated far ahead never outlasts the removal.
    let future = Self.view(a, entries + [try Self.entry(x, by: sockpuppet, at: 10_000_000)], [removal])
    #expect(future[x.deviceID]?.revoked == true)
  }

  @Test func massRevocationNeverRemovesTheHonestMacs() throws {
    let a = Self.identity(.mac), b = Self.identity(.mac), x = Self.identity(.mac), linux = Self.identity(.linux), spared = Self.identity(.mac)
    var entries = try Self.meshed([a, b, x, spared], at: 10)
    entries.append(try Self.entry(linux, by: a, at: 10))
    // X removes everyone it can, dated as early as possible and as now.
    let attack = try [a, b, linux].flatMap { target in
      [try LibraryMemberRevocation.signed(deviceID: target.deviceID, by: x, at: 1),
       try LibraryMemberRevocation.signed(deviceID: target.deviceID, by: x, at: 500)]
    }
    let removal = try LibraryMemberRevocation.signed(deviceID: x.deviceID, by: a, at: 400)
    for own in [a, b, linux] {
      // Every device X revoked keeps the honest Macs and drops X.
      let members = Self.view(own, entries, attack + [removal], pinned: own.kind == .linux ? [a] : [a, b, x].filter { $0.deviceID != own.deviceID })
      #expect(Self.active(members, a) && Self.active(members, b), "honest Macs stand on \(own.kind)")
      #expect(members[x.deviceID]?.revoked == true, "the attacker is removed on \(own.kind)")
      if own.kind != .linux { #expect(Self.active(members, linux)) }
    }
    // A device X spared trusts neither side of the dispute: X never wins.
    let sparedView = Self.view(spared, entries, attack + [removal], pinned: [a, b, x])
    #expect(sparedView[x.deviceID]?.revoked == true)
    // Backdated revocations alone do nothing: a standing Mac's later entry outlasts them.
    let early = Self.view(spared, entries, attack.filter { $0.revokedAt == 1 }, pinned: [a, b, x])
    #expect(Self.active(early, a) && Self.active(early, b) && Self.active(early, x))
  }

  @Test func removalStaysOutWithoutTheMacThatIntroducedADevice() throws {
    // C paired only with A; B joined through A, then B removes A.
    let a = Self.identity(.mac), b = Self.identity(.mac), c = Self.identity(.mac)
    let entries = try Self.meshed([a, b], at: 10) + Self.meshed([a, c], at: 10)
    let removal = try LibraryMemberRevocation.signed(deviceID: a.deviceID, by: b, at: 100)
    let pinnedView = Self.view(c, entries, [removal], pinned: [b])
    #expect(Self.active(pinnedView, b) && pinnedView[a.deviceID]?.revoked == true, "a Mac C pinned stays a root")
    // Re-adding the removed Mac later takes a newer entry from a standing Mac.
    let readded = Self.view(c, entries + [try Self.entry(a, by: b, at: 200)], [removal], pinned: [b])
    #expect(Self.active(readded, a))
  }

  @Test func aMacThatRemovedThisDeviceCannotRemoveOthersHere() throws {
    let a = Self.identity(.mac), b = Self.identity(.mac), phone = Self.identity(.ios)
    let entries = try Self.meshed([a, b], at: 10) + [try Self.entry(phone, by: a, at: 10)]
    let removeA = try LibraryMemberRevocation.signed(deviceID: a.deviceID, by: b, at: 100)
    let removePhone = try LibraryMemberRevocation.signed(deviceID: phone.deviceID, by: b, at: 110)
    // A's own view: B removed A, so B removes nobody here.
    let members = Self.view(a, entries, [removeA, removePhone], pinned: [b])
    #expect(Self.active(members, phone))
    // Once a standing Mac re-adds A, B's removals count on A again.
    let c = Self.identity(.mac)
    let readd = try entries + Self.meshed([a, c], at: 10) + [Self.entry(a, by: c, at: 120)]
    let after = Self.view(a, readd, [removeA, removePhone], pinned: [b, c])
    #expect(after[phone.deviceID]?.revoked == true)
  }

  @Test func directoryRemovalReSignsWhatItKeepsAndReplacesAPhonesKey() async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
    let own = MemberIdentity(deviceID: try await database.libraryIdentity().hostDeviceID, kind: .mac, key: .init())
    let directory = MemberDirectory(database: database, identity: own, cacheLifetime: 0, pinAfter: 0)
    try await directory.ensureSelf(name: "Own", endpoints: [])
    let x = Self.identity(.mac), phone = Self.identity(.ios), removedEarlier = Self.identity(.ios)
    try await directory.add(deviceID: x.deviceID, kind: .mac, name: "X", publicKey: x.publicKey, endpoints: [])
    let now = MemberRequestSignature.now()
    try await database.saveLibraryMemberEntries([try Self.entry(own, by: x, at: now), try Self.entry(phone, by: x, at: now),
                                                 try Self.entry(removedEarlier, by: x, at: now), try Self.entry(removedEarlier, by: own, at: now)])
    try await database.saveLibraryMemberRevocations([try .signed(deviceID: removedEarlier.deviceID, by: x, at: now + 1)])
    #expect(await directory.member(phone.deviceID) != nil)
    let earlier = try await directory.list().members.first { $0.deviceID == removedEarlier.deviceID }
    #expect(earlier?.revoked == true)
    try await directory.remove(x.deviceID)
    let list = try await directory.list()
    #expect(list.members.first { $0.deviceID == x.deviceID }?.revoked == true)
    #expect(list.active(phone.deviceID)?.addedBy == own.deviceID, "the phone X added is kept, re-signed by this Mac")
    #expect(list.members.first { $0.deviceID == removedEarlier.deviceID }?.revoked == true, "X's own removals are re-signed too")
    // The phone is restored from a backup with a new key and paired again here.
    let restored = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    await #expect(throws: LibraryAPIError.self) {
      try await directory.add(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: restored, endpoints: [])
    }
    try await directory.checkAdd(deviceID: phone.deviceID, kind: .ios, publicKey: restored, replacingKey: true)
    try await directory.add(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: restored, endpoints: [], replacingKey: true)
    #expect(try await directory.list().active(phone.deviceID)?.publicKey == restored)
    // A removed phone comes back with whatever key it presents.
    try await directory.remove(phone.deviceID)
    let again = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    try await directory.add(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: again, endpoints: [])
    #expect(try await directory.list().active(phone.deviceID)?.publicKey == again)
    // A Mac's key never changes.
    await #expect(throws: LibraryAPIError.self) {
      try await directory.add(deviceID: x.deviceID, kind: .mac, name: "X", publicKey: restored, endpoints: [], replacingKey: true)
    }
  }

  @Test func trustedMacsArePinnedOnlyAfterTheyStayTrusted() async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
    let own = MemberIdentity(deviceID: try await database.libraryIdentity().hostDeviceID, kind: .mac, key: .init())
    let waiting = MemberDirectory(database: database, identity: own, cacheLifetime: 0)
    try await waiting.ensureSelf(name: "Own", endpoints: [])
    let a = Self.identity(.mac), b = Self.identity(.mac)
    try await waiting.add(deviceID: a.deviceID, kind: .mac, name: "A", publicKey: a.publicKey, endpoints: [])
    try await database.saveLibraryMemberEntries([try Self.entry(b, by: a, at: MemberRequestSignature.now())])
    _ = try await waiting.list(); _ = try await waiting.list()
    #expect(try await database.libraryMemberRecords().anchors.map(\.deviceID).sorted() == [own.deviceID], "a day of trust first")
    let immediate = MemberDirectory(database: database, identity: own, cacheLifetime: 0, pinAfter: 0)
    _ = try await immediate.list(); _ = try await immediate.list()
    #expect(Set(try await database.libraryMemberRecords().anchors.map(\.deviceID)) == [own.deviceID, a.deviceID, b.deviceID])
    #expect(try await immediate.list().adopted == true)
  }

  @Test func laterAdoptionsNeverAddOrReplaceAnchors() async throws {
    let persistence = try PersistenceFixture(); defer { persistence.remove() }
    let database = try await persistence.openDatabase()
    let host = MemberIdentity(deviceID: try await database.libraryIdentity().hostDeviceID, kind: .linux, key: .init())
    let directory = MemberDirectory(database: database, identity: host, cacheLifetime: 0)
    try await directory.ensureSelf(name: "Host", endpoints: [])
    #expect(try await directory.list().adopted == false)
    let installer = Self.identity(.mac), other = Self.identity(.mac), stranger = Self.identity(.mac)
    let records = try Self.meshed([installer, other], at: 10) + [try Self.entry(host, by: installer, at: 10)]
    _ = try await directory.adopt(.init(anchor: installer.anchor, entries: records, revocations: []))
    #expect(try await directory.list().adopted == true)
    // A stranger, even one that signed this host's key, is not let in.
    let planted = [try Self.entry(host, by: stranger, at: 20)]
    await #expect(throws: LibraryAPIError.self) { _ = try await directory.adopt(.init(anchor: stranger.anchor, entries: planted, revocations: [])) }
    // A trusted Mac with another key cannot replace the installer's anchor.
    let forged = LibraryMemberAnchor(deviceID: installer.deviceID, kind: .mac, publicKey: stranger.publicKey)
    await #expect(throws: LibraryAPIError.self) { _ = try await directory.adopt(.init(anchor: forged, entries: planted, revocations: [])) }
    // Another trusted Mac only brings records.
    _ = try await directory.adopt(.init(anchor: other.anchor, entries: [], revocations: [try .signed(deviceID: stranger.deviceID, by: other, at: 30)]))
    let anchors = try await database.libraryMemberRecords().anchors
    #expect(Set(anchors.map(\.deviceID)) == [host.deviceID, installer.deviceID])
    #expect(anchors.first { $0.deviceID == installer.deviceID }?.publicKey == installer.publicKey)
    // With every Mac removed the host still counts as adopted.
    try await database.saveLibraryMemberRevocations([try .signed(deviceID: installer.deviceID, by: other, at: 40),
                                                     try .signed(deviceID: other.deviceID, by: other, at: 41)])
    let list = try await directory.list()
    #expect(!list.members.contains { $0.kind == .mac && !$0.revoked } && list.adopted == true)
  }
}

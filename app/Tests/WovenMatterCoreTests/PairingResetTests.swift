#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterLibraryStore

/// Pairing whose records were signed under other labels no longer verifies.
/// A device that opens such pairing clears all of it once and starts as an
/// unpaired device (`holdsUnverifiablePairing`, `clearPairingRecords`,
/// `DeviceAuthentication.clearPairing`).
@Suite("Pairing reset") struct PairingResetTests {
  /// Records as a build that signed under other labels left them.
  private enum OtherBuild {
    static func entry(_ device: MemberIdentity, name: String, endpoints: [URL] = [], by signer: MemberIdentity, at time: Int64) throws -> LibraryMemberEntry {
      let statement = canonical([("device", device.deviceID), ("kind", device.kind.rawValue), ("name", name),
        ("key", device.publicKey.base64EncodedString()), ("endpoints", endpoints.map(\.absoluteString).joined(separator: "\n")),
        ("added_by", signer.deviceID), ("added_at", String(time))], domain: "test.member.entry.other")
      return .init(deviceID: device.deviceID, kind: device.kind, name: name, publicKey: device.publicKey, endpoints: endpoints,
                   addedBy: signer.deviceID, addedAt: time, signature: try signer.sign(statement))
    }
    static func removal(of device: MemberIdentity, by signer: MemberIdentity, at time: Int64) throws -> LibraryMemberRevocation {
      let event = UUID().uuidString.lowercased()
      let statement = canonical([("event", event), ("device", device.deviceID), ("revoked_by", signer.deviceID), ("revoked_at", String(time))],
                                domain: "test.member.revocation.other")
      return .init(eventID: event, deviceID: device.deviceID, revokedBy: signer.deviceID, revokedAt: time, signature: try signer.sign(statement))
    }
  }

  private static func member(_ kind: MemberKind, id: String = UUID().uuidString.lowercased()) -> MemberIdentity {
    .init(deviceID: id, kind: kind, key: Curve25519.Signing.PrivateKey())
  }
  private static func count(_ database: WorkspaceDatabase, _ sql: String) async throws -> Int {
    try await database.read { try $0.historyRowsUnlocked("SELECT (" + sql + ") AS n", values: []).first?.objectValue?["n"]?.intValue ?? -1 }
  }
  private static let pairingTables = ["library_members", "library_member_revocations", "library_member_anchors",
                                      "library_member_pin_candidates", "github_identity", "github_identity_recipients"]

  /// A Mac's library as an earlier build left it: itself, a paired Mac it
  /// has pinned, a phone, a Linux host, and a Mac it removed after pinning it.
  private struct Library {
    let persistence: PersistenceFixture
    let database: WorkspaceDatabase
    let own: MemberIdentity, mac: MemberIdentity, phone: MemberIdentity, linux: MemberIdentity, removed: MemberIdentity
    let note = UUID().uuidString.lowercased()
    let endpoint = URL(string: "https://studio.fixture.ts.net/wovenmatter")!

    init() async throws {
      persistence = try PersistenceFixture()
      database = try await persistence.openDatabase()
      own = PairingResetTests.member(.mac, id: try await database.libraryIdentity().hostDeviceID)
      mac = PairingResetTests.member(.mac); phone = PairingResetTests.member(.ios)
      linux = PairingResetTests.member(.linux); removed = PairingResetTests.member(.mac)
      let now = MemberRequestSignature.now() - 86_400_000
      let other = URL(string: "https://mini.fixture.ts.net/wovenmatter")!
      try await database.saveLibraryMemberEntries([
        try OtherBuild.entry(own, name: "Studio", endpoints: [endpoint], by: own, at: now),
        try OtherBuild.entry(mac, name: "Mini", endpoints: [other], by: own, at: now + 1),
        try OtherBuild.entry(mac, name: "Mini", endpoints: [other], by: mac, at: now + 2),
        try OtherBuild.entry(own, name: "Studio", endpoints: [endpoint], by: mac, at: now + 3),
        try OtherBuild.entry(phone, name: "iPhone", by: own, at: now + 4),
        try OtherBuild.entry(linux, name: "Box", endpoints: [URL(string: "https://box.fixture.ts.net/wovenmatter/")!], by: own, at: now + 5),
        try OtherBuild.entry(removed, name: "Old Mac", endpoints: [URL(string: "https://old.fixture.ts.net/wovenmatter")!], by: own, at: now + 6),
      ])
      try await database.saveLibraryMemberRevocations([try OtherBuild.removal(of: removed, by: own, at: now + 7)])
      for anchor in [own.anchor, mac.anchor, removed.anchor] { try await database.saveLibraryMemberAnchor(anchor) }
      try await database.updateLibraryMemberPinCandidates(saving: [(PairingResetTests.member(.mac).anchor, now)], removing: [])
      let signature = Data(repeating: 7, count: 64).base64EncodedString(), key = Data(repeating: 9, count: 32).base64EncodedString()
      let record = #"{"access":{},"author":"\#(own.deviceID)","identity":{},"revision":5,"sealed":[],"signature":"\#(signature)"}"#
      let recipients = [own.deviceID, mac.deviceID, linux.deviceID].map { ($0, #"{"device":"\#($0)","key":"\#(key)","signature":"\#(signature)"}"#) }
      try await database.write { connection in
        try connection.toolsExecuteUnlocked("INSERT INTO github_identity(singleton,payload) VALUES(1,?)", [record])
        for (device, payload) in recipients {
          try connection.toolsExecuteUnlocked("INSERT INTO github_identity_recipients(device_id,payload) VALUES(?,?)", [device, payload])
        }
      }
      // What a reset must leave alone.
      let content = try NoteDocument(blocks: [.richText(.init(text: "Kept"))]).encoded()
      _ = try await database.applyLibraryMutation(.init(deviceID: own.deviceID, kind: .createNote, resourceID: note, title: "Kept", content: content))
      try await database.reconcileLocalCLIAgentCatalog(ownerDeviceID: UUID())
      try await database.saveMacRoute(.init(deviceID: mac.deviceID, libraryID: UUID().uuidString.lowercased(), endpoint: other, name: "Mini"))
    }
    func remove() { persistence.remove() }
  }

  /// A paired-device file with every key today's file has, and its phone's bearer.
  private struct DeviceFile {
    let file: URL
    let phone: (id: String, bearer: String)
    let workspace = UUID().uuidString.lowercased()

    init(in directory: URL) async throws {
      file = directory.appending(path: DeviceAuthentication.fileName)
      let authentication = try DeviceAuthentication(fileURL: file)
      let endpoint = URL(string: "https://studio.fixture.ts.net/wovenmatter")!
      func offer() async throws -> String { try await authentication.createOffer(endpoint: endpoint).payload.token }
      let device = UUID().uuidString.lowercased()
      let paired = try await authentication.pairConfirmed(.init(token: try await offer(), deviceID: device, deviceName: "iPhone",
        metadata: .init(kind: .iPhone)), workspaceID: workspace)
      phone = (device, paired.credential)
      // A Mac that completed its signed join: a grant, a pin and an admission.
      let own = PeerSelf(deviceID: UUID().uuidString.lowercased(), libraryID: workspace, key: .init())
      let mac = PeerSelf(deviceID: UUID().uuidString.lowercased(), libraryID: UUID().uuidString.lowercased(), key: .init())
      let statement = PeerAdmission.subjectStatement(issuerDeviceID: own.deviceID, issuerLibraryID: own.libraryID, subjectDeviceID: mac.deviceID,
        subjectLibraryID: mac.libraryID, subjectPublicKey: mac.publicKey, acknowledgedRevocations: [])
      try await authentication.enrollPeer(route: .init(deviceID: mac.deviceID, libraryID: mac.libraryID, endpoint: endpoint, name: "Mini"),
        token: String(repeating: "t", count: 43), publicKey: mac.publicKey, subjectSignature: try mac.key.signature(for: statement),
        acknowledgedRevocations: [], own: own)
      // An unpaired tablet, a phone that never confirmed, and a Mac waiting for approval.
      let tablet = UUID().uuidString.lowercased()
      _ = try await authentication.pairConfirmed(.init(token: try await offer(), deviceID: tablet, deviceName: "iPad", metadata: .init(kind: .iPad)), workspaceID: workspace)
      try await authentication.revoke(deviceID: tablet)
      _ = try await authentication.pair(.init(token: try await offer(), deviceID: UUID().uuidString.lowercased(), deviceName: "Second iPhone",
        metadata: .init(kind: .iPhone), requiresConfirmation: true), workspaceID: workspace)
      _ = try await authentication.requestPairing(.init(requestID: UUID().uuidString.lowercased(), requestSecret: String(repeating: "s", count: 43),
        identity: .init(deviceID: UUID().uuidString.lowercased(), deviceName: "Other Mac", metadata: .init(kind: .mac))), workspaceID: workspace)
      // The two keys the released build also writes, which nothing reads.
      var stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
      stored["version"] = 1; stored["admissionVersion"] = 3
      try JSONSerialization.data(withJSONObject: stored).write(to: file)
    }
    var keys: Set<String> {
      get throws { Set(try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]).keys) }
    }
  }

  @Test func aLibraryAndPairedDeviceFileInTodaysShapeAreClearedOnceAndTheirContentIsKept() async throws {
    let library = try await Library(); defer { library.remove() }
    let database = library.database
    let devices = try await DeviceFile(in: library.persistence.directory)
    #expect(try devices.keys.isSuperset(of: ["version", "admissionVersion", "devices", "roster", "pins", "revocations", "pendingQRPairings", "approvals"]))
    for table in Self.pairingTables { #expect(try await Self.count(database, "SELECT count(*) FROM " + table) > 0, "\(table)") }
    let agents = try await Self.count(database, "SELECT count(*) FROM agents")
    #expect(agents > 0)

    // Unverifiable records must not stay: a Mac this one pinned is still
    // trusted, but has no address, and the Mac it removed is trusted again.
    let stale = try await database.libraryMembers(own: library.own.deviceID).members
    #expect(stale.first { $0.deviceID == library.mac.deviceID }?.endpoints == [])
    #expect(stale.contains { $0.deviceID == library.removed.deviceID && !$0.revoked })

    #expect(try await database.holdsUnverifiablePairing())
    let authentication = try DeviceAuthentication(fileURL: devices.file)
    #expect(await authentication.devices().count == 2)
    try await authentication.clearPairing()
    try await database.clearPairingRecords()

    for table in Self.pairingTables { #expect(try await Self.count(database, "SELECT count(*) FROM " + table) == 0, "\(table)") }
    let named = WorkspaceDatabase.sharedPairingTables.map { "'" + $0 + "'" }.joined(separator: ",")
    for bookkeeping in ["peer_sync_versions", "peer_sync_conflicts", "peer_sync_quarantine", "peer_sync_reassert"] {
      #expect(try await Self.count(database, "SELECT count(*) FROM \(bookkeeping) WHERE table_name IN (\(named))") == 0, "\(bookkeeping)")
    }
    // Nothing is left to send a peer about them, not even a deletion.
    var cursor: Int64 = 0, sent = 0
    while true {
      let page = try await database.pairedLibraryPage(after: cursor)
      sent += page.entries.filter { WorkspaceDatabase.sharedPairingTables.contains($0.table) }.count
      guard page.hasMore else { break }
      cursor = page.cursor
    }
    #expect(sent == 0)
    #expect(try await Self.count(database, "SELECT applying FROM peer_sync_clock") == 0)
    // Content and what is known of other machines stay.
    #expect(try await database.libraryNote(id: library.note)?.title == "Kept")
    #expect(try await Self.count(database, "SELECT count(*) FROM agents") == agents)
    #expect(try await database.macRoutes().map(\.deviceID) == [library.mac.deviceID])

    // The file holds no grant, pending pairing, pin, admission or unpair, and says so once.
    #expect(await authentication.devices().isEmpty)
    #expect(await authentication.pendingPairingRequests().isEmpty)
    #expect(await authentication.pin(for: library.mac.deviceID) == nil)
    #expect(await authentication.peerMembership().entries.isEmpty)
    await #expect(throws: LibraryAPIError.self) { try await authentication.authenticate(bearer: devices.phone.bearer) }
    #expect(try devices.keys == ["devices", "pairingResetNotice"])
    let reopened = try DeviceAuthentication(fileURL: devices.file)
    #expect(await reopened.devices().isEmpty)
    #expect(await reopened.showsPairingResetNotice())

    // The device then signs its own entry, and there is nothing to clear a second time.
    #expect(try await !database.holdsUnverifiablePairing())
    let directory = MemberDirectory(database: database, identity: library.own, cacheLifetime: 0)
    try await directory.ensureSelf(name: "Studio", endpoints: [library.endpoint])
    let entry = try #require(try await database.libraryMemberRecords().entries.first)
    #expect(entry.verifies(with: library.own.publicKey))
    #expect(try await directory.list().members.map(\.deviceID) == [library.own.deviceID])
    #expect(try await directory.list().members.first?.endpoints == [library.endpoint])
    #expect(try await !database.holdsUnverifiablePairing())
    let head = try await database.peerSyncHead(), bytes = try Data(contentsOf: devices.file)
    let again = try await WorkspaceDatabase(url: database.fileURL)
    #expect(try await !again.holdsUnverifiablePairing())
    #expect(try await again.peerSyncHead() == head)
    #expect(try Data(contentsOf: devices.file) == bytes)
  }

  /// A reset that stopped after the paired-device file was cleared starts
  /// again, because the library is cleared last and is what the check reads.
  @Test func aResetInterruptedBeforeTheLibraryRunsAgainAndKeepsItsNotice() async throws {
    let library = try await Library(); defer { library.remove() }
    let devices = try await DeviceFile(in: library.persistence.directory)
    try await DeviceAuthentication(fileURL: devices.file).clearPairing()
    let reopened = try await WorkspaceDatabase(url: library.database.fileURL)
    #expect(try await reopened.holdsUnverifiablePairing())
    let authentication = try DeviceAuthentication(fileURL: devices.file)
    try await authentication.clearPairing()
    #expect(await authentication.showsPairingResetNotice())
    try await reopened.clearPairingRecords()
    #expect(try await !reopened.holdsUnverifiablePairing())
  }

  @Test func aRemovedMacIsNotTrustedAgainAndTheOthersAreOnlyOncePairedAgain() async throws {
    let library = try await Library(); defer { library.remove() }
    try await library.database.clearPairingRecords()
    let directory = MemberDirectory(database: library.database, identity: library.own, cacheLifetime: 0, pinAfter: 0)
    try await directory.ensureSelf(name: "Studio", endpoints: [library.endpoint])
    for device in [library.mac, library.phone, library.linux, library.removed] {
      #expect(await directory.activeKey(device.deviceID) == nil)
    }
    // Pairing the Mac and the phone again makes them members; with no wait, listing pins the Mac.
    let other = URL(string: "https://mini.fixture.ts.net/wovenmatter")!
    try await directory.add(deviceID: library.mac.deviceID, kind: .mac, name: "Mini", publicKey: library.mac.publicKey, endpoints: [other])
    try await directory.add(deviceID: library.phone.deviceID, kind: .ios, name: "iPhone", publicKey: library.phone.publicKey, endpoints: [])
    _ = try await directory.list(); _ = try await directory.list()
    #expect(await directory.member(library.mac.deviceID)?.endpoints == [other])
    #expect(await directory.activeKey(library.phone.deviceID) != nil)
    #expect(await directory.activeKey(library.removed.deviceID) == nil)
    #expect(try await library.database.libraryMemberRecords().anchors.map(\.deviceID).sorted() == [library.own.deviceID, library.mac.deviceID].sorted())
  }

  @Test func aPhonePairsAgainOnlyAfterTheResetAndPairingEndsTheNotice() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let devices = try await DeviceFile(in: fixture.directory)
    let authentication = try DeviceAuthentication(fileURL: devices.file)
    let endpoint = URL(string: "https://studio.fixture.ts.net/wovenmatter")!
    func pairPhone() async throws -> PairResponse {
      try await authentication.pairConfirmed(.init(token: try await authentication.createOffer(endpoint: endpoint).payload.token,
        deviceID: devices.phone.id, deviceName: "iPhone", metadata: .init(kind: .iPhone)), workspaceID: devices.workspace)
    }
    await #expect(throws: LibraryAPIError.self) { try await pairPhone() }
    try await authentication.clearPairing()
    #expect(await authentication.showsPairingResetNotice())
    let paired = try await pairPhone()
    #expect(try await authentication.authenticate(bearer: paired.credential).id == devices.phone.id)
    #expect(await !authentication.showsPairingResetNotice())
    #expect(try await !DeviceAuthentication(fileURL: devices.file).showsPairingResetNotice())
    await #expect(throws: LibraryAPIError.self) { try await authentication.authenticate(bearer: devices.phone.bearer) }
  }

  @Test func theNoticeIsOnlyForADeviceThatHeldPairingsAndEndsWhenDismissed() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let file = fixture.directory.appending(path: DeviceAuthentication.fileName)
    // No file, as on a Mac that never paired and on a Linux host.
    let never = try DeviceAuthentication(fileURL: file)
    try await never.clearPairing()
    #expect(await !never.showsPairingResetNotice())
    #expect(!FileManager.default.fileExists(atPath: file.path))
    // Only a development instance: nothing a person paired.
    let workspace = UUID().uuidString.lowercased()
    let token = try await never.createOffer(endpoint: URL(string: "https://studio.fixture.ts.net/wovenmatter")!).payload.token
    _ = try await never.pairConfirmed(.init(token: token, deviceID: UUID().uuidString.lowercased(), deviceName: "Dev",
      metadata: .init(kind: .mac, developmentInstance: "fixture")), workspaceID: workspace)
    try await never.clearPairing()
    #expect(await !never.showsPairingResetNotice())
    #expect(await never.devices().isEmpty)
    try FileManager.default.removeItem(at: file)

    let devices = try await DeviceFile(in: fixture.directory)
    let authentication = try DeviceAuthentication(fileURL: devices.file)
    try await authentication.clearPairing()
    #expect(await authentication.showsPairingResetNotice())
    try await authentication.dismissPairingResetNotice()
    #expect(await !authentication.showsPairingResetNotice())
    let reopened = try DeviceAuthentication(fileURL: devices.file)
    #expect(await !reopened.showsPairingResetNotice())
    // Clearing what is already clear raises nothing again.
    try await reopened.clearPairing()
    #expect(await !reopened.showsPairingResetNotice())
  }

  /// The check reads only this device's own entry, and judges it by the key
  /// the entry names: a library without one, or with one another key of
  /// this device signed, holds nothing to clear.
  @Test func onlyAnOwnEntryThatDoesNotVerifyIsRecognised() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    #expect(try await !database.holdsUnverifiablePairing())
    let own = Self.member(.mac, id: try await database.libraryIdentity().hostDeviceID)
    let now = MemberRequestSignature.now()
    // Another device's unverifiable entry is not this device's pairing.
    let stranger = Self.member(.mac)
    try await database.saveLibraryMemberEntries([try OtherBuild.entry(stranger, name: "Stranger", by: stranger, at: now)])
    #expect(try await !database.holdsUnverifiablePairing())
    try await MemberDirectory(database: database, identity: own).ensureSelf(name: "Studio", endpoints: [])
    #expect(try await !database.holdsUnverifiablePairing())
    // The same device with another key (a Dev build on this library) signs a valid entry too.
    let rekeyed = Self.member(.mac, id: own.deviceID)
    try await MemberDirectory(database: database, identity: rekeyed).ensureSelf(name: "Studio", endpoints: [])
    #expect(try await database.libraryMemberRecords().entries.first { $0.deviceID == own.deviceID }?.publicKey == rekeyed.publicKey)
    #expect(try await !database.holdsUnverifiablePairing())
    try await database.saveLibraryMemberEntries([try OtherBuild.entry(own, name: "Studio", by: own, at: now + 60_000)])
    #expect(try await database.holdsUnverifiablePairing())
  }
}

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

/// In-process network of members. Each endpoint host (`<name>.ts.net`)
/// routes to one peer's handler; Linux hosts sit behind a Serve-style
/// `/wovenmatter` strip.
private actor Network {
  var handlers: [String: LibraryPeerSync] = [:]
  var offline: Set<String> = []
  var routed: [String: Int] = [:]
  /// Each reply is delayed by this long after the request was handled.
  var latency: Duration = .zero
  func register(_ host: String, _ sync: LibraryPeerSync) { handlers[host] = sync }
  func setOffline(_ hosts: Set<String>) { offline = hosts }
  func setLatency(_ value: Duration) { latency = value }
  /// An offline device neither answers nor sends.
  func route(from caller: String, _ endpoint: URL, _ request: CompanionHTTPRequest) async throws -> CompanionHTTPResponse {
    let host = endpoint.host.map { $0.hasSuffix(".ts.net") ? String($0.dropLast(".ts.net".count)) : $0 } ?? ""
    routed[host, default: 0] += 1
    guard !offline.contains(caller), !offline.contains(host), let handler = handlers[host] else { throw URLError(.cannotConnectToHost) }
    var target = request.target
    if endpoint.path.hasPrefix("/wovenmatter") { target = String(target.dropFirst("/wovenmatter".count)) }
    let lowered = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.key.lowercased(), $0.value) })
    let response = await handler.handle(.init(method: request.method, target: target, headers: lowered, body: request.body))
    if latency > .zero { try await Task.sleep(for: latency) }
    // A device that went offline mid-request never receives the reply.
    guard !offline.contains(caller), !offline.contains(host) else { throw URLError(.networkConnectionLost) }
    return response ?? .error("not_found", "Unrouted", status: 404)
  }
}

private struct Member {
  let persistence: PersistenceFixture
  let database: WorkspaceDatabase
  let identity: MemberIdentity
  let directory: MemberDirectory
  let sync: LibraryPeerSync
  let host: String
  let endpoint: URL
  var id: String { identity.deviceID }

  init(_ host: String, kind: MemberKind, network: Network, presence: TimeInterval = 3600) async throws {
    persistence = try PersistenceFixture()
    database = try await persistence.openDatabase()
    let deviceID = try await database.companionLibraryIdentity().hostDeviceID
    identity = MemberIdentity(deviceID: deviceID, kind: kind, key: Curve25519.Signing.PrivateKey())
    directory = MemberDirectory(database: database, identity: identity, cacheLifetime: 0)
    var configuration = LibraryPeerSync.Configuration(version: "test")
    configuration.presenceInterval = presence; configuration.announceDelay = 0.05
    let network = network
    sync = LibraryPeerSync(directory: directory, transport: .init { try await network.route(from: host, $0, $1) }, configuration: configuration)
    self.host = host
    endpoint = URL(string: kind == .linux ? "https://\(host).ts.net/wovenmatter/" : "https://\(host).ts.net/wovenmatter")!
    try await directory.ensureSelf(name: host, endpoints: [endpoint])
    await network.register(host, sync)
  }

  func note(_ id: String, _ title: String) async throws {
    let content = try NoteDocument(blocks: [.richText(.init(text: title))]).encoded()
    let receipt = try await database.applyCompanionMutation(.init(deviceID: self.id, kind: .createNote, resourceID: id, title: title, content: content))
    #expect(receipt.status == .accepted)
  }
  func has(_ note: String) async -> Bool { (try? await database.companionNote(id: note)) != nil }
  func remove() async { await sync.stop(); persistence.remove() }

  /// Mac-side pairing result: this Mac signs the other device's entry.
  func add(_ other: Member, kind: MemberKind? = nil) async throws {
    try await directory.add(deviceID: other.id, kind: kind ?? other.identity.kind, name: other.host,
                            publicKey: other.identity.publicKey, endpoints: other.identity.kind == .ios ? [] : [other.endpoint])
  }
}

@Suite("Members and change-driven peer sync", .serialized)
struct MemberSyncTests {
  /// Three Macs, two Linux hosts and a phone, paired the way the UI does:
  /// Mac pairs sign each other; Linux hosts adopt Mac 1's records.
  private static func mesh(presence: TimeInterval = 3600) async throws -> (Network, [Member], phone: MemberIdentity) {
    let network = Network()
    let mac1 = try await Member("mac1.test", kind: .mac, network: network, presence: presence)
    let mac2 = try await Member("mac2.test", kind: .mac, network: network, presence: presence)
    let mac3 = try await Member("mac3.test", kind: .mac, network: network, presence: presence)
    let linux1 = try await Member("linux1.test", kind: .linux, network: network, presence: presence)
    let linux2 = try await Member("linux2.test", kind: .linux, network: network, presence: presence)
    for mac in [mac2, mac3] { try await mac1.add(mac); try await mac.add(mac1) }
    try await mac1.add(linux1); try await mac2.add(linux2)
    let phone = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .ios, key: Curve25519.Signing.PrivateKey())
    try await mac3.directory.add(deviceID: phone.deviceID, kind: .ios, name: "iPhone", publicKey: phone.publicKey, endpoints: [])
    // Linux hosts receive their adding Mac's records over the trusted local channel.
    _ = try await linux1.directory.adopt(try await mac1.directory.adoption())
    _ = try await linux2.directory.adopt(try await mac2.directory.adoption())
    return (network, [mac1, mac2, mac3, linux1, linux2], phone)
  }

  private static func settle(_ members: [Member], _ condition: @escaping (Member) async -> Bool) async throws -> Bool {
    try await pollUntil(attempts: 300, interval: .milliseconds(50)) {
      for member in members where !(await condition(member)) { return false }
      return true
    }
  }

  /// The vectors the Node server also checks, verified with this
  /// platform's Ed25519 (swift-crypto on Linux, CryptoKit on Apple).
  @Test func sharedVectorsVerifyWithThisPlatformsEd25519() async throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../shared/Tests/WovenMatterCompanionTests/MemberSignatureVectors.json").standardizedFileURL
    let vectors = try #require(try JSONDecoder().decode(GatewayJSONValue.self, from: Data(contentsOf: url)).objectValue)
    let key = try #require(vectors["publicKeyBase64"]?.stringValue.flatMap { Data(base64Encoded: $0) })
    let device = try #require(vectors["deviceID"]?.stringValue), audience = try #require(vectors["audience"]?.stringValue)
    for vector in try #require(vectors["cases"]?.arrayValue).compactMap(\.objectValue) {
      let time = Int64(try #require(vectors["windowMilliseconds"] != nil ? vector["time"]?.doubleValue : nil))
      let headers = try #require(vector["headers"]?.objectValue).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.stringValue }
      let verifier = { (own: String) in MemberRequestVerifier(audience: own,
        lookup: { $0 == device ? MemberKey(deviceID: device, kind: .linux, name: "Vector", publicKey: key) : nil },
        verify: { MemberIdentity.verify(publicKey: $0, signature: $1, message: $2) }, clock: { time }) }
      let method = try #require(vector["method"]?.stringValue), target = try #require(vector["target"]?.stringValue)
      let body = Data(try #require(vector["body"]?.stringValue).utf8)
      let member = try await verifier(audience).verify(method: method, target: target, headers: headers, body: body)
      #expect(member.deviceID == device)
      // The same request presented to any other member is refused.
      await #expect(throws: MemberRequestError.audience) {
        try await verifier(UUID().uuidString.lowercased()).verify(method: method, target: target, headers: headers, body: body)
      }
    }
  }

  /// Upgrade proof on a copy of a real library (never a production path):
  /// opening runs every migration; the caller compares tables before and after.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WOVENMATTER_MIGRATION_PROOF_DB"] != nil))
  func migratesACopiedLibraryInPlace() async throws {
    let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WOVENMATTER_MIGRATION_PROOF_DB"]))
    #expect(!url.path.contains("/Library/Application Support/Woven Matter"))
    let database = try await WorkspaceDatabase(url: url)
    let identity = MemberIdentity(deviceID: try await database.companionLibraryIdentity().hostDeviceID, kind: .mac, key: .init())
    try await MemberDirectory(database: database, identity: identity).ensureSelf(name: "Proof", endpoints: [])
    #expect(try await database.libraryMembers().members.map(\.deviceID) == [identity.deviceID])
  }

  @Test func memberResolutionFollowsSignaturesAnchorsAndRemovals() throws {
    let mac = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
    let other = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
    let phone = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .ios, key: .init())
    let host = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .linux, key: .init())
    let endpoint = URL(string: "https://other.test/")!
    let otherEntry = try LibraryMemberEntry.signed(deviceID: other.deviceID, kind: .mac, name: "Other", publicKey: other.publicKey, endpoints: [endpoint], by: mac, at: 10)
    let phoneEntry = try LibraryMemberEntry.signed(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: phone.publicKey, endpoints: [], by: other, at: 20)
    // A phone cannot promote itself, nor can it add devices.
    let promoted = try LibraryMemberEntry.signed(deviceID: phone.deviceID, kind: .mac, name: "Renamed", publicKey: phone.publicKey, endpoints: [], by: phone, at: 30)
    let byPhone = try LibraryMemberEntry.signed(deviceID: host.deviceID, kind: .linux, name: "Host", publicKey: host.publicKey, endpoints: [], by: phone, at: 31)
    var members = LibraryMemberResolver.resolve(entries: [otherEntry, phoneEntry, promoted, byPhone], revocations: [], anchors: [mac.anchor])
    #expect(Set(members.map(\.deviceID)) == [mac.deviceID, other.deviceID, phone.deviceID])
    let resolvedPhone = try #require(members.first { $0.deviceID == phone.deviceID })
    #expect(resolvedPhone.kind == .ios && resolvedPhone.name == "Renamed" && resolvedPhone.addedBy == other.deviceID)
    // A forged signature never adds anyone.
    let forged = LibraryMemberEntry(deviceID: host.deviceID, kind: .linux, name: "Host", publicKey: host.publicKey, endpoints: [],
      addedBy: mac.deviceID, addedAt: 40, signature: phoneEntry.signature)
    #expect(!LibraryMemberResolver.resolve(entries: [forged], revocations: [], anchors: [mac.anchor]).contains { $0.deviceID == host.deviceID })
    // Everything a removed Mac signed is void, whatever its date: the phone
    // it added drops out until a standing Mac re-signs it (MemberDirectory
    // .remove does), and its later entries never count.
    let removeOther = try LibraryMemberRevocation.signed(deviceID: other.deviceID, by: mac, at: 50)
    let late = try LibraryMemberEntry.signed(deviceID: host.deviceID, kind: .linux, name: "Host", publicKey: host.publicKey, endpoints: [], by: other, at: 60)
    members = LibraryMemberResolver.resolve(entries: [otherEntry, phoneEntry, late], revocations: [removeOther], anchors: [mac.anchor], own: mac.deviceID)
    #expect(members.first { $0.deviceID == other.deviceID }?.revoked == true)
    #expect(!members.contains { $0.deviceID == phone.deviceID })
    #expect(!members.contains { $0.deviceID == host.deviceID })
    let kept = try LibraryMemberEntry.signed(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: phone.publicKey, endpoints: [], by: mac, at: 51)
    members = LibraryMemberResolver.resolve(entries: [otherEntry, phoneEntry, kept], revocations: [removeOther], anchors: [mac.anchor], own: mac.deviceID)
    #expect(members.first { $0.deviceID == phone.deviceID }?.revoked == false)
    // A newer entry from an unremoved Mac re-adds.
    let readd = try LibraryMemberEntry.signed(deviceID: other.deviceID, kind: .mac, name: "Other", publicKey: other.publicKey, endpoints: [endpoint], by: mac, at: 70)
    members = LibraryMemberResolver.resolve(entries: [readd, phoneEntry], revocations: [removeOther], anchors: [mac.anchor])
    #expect(members.first { $0.deviceID == other.deviceID }?.revoked == false)
    // Two keys for one device: not trusted.
    let conflicting = try LibraryMemberEntry.signed(deviceID: phone.deviceID, kind: .ios, name: "Phone", publicKey: host.publicKey, endpoints: [], by: mac, at: 80)
    members = LibraryMemberResolver.resolve(entries: [otherEntry, phoneEntry, conflicting], revocations: [], anchors: [mac.anchor])
    #expect(!members.contains { $0.deviceID == phone.deviceID })
  }

  @Test func everyMemberConvergesThroughAnnouncementsWithoutPolling() async throws {
    let (_, members, phone) = try await Self.mesh()
    defer { Task { for member in members { await member.remove() } } }
    for member in members { await member.sync.start() }
    // Coming online catches up once; membership itself spreads this way.
    #expect(try await Self.settle(members) { member in
      let list = (try? await member.directory.list().members.filter { !$0.revoked }.count) ?? 0
      return list == 6
    })
    #expect(try await Self.settle(members) { $0.identity.kind == .linux ? true : await $0.directory.member(phone.deviceID)?.kind == .ios })
    let note = UUID().uuidString.lowercased()
    try await members[0].note(note, "Written on Mac 1")
    #expect(try await Self.settle(members) { await $0.has(note) })
    for member in members { #expect(await member.sync.exchanges["presence", default: 0] == 0) }
    let notices = await withTaskGroup(of: Int.self) { group in
      for member in members { group.addTask { await member.sync.exchanges["notice", default: 0] } }
      return await group.reduce(0, +)
    }
    #expect(notices > 0)
  }

  @Test func linuxHostsSynchronizeWithEveryMacOffline() async throws {
    let (network, members, _) = try await Self.mesh()
    defer { Task { for member in members { await member.remove() } } }
    for member in members { await member.sync.start() }
    #expect(try await Self.settle(members) { (try? await $0.directory.list().members.filter { !$0.revoked }.count) == 6 })
    // Wait for each Linux host to have reached the other once.
    let linux1 = members[3], linux2 = members[4]
    #expect(try await Self.settle([linux1, linux2]) { member in
      await member.sync.status().peers.first { $0.kind == .linux }?.state == .online
    })
    await network.setOffline(["mac1.test", "mac2.test", "mac3.test"])
    let note = UUID().uuidString.lowercased()
    try await linux1.note(note, "Written on Linux 1")
    #expect(try await Self.settle([linux2]) { await $0.has(note) })
    for mac in members[0..<3] { #expect(await !mac.has(note)) }
    // A Mac coming back is caught up by its next contact.
    await network.setOffline([])
    await members[0].sync.scheduleSync(linux2.id, reason: "test")
    #expect(try await Self.settle([members[0]]) { await $0.has(note) })
  }

  @Test func removalPropagatesAndEndsAccess() async throws {
    let (_, members, _) = try await Self.mesh()
    defer { Task { for member in members { await member.remove() } } }
    for member in members { await member.sync.start() }
    #expect(try await Self.settle(members) { (try? await $0.directory.list().members.filter { !$0.revoked }.count) == 6 })
    let linux2 = members[4]
    try await members[1].directory.remove(linux2.id)
    let others = Array(members[0..<4])
    #expect(try await Self.settle(others) { await $0.directory.member(linux2.id) == nil })
    // The removed host can no longer exchange with anyone.
    let note = UUID().uuidString.lowercased()
    try await linux2.note(note, "After removal")
    for member in others { await linux2.sync.scheduleSync(member.id, reason: "test") }
    try await Task.sleep(for: .milliseconds(500))
    for member in others { #expect(await !member.has(note)) }
  }

  /// A Mac removed while a Linux host is offline: the host applies it when it
  /// is back, and keeps the phone the removed Mac added (re-signed by the remover).
  @Test func removalReachesAnOfflineHostAndKeepsWhatTheRemovedMacAdded() async throws {
    let (network, members, phone) = try await Self.mesh()
    defer { Task { for member in members { await member.remove() } } }
    for member in members { await member.sync.start() }
    #expect(try await Self.settle(members) { (try? await $0.directory.list().members.filter { !$0.revoked }.count) == 6 })
    let mac1 = members[0], mac3 = members[2], linux1 = members[3]
    await network.setOffline(["linux1.test"])
    try await mac1.directory.remove(mac3.id)
    let others = [members[0], members[1], members[4]]
    #expect(try await Self.settle(others) { await $0.directory.member(mac3.id) == nil })
    #expect(await linux1.directory.member(mac3.id) != nil, "offline, the host has not heard yet")
    await network.setOffline([])
    await mac1.sync.scheduleSync(linux1.id, reason: "test")
    #expect(try await Self.settle([linux1]) { await $0.directory.member(mac3.id) == nil })
    for member in members where member.id != mac3.id {
      #expect(await member.directory.member(phone.deviceID)?.addedBy == mac1.id, "\(member.host) keeps the phone")
    }
  }

  /// Endpoints are self-advertised: peer sync never follows one outside the tailnet.
  @Test func peerSyncSendsOnlyToTailnetEndpoints() async throws {
    #expect(LibraryPeerSync.isTailnetEndpoint(URL(string: "https://mac.tail1.ts.net:8443/wovenmatter")!))
    for bad in ["http://mac.tail1.ts.net/wovenmatter", "https://127.0.0.1/wovenmatter", "https://localhost/", "https://evil.example/ts.net",
                "https://user:pass@mac.tail1.ts.net/", "https://mac.tail1.ts.net/?x=1"] {
      #expect(!LibraryPeerSync.isTailnetEndpoint(URL(string: bad)!), "\(bad)")
    }
    let network = Network()
    let a = try await Member("a", kind: .mac, network: network), b = try await Member("b", kind: .mac, network: network)
    defer { Task { await a.remove(); await b.remove() } }
    try await a.directory.add(deviceID: b.id, kind: .mac, name: "b", publicKey: b.identity.publicKey, endpoints: [URL(string: "http://b/wovenmatter")!])
    try await b.directory.ensureSelf(name: "b", endpoints: [URL(string: "http://b/wovenmatter")!])
    let member = try #require(await a.directory.member(b.id))
    await a.sync.synchronize(with: member)
    #expect(await network.routed["b", default: 0] == 0)
  }

  /// "Sync now" while a notice arrives: the notice runs once more afterwards.
  @Test func aNoticeDuringSyncNowIsNotDropped() async throws {
    let network = Network()
    let a = try await Member("a", kind: .mac, network: network), b = try await Member("b", kind: .mac, network: network)
    defer { Task { await a.remove(); await b.remove() } }
    try await a.add(b); try await b.add(a)
    await a.sync.start(); await b.sync.start()
    #expect(try await Self.settle([a, b]) { await $0.sync.status().peers.first?.state == .online })
    try await Task.sleep(for: .milliseconds(300))
    await network.setLatency(.milliseconds(400))
    let note = UUID().uuidString.lowercased()
    async let now: Void = a.sync.synchronizeAll()
    try await Task.sleep(for: .milliseconds(100))
    try await b.note(note, "Written during Sync now")
    await now
    await network.setLatency(.zero)
    #expect(try await Self.settle([a]) { await $0.has(note) })
  }

  /// Waking or a network change resets the offline backoff and catches up at once.
  @Test func resumingCatchesUpWithOfflinePeers() async throws {
    let network = Network()
    let a = try await Member("a", kind: .mac, network: network), b = try await Member("b", kind: .mac, network: network)
    defer { Task { await a.remove(); await b.remove() } }
    try await a.add(b); try await b.add(a)
    await network.setOffline(["b"])
    await a.sync.start()
    #expect(try await Self.settle([a]) { await $0.sync.status().peers.first?.state == .offline })
    let note = UUID().uuidString.lowercased()
    try await b.note(note, "Written while away")
    await network.setOffline([])
    await a.sync.resume(reason: "wake")
    #expect(try await Self.settle([a]) { await $0.has(note) })
    #expect(await a.sync.exchanges["wake", default: 0] >= 1)
  }

  /// A Linux host relays every row, but may write registry and ownership rows
  /// only for what it serves: it cannot point a Mac's workspace at itself.
  @Test func aLinuxHostCannotTakeOverAMacsWorkspace() async throws {
    let (_, members, _) = try await Self.mesh()
    defer { Task { for member in members { await member.remove() } } }
    for member in members { await member.sync.start() }
    #expect(try await Self.settle(members) { (try? await $0.directory.list().members.filter { !$0.revoked }.count) == 6 })
    let mac1 = members[0], mac2 = members[1], linux1 = members[3]
    let library = try await mac1.database.companionLibraryIdentity().libraryID
    func insert(_ workspace: CompanionExecutionWorkspace, into member: Member) async throws {
      let payload = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)
      try await member.database.write { connection in
        try connection.toolsExecuteUnlocked("INSERT INTO companion_execution_workspaces(id,owner_device_id,revision,deleted,payload) VALUES(?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload",
                                            [workspace.id, workspace.ownerDeviceID, String(workspace.revision), payload])
      }
    }
    let macWorkspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: library, ownerDeviceID: mac1.id, kind: .mac,
      name: "Mac 1", endpoint: URL(string: "https://mac1.test.ts.net/wovenmatter"), executionDeviceID: mac1.id, revision: 1)
    try await insert(macWorkspace, into: mac1)
    #expect(try await Self.settle([mac2, linux1]) { (try? await $0.database.companionExecutionWorkspaces().contains { $0.id == macWorkspace.id }) == true })
    // The host rewrites the Mac's registration to name itself.
    var forged = macWorkspace; forged.executionDeviceID = linux1.id; forged.revision = 2
    try await insert(forged, into: linux1)
    // Its own workspace's registration goes through.
    let own = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: library, ownerDeviceID: mac1.id, kind: .linux,
      name: "Linux 1", endpoint: URL(string: "https://linux1.test.ts.net/wovenmatter-execution/one"), executionDeviceID: UUID().uuidString.lowercased(), revision: 1)
    try await insert(own, into: linux1)
    #expect(try await Self.settle([mac2]) { (try? await $0.database.companionExecutionWorkspaces().contains { $0.id == own.id }) == true })
    let seen = try #require(try await mac2.database.companionExecutionWorkspaces().first { $0.id == macWorkspace.id })
    #expect(seen.executionDeviceID == mac1.id && seen.revision == 1)
    #expect(await mac2.directory.audience(for: seen) == mac1.id)
  }

  @Test func differentSchemasReportUpdateRequired() async throws {
    let network = Network()
    let a = try await Member("a.test", kind: .mac, network: network), b = try await Member("b.test", kind: .mac, network: network)
    defer { Task { await a.remove(); await b.remove() } }
    try await a.add(b); try await b.add(a)
    let page = PairedLibraryPage(schema: "older", entries: [], cursor: 0, hasMore: false)
    let body = try JSONEncoder().encode(LibraryPeerExchange(deviceID: b.id, after: 0, page: page, version: "0.9"))
    var headers = try b.identity.signer.headers(method: "POST", target: "/v1/peers/sync", body: body, audience: a.id)
    headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    let response = try #require(await a.sync.handle(.init(method: "POST", target: "/v1/peers/sync", headers: headers, body: body)))
    #expect(response.status == 409)
    let mismatch = try JSONDecoder().decode(LibraryPeerUpdateRequired.self, from: response.body)
    #expect(mismatch.code == "update_required" && mismatch.version == "test")
    let status = await a.sync.status()
    #expect(status.updateRequired && status.peers.first?.version == "0.9")
    // Unsigned or replayed requests are refused.
    #expect(await a.sync.handle(.init(method: "POST", target: "/v1/peers/sync", headers: [:], body: body)) == nil)
    let replay = try #require(await a.sync.handle(.init(method: "POST", target: "/v1/peers/sync", headers: headers, body: body)))
    #expect(replay.status == 401)
  }
}

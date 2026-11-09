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

/// In-process network of members. Each endpoint host routes to one peer's
/// handler; Linux hosts sit behind a Serve-style `/wovenmatter` strip.
private actor Network {
  var handlers: [String: LibraryPeerSync] = [:]
  var offline: Set<String> = []
  func register(_ host: String, _ sync: LibraryPeerSync) { handlers[host] = sync }
  func setOffline(_ hosts: Set<String>) { offline = hosts }
  /// An offline device neither answers nor sends.
  func route(from caller: String, _ endpoint: URL, _ request: CompanionHTTPRequest) async throws -> CompanionHTTPResponse {
    guard !offline.contains(caller), let host = endpoint.host, !offline.contains(host), let handler = handlers[host] else { throw URLError(.cannotConnectToHost) }
    var target = request.target
    if endpoint.path.hasPrefix("/wovenmatter") { target = String(target.dropFirst("/wovenmatter".count)) }
    let lowered = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.key.lowercased(), $0.value) })
    let response = await handler.handle(.init(method: request.method, target: target, headers: lowered, body: request.body))
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
    endpoint = URL(string: kind == .linux ? "https://\(host)/wovenmatter/" : "https://\(host)/")!
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
    let device = try #require(vectors["deviceID"]?.stringValue)
    for vector in try #require(vectors["cases"]?.arrayValue).compactMap(\.objectValue) {
      let time = Int64(try #require(vectors["windowMilliseconds"] != nil ? vector["time"]?.doubleValue : nil))
      let headers = try #require(vector["headers"]?.objectValue).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.stringValue }
      let verifier = MemberRequestVerifier(lookup: { $0 == device ? MemberKey(deviceID: device, kind: .linux, name: "Vector", publicKey: key) : nil },
        verify: { MemberIdentity.verify(publicKey: $0, signature: $1, message: $2) }, clock: { time })
      let member = try await verifier.verify(method: try #require(vector["method"]?.stringValue), target: try #require(vector["target"]?.stringValue),
                                             headers: headers, body: Data(try #require(vector["body"]?.stringValue).utf8))
      #expect(member.deviceID == device)
    }
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
    // Removing the Mac that added the phone keeps the phone; the Mac's later entries are void.
    let removeOther = try LibraryMemberRevocation.signed(deviceID: other.deviceID, by: mac, at: 50)
    let late = try LibraryMemberEntry.signed(deviceID: host.deviceID, kind: .linux, name: "Host", publicKey: host.publicKey, endpoints: [], by: other, at: 60)
    members = LibraryMemberResolver.resolve(entries: [otherEntry, phoneEntry, late], revocations: [removeOther], anchors: [mac.anchor])
    #expect(members.first { $0.deviceID == other.deviceID }?.revoked == true)
    #expect(members.first { $0.deviceID == phone.deviceID }?.revoked == false)
    #expect(!members.contains { $0.deviceID == host.deviceID })
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

  @Test func differentSchemasReportUpdateRequired() async throws {
    let network = Network()
    let a = try await Member("a.test", kind: .mac, network: network), b = try await Member("b.test", kind: .mac, network: network)
    defer { Task { await a.remove(); await b.remove() } }
    try await a.add(b); try await b.add(a)
    let page = PairedLibraryPage(schema: "older", entries: [], cursor: 0, hasMore: false)
    let body = try JSONEncoder().encode(LibraryPeerExchange(deviceID: b.id, after: 0, page: page, version: "0.9"))
    var headers = try b.identity.signer.headers(method: "POST", target: "/v1/peers/sync", body: body)
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

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

/// The in-memory roster of client-mode Dev stream keys a live host admits
/// ("Client mode", docs/DEVELOPMENT_BUILDS.md). Portable: the Linux build
/// compiles it with the library daemon, though only a Mac serves Dev clients.
@Suite struct DevelopmentStreamRosterTests {
  private let target = "/v1/stream?protocol=1"

  private func request(_ identity: MemberIdentity, audience: String) throws -> LibraryHTTPRequest {
    let headers = try identity.signer.headers(method: "GET", target: target, audience: audience)
    return .init(method: "GET", target: target, headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }))
  }

  @Test func onlyAdmittedKeysVerifyAndNothingReachesTheMemberList() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let host = MemberIdentity(deviceID: try await database.libraryIdentity().hostDeviceID, kind: .mac, key: .init())
    let directory = MemberDirectory(database: database, identity: host, cacheLifetime: 0)
    try await directory.ensureSelf(name: "Live host", endpoints: [])
    let before = try await database.libraryMemberRecords()
    let roster = DevelopmentStreamRoster(audience: host.deviceID)
    let dev = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
    try await roster.admit(deviceID: dev.deviceID, name: "Dev · fixture", publicKey: dev.publicKey)

    let member = try await roster.authenticate(try request(dev, audience: host.deviceID))
    #expect(member.deviceID == dev.deviceID && member.kind == .mac && !member.revoked)
    // In memory only: the signed member list and anchors are untouched, and
    // the member directory does not know the Dev device.
    let after = try await database.libraryMemberRecords()
    #expect(after.entries == before.entries && after.revocations == before.revocations && after.anchors == before.anchors)
    #expect(await directory.member(dev.deviceID) == nil)
    #expect(try await directory.list().members.allSatisfy { $0.publicKey != dev.publicKey })

    // A key the roster does not hold, a signature for another audience, and
    // a replayed signature are refused.
    let stranger = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
    await #expect(throws: MemberRequestError.unknown) { try await roster.authenticate(try request(stranger, audience: host.deviceID)) }
    await #expect(throws: MemberRequestError.audience) {
      try await roster.authenticate(try request(dev, audience: UUID().uuidString.lowercased()))
    }
    let once = try request(dev, audience: host.deviceID)
    _ = try await roster.authenticate(once)
    await #expect(throws: MemberRequestError.replay) { try await roster.authenticate(once) }
    // The host's own ID is never a Dev identity.
    await #expect(throws: LibraryAPIError.self) { try await roster.admit(deviceID: host.deviceID, name: "Dev · self", publicKey: dev.publicKey) }
  }

  @Test func revocationAndReplacementNotifyAndStopVerification() async throws {
    let roster = DevelopmentStreamRoster(audience: UUID().uuidString.lowercased())
    let removals = Removals()
    await roster.observeRemovals { removals.append($0, $1) }
    let dev = MemberIdentity(deviceID: UUID().uuidString.lowercased(), kind: .mac, key: .init())
    try await roster.admit(deviceID: dev.deviceID, name: "Dev · fixture", publicKey: dev.publicKey)
    try await roster.admit(deviceID: dev.deviceID, name: "Dev · fixture", publicKey: dev.publicKey)
    #expect(removals.all.isEmpty, "admitting the same key again changes nothing")
    let next = MemberIdentity(deviceID: dev.deviceID, kind: .mac, key: .init())
    try await roster.admit(deviceID: dev.deviceID, name: "Dev · fixture", publicKey: next.publicKey)
    #expect(removals.all.map(\.1) == [.replaced])
    await #expect(throws: MemberRequestError.self) { try await roster.authenticate(try request(dev, audience: roster.audience)) }
    _ = try await roster.authenticate(try request(next, audience: roster.audience))
    await roster.revoke(dev.deviceID)
    #expect(removals.all.map(\.1) == [.replaced, .revoked])
    await #expect(throws: MemberRequestError.unknown) { try await roster.authenticate(try request(next, audience: roster.audience)) }
    await roster.revoke(dev.deviceID)
    #expect(removals.all.count == 2, "revoking an absent key notifies nothing")
  }
}

private final class Removals: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [(String, DevelopmentStreamRoster.Removal)] = []
  var all: [(String, DevelopmentStreamRoster.Removal)] { lock.lock(); defer { lock.unlock() }; return values }
  func append(_ id: String, _ removal: DevelopmentStreamRoster.Removal) { lock.lock(); values.append((id, removal)); lock.unlock() }
}

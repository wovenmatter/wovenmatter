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

/// A paired Mac for fixtures: canonical UUIDs, a signing key and a local store.
struct PeerIdentityFixture {
  let id = UUID().uuidString.lowercased()
  let library = UUID().uuidString.lowercased()
  let key = Curve25519.Signing.PrivateKey()
  var publicKey: Data { key.publicKey.rawRepresentation }
  var own: PeerSelf { .init(deviceID: id, libraryID: library, key: key) }
  var route: PairedMacRoute { .init(deviceID: id, libraryID: library, endpoint: URL(string: "https://m\(id.prefix(8)).fixture.ts.net/wovenmatter")!, name: "Mac " + id.prefix(4)) }
  func subjectSignature(issuer: PeerIdentityFixture, acknowledged: [String]) throws -> Data {
    try key.signature(for: PeerAdmission.subjectStatement(issuerDeviceID: issuer.id, issuerLibraryID: issuer.library, subjectDeviceID: id,
      subjectLibraryID: library, subjectPublicKey: publicKey, acknowledgedRevocations: acknowledged))
  }
}

@Suite("Signed paired Mac identity", .serialized)
struct PairedMacIdentityTests {
  private let directory = FileManager.default.temporaryDirectory.appending(path: "paired-identity-" + UUID().uuidString)
  private func store(_ name: String) throws -> DeviceAuthentication {
    try DeviceAuthentication(fileURL: directory.appending(path: name + ".json"))
  }
  private func secret() -> String { (0..<2).map { _ in UUID().uuidString }.joined() }

  /// Explicit approval on `issuer`, then the signed join and reciprocal grant.
  /// Returns the bearer `requester` uses at `issuer` and the one `issuer` uses at `requester`.
  @discardableResult
  private func pair(_ requester: (DeviceAuthentication, PeerIdentityFixture), with issuer: (DeviceAuthentication, PeerIdentityFixture)) async throws -> (atIssuer: String, atRequester: String) {
    await requester.0.useIdentity(requester.1.own); await issuer.0.useIdentity(issuer.1.own)
    let offer = try await issuer.0.createOffer(endpoint: issuer.1.route.endpoint)
    let response = try await issuer.0.pairConfirmed(.init(token: offer.payload.token, deviceID: requester.1.id, deviceName: "Mac",
      metadata: .init(kind: .mac), purpose: PairingPurpose.peerMac), workspaceID: issuer.1.library)
    let principal = try await issuer.0.authenticate(bearer: response.credential)
    let context = try await issuer.0.joinContext(for: principal)
    let reciprocal = secret()
    let join = PairedMacJoin(route: requester.1.route, returnCredential: reciprocal, publicKey: requester.1.publicKey,
      acknowledgedRevocations: context, subjectSignature: try requester.1.subjectSignature(issuer: issuer.1, acknowledged: context),
      reciprocalRevocations: await requester.0.revocationContext(for: issuer.1.id))
    try await issuer.0.admitJoin(principal, join: join, own: issuer.1.own)
    try await requester.0.enrollPeer(route: issuer.1.route, token: reciprocal, publicKey: issuer.1.publicKey,
      subjectSignature: issuer.1.subjectSignature(issuer: requester.1, acknowledged: join.reciprocalRevocations),
      acknowledgedRevocations: join.reciprocalRevocations, own: requester.1.own)
    return (response.credential, reciprocal)
  }
  @Test func bearersAuthenticateOnlyAtTheMacThatIssuedThem() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture()
    let air = try store("air"), mini = try store("mini"), third = try store("third")
    try await pair((mini, b), with: (air, a))
    let thirdTokens = try await pair((third, c), with: (air, a))
    // A phone paired with the Air.
    let offer = try await air.createOffer(endpoint: a.route.endpoint)
    let phone = try await air.pairConfirmed(.init(token: offer.payload.token, deviceID: UUID().uuidString.lowercased(), deviceName: "Phone",
      metadata: .init(kind: .iPhone)), workspaceID: a.library)
    try await mini.mergeMembership(air.peerMembership(), own: b.own)
    // The Mini knows C as an admitted Mac and the phone by name, but no bearer
    // the Air issued or minted authenticates at the Mini.
    #expect(await mini.isActiveMac(c.id))
    for bearer in [thirdTokens.atIssuer, thirdTokens.atRequester, phone.credential] {
      await #expect(throws: LibraryAPIError.self) { try await mini.authenticate(bearer: bearer) }
    }
    // A phone bearer that later claims Mac metadata never becomes a peer.
    let phonePrincipal = try await air.authenticate(bearer: phone.credential, metadata: .init(kind: .mac))
    #expect(phonePrincipal.kind == .mac)
    #expect(await !air.isAuthorizedPeer(phonePrincipal))
    await #expect(throws: LibraryAPIError.self) { try await air.joinContext(for: phonePrincipal) }
  }

  @Test func distinctConcurrentUnpairsAllRevokeAndOnlyAFreshPairingAcknowledgingThemSurvives() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture()
    let air = try store("air"), mini = try store("mini"), third = try store("third")
    try await pair((mini, b), with: (air, a)); try await pair((mini, b), with: (third, c)); try await pair((third, c), with: (air, a))
    // The Air and the third Mac unpair the Mini independently while offline.
    try await air.revoke(deviceID: b.id); try await third.revoke(deviceID: b.id)
    // The Mini pairs with the Air again, which has seen only its own unpair.
    let fresh = try await pair((mini, b), with: (air, a))
    #expect(try await air.authenticate(bearer: fresh.atIssuer).id == b.id)
    // The third Mac's distinct unpair arrives later: the fresh grant did not
    // acknowledge it, so it is revoked too.
    try await air.mergeMembership(third.peerMembership(), own: a.own)
    await #expect(throws: LibraryAPIError.self) { try await air.authenticate(bearer: fresh.atIssuer) }
    #expect(await !air.isActiveMac(b.id))
    // Pairing after learning both unpairs survives.
    let final = try await pair((mini, b), with: (air, a))
    #expect(try await air.authenticate(bearer: final.atIssuer).id == b.id)
    #expect(await air.isActiveMac(b.id))
    #expect(await air.revocationContext(for: b.id).count == 2)
  }

  @Test func admissionsBindTheirRevocationContextAndCannotBeRelabeledOrIntroducedByARevokedMac() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture(), d = PeerIdentityFixture(), e = PeerIdentityFixture()
    let mini = try store("mini"), third = try store("third"), other = try store("other"), early = try store("early")
    try await pair((third, c), with: (mini, b))
    try await pair((early, e), with: (third, c))
    try await mini.mergeMembership(third.peerMembership(), own: b.own)
    let beforeRevocation = await mini.peerMembership()
    // C introduces D, then the Mini unpairs C.
    try await pair((other, d), with: (third, c))
    try await mini.revoke(deviceID: c.id)
    let unpaired = await mini.peerMembership(), introduction = await third.peerMembership()
    for reversed in [false, true] {
      let receiver = try store("receiver-\(reversed)")
      try await pair((mini, b), with: (receiver, a))
      // One trust hop per exchange: C first, then E introduced by C.
      try await receiver.mergeMembership(beforeRevocation, own: a.own)
      #expect(await !receiver.isActiveMac(e.id))
      try await receiver.mergeMembership(beforeRevocation, own: a.own)
      #expect(await receiver.isActiveMac(c.id)); #expect(await receiver.isActiveMac(e.id))
      // One exchange carries both the unpair of C and C's new introduction of
      // D. The unpair applies first in every order: D is rejected, while E,
      // accepted earlier, stays admitted.
      let entries = introduction.entries + unpaired.entries
      try await receiver.mergeMembership(.init(entries: reversed ? entries.reversed() : entries,
        revocations: reversed ? unpaired.revocations.reversed() : unpaired.revocations), own: a.own)
      #expect(await !receiver.isActiveMac(d.id))
      #expect(await receiver.isActiveMac(e.id))
      #expect(await !receiver.isActiveMac(c.id))
      // Relabeling: re-signing C's old subject proof under the newer revocation
      // context fails, because C signed the context it acknowledged.
      let original = try #require(beforeRevocation.entries.first { $0.admission?.subjectDeviceID == c.id }?.admission)
      let relabeled = try PeerAdmission.issue(issuer: b.own, subjectDeviceID: c.id, subjectLibraryID: c.library, subjectPublicKey: c.publicKey,
        acknowledgedRevocations: await receiver.revocationContext(for: c.id), subjectSignature: original.subjectSignature)
      try await receiver.mergeMembership(.init(entries: [.init(deviceID: c.id, name: "Third", kind: .mac, introducedBy: b.id, admission: relabeled)],
        revocations: []), own: a.own)
      #expect(await !receiver.isActiveMac(c.id))
    }
  }

  @Test func membershipRejectsNonCanonicalIdentitiesAndUnboundedContexts() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture()
    let air = try store("air"), mini = try store("mini"), third = try store("third")
    try await pair((mini, b), with: (air, a)); try await pair((third, c), with: (mini, b))
    let admission = try #require(await mini.peerMembership().entries.first { $0.admission?.subjectDeviceID == c.id }?.admission)
    // The same signed admission in an uppercase envelope is not a second identity.
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(admission)) as? [String: Any])
    json["subjectDeviceID"] = c.id.uppercased()
    let upper = try JSONDecoder().decode(PeerAdmission.self, from: JSONSerialization.data(withJSONObject: json))
    try await air.mergeMembership(.init(entries: [.init(deviceID: c.id.uppercased(), name: "C", kind: .mac, introducedBy: b.id, admission: upper)], revocations: []), own: a.own)
    #expect(await !air.isActiveMac(c.id.uppercased())); #expect(await !air.isActiveMac(c.id))
    // A revocation in a non-canonical envelope is ignored, never half-applied.
    let event = try PeerRevocation.signed(deviceID: c.id.uppercased(), by: b.own)
    #expect(!event.isWellFormed)
    // Contexts beyond the bound are rejected.
    let large = (0..<(PeerIdentifier.maximumRevocationsPerDevice + 1)).map { _ in UUID().uuidString.lowercased() }.sorted()
    let bounded = PeerAdmission(issuerDeviceID: b.id, issuerLibraryID: b.library, subjectDeviceID: c.id, subjectLibraryID: c.library,
      subjectPublicKey: c.publicKey, acknowledgedRevocations: large, subjectSignature: Data(count: 64), issuerSignature: Data(count: 64))
    #expect(!bounded.isWellFormed)
    #expect(PeerIdentifier.canonical(c.id.uppercased()) == nil && PeerIdentifier.canonical(c.id) == c.id)
  }

  @Test func explicitJoinsAcceptOnlyTheirExactTranscript() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture()
    let air = try store("air"), mini = try store("mini"), third = try store("third")
    await air.useIdentity(a.own)
    let offer = try await air.createOffer(endpoint: a.route.endpoint)
    let response = try await air.pairConfirmed(.init(token: offer.payload.token, deviceID: b.id, deviceName: "Mini", metadata: .init(kind: .mac),
      purpose: PairingPurpose.peerMac), workspaceID: a.library)
    let principal = try await air.authenticate(bearer: response.credential)
    let context = try await air.joinContext(for: principal)
    let join = PairedMacJoin(route: b.route, returnCredential: secret(), publicKey: b.publicKey, acknowledgedRevocations: context,
      subjectSignature: try b.subjectSignature(issuer: a, acknowledged: context), reciprocalRevocations: [])
    try await air.admitJoin(principal, join: join, own: a.own)
    // A lost reply is retried with the identical transcript.
    try await air.admitJoin(principal, join: join, own: a.own)
    // Any change after admission, such as another reciprocal bearer, is rejected.
    let changed = PairedMacJoin(route: b.route, returnCredential: secret(), publicKey: b.publicKey, acknowledgedRevocations: context,
      subjectSignature: join.subjectSignature, reciprocalRevocations: [])
    await #expect(throws: LibraryAPIError.self) { try await air.admitJoin(principal, join: changed, own: a.own) }
    // A Mac learned through another Mac's membership holds no grant here.
    try await pair((third, c), with: (mini, b))
    try await air.mergeMembership(mini.peerMembership(), own: a.own)
    // A pin is never replaced while that Mac is still admitted.
    await #expect(throws: LibraryAPIError.self) {
      try await air.enrollPeer(route: c.route, token: secret(), publicKey: b.publicKey,
        subjectSignature: try b.key.signature(for: PeerAdmission.subjectStatement(issuerDeviceID: a.id, issuerLibraryID: a.library, subjectDeviceID: c.id,
          subjectLibraryID: c.library, subjectPublicKey: b.publicKey, acknowledgedRevocations: [])), acknowledgedRevocations: [], own: a.own)
    }
    // Restarting keeps the admission, the pin and the peer grant.
    let reopened = try store("air")
    #expect(await reopened.isAuthorizedPeer(principal))
  }

  @Test func aDescendantIntroducedWithItsIntroducersUnpairIsRejectedInEveryOrder() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture(), d = PeerIdentityFixture()
    let mini = try store("mini"), third = try store("third"), other = try store("other")
    try await pair((third, c), with: (mini, b))
    try await pair((other, d), with: (third, c))
    // C (unknown to the receiver) is introduced by B, introduces D, and its
    // own unpair is signed by C itself: all in one exchange.
    let introductions = (await mini.peerMembership().entries + third.peerMembership().entries).filter {
      $0.admission?.subjectDeviceID == c.id || $0.admission?.subjectDeviceID == d.id
    }
    let unpair = try PeerRevocation.signed(deviceID: c.id, by: c.own)
    for (index, order) in [introductions, introductions.reversed()].enumerated() {
      let receiver = try store("receiver-\(index)")
      try await pair((mini, b), with: (receiver, a))
      #expect(await !receiver.isActiveMac(c.id))
      // Repeated full membership: C is learned first; its own unpair applies on
      // the next exchange, before C could ever introduce D.
      for _ in 0..<3 {
        try await receiver.mergeMembership(.init(entries: order, revocations: [unpair]), own: a.own)
        #expect(await !receiver.isActiveMac(d.id))
      }
      #expect(await !receiver.isActiveMac(c.id))
    }
    // D accepted earlier, before C's unpair arrived, survives it.
    let earlier = try store("earlier")
    try await pair((mini, b), with: (earlier, a))
    for _ in 0..<2 { try await earlier.mergeMembership(.init(entries: introductions, revocations: []), own: a.own) }
    #expect(await earlier.isActiveMac(d.id))
    try await earlier.mergeMembership(.init(entries: [], revocations: [unpair]), own: a.own)
    #expect(await earlier.isActiveMac(d.id))
    #expect(await !earlier.isActiveMac(c.id))
  }

  @Test func aRevokedMacsNewUnpairsAreRejectedWhileAcceptedOnesPersistAndChainsAreOrderIndependent() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let a = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture(), x = PeerIdentityFixture()
    let receiver = try store("receiver"), air = try store("air"), mini = try store("mini"), third = try store("third")
    try await pair((air, a), with: (receiver, x)); try await pair((mini, b), with: (receiver, x)); try await pair((third, c), with: (receiver, x))
    // A unpairs C while A is still admitted: accepted.
    let earlier = try PeerRevocation.signed(deviceID: c.id, by: a.own)
    try await receiver.mergeMembership(.init(entries: [], revocations: [earlier]), own: x.own)
    #expect(await !receiver.isActiveMac(c.id))
    // The receiver unpairs A; A then mints a new unpair of B, relayed by a peer.
    try await receiver.revoke(deviceID: a.id)
    let late = try PeerRevocation.signed(deviceID: b.id, by: a.own)
    try await receiver.mergeMembership(.init(entries: [], revocations: [late]), own: x.own)
    #expect(await receiver.isActiveMac(b.id))
    #expect(await receiver.revocationContext(for: b.id).isEmpty)
    // The accepted earlier unpair remains, replayed or not.
    try await receiver.mergeMembership(.init(entries: [], revocations: [earlier]), own: x.own)
    #expect(await receiver.revocationContext(for: c.id) == [earlier.eventID])

    // Chained unpairs in one exchange: B unpairs A2 while A2 unpairs C2. Both
    // signers were admitted at entry, so both concurrent unpairs apply in
    // either order; topology is not treated as causal order.
    let a2 = PeerIdentityFixture(), c2 = PeerIdentityFixture()
    for (index, reversed) in [false, true].enumerated() {
      let target = try store("target-\(index)"), first = try store("a2-\(index)"), second = try store("c2-\(index)"), minis = try store("b-\(index)")
      try await pair((first, a2), with: (target, x)); try await pair((second, c2), with: (target, x)); try await pair((minis, b), with: (target, x))
      let events = [try PeerRevocation.signed(deviceID: a2.id, by: b.own), try PeerRevocation.signed(deviceID: c2.id, by: a2.own)]
      try await target.mergeMembership(.init(entries: [], revocations: reversed ? events.reversed() : events), own: x.own)
      #expect(await !target.isActiveMac(a2.id))
      #expect(await !target.isActiveMac(c2.id))
    }
  }

  @Test func oneTrustHopPerExchangeOrdersUnpairsBeforeIntroductionsInEveryArrangement() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let x = PeerIdentityFixture(), a = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture()
    // Entry-admitted A, B and C: A unpairs B while B unpairs C, and B and C unpair
    // each other. Every concurrent unpair applies, in either array order.
    for reversed in [false, true] {
      let receiver = try store("chain-\(reversed)"), first = try store("a-\(reversed)"), second = try store("b-\(reversed)"), third = try store("c-\(reversed)")
      try await pair((first, a), with: (receiver, x)); try await pair((second, b), with: (receiver, x)); try await pair((third, c), with: (receiver, x))
      let events = [try PeerRevocation.signed(deviceID: b.id, by: a.own), try PeerRevocation.signed(deviceID: c.id, by: b.own),
                    try PeerRevocation.signed(deviceID: b.id, by: c.own)]
      try await receiver.mergeMembership(.init(entries: [], revocations: reversed ? events.reversed() : events), own: x.own)
      #expect(await receiver.isActiveMac(a.id))
      #expect(await !receiver.isActiveMac(b.id))
      #expect(await !receiver.isActiveMac(c.id))
      #expect(await receiver.revocationContext(for: b.id).count == 2)
    }
  }

  @Test func newlyLearnedMacsUnpairApplyOnTheNextExchangeBeforeTheirIntroductions() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let x = PeerIdentityFixture(), b = PeerIdentityFixture(), c = PeerIdentityFixture(), d = PeerIdentityFixture(), e = PeerIdentityFixture()
    let receiver = try store("receiver"), mini = try store("mini"), third = try store("third"), other = try store("other"), fifth = try store("fifth")
    try await pair((mini, b), with: (receiver, x))
    try await pair((third, c), with: (mini, b)); try await pair((fifth, e), with: (mini, b))
    try await pair((other, d), with: (third, c))
    // B introduces C and E; C introduces D; E unpairs C. None of C, D or E is
    // known to the receiver before this exchange.
    let membership = PeerMembership(entries: (await mini.peerMembership().entries + third.peerMembership().entries),
      revocations: [try PeerRevocation.signed(deviceID: c.id, by: e.own)])
    for reversed in [false, true] {
      let target = try store("target-\(reversed)")
      try await pair((mini, b), with: (target, x))
      let ordered = PeerMembership(entries: reversed ? membership.entries.reversed() : membership.entries, revocations: membership.revocations)
      // First exchange learns C and E only; E's unpair and C's introduction wait.
      try await target.mergeMembership(ordered, own: x.own)
      #expect(await target.isActiveMac(c.id)); #expect(await target.isActiveMac(e.id)); #expect(await !target.isActiveMac(d.id))
      // Second exchange applies E's unpair of C before judging C's introduction.
      try await target.mergeMembership(ordered, own: x.own)
      #expect(await !target.isActiveMac(c.id)); #expect(await !target.isActiveMac(d.id))
      // Repeated full membership converges and never admits D.
      try await target.mergeMembership(ordered, own: x.own)
      #expect(await !target.isActiveMac(d.id))
    }
    // B's own unpair in the same exchange as B's new introduction of C denies C.
    let late = try store("late")
    try await pair((mini, b), with: (late, x))
    let other2 = PeerIdentityFixture(), ownerX = try store("owner-x")
    try await pair((ownerX, other2), with: (late, x))
    let unpairB = try PeerRevocation.signed(deviceID: b.id, by: other2.own)
    try await late.mergeMembership(.init(entries: await mini.peerMembership().entries, revocations: [unpairB]), own: x.own)
    #expect(await !late.isActiveMac(b.id))
    #expect(await !late.isActiveMac(c.id))
  }
}

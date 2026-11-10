#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
import Testing
import WovenMatterCompanion

/// The vector file is shared with the Node server's tests.
struct MemberSignatureVectors: Decodable {
  struct Case: Decodable {
    let name, method, target, nonce, body, bodySHA256, message, signature: String
    let time: Int64
    let headers: [String: String]
  }
  struct Reject: Decodable {
    let name: String
    let `case`: String
    let method, target, nonce, body, audience: String?
    let time: Int64?
  }
  let privateKeySeedHex, publicKeyBase64, deviceID, audience: String
  let windowMilliseconds: Int64
  let cases: [Case]
  let rejects: [Reject]

  static func load() throws -> Self {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "MemberSignatureVectors.json")
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
}

@Suite("Signed member requests")
struct MemberRequestSignatureTests {
  @Test func messagesMatchTheSharedVectors() throws {
    let vectors = try MemberSignatureVectors.load()
    #expect(vectors.windowMilliseconds == MemberRequestSignature.windowMilliseconds)
    for vector in vectors.cases {
      let body = Data(vector.body.utf8)
      #expect(MemberRequestSignature.bodyHash(body) == vector.bodySHA256, "\(vector.name)")
      let message = MemberRequestSignature.message(audience: vectors.audience, method: vector.method, target: vector.target,
                                                   time: vector.time, nonce: vector.nonce, body: body)
      #expect(String(decoding: message, as: UTF8.self) == vector.message, "\(vector.name)")
      #expect(vector.headers[MemberRequestSignature.deviceHeader] == vectors.deviceID)
      #expect(vector.headers[MemberRequestSignature.audienceHeader] == vectors.audience)
      #expect(vector.headers[MemberRequestSignature.signatureHeader] == vector.signature)
      #expect(MemberRequestSignature.decodeBase64URL(vector.nonce)?.count == 16)
      #expect(MemberRequestSignature.decodeBase64URL(vector.signature)?.count == 64)
    }
  }

  @Test func mountPrefixIsNotSigned() {
    #expect(MemberRequestSignature.canonicalTarget("/wovenmatter/v1/peers/sync") == "/v1/peers/sync")
    #expect(MemberRequestSignature.canonicalTarget("/wovenmatter?x=1") == "/?x=1")
    #expect(MemberRequestSignature.canonicalTarget("/wovenmatterx/v1") == "/wovenmatterx/v1")
    let audience = "a3b4c5d6-e7f8-4a09-9b1c-2d3e4f5a6b7c"
    #expect(MemberRequestSignature.message(audience: audience, method: "get", target: "/wovenmatter/v1/a?b=1", time: 1, nonce: "n", body: Data())
      == MemberRequestSignature.message(audience: audience, method: "GET", target: "/v1/a?b=1", time: 1, nonce: "n", body: Data()))
  }

  @Test func theAudienceComesFromSyncedRecordsOnly() {
    let mac = "a0000000-0000-4000-8000-00000000000a", linux = "b0000000-0000-4000-8000-00000000000b"
    let members: [MemberAudience.Member] = [
      .init(deviceID: mac, kind: .mac, endpoints: [URL(string: "https://studio.tail1.ts.net:8443/wovenmatter")!], revoked: false),
      .init(deviceID: linux, kind: .linux, endpoints: [URL(string: "https://box.tail1.ts.net:8443/wovenmatter/")!], revoked: false)]
    let macWorkspace = CompanionExecutionWorkspace(id: "m", libraryID: "l", ownerDeviceID: mac, kind: .mac, name: "Studio",
      endpoint: URL(string: "https://studio.tail1.ts.net:8443/wovenmatter"), executionDeviceID: mac)
    #expect(MemberAudience.serving(macWorkspace, members: members) == mac)
    // A Linux host's execution device is its Node server's own ID: matched by host instead.
    let box = CompanionExecutionWorkspace(id: "w", libraryID: "l", ownerDeviceID: mac, kind: .linux, name: "Box",
      endpoint: URL(string: "https://box.tail1.ts.net/wovenmatter-execution/w"), executionDeviceID: "c0000000-0000-4000-8000-00000000000c")
    #expect(MemberAudience.serving(box, members: members) == linux)
    var elsewhere = box; elsewhere.endpoint = URL(string: "https://other.tail1.ts.net/wovenmatter-execution/w")
    #expect(MemberAudience.serving(elsewhere, members: members) == nil)
    // Removed, ambiguous or phone members never serve a workspace.
    #expect(MemberAudience.serving(box, members: [.init(deviceID: linux, kind: .linux, endpoints: members[1].endpoints, revoked: true)]) == nil)
    #expect(MemberAudience.serving(box, members: members + [.init(deviceID: "d0000000-0000-4000-8000-00000000000d", kind: .linux,
      endpoints: [URL(string: "https://box.tail1.ts.net/wovenmatter/")!], revoked: false)]) == nil)
    #expect(MemberAudience.serving(box, members: [.init(deviceID: linux, kind: .ios, endpoints: members[1].endpoints, revoked: false)]) == nil)
    var macByHost = macWorkspace; macByHost.executionDeviceID = nil
    #expect(MemberAudience.serving(macByHost, members: members) == nil, "a Mac workspace is addressed only by its execution device")
    // A Mac workspace's execution device is that Mac's member ID, even before the list arrives; a removed Mac is not.
    #expect(MemberAudience.serving(macWorkspace, members: []) == mac)
    #expect(MemberAudience.serving(macWorkspace, members: [.init(deviceID: mac, kind: .mac, endpoints: [], revoked: true)]) == nil)
  }

  @Test func base64URLIsStrict() {
    #expect(MemberRequestSignature.decodeBase64URL("AAECAwQFBgcICQoLDA0ODw") == Data(0..<16))
    #expect(MemberRequestSignature.decodeBase64URL("AAECAwQFBgcICQoLDA0ODw==") == nil)
    #expect(MemberRequestSignature.decodeBase64URL("AAECAwQFBgcICQoLDA0OD+") == nil)
    #expect(MemberRequestSignature.decodeBase64URL("") == nil)
    #expect(MemberRequestSignature.base64URL(Data([0xfb, 0xff])) == "-_8")
  }

  #if canImport(CryptoKit)
  private static func key(_ vectors: MemberSignatureVectors) throws -> Curve25519.Signing.PrivateKey {
    let seed = stride(from: 0, to: vectors.privateKeySeedHex.count, by: 2).map {
      let start = vectors.privateKeySeedHex.index(vectors.privateKeySeedHex.startIndex, offsetBy: $0)
      return UInt8(vectors.privateKeySeedHex[start..<vectors.privateKeySeedHex.index(start, offsetBy: 2)], radix: 16)!
    }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
  }

  private static func verifier(_ vectors: MemberSignatureVectors, at time: Int64, revoked: Bool = false,
                               audience: String? = nil) -> MemberRequestVerifier {
    let member = MemberKey(deviceID: vectors.deviceID, kind: .mac, name: "Vector",
                           publicKey: Data(base64Encoded: vectors.publicKeyBase64)!)
    return MemberRequestVerifier(audience: audience ?? vectors.audience, lookup: { $0 == member.deviceID && !revoked ? member : nil }, clock: { time })
  }

  private static func lowercased(_ headers: [String: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
  }

  @Test func vectorSignaturesVerifyAndTamperingIsRefused() async throws {
    let vectors = try MemberSignatureVectors.load()
    #expect(try Self.key(vectors).publicKey.rawRepresentation.base64EncodedString() == vectors.publicKeyBase64)
    for vector in vectors.cases {
      let verifier = Self.verifier(vectors, at: vector.time + 299_000)
      let member = try await verifier.verify(method: vector.method, target: vector.target,
        headers: Self.lowercased(vector.headers), body: Data(vector.body.utf8))
      #expect(member.deviceID == vectors.deviceID)
    }
    for reject in vectors.rejects {
      let original = try #require(vectors.cases.first { $0.name == reject.case })
      var headers = Self.lowercased(original.headers)
      if let time = reject.time { headers["x-woven-member-time"] = String(time) }
      if let nonce = reject.nonce { headers["x-woven-member-nonce"] = nonce }
      // Presented to the member it names: the audience-changed reject is a second member.
      if let audience = reject.audience { headers["x-woven-member-audience"] = audience }
      let verifier = Self.verifier(vectors, at: original.time, audience: reject.audience)
      await #expect(throws: MemberRequestError.signature, "\(reject.name)") {
        try await verifier.verify(method: reject.method ?? original.method, target: reject.target ?? original.target,
          headers: headers, body: Data((reject.body ?? original.body).utf8))
      }
    }
  }

  @Test func windowReplayAndRevocation() async throws {
    let vectors = try MemberSignatureVectors.load()
    let vector = vectors.cases[0]
    let headers = Self.lowercased(vector.headers), body = Data(vector.body.utf8)
    for skew: Int64 in [-300_001, 300_001] {
      await #expect(throws: MemberRequestError.clock) {
        try await Self.verifier(vectors, at: vector.time + skew).verify(method: vector.method, target: vector.target, headers: headers, body: body)
      }
    }
    let verifier = Self.verifier(vectors, at: vector.time - 300_000)
    _ = try await verifier.verify(method: vector.method, target: vector.target, headers: headers, body: body)
    await #expect(throws: MemberRequestError.replay) {
      try await verifier.verify(method: vector.method, target: vector.target, headers: headers, body: body)
    }
    await #expect(throws: MemberRequestError.unknown) {
      try await Self.verifier(vectors, at: vector.time, revoked: true).verify(method: vector.method, target: vector.target, headers: headers, body: body)
    }
    await #expect(throws: MemberRequestError.kind) {
      try await Self.verifier(vectors, at: vector.time).verify(method: vector.method, target: vector.target, headers: headers, body: body, allowing: [.linux])
    }
  }

  @Test func signerRoundTrips() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let device = UUID().uuidString.lowercased()
    let signer = MemberRequestSigner(deviceID: device, key: key)
    let body = Data("{\"after\":3}".utf8)
    let host = UUID().uuidString.lowercased()
    let headers = try signer.headers(method: "POST", target: "/wovenmatter/v1/peers/sync", body: body, audience: host)
    let member = MemberKey(deviceID: device, kind: .linux, name: "Host", publicKey: key.publicKey.rawRepresentation)
    let verifier = MemberRequestVerifier(audience: host, lookup: { $0 == device ? member : nil })
    // A Linux host behind Tailscale Serve sees the path without its prefix.
    #expect(try await verifier.verify(method: "POST", target: "/v1/peers/sync", headers: Self.lowercased(headers), body: body) == member)
    await #expect(throws: MemberRequestError.signature) {
      try await MemberRequestVerifier(audience: host, lookup: { _ in member }).verify(method: "POST", target: "/v1/peers/files", headers: Self.lowercased(headers), body: body)
    }
    // Nothing can be signed without knowing the destination.
    #expect(throws: MemberRequestError.audienceUnknown) { try signer.headers(method: "GET", target: "/v1/hello", audience: "paired") }
  }

  /// Each member keeps its own nonce cache, so a captured request must not
  /// verify at a second member even though its nonce is new there.
  @Test func aRequestForOneMemberIsRefusedByAnother() async throws {
    let key = Curve25519.Signing.PrivateKey(), device = UUID().uuidString.lowercased()
    let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
    let member = MemberKey(deviceID: device, kind: .ios, name: "Phone", publicKey: key.publicKey.rawRepresentation)
    let signer = MemberRequestSigner(deviceID: device, key: key)
    let headers = Self.lowercased(try signer.headers(method: "GET", target: "/wovenmatter/v1/snapshot", audience: first))
    let atFirst = MemberRequestVerifier(audience: first, lookup: { $0 == device ? member : nil })
    let atSecond = MemberRequestVerifier(audience: second, lookup: { $0 == device ? member : nil })
    #expect(try await atFirst.verify(method: "GET", target: "/v1/snapshot", headers: headers, body: Data()) == member)
    // The same bytes replayed to the second member.
    await #expect(throws: MemberRequestError.audience) {
      try await atSecond.verify(method: "GET", target: "/v1/snapshot", headers: headers, body: Data())
    }
    // Relabelled for the second member, the signature no longer verifies.
    var relabelled = headers; relabelled["x-woven-member-audience"] = second
    await #expect(throws: MemberRequestError.signature) {
      try await atSecond.verify(method: "GET", target: "/v1/snapshot", headers: relabelled, body: Data())
    }
    // Missing or malformed audiences are refused outright.
    var missing = headers; missing["x-woven-member-audience"] = nil
    await #expect(throws: MemberRequestError.missing) { try await atFirst.verify(method: "GET", target: "/v1/snapshot", headers: missing, body: Data()) }
    var upper = headers; upper["x-woven-member-audience"] = first.uppercased()
    await #expect(throws: MemberRequestError.signature) { try await atFirst.verify(method: "GET", target: "/v1/snapshot", headers: upper, body: Data()) }
  }
  #endif
}

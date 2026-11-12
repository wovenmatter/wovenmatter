#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Signed member requests (docs/architecture/WOVEN_EVERYWHERE.md, "Membership
/// and device keys"). Every request from one member to another carries the
/// caller's device ID, the destination member's device ID (the audience), a
/// millisecond timestamp, a 16-byte nonce and an Ed25519 signature over a fixed
/// message. Nothing is issued, cached or renewed. The audience binds a request
/// to one destination: each member keeps its own nonce cache, so without it a
/// request captured on its way to one member could be replayed to another.
///
/// This file is portable: signing and verification take the Ed25519 primitive
/// as closures, so Linux builds (swift-crypto) and Apple builds (CryptoKit)
/// share the exact message format, window and replay rules.
public enum MemberRequestSignature {
  public static let deviceHeader = "X-Woven-Member-Device"
  public static let audienceHeader = "X-Woven-Member-Audience"
  public static let timeHeader = "X-Woven-Member-Time"
  public static let nonceHeader = "X-Woven-Member-Nonce"
  public static let signatureHeader = "X-Woven-Member-Signature"
  /// Accepted clock difference in either direction.
  public static let windowMilliseconds: Int64 = 300_000
  public static let domain = "woven-member-v2"

  /// `woven-member-v2\n<audience>\n<METHOD>\n<path with query>\n<time>\n<nonce>\n<hex SHA-256 of body>`.
  /// The path is `canonicalTarget(target)`; `audience` is the destination
  /// member's lowercase device ID.
  public static func message(audience: String, method: String, target: String, time: Int64, nonce: String, body: Data) -> Data {
    message(audience: audience, method: method, target: target, time: time, nonce: nonce, bodySHA256: bodyHash(body))
  }

  /// The same message from the body's lowercase hex SHA-256, for a caller that
  /// hashes a large or streamed body itself (a Linux library host signing for
  /// its Node server).
  public static func message(audience: String, method: String, target: String, time: Int64, nonce: String, bodySHA256: String) -> Data {
    Data([domain, audience, method.uppercased(), canonicalTarget(target), String(time), nonce, bodySHA256].joined(separator: "\n").utf8)
  }

  /// A device ID as it appears on the wire: a lowercase UUID.
  public static func isDeviceID(_ value: String) -> Bool {
    value.utf8.count == 36 && UUID(uuidString: value) != nil && value == value.lowercased()
  }

  /// The signed path omits a leading `/wovenmatter` mount prefix, because
  /// Tailscale Serve strips it before a Linux host sees the request while a
  /// Mac receives it intact. `/wovenmatter/v1/x?y` and `/v1/x?y` sign alike.
  public static func canonicalTarget(_ target: String) -> String {
    if target == "/wovenmatter" { return "/" }
    if target.hasPrefix("/wovenmatter/") { return String(target.dropFirst("/wovenmatter".count)) }
    if target.hasPrefix("/wovenmatter?") { return "/" + target.dropFirst("/wovenmatter".count) }
    return target
  }

  public static func bodyHash(_ body: Data) -> String {
    PortableSHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
  }

  public static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  /// Strict unpadded base64url; anything else (padding, `+`, `/`) is refused.
  public static func decodeBase64URL(_ text: String) -> Data? {
    guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
          text.utf8.count % 4 != 1 else { return nil }
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.utf8.count % 4 != 0 { base64 += "=" }
    guard let data = Data(base64Encoded: base64), base64URL(data) == text else { return nil }
    return data
  }

  public static func randomNonce() -> String {
    var generator = SystemRandomNumberGenerator()
    return base64URL(Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  public static func now() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}

/// Signs requests as one member device.
public struct MemberRequestSigner: Sendable {
  public let deviceID: String
  private let sign: @Sendable (Data) throws -> Data

  public init(deviceID: String, sign: @escaping @Sendable (Data) throws -> Data) {
    self.deviceID = deviceID.lowercased(); self.sign = sign
  }

  /// `target` is the request's path with query exactly as sent on the wire,
  /// including any `/wovenmatter` prefix the verifier will see. `audience` is
  /// the destination member's device ID, taken from a signed record (the
  /// member list, or the workspace registry's `executionDeviceID`), never from
  /// what the destination says about itself.
  public func headers(method: String, target: String, body: Data = Data(), audience: String,
                      time: Int64 = MemberRequestSignature.now(),
                      nonce: String = MemberRequestSignature.randomNonce()) throws -> [String: String] {
    try headers(method: method, target: target, bodySHA256: MemberRequestSignature.bodyHash(body), audience: audience, time: time, nonce: nonce)
  }

  /// `bodySHA256` is the lowercase hex SHA-256 of the exact body bytes.
  public func headers(method: String, target: String, bodySHA256: String, audience: String,
                      time: Int64 = MemberRequestSignature.now(),
                      nonce: String = MemberRequestSignature.randomNonce()) throws -> [String: String] {
    let audience = audience.lowercased()
    guard MemberRequestSignature.isDeviceID(audience) else { throw MemberRequestError.audienceUnknown }
    let message = MemberRequestSignature.message(audience: audience, method: method, target: target, time: time, nonce: nonce, bodySHA256: bodySHA256)
    return [MemberRequestSignature.deviceHeader: deviceID, MemberRequestSignature.audienceHeader: audience,
            MemberRequestSignature.timeHeader: String(time),
            MemberRequestSignature.nonceHeader: nonce,
            MemberRequestSignature.signatureHeader: MemberRequestSignature.base64URL(try sign(message))]
  }

  #if canImport(CryptoKit)
  public init(deviceID: String, key: Curve25519.Signing.PrivateKey) {
    self.init(deviceID: deviceID) { try key.signature(for: $0) }
  }
  #endif
}

public enum MemberKind: String, Codable, Sendable, CaseIterable {
  case mac, linux, ios
}

/// What a verifier needs to know about a member at request time.
public struct MemberKey: Sendable, Equatable {
  public let deviceID: String
  public let kind: MemberKind
  public let name: String
  public let publicKey: Data
  public init(deviceID: String, kind: MemberKind, name: String, publicKey: Data) {
    self.deviceID = deviceID; self.kind = kind; self.name = name; self.publicKey = publicKey
  }
}

public struct MemberRequestError: Error, Equatable, Sendable, LocalizedError {
  public let code: String
  public let message: String
  public init(_ code: String, _ message: String) { self.code = code; self.message = message }
  public var errorDescription: String? { message }
  public static let missing = MemberRequestError("unauthorized", "This request is not signed by a member device.")
  public static let unknown = MemberRequestError("unauthorized", "This device is not a member, or it was removed.")
  public static let clock = MemberRequestError("clock_skew", "This device's clock differs from the other device's by more than five minutes.")
  public static let replay = MemberRequestError("unauthorized", "This signed request was already used.")
  public static let signature = MemberRequestError("unauthorized", "The member signature is invalid.")
  public static let kind = MemberRequestError("wrong_device", "This kind of member device cannot use this route.")
  /// Signed for another member: refused before the signature is checked.
  public static let audience = MemberRequestError("unauthorized", "This signed request was meant for another device.")
  /// A caller that does not know the destination's member device ID cannot sign for it.
  public static let audienceUnknown = MemberRequestError("member_audience_unknown",
    "This device has not learned that member's identity yet. Try again once the libraries have synchronized.")
}

/// Verifies signed member requests addressed to this device (`audience`)
/// against the current member list. The nonce cache keeps every accepted
/// (device, nonce) until it falls out of the time window, so a captured request
/// cannot be replayed here within it, and the audience keeps it from being
/// replayed to any other member.
public actor MemberRequestVerifier {
  public typealias Lookup = @Sendable (String) async -> MemberKey?
  public typealias Verify = @Sendable (_ publicKey: Data, _ signature: Data, _ message: Data) -> Bool
  /// This device's own member ID: the only audience it accepts.
  public nonisolated let audience: String
  private let lookup: Lookup
  private let verifySignature: Verify
  private let clock: @Sendable () -> Int64
  private var seen: [String: Int64] = [:]
  private var nextSweep: Int64 = 0
  private let maximumNonces: Int

  public init(audience: String, lookup: @escaping Lookup, verify: @escaping Verify,
              clock: @escaping @Sendable () -> Int64 = { MemberRequestSignature.now() }, maximumNonces: Int = 200_000) {
    self.audience = audience.lowercased()
    self.lookup = lookup; self.verifySignature = verify; self.clock = clock; self.maximumNonces = maximumNonces
  }

  #if canImport(CryptoKit)
  public init(audience: String, lookup: @escaping Lookup, clock: @escaping @Sendable () -> Int64 = { MemberRequestSignature.now() }) {
    self.init(audience: audience, lookup: lookup, verify: MemberRequestVerifier.curve25519, clock: clock)
  }
  public static let curve25519: Verify = { publicKey, signature, message in
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
    return key.isValidSignature(signature, for: message)
  }
  #endif

  /// True when the request carries any member header; such a request is
  /// authenticated only by its signature, never by a bearer alongside it.
  public nonisolated static func isSigned(_ headers: [String: String]) -> Bool {
    headers[MemberRequestSignature.deviceHeader.lowercased()] != nil
  }

  /// `headers` are lowercased names, as `LibraryHTTPRequest` stores them.
  public func verify(method: String, target: String, headers: [String: String], body: Data,
                     allowing kinds: Set<MemberKind> = Set(MemberKind.allCases)) async throws -> MemberKey {
    guard let device = headers[MemberRequestSignature.deviceHeader.lowercased()],
          let addressed = headers[MemberRequestSignature.audienceHeader.lowercased()],
          let rawTime = headers[MemberRequestSignature.timeHeader.lowercased()],
          let nonce = headers[MemberRequestSignature.nonceHeader.lowercased()],
          let rawSignature = headers[MemberRequestSignature.signatureHeader.lowercased()] else { throw MemberRequestError.missing }
    guard MemberRequestSignature.isDeviceID(device), MemberRequestSignature.isDeviceID(addressed),
          rawTime.utf8.count <= 16, rawTime.utf8.allSatisfy({ (48...57).contains($0) }), let time = Int64(rawTime),
          MemberRequestSignature.decodeBase64URL(nonce)?.count == 16,
          let signature = MemberRequestSignature.decodeBase64URL(rawSignature), signature.count == 64 else {
      throw MemberRequestError.signature
    }
    guard addressed == audience else { throw MemberRequestError.audience }
    let now = clock()
    guard abs(now - time) <= MemberRequestSignature.windowMilliseconds else { throw MemberRequestError.clock }
    guard let member = await lookup(device), member.publicKey.count == 32 else { throw MemberRequestError.unknown }
    let message = MemberRequestSignature.message(audience: addressed, method: method, target: target, time: time, nonce: nonce, body: body)
    guard verifySignature(member.publicKey, signature, message) else { throw MemberRequestError.signature }
    // Checked after the signature so an unsigned flood cannot fill the cache.
    let key = device + ":" + nonce
    sweep(now: now)
    guard seen[key] == nil else { throw MemberRequestError.replay }
    guard seen.count < maximumNonces else { throw MemberRequestError("rate_limited", "Too many signed requests; retry shortly.") }
    seen[key] = time + MemberRequestSignature.windowMilliseconds
    guard kinds.contains(member.kind) else { throw MemberRequestError.kind }
    return member
  }

  private func sweep(now: Int64) {
    guard now >= nextSweep || seen.count >= maximumNonces else { return }
    seen = seen.filter { $0.value >= now }
    nextSweep = now + 10_000
  }
}

/// Which member serves a workspace's endpoint: the audience of signed requests
/// to it (docs/architecture/WOVEN_EVERYWHERE.md, "Where the audience comes
/// from"). Taken only from synced records, never from the endpoint itself.
public enum MemberAudience {
  public struct Member: Sendable, Equatable {
    public let deviceID: String
    public let kind: MemberKind
    public let endpoints: [URL]
    public let revoked: Bool
    public init(deviceID: String, kind: MemberKind, endpoints: [URL], revoked: Bool) {
      self.deviceID = deviceID.lowercased(); self.kind = kind; self.endpoints = endpoints; self.revoked = revoked
    }
  }

  /// The workspace's execution device when that is an active Mac or Linux
  /// member, and for a Mac workspace (whose execution device is the Mac's
  /// member ID) whenever that device was not removed. A Linux host registers
  /// new workspaces with its member ID too; an older Linux record names its
  /// Node server's own execution device ID, so otherwise it is the one active
  /// Linux member that advertises an endpoint
  /// on the same tailnet host. Two members claiming that host: nobody.
  public static func serving(_ workspace: ExecutionWorkspace, members: [Member]) -> String? {
    guard workspace.kind != .ios, !workspace.deleted else { return nil }
    let active = members.filter { !$0.revoked && $0.kind != .ios }
    if let id = workspace.executionDeviceID?.lowercased(), active.contains(where: { $0.deviceID == id }) { return id }
    if workspace.kind == .mac, let id = workspace.executionDeviceID?.lowercased(), MemberRequestSignature.isDeviceID(id),
       !members.contains(where: { $0.deviceID == id && ($0.revoked || $0.kind != .mac) }) { return id }
    guard workspace.kind == .linux, let host = workspace.endpoint?.host?.lowercased(), host.hasSuffix(".ts.net") else { return nil }
    let matches = active.filter { member in member.kind == .linux && member.endpoints.contains { $0.host?.lowercased() == host } }
    return matches.count == 1 ? matches[0].deviceID : nil
  }
}

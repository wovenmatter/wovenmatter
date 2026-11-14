import Foundation
import WovenMatterShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one request and returns its bounded body. Production uses URLSession
/// without cookies, caches or redirects; tests route requests to in-process
/// Mac and Linux hosts.
public protocol MobileHTTPPerforming: Sendable {
  /// `longLived` selects the long-timeout session (MCP calls).
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionMobileHTTP: MobileHTTPPerforming, @unchecked Sendable {
  private let session: URLSession
  private let longSession: URLSession
  public init(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 45) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = requestTimeout; configuration.timeoutIntervalForResource = resourceTimeout
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    let long = URLSessionConfiguration.ephemeral
    long.httpCookieStorage = nil; long.urlCache = nil
    long.timeoutIntervalForRequest = 24 * 60 * 60; long.timeoutIntervalForResource = 24 * 60 * 60
    longSession = URLSession(configuration: long, delegate: NoRedirects(), delegateQueue: nil)
  }
  public func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    let session = longLived ? longSession : session
    #if !os(Linux)
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard response.expectedContentLength <= maximumBytes else { throw MobileConnectionError.responseTooLarge }
    var data = Data(); data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
    for try await byte in bytes {
      guard data.count < maximumBytes else { throw MobileConnectionError.responseTooLarge }
      data.append(byte)
    }
    return (data, response)
    #else
    let (data, rawResponse) = try await session.data(for: request)
    guard let response = rawResponse as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard data.count <= maximumBytes else { throw MobileConnectionError.responseTooLarge }
    return (data, response)
    #endif
  }
}

public enum MobileRequestSigning {
  /// The request target exactly as it goes on the wire: percent-encoded path
  /// and query. A `/wovenmatter` mount is part of it; the verifier drops it.
  public static func target(of url: URL) -> String {
    var path = url.path(percentEncoded: true)
    if path.isEmpty { path = "/" }
    if let query = url.query(percentEncoded: true) { path += "?" + query }
    return path
  }

  /// Adds the member signature headers, addressed to the member `audience`
  /// (its device ID from the member list or the workspace registry). A signed
  /// request never carries a bearer.
  public static func sign(_ request: inout URLRequest, with signer: MemberRequestSigner, audience: String) throws {
    guard let url = request.url else { throw MobileConnectionError.invalidResponse }
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    let headers = try signer.headers(method: request.httpMethod ?? "GET", target: target(of: url), body: request.httpBody ?? Data(), audience: audience)
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
  }

  /// Maps a non-success status to the client's error. Signed requests keep
  /// "this host does not know this phone yet" apart from "pair again": a
  /// host learns a new member only after it syncs with a Mac that added it.
  static func failure(status: Int, data: Data, signed: Bool, fallback: String) -> MobileConnectionError {
    let error = try? JSONDecoder().decode(LibraryAPIError.self, from: data)
    let code = error?.code ?? (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
    if code == "update_required" { return .updateRequired(error?.message ?? "Update Woven Matter on every device.") }
    switch status {
    case 401, 403:
      guard signed else { return .revoked }
      // The host has not loaded its member list yet; try again later.
      if code == "member_auth_unavailable" || error?.message.contains("does not accept member requests") == true {
        return .http(status, error?.message ?? "The device you reached isn’t ready for member requests yet.")
      }
      if code == "clock_skew" { return .http(status, error?.message ?? "This device's clock is more than five minutes off.") }
      if code == "wrong_device" || code == "wrong_workspace" { return .http(status, error?.message ?? fallback) }
      return .memberUnknown
    case 426: return .versionMismatch
    default: return .http(status, error?.message ?? fallback)
    }
  }
}

/// The member list a phone learns from whichever Mac or Linux host it syncs
/// with (`GET /v1/members` on the mobile API). Keys are not needed here: the
/// phone signs, it does not verify other members.
public struct MobileLibraryMember: Codable, Equatable, Sendable, Identifiable {
  public var id: String { deviceID }
  public var deviceID: String
  public var kind: String
  public var name: String
  public var endpoints: [URL]
  public var revoked: Bool
  public init(deviceID: String, kind: String, name: String, endpoints: [URL], revoked: Bool = false) {
    self.deviceID = deviceID.lowercased(); self.kind = kind; self.name = name; self.endpoints = endpoints; self.revoked = revoked
  }
}
public struct MobileLibraryMemberList: Codable, Equatable, Sendable {
  public var members: [MobileLibraryMember]
  public var revision: String
  public init(members: [MobileLibraryMember], revision: String) { self.members = members; self.revision = revision }
}

/// `GET /v1/sync/status` on every Mac and Linux library host.
public struct MobileLibrarySyncStatus: Codable, Equatable, Sendable {
  public struct Peer: Codable, Equatable, Sendable, Identifiable {
    public var id: String { deviceID }
    public var deviceID: String
    public var name: String
    public var kind: String
    public var state: String
    public var version: String?
    public var lastSynchronized: Date?
    public var lastContact: Date?
    public var error: String?
  }
  public var deviceID: String
  public var version: String
  public var schema: String
  public var peers: [Peer]
  public var conflicts: Int
  public var quarantined: Int
  public var updateRequired: Bool { peers.contains { $0.state == "updateRequired" } }
  public init(deviceID: String, version: String, schema: String, peers: [Peer], conflicts: Int = 0, quarantined: Int = 0) {
    self.deviceID = deviceID; self.version = version; self.schema = schema; self.peers = peers
    self.conflicts = conflicts; self.quarantined = quarantined
  }
}

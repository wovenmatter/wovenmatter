import CryptoKit
import Foundation
import WovenMatterCore

private final class PairedMacRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Discovery/replica addresses are untrusted until they prove possession of an
/// existing device verifier. Never send a bearer to a learned address first.
public final class PairedMacNetwork: Sendable {
  public typealias Request = @Sendable (URL, String, String?, String?, Data?) async throws -> Data
  private let session: URLSession
  private let injectedRequest: Request?
  public init(request: Request? = nil) {
    injectedRequest = request
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 45
    session = URLSession(configuration: configuration, delegate: PairedMacRedirectPolicy(), delegateQueue: nil)
  }
  public func request<T: Decodable & Sendable>(_ endpoint: URL, path: String, token: String? = nil, libraryID: String? = nil, body: Data? = nil) async throws -> T {
    guard CompanionPairingPayload.isValidEndpoint(endpoint),
          ["v1/discovery", "v1/pair", "v1/pair/preview", "v1/pair/confirm"].contains(path) || path.hasPrefix("v1/peers/") || path.hasPrefix("v1/federation/workspaces/") else {
      throw CompanionAPIError(code: "invalid_endpoint", message: "Invalid paired Mac endpoint.")
    }
    if let injectedRequest {
      return try JSONDecoder().decode(T.self, from: await injectedRequest(endpoint, path, token, libraryID, body))
    }
    var request = URLRequest(url: endpoint.appending(path: path)); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    if let libraryID { request.setValue(libraryID, forHTTPHeaderField: "X-Woven-Workspace") }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 48 * 1_024 * 1_024 else { throw invalidResponse }
    var data = Data()
    for try await byte in bytes { guard data.count < 48 * 1_024 * 1_024 else { throw invalidResponse }; data.append(byte) }
    guard response.statusCode == 200 else {
      if let error = try? JSONDecoder().decode(CompanionAPIError.self, from: data) { throw error }; throw invalidResponse
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
  /// The target must sign a fresh challenge with the key this Mac pinned for
  /// its device UUID. The key is never taken from the route or the proof, and
  /// there is no shared-secret fallback: a learned or poisoned address cannot
  /// obtain this Mac's target-local bearer. Identity is the pinned device,
  /// library and contacted endpoint; a signed display-name change is returned.
  @discardableResult
  public func verify(_ route: PairedMacRoute, deviceID: String, token: String, pin: PeerPin) async throws -> PairedMacRoute {
    try route.validate()
    guard pin.libraryID == route.libraryID.lowercased(),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pin.publicKey) else { throw unverified }
    let digest = Data(SHA256.hash(data: Data(token.utf8)))
    let credentialID = SHA256.hash(data: digest).map { String(format: "%02x", $0) }.joined()
    let challenge = PairedMacProofChallenge(deviceID: deviceID, credentialID: credentialID, nonce: Self.nonce(),
      targetDeviceID: route.deviceID, targetLibraryID: route.libraryID)
    let proof: PairedMacProof = try await request(route.endpoint, path: "v1/peers/proof", body: JSONEncoder().encode(challenge))
    guard proof.route.deviceID == route.deviceID, proof.route.libraryID == route.libraryID, proof.route.endpoint == route.endpoint,
          (try? proof.route.validate()) != nil,
          key.isValidSignature(proof.signature, for: PairedMacProof.statement(challenge, route: proof.route)) else { throw unverified }
    return proof.route
  }

  /// Learned-peer handshake. The target first proves its pinned key over a
  /// one-use challenge for this exact pair; only then does this Mac sign the
  /// challenge, and the target returns a fresh grant valid only at itself.
  public func handshake(_ route: PairedMacRoute, own: PeerSelf, pin: PeerPin, operationID: String) async throws -> (token: String, route: PairedMacRoute) {
    try route.validate()
    guard pin.libraryID == route.libraryID.lowercased(),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pin.publicKey) else { throw unverified }
    let request = PairedMacChallengeRequest(requesterDeviceID: own.deviceID, requesterLibraryID: own.libraryID,
      targetDeviceID: route.deviceID.lowercased(), targetLibraryID: route.libraryID.lowercased())
    let challenge: PairedMacChallenge = try await self.request(route.endpoint, path: "v1/peers/challenge", body: JSONEncoder().encode(request))
    guard challenge.route.deviceID == route.deviceID, challenge.route.libraryID == route.libraryID, challenge.route.endpoint == route.endpoint,
          challenge.nonce.count == 32, PeerIdentifier.canonical(challenge.challengeID) != nil, PeerIdentifier.canonical(challenge.serviceID) != nil,
          key.isValidSignature(challenge.signature, for: PairedMacChallenge.statement(challengeID: challenge.challengeID, nonce: challenge.nonce,
            serviceID: challenge.serviceID, request: request, route: challenge.route)) else { throw unverified }
    let signature = try own.key.signature(for: PairedMacHandshake.statement(challenge: challenge, request: request, operationID: operationID))
    let grant: PairedMacGrant = try await self.request(route.endpoint, path: "v1/peers/handshake",
      body: JSONEncoder().encode(PairedMacHandshake(challengeID: challenge.challengeID, request: request, operationID: operationID, signature: signature)))
    guard (32...256).contains(grant.token.utf8.count) else { throw unverified }
    return (grant.token, challenge.route)
  }
  static func nonce() -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
  }
  private var unverified: CompanionAPIError { .init(code: "unverified_peer", message: "This address could not prove that it belongs to the paired Mac.") }
  private var invalidResponse: CompanionAPIError { .init(code: "peer_unavailable", message: "The paired Mac did not return a valid synchronization response.") }
}

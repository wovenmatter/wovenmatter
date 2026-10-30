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
  public func verify(_ route: PairedMacRoute, deviceID: String, token: String) async throws {
    try route.validate()
    let digest = Data(SHA256.hash(data: Data(token.utf8)))
    let credentialID = SHA256.hash(data: digest).map { String(format: "%02x", $0) }.joined()
    var generator = SystemRandomNumberGenerator()
    let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
    let proof: PairedMacProof = try await request(route.endpoint, path: "v1/peers/proof",
      body: JSONEncoder().encode(PairedMacProofChallenge(deviceID: deviceID, credentialID: credentialID, nonce: nonce)))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard proof.route.deviceID == route.deviceID, proof.route.libraryID == route.libraryID, proof.route.endpoint == route.endpoint,
          HMAC<SHA256>.isValidAuthenticationCode(proof.signature, authenticating: nonce + (try encoder.encode(proof.route)), using: SymmetricKey(data: digest)) else {
      throw CompanionAPIError(code: "unverified_peer", message: "This address could not prove that it belongs to the paired Mac.")
    }
  }
  private var invalidResponse: CompanionAPIError { .init(code: "peer_unavailable", message: "The paired Mac did not return a valid synchronization response.") }
}

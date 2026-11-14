#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WovenMatterClient
import WovenMatterCore

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
    session = URLSession(configuration: configuration, delegate: RemoteWorkspaceRedirectPolicy.shared, delegateQueue: nil)
  }
  public func request<T: Decodable & Sendable>(_ endpoint: URL, path: String, token: String? = nil, libraryID: String? = nil, body: Data? = nil) async throws -> T {
    guard PairingPayload.isValidEndpoint(endpoint),
          ["v1/discovery", "v1/pair", "v1/pair/preview", "v1/pair/confirm"].contains(path) || path.hasPrefix("v1/peers/") else {
      throw LibraryAPIError(code: "invalid_endpoint", message: "Invalid paired Mac endpoint.")
    }
    if let injectedRequest {
      return try JSONDecoder().decode(T.self, from: await injectedRequest(endpoint, path, token, libraryID, body))
    }
    var request = URLRequest(url: endpoint.appending(path: path)); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    if let libraryID { request.setValue(libraryID, forHTTPHeaderField: "X-Woven-Workspace") }
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 48 * 1_024 * 1_024 else { throw invalidResponse }
    var data = Data()
    for try await byte in bytes { guard data.count < 48 * 1_024 * 1_024 else { throw invalidResponse }; data.append(byte) }
    guard response.statusCode == 200 else {
      if let error = try? JSONDecoder().decode(LibraryAPIError.self, from: data) { throw error }; throw invalidResponse
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
  private var invalidResponse: LibraryAPIError { .init(code: "peer_unavailable", message: "The paired Mac did not return a valid synchronization response.") }
}

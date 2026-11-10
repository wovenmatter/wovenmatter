import Foundation
import WovenMatterCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTPS to another member (a paired Mac or a Linux host) authenticated only
/// by this device's member signature (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Membership and device keys"). Nothing is issued or stored: every request
/// signs its exact wire target, so `/wovenmatter/…` on a Mac and
/// `/wovenmatter-execution/<id>/…` on a Linux host both verify, and names the
/// destination member (`audience`), so it verifies only there.
public struct MemberSignedHTTPClient: Sendable {
  public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  public let endpoint: URL
  public let signer: MemberRequestSigner
  /// The destination member's device ID, from the member list or registry.
  public let audience: String
  private let headers: [String: String]
  private let send: Send
  public static let maximumResponseBytes = 80 * 1_024 * 1_024

  /// `endpoint` is a private tailnet HTTPS base URL and `audience` the device
  /// ID of the member that serves it. `send` replaces the network for
  /// in-process tests.
  public init(endpoint: URL, signer: MemberRequestSigner, audience: String, headers: [String: String] = [:], send: Send? = nil) throws {
    guard endpoint.scheme == "https", endpoint.host?.lowercased().hasSuffix(".ts.net") == true,
          endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
          !endpoint.pathComponents.contains("..") else { throw MemberSignedHTTPError.insecureEndpoint }
    guard MemberRequestSignature.isDeviceID(audience.lowercased()) else { throw MemberRequestError.audienceUnknown }
    self.endpoint = endpoint; self.signer = signer; self.audience = audience.lowercased(); self.headers = headers
    self.send = send ?? Self.network
  }

  /// The signed request as it goes on the wire (exposed for tests).
  public func signedRequest(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                            headers extra: [String: String] = [:], timeout: TimeInterval = 30) throws -> URLRequest {
    let base = endpoint.absoluteString.hasSuffix("/") ? endpoint : endpoint.appendingPathComponent("")
    guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw MemberSignedHTTPError.invalidResponse }
    components.queryItems = query.isEmpty ? nil : query
    guard let final = components.url else { throw MemberSignedHTTPError.invalidResponse }
    let target = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
    var request = URLRequest(url: final, timeoutInterval: timeout)
    request.httpMethod = method; request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    for (key, value) in headers.merging(extra, uniquingKeysWith: { $1 }) { request.setValue(value, forHTTPHeaderField: key) }
    for (key, value) in try signer.headers(method: method, target: target, body: body ?? Data(), audience: audience) {
      request.setValue(value, forHTTPHeaderField: key)
    }
    return request
  }

  public func data(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                   headers extra: [String: String] = [:], timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
    let request = try signedRequest(path, method: method, query: query, body: body, headers: extra, timeout: timeout)
    let (data, response) = try await send(request)
    guard data.count <= Self.maximumResponseBytes else { throw MemberSignedHTTPError.responseTooLarge }
    return (data, response)
  }

  /// Decodes a 2xx reply; any other status becomes `MemberSignedHTTPError.http`.
  public func request<Value: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                                        headers extra: [String: String] = [:], timeout: TimeInterval = 30) async throws -> Value {
    let (data, response) = try await data(path, method: method, query: query, body: body, headers: extra, timeout: timeout)
    guard (200..<300).contains(response.statusCode) else { throw MemberSignedHTTPError.failure(status: response.statusCode, data: data) }
    return try JSONDecoder().decode(Value.self, from: data)
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
    return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
  }()
  private static let network: Send = { request in
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw MemberSignedHTTPError.invalidResponse }
    return (data, response)
  }
  private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
  }
}

public enum MemberSignedHTTPError: Error, Equatable, Sendable, LocalizedError {
  case insecureEndpoint
  case invalidResponse
  case responseTooLarge
  case http(status: Int, code: String?, message: String)

  static func failure(status: Int, data: Data) -> MemberSignedHTTPError {
    struct Reply: Decodable { var code: String?; var error: String?; var message: String? }
    let reply = try? JSONDecoder().decode(Reply.self, from: data)
    return .http(status: status, code: reply?.code ?? reply?.error,
                 message: reply?.message ?? reply?.error ?? "The device answered \(status).")
  }
  /// The peer does not accept this device's signature (not yet a member there,
  /// or an older version that only knows bearer grants).
  public var isUnauthorized: Bool { if case .http(let status, _, _) = self { return status == 401 || status == 403 }; return false }
  public var errorDescription: String? {
    switch self {
    case .insecureEndpoint: "Other devices are reached only at private tailnet HTTPS addresses."
    case .invalidResponse: "The device returned an invalid response."
    case .responseTooLarge: "The device's response is too large."
    case .http(_, _, let message): message
    }
  }
}

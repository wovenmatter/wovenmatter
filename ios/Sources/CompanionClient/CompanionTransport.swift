import Foundation
import WovenMatterCompanion
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public struct MobileCredential: Codable, Sendable, Equatable {
  public var endpoint: URL
  public var workspaceID: String
  public var deviceID: String
  public var token: String
  public init(endpoint: URL, workspaceID: String, deviceID: String, token: String) {
    self.endpoint = endpoint; self.workspaceID = workspaceID; self.deviceID = deviceID; self.token = token
  }
}

public protocol CompanionTransport: Sendable {
  func workspaceIdentity() async throws -> String
  func snapshot() async throws -> CompanionSnapshot
  func changes(after: Int64) async throws -> CompanionChangePage
  func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult
  func note(_ id: String) async throws -> CompanionNote
  func linkedData(_ id: String, tableID: String?) async throws -> CompanionLinkedData
  func providers() async throws -> [CompanionProvider]
  func pending() async throws -> [CompanionPendingInteraction]
  func transcript(_ id: String) async throws -> CompanionTranscript
  func transcript(_ id: String, before: String) async throws -> CompanionTranscript
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt
  func receipt(_ id: String) async throws -> CompanionCommandReceipt?
}

public extension CompanionTransport {
  func linkedData(_ id: String, tableID: String?) async throws -> CompanionLinkedData { throw MobileConnectionError.offline }
  func transcript(_ id: String, before: String) async throws -> CompanionTranscript { throw MobileConnectionError.http(400, "This connection does not support older transcript pages.") }
}

public enum MobileConnectionError: Error, LocalizedError {
  case http(Int, String), revoked, versionMismatch, invalidResponse, responseTooLarge, insecureEndpoint, offline
  public var errorDescription: String? {
    switch self {
    case .http(_, let message): message
    case .revoked: "This iPhone’s access was revoked or expired. Pair again on your Mac. Local notes remain available."
    case .versionMismatch: "The Mac and iPhone need compatible versions of Woven Matter. Local notes remain available."
    case .invalidResponse: "The Mac returned an unreadable response."
    case .responseTooLarge: "This response exceeds the iPhone’s download limit."
    case .insecureEndpoint: "Pair using the Tailscale HTTPS address shown by Woven Matter on your Mac."
    case .offline: "Connect to your running Mac to use agents. Your notes work offline."
    }
  }
}

/// No cookies, disk response cache or redirects. The bearer never leaves the
/// endpoint selected during pairing, including a redirect to another tailnet host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

public final class HTTPSCompanionTransport: CompanionTransport, @unchecked Sendable {
  private let credential: MobileCredential
  private let session: URLSession
  public init(credential: MobileCredential) throws {
    guard Self.validEndpoint(credential.endpoint) else { throw MobileConnectionError.insecureEndpoint }
    self.credential = credential
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }
  public static func pair(_ payload: CompanionPairingPayload, deviceID: String, deviceName: String) async throws -> MobileCredential {
    let provisional = MobileCredential(endpoint: payload.endpoint, workspaceID: "", deviceID: deviceID, token: "")
    let transport = try HTTPSCompanionTransport(credential: provisional)
    let request = CompanionPairRequest(token: payload.token, deviceID: deviceID, deviceName: deviceName, protocolVersion: payload.protocolVersion)
    let result: CompanionPairResponse = try await transport.request("v1/pair", method: "POST", body: JSONEncoder().encode(request))
    guard result.protocolVersion == CompanionProtocol.version, result.deviceID == deviceID else { throw MobileConnectionError.versionMismatch }
    return MobileCredential(endpoint: payload.endpoint, workspaceID: result.workspaceID, deviceID: result.deviceID, token: result.credential)
  }
  public func workspaceIdentity() async throws -> String {
    let hello: CompanionHello = try await request("v1/hello")
    guard hello.protocolVersion == CompanionProtocol.version else { throw MobileConnectionError.versionMismatch }
    guard hello.workspaceID == credential.workspaceID else { throw MobileStore.Failure.wrongWorkspace }
    return hello.workspaceID
  }
  public func snapshot() async throws -> CompanionSnapshot { try await request("v1/snapshot") }
  public func changes(after: Int64) async throws -> CompanionChangePage { try await request("v1/changes", query: [.init(name: "after", value: String(after)), .init(name: "limit", value: "200")]) }
  public func mutate(_ mutation: CompanionMutation) async throws -> CompanionMutationResult { try await request("v1/mutations", method: "POST", body: JSONEncoder().encode(mutation)) }
  public func note(_ id: String) async throws -> CompanionNote { try await request("v1/notes/\(try Self.safeID(id))") }
  public func linkedData(_ id: String, tableID: String?) async throws -> CompanionLinkedData { try await request("v1/assets/\(try Self.safeID(id))/linked-data", query: tableID.map { [.init(name: "tableID", value: $0)] } ?? []) }
  public func providers() async throws -> [CompanionProvider] { try await request("v1/providers") }
  public func pending() async throws -> [CompanionPendingInteraction] { try await request("v1/pending") }
  public func transcript(_ id: String) async throws -> CompanionTranscript { try await request("v1/sessions/\(try Self.safeID(id))/transcript") }
  public func transcript(_ id: String, before: String) async throws -> CompanionTranscript { try await request("v1/sessions/\(try Self.safeID(id))/transcript", query: [.init(name: "before", value: before)]) }
  public func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt { try await request("v1/commands", method: "POST", body: JSONEncoder().encode(command)) }
  public func receipt(_ id: String) async throws -> CompanionCommandReceipt? {
    do { return try await request("v1/command-receipts/\(try Self.safeID(id))") }
    catch MobileConnectionError.http(404, _) { return nil }
  }
  public func capabilities(_ id: String) async throws -> CompanionProvider { try await request("v1/sessions/\(try Self.safeID(id))/capabilities") }
  public func asset(_ id: String) async throws -> CompanionNote { try await request("v1/assets/\(try Self.safeID(id))") }

  private func request<Result: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Result {
    let (data, _) = try await data(path, method: method, query: query, body: body, maximumBytes: 80 * 1_024 * 1_024)
    return try JSONDecoder().decode(Result.self, from: data)
  }
  private func data(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
    var components = URLComponents(url: credential.endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!)
    request.httpMethod = method; request.httpBody = body
    request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if !credential.token.isEmpty {
      request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
      request.setValue(credential.workspaceID, forHTTPHeaderField: "X-Woven-Workspace")
    }
    #if !os(Linux)
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard response.expectedContentLength <= maximumBytes else { throw MobileConnectionError.responseTooLarge }
    var data = Data(); data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
    for try await byte in bytes {
      guard data.count < maximumBytes else { throw MobileConnectionError.responseTooLarge }
      data.append(byte)
    }
    #else
    let (data, rawResponse) = try await session.data(for: request)
    guard let response = rawResponse as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard data.count <= maximumBytes else { throw MobileConnectionError.responseTooLarge }
    #endif
    switch response.statusCode {
    case 200..<300: return (data, response)
    case 401, 403: throw MobileConnectionError.revoked
    case 426: throw MobileConnectionError.versionMismatch
    default:
      let error = try? JSONDecoder().decode(CompanionAPIError.self, from: data)
      throw MobileConnectionError.http(response.statusCode, error?.message ?? "Mac connection failed (\(response.statusCode)).")
    }
  }
  private static func safeID(_ id: String) throws -> String {
    guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { throw MobileConnectionError.invalidResponse }
    return id
  }
  private static func validEndpoint(_ url: URL) -> Bool {
    guard url.scheme == "https", let host = url.host?.lowercased(), host.hasSuffix(".ts.net"), url.user == nil,
          url.password == nil, url.query == nil, url.fragment == nil else { return false }
    return url.path == "/wovenmatter"
  }
}

public enum MobileCredentialVault {
  private static let service = "com.wovenmatter.companion.dev.pairing"
  public static func load() throws -> MobileCredential? {
    #if canImport(Security)
    var result: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: "paired-mac", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return try JSONDecoder().decode(MobileCredential.self, from: data)
    #else
    return nil
    #endif
  }
  public static func save(_ credential: MobileCredential) throws {
    #if canImport(Security)
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "paired-mac"]
    let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(credential), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecItemNotFound {
      let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    } else if updated != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
    #else
    throw MobileConnectionError.insecureEndpoint
    #endif
  }
}

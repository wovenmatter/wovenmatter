import Foundation
import WovenMatterCompanion
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public struct DirectWorkspaceCredential: Codable, Equatable, Sendable {
  public var endpoint: URL
  public var libraryID: String
  public var workspaceID: String
  public var deviceID: String
  public var token: String
  public init(endpoint: URL, libraryID: String, workspaceID: String, deviceID: String, token: String) {
    self.endpoint = endpoint; self.libraryID = libraryID; self.workspaceID = workspaceID; self.deviceID = deviceID; self.token = token
  }
}

/// Execution transport is independent of the central library. A local runtime
/// supplies the same interface without using HTTP or library connectivity.
public protocol ExecutionWorkspaceTransport: Sendable {
  func identity() async throws -> CompanionExecutionWorkspace
  func providers() async throws -> [CompanionProvider]
  func pending() async throws -> [CompanionPendingInteraction]
  func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt
  func receipt(_ id: String) async throws -> CompanionCommandReceipt?
  func events(after: Int64) async throws -> CompanionJournalPage
  func conversations() async throws -> [CompanionConversation]
  func transcript(_ id: String) async throws -> CompanionTranscript
  func transcript(_ id: String, before: String) async throws -> CompanionTranscript
  func capabilities(_ id: String) async throws -> CompanionProvider
  func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult
}

public extension ExecutionWorkspaceTransport {
  func transcript(_ id: String, before: String) async throws -> CompanionTranscript { throw MobileConnectionError.http(400, "Older history is unavailable for this workspace.") }
  func capabilities(_ id: String) async throws -> CompanionProvider { throw MobileConnectionError.http(400, "Session capabilities are unavailable for this workspace.") }
  func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult { throw MobileConnectionError.http(400, "This action is unavailable for this execution workspace.") }
}

public final class HTTPSExecutionWorkspaceTransport: ExecutionWorkspaceTransport, @unchecked Sendable {
  private let credential: DirectWorkspaceCredential
  private let client: TailnetJSONClient
  public init(credential: DirectWorkspaceCredential) throws {
    self.credential = credential
    client = try TailnetJSONClient(endpoint: credential.endpoint, token: credential.token,
      headers: ["X-Woven-Library": credential.libraryID, "X-Woven-Workspace": credential.workspaceID, "X-Woven-Device": credential.deviceID])
  }
  public func identity() async throws -> CompanionExecutionWorkspace {
    let value: CompanionExecutionWorkspace = try await client.request("v1/execution")
    guard value.id == credential.workspaceID, value.libraryID == credential.libraryID else { throw MobileStore.Failure.wrongWorkspace }
    return value
  }
  public func providers() async throws -> [CompanionProvider] {
    try await client.request("v1/execution/providers")
  }
  public func pending() async throws -> [CompanionPendingInteraction] {
    try await client.request("v1/execution/interactions")
  }
  public func command(_ command: CompanionCommand) async throws -> CompanionCommandReceipt {
    guard command.deviceID == credential.deviceID else { throw MobileConnectionError.revoked }
    // Identity is also carried in the body for workspace services behind private Serve.
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
    value["libraryID"] = credential.libraryID; value["workspaceID"] = credential.workspaceID
    return try await client.request("v1/execution/commands", method: "POST", body: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
  }
  public func receipt(_ id: String) async throws -> CompanionCommandReceipt? {
    do { return try await client.request("v1/execution/commands/" + TailnetJSONClient.safeID(id), query: [.init(name: "deviceID", value: credential.deviceID)]) }
    catch MobileConnectionError.http(404, _) { return nil }
  }
  public func events(after: Int64) async throws -> CompanionJournalPage {
    try await client.request("v1/execution/events", query: [.init(name: "after", value: String(after))])
  }
  public func conversations() async throws -> [CompanionConversation] {
    try await client.request("v1/execution/conversations")
  }
  public func transcript(_ id: String) async throws -> CompanionTranscript {
    try await client.request("v1/execution/conversations/" + TailnetJSONClient.safeID(id) + "/transcript")
  }
  public func transcript(_ id: String, before: String) async throws -> CompanionTranscript {
    try await client.request("v1/execution/conversations/" + TailnetJSONClient.safeID(id) + "/transcript", query: [.init(name: "before", value: before)])
  }
  public func capabilities(_ id: String) async throws -> CompanionProvider {
    try await client.request("v1/execution/conversations/" + TailnetJSONClient.safeID(id) + "/capabilities")
  }
  public func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
    try await client.request("v1/execution/workspace-read", method: "POST", body: JSONEncoder().encode(request))
  }
}

private final class RejectExecutionRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

final class TailnetJSONClient: @unchecked Sendable {
  private let endpoint: URL
  private let token: String
  private let headers: [String: String]
  private let session: URLSession
  init(endpoint: URL, token: String, headers: [String: String]) throws {
    guard endpoint.scheme == "https", endpoint.host?.lowercased().hasSuffix(".ts.net") == true,
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
      !endpoint.pathComponents.contains("..") else { throw MobileConnectionError.insecureEndpoint }
    self.endpoint = endpoint; self.token = token; self.headers = headers
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
    session = URLSession(configuration: configuration, delegate: RejectExecutionRedirects(), delegateQueue: nil)
  }
  static func safeID(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 200, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { throw MobileConnectionError.invalidResponse }
    return value
  }
  func request<Value: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Value {
    var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let maximum = 80 * 1_024 * 1_024
    #if !os(Linux)
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard response.expectedContentLength <= maximum else { throw MobileConnectionError.responseTooLarge }
    var data = Data()
    for try await byte in bytes {
      guard data.count < maximum else { throw MobileConnectionError.responseTooLarge }; data.append(byte)
    }
    #else
    let (data, rawResponse) = try await session.data(for: request)
    guard let response = rawResponse as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard data.count <= maximum else { throw MobileConnectionError.responseTooLarge }
    #endif
    switch response.statusCode {
    case 200..<300: return try JSONDecoder().decode(Value.self, from: data)
    case 401, 403: throw MobileConnectionError.revoked
    case 426: throw MobileConnectionError.versionMismatch
    default:
      let error = try? JSONDecoder().decode(CompanionAPIError.self, from: data)
      throw MobileConnectionError.http(response.statusCode, error?.message ?? "Workspace request failed (\(response.statusCode)).")
    }
  }
}

public enum WorkspaceCredentialVault {
  private static let service = "com.wovenmatter.execution.pairing"
  public static func load(workspaceID: String) throws -> DirectWorkspaceCredential? {
    #if canImport(Security)
    var value: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: workspaceID, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return try JSONDecoder().decode(DirectWorkspaceCredential.self, from: data)
    #else
    return nil
    #endif
  }
  public static func save(_ credential: DirectWorkspaceCredential) throws {
    #if canImport(Security)
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: credential.workspaceID]
    let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(credential), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      let inserted = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
    } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    #else
    throw MobileConnectionError.insecureEndpoint
    #endif
  }
}

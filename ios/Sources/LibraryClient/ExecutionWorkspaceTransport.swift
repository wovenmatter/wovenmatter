import CryptoKit
import Foundation
import WovenMatterShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// Whether a saved or newly issued direct workspace credential belongs to this
/// phone: its own device, and either its paired Mac's library or the workspace's
/// own registered namespace and endpoint (a workspace another paired Mac owns).
public enum WorkspaceCredentialPolicy {
  public static func accepts(_ credential: DirectWorkspaceCredential, deviceID: String, libraryID: String?,
                             registered: ExecutionWorkspace?) -> Bool {
    guard credential.deviceID == deviceID else { return false }
    if credential.libraryID == libraryID { return true }
    guard let registered, !registered.deleted, registered.id == credential.workspaceID else { return false }
    return registered.libraryID == credential.libraryID && registered.endpoint == credential.endpoint
  }
}

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
  func identity() async throws -> ExecutionWorkspace
  func providers() async throws -> [HarnessCapabilities]
  func pending() async throws -> [PendingInteraction]
  func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt
  func receipt(_ id: String) async throws -> LibraryCommandReceipt?
  func events(after: Int64) async throws -> ExecutionJournalPage
  func conversations() async throws -> [LibraryConversation]
  func transcript(_ id: String) async throws -> LibraryTranscript
  func transcript(_ id: String, before: String) async throws -> LibraryTranscript
  func capabilities(_ id: String) async throws -> HarnessCapabilities
  func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult
  /// One activity's complete projection, read when its disclosure opens
  /// (`GET v1/execution/conversations/<id>/activity?id=&run=`).
  func activityDetails(_ id: String, runID: String, activityID: String) async throws -> LibraryActivity
  /// A message file's bytes (`GET v1/execution/attachments/<sha256>?name=`),
  /// checked against its digest.
  func attachment(_ reference: LibraryAttachmentReference) async throws -> Data
}

public extension ExecutionWorkspaceTransport {
  func attachment(_ reference: LibraryAttachmentReference) async throws -> Data {
    throw MobileConnectionError.http(404, "This workspace does not serve its message files.")
  }
  func transcript(_ id: String, before: String) async throws -> LibraryTranscript { throw MobileConnectionError.http(400, "Older history is unavailable for this workspace.") }
  func capabilities(_ id: String) async throws -> HarnessCapabilities { throw MobileConnectionError.http(400, "Session capabilities are unavailable for this workspace.") }
  func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult { throw MobileConnectionError.http(400, "This action is unavailable for this execution workspace.") }
  func activityDetails(_ id: String, runID: String, activityID: String) async throws -> LibraryActivity {
    throw MobileConnectionError.http(404, "Activity details are unavailable for this workspace.")
  }
}

/// The query of an activity details read; activity IDs are free-form, so they travel as query values.
public func activityDetailsQuery(runID: String, activityID: String) -> [URLQueryItem] {
  [.init(name: "id", value: activityID), .init(name: "run", value: runID)]
}

public final class HTTPSExecutionWorkspaceTransport: ExecutionWorkspaceTransport, @unchecked Sendable {
  private let credential: DirectWorkspaceCredential
  private let client: TailnetJSONClient
  public var isSigned: Bool { client.signer != nil }
  public init(credential: DirectWorkspaceCredential, performer: (any MobileHTTPPerforming)? = nil) throws {
    self.credential = credential
    client = try TailnetJSONClient(endpoint: credential.endpoint, token: credential.token,
      headers: ["X-Woven-Library": credential.libraryID, "X-Woven-Workspace": credential.workspaceID, "X-Woven-Device": credential.deviceID],
      performer: performer)
  }
  /// Signed member requests straight to a Mac or Linux workspace's own
  /// execution endpoint. No grant is issued; the workspace checks the
  /// signature against its member list, whichever Macs are offline.
  /// `audience` is the member that serves the workspace (`MobileMembershipState.audience(for:)`);
  /// by default its execution device, which is a Mac's member ID.
  public init(workspace: ExecutionWorkspace, identity: MobileMemberIdentity, audience: String? = nil,
              performer: (any MobileHTTPPerforming)? = nil) throws {
    guard let endpoint = workspace.endpoint, !workspace.deleted else { throw MobileConnectionError.offline }
    guard let audience = (audience ?? workspace.executionDeviceID)?.lowercased(), MemberRequestSignature.isDeviceID(audience) else {
      throw MobileConnectionError.memberUnknown
    }
    credential = .init(endpoint: endpoint, libraryID: workspace.libraryID, workspaceID: workspace.id, deviceID: identity.deviceID, token: "")
    client = try TailnetJSONClient(endpoint: endpoint, token: "",
      headers: ["X-Woven-Library": workspace.libraryID, "X-Woven-Workspace": workspace.id, "X-Woven-Device": identity.deviceID],
      signer: identity.signer, audience: audience, performer: performer)
  }
  public func identity() async throws -> ExecutionWorkspace {
    let value: ExecutionWorkspace = try await client.request("v1/execution")
    guard value.id == credential.workspaceID, value.libraryID == credential.libraryID else { throw MobileStore.Failure.wrongWorkspace }
    return value
  }
  public func providers() async throws -> [HarnessCapabilities] {
    try await client.request("v1/execution/providers")
  }
  public func pending() async throws -> [PendingInteraction] {
    try await client.request("v1/execution/interactions")
  }
  public func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt {
    guard command.deviceID == credential.deviceID else { throw MobileConnectionError.revoked }
    // Identity is also carried in the body for workspace services behind private Serve.
    var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
    value["libraryID"] = credential.libraryID; value["workspaceID"] = credential.workspaceID
    return try await client.request("v1/execution/commands", method: "POST", body: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
  }
  public func receipt(_ id: String) async throws -> LibraryCommandReceipt? {
    do { return try await client.request("v1/execution/commands/" + TailnetJSONClient.safeID(id), query: [.init(name: "deviceID", value: credential.deviceID)]) }
    catch MobileConnectionError.http(404, _) { return nil }
  }
  public func events(after: Int64) async throws -> ExecutionJournalPage {
    try await client.request("v1/execution/events", query: [.init(name: "after", value: String(after))])
  }
  public func conversations() async throws -> [LibraryConversation] {
    try await client.request("v1/execution/conversations")
  }
  public func transcript(_ id: String) async throws -> LibraryTranscript {
    try await client.request("v1/execution/conversations/" + TailnetJSONClient.safeID(id) + "/transcript")
  }
  public func transcript(_ id: String, before: String) async throws -> LibraryTranscript {
    try await client.request("v1/execution/conversations/" + TailnetJSONClient.safeID(id) + "/transcript", query: [.init(name: "before", value: before)])
  }
  public func capabilities(_ id: String) async throws -> HarnessCapabilities {
    try await client.request("v1/execution/conversations/" + TailnetJSONClient.safeID(id) + "/capabilities")
  }
  public func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult {
    try await client.request("v1/execution/workspace-read", method: "POST", body: JSONEncoder().encode(request))
  }
  public func activityDetails(_ id: String, runID: String, activityID: String) async throws -> LibraryActivity {
    try await client.request("v1/execution/conversations/" + TailnetJSONClient.safeID(id) + "/activity",
      query: activityDetailsQuery(runID: runID, activityID: activityID))
  }
  public func attachment(_ reference: LibraryAttachmentReference) async throws -> Data {
    guard reference.isReadable else { throw MobileConnectionError.http(404, "This file was not saved with its message.") }
    let data = try await client.data(reference.readPath, query: [.init(name: "name", value: reference.name)],
                                     maximumBytes: LibraryAttachmentReference.maximumBytes)
    guard SHA256.hash(data: data).hexString == reference.id else { throw MobileConnectionError.invalidResponse }
    return data
  }
}

final class TailnetJSONClient: @unchecked Sendable {
  private let endpoint: URL
  private let token: String
  private let headers: [String: String]
  let signer: MemberRequestSigner?
  private let audience: String
  private let performer: any MobileHTTPPerforming
  init(endpoint: URL, token: String, headers: [String: String], signer: MemberRequestSigner? = nil, audience: String = "",
       performer: (any MobileHTTPPerforming)? = nil) throws {
    guard endpoint.scheme == "https", endpoint.host?.lowercased().hasSuffix(".ts.net") == true,
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
      !endpoint.pathComponents.contains("..") else { throw MobileConnectionError.insecureEndpoint }
    self.endpoint = endpoint; self.token = token; self.headers = headers; self.signer = signer; self.audience = audience
    self.performer = performer ?? URLSessionMobileHTTP(requestTimeout: 30, resourceTimeout: 60)
  }
  static func safeID(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 200, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { throw MobileConnectionError.invalidResponse }
    return value
  }
  func request<Value: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Value {
    try JSONDecoder().decode(Value.self, from: await data(path, method: method, query: query, body: body))
  }
  /// A 2xx reply's bytes, at most `maximumBytes`.
  func data(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
            maximumBytes: Int = 80 * 1_024 * 1_024) async throws -> Data {
    var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    if let signer { try MobileRequestSigning.sign(&request, with: signer, audience: audience) }
    else { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    let (data, response) = try await performer.perform(request, maximumBytes: maximumBytes, longLived: false)
    guard (200..<300).contains(response.statusCode) else {
      throw MobileRequestSigning.failure(status: response.statusCode, data: data, signed: signer != nil,
                                         fallback: "Workspace request failed (\(response.statusCode)).")
    }
    guard data.count <= maximumBytes else { throw MobileConnectionError.invalidResponse }
    return data
  }
}

public enum WorkspaceCredentialVault {
  private static var service: String { ClientCredentialNamespace.service("com.wovenmatter.execution.pairing") }
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
  public static func clear(workspaceID: String) throws {
    #if canImport(Security)
    let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: workspaceID] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
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

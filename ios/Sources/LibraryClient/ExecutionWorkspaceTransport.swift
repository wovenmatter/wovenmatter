import CryptoKit
import Foundation
import WovenMatterShared
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

/// Execution transport is independent of library sync. A local runtime
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
    client = try TailnetJSONClient(endpoint: endpoint,
      headers: ["X-Woven-Library": workspace.libraryID, "X-Woven-Workspace": workspace.id, "X-Woven-Device": identity.deviceID],
      signer: identity.signer, audience: audience, performer: performer)
  }
  public func identity() async throws -> ExecutionWorkspace {
    let value: ExecutionWorkspace = try await client.request("v1/execution")
    guard value.id == credential.workspaceID, value.libraryID == credential.libraryID else { throw MobileStore.Failure.wrongWorkspace }
    return value
  }
  public func providers() async throws -> [HarnessCapabilities] {
    try await client.list("v1/execution/providers")
  }
  public func pending() async throws -> [PendingInteraction] {
    try await client.list("v1/execution/interactions")
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
    try await client.list("v1/execution/conversations")
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
  private let headers: [String: String]
  let signer: MemberRequestSigner
  private let audience: String
  private let performer: any MobileHTTPPerforming
  init(endpoint: URL, headers: [String: String], signer: MemberRequestSigner, audience: String,
       performer: (any MobileHTTPPerforming)? = nil) throws {
    guard endpoint.scheme == "https", endpoint.host?.lowercased().hasSuffix(".ts.net") == true,
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
      !endpoint.pathComponents.contains("..") else { throw MobileConnectionError.insecureEndpoint }
    self.endpoint = endpoint; self.headers = headers; self.signer = signer; self.audience = audience
    self.performer = performer ?? URLSessionMobileHTTP(requestTimeout: 30, resourceTimeout: 60)
  }
  static func safeID(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 200, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { throw MobileConnectionError.invalidResponse }
    return value
  }
  func request<Value: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Value {
    try JSONDecoder().decode(Value.self, from: await data(path, method: method, query: query, body: body))
  }
  /// A list the workspace answers with. An element a newer workspace wrote and
  /// this build cannot read is dropped; the rest of the list still arrives.
  func list<Element: Decodable>(_ path: String) async throws -> [Element] {
    (try await request(path) as LossyArray<Element>).wrappedValue
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
    try MobileRequestSigning.sign(&request, with: signer, audience: audience)
    let (data, response) = try await performer.perform(request, maximumBytes: maximumBytes, longLived: false)
    guard (200..<300).contains(response.statusCode) else {
      throw MobileRequestSigning.failure(status: response.statusCode, data: data, signed: true,
                                         fallback: "Workspace request failed (\(response.statusCode)).")
    }
    guard data.count <= maximumBytes else { throw MobileConnectionError.invalidResponse }
    return data
  }
}


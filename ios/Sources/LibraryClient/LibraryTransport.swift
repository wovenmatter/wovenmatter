import Foundation
import WovenMatterShared
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
  public var confirmationPending: Bool?
  /// The paired Mac's member device ID, when it reported one.
  public var hostDeviceID: String?
  /// The libraries in that Mac's workspace registry, when it reported them.
  public var libraryIDs: [String]?
  public init(endpoint: URL, workspaceID: String, deviceID: String, token: String, confirmationPending: Bool? = nil, hostDeviceID: String? = nil,
              libraryIDs: [String]? = nil) {
    self.endpoint = endpoint; self.workspaceID = workspaceID; self.deviceID = deviceID; self.token = token; self.confirmationPending = confirmationPending
    self.hostDeviceID = hostDeviceID?.lowercased(); self.libraryIDs = libraryIDs
  }
}

public protocol LibraryTransport: Sendable {
  func executeMCP(_ message: GatewayJSONValue, conversationID: String, enabledGroups: [WorkspaceToolGroup], contextID: String?) async throws -> GatewayJSONValue
  func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult
  func workspaceIdentity() async throws -> String
  func snapshot() async throws -> LibrarySnapshot
  func changes(after: Int64) async throws -> LibraryChangePage
  func mutate(_ mutation: LibraryMutation) async throws -> LibraryMutationResult
  func note(_ id: String) async throws -> LibraryNote
  func linkedData(_ id: String, tableID: String?) async throws -> LinkedDataPreview
  func providers() async throws -> [HarnessCapabilities]
  func pending() async throws -> [PendingInteraction]
  func transcript(_ id: String) async throws -> LibraryTranscript
  func transcript(_ id: String, before: String) async throws -> LibraryTranscript
  func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt
  func receipt(_ id: String) async throws -> LibraryCommandReceipt?
}

public extension LibraryTransport {
  func executeMCP(_ message: GatewayJSONValue, conversationID: String, enabledGroups: [WorkspaceToolGroup], contextID: String? = nil) async throws -> GatewayJSONValue { throw MobileConnectionError.offline }
  func readWorkspace(_ request: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult { throw MobileConnectionError.offline }
  func linkedData(_ id: String, tableID: String?) async throws -> LinkedDataPreview { throw MobileConnectionError.offline }
  func transcript(_ id: String, before: String) async throws -> LibraryTranscript { throw MobileConnectionError.http(400, "This connection does not support older transcript pages.") }
}

public enum MobileConnectionError: Error, LocalizedError {
  case http(Int, String), revoked, versionMismatch, invalidResponse, responseTooLarge, insecureEndpoint, offline
  /// Signed: this host does not list this phone as a member (yet, or any more).
  case memberUnknown
  /// Signed: this host is too old to accept member requests.
  case memberUnsupported
  /// Devices disagree on versions; every device shows "Update everything".
  case updateRequired(String)
  public var errorDescription: String? {
    switch self {
    case .http(_, let message): message
    case .revoked: "This device’s access was revoked or expired. Pair again with the central Mac. Local notes remain available."
    case .versionMismatch: "These devices need compatible versions of Woven Matter. Local notes remain available."
    case .invalidResponse: "The connected workspace returned an unreadable response."
    case .responseTooLarge: "This response exceeds the client download limit."
    case .insecureEndpoint: "Pair using the Tailscale HTTPS address shown by Woven Matter on your Mac."
    case .offline: "This workspace is unavailable. Locally saved work remains available."
    case .memberUnknown: "This device doesn’t recognize your iPhone yet. It learns about it after it syncs with a Mac you paired with."
    case .memberUnsupported: "Update everything: this device needs a newer Woven Matter before your iPhone can connect directly."
    case .updateRequired(let message): "Update everything. " + message
    }
  }
}

/// No cookies, disk response cache or redirects. The bearer never leaves the
/// endpoint selected during pairing, including a redirect to another tailnet host.
public final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

private actor MCPSessionCache {
  struct Session: Sendable { let protocolVersion: String; let id: String? }
  private var sessions: [String: Task<Session, any Error>] = [:]
  func connect(_ conversationID: String, initialize: @escaping @Sendable () async throws -> Session) async throws -> Session {
    if let existing = sessions[conversationID] { return try await existing.value }
    let task = Task { try await initialize() }
    sessions[conversationID] = task
    do { return try await task.value }
    catch { sessions.removeValue(forKey: conversationID); throw error }
  }
}

/// Requests that confirm or end this device's pairing with central.
public protocol MobilePairingRequests: Sendable {
  func confirmPairing() async throws
  func unpair() async throws
}

public final class HTTPSLibraryTransport: LibraryTransport, MobilePairingRequests, @unchecked Sendable {
  let credential: MobileCredential
  /// Signed member requests (no bearer). Nil for bearer-era pairing.
  let signer: MemberRequestSigner?
  /// The host's member device ID, which every signed request names.
  let audience: String
  private let performer: any MobileHTTPPerforming
  private let mcpConnections = MCPSessionCache()
  private let deviceMetadata: DeviceMetadata?
  public var endpoint: URL { credential.endpoint }
  public var isSigned: Bool { signer != nil }
  public init(credential: MobileCredential, metadata: DeviceMetadata? = nil, signer: MemberRequestSigner? = nil,
              audience: String? = nil, performer: (any MobileHTTPPerforming)? = nil) throws {
    guard PairingPayload.isValidEndpoint(credential.endpoint) else { throw MobileConnectionError.insecureEndpoint }
    let audience = (audience ?? credential.hostDeviceID ?? "").lowercased()
    // A signed connection needs the host's member device ID; skip a host whose identity is not known yet.
    if signer != nil, !MemberRequestSignature.isDeviceID(audience) { throw MobileConnectionError.memberUnknown }
    self.credential = credential; self.deviceMetadata = metadata; self.signer = signer; self.audience = audience
    self.performer = performer ?? URLSessionMobileHTTP()
  }
  /// A signed connection to any Mac or Linux library host, the member
  /// `hostDeviceID`. Its library ID is whatever the host reports; the store
  /// decides whether to rebind.
  public convenience init(host endpoint: URL, hostDeviceID: String, identity: MobileMemberIdentity, metadata: DeviceMetadata? = nil,
                          performer: (any MobileHTTPPerforming)? = nil) throws {
    try self.init(credential: .init(endpoint: endpoint, workspaceID: "", deviceID: identity.deviceID, token: ""),
                  metadata: metadata, signer: identity.signer, audience: hostDeviceID, performer: performer)
  }
  public static func previewPairing(_ payload: PairingPayload, deviceID: String, deviceName: String,
                                    metadata: DeviceMetadata? = nil, performer: (any MobileHTTPPerforming)? = nil) async throws -> String {
    let provisional = MobileCredential(endpoint: payload.endpoint, workspaceID: "", deviceID: deviceID, token: "")
    let transport = try HTTPSLibraryTransport(credential: provisional, performer: performer)
    let request = PairRequest(token: payload.token, deviceID: deviceID, deviceName: deviceName,
      metadata: metadata, requiresConfirmation: true)
    let preview: PairingPreview = try await transport.request("v1/pair/preview", method: "POST", body: JSONEncoder().encode(request))
    return preview.workspaceID
  }
  public func confirmPairing() async throws {
    let _: [String: Bool] = try await request("v1/pair/confirm", method: "POST", body: Data("{}".utf8))
  }
  public func unpair() async throws {
    let _: [String: Bool] = try await request("v1/pair/unpair", method: "POST", body: Data("{}".utf8))
  }
  public static func pair(_ payload: PairingPayload, deviceID: String, deviceName: String,
                          metadata: DeviceMetadata? = nil, expectedWorkspaceID: String? = nil,
                          requiresConfirmation: Bool = false, memberPublicKey: Data? = nil,
                          performer: (any MobileHTTPPerforming)? = nil) async throws -> MobileCredential {
    let provisional = MobileCredential(endpoint: payload.endpoint, workspaceID: "", deviceID: deviceID, token: "")
    let transport = try HTTPSLibraryTransport(credential: provisional, metadata: metadata, performer: performer)
    var request = PairRequest(token: payload.token, deviceID: deviceID, deviceName: deviceName, protocolVersion: payload.protocolVersion, metadata: metadata, expectedWorkspaceID: expectedWorkspaceID, requiresConfirmation: requiresConfirmation ? true : nil)
    // The Mac signs an `ios` member entry for this key; the phone then signs
    // its requests to every Mac and Linux member, whichever is online.
    request.memberPublicKey = memberPublicKey
    let result: PairResponse = try await transport.request("v1/pair", method: "POST", body: JSONEncoder().encode(request))
    guard result.protocolVersion == LibraryProtocol.version, result.deviceID == deviceID else { throw MobileConnectionError.versionMismatch }
    guard expectedWorkspaceID == nil || result.workspaceID == expectedWorkspaceID,
      !requiresConfirmation || result.confirmationRequired == true else { throw MobileConnectionError.versionMismatch }
    return MobileCredential(endpoint: payload.endpoint, workspaceID: result.workspaceID, deviceID: result.deviceID,
      token: result.credential, confirmationPending: result.confirmationRequired,
      hostDeviceID: result.hostDeviceID.flatMap { MemberRequestSignature.isDeviceID($0.lowercased()) ? $0 : nil },
      libraryIDs: result.libraryIDs)
  }
  public func executeMCP(_ message: GatewayJSONValue, conversationID: String, enabledGroups: [WorkspaceToolGroup], contextID: String? = nil) async throws -> GatewayJSONValue {
    guard UUID(uuidString: conversationID) != nil else { throw MobileConnectionError.invalidResponse }
    var headers = ["X-Woven-Conversation-ID": conversationID,
      "X-Woven-Enabled-Groups": Set(enabledGroups).sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ","),
      "MCP-Protocol-Version": "2025-06-18"]
    if let contextID { headers["X-Woven-Context-ID"] = contextID }
    let initializationHeaders = headers
    let negotiated = try await mcpConnections.connect(conversationID) { [self] in
      let initialize: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString.lowercased()),
        "method": .string("initialize"), "params": .object(["protocolVersion": .string(WovenMCPServer.protocolVersion),
          "capabilities": .object([:]), "clientInfo": .object(["name": .string("woven-ios"), "version": .string("1.0.0")])])])
      let (bytes, response) = try await data("mcp", method: "POST", body: JSONEncoder().encode(initialize),
        maximumBytes: 1_048_576, timeout: 30, headers: initializationHeaders)
      let reply = try JSONDecoder().decode(GatewayJSONValue.self, from: bytes)
      guard let version = reply.objectValue?["result"]?.objectValue?["protocolVersion"]?.stringValue,
            WovenMCPServer.supportedProtocolVersions.contains(version) else { throw MobileConnectionError.versionMismatch }
      let sessionID = response.value(forHTTPHeaderField: "MCP-Session-Id")
      if let sessionID, sessionID.count > 512 || sessionID.contains("\r") || sessionID.contains("\n") { throw MobileConnectionError.invalidResponse }
      var notificationHeaders = initializationHeaders
      notificationHeaders["MCP-Protocol-Version"] = version
      if let sessionID { notificationHeaders["MCP-Session-Id"] = sessionID }
      let initialized: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])
      _ = try await data("mcp", method: "POST", body: JSONEncoder().encode(initialized),
        maximumBytes: 1_048_576, timeout: 30, headers: notificationHeaders)
      return MCPSessionCache.Session(protocolVersion: version, id: sessionID)
    }
    headers["MCP-Protocol-Version"] = negotiated.protocolVersion
    if let sessionID = negotiated.id { headers["MCP-Session-Id"] = sessionID }
    let (responseData, _) = try await data("mcp", method: "POST", body: JSONEncoder().encode(message),
      maximumBytes: 80 * 1_024 * 1_024, timeout: 24 * 60 * 60, headers: headers)
    return try JSONDecoder().decode(GatewayJSONValue.self, from: responseData)
  }
  public func readWorkspace(_ value: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult { try await request("v1/workspace-read", method: "POST", body: JSONEncoder().encode(value)) }
  public func workspaceIdentity() async throws -> String {
    let hello: LibraryHello = try await request("v1/hello")
    guard hello.protocolVersion == LibraryProtocol.version else { throw MobileConnectionError.versionMismatch }
    // A signed host connection reports its own library ID; the store binds or rebinds.
    guard (signer != nil && credential.workspaceID.isEmpty) || hello.workspaceID == credential.workspaceID else { throw MobileStore.Failure.wrongWorkspace }
    return hello.workspaceID
  }
  /// Members with endpoints, as this host resolves them.
  public func members() async throws -> MobileLibraryMemberList { try await request("v1/members", timeout: 15) }
  /// Every peer's synchronization state on this host, for "Update everything".
  public func syncStatus() async throws -> MobileLibrarySyncStatus { try await request("v1/sync/status", timeout: 15) }
  /// A short reachability and identity probe used when choosing a library host.
  public func probe(timeout: TimeInterval = 8) async throws -> LibraryHello {
    let hello: LibraryHello = try await request("v1/hello", timeout: timeout)
    guard hello.protocolVersion == LibraryProtocol.version else { throw MobileConnectionError.versionMismatch }
    return hello
  }
  public func snapshot() async throws -> LibrarySnapshot { try await request("v1/snapshot") }
  public func changes(after: Int64) async throws -> LibraryChangePage { try await request("v1/changes", query: [.init(name: "after", value: String(after)), .init(name: "limit", value: "200")]) }
  public func mutate(_ mutation: LibraryMutation) async throws -> LibraryMutationResult { try await request("v1/mutations", method: "POST", body: JSONEncoder().encode(mutation)) }
  public func note(_ id: String) async throws -> LibraryNote { try await request("v1/notes/\(try Self.safeID(id))") }
  public func linkedData(_ id: String, tableID: String?) async throws -> LinkedDataPreview { try await request("v1/assets/\(try Self.safeID(id))/linked-data", query: tableID.map { [.init(name: "tableID", value: $0)] } ?? []) }
  public func providers() async throws -> [HarnessCapabilities] { try await request("v1/providers") }
  public func pending() async throws -> [PendingInteraction] { try await request("v1/pending") }
  public func transcript(_ id: String) async throws -> LibraryTranscript { try await request("v1/sessions/\(try Self.safeID(id))/transcript") }
  public func transcript(_ id: String, before: String) async throws -> LibraryTranscript { try await request("v1/sessions/\(try Self.safeID(id))/transcript", query: [.init(name: "before", value: before)]) }
  public func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt { try await request("v1/commands", method: "POST", body: JSONEncoder().encode(command)) }
  public func receipt(_ id: String) async throws -> LibraryCommandReceipt? {
    do { return try await request("v1/command-receipts/\(try Self.safeID(id))") }
    catch MobileConnectionError.http(404, _) { return nil }
  }
  public func deviceConnections() async throws -> [DeviceConnection] { try await request("v1/devices") }
  public func suspendDevelopmentConnection() async throws {
    let _: [String: Bool] = try await request("v1/devices/development/disconnect", method: "POST", body: Data("{}".utf8), timeout: 3)
  }
  public func capabilities(_ id: String) async throws -> HarnessCapabilities { try await request("v1/sessions/\(try Self.safeID(id))/capabilities") }
  public func asset(_ id: String) async throws -> LibraryNote { try await request("v1/assets/\(try Self.safeID(id))") }

  func request<Result: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval? = nil) async throws -> Result {
    let (data, _) = try await data(path, method: method, query: query, body: body, maximumBytes: 80 * 1_024 * 1_024, timeout: timeout)
    return try JSONDecoder().decode(Result.self, from: data)
  }
  private func data(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, maximumBytes: Int, timeout: TimeInterval? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
    var components = URLComponents(url: credential.endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!)
    if let timeout { request.timeoutInterval = timeout }
    request.httpMethod = method; request.httpBody = body
    request.setValue(String(LibraryProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let deviceMetadata {
      request.setValue(deviceMetadata.kind.rawValue, forHTTPHeaderField: "X-Woven-Device-Kind")
      if let value = deviceMetadata.developmentInstance { request.setValue(value, forHTTPHeaderField: "X-Woven-Development-Instance") }
      if let value = deviceMetadata.osVersion { request.setValue(value, forHTTPHeaderField: "X-Woven-OS-Version") }
      if let value = deviceMetadata.appVersion { request.setValue(value, forHTTPHeaderField: "X-Woven-App-Version") }
    }
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if let signer {
      if !credential.workspaceID.isEmpty { request.setValue(credential.workspaceID, forHTTPHeaderField: "X-Woven-Workspace") }
      try MobileRequestSigning.sign(&request, with: signer, audience: audience)
    } else if !credential.token.isEmpty {
      request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
      request.setValue(credential.workspaceID, forHTTPHeaderField: "X-Woven-Workspace")
    }
    let (data, response) = try await performer.perform(request, maximumBytes: maximumBytes, longLived: headers["MCP-Protocol-Version"] != nil)
    guard (200..<300).contains(response.statusCode) else {
      throw MobileRequestSigning.failure(status: response.statusCode, data: data, signed: signer != nil,
                                         fallback: "Mac connection failed (\(response.statusCode)).")
    }
    return (data, response)
  }
  private static func safeID(_ id: String) throws -> String {
    guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { throw MobileConnectionError.invalidResponse }
    return id
  }
}

public enum MobileCredentialVault {
  private static var service: String { ClientCredentialNamespace.service("com.wovenmatter.wovenmatter.pairing") }
  public static func load() throws -> MobileCredential? {
    #if canImport(Security)
    LegacyKeychainItem.move(from: ClientCredentialNamespace.service("com.wovenmatter.companion.dev.pairing"), to: service, account: "paired-mac")
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
  /// Disconnect the central library only. Provider and direct-workspace grants
  /// use different services and remain available on this device.
  public static func clear() throws {
    #if canImport(Security)
    let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: "paired-mac"] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
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

#if canImport(Security)
/// Desktop apps from before November 2026 saved these items under
/// `com.wovenmatter.companion.*` services. An item moves once, the first time it
/// is read, so a Mac that is a library client stays paired.
enum LegacyKeychainItem {
  static func move(from legacy: String, to service: String, account: String) {
    let current: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    guard SecItemCopyMatching(current as CFDictionary, nil) == errSecItemNotFound else { return }
    let old: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: legacy, kSecAttrAccount: account]
    var result: CFTypeRef?
    guard SecItemCopyMatching(old.merging([kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) { _, new in new } as CFDictionary,
                              &result) == errSecSuccess, let data = result as? Data else { return }
    let added = SecItemAdd(current.merging([kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new } as CFDictionary, nil)
    if added == errSecSuccess { SecItemDelete(old as CFDictionary) }
  }
}
#endif

/// Multiple desktop instances share a Keychain but must never share a device's
/// library bearer. Preserve the established service for ordinary installations.
public enum ClientCredentialNamespace {
  public static func service(_ base: String) -> String {
    guard let bundleID = Bundle.main.bundleIdentifier, bundleID.hasPrefix("wovenmatter.desktop.dev.") else { return base }
    return base + "." + bundleID
  }
}

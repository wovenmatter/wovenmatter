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
  public var confirmationPending: Bool?
  public var relocationID: String? = nil
  public var centralLibraryID: String? = nil
  public var migrationCandidates: [URL]? = nil
  public init(endpoint: URL, workspaceID: String, deviceID: String, token: String, confirmationPending: Bool? = nil) {
    self.endpoint = endpoint; self.workspaceID = workspaceID; self.deviceID = deviceID; self.token = token; self.confirmationPending = confirmationPending
  }
}

public protocol CompanionTransport: Sendable {
  func libraryRelocationID() async -> String?
  func rememberLibraryCandidates(_ candidates: [URL]) async throws
  func executeMCP(_ message: GatewayJSONValue, conversationID: String, enabledGroups: [WorkspaceToolGroup], contextID: String?) async throws -> GatewayJSONValue
  func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult
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
  func libraryRelocationID() async -> String? { nil }
  func rememberLibraryCandidates(_ candidates: [URL]) async throws {}
  func executeMCP(_ message: GatewayJSONValue, conversationID: String, enabledGroups: [WorkspaceToolGroup], contextID: String? = nil) async throws -> GatewayJSONValue { throw MobileConnectionError.offline }
  func readWorkspace(_ request: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult { throw MobileConnectionError.offline }
  func linkedData(_ id: String, tableID: String?) async throws -> CompanionLinkedData { throw MobileConnectionError.offline }
  func transcript(_ id: String, before: String) async throws -> CompanionTranscript { throw MobileConnectionError.http(400, "This connection does not support older transcript pages.") }
}

public enum MobileConnectionError: Error, LocalizedError {
  case http(Int, String), revoked, versionMismatch, invalidResponse, responseTooLarge, insecureEndpoint, offline
  public var errorDescription: String? {
    switch self {
    case .http(_, let message): message
    case .revoked: "This device’s access was revoked or expired. Pair again with the central Mac. Local notes remain available."
    case .versionMismatch: "These devices need compatible versions of Woven Matter. Local notes remain available."
    case .invalidResponse: "The connected workspace returned an unreadable response."
    case .responseTooLarge: "This response exceeds the client download limit."
    case .insecureEndpoint: "Pair using the Tailscale HTTPS address shown by Woven Matter on your Mac."
    case .offline: "This workspace is unavailable. Locally saved work remains available."
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

private actor CompanionMCPConnections {
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

public final class HTTPSCompanionTransport: CompanionTransport, @unchecked Sendable {
  private let credentialLock = NSLock()
  private var storedCredential: MobileCredential
  public var credential: MobileCredential { credentialLock.withLock { storedCredential } }
  private let session: URLSession
  private let mcpSession: URLSession
  private let mcpConnections = CompanionMCPConnections()
  private let deviceMetadata: CompanionDeviceMetadata?
  private let persistCredential: @Sendable (MobileCredential) throws -> Void
  public init(credential: MobileCredential, metadata: CompanionDeviceMetadata? = nil,
              persistCredential: @escaping @Sendable (MobileCredential) throws -> Void = { try MobileCredentialVault.save($0) }) throws {
    guard Self.validEndpoint(credential.endpoint) else { throw MobileConnectionError.insecureEndpoint }
    self.storedCredential = credential; self.deviceMetadata = metadata
    self.persistCredential = persistCredential
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    let mcpConfiguration = URLSessionConfiguration.ephemeral
    mcpConfiguration.httpCookieStorage = nil; mcpConfiguration.urlCache = nil
    mcpConfiguration.timeoutIntervalForRequest = 24 * 60 * 60
    mcpConfiguration.timeoutIntervalForResource = 24 * 60 * 60
    mcpSession = URLSession(configuration: mcpConfiguration, delegate: NoRedirects(), delegateQueue: nil)
  }
  public static func previewPairing(_ payload: CompanionPairingPayload, deviceID: String, deviceName: String,
                                    metadata: CompanionDeviceMetadata? = nil) async throws -> String {
    let provisional = MobileCredential(endpoint: payload.endpoint, workspaceID: "", deviceID: deviceID, token: "")
    let transport = try HTTPSCompanionTransport(credential: provisional)
    let request = CompanionPairRequest(token: payload.token, deviceID: deviceID, deviceName: deviceName,
      metadata: metadata, requiresConfirmation: true)
    let preview: CompanionPairingPreview = try await transport.request("v1/pair/preview", method: "POST", body: JSONEncoder().encode(request))
    return preview.workspaceID
  }
  public func confirmPairing() async throws {
    let _: [String: Bool] = try await request("v1/pair/confirm", method: "POST", body: Data("{}".utf8))
  }
  public func unpair() async throws {
    let _: [String: Bool] = try await request("v1/pair/unpair", method: "POST", body: Data("{}".utf8))
  }
  public static func pair(_ payload: CompanionPairingPayload, deviceID: String, deviceName: String,
                          metadata: CompanionDeviceMetadata? = nil, expectedWorkspaceID: String? = nil,
                          requiresConfirmation: Bool = false) async throws -> MobileCredential {
    let provisional = MobileCredential(endpoint: payload.endpoint, workspaceID: "", deviceID: deviceID, token: "")
    let transport = try HTTPSCompanionTransport(credential: provisional, metadata: metadata)
    let request = CompanionPairRequest(token: payload.token, deviceID: deviceID, deviceName: deviceName, protocolVersion: payload.protocolVersion, metadata: metadata, expectedWorkspaceID: expectedWorkspaceID, requiresConfirmation: requiresConfirmation ? true : nil)
    let result: CompanionPairResponse = try await transport.request("v1/pair", method: "POST", body: JSONEncoder().encode(request))
    guard result.protocolVersion == CompanionProtocol.version, result.deviceID == deviceID else { throw MobileConnectionError.versionMismatch }
    guard expectedWorkspaceID == nil || result.workspaceID == expectedWorkspaceID,
      !requiresConfirmation || result.confirmationRequired == true else { throw MobileConnectionError.versionMismatch }
    return MobileCredential(endpoint: payload.endpoint, workspaceID: result.workspaceID, deviceID: result.deviceID,
      token: result.credential, confirmationPending: result.confirmationRequired)
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
      return CompanionMCPConnections.Session(protocolVersion: version, id: sessionID)
    }
    headers["MCP-Protocol-Version"] = negotiated.protocolVersion
    if let sessionID = negotiated.id { headers["MCP-Session-Id"] = sessionID }
    let (responseData, _) = try await data("mcp", method: "POST", body: JSONEncoder().encode(message),
      maximumBytes: 80 * 1_024 * 1_024, timeout: 24 * 60 * 60, headers: headers)
    return try JSONDecoder().decode(GatewayJSONValue.self, from: responseData)
  }
  public func readWorkspace(_ value: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult { try await request("v1/workspace-read", method: "POST", body: JSONEncoder().encode(value)) }
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
  public func deviceConnections() async throws -> [CompanionDeviceConnection] { try await request("v1/devices") }
  public func capabilities(_ id: String) async throws -> CompanionProvider { try await request("v1/sessions/\(try Self.safeID(id))/capabilities") }
  public func asset(_ id: String) async throws -> CompanionNote { try await request("v1/assets/\(try Self.safeID(id))") }

  func request<Result: Decodable>(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval? = nil) async throws -> Result {
    let (data, _) = try await data(path, method: method, query: query, body: body, maximumBytes: 80 * 1_024 * 1_024, timeout: timeout)
    return try JSONDecoder().decode(Result.self, from: data)
  }
  private func data(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, maximumBytes: Int, timeout: TimeInterval? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
    for _ in 0..<8 {
      do { return try await sendData(path, method: method, query: query, body: body, maximumBytes: maximumBytes, timeout: timeout, headers: headers) }
      catch let moved as LibraryRelocationSignal { try acceptRelocation(moved.relocation, expectedEndpoint: moved.previousEndpoint) }
      catch let error as URLError {
        let previous = credential
        guard let relocation = try? await LibraryRelocationResolver.find(credential: previous) else { throw error }
        try acceptRelocation(relocation, expectedEndpoint: previous.endpoint)
      }
    }
    throw MobileConnectionError.http(409, "The database transfer route needs attention on its central Mac. Your local work is retained.")
  }
  public func libraryRelocationID() async -> String? { credential.relocationID }
  public func rememberLibraryCandidates(_ candidates: [URL]) async throws {
    credentialLock.withLock {
      let valid = Array(Set((storedCredential.migrationCandidates ?? []) + candidates.filter(Self.validEndpoint))).sorted { $0.absoluteString < $1.absoluteString }
      guard valid != storedCredential.migrationCandidates else { return }
      var next = storedCredential; next.migrationCandidates = Array(valid.prefix(64))
      // Discovery hints are optional. A temporarily locked Keychain must not
      // prevent publishing durable history through an already working connection.
      try? persistCredential(next)
      storedCredential = next
    }
  }
  private func acceptRelocation(_ relocation: CompanionLibraryRelocation, expectedEndpoint: URL) throws {
    try credentialLock.withLock {
    let existing = storedCredential
    guard existing.endpoint == expectedEndpoint else { return }
    guard relocation.previousLibraryID == existing.workspaceID, UUID(uuidString: relocation.transferID) != nil,
          UUID(uuidString: relocation.libraryID) != nil, Self.validEndpoint(relocation.endpoint),
          relocation.endpoint != existing.endpoint else { throw MobileConnectionError.invalidResponse }
    var next = existing; next.endpoint = relocation.endpoint; next.relocationID = relocation.transferID; next.centralLibraryID = relocation.libraryID
    // Persist the route before using it. The sync engine resets only central
    // cursors; pending operations and direct-owner credentials keep their IDs.
    try persistCredential(next)
    storedCredential = next
    }
  }
  private func sendData(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil, maximumBytes: Int, timeout: TimeInterval? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
    let credential = self.credential
    var components = URLComponents(url: credential.endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: components.url!)
    if let timeout { request.timeoutInterval = timeout }
    request.httpMethod = method; request.httpBody = body
    request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let deviceMetadata {
      request.setValue(deviceMetadata.kind.rawValue, forHTTPHeaderField: "X-Woven-Device-Kind")
      if let value = deviceMetadata.osVersion { request.setValue(value, forHTTPHeaderField: "X-Woven-OS-Version") }
      if let value = deviceMetadata.appVersion { request.setValue(value, forHTTPHeaderField: "X-Woven-App-Version") }
    }
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if !credential.token.isEmpty {
      request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
      request.setValue(credential.workspaceID, forHTTPHeaderField: "X-Woven-Workspace")
    }
    #if !os(Linux)
    let (bytes, response) = try await (headers["MCP-Protocol-Version"] == nil ? session : mcpSession).bytes(for: request)
    guard let response = response as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard response.expectedContentLength <= maximumBytes else { throw MobileConnectionError.responseTooLarge }
    var data = Data(); data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
    for try await byte in bytes {
      guard data.count < maximumBytes else { throw MobileConnectionError.responseTooLarge }
      data.append(byte)
    }
    #else
    let (data, rawResponse) = try await (headers["MCP-Protocol-Version"] == nil ? session : mcpSession).data(for: request)
    guard let response = rawResponse as? HTTPURLResponse else { throw MobileConnectionError.invalidResponse }
    guard data.count <= maximumBytes else { throw MobileConnectionError.responseTooLarge }
    #endif
    switch response.statusCode {
    case 200..<300: return (data, response)
    case 409:
      if let moved = try? JSONDecoder().decode(CompanionLibraryMoved.self, from: data), moved.code == "library_moved" {
        throw LibraryRelocationSignal(relocation: moved.relocation, previousEndpoint: credential.endpoint)
      }
      let error = try? JSONDecoder().decode(CompanionAPIError.self, from: data)
      throw MobileConnectionError.http(409, error?.message ?? "The library could not accept this change.")
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
  private static var service: String { ClientCredentialNamespace.service("com.wovenmatter.companion.dev.pairing") }
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

/// Multiple desktop instances share a Keychain but must never share a device's
/// library bearer. Preserve the established service for ordinary installations.
public enum ClientCredentialNamespace {
  public static func service(_ base: String, bundleID: String? = Bundle.main.bundleIdentifier) -> String {
    guard let bundleID, bundleID.hasPrefix("wovenmatter.desktop.dev.") else { return base }
    return base + "." + bundleID
  }
}

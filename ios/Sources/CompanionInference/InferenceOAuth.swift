import Foundation
import CryptoKit
import Security

public struct InferenceOAuthCredential: Codable, Sendable, Equatable, CustomStringConvertible {
  public let type: String
  public let provider: String
  public let access: String
  public let refresh: String
  /// Effective refresh deadline, in Unix milliseconds (matching the pinned Pi credential contract).
  public let expires: Double
  public let accountID: String
  public let bindingID: String
  public let subject: String?
  public var description: String { "InferenceOAuthCredential(provider: \(provider), credentials: redacted)" }
  public init(provider: String, access: String, refresh: String, expires: Double, accountID: String,
              bindingID: String = UUID().uuidString, subject: String? = nil) throws {
    self.type = "oauth"; self.provider = provider; self.access = access; self.refresh = refresh
    self.expires = expires; self.accountID = accountID; self.bindingID = bindingID; self.subject = subject
    try validate()
  }
  enum CodingKeys: String, CodingKey { case type, provider, access, refresh, expires, accountID = "accountId", bindingID, subject }
  public func serialized() throws -> String {
    try validate()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
  public static func decode(_ value: String) throws -> Self {
    guard value.utf8.count < 65536, let data = value.data(using: .utf8), let credential = try? JSONDecoder().decode(Self.self, from: data) else { throw InferenceOAuthError.signInRequired }
    try credential.validate(); return credential
  }
  func validate() throws {
    guard type == "oauth", InferenceOAuthSession.supports(provider), expires.isFinite, expires > 0,
      [access, refresh, accountID, bindingID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 32768 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
      accountID.utf8.count <= 512, bindingID.utf8.count <= 512,
      subject == nil || (subject!.utf8.count <= 512 && !subject!.isEmpty && !subject!.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)) else { throw InferenceOAuthError.invalidResponse }
    if provider == "openai-codex", InferenceOAuthClient.openAIAccount(access) != accountID { throw InferenceOAuthError.accountChanged }
  }
}

public struct InferenceOAuthChallenge: Sendable, Equatable {
  public enum Kind: Sendable, Equatable { case deviceCode, authorizationCode }
  public let provider: String
  public let kind: Kind
  public let verificationURL: URL
  public let userCode: String?
  public let expiresAt: Date
}

public enum InferenceOAuthError: Error, LocalizedError, Sendable, Equatable {
  case unsupportedProvider, deviceCodeUnavailable, authorizationDenied, expired, invalidResponse, connectionFailed, signInRequired, credentialChanged, accountChanged, sessionUnavailable, stateMismatch
  public var errorDescription: String? {
    switch self {
    case .unsupportedProvider: "This provider does not support direct sign-in in this app. Choose a supported connection."
    case .deviceCodeUnavailable: "Device-code sign-in is unavailable for this ChatGPT account. Check the device-code sign-in setting in ChatGPT security settings, then try again."
    case .authorizationDenied: "Sign-in was declined. Start again when you are ready."
    case .expired: "This sign-in code expired. Start sign-in again to get a new code."
    case .invalidResponse: "The sign-in service returned an invalid response. No credentials were saved."
    case .connectionFailed: "The sign-in service could not be reached. Check your connection and try again."
    case .signInRequired: "Sign in to this subscription on this device before using it."
    case .credentialChanged: "This connection changed during token refresh. Retry with the connection you selected."
    case .accountChanged: "The subscription account changed. Sign in explicitly to the account you want to use."
    case .sessionUnavailable: "Start sign-in before checking its result."
    case .stateMismatch: "The authorization response does not belong to this sign-in attempt. Start again and paste the complete code and state."
    }
  }
}

public struct InferenceOAuthHTTPResponse: Sendable {
  public let status: Int
  public let data: Data
  public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public protocol InferenceOAuthHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> InferenceOAuthHTTPResponse
}

/// Authentication traffic never follows redirects, uses shared cookies, or enters the model transport.
public final class InferenceOAuthURLSessionTransport: NSObject, InferenceOAuthHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
  public override init() { super.init() }
  public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
  public func send(_ request: URLRequest) async throws -> InferenceOAuthHTTPResponse {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
    config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
    let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 131072 else { throw InferenceOAuthError.invalidResponse }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < 131072 else { throw InferenceOAuthError.invalidResponse }
        data.append(byte)
      }
      return .init(status: response.statusCode, data: data)
    } catch is CancellationError { throw CancellationError() }
    catch let error as InferenceOAuthError { throw error }
    catch { if Task.isCancelled { throw CancellationError() }; throw InferenceOAuthError.connectionFailed }
  }
}

struct InferenceOAuthClient: Sendable {
  let transport: any InferenceOAuthHTTPTransport
  let now: @Sendable () -> Date
  let sleep: @Sendable (TimeInterval) async throws -> Void
  static let openAIClient = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let xaiClient = "b1a00492-073a-47ea-816f-4c329264a828"
  static let claudeClient = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  static let claudeCallback = "https://platform.claude.com/oauth/code/callback"
  struct Pending: Sendable {
    let challenge: InferenceOAuthChallenge
    let deviceCode: String
    let interval: TimeInterval
    let bindingID: String
    var verifier: String? = nil
    var state: String? = nil
  }
  func begin(_ provider: String) async throws -> Pending {
    guard InferenceOAuthSession.supports(provider) else { throw InferenceOAuthError.unsupportedProvider }
    if provider == "claude-subscription" {
      let verifier = try Self.random(), state = try Self.random()
      let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
      var url = URLComponents(string: "https://claude.ai/oauth/authorize")!
      url.queryItems = ["code": "true", "client_id": Self.claudeClient, "response_type": "code", "redirect_uri": Self.claudeCallback,
        "scope": "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
        "code_challenge": challenge, "code_challenge_method": "S256", "state": state].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
      return Pending(challenge: .init(provider: provider, kind: .authorizationCode, verificationURL: url.url!, userCode: nil, expiresAt: now().addingTimeInterval(900)),
        deviceCode: "", interval: 0, bindingID: UUID().uuidString, verifier: verifier, state: state)
    }
    let openAI = provider == "openai-codex"
    let response = try await post(openAI ? "https://auth.openai.com/api/accounts/deviceauth/usercode" : "https://auth.x.ai/oauth2/device/code",
      fields: openAI ? ["client_id": Self.openAIClient] : ["client_id": Self.xaiClient, "scope": "openid profile email offline_access grok-cli:access api:access", "referrer": "wovenmatter"], json: openAI)
    if openAI && response.status == 404 { throw InferenceOAuthError.deviceCodeUnavailable }
    guard response.status == 200 else { throw failure(response) }
    let body = try object(response)
    let code = try string(body, openAI ? "device_auth_id" : "device_code")
    let userCode = try string(body, "user_code")
    guard userCode.count <= 128 else { throw InferenceOAuthError.invalidResponse }
    let lifetime = openAI ? 900 : try positive(body["expires_in"], max: 86400)
    let interval: Double
    if openAI {
      let value = (body["interval"] as? Double) ?? Double(body["interval"] as? String ?? "")
      guard let value, value.isFinite, value >= 0, value <= 300 else { throw InferenceOAuthError.invalidResponse }
      interval = max(1, value)
    } else { interval = min(300, max(1, body["interval"] as? Double ?? 5)) }
    let url: URL
    if openAI { url = URL(string: "https://auth.openai.com/codex/device")! }
    else {
      _ = try verificationURL(try string(body, "verification_uri"))
      url = try verificationURL((body["verification_uri_complete"] as? String) ?? string(body, "verification_uri"))
    }
    return Pending(challenge: .init(provider: provider, kind: .deviceCode, verificationURL: url, userCode: userCode, expiresAt: now().addingTimeInterval(lifetime)),
      deviceCode: code, interval: interval, bindingID: UUID().uuidString)
  }
  func poll(_ pending: Pending) async throws -> InferenceOAuthCredential {
    guard pending.challenge.kind == .deviceCode else { throw InferenceOAuthError.sessionUnavailable }
    let openAI = pending.challenge.provider == "openai-codex"
    var interval = pending.interval
    if !openAI { try await pause(interval, deadline: pending.challenge.expiresAt) }
    while now() < pending.challenge.expiresAt {
      try Task.checkCancellation()
      let response = try await post(openAI ? "https://auth.openai.com/api/accounts/deviceauth/token" : "https://auth.x.ai/oauth2/token",
        fields: openAI ? ["device_auth_id": pending.deviceCode, "user_code": pending.challenge.userCode ?? ""] :
          ["grant_type": "urn:ietf:params:oauth:grant-type:device_code", "client_id": Self.xaiClient, "device_code": pending.deviceCode], json: openAI)
      try Task.checkCancellation()
      guard now() < pending.challenge.expiresAt else { throw InferenceOAuthError.expired }
      if response.status == 200 {
        if openAI {
          let body = try object(response)
          let token = try await post("https://auth.openai.com/oauth/token", fields: ["grant_type": "authorization_code", "client_id": Self.openAIClient,
            "code": try string(body, "authorization_code"), "code_verifier": try string(body, "code_verifier"), "redirect_uri": "https://auth.openai.com/deviceauth/callback"])
          guard token.status == 200 else { throw failure(token) }
          return try credential(object(token), provider: pending.challenge.provider, bindingID: pending.bindingID)
        }
        return try credential(object(response), provider: pending.challenge.provider, bindingID: pending.bindingID)
      }
      let code = errorCode(response)
      if code == "slow_down" {
        let serverInterval = (try? object(response))?["interval"] as? Double
        interval = min(300, max(interval + 5, serverInterval ?? 0))
      } else if ["access_denied", "authorization_denied", "expired_token", "invalid_grant", "invalid_token"].contains(code ?? "") {
        throw failure(response)
      } else if code == "authorization_pending" || code == "deviceauth_authorization_pending" || (openAI && [403, 404].contains(response.status)) {
        // The provider has not completed the user-authorized device flow.
      } else { throw failure(response) }
      try await pause(interval, deadline: pending.challenge.expiresAt)
    }
    throw InferenceOAuthError.expired
  }
  func complete(_ input: String, pending: Pending) async throws -> InferenceOAuthCredential {
    try Task.checkCancellation()
    guard pending.challenge.kind == .authorizationCode, let state = pending.state, let verifier = pending.verifier else { throw InferenceOAuthError.sessionUnavailable }
    guard now() < pending.challenge.expiresAt else { throw InferenceOAuthError.expired }
    let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard input.utf8.count <= 32768 else { throw InferenceOAuthError.stateMismatch }
    let code: String, returnedState: String
    if input.contains("://") {
      guard let url = URLComponents(string: input), url.scheme == "https", url.host == "platform.claude.com",
        url.path == "/oauth/code/callback", url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
        let items = url.queryItems, items.filter({ $0.name == "code" }).count == 1, items.filter({ $0.name == "state" }).count == 1,
        let value = items.first(where: { $0.name == "code" })?.value, let returned = items.first(where: { $0.name == "state" })?.value else { throw InferenceOAuthError.stateMismatch }
      code = value; returnedState = returned
    } else {
      let parts = input.split(separator: "#", omittingEmptySubsequences: false)
      guard parts.count == 2 else { throw InferenceOAuthError.stateMismatch }
      code = String(parts[0]); returnedState = String(parts[1])
    }
    guard !code.isEmpty, !code.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), returnedState == state else { throw InferenceOAuthError.stateMismatch }
    let response = try await post("https://platform.claude.com/v1/oauth/token", fields: ["grant_type": "authorization_code", "client_id": Self.claudeClient,
      "code": code, "state": state, "code_verifier": verifier, "redirect_uri": Self.claudeCallback], json: true)
    guard response.status == 200 else { throw failure(response) }
    guard now() < pending.challenge.expiresAt else { throw InferenceOAuthError.expired }
    return try credential(object(response), provider: "claude-subscription", bindingID: pending.bindingID)
  }
  private static func random() throws -> String {
    var data = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, data.count, &data) == errSecSuccess else { throw InferenceOAuthError.invalidResponse }
    return base64URL(Data(data))
  }
  private static func base64URL(_ value: Data) -> String { value.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
  func refresh(_ old: InferenceOAuthCredential) async throws -> InferenceOAuthCredential {
    try old.validate(); try Task.checkCancellation()
    let openAI = old.provider == "openai-codex", claude = old.provider == "claude-subscription"
    let response = try await post(openAI ? "https://auth.openai.com/oauth/token" : claude ? "https://platform.claude.com/v1/oauth/token" : "https://auth.x.ai/oauth2/token",
      fields: ["grant_type": "refresh_token", "client_id": openAI ? Self.openAIClient : claude ? Self.claudeClient : Self.xaiClient, "refresh_token": old.refresh], json: claude)
    guard response.status == 200 else { throw InferenceOAuthError.signInRequired }
    let result = try credential(object(response), provider: old.provider, bindingID: old.bindingID, previous: old)
    guard result.accountID == old.accountID, result.subject == old.subject || old.subject == nil else { throw InferenceOAuthError.accountChanged }
    return result
  }
  private func pause(_ interval: Double, deadline: Date) async throws {
    try Task.checkCancellation()
    let remaining = deadline.timeIntervalSince(now())
    guard remaining > 0 else { throw InferenceOAuthError.expired }
    try await sleep(min(interval, remaining)); try Task.checkCancellation()
  }
  private func credential(_ body: InferenceObject, provider: String, bindingID: String, previous: InferenceOAuthCredential? = nil) throws -> InferenceOAuthCredential {
    let access = try string(body, "access_token"), openAI = provider == "openai-codex"
    let refresh = provider != "openai-codex" && body["refresh_token"] == nil ? previous?.refresh : body["refresh_token"] as? String
    guard let refresh, !refresh.isEmpty else { throw InferenceOAuthError.invalidResponse }
    let seconds = try positive(body["expires_in"] ?? (provider == "xai" ? 3600 : 0), max: 366 * 86400)
    let subject = Self.jwt(access)?["sub"] as? String ?? inferenceObject(body["account"])["uuid"] as? String
    let accountID: String
    if openAI {
      guard let value = Self.openAIAccount(access) else { throw InferenceOAuthError.invalidResponse }
      accountID = value
    } else { accountID = previous?.accountID ?? subject ?? "\(provider)-\(bindingID)" }
    if let previous, let previousSubject = previous.subject, let subject, previousSubject != subject { throw InferenceOAuthError.accountChanged }
    return try .init(provider: provider, access: access, refresh: refresh,
      expires: now().timeIntervalSince1970 * 1000 + max(1, seconds - (openAI ? 60 : 300)) * 1000,
      accountID: accountID, bindingID: bindingID, subject: subject ?? previous?.subject)
  }
  static func jwt(_ token: String) -> InferenceObject? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[1].utf8.count < 65536 else { return nil }
    var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base += String(repeating: "=", count: (4 - base.count % 4) % 4)
    guard let data = Data(base64Encoded: base) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? InferenceObject
  }
  static func openAIAccount(_ token: String) -> String? {
    let value = inferenceObject(jwt(token)?["https://api.openai.com/auth"])["chatgpt_account_id"] as? String
    return value?.isEmpty == false ? value : nil
  }
  private func verificationURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.scheme == "https", let host = url.host?.lowercased(),
      url.user == nil, url.password == nil, url.port == nil,
      ["x.ai", "grok.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw InferenceOAuthError.invalidResponse }
    return url
  }
  private func string(_ value: InferenceObject, _ name: String) throws -> String {
    guard let string = value[name] as? String, !string.isEmpty, string.utf8.count <= 32768,
      !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw InferenceOAuthError.invalidResponse }
    return string
  }
  private func positive(_ value: Any?, max: Double) throws -> Double {
    guard let number = value as? Double, number.isFinite, number > 0, number <= max else { throw InferenceOAuthError.invalidResponse }
    return number
  }
  private func object(_ response: InferenceOAuthHTTPResponse) throws -> InferenceObject {
    guard response.data.count <= 131072, let body = (try? JSONSerialization.jsonObject(with: response.data)) as? InferenceObject else { throw InferenceOAuthError.invalidResponse }
    return body
  }
  private func errorCode(_ response: InferenceOAuthHTTPResponse) -> String? {
    guard let body = try? object(response) else { return nil }
    return body["error"] as? String ?? inferenceObject(body["error"])["code"] as? String
  }
  private func failure(_ response: InferenceOAuthHTTPResponse) -> InferenceOAuthError {
    switch errorCode(response) {
    case "access_denied", "authorization_denied": .authorizationDenied
    case "expired_token": .expired
    case "invalid_grant", "invalid_token": .signInRequired
    default: .invalidResponse
    }
  }
  private func post(_ endpoint: String, fields: [String: String], json: Bool = false) async throws -> InferenceOAuthHTTPResponse {
    try Task.checkCancellation()
    var request = URLRequest(url: URL(string: endpoint)!)
    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("WovenMatter/1 iOS", forHTTPHeaderField: "User-Agent")
    request.setValue(json ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    if json { request.httpBody = try JSONSerialization.data(withJSONObject: fields) }
    else {
      let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
      let form = fields.sorted { $0.key < $1.key }.map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
      request.httpBody = Data(form.utf8)
    }
    do { let result = try await transport.send(request); try Task.checkCancellation(); return result }
    catch is CancellationError { throw CancellationError() }
    catch let error as InferenceOAuthError { throw error }
    catch { if Task.isCancelled { throw CancellationError() }; throw InferenceOAuthError.connectionFailed }
  }
}

/// Start only from an explicit user action. This type never opens a browser or chooses an account.
public actor InferenceOAuthSession {
  public nonisolated static func supports(_ provider: String) -> Bool { ["openai-codex", "xai", "claude-subscription"].contains(provider) }
  private let client: InferenceOAuthClient
  private var generation = 0
  private var pending: InferenceOAuthClient.Pending?
  private var starting: Task<InferenceOAuthClient.Pending, Error>?
  private var polling: Task<InferenceOAuthCredential, Error>?
  public init(transport: any InferenceOAuthHTTPTransport = InferenceOAuthURLSessionTransport(),
              now: @escaping @Sendable () -> Date = { Date() },
              sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
    client = .init(transport: transport, now: now, sleep: sleep)
  }
  public func start(provider: String) async throws -> InferenceOAuthChallenge {
    cancel(); let revision = generation, client = client
    let task = Task { try await client.begin(provider) }; starting = task
    do {
      let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      guard generation == revision else { throw CancellationError() }
      starting = nil; pending = value; return value.challenge
    } catch { if generation == revision { starting = nil }; throw error }
  }
  public func poll() async throws -> InferenceOAuthCredential {
    guard let pending, pending.challenge.kind == .deviceCode else { throw InferenceOAuthError.sessionUnavailable }
    let revision = generation, client = client
    let task = polling ?? Task { try await client.poll(pending) }; polling = task
    do {
      let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      guard generation == revision else { throw CancellationError() }
      polling = nil; self.pending = nil; return value
    } catch { if generation == revision { polling = nil; self.pending = nil }; throw error }
  }
  public func complete(code: String) async throws -> InferenceOAuthCredential {
    guard let pending, pending.challenge.kind == .authorizationCode, polling == nil else { throw InferenceOAuthError.sessionUnavailable }
    self.pending = nil // A pasted authorization response is single-use, including failed exchanges.
    let revision = generation, client = client
    let task = Task { try await client.complete(code, pending: pending) }; polling = task
    do {
      let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
      guard generation == revision else { throw CancellationError() }
      polling = nil; return value
    } catch { if generation == revision { polling = nil }; throw error }
  }
  public func cancel() { generation += 1; starting?.cancel(); polling?.cancel(); starting = nil; polling = nil; pending = nil }
}

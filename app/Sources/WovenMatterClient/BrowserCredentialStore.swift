import Foundation
import Security

/// Browser-only credentials. Values never enter workspace snapshots, agent IPC,
/// diagnostics, defaults, or plaintext files. Dev and production have distinct vaults.
public final class BrowserCredentialStore: @unchecked Sendable {
  public static let consentKey = "wovenmatter.credential-access.disclosure-acknowledged"
  public static let shared = BrowserCredentialStore(scope: Bundle.main.bundleIdentifier ?? "wovenmatter.desktop")

  public struct Password: Codable, Equatable, Sendable {
    public let origin: String
    public let username: String
    public let password: String
  }
  public enum AccessError: LocalizedError {
    case consentRequired, unavailable(OSStatus), invalidOrigin, invalidCredential
    public var errorDescription: String? {
      switch self {
      case .consentRequired: "Enable Credential access in Settings > General to use saved website sessions and passwords."
      case .unavailable: "Browser credential access is unavailable. Use Reconnect saved credentials in Settings > General, then reopen the browser."
      case .invalidOrigin: "Passwords can only be saved and filled on a secure website."
      case .invalidCredential: "This website password could not be saved."
      }
    }
  }
  private let scope: String
  private let keychain: KeychainAccess
  private let lock = NSLock()
  private var passwords: [Password]?

  public init(scope: String, keychain: KeychainAccess = .init()) {
    self.scope = scope; self.keychain = keychain
  }

  /// Exact scheme/host/port matching, including IDN normalization by URLComponents.
  /// Loopback HTTP is a secure local context and supports local app sign-ins/tests.
  public static func origin(for address: String) -> String? {
    guard let parts = URLComponents(string: address), let scheme = parts.scheme?.lowercased(),
          let host = parts.url?.host()?.lowercased(), !host.isEmpty,
          parts.user == nil, parts.password == nil,
          scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host))
    else { return nil }
    var origin = URLComponents()
    origin.scheme = scheme; origin.host = host
    if let port = parts.port, port != (scheme == "https" ? 443 : 80) { origin.port = port }
    return origin.string
  }

  public func prepare(consented: Bool, authorize: Bool = false) throws {
    guard consented else { throw AccessError.consentRequired }
    try lock.withLock {
      // Chromium's pinned SDK uses this shared service. Preserve the existing
      // secret; never replace a denied/inaccessible item with a different key.
      let cryptoQuery = query(service: "Chromium Safe Storage", account: "Chromium")
      if try read(cryptoQuery, authorize: authorize) == nil {
        var random = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
          throw AccessError.unavailable(errSecNotAvailable)
        }
        let secret = Data(Data(random).base64EncodedString().utf8)
        try insert(secret, query: cryptoQuery, authorize: authorize, allowDuplicate: true)
        // A concurrent creator wins; make sure that winning item is accessible.
        guard try read(cryptoQuery, authorize: authorize)?.isEmpty == false else {
          throw AccessError.unavailable(errSecNotAvailable)
        }
      }
      // Recovery refreshes the vault instead of trusting an earlier cached read.
      if passwords == nil || authorize {
        let data = try read(vaultQuery, authorize: authorize)
        passwords = try data.map { try JSONDecoder().decode([Password].self, from: $0) } ?? []
      }
    }
  }

  public func savedPasswords(for origin: String) throws -> [Password] {
    guard Self.origin(for: origin) == origin else { throw AccessError.invalidOrigin }
    return try lock.withLock {
      guard let passwords else { throw AccessError.unavailable(errSecInteractionNotAllowed) }
      return passwords.filter { $0.origin == origin }
    }
  }

  public func save(origin: String, username: String, password: String) throws {
    guard Self.origin(for: origin) == origin else { throw AccessError.invalidOrigin }
    guard username.utf8.count <= 1024, !password.isEmpty, password.utf8.count <= 4096 else {
      throw AccessError.invalidCredential
    }
    try lock.withLock {
      guard var values = passwords else { throw AccessError.unavailable(errSecInteractionNotAllowed) }
      values.removeAll { $0.origin == origin && $0.username == username }
      values.insert(.init(origin: origin, username: username, password: password), at: 0)
      guard values.count <= 2000 else { throw AccessError.invalidCredential }
      let data = try JSONEncoder().encode(values)
      let status = keychain.update(vaultQuery, [kSecValueData as String: data])
      if status == errSecItemNotFound { try insert(data, query: vaultQuery, authorize: false) }
      else if status != errSecSuccess { throw AccessError.unavailable(status) }
      // Failed persistence never changes the cached credentials.
      passwords = values
    }
  }

  private var vaultQuery: [String: Any] { query(service: "wovenmatter.browser.passwords", account: scope) }
  private func query(service: String, account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: account]
  }
  private func read(_ query: [String: Any], authorize: Bool) throws -> Data? {
    var query = query
    query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, result) = keychain.copyMatching(query, allowInteraction: authorize)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
      throw AccessError.unavailable(status)
    }
    return data
  }
  private func insert(_ data: Data, query: [String: Any], authorize: Bool, allowDuplicate: Bool = false) throws {
    var item = query; item[kSecValueData as String] = data
    let status = keychain.add(item, allowInteraction: authorize)
    guard status == errSecSuccess || (allowDuplicate && status == errSecDuplicateItem) else {
      throw AccessError.unavailable(status)
    }
  }
}

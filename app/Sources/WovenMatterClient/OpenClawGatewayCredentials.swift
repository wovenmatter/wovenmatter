import CryptoKit
import Foundation
import Security

public struct OpenClawGatewayCredentials: Codable, Equatable, Sendable {
  public var privateKey: Data
  public var deviceToken: String?

  public init(privateKey: Data, deviceToken: String? = nil) {
    self.privateKey = privateKey
    self.deviceToken = deviceToken
  }
}

/// A credential scope is an enrolled Gateway identity, not a transient SSH port.
public protocol OpenClawGatewayCredentialStore: Sendable {
  func credentials(for scope: String) throws -> OpenClawGatewayCredentials
  func save(_ credentials: OpenClawGatewayCredentials, for scope: String) throws
}

public final class OpenClawGatewayKeychain: OpenClawGatewayCredentialStore, @unchecked Sendable {
  public static let shared = OpenClawGatewayKeychain()
  private let lock = NSLock()
  private let service: String
  private let keychain: KeychainAccess
  private var cached: [String: OpenClawGatewayCredentials] = [:]
  private var blocked: [String: OSStatus] = [:]
  private var pending: [String: OpenClawGatewayCredentials] = [:]

  public init(service: String? = nil) {
    self.service = service ?? Self.serviceName(bundleIdentifier: Bundle.main.bundleIdentifier)
    keychain = KeychainAccess()
  }

  init(service: String, keychain: KeychainAccess) {
    self.service = service
    self.keychain = keychain
  }

  static func serviceName(bundleIdentifier: String?) -> String {
    if let bundleIdentifier,
       bundleIdentifier == "wovenmatter.desktop.dev" || bundleIdentifier.hasPrefix("wovenmatter.desktop.dev.") {
      return "Woven Matter.desktop.dev" + bundleIdentifier.dropFirst("wovenmatter.desktop.dev".count) + ".OpenClaw"
    }
    return "Woven Matter.desktop.OpenClaw"
  }

  public func credentials(for scope: String) throws -> OpenClawGatewayCredentials {
    try lock.withLock {
      if let status = blocked[scope] { throw failure(status) }
      if let value = cached[scope] { return value }
      return try loadUnlocked(scope, allowInteraction: false)
    }
  }

  /// Only an explicit user credential-retry action may request system UI.
  public func authorizeCredentials(for scope: String) throws -> OpenClawGatewayCredentials {
    try lock.withLock {
      if let value = pending[scope] {
        try saveUnlocked(value, scope: scope, allowInteraction: true)
        return value
      }
      if blocked[scope] == nil, let value = cached[scope] { return value }
      return try loadUnlocked(scope, allowInteraction: true)
    }
  }

  private func loadUnlocked(_ scope: String, allowInteraction: Bool) throws -> OpenClawGatewayCredentials {
    var query = query(scope)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, result) = keychain.copyMatching(query, allowInteraction: allowInteraction)
    if status == errSecSuccess {
      guard let data = result as? Data,
            let stored = try? JSONDecoder().decode(OpenClawGatewayCredentials.self, from: data),
            (try? Curve25519.Signing.PrivateKey(rawRepresentation: stored.privateKey)) != nil else {
        blocked[scope] = errSecDecode
        throw failure(errSecDecode)
      }
      cached[scope] = stored
      blocked[scope] = nil
      return stored
    }
    guard status == errSecItemNotFound else {
      blocked[scope] = status
      throw failure(status)
    }
    // A denied read is never interpreted as a missing identity.
    let created = OpenClawGatewayCredentials(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
    try saveUnlocked(created, scope: scope, allowInteraction: allowInteraction)
    return created
  }

  public func save(_ credentials: OpenClawGatewayCredentials, for scope: String) throws {
    try lock.withLock {
      if let status = blocked[scope] { throw failure(status) }
      guard cached[scope] != credentials else { return }
      try saveUnlocked(credentials, scope: scope, allowInteraction: false)
    }
  }

  private func saveUnlocked(_ credentials: OpenClawGatewayCredentials, scope: String, allowInteraction: Bool) throws {
    let data = try JSONEncoder().encode(credentials)
    var status = keychain.update(query(scope), [kSecValueData as String: data], allowInteraction: allowInteraction)
    if status == errSecItemNotFound {
      var item = query(scope)
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = keychain.add(item, allowInteraction: allowInteraction)
    }
    guard status == errSecSuccess else {
      // Retain the same identity/token in memory for an explicit retry. Never
      // repeatedly rewrite it or generate a replacement after denied access.
      pending[scope] = credentials
      blocked[scope] = status
      throw failure(status)
    }
    cached[scope] = credentials
    pending[scope] = nil
    blocked[scope] = nil
  }

  private func query(_ scope: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: scope]
  }

  private func failure(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
      NSLocalizedDescriptionKey: "OpenClaw device credentials are unavailable from Keychain (\(status)). Use Reconnect in OpenClaw settings; automatic reconnect will not request access."
    ])
  }
}

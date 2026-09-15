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

  public init(service: String? = nil) {
    self.service = service ?? Self.serviceName(bundleIdentifier: Bundle.main.bundleIdentifier)
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
      var query = query(scope)
      query[kSecReturnData as String] = true
      query[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecSuccess, let data = result as? Data {
        let stored = try JSONDecoder().decode(OpenClawGatewayCredentials.self, from: data)
        _ = try Curve25519.Signing.PrivateKey(rawRepresentation: stored.privateKey)
        return stored
      }
      guard status == errSecItemNotFound else { throw failure(status) }
      let created = OpenClawGatewayCredentials(
        privateKey: Curve25519.Signing.PrivateKey().rawRepresentation
      )
      try saveUnlocked(created, scope: scope)
      return created
    }
  }

  public func save(_ credentials: OpenClawGatewayCredentials, for scope: String) throws {
    try lock.withLock { try saveUnlocked(credentials, scope: scope) }
  }

  private func saveUnlocked(_ credentials: OpenClawGatewayCredentials, scope: String) throws {
    let data = try JSONEncoder().encode(credentials)
    let update = [kSecValueData as String: data]
    let status = SecItemUpdate(query(scope) as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var item = query(scope)
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw failure(added) }
    } else if status != errSecSuccess {
      throw failure(status)
    }
  }

  private func query(_ scope: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: scope]
  }

  private func failure(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
      NSLocalizedDescriptionKey: "OpenClaw device credentials could not be accessed in Keychain (\(status))."
    ])
  }
}

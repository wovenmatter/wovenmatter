import Foundation
import Security

/// Each connection owns a separate device-only Keychain item. No secret enters content synchronization.
public protocol InferenceCredentialReading: Sendable {
  func read(connectionID: String) async throws -> String?
}

public actor InferenceCredentialStore: InferenceCredentialReading {
  private let service: String
  public init(service: String = "com.wovenmatter.companion.inference") { self.service = service }
  public func save(_ secret: String, connectionID: String) throws {
    guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !secret.contains("\r"), !secret.contains("\n"), secret.utf8.count < 65536 else { throw InferenceError.missingCredential }
    let query = item(connectionID)
    let data = Data(secret.utf8)
    let update = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
    if update == errSecItemNotFound {
      var attributes = query; attributes[kSecValueData as String] = data
      attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw InferenceError.missingCredential }
    } else if update != errSecSuccess { throw InferenceError.missingCredential }
  }
  public func read(connectionID: String) throws -> String? {
    var query = item(connectionID); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data, let secret = String(data: data, encoding: .utf8) else { throw InferenceError.missingCredential }
    return secret
  }
  public func remove(connectionID: String) throws {
    let status = SecItemDelete(item(connectionID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw InferenceError.missingCredential }
  }
  private func item(_ id: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
  }
}

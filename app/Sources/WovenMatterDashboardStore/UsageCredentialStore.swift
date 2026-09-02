import Foundation
import Security

protocol UsageCredentialStoring: Sendable {
  func hasOpenRouterAPIKey() throws -> Bool
  func loadOpenRouterAPIKey() throws -> String?
  func saveOpenRouterAPIKey(_ key: String) throws
  func deleteOpenRouterAPIKey() throws
}

struct UsageCredentialStore: UsageCredentialStoring, Sendable {
  private let service: String
  private let openRouterAccount = "openrouter.api-key"

  init(service: String) {
    self.service = service
  }

  func hasOpenRouterAPIKey() throws -> Bool {
    try loadOpenRouterAPIKey() != nil
  }

  func loadOpenRouterAPIKey() throws -> String? {
    try load(account: openRouterAccount)
  }

  private func load(account: String) throws -> String? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      query(account: account, returnData: true) as CFDictionary,
      &result
    )
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw UsageCredentialStoreError.keychain(status)
    }
    return String(data: data, encoding: .utf8)
  }

  func saveOpenRouterAPIKey(_ key: String) throws {
    try save(key, account: openRouterAccount)
  }

  private func save(_ key: String, account: String) throws {
    let data = Data(key.utf8)
    let base = query(account: account, returnData: false)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
    let updated = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw UsageCredentialStoreError.keychain(updated) }
    var item = base
    attributes.forEach { item[$0.key] = $0.value }
    let inserted = SecItemAdd(item as CFDictionary, nil)
    guard inserted == errSecSuccess else { throw UsageCredentialStoreError.keychain(inserted) }
  }

  func deleteOpenRouterAPIKey() throws {
    try delete(account: openRouterAccount)
  }

  private func delete(account: String) throws {
    let status = SecItemDelete(query(account: account, returnData: false) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw UsageCredentialStoreError.keychain(status)
    }
  }

  private func query(account: String, returnData: Bool) -> [String: Any] {
    var value: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
    if returnData {
      value[kSecReturnData as String] = true
      value[kSecMatchLimit as String] = kSecMatchLimitOne
    }
    return value
  }
}

enum UsageCredentialStoreError: LocalizedError {
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "The usage credential could not be read from this Mac's Keychain (status \(status))."
    }
  }
}

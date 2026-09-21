import Foundation
import Security
import WovenMatterClient

protocol UsageCredentialStoring: Sendable {
  func hasOpenRouterAPIKey() throws -> Bool
  func loadOpenRouterAPIKey() throws -> String?
  func authorizeOpenRouterAPIKey() throws -> String?
  func saveOpenRouterAPIKey(_ key: String) throws
  func deleteOpenRouterAPIKey() throws
}

struct UsageCredentialStore: UsageCredentialStoring, Sendable {
  private let service: String
  private let keychain: KeychainAccess
  private let openRouterAccount = "openrouter.api-key"

  init(service: String, operations: KeychainOperations = KeychainOperations()) {
    self.service = service
    keychain = KeychainAccess(operations: operations)
  }

  func hasOpenRouterAPIKey() throws -> Bool {
    var query = query(account: openRouterAccount)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, _) = keychain.copyMatching(query)
    if status == errSecItemNotFound { return false }
    guard status == errSecSuccess else { throw UsageCredentialStoreError.keychain(status) }
    return true
  }

  func loadOpenRouterAPIKey() throws -> String? {
    try loadOpenRouterAPIKey(allowInteraction: false)
  }

  /// Called only by explicit saved-credential recovery, never a refresh.
  func authorizeOpenRouterAPIKey() throws -> String? {
    try loadOpenRouterAPIKey(allowInteraction: true)
  }

  private func loadOpenRouterAPIKey(allowInteraction: Bool) throws -> String? {
    var query = query(account: openRouterAccount)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, result) = keychain.copyMatching(query, allowInteraction: allowInteraction)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw UsageCredentialStoreError.keychain(status) }
    guard let data = result as? Data,
          let key = String(data: data, encoding: .utf8), !key.isEmpty else {
      throw UsageCredentialStoreError.keychain(errSecDecode)
    }
    return key
  }

  func saveOpenRouterAPIKey(_ key: String) throws {
    let data = Data(key.utf8)
    let base = query(account: openRouterAccount)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
    let updated = keychain.update(base, attributes, allowInteraction: true)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw UsageCredentialStoreError.keychain(updated) }
    var item = base
    attributes.forEach { item[$0.key] = $0.value }
    let inserted = keychain.add(item, allowInteraction: true)
    guard inserted == errSecSuccess else { throw UsageCredentialStoreError.keychain(inserted) }
  }

  func deleteOpenRouterAPIKey() throws {
    let status = keychain.delete(query(account: openRouterAccount), allowInteraction: true)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw UsageCredentialStoreError.keychain(status)
    }
  }

  private func query(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }
}

enum UsageCredentialStoreError: LocalizedError {
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "The usage credential is unavailable from this Mac's Keychain (status \(status)). Automatic refresh will not prompt. Use Reconnect saved credentials in Settings > General to restore access."
    }
  }
}

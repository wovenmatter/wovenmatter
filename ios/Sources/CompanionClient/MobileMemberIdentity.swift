import Foundation
import CryptoKit
import WovenMatterCompanion
#if canImport(Security)
import Security
#endif

/// This phone's long-lived member identity (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Membership and device keys"): a Curve25519 signing key in the iPhone
/// Keychain, bound to the library device ID. A Mac that pairs with the phone
/// signs a member entry for its public key; every request to a Mac or Linux
/// member is then signed with it. Nothing is issued, cached or renewed.
public struct MobileMemberIdentity: Sendable {
  public let deviceID: String
  public let publicKey: Data
  public let signer: MemberRequestSigner
  public init(deviceID: String, privateKey: Curve25519.Signing.PrivateKey) {
    self.deviceID = deviceID.lowercased()
    publicKey = privateKey.publicKey.rawRepresentation
    signer = MemberRequestSigner(deviceID: deviceID, key: privateKey)
  }
}

/// Where the member key lives. The Keychain item is this device only and never
/// syncs or backs up, so a restored backup pairs again as a new member.
public struct MobileMemberKeyStorage: Sendable {
  public var load: @Sendable () throws -> Data?
  public var save: @Sendable (Data) throws -> Void
  public init(load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void) {
    self.load = load; self.save = save
  }

  public static func memory() -> MobileMemberKeyStorage {
    final class Box: @unchecked Sendable { var value: Data?; let lock = NSLock() }
    let box = Box()
    return .init(load: { box.lock.withLock { box.value } }, save: { value in box.lock.withLock { box.value = value } })
  }

  #if canImport(Security)
  private static var service: String { ClientCredentialNamespace.service("com.wovenmatter.companion.member") }
  private static let account = "member-signing-key"
  public static let keychain = MobileMemberKeyStorage(load: {
    var result: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
      kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return data
  }, save: { data in
    let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecItemNotFound {
      let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    } else if updated != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
  })
  #endif
}

public enum MobileMemberKeyVault {
  private struct Record: Codable { var deviceID: String; var key: Data }

  /// The key for this library device, created on first use. A re-pair keeps the
  /// same key, because a Mac refuses a known device that presents a new one.
  /// A key saved for another device ID (a reinstalled library) is replaced.
  public static func loadOrCreate(deviceID: String, storage: MobileMemberKeyStorage) throws -> MobileMemberIdentity {
    let deviceID = deviceID.lowercased()
    if let data = try storage.load(), let record = try? JSONDecoder().decode(Record.self, from: data), record.deviceID == deviceID,
       let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: record.key) {
      return MobileMemberIdentity(deviceID: deviceID, privateKey: key)
    }
    let key = Curve25519.Signing.PrivateKey()
    try storage.save(JSONEncoder().encode(Record(deviceID: deviceID, key: key.rawRepresentation)))
    return MobileMemberIdentity(deviceID: deviceID, privateKey: key)
  }
}

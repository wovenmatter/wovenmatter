import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Generic-password storage for hosts without a Keychain. Each item is one 0600
/// file in a 0700 directory under the Woven data root. Nothing is stored until a
/// host configures the directory, so tests and tools never reach a default path.
public enum LinuxSecretStore {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var configuredDirectory: URL?

  public static var directory: URL? {
    get { lock.withLock { configuredDirectory } }
    set { lock.withLock { configuredDirectory = newValue } }
  }

  struct Item: Codable {
    var itemClass: String
    var service: String
    var account: String
    var data: Data
    var accessible: String?
  }

  static func read(service: String, account: String?, itemClass: String) throws -> [Item]? {
    guard let directory else { return nil }
    let names: [String]
    if let account { names = [fileName(itemClass: itemClass, service: service, account: account)] }
    else { names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasSuffix(".secret") }.sorted() ?? [] }
    var items: [Item] = []
    for name in names {
      let url = directory.appending(path: name)
      guard let data = try? Data(contentsOf: url) else { continue }
      let item = try JSONDecoder().decode(Item.self, from: data)
      if item.itemClass == itemClass, item.service == service, account == nil || item.account == account { items.append(item) }
    }
    return items
  }

  static func write(_ item: Item) throws {
    guard let directory else { throw CocoaError(.fileNoSuchFile) }
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let target = directory.appending(path: fileName(itemClass: item.itemClass, service: item.service, account: item.account))
    let staging = directory.appending(path: ".\(UUID().uuidString).tmp")
    guard manager.createFile(atPath: staging.path, contents: try JSONEncoder().encode(item), attributes: [.posixPermissions: 0o600]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
      if manager.fileExists(atPath: target.path) { _ = try manager.replaceItemAt(target, withItemAt: staging) }
      else { try manager.moveItem(at: staging, to: target) }
    } catch { try? manager.removeItem(at: staging); throw error }
  }

  static func remove(_ item: Item) throws {
    guard let directory else { return }
    try FileManager.default.removeItem(at: directory.appending(path: fileName(itemClass: item.itemClass, service: item.service, account: item.account)))
  }

  private static func fileName(itemClass: String, service: String, account: String) -> String {
    SHA256.hash(data: Data("\(itemClass)\0\(service)\0\(account)".utf8)).map { String(format: "%02x", $0) }.joined() + ".secret"
  }
}

#if !canImport(Security)
// The Security names Woven uses, so credential code compiles unchanged and is
// served by LinuxSecretStore. Status values match Apple's for logs and tests.
public typealias OSStatus = Int32
public typealias CFTypeRef = Any
public let errSecSuccess: OSStatus = 0
public let errSecParam: OSStatus = -50
public let errSecUserCanceled: OSStatus = -128
public let errSecNotAvailable: OSStatus = -25291
public let errSecAuthFailed: OSStatus = -25293
public let errSecDuplicateItem: OSStatus = -25299
public let errSecItemNotFound: OSStatus = -25300
public let errSecInteractionNotAllowed: OSStatus = -25308
public let errSecDecode: OSStatus = -26275
public let kSecClass = "class"
public let kSecClassGenericPassword = "genp"
public let kSecAttrService = "svce"
public let kSecAttrAccount = "acct"
public let kSecAttrAccessible = "pdmn"
public let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "cku"
public let kSecAttrSynchronizable = "sync"
public let kSecValueData = "v_Data"
public let kSecReturnData = "r_Data"
public let kSecReturnAttributes = "r_Attributes"
public let kSecMatchLimit = "m_Limit"
public let kSecMatchLimitOne = "m_LimitOne"
public let kSecMatchLimitAll = "m_LimitAll"
public let kSecUseAuthenticationContext = "u_AuthCtx"
public let kSecRandomDefault: Int? = nil

/// SystemRandomNumberGenerator reads the kernel CSPRNG (getrandom) on Linux.
public func SecRandomCopyBytes(_ generator: Int?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 {
  var system = SystemRandomNumberGenerator()
  let buffer = bytes.bindMemory(to: UInt8.self, capacity: count)
  for index in 0..<count { buffer[index] = UInt8.random(in: .min ... .max, using: &system) }
  return errSecSuccess
}

extension LinuxSecretStore {
  private static func key(_ query: [String: Any]) -> (String, String, String?)? {
    guard let itemClass = query[kSecClass] as? String, itemClass == kSecClassGenericPassword,
          let service = query[kSecAttrService] as? String else { return nil }
    return (itemClass, service, query[kSecAttrAccount] as? String)
  }

  public static func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
    guard let (itemClass, service, account) = key(query) else { return (errSecParam, nil) }
    guard directory != nil else { return (errSecNotAvailable, nil) }
    guard let items = try? read(service: service, account: account, itemClass: itemClass) else { return (errSecDecode, nil) }
    guard !items.isEmpty else { return (errSecItemNotFound, nil) }
    let all = query[kSecMatchLimit] as? String == kSecMatchLimitAll
    let returnsData = query[kSecReturnData] as? Bool == true
    let returnsAttributes = query[kSecReturnAttributes] as? Bool == true
    func value(_ item: Item) -> Any {
      guard returnsAttributes else { return item.data }
      var attributes: [String: Any] = [kSecClass: item.itemClass, kSecAttrService: item.service, kSecAttrAccount: item.account]
      if let accessible = item.accessible { attributes[kSecAttrAccessible] = accessible }
      if returnsData { attributes[kSecValueData] = item.data }
      return attributes
    }
    if all { return (errSecSuccess, items.map(value)) }
    return (errSecSuccess, (returnsData || returnsAttributes) ? value(items[0]) : nil)
  }

  public static func add(_ attributes: [String: Any]) -> OSStatus {
    guard let (itemClass, service, account) = key(attributes), let account,
          let data = attributes[kSecValueData] as? Data else { return errSecParam }
    guard directory != nil else { return errSecNotAvailable }
    if let existing = try? read(service: service, account: account, itemClass: itemClass), !existing.isEmpty { return errSecDuplicateItem }
    do {
      try write(.init(itemClass: itemClass, service: service, account: account, data: data,
                      accessible: attributes[kSecAttrAccessible] as? String))
      return errSecSuccess
    } catch { return errSecNotAvailable }
  }

  public static func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
    guard let (itemClass, service, account) = key(query) else { return errSecParam }
    guard directory != nil else { return errSecNotAvailable }
    guard let items = try? read(service: service, account: account, itemClass: itemClass) else { return errSecDecode }
    guard !items.isEmpty else { return errSecItemNotFound }
    do {
      for var item in items {
        if let data = attributes[kSecValueData] as? Data { item.data = data }
        if let accessible = attributes[kSecAttrAccessible] as? String { item.accessible = accessible }
        try write(item)
      }
      return errSecSuccess
    } catch { return errSecNotAvailable }
  }

  public static func delete(_ query: [String: Any]) -> OSStatus {
    guard let (itemClass, service, account) = key(query) else { return errSecParam }
    guard directory != nil else { return errSecNotAvailable }
    guard let items = try? read(service: service, account: account, itemClass: itemClass) else { return errSecDecode }
    guard !items.isEmpty else { return errSecItemNotFound }
    do { for item in items { try remove(item) }; return errSecSuccess } catch { return errSecNotAvailable }
  }
}
#endif

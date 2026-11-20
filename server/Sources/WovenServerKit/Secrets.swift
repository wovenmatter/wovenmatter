import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

/// Where this machine keeps what never leaves it: its private key and its
/// subscription sign-ins. Never the library.
public protocol SecretStore: Sendable {
  func read(_ name: String) throws -> Data?
  /// Writes a secret, or removes it when `data` is nil.
  func write(_ name: String, _ data: Data?) throws
}

/// The Keychain on a Mac and a private file on Linux. On a Mac,
/// `WOVEN_SECRET_STORE=file` uses the private file instead.
public func standardSecretStore(dataFolder: URL, machineID: String) -> any SecretStore {
    #if canImport(Security)
    if ProcessInfo.processInfo.environment["WOVEN_SECRET_STORE"] != "file" {
      return KeychainSecretStore(account: machineID)
    }
    #endif
  return FileSecretStore(file: dataFolder.appendingPathComponent("secrets.json"))
}

/// Secrets in one JSON file that only this user can read.
public final class FileSecretStore: SecretStore {
  private let file: URL
  private let lock = Mutex(())

  public init(file: URL) {
    self.file = file
  }

  public func read(_ name: String) throws -> Data? {
    try lock.withLock { _ in try load()[name].flatMap { Data(base64Encoded: $0) } }
  }

  public func write(_ name: String, _ data: Data?) throws {
    try lock.withLock { _ in
      var all = try load()
      all[name] = data?.base64EncodedString()
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      let partial = file.appendingPathExtension("partial")
      FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
      try JSONEncoder().encode(all).write(to: partial)
      // rename(2) replaces the old file in one step, on every platform.
      guard rename(partial.path, file.path) == 0 else { throw RuntimeError.failed("Could not save \(file.path).") }
    }
  }

  private func load() throws -> [String: String] {
    guard let data = try? Data(contentsOf: file) else { return [:] }
    return try JSONDecoder().decode([String: String].self, from: data)
  }
}

#if canImport(Security)
/// Secrets as generic passwords in the login Keychain, kept on this device
/// only. `account` separates one data folder's machine from another's.
public struct KeychainSecretStore: SecretStore {
  private let service = "Woven Matter"
  private let account: String

  public init(account: String) {
    self.account = account
    // Nobody may be at this Mac. A read that would need a Keychain prompt
    // fails with its reason instead of waiting on one. Process-wide.
    SecKeychainSetUserInteractionAllowed(false)
  }

  private func query(_ name: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
     kSecAttrAccount as String: account + "/" + name, kSecUseDataProtectionKeychain as String: false]
  }

  public func read(_ name: String) throws -> Data? {
    var query = query(name)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw RuntimeError.failed("The Keychain refused to read \(name) (\(status)).") }
    return result as? Data
  }

  public func write(_ name: String, _ data: Data?) throws {
    let query = query(name)
    SecItemDelete(query as CFDictionary)
    guard let data else { return }
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw RuntimeError.failed("The Keychain refused to save \(name) (\(status)).") }
  }
}
#endif

/// Sealing: each synced secret (API keys, the GitHub key) is sealed separately
/// for every machine with that machine's public key (HPKE, X25519 with
/// ChaCha20-Poly1305), so only that machine can open its copy.
enum Sealing {
  static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
  static let info = Data("Woven Matter sealed secret".utf8)

  static func seal(_ plaintext: Data, name: String, for publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
    var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: suite, info: info)
    let sealed = try sender.seal(plaintext, authenticating: Data(name.utf8))
    return sender.encapsulatedKey + sealed
  }

  static func open(_ sealed: Data, name: String, with privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
    guard sealed.count > 32 else { throw RuntimeError.failed("A sealed secret is too short.") }
    var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: suite, info: info,
                                       encapsulatedKey: sealed.prefix(32))
    return try recipient.open(sealed.dropFirst(32), authenticating: Data(name.utf8))
  }
}

/// This machine's keys and secrets: its private key, its own subscription
/// sign-ins, and the synced API keys it can open.
actor Secrets {
  private let library: Library
  private let store: any SecretStore
  private let privateKey: Curve25519.KeyAgreement.PrivateKey

  private init(library: Library, store: any SecretStore, privateKey: Curve25519.KeyAgreement.PrivateKey) {
    self.library = library
    self.store = store
    self.privateKey = privateKey
  }

  /// Loads this machine's private key, making one the first time, and
  /// publishes its public key in the machine's row.
  static func open(library: Library, store: any SecretStore) async throws -> Secrets {
    let key: Curve25519.KeyAgreement.PrivateKey
    if let raw = try store.read("machine-key") {
      key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    } else {
      key = Curve25519.KeyAgreement.PrivateKey()
      try store.write("machine-key", key.rawRepresentation)
    }
    let published = key.publicKey.rawRepresentation.base64EncodedString()
    let row = try await library.row("machines", id: library.machineID)
    if row?.values["public_key"] != .text(published) {
      try await library.put("machines", id: library.machineID, ["public_key": .text(published)])
    }
    return Secrets(library: library, store: store, privateKey: key)
  }

  // MARK: Synced secrets (sealed per machine)

  /// The GitHub SSH key's secret name. It syncs like an API key but is not one.
  static let gitHubKey = "github-ssh-key"

  /// Sets an API key for every machine that has a public key, or removes it everywhere.
  func setAPIKey(_ provider: String, _ key: String?) async throws {
    guard provider != Self.gitHubKey else { throw RuntimeError.failed("\(provider) is not an API key.") }
    try await setSecret(provider, key.map { Data($0.utf8) })
  }

  /// Seals a secret for every machine that has a public key, or unsets it everywhere.
  func setSecret(_ name: String, _ value: Data?) async throws {
    for (machineID, publicKey) in try await publicKeys() {
      let id = "\(name):\(machineID)"
      if let value {
        let sealed = try Sealing.seal(value, name: name, for: publicKey)
        try await library.put("sealed_secrets", id: id, ["name": .text(name), "machine_id": .text(machineID), "sealed": .blob(sealed)])
      } else if try await library.row("sealed_secrets", id: id) != nil {
        try await library.delete("sealed_secrets", id: id)
      }
    }
  }

  /// This machine's copy of a secret, opened, or nil when it has none.
  func secret(_ name: String) async throws -> Data? {
    guard let row = try await library.row("sealed_secrets", id: "\(name):\(library.machineID)"), !row.deleted,
          case .blob(let sealed)? = row.values["sealed"] else { return nil }
    return try Sealing.open(sealed, name: name, with: privateKey)
  }

  /// The API keys sealed for this machine, opened, by provider.
  func apiKeys() async throws -> [String: String] {
    try await openedSecrets().filter { $0.key != Self.gitHubKey }.mapValues { String(decoding: $0, as: UTF8.self) }
  }

  /// Every secret sealed for this machine, opened, by name.
  private func openedSecrets() async throws -> [String: Data] {
    var secrets: [String: Data] = [:]
    for row in try await library.rows("sealed_secrets", where: "machine_id", is: .text(library.machineID)) {
      guard case .blob(let sealed)? = row.values["sealed"], case .text(let name)? = row.values["name"],
            let opened = try? Sealing.open(sealed, name: name, with: privateKey) else { continue }
      secrets[name] = opened
    }
    return secrets
  }

  /// Seals each secret this machine holds for every machine that has never
  /// had a copy, such as one that joined since the secret was set.
  func sealForEveryMachine() async {
    guard let secrets = try? await openedSecrets(), !secrets.isEmpty, let machines = try? await publicKeys() else { return }
    for (name, value) in secrets {
      for (machineID, publicKey) in machines {
        let id = "\(name):\(machineID)"
        // A row emptied by a removal stays empty; only a machine with no row at all gets a copy.
        if (try? await library.row("sealed_secrets", id: id)) ?? nil != nil { continue }
        guard let sealed = try? Sealing.seal(value, name: name, for: publicKey) else { continue }
        _ = try? await library.put("sealed_secrets", id: id,
                                   ["name": .text(name), "machine_id": .text(machineID), "sealed": .blob(sealed)])
      }
    }
  }

  private func publicKeys() async throws -> [(String, Curve25519.KeyAgreement.PublicKey)] {
    var keys: [(String, Curve25519.KeyAgreement.PublicKey)] = []
    for machine in try await library.machines() {
      guard case .text(let text)? = try await library.row("machines", id: machine.id)?.values["public_key"],
            let raw = Data(base64Encoded: text), let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else { continue }
      keys.append((machine.id, key))
    }
    return keys
  }

  // MARK: Subscriptions (this machine only)

  func subscription(_ provider: String) throws -> JSONValue? {
    guard let data = try store.read("sign-in/" + provider) else { return nil }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  func setSubscription(_ provider: String, _ credential: JSONValue?) throws {
    try store.write("sign-in/" + provider, try credential.map { try JSONEncoder().encode($0) })
  }

  // MARK: Local model servers (this machine only)

  struct SavedModelServer: Codable {
    var server: LocalModelServer
    var key: String
  }

  func localModelServers() throws -> [SavedModelServer] {
    guard let data = try store.read("local-model-servers") else { return [] }
    return try JSONDecoder().decode([SavedModelServer].self, from: data)
  }

  func setLocalModelServers(_ servers: [SavedModelServer]) throws {
    try store.write("local-model-servers", servers.isEmpty ? nil : try JSONEncoder().encode(servers))
  }

  /// The model servers as Pi Durable registers them, without their keys.
  func piLocalServers() -> JSONValue {
    .array(((try? localModelServers()) ?? []).map {
      .object(["id": .string($0.server.id), "url": .string($0.server.url), "models": .array($0.server.models.map(JSONValue.string))])
    })
  }

  /// Pi Durable's chat settings on this machine: the synced setting
  /// `piDurable.<machineID>` when this machine keeps its own, else
  /// `piDurable`, with `defaultModel` from the defaults for new chats
  /// (`agentDefaults.piDurable[.<machineID>]`) and this machine's model servers.
  func piSettings() async -> JSONValue {
    func setting(_ key: String) async -> JSONValue? { (try? await library.setting(key))?.value }
    let own = library.machineID
    var settings = await setting("piDurable.\(own)")
    if settings == nil { settings = await setting("piDurable") }
    var defaults = await setting("agentDefaults.piDurable.\(own)")
    if defaults == nil { defaults = await setting("agentDefaults.piDurable") }
    guard case .object(var fields) = settings ?? .object([:]) else { return .object([:]) }
    fields["defaultModel"] = defaults?["model"]
    fields["localServers"] = piLocalServers()
    return .object(fields)
  }

  /// Every credential Pi Durable may use on this machine, in its shape.
  func piCredentials(subscriptions providers: [String]) async -> JSONValue {
    var credentials: [String: JSONValue] = [:]
    for (provider, key) in (try? await apiKeys()) ?? [:] {
      credentials[provider] = .object(["type": .string("apiKey"), "key": .string(key)])
    }
    for provider in providers {
      if let credential = try? subscription(provider) { credentials[provider] = credential }
    }
    for saved in (try? localModelServers()) ?? [] {
      credentials[saved.server.id] = .object(["type": .string("apiKey"), "key": .string(saved.key)])
    }
    return .object(credentials)
  }
}
